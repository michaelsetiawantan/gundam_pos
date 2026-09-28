import 'package:flutter_test/flutter_test.dart';
import 'package:gundam_pos/logic/cart.dart';
import 'package:gundam_pos/logic/money.dart' as money;
import 'package:gundam_pos/models/config_models.dart';
import 'package:gundam_pos/state/payment_controller.dart';

import 'support/fake_backend.dart';

// Integration: the tablet reads the REAL config keys the server ships
// (MASTER.discounts / MASTER.vouchers) and applies/clears pricing through
// POST /api/pos/orders/[id]/pricing (tablet proposes, server decides).

Map<String, dynamic> _discountJson({
  required String id,
  String name = 'Disc',
  String kind = 'FIXED',
  num value = 300,
  List<Map<String, dynamic>> tags = const [],
}) =>
    {
      'id': id,
      'tenantId': 't1',
      'name': name,
      'kind': kind,
      'value': '$value',
      'target': 'WHOLE_BILL',
      'expiresAt': null,
      'active': true,
      'categoryTags': tags,
    };

Map<String, dynamic> _voucherJson({
  required String id,
  String name = 'Vouch',
  String kind = 'FIXED',
  num value = 10000,
  int qtyUse = 0,
  int usedCount = 0,
  List<Map<String, dynamic>> tags = const [],
}) =>
    {
      'id': id,
      'tenantId': 't1',
      'name': name,
      'kind': kind,
      'value': '$value',
      'expiresAt': null,
      'qtyUse': qtyUse,
      'usedCount': usedCount,
      'active': true,
      'categoryTags': tags,
    };

Map<String, dynamic> _tag(String categoryId) => {'categoryId': categoryId, 'includesChildren': true};

TenantConfig _config({
  List<Map<String, dynamic>> discounts = const [],
  List<Map<String, dynamic>> vouchers = const [],
}) {
  final master = Map<String, dynamic>.from(FakeBackend.northstarMaster());
  master['discounts'] = discounts;
  master['vouchers'] = vouchers;
  return TenantConfig.fromSyncPayloads(master, FakeBackend.northstarOutlet());
}

Cart _espressoCart() {
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

final _disc = _discountJson(id: 'd-fixed', value: 300, tags: [_tag('cat-bev')]);
final _vouch = _voucherJson(id: 'v-fixed', value: 10000, tags: [_tag('cat-bev')]);

PaymentController _ctrl(FakeBackend backend, TenantConfig config, Cart cart) => PaymentController(
      posApi: backend.createSession().posApi,
      tenantId: 't1',
      config: config,
      orderId: 'order-1',
      tableName: 'A1',
      cart: cart,
      deviceAssetId: 'device-1',
      shortcode: 'NSTAR-POS1',
    );

void main() {
  group('config keys (real server MASTER keys)', () {
    test('parses discounts and vouchers from MASTER with real key names', () {
      final config = _config(discounts: [_disc], vouchers: [_vouch]);
      expect(config.discounts.map((d) => d.id), ['d-fixed']);
      expect(config.discounts.single.value, 300);
      expect(config.discounts.single.categoryTags.single.categoryId, 'cat-bev');
      expect(config.vouchers.map((v) => v.id), ['v-fixed']);
      expect(config.vouchers.single.value, 10000);
    });

    test('missing keys → empty lists (tolerant, never throws)', () {
      final master = Map<String, dynamic>.from(FakeBackend.northstarMaster());
      master.remove('discounts');
      master.remove('vouchers');
      final config = TenantConfig.fromSyncPayloads(master, FakeBackend.northstarOutlet());
      expect(config.discounts, isEmpty);
      expect(config.vouchers, isEmpty);
    });
  });

  group('apply / clear through the server', () {
    test('successful apply round-trip: tablet proposes, server confirms, payable mirrors', () async {
      final backend = FakeBackend();
      final config = _config(discounts: [_disc]);
      final c = _ctrl(backend, config, _espressoCart());

      expect(await c.applyDiscount(c.availableDiscounts.single), isTrue);
      expect(backend.lastPricingBody, {'discountId': 'd-fixed', 'voucherId': null});
      expect(c.appliedDiscount?.id, 'd-fixed');
      expect(c.discountAmount, 300);
      expect(c.payable, 27450); // 25000 − 300 + 2750 VAT
      expect(c.pricingPending, isFalse);
    });

    test('clearing sends null ids and restores the original payable', () async {
      final backend = FakeBackend();
      final config = _config(discounts: [_disc]);
      final c = _ctrl(backend, config, _espressoCart());

      expect(await c.applyDiscount(c.availableDiscounts.single), isTrue);
      expect(c.payable, 27450);
      expect(await c.cancelPricing(), isTrue);
      expect(backend.lastPricingBody, {'discountId': null, 'voucherId': null});
      expect(c.appliedDiscount, isNull);
      expect(c.discountAmount, 0);
      expect(c.payable, 28000);
    });

    test('pending approval: bill shows awaiting approval, no local discount applied', () async {
      final backend = FakeBackend()..pricingPending = true;
      final config = _config(discounts: [_disc]);
      final c = _ctrl(backend, config, _espressoCart());

      expect(await c.applyDiscount(c.availableDiscounts.single), isTrue);
      expect(c.pricingPending, isTrue);
      expect(c.appliedDiscount, isNull);
      expect(c.appliedVoucher, isNull);
      expect(c.discountAmount, 0);
      expect(c.payable, 28000); // untouched — awaiting approval
    });
  });

  group('server error codes surface readable messages', () {
    const cases = <String, String>{
      'discount_expired': 'expired',
      'voucher_expired': 'expired',
      'discount_inactive': 'no longer active',
      'voucher_inactive': 'no longer active',
      'voucher_exhausted': 'no uses left',
      'discount_not_eligible': 'does not apply',
      'voucher_not_eligible': 'does not apply',
      'discount_and_voucher_mutually_exclusive': 'only one discount OR one voucher',
      'discount_not_found': 'no longer available',
      'voucher_not_found': 'no longer available',
      'order_closed': 'already closed',
    };

    for (final entry in cases.entries) {
      test('${entry.key} → readable message', () async {
        final backend = FakeBackend()..pricingError = entry.key;
        final config = _config(discounts: [_disc]);
        final c = _ctrl(backend, config, _espressoCart());

        expect(await c.applyDiscount(c.availableDiscounts.single), isFalse);
        expect(c.error, isNotNull);
        expect(c.error, contains(entry.value));
        expect(c.error, isNot(contains(entry.key)), reason: 'raw code must be translated');
        expect(c.appliedDiscount, isNull);
        expect(c.payable, 28000);
      });
    }
  });

  group('settle no longer carries an authoritative discount amount', () {
    test('settle body omits discountAmount (server re-derives from stored ids)', () async {
      final backend = FakeBackend();
      final config = _config(discounts: [_disc]);
      final c = _ctrl(backend, config, _espressoCart());

      expect(await c.applyDiscount(c.availableDiscounts.single), isTrue);
      final cash = config.paymentMethods.firstWhere((m) => m.type == money.PayType.cash);
      c.addPayment(cash, c.payable);
      expect(await c.settle(), isTrue);

      final sent = backend.lastSettleBody!;
      expect(sent.containsKey('discountAmount'), isFalse);
      expect(sent.containsKey('discountId'), isFalse);
      expect(sent.containsKey('voucherId'), isFalse);
    });
  });
}