import 'package:flutter_test/flutter_test.dart';
import 'package:gundam_pos/logic/money.dart';

void main() {
  group('finalizePayments (server money.ts mirror)', () {
    test('exact cash covers payable, no change', () {
      final r = finalizePayments(100.0, [
        PaymentInput(outletMethodId: 'cash', type: PayType.cash, amount: 100),
      ]);
      expect(r.payable, 100.0);
      expect(r.change, 0.0);
      expect(r.tips, 0.0);
      expect(r.pay.single.allocated, 100.0);
      expect(r.pay.single.splitIndex, 1);
    });

    test('cash overpay produces change', () {
      final r = finalizePayments(75000, [
        PaymentInput(outletMethodId: 'cash', type: PayType.cash, amount: 100000),
      ]);
      expect(r.change, 25000);
      expect(r.tips, 0.0);
    });

    test('non-cash overpay becomes a PENDING tip (no change)', () {
      final r = finalizePayments(75000, [
        PaymentInput(outletMethodId: 'card', type: PayType.nonCash, amount: 80000),
      ]);
      expect(r.change, 0.0);
      expect(r.tips, 5000);
      expect(r.pay.single.tipsPending, isTrue);
    });

    test('split across two methods sums to payable, no second rounding', () {
      final r = finalizePayments(100000, [
        PaymentInput(outletMethodId: 'cash', type: PayType.cash, amount: 50000),
        PaymentInput(outletMethodId: 'card', type: PayType.nonCash, amount: 50000),
      ]);
      expect(r.payable, 100000);
      expect(r.change, 0.0);
      expect(r.paid, 100000);
      expect(r.pay, hasLength(2));
      expect(r.pay[1].splitIndex, 2);
    });

    test('split continues until payable covered', () {
      final r = finalizePayments(60000, [
        PaymentInput(outletMethodId: 'cash', type: PayType.cash, amount: 20000),
        PaymentInput(outletMethodId: 'card', type: PayType.nonCash, amount: 50000),
      ]);
      expect(r.change, 0.0);
      expect(r.tips, 10000); // 50k card over the remaining 40k
    });

    test('insufficient payment throws', () {
      expect(
        () => finalizePayments(50000, [
          PaymentInput(outletMethodId: 'cash', type: PayType.cash, amount: 40000),
        ]),
        throwsA(isA<InsufficientPaymentException>()),
      );
    });
  });

  group('computeMoneyFlow (server pricing.ts mirror)', () {
    MoneyLine plain(double subtotal) =>
        MoneyLine(subtotal: subtotal); // no tax, no sc

    test('no tax/rounding → total equals subtotal', () {
      final f = computeMoneyFlow([plain(100000), plain(50000)], 0, 0, RoundingMode.none);
      expect(f.subtotal, 150000);
      expect(f.vatAmount, 0);
      expect(f.total, 150000);
      expect(f.roundingAmount, 0);
    });

    test('rounding UP to next thousand (last 3 >= 500)', () {
      final f = computeMoneyFlow([plain(601500)], 0, 0, RoundingMode.up);
      expect(f.total, 602000);
      expect(f.roundingAmount, 500);
    });

    test('rounding DOWN (last 3 < 500)', () {
      final f = computeMoneyFlow([plain(601499)], 0, 0, RoundingMode.down);
      expect(f.total, 601000);
      expect(f.roundingAmount, -499);
    });

    test('discount is subtract-only, pre-tax', () {
      final f = computeMoneyFlow([plain(100000)], 10000, 0, RoundingMode.none);
      expect(f.discountAmount, 10000);
      expect(f.total, 90000);
    });

    test('shipment adds after SC, before rounding', () {
      final f = computeMoneyFlow([plain(100000)], 0, 20000, RoundingMode.none);
      expect(f.shipmentAmount, 20000);
      expect(f.total, 120000);
    });

    test('VAT exclude adds percentage; include extracts embedded', () {
      final excl = computeMoneyFlow([
        MoneyLine(subtotal: 100000, vatMode: VatScMode.exclude, vatRate: 11),
      ], 0, 0, RoundingMode.none);
      expect(excl.vatAmount, closeTo(11000, 0.001));
      expect(excl.total, closeTo(111000, 0.001));

      final incl = computeMoneyFlow([
        MoneyLine(subtotal: 111000, vatMode: VatScMode.include, vatRate: 11),
      ], 0, 0, RoundingMode.none);
      expect(incl.vatAmount, closeTo(11000, 0.001));
    });
  });
}