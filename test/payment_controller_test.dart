import 'package:flutter_test/flutter_test.dart';
import 'package:gundam_pos/logic/cart.dart';
import 'package:gundam_pos/logic/money.dart' as money;
import 'package:gundam_pos/logic/receipt.dart';
import 'package:gundam_pos/models/config_models.dart';
import 'package:gundam_pos/state/payment_controller.dart';

import 'support/fake_backend.dart';

TenantConfig _northstar() =>
    TenantConfig.fromSyncPayloads(FakeBackend.northstarMaster(), FakeBackend.northstarOutlet());

FakeBackend _backend() => FakeBackend();

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

    PaymentController makeCtrl(Cart cart, {FakeBackend? backend}) => PaymentController(
          posApi: (backend ?? _backend()).createSession().posApi,
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

  group('PaymentController shipment step', () {
    late TenantConfig config;
    setUp(() => config = _northstar());

    OutletPaymentMethod cashMethod(TenantConfig cfg) =>
        cfg.paymentMethods.firstWhere((m) => m.type == money.PayType.cash);

    PaymentController makeCtrl(Cart cart, {FakeBackend? backend, TenantConfig? cfg}) => PaymentController(
          posApi: (backend ?? _backend()).createSession().posApi,
          tenantId: 't1',
          config: cfg ?? config,
          orderId: 'order-1',
          tableName: 'A1',
          cart: cart,
          deviceAssetId: 'device-1',
          shortcode: 'NSTAR-POS1',
        );

    test('open shipment joins the payable AFTER SC and rounds exactly once', () {
      final c = makeCtrl(_singleEspresso());
      expect(c.payable, 28000); // 25000 + 11% VAT = 27750 → UP → 28000
      expect(c.setOpenShipment('5000'), isTrue);
      expect(c.shipmentAmount, 5000);
      // 25000 + 2750 VAT + 5000 shipment = 32750 → UP → 33000 (rounded once)
      expect(c.payable, 33000);
      expect(c.shipment!.isMaster, isFalse);
    });

    test('open shipment validation: rejects non-numeric and negative, 0 = no line', () {
      final c = makeCtrl(_singleEspresso());
      expect(c.setOpenShipment('abc'), isFalse);
      expect(c.error, 'Shipment amount must be a number of 0 or more.');
      expect(c.shipment, isNull);
      expect(c.setOpenShipment('-5'), isFalse);
      expect(c.shipment, isNull);
      expect(c.setOpenShipment(''), isTrue);
      expect(c.shipment, isNull);
      expect(c.setOpenShipment('0'), isTrue);
      expect(c.shipment, isNull);
      expect(c.shipmentAmount, 0);
      expect(c.payable, 28000);
    });

    test('master shipment used when the config ships masters', () {
      final withMaster = TenantConfig.fromSyncPayloads(
        {
          ...FakeBackend.northstarMaster(),
          'shipmentMasters': [
            {'id': 'ship-1', 'name': 'Gojek Instant', 'amount': '15000', 'active': true},
          ],
        },
        FakeBackend.northstarOutlet(),
      );
      final c = makeCtrl(_singleEspresso(), cfg: withMaster);
      expect(c.setMasterShipment(withMaster.shipmentMasters.first), isTrue);
      expect(c.shipment!.isMaster, isTrue);
      expect(c.shipment!.amount, 15000);
      // 25000 + 2750 VAT + 15000 = 42750 → UP → 43000
      expect(c.payable, 43000);
    });

    test('master shipment unavailable without shipped masters (open path only)', () {
      final c = makeCtrl(_singleEspresso());
      expect(c.setMasterShipment(ShipmentMaster(id: 'x', name: 'x', amount: 9000)), isFalse);
      expect(c.error, kShipmentMastersUnavailable);
      expect(c.shipment, isNull);
    });

    test('cancelling the shipment restores the original payable', () {
      final c = makeCtrl(_singleEspresso());
      c.setOpenShipment('7000');
      expect(c.payable, isNot(28000));
      c.cancelShipment();
      expect(c.shipment, isNull);
      expect(c.shipmentAmount, 0);
      expect(c.payable, 28000);
    });

    test('settle body carries the OPEN shipment shape', () async {
      final backend = _backend();
      final c = makeCtrl(_singleEspresso(), backend: backend);
      c.setOpenShipment('5000');
      c.addPayment(cashMethod(config), 33000);
      expect(await c.settle(), isTrue);
      final ship = backend.lastSettleBody!['shipment'] as Map<String, dynamic>;
      expect(ship['amount'], 5000);
      expect(ship['description'], 'Shipment');
      expect(ship.containsKey('masterShipmentId'), isFalse);
    });

    test('settle body carries the MASTER shipment shape', () async {
      final backend = _backend();
      final withMaster = TenantConfig.fromSyncPayloads(
        {
          ...FakeBackend.northstarMaster(),
          'shipmentMasters': [
            {'id': 'ship-1', 'name': 'Gojek Instant', 'amount': '15000', 'active': true},
          ],
        },
        FakeBackend.northstarOutlet(),
      );
      final c = makeCtrl(_singleEspresso(), backend: backend, cfg: withMaster);
      c.setMasterShipment(withMaster.shipmentMasters.first);
      c.addPayment(cashMethod(withMaster), 43000);
      expect(await c.settle(), isTrue);
      final ship = backend.lastSettleBody!['shipment'] as Map<String, dynamic>;
      expect(ship['masterShipmentId'], 'ship-1');
      expect(ship.containsKey('amount'), isFalse);
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