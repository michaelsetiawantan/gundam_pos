import 'package:flutter/foundation.dart';

import 'package:gundam_pos/api/api_client.dart';
import 'package:gundam_pos/api/pos_api.dart';
import 'package:gundam_pos/data/pos_store.dart';
import 'package:gundam_pos/logic/cart.dart';
import 'package:gundam_pos/logic/discount_voucher.dart' as dv;
import 'package:gundam_pos/logic/money.dart' as money;
import 'package:gundam_pos/logic/receipt.dart';
import 'package:gundam_pos/models/config_models.dart';

/// Drives payment for an order: canonical payable preview (server recomputes at
/// settle), split allocation until payable is covered — rounding happens once
/// in the money-flow, NEVER again in the split. Cash overpay → change; non-cash
/// overpay → pending tip (approve/reject is web-only). Settle calls the server.
class PaymentController extends ChangeNotifier {
  PaymentController({
    required this.posApi,
    required this.tenantId,
    required this.config,
    required this.orderId,
    required this.tableName,
    required this.cart,
    this.deviceAssetId,
    this.shortcode,
    ReceiptSequencer? receipts,
    this.onSettled,
  }) : _receipts = receipts ?? ReceiptSequencer();

  final PosApi posApi;
  final String tenantId;
  final TenantConfig config;
  final String orderId;
  final String? tableName;
  final Cart cart;
  final String? deviceAssetId;
  final String? shortcode;
  final ReceiptSequencer _receipts;

  final List<money.PaymentInput> payments = [];

  /// At most ONE discount OR ONE voucher per bill (mutually exclusive). Empty
  /// until the cashier picks one; the server re-validates and is authoritative.
  dv.PricingSelection pricing = dv.PricingSelection.none;

  /// Result of the last successful split (pay/change/tips). Null while unpaid.
  money.SplitResult? split;
  Map<String, dynamic>? settled; // server bill
  String? receiptId;
  bool settling = false;
  String? error;

  /// Called with the server bill after a successful settle (used to record the
  /// bill into the session's same-day ledger).
  void Function(Map<String, dynamic>? bill)? onSettled;

  bool get covered => paid >= payable;

  /// Canonical money-flow preview: subtotal − (discount|voucher) + VAT + SC →
  /// round ONCE → total. Server recomputes authoritatively at settle.
  money.MoneyFlow get _flow {
    final lines = <money.MoneyLine>[
      for (final l in cart.lines)
        money.MoneyLine(
          subtotal: l.lineSubtotal,
          vatMode: l.vatMode,
          vatRate: config.itemById(l.itemId)?.vatRate,
          scMode: l.scMode,
          scRate: config.itemById(l.itemId)?.scRate,
        ),
    ];
    final subtotal = lines.fold<double>(0, (s, l) => s + l.subtotal);
    return money.computeMoneyFlow(lines, pricing.amountFor(subtotal), 0, config.shift.roundingMode);
  }

  double get payable => money.round2(_flow.total);

  /// Discount/voucher amount applied to the bill (before VAT/SC).
  double get discountAmount => money.round2(_flow.discountAmount);

  dv.DiscountMaster? get appliedDiscount => pricing.discount;
  dv.VoucherMaster? get appliedVoucher => pricing.voucher;

  List<String> get _lineCategoryIds => [
        for (final l in cart.lines)
          if (config.itemById(l.itemId)?.categoryId case final c?) c,
      ];

  /// Discounts offered for the current cart (active, unexpired, category-eligible).
  List<dv.DiscountMaster> get availableDiscounts => dv.eligibleDiscounts(
        discounts: config.discounts,
        lineCategoryIds: _lineCategoryIds,
        parentById: config.categoryParentId,
      );

  /// Vouchers offered for the current cart (active, unexpired, eligible, in quota).
  List<dv.VoucherMaster> get availableVouchers => dv.eligibleVouchers(
        vouchers: config.vouchers,
        lineCategoryIds: _lineCategoryIds,
        parentById: config.categoryParentId,
      );

