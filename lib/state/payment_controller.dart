import 'dart:async';

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
import 'package:gundam_pos/state/pricing_controller.dart';

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
    this.openedByName = '',
    this.deviceAssetId,
    this.shortcode,
    ReceiptSequencer? receipts,
    this.onSettled,
    this.printer,
    this.openedAt,
    this.shiftGate,
    this.onPrintAlerts,
    this.pushStore,
    PricingController? pricingController,
  })  : _receipts = receipts ?? ReceiptSequencer(),
        // Share the order's pricing when the cashier already applied a
        // discount/voucher during order entry — one source of truth for the
        // payable preview on both screens.
        _pricing = pricingController ??
            PricingController(posApi: posApi, orderId: orderId, config: config, cart: cart) {
    _pricing.addListener(_onPricingChanged);
  }

  final PosApi posApi;
  final String tenantId;
  final TenantConfig config;
  final String orderId;
  final String? tableName;

  /// Numeric table NUMBER for the print payload — derived from the table label.
  String get tableNumber {
    final t = (tableName ?? '').trim();
    return RegExp(r'^\d+$').hasMatch(t) ? t : '';
  }

  /// Cashier who opened the order (feeds {cashier_name_opened_bill}); '' when the
  /// caller has no opener (the token then prints blank, never a wrong name).
  final String openedByName;
  final Cart cart;
  final String? deviceAssetId;
  final String? shortcode;
  final ReceiptSequencer _receipts;

  /// Durable outbox. When present, a settle that cannot reach the server is
  /// completed LOCALLY (money flow + receipt id are device-side) and queued as an
  /// idempotent `order_settle` push; when null the legacy server-only settle runs.
  final PushStore? pushStore;

  /// True when the last settle completed LOCALLY (offline) and its
  /// `order_settle` is still queued — the screen can say "will sync later".
  bool offlineSettled = false;

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
  /// Filled late — the print runs OFF the settle path, so this is set when the
  /// printer finally answers, not when [settle] returns.
  List<String> printAlerts = const [];

  /// Delivered the moment a fire-and-forget print finishes with warnings, so the
  /// operator still sees them after the settle screen has moved on. Wired to the
  /// app session's shared alert surface; never called with an empty list.
  final void Function(List<String> alerts)? onPrintAlerts;

  final List<money.PaymentInput> payments = [];

  /// The order's discount/voucher — shared with order entry (see ctor). All
  /// apply/clear goes through the server; this holds what the server returned.
  final PricingController _pricing;
  PricingController get pricingController => _pricing;

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
      _pricing.selection.amountFor(subtotal),
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

  dv.PricingSelection get pricing => _pricing.selection;
  dv.DiscountMaster? get appliedDiscount => _pricing.selection.discount;
  dv.VoucherMaster? get appliedVoucher => _pricing.selection.voucher;
  bool get pricingPending => _pricing.pending;
  bool get pricingBusy => _pricing.busy;

  /// Discounts offered for the current cart (active, unexpired, category-eligible).
  List<dv.DiscountMaster> get availableDiscounts => _pricing.availableDiscounts;

  /// Vouchers offered for the current cart (active, unexpired, eligible, in quota).
  List<dv.VoucherMaster> get availableVouchers => _pricing.availableVouchers;

  /// Propose applying a discount — the SERVER re-validates and decides. False
  /// (with [error] set) if the server rejected it.
  Future<bool> applyDiscount(dv.DiscountMaster d) => _pricing.applyDiscount(d);

  /// Propose applying a voucher — the SERVER re-validates and decides.
  Future<bool> applyVoucher(dv.VoucherMaster v) => _pricing.applyVoucher(v);

  /// Clear the bill's discount/voucher through the server (ids sent null).
  Future<bool> cancelPricing() => _pricing.cancelPricing();

  /// Pricing changed (applied here or from order entry): the payable moved, so
  /// re-allocate the split and surface the pricing error on this controller too.
  void _onPricingChanged() {
    try {
      split = money.finalizePayments(payable, payments);
    } on money.InsufficientPaymentException {
      split = null;
    }
    error = _pricing.error;
    notifyListeners();
  }

  @override
  void dispose() {
    _pricing.removeListener(_onPricingChanged);
    super.dispose();
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
  /// server (authoritative ledger + payment snapshots + order close). When the
  /// server is UNREACHABLE (offline-first), the sale is completed LOCALLY with
  /// the same money flow + receipt id and queued as an idempotent
  /// `order_settle` push — the cashier is never stopped by a dead network.
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
    offlineSettled = false;
    notifyListeners();
    try {
      final id = await _receipts.next(shortcode: shortcode ?? 'POS', at: DateTime.now());
      try {
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
        onSettled?.call(settled);
        // Print the receipt OFF the settle path: the server already recorded the
        // payment, so a slow/flaky printer (3 attempts × 20s) must never keep the
        // cashier waiting. The honest warnings arrive later via [printAlerts] and
        // [onPrintAlerts] — the sale never waits for paper.
        unawaited(_printBillAndNotify());
        return settled != null;
      } on PosNetworkException {
        // Offline-first: complete the sale locally and queue the push. Without a
        // durable outbox there is nowhere to keep the settlement, so keep the
        // legacy honest failure.
        if (pushStore == null) {
          error = 'No network — payment not settled.';
          return false;
        }
        return await _settleOffline(id);
      }
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

  /// Complete the sale WITHOUT the server: money flow + receipt id are already
  /// device-side, so mark the order PAID locally, print the bill (local path),
  /// and queue the full snapshot as an idempotent `order_settle` push. Returns
  /// true (the sale is done); the push is a background concern.
  Future<bool> _settleOffline(String id) async {
    receiptId = id;
    final key = id; // unique per settlement (device shortcode + day + seq)
    final now = DateTime.now();
    final payload = _settlementPayload(key, now);
    try {
      await pushStore!.enqueue('order_settle', key, payload);
    } catch (_) {
      // Never lose the sale to an outbox write failure; the cashier is told via
      // the Today's list (pending) once the queue is readable again.
    }
    final bill = <String, dynamic>{
      'orderId': orderId,
      'receiptId': id,
      'status': 'PAID',
      'total': payable,
      'change': money.round2(split?.change ?? 0),
      'tipsPending': money.round2(split?.tips ?? 0),
      'paidAt': now.toUtc().toIso8601String(),
      'offline': true,
      'clientSettlementKey': key,
    };
    settled = bill;
    offlineSettled = true;
    onSettled?.call(bill);
    unawaited(_printBillAndNotify());
    return true;
  }

  /// The FULL settlement snapshot for `POST /orders/{id}/settle-deferred`.
  /// Prices come from the ACTUAL cart lines (never recomputed from the master,
  /// which may have changed) so the server replays exactly what the cashier rang.
  Map<String, dynamic> _settlementPayload(String key, DateTime now) {
    final sel = _pricing.selection;
    final pay = split;
    return {
      'orderId': orderId,
      'clientSettlementKey': key,
      'receiptId': receiptId ?? key,
      'paidAt': now.toUtc().toIso8601String(),
      if (openedAt != null) 'openedAt': openedAt!.toUtc().toIso8601String(),
      'closedAt': now.toUtc().toIso8601String(),
      'lines': [
        for (final l in cart.lines)
          {
            'itemId': l.itemId,
            'itemName': l.name,
            'qty': l.qty,
            'priceLevelIndex': l.priceLevelIndex,
            'unitPrice': l.unitPrice,
            'vatMode': _modeName(l.vatMode),
            'scMode': _modeName(l.scMode),
            'mods': [
              for (final m in l.modifiers)
                {
                  if (m.modifierId != null) 'modifierId': m.modifierId,
                  'name': m.name,
                  'price': m.price,
                  'qty': m.qty,
                  if (m.openText != null) 'openText': m.openText,
                },
            ],
          },
      ],
      'payments': [
        for (final p in payments)
          {
            'outletMethodId': p.outletMethodId,
            'name': _methodName(p.outletMethodId),
            'type': p.type == money.PayType.cash ? 'CASH' : 'NON_CASH',
            'amount': p.amount,
            if (p.reference != null) 'reference': p.reference,
          },
      ],
      'totals': {
        'subtotal': money.round2(_flow.subtotal),
        'discountAmount': money.round2(_flow.discountAmount),
        'vatAmount': money.round2(_flow.vatAmount),
        'scAmount': money.round2(_flow.scAmount),
        'shipmentAmount': money.round2(_flow.shipmentAmount),
        'roundingAmount': money.round2(_flow.roundingAmount),
        'tipsAmount': money.round2(pay?.tips ?? 0),
        'total': payable,
        'change': money.round2(pay?.change ?? 0),
        'paidAmount': paid,
      },
      'discountId': sel.discount?.id,
      'voucherId': sel.voucher?.id,
      if (deviceAssetId != null) 'deviceId': deviceAssetId,
    };
  }

  String _methodName(String outletMethodId) {
    for (final m in config.paymentMethods) {
      if (m.id == outletMethodId) return m.displayName;
    }
    return '';
  }

  static String _modeName(money.VatScMode m) => switch (m) {
        money.VatScMode.include => 'INCLUDE',
        money.VatScMode.exclude => 'EXCLUDE',
        money.VatScMode.none => 'NONE',
      };

  /// Run [printBill] without holding the settle caller: fill [printAlerts] and
  /// publish any honest warnings when it finally finishes, even if the screen is
  /// gone. Never throws (the dispatcher path is already best-effort).
  Future<void> _printBillAndNotify() async {
    final alerts = await _printBill();
    printAlerts = alerts;
    if (alerts.isNotEmpty) onPrintAlerts?.call(alerts);
  }

  Future<List<String>> _printBill() async {
    final d = printer;
    final s = split;
    if (d == null || s == null) return const [];
    // The printed bill merges identical picks into one row (qty summed).
    final items = mergePrintItems([for (final l in cart.lines) PrintItem.fromCartLine(l)]);
    final names = {for (final m in config.paymentMethods) m.id: m.displayName};
    // Discount/voucher are mutually exclusive (1 bill = 1). The applied amount
    // is already inside the money-flow; split it onto the right caption so the
    // printed bill matches the preview.
    final sel = _pricing.selection;
    try {
      final out = await d.printBill(
        items: items,
        receiptId: receiptId ?? '',
        flow: _flow,
        split: s,
        methodNames: names,
        tableName: tableName,
        tableNumber: tableNumber,
        openedBy: openedByName,
        discountName: sel.discount?.name ?? '',
        voucherName: sel.voucher?.name ?? '',
        discountAmount: sel.discount != null ? _flow.discountAmount : 0.0,
        voucherAmount: sel.voucher != null ? _flow.discountAmount : 0.0,
        // A CASH sale pops the drawer (wired to the receipt printer). The pulse
        // rides THIS bill job — same connection, same queue, works offline.
        openDrawer: payments.any((p) => p.type == money.PayType.cash),
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