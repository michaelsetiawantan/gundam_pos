import 'package:flutter_test/flutter_test.dart';
import 'package:gundam_pos/api/pos_api.dart';
import 'package:gundam_pos/logic/cart.dart';
import 'package:gundam_pos/logic/money.dart' as money;
import 'package:gundam_pos/logic/receipt.dart';
import 'package:gundam_pos/models/config_models.dart';
import 'package:gundam_pos/state/payment_controller.dart';

import 'support/fake_backend.dart';

TenantConfig _northstar() =>
    TenantConfig.fromSyncPayloads(FakeBackend.northstarMaster(), FakeBackend.northstarOutlet());

PosApi _backendPos() {
  final backend = FakeBackend();
  return backend.createSession().posApi;
}

Cart _singleEspresso() {
  final cart = Cart();
  cart.addLine(CartLine(
    itemId: 'item-espresso',
    name: 'Espresso',
    sku: 'NSTAR-NS-ESP',
    qty: 1,
    priceLevelIndex: 0,
    unitPrice: 25000,
    vatMode: money.VatScMode.exclude,
    scMode: money.VatScMode.none,
  ));
  return cart;
}

void main() {
  group('PaymentController payable + split', () {
    late TenantConfig config;

    setUp(() => config = _northstar());

    OutletPaymentMethod cashMethod(TenantConfig cfg) => cfg.paymentMethods.firstWhere((m) => m.type == money.PayType.cash);
    OutletPaymentMethod cardMethod(TenantConfig cfg) => cfg.paymentMethods.firstWhere((m) => m.type == money.PayType.nonCash);

    PaymentController makeCtrl(Cart cart) => PaymentController(
          posApi: _backendPos(),
          tenantId: 't1',
          config: config,
          orderId: 'order-1',
          tableName: 'A1',
          cart: cart,
          deviceAssetId: 'device-1',
          shortcode: 'NSTAR-POS1',
        );

    test('payable = money-flow with UP rounding (25000 + 11% VAT = 28000)', () {
      final c = makeCtrl(_singleEspresso());
      expect(c.payable, 28000);
    });

    test('exact cash → covered, no change or tip', () {
      final c = makeCtrl(_singleEspresso());
      expect(c.covered, isFalse);
      c.addPayment(cashMethod(config), 28000);
      expect(c.covered, isTrue);
      expect(c.change, 0);
      expect(c.tipsPending, 0);
      expect(c.remaining, 0);
    });

    test('cash overpay → change, no tip', () {
      final c = makeCtrl(_singleEspresso());
      c.addPayment(cashMethod(config), 40000);
      expect(c.covered, isTrue);
      expect(c.change, 12000);
      expect(c.tipsPending, 0);
      expect(c.hasNonCashOverpay, isFalse);
    });

    test('non-cash overpay → pending tip, no change', () {
      final c = makeCtrl(_singleEspresso());
      c.addPayment(cardMethod(config), 32000);
      expect(c.covered, isTrue);
      expect(c.change, 0);
      expect(c.tipsPending, 4000);
      expect(c.hasNonCashOverpay, isTrue);
    });

    test('insufficient → not covered, split cleared until whole payable covered', () {
      final c = makeCtrl(_singleEspresso());
      c.addPayment(cashMethod(config), 20000);
      expect(c.covered, isFalse);
      expect(c.remaining, 8000);
      expect(c.split, isNull);
      c.addPayment(cardMethod(config), 8000);
      expect(c.covered, isTrue);
      expect(c.payments, hasLength(2));
    });

    test('split continues until payable covered (partial second line)', () {
      final c = makeCtrl(_singleEspresso());
      c.addPayment(cardMethod(config), 15000);
      c.addPayment(cardMethod(config), 15000);
      // 30000 → over 28000 by 2000 → pending tip
      expect(c.covered, isTrue);
      expect(c.tipsPending, 2000);
    });

    test('settle generates device receipt id and records the server bill', () async {
      final c = makeCtrl(_singleEspresso());
      c.addPayment(cashMethod(config), 28000);
      expect(await c.settle(), isTrue);
      expect(c.receiptId, startsWith('NSTAR-POS1-'));
      expect(isValidReceiptId(c.receiptId!), isTrue);
      expect(c.settled, isNotNull);
      expect(c.error, isNull);
    });
  });

  group('ReceiptSequencer', () {
    test('increments seq and resets per date', () async {
      final seq = ReceiptSequencer();
      final d1 = DateTime(2026, 9, 17, 10, 0);
      expect(await seq.next(shortcode: 'NS', at: d1), 'NS-20260917-10:00-0000001');
      expect(await seq.next(shortcode: 'NS', at: d1.add(const Duration(minutes: 5))), 'NS-20260917-10:05-0000002');
      final d2 = DateTime(2026, 9, 18, 9, 30);
      expect(await seq.next(shortcode: 'NS', at: d2), 'NS-20260918-09:30-0000001');
    });
  });
}