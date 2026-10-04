import 'package:flutter/material.dart';
import 'package:gundam_pos/logic/money.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gundam_pos/models/config_models.dart';
import 'package:gundam_pos/state/app_session.dart';
import 'package:gundam_pos/state/order_controller.dart';
import 'package:gundam_pos/state/payment_controller.dart';
import 'package:gundam_pos/state/session_store.dart';
import 'package:gundam_pos/ui/order_entry_screen.dart';
import 'package:gundam_pos/ui/theme.dart';

import 'support/fake_backend.dart';

/// Order-entry UX regressions the operator hit on the tablet:
///   1. a bigger menu tile;
///   2. an added/removed line must show up in the cart AT ONCE — no reopen needed;
///   3. discount/voucher must be reachable from the ORDER flow, not only payment.

Map<String, dynamic> _masterWithPricing() {
  final master = Map<String, dynamic>.from(FakeBackend.northstarMaster());
  master['discounts'] = [
    {
      'id': 'd-fixed',
      'name': 'Happy Hour',
      'kind': 'FIXED',
      'value': '300',
      'target': 'WHOLE_BILL',
      'expiresAt': null,
      'active': true,
      'categoryTags': [
        {'categoryId': 'cat-bev', 'includesChildren': true},
      ],
    },
  ];
  master['vouchers'] = [
    {
      'id': 'v-fixed',
      'name': 'Member Voucher',
      'kind': 'FIXED',
      'value': '10000',
      'expiresAt': null,
      'qtyUse': 0,
      'usedCount': 0,
      'active': true,
      'categoryTags': [
        {'categoryId': 'cat-bev', 'includesChildren': true},
      ],
    },
  ];
  return master;
}

TenantConfig _config() =>
    TenantConfig.fromSyncPayloads(_masterWithPricing(), FakeBackend.northstarOutlet());

Future<AppSession> _readySession(FakeBackend backend) async {
  final store = InMemorySessionStore();
  await store.save(const PosContext()
      .withRedeem({'deviceToken': 'dev', 'groupId': 'g1', 'tenantId': 't1', 'shortcode': 'NSTAR-POS1'})
      .withSession({
        'sessionId': 'sess-1',
        'user': {'id': 'u1', 'fullName': 'C1'},
        'outlet': {'id': 't1', 'name': 'Northstar'},
      })
      .copyWith(deviceId: 'device-1'));
  final session = backend.createSession(store: store);
  await session.init();
  return session;
}

Future<(FakeBackend, AppSession, TenantConfig, OrderController)> _orderWithEspresso() async {
  final backend = FakeBackend();
  final session = await _readySession(backend);
  final config = _config();
  final c = OrderController(posApi: session.posApi, tenantId: 't1', config: config, deviceAssetId: 'device-1');
  await c.startOrder(tableId: 'tbl-a1', tableName: 'A1');
  return (backend, session, config, c);
}

void main() {
  testWidgets('menu tiles are the larger size (tile width drives the columns)', (tester) async {
    final (_, session, _, c) = await _orderWithEspresso();
    await tester.pumpWidget(MaterialApp(theme: PosTheme.theme(), home: OrderEntryScreen(session: session, controller: c)));
    await tester.pumpAndSettle();

    final grid = tester.widget<GridView>(find.byType(GridView));
    final delegate = grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
    expect(delegate.crossAxisCount, lessThanOrEqualTo(9));
    // Roomier than before: taller-than-wide cells so an UPLOADED image is
    // actually visible on the tile (was a near-square 1.15).
    expect(delegate.childAspectRatio, lessThan(1.05));
    expect(delegate.childAspectRatio, greaterThan(0.8));
  });

  testWidgets('removing a line in the cart sheet updates it live — no reopen', (tester) async {
    final (_, session, config, c) = await _orderWithEspresso();
    await c.addItem(config.itemById('item-espresso')!);
    await c.addItem(config.itemById('item-nasi')!);

    await tester.pumpWidget(MaterialApp(theme: PosTheme.theme(), home: OrderEntryScreen(session: session, controller: c)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Cart'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.delete_outline), findsNWidgets(2));
    expect(find.text(moneyLabel(70000, 'Rp')), findsWidgets);

    await tester.tap(find.byIcon(Icons.delete_outline).first);
    await tester.pumpAndSettle();

    // The sheet itself reflects the removal (it listens) — the old bug left two
    // rows and the stale 70000 total until the sheet was closed and reopened.
    expect(c.cart.lines, hasLength(1));
    expect(find.byIcon(Icons.delete_outline), findsOneWidget);
    expect(find.text(moneyLabel(70000, 'Rp')), findsNothing);
    expect(find.text(moneyLabel(45000, 'Rp')), findsWidgets);
  });

  testWidgets('discount is reachable from the order screen and shows on the cart bar', (tester) async {
    final (backend, session, config, c) = await _orderWithEspresso();
    await c.addItem(config.itemById('item-espresso')!);

    await tester.pumpWidget(MaterialApp(theme: PosTheme.theme(), home: OrderEntryScreen(session: session, controller: c)));
    await tester.pumpAndSettle();

    // The discount lives on the order flow — an app-bar action, not payment-only.
    await tester.tap(find.byKey(const Key('order-pricing')));
    await tester.pumpAndSettle();
    expect(find.text('Happy Hour (${moneyLabel(300, 'Rp')})'), findsOneWidget);

    await tester.tap(find.text('Happy Hour (${moneyLabel(300, 'Rp')})'));
    await tester.pumpAndSettle();

    expect(backend.lastPricingBody, {'discountId': 'd-fixed', 'voucherId': null});
    expect(c.pricing!.applied?.name, 'Happy Hour');
    // Applied badge on the cart bar, still on the order screen.
    expect(find.byKey(const Key('cart-pricing')), findsOneWidget);
    expect(find.textContaining('Discount: Happy Hour'), findsWidgets);
  });

  testWidgets('a discount applied during order entry is settled by payment', (tester) async {
    final (_, session, config, c) = await _orderWithEspresso();
    final espresso = config.itemById('item-espresso')!;
    await c.addItem(espresso);
    expect(await c.pricing!.applyDiscount(c.pricing!.availableDiscounts.single), isTrue);

    // The payment screen shares the order's pricing controller → same payable
    // the server will compute (25000 − 300 + 11% VAT = 27450).
    final pc = PaymentController(
      posApi: session.posApi,
      tenantId: 't1',
      config: config,
      orderId: c.orderId!,
      tableName: 'A1',
      cart: c.cart,
      deviceAssetId: 'device-1',
      shortcode: 'NSTAR-POS1',
      pricingController: c.pricing,
    );
    expect(pc.appliedDiscount?.id, 'd-fixed');
    expect(pc.discountAmount, 300);
    expect(pc.payable, 27450);
  });
}
