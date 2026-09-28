import 'package:flutter/foundation.dart';

import 'package:gundam_pos/api/api_client.dart';
import 'package:gundam_pos/api/pos_api.dart';
import 'package:gundam_pos/data/pos_store.dart';
import 'package:gundam_pos/logic/cart.dart';
import 'package:gundam_pos/logic/discount_voucher.dart' as dv;
import 'package:gundam_pos/logic/money.dart' as money;
import 'package:gundam_pos/logic/print_payload.dart';
import 'package:gundam_pos/logic/receipt.dart';
import 'package:gundam_pos/logic/shift_window.dart';
import 'package:gundam_pos/logic/shipment.dart';
import 'package:gundam_pos/models/config_models.dart';
import 'package:gundam_pos/services/print_dispatcher.dart';

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
    this.printer,
    this.openedAt,
    this.shiftGate,
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

  /// When the order was opened (server `openedAt`). Feeds the recap-window
  /// block on a pre-midnight hanging order. Null → that check is skipped.
  final DateTime? openedAt;

  /// Shift window gate (AUTOMATIC meal-shift). Null → derived from [config].
  final ShiftGate? shiftGate;

  ShiftGate get shiftRules => shiftGate ?? ShiftGate(config.shift);

  /// The shift-window reason this payment cannot proceed NOW (else null):
  /// outside the meal-shift range, or a pre-midnight hanging order caught in
  /// the recap window. The screen consults this to disable Settle and show the
  /// reason instead of offering a button that can only fail.
  String? get paymentBlock => shiftRules.blockPayment(openedAt);

  /// The outlet print path (from the app session). Null → printing is a no-op.
  final PrintDispatcher? printer;

  /// Honest print warnings from the last settle (never blocks the sale).
  List<String> printAlerts = const [];

  final List<money.PaymentInput> payments = [];

  /// Server-confirmed pricing choice: at most ONE discount OR ONE voucher per
  /// bill. Never set locally — applying or clearing goes through POST
  /// /api/pos/orders/[id]/pricing and this holds exactly what the SERVER
  /// returned (empty while an approval is pending).
  dv.PricingSelection pricing = dv.PricingSelection.none;

  /// True while a below-threshold choice is queued: the bill is AWAITING
  /// APPROVAL and no discount/voucher is applied yet.
  bool pricingPending = false;
  bool pricingBusy = false;

  /// The shipment line (separate revenue stream, after SC before rounding).
  /// Null = no shipment line. Set by the cashier BEFORE settle; cancellable
  /// until settle. Flows into [payable] and the settle body.
  ShipmentLine? shipment;

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
    return money.computeMoneyFlow(
      lines,
      pricing.amountFor(subtotal),
      shipment?.amount ?? 0,
      config.shift.roundingMode,
    );
  }

  double get payable => money.round2(_flow.total);

  /// Shipment line amount included in the payable (after SC, before rounding).
  double get shipmentAmount => money.round2(_flow.shipmentAmount);

  /// Set/replace the shipment from a cashier-typed OPEN amount. Empty or 0
  /// CLEARS the shipment (no line). Non-numeric or negative is rejected — a
  /// shipment can never be negative. Returns false (with [error]) when invalid.
  bool setOpenShipment(Object? raw, {String description = 'Shipment'}) {
    final v = parseShipmentAmount(raw);
    if (v == null) {
      error = 'Shipment amount must be a number of 0 or more.';
      notifyListeners();
      return false;
    }
    shipment = v > 0 ? ShipmentLine.open(v, description: description) : null;
    _recompute();
    return true;
  }

  /// Choose a MASTER shipment (precise amount). Unavailable while the server
  /// ships no masters (see [kShipmentMastersUnavailable]).
  bool setMasterShipment(ShipmentMaster m) {
    if (config.shipmentMasters.isEmpty) {
      error = kShipmentMastersUnavailable;
      notifyListeners();
      return false;
    }
    shipment = ShipmentLine.master(masterId: m.id, masterName: m.name, amount: m.amount);
    _recompute();
    return true;
  }

  /// Cancel the shipment line before settle — payable returns to its pre-shipment
  /// value (rounding is still applied exactly once, by the money-flow).
  void cancelShipment() {
    shipment = null;
    _recompute();
  }

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

  /// Propose applying a discount — the SERVER re-validates and decides. False
  /// (with [error] set) if the server rejected it.
  Future<bool> applyDiscount(dv.DiscountMaster d) => _setChoice(discountId: d.id);

  /// Propose applying a voucher — the SERVER re-validates and decides.
  Future<bool> applyVoucher(dv.VoucherMaster v) => _setChoice(voucherId: v.id);

  /// Clear the bill's discount/voucher through the server (ids sent null).
  Future<bool> cancelPricing() => _setChoice();

  /// Tablet proposes; server decides. A below-threshold caller gets a PENDING
  /// approval — the bill shows awaiting approval and nothing is applied locally.
  /// On success we ADOPT the server's ids (never a locally computed amount).
  Future<bool> _setChoice({String? discountId, String? voucherId}) async {
    pricingBusy = true;
    pricingPending = false;
    error = null;
    notifyListeners();
    try {
      final r = await posApi.setPricing(orderId, discountId: discountId, voucherId: voucherId);
      if (r['approval'] != null) {
        pricing = dv.PricingSelection.none;
        pricingPending = true;
      } else {
        final o = r['order'] as Map<String, dynamic>? ?? const {};
        _adoptServerChoice(o['discountId'] as String?, o['voucherId'] as String?);
      }
      _recompute();
      return true;
    } on PosApiException catch (e) {
      error = _pricingMessage(e);
      notifyListeners();
      return false;
    } on PosNetworkException {
      error = 'No network — discount/voucher not changed.';
      notifyListeners();
      return false;
    } finally {
      pricingBusy = false;
      notifyListeners();
    }
  }

  /// Adopt the server's authoritative choice: map the confirmed id back to the
  /// server-shipped config master. Any locally computed amount is discarded —
  /// display and settle money-flow derive from this, mirroring the server.
  void _adoptServerChoice(String? discountId, String? voucherId) {
    if (discountId != null) {
      final d = _discountById(discountId);
      pricing = d == null ? dv.PricingSelection.none : dv.PricingSelection(discount: d);
    } else if (voucherId != null) {
      final v = _voucherById(voucherId);
      pricing = v == null ? dv.PricingSelection.none : dv.PricingSelection(voucher: v);
    } else {
      pricing = dv.PricingSelection.none;
    }
  }

  dv.DiscountMaster? _discountById(String id) {
    for (final d in config.discounts) {
      if (d.id == id) return d;
    }
    return null;
  }

  dv.VoucherMaster? _voucherById(String id) {
    for (final v in config.vouchers) {
      if (v.id == id) return v;
    }
    return null;
  }

  /// Readable message for each server pricing error code.
  String _pricingMessage(PosApiException e) {
    switch (e.code) {
      case 'discount_expired':
      case 'voucher_expired':
        return 'That discount or voucher has expired.';
      case 'discount_inactive':
      case 'voucher_inactive':
        return 'That discount or voucher is no longer active.';
      case 'voucher_exhausted':
        return 'That voucher has no uses left.';
      case 'discount_not_eligible':
      case 'voucher_not_eligible':
        return 'That discount or voucher does not apply to the items on this bill.';
      case 'discount_and_voucher_mutually_exclusive':
        return 'A bill can have only one discount OR one voucher.';
      case 'discount_not_found':
      case 'voucher_not_found':
        return 'That discount or voucher is no longer available.';
      case 'order_closed':
        return 'This bill is already closed.';
      default:
        return e.isRateLimited
            ? 'Too many attempts. Wait and retry.'
            : 'Could not change the discount/voucher (${e.code}).';
    }
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
    // PRD: outside the meal-shift range no payment may complete; a pre-midnight
    // hanging order caught in the recap window must be finished after it.
    final block = shiftRules.blockPayment(openedAt);
    if (block != null) {
      error = block;
      notifyListeners();
      return false;
    }
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
        shipment: shipment?.toSettleBody(),
      );
      settled = r['bill'] as Map<String, dynamic>?;
      receiptId = (settled?['receiptId'] ?? id) as String;
      // Print the receipt at the settle moment; never blocks or fails the sale.
      printAlerts = await _printBill();
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

  Future<List<String>> _printBill() async {
    final d = printer;
    final s = split;
    if (d == null || s == null) return const [];
    final items = [for (final l in cart.lines) PrintItem.fromCartLine(l)];
    final names = {for (final m in config.paymentMethods) m.id: m.displayName};
    try {
      final out = await d.printBill(
        items: items,
        receiptId: receiptId ?? '',
        flow: _flow,
        split: s,
        methodNames: names,
        tableName: tableName,
      );
      return out.alerts;
    } catch (_) {
      return const ['Print path errored — sale unaffected.'];
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