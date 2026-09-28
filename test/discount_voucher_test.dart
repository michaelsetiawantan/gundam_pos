import 'package:flutter_test/flutter_test.dart';
import 'package:gundam_pos/logic/cart.dart';
import 'package:gundam_pos/logic/discount_voucher.dart' as dv;
import 'package:gundam_pos/logic/money.dart' as money;
import 'package:gundam_pos/models/config_models.dart';
import 'package:gundam_pos/state/payment_controller.dart';

import 'support/fake_backend.dart';

// Northstar espresso: 25000, VAT EXCLUDE 11% → 2750; mode UP rounds 27750→28000.
// Adding a 300 fixed discount: 25000−300+2750 = 27450 → rem 450 → no round-up.

TenantConfig _config({
  List<Map<String, dynamic>> discounts = const [],
  List<Map<String, dynamic>> vouchers = const [],
}) {
  final master = Map<String, dynamic>.from(FakeBackend.northstarMaster());
  if (discounts.isNotEmpty) master['discounts'] = discounts;
  if (vouchers.isNotEmpty) master['vouchers'] = vouchers;
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

PaymentController _ctrl(Cart cart, TenantConfig config) => PaymentController(
      posApi: FakeBackend().createSession().posApi,
      tenantId: 't1',
      config: config,
      orderId: 'order-1',
      tableName: 'A1',
      cart: cart,
      deviceAssetId: 'device-1',
      shortcode: 'NSTAR-POS1',
    );

Map<String, dynamic> _discountJson({
  required String id,
  String name = 'Disc',
  String kind = 'FIXED',
  num value = 300,
  String? expiresAt,
  bool active = true,
  List<Map<String, dynamic>> tags = const [],
}) =>
    {
      'id': id,
      'name': name,
      'kind': kind,
      'value': '$value',
      'target': 'WHOLE_BILL',
      'expiresAt': expiresAt,
      'active': active,
      'categoryTags': tags,
    };

Map<String, dynamic> _voucherJson({
  required String id,
  String name = 'Vouch',
  String kind = 'FIXED',
  num value = 10000,
  int qtyUse = 0,
  int usedCount = 0,
  String? expiresAt,
  bool active = true,
  List<Map<String, dynamic>> tags = const [],
}) =>
    {
      'id': id,
      'name': name,
      'kind': kind,
      'value': '$value',
      'qtyUse': qtyUse,
      'usedCount': usedCount,
      'expiresAt': expiresAt,
      'active': active,
      'categoryTags': tags,
    };

Map<String, dynamic> _tag(String categoryId, {bool includesChildren = true}) =>
    {'categoryId': categoryId, 'includesChildren': includesChildren};

// Parent (Beverages) → child (Coffee); a line on Coffee must be covered by a
// Beverages tag (inheritance), but a Coffee-only tag must not cover Beverages.
final _parentById = <String, String?>{'cat-bev': null, 'cat-bev-coffee': 'cat-bev'};

void main() {
  group('discount/voucher eligibility (pure)', () {
    test('parent-category tag inherits to descendants; untagged dormant', () {
      final parentTag = dv.DiscountMaster.fromJson(_discountJson(id: 'd-parent', tags: [_tag('cat-bev')]));
      final childTag = dv.DiscountMaster.fromJson(_discountJson(id: 'd-child', tags: [_tag('cat-bev-coffee', includesChildren: false)]));
      final untagged = dv.DiscountMaster.fromJson(_discountJson(id: 'd-none'));

      final eligible = dv.eligibleDiscounts(
        discounts: [parentTag, childTag, untagged],
        lineCategoryIds: const ['cat-bev-coffee'],
        parentById: _parentById,
      ).map((d) => d.id).toList();

      expect(eligible, contains('d-parent'), reason: 'parent tag covers descendant line category');
      expect(eligible, contains('d-child'), reason: 'exact non-inheriting tag matches its own category');
      expect(eligible, isNot(contains('d-none')), reason: 'untagged master is dormant');
    });

    test('non-inheriting tag does NOT cover a parent line category', () {
      final childTag = dv.DiscountMaster.fromJson(_discountJson(id: 'd-child', tags: [_tag('cat-bev-coffee', includesChildren: false)]));
      final eligible = dv.eligibleDiscounts(
        discounts: [childTag],
        lineCategoryIds: const ['cat-bev'],
        parentById: _parentById,
      );
      expect(eligible, isEmpty);
    });

    test('expired entries are not offered; unexpired are', () {
      final past = DateTime(2020, 1, 1);
      final future = DateTime(2999, 1, 1);
      final expired = dv.DiscountMaster.fromJson(_discountJson(id: 'd-old', expiresAt: past.toIso8601String(), tags: [_tag('cat-bev')]));
      final live = dv.DiscountMaster.fromJson(_discountJson(id: 'd-live', expiresAt: future.toIso8601String(), tags: [_tag('cat-bev')]));
      final eligible = dv.eligibleDiscounts(
        discounts: [expired, live],
        lineCategoryIds: const ['cat-bev'],
        parentById: _parentById,
      ).map((d) => d.id).toList();
      expect(eligible, ['d-live']);
    });

    test('percentage vs fixed amounts, clamped to subtotal', () {
      final pct = dv.DiscountMaster.fromJson(_discountJson(id: 'p', kind: 'PERCENTAGE', value: 10));
      final fixed = dv.DiscountMaster.fromJson(_discountJson(id: 'f', kind: 'FIXED', value: 5000));
      final huge = dv.DiscountMaster.fromJson(_discountJson(id: 'h', kind: 'FIXED', value: 999999));
      expect(dv.pricingAmount(pct, 25000), 2500);
      expect(dv.pricingAmount(fixed, 25000), 5000);
      expect(dv.pricingAmount(huge, 25000), 25000);
    });

    test('quota-exhausted vouchers not offered; 0 quota = unlimited', () {
      final exhausted = dv.VoucherMaster.fromJson(_voucherJson(id: 'v-out', qtyUse: 5, usedCount: 5, tags: [_tag('cat-bev')]));
      final available = dv.VoucherMaster.fromJson(_voucherJson(id: 'v-in', qtyUse: 5, usedCount: 4, tags: [_tag('cat-bev')]));
      final unlimited = dv.VoucherMaster.fromJson(_voucherJson(id: 'v-any', qtyUse: 0, tags: [_tag('cat-bev')]));
      final eligible = dv.eligibleVouchers(
        vouchers: [exhausted, available, unlimited],
        lineCategoryIds: const ['cat-bev'],
        parentById: _parentById,
      ).map((v) => v.id).toList();
      expect(eligible, containsAll(['v-in', 'v-any']));
      expect(eligible, isNot(contains('v-out')));
    });

    test('mutual exclusion: applying one clears the other both ways', () {
      final d = dv.DiscountMaster.fromJson(_discountJson(id: 'd'));
      final v = dv.VoucherMaster.fromJson(_voucherJson(id: 'v'));
      final withVoucher = dv.PricingSelection.none.applyDiscount(d).applyVoucher(v);
      expect(withVoucher.voucher?.id, 'v');
      expect(withVoucher.discount, isNull);
      final withDiscount = dv.PricingSelection.none.applyVoucher(v).applyDiscount(d);
      expect(withDiscount.discount?.id, 'd');
      expect(withDiscount.voucher, isNull);
    });
  });

  group('PaymentController discount/voucher money-flow', () {
    test('baseline payable unchanged when nothing applied', () {
      final c = _ctrl(_espressoCart(), _config());
      expect(c.payable, 28000);
      expect(c.availableDiscounts, isEmpty);
      expect(c.availableVouchers, isEmpty);
    });

    test('discount applies before tax and changes the rounding delta', () {
      final config = _config(discounts: [_discountJson(id: 'd-fixed', value: 300, tags: [_tag('cat-bev')])]);
      final c = _ctrl(_espressoCart(), config);
      expect(c.availableDiscounts.map((d) => d.id), ['d-fixed']);

      c.applyDiscount(c.availableDiscounts.single);
      expect(c.discountAmount, 300);
      // 25000 − 300 + 2750 VAT = 27450; rem 450 < 500 → no round-up (delta 0).
      expect(c.payable, 27450);
    });

    test('percentage discount applies to the pre-tax subtotal', () {
      final config = _config(discounts: [_discountJson(id: 'd-pct', kind: 'PERCENTAGE', value: 10, tags: [_tag('cat-bev')])]);
      final c = _ctrl(_espressoCart(), config);
      c.applyDiscount(c.availableDiscounts.single);
      expect(c.discountAmount, 2500);
      // 25000 − 2500 + 2750 = 25250; rem 250 < 500 → no round-up.
      expect(c.payable, 25250);
    });

    test('applying a voucher replaces the discount (one-per-bill)', () {
      final config = _config(
        discounts: [_discountJson(id: 'd-fixed', value: 300, tags: [_tag('cat-bev')])],
        vouchers: [_voucherJson(id: 'v-fixed', value: 10000, tags: [_tag('cat-bev')])],
      );
      final c = _ctrl(_espressoCart(), config);
      c.applyDiscount(c.availableDiscounts.single);
      expect(c.payable, 27450);
      c.applyVoucher(c.availableVouchers.single);
      expect(c.appliedDiscount, isNull);
      expect(c.appliedVoucher?.id, 'v-fixed');
      // 25000 − 10000 + 2750 = 17750 → rem 750 ≥ 500 → 18000.
      expect(c.payable, 18000);
    });

    test('cancel restores the original payable', () {
      final config = _config(discounts: [_discountJson(id: 'd-fixed', value: 300, tags: [_tag('cat-bev')])]);
      final c = _ctrl(_espressoCart(), config);
      c.applyDiscount(c.availableDiscounts.single);
      expect(c.payable, 27450);
      c.cancelPricing();
      expect(c.appliedDiscount, isNull);
      expect(c.appliedVoucher, isNull);
      expect(c.discountAmount, 0);
      expect(c.payable, 28000);
    });

    test('end-to-end: discounted payable covers the settled bill', () async {
      final config = _config(discounts: [_discountJson(id: 'd-fixed', value: 300, tags: [_tag('cat-bev')])]);
      final c = _ctrl(_espressoCart(), config);
      final cash = config.paymentMethods.firstWhere((m) => m.type == money.PayType.cash);
      c.applyDiscount(c.availableDiscounts.single);
      c.addPayment(cash, c.payable); // exactly the discounted payable
      expect(c.covered, isTrue);
      expect(c.payable, 27450);
      expect(await c.settle(), isTrue);
      expect(c.settled, isNotNull);
    });
  });
}