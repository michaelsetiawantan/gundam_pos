import 'dart:math' as math;

// Client mirror of `web/lib/pos/money.ts` (server is authoritative at settle).
// The bill is rounded exactly ONCE in the money-flow (after VAT/SC/shipment);
// the payment split NEVER re-rounds — it only allocates against the fixed
// payable and derives change / pending tip. Cash overpay → change; non-cash
// overpay → pending tip (approve/reject is web-only).

double round2(double n) => (n * 100).roundToDouble() / 100;

enum PayType { cash, nonCash }

class PaymentInput {
  PaymentInput({
    required this.outletMethodId,
    required this.type,
    required this.amount,
    this.reference,
  });

  final String outletMethodId;
  final PayType type;
  final double amount;
  final String? reference;
}

class PaymentAllocation {
  PaymentAllocation({
    required this.outletMethodId,
    required this.type,
    required this.amount,
    required this.allocated,
    required this.change,
    required this.tipsPending,
    required this.splitIndex,
    this.reference,
  });

  final String outletMethodId;
  final PayType type;
  final double amount;
  final double allocated; // counts toward payable
  final double change; // cash overpay on this line
  final bool tipsPending; // non-cash overpay on this line
  final int splitIndex; // 1-based
  final String? reference;
}

class SplitResult {
  SplitResult({
    required this.pay,
    required this.change,
    required this.tips,
    required this.paid,
    required this.payable,
  });

  final List<PaymentAllocation> pay;
  final double change;
  final double tips;
  final double paid;
  final double payable;
}

/// Allocate each payment against the fixed payable until it is fully covered.
/// Mirrors server `finalizePayments`. Returns an error string when total <
/// payable.
SplitResult finalizePayments(double payable, List<PaymentInput> payments) {
  var remaining = payable;
  var change = 0.0;
  var tips = 0.0;
  final pay = <PaymentAllocation>[];
  for (var i = 0; i < payments.length; i++) {
    final p = payments[i];
    final amount = round2(math.max(0, p.amount));
    final allocated = round2(math.min(amount, math.max(0, remaining)));
    if (allocated > 0) remaining = round2(remaining - allocated);
    final over = round2(amount - allocated);
    var lineChange = 0.0;
    var tipsPending = false;
    if (over > 0) {
      if (p.type == PayType.cash) {
        lineChange = over;
      } else {
        tips = round2(tips + over);
        tipsPending = true;
      }
    }
    change = round2(change + lineChange);
    pay.add(PaymentAllocation(
      outletMethodId: p.outletMethodId,
      type: p.type,
      amount: amount,
      allocated: allocated,
      change: lineChange,
      tipsPending: tipsPending,
      splitIndex: i + 1,
      reference: p.reference,
    ));
  }
  if (remaining > 0) {
    throw const InsufficientPaymentException();
  }
  final paid = round2(payments.fold<double>(0, (s, p) => s + math.max(0, p.amount)));
  return SplitResult(pay: pay, change: change, tips: tips, paid: paid, payable: payable);
}

class InsufficientPaymentException implements Exception {
  const InsufficientPaymentException();

  final String error = 'insufficient_payment';
}

// ---------------------------------------------------------------------------
// Money-flow (server `pricing.ts` mirror) — used to show the payable preview
// before settle. Server recomputes and is authoritative.
// ---------------------------------------------------------------------------

enum RoundingMode { none, up, down }

enum VatScMode { none, include, exclude }

({double vatAmount, double scAmount}) taxPortions(
  double amount,
  VatScMode vatMode,
  double? vatRate,
  VatScMode scMode,
  double? scRate,
) {
  double portion(double a, VatScMode mode, double? rate) {
    if (mode == VatScMode.none || rate == null || rate <= 0) return 0;
    if (mode == VatScMode.exclude) return a * (rate / 100);
    return a - a / (1 + rate / 100);
  }

  return (vatAmount: portion(amount, vatMode, vatRate), scAmount: portion(amount, scMode, scRate));
}

({double total, double roundingAmount}) applyRounding(double amount, RoundingMode mode) {
  if (mode == RoundingMode.none) return (total: amount, roundingAmount: 0);
  final rem = amount % 1000;
  var total = amount;
  if (mode == RoundingMode.up && rem >= 500) total = amount - rem + 1000;
  if (mode == RoundingMode.down && rem < 500) total = amount - rem;
  return (total: total, roundingAmount: total - amount);
}

class MoneyLine {
  MoneyLine({
    required this.subtotal,
    this.vatMode = VatScMode.none,
    this.vatRate,
    this.scMode = VatScMode.none,
    this.scRate,
  });

  final double subtotal;
  final VatScMode vatMode;
  final double? vatRate;
  final VatScMode scMode;
  final double? scRate;
}

class MoneyFlow {
  final double subtotal;
  final double discountAmount;
  final double vatAmount;
  final double scAmount;
  final double shipmentAmount;
  final double roundingAmount;
  final double total;

  MoneyFlow({
    required this.subtotal,
    required this.discountAmount,
    required this.vatAmount,
    required this.scAmount,
    required this.shipmentAmount,
    required this.roundingAmount,
    required this.total,
  });
}

/// Ledger money-flow: subtotal −discount +VAT +SC +shipment → round ONCE → total.
MoneyFlow computeMoneyFlow(
  List<MoneyLine> lines,
  double discountAmount,
  double shipmentAmount,
  RoundingMode roundingMode,
) {
  var subtotal = 0.0, vat = 0.0, sc = 0.0;
  for (final l in lines) {
    subtotal += l.subtotal;
    final t = taxPortions(l.subtotal, l.vatMode, l.vatRate, l.scMode, l.scRate);
    vat += t.vatAmount;
    sc += t.scAmount;
  }
  final afterShipment = subtotal - discountAmount + vat + sc + shipmentAmount;
  final r = applyRounding(afterShipment, roundingMode);
  return MoneyFlow(
    subtotal: subtotal,
    discountAmount: discountAmount,
    vatAmount: vat,
    scAmount: sc,
    shipmentAmount: shipmentAmount,
    roundingAmount: r.roundingAmount,
    total: r.total,
  );
}