  /// Apply a discount — replaces any applied voucher (one-per-bill).
  void applyDiscount(dv.DiscountMaster d) {
    pricing = pricing.applyDiscount(d);
    _recompute();
  }

  /// Apply a voucher — replaces any applied discount (one-per-bill).
  void applyVoucher(dv.VoucherMaster v) {
    pricing = pricing.applyVoucher(v);
    _recompute();
  }

  /// Cancel the applied discount/voucher (distinct from cancelling the order).
  void cancelPricing() {
    pricing = pricing.cleared();
    _recompute();
  }

  double get paid => money.round2(payments.fold<double>(0, (s, p) => s + p.amount));
  double get remaining => money.round2((payable - paid).clamp(0, double.infinity));
  double get change => split?.change ?? 0;
  double get tipsPending => split?.tips ?? 0;
  bool get hasNonCashOverpay => split?.pay.any((p) => p.tipsPending) ?? false;
  int get splitIndex => payments.length + 1;

  void addPayment(OutletPaymentMethod method, double amount) {
    if (amount <= 0) return;
    payments.add(money.PaymentInput(outletMethodId: method.id, type: method.type, amount: amount));
    _recompute();
  }

  void removePayment(int index) {
    if (index < 0 || index >= payments.length) return;
    payments.removeAt(index);
    _recompute();
  }

  void _recompute() {
    try {
      split = money.finalizePayments(payable, payments);
    } on money.InsufficientPaymentException {
      split = null;
    }
    error = null;
    notifyListeners();
  }

  /// Settle: generate the device-side receipt id, then hand the split to the
  /// server (authoritative ledger + payment snapshots + order close).
  Future<bool> settle() async {
    if (!covered) return false;
    settling = true;
    error = null;
    notifyListeners();
    try {
      final id = await _receipts.next(shortcode: shortcode ?? 'POS', at: DateTime.now());
      final r = await posApi.settle(
        orderId,
        payments: [
          for (final p in payments) {'outletMethodId': p.outletMethodId, 'amount': p.amount},
        ],
        receiptId: id,
        transactedAt: DateTime.now().toUtc().toIso8601String(),
        deviceAssetId: deviceAssetId,
      );
      settled = r['bill'] as Map<String, dynamic>?;
      receiptId = (settled?['receiptId'] ?? id) as String;
      onSettled?.call(settled);
      return settled != null;
    } on PosApiException catch (e) {
      error = _settleMessage(e);
      return false;
    } on PosNetworkException {
      error = 'No network — payment not settled.';
      return false;
    } finally {
      settling = false;
      notifyListeners();
    }
  }

  String _settleMessage(PosApiException e) {
    switch (e.code) {
      case 'insufficient_payment':
        return 'Payments do not cover the total yet.';
      case 'receipt_id_exists':
        return 'This receipt was already recorded. Retrying next number.';
      case 'require_send_cart':
        return 'Send the cart to the kitchen before payment.';
      case 'method_inactive':
        return 'One of the payment methods is no longer active.';
      default:
        return e.isRateLimited ? 'Too many attempts. Wait and retry.' : 'Settlement failed (${e.code}).';
    }
  }
}

/// Device-side receipt sequence (reset 00:00 per device per LOCAL-SCHEMA).
/// Persisted through a [ReceiptSequenceStore] (sqflite `receipt_sequence` on
/// device; in-memory in tests/fallback) so numbering survives app restart.
class ReceiptSequencer {
  ReceiptSequencer({DateTime Function()? now, ReceiptSequenceStore? store})
      : _now = now ?? DateTime.now,
        _store = store ?? MemoryReceiptSequenceStore();

  final DateTime Function() _now;
  final ReceiptSequenceStore _store;

  /// Returns the next receipt id: `[shortcode]-[YYYYMMDD]-[HH:MM]-NNNNNNN`.
  /// The sequence is atomically incremented per (device, day).
  Future<String> next({required String shortcode, DateTime? at}) async {
    final now = at ?? _now();
    final date = dateStamp(now);
    final seq = await _store.next(shortcode, date);
    return makeReceiptId(shortcode: shortcode, at: now, seq: seq);
  }
}