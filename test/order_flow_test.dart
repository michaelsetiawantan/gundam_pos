import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gundam_pos/logic/cart.dart';
import 'package:gundam_pos/models/config_models.dart';
import 'package:gundam_pos/state/app_session.dart';
import 'package:gundam_pos/state/order_controller.dart';
import 'package:gundam_pos/state/session_store.dart';
import 'package:gundam_pos/ui/open_tables_screen.dart';
import 'package:gundam_pos/ui/order_entry_screen.dart';
import 'package:gundam_pos/ui/theme.dart';

import 'support/fake_backend.dart';

TenantConfig _northstar() =>
    TenantConfig.fromSyncPayloads(FakeBackend.northstarMaster(), FakeBackend.northstarOutlet());

Widget _wrap(Widget child) => MaterialApp(theme: PosTheme.theme(), home: child);

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

void main() {
  group('OrderController flow (server-backed)', () {
    test('start → add priced lines → send-cart batch', () async {
      final backend = FakeBackend();
      final session = await _readySession(backend);
      final config = _northstar();
      final c = OrderController(posApi: session.posApi, tenantId: 't1', config: config, deviceAssetId: 'device-1');

      expect(await c.startOrder(tableId: 'tbl-a1', tableName: 'A1', guest: {'pax': 2}), isTrue);
      expect(c.started, isTrue);
      expect(c.orderId, 'order-1');

      final espresso = config.itemById('item-espresso')!;
      final nasi = config.itemById('item-nasi')!;
      final l1 = await c.addItem(espresso, levelIndex: 1, qty: 2);
      final l2 = await c.addItem(nasi, mods: [CartModifier(modifierId: 'mod-egg', name: 'Add egg', price: 5000)]);
      expect(l1, isNotNull);
      expect(l2, isNotNull);
      expect(c.cart.lines, hasLength(2));
      // 2× Double espresso (32000) + nasi (45000) + add egg (5000)
      expect(c.cart.total, 2 * 32000 + (45000 + 5000));
      expect(c.error, isNull);

      expect(await c.sendCart(), isTrue);
      expect(c.lastBatchLabel, 'A');
      expect(c.cart.lines.every((l) => l.sent), isTrue, reason: 'send marks lines sent → never reprinted');
      expect(c.captainBatchCount, 1);
    });

    test('orderTree produces drillable groups from Northstar layout', () {
      final tree = _northstar().orderTree();
      expect(tree.map((n) => n.name), containsAll(['Beverages', 'Main Dishes']));
      expect(tree.first.itemIds, contains('item-espresso'));
    });

    test('pay gate: unsent lines block payment, sending unlocks, sent lines untouched', () async {
      final backend = FakeBackend();
      final session = await _readySession(backend);
      final config = _northstar();
      final c = OrderController(posApi: session.posApi, tenantId: 't1', config: config, deviceAssetId: 'device-1');
      await c.startOrder(tableId: 'tbl-a1', tableName: 'A1');
      await c.addItem(config.itemById('item-espresso')!);

      // Fresh line → payment blocked.
      expect(c.hasUnsentLines, isTrue);
      expect(c.canPay, isFalse);

      expect(await c.sendCart(), isTrue);
      expect(c.hasUnsentLines, isFalse);
      expect(c.canPay, isTrue);

      // A new line after the batch → blocked again; the SENT line is not merged
      // into nor re-sent (already-sent lines are never reprinted).
      await c.addItem(config.itemById('item-espresso')!);
      expect(c.cart.lines, hasLength(2));
      expect(c.cart.lines.first.sent, isTrue);
      expect(c.cart.lines.first.qty, 1);
      expect(c.cart.lines.last.sent, isFalse);
      expect(c.canPay, isFalse);

      expect(await c.sendCart(), isTrue);
      expect(c.captainBatchCount, 2, reason: 'second send is a fresh batch, not a reprint');
      expect(c.cart.lines.every((l) => l.sent), isTrue);
      expect(c.canPay, isTrue);
    });
  });

  testWidgets('order entry disables payment and offers Send cart until lines are sent', (tester) async {
    final backend = FakeBackend();
    final session = await _readySession(backend);
    final config = _northstar();
    final c = OrderController(posApi: session.posApi, tenantId: 't1', config: config, deviceAssetId: 'device-1');
    await c.startOrder(tableId: 'tbl-a1', tableName: 'A1');
    await c.addItem(config.itemById('item-espresso')!);

    await tester.pumpWidget(_wrap(OrderEntryScreen(session: session, controller: c)));
    await tester.pumpAndSettle();

    OutlinedButton payButton() =>
        tester.widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Payment'));

    expect(payButton().onPressed, isNull, reason: 'unsent line → payment disabled');
    expect(find.byKey(const Key('send-gate-reason')), findsOneWidget);
    expect(find.text('Send cart'), findsOneWidget);

    await tester.tap(find.text('Send cart'));
    await tester.pumpAndSettle();

    expect(payButton().onPressed, isNotNull, reason: 'all lines sent → payment unlocks');
    expect(find.byKey(const Key('send-gate-reason')), findsNothing);
    expect(find.text('Send cart'), findsNothing);
    expect(c.canPay, isTrue);
  });

  testWidgets('open tables → new order → order entry adds item', (tester) async {
    final backend = FakeBackend();
    final session = await _readySession(backend);
    final config = _northstar();
    await tester.pumpWidget(_wrap(OpenTablesScreen(session: session, config: config)));
    await tester.pumpAndSettle();
    expect(find.textContaining('No open tables'), findsWidgets);

    await tester.tap(find.text('New order'));
    await tester.pumpAndSettle();
    expect(find.text('Table'), findsOneWidget);

    await tester.tap(find.text('A1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start order'));
    await tester.pumpAndSettle();

    // Order entry shows the menu forest root groups.
    expect(find.text('Beverages'), findsOneWidget);
    expect(find.text('Main Dishes'), findsOneWidget);

    // Drill into Beverages → Espresso item card.
    await tester.tap(find.text('Beverages'));
    await tester.pumpAndSettle();
    expect(find.text('Espresso'), findsOneWidget);

    // Add espresso → cart bar appears.
    await tester.tap(find.text('Espresso'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Add'));
    await tester.pumpAndSettle();
    expect(find.text('1 item(s)'), findsOneWidget);
    expect(find.textContaining('25000'), findsWidgets); // price on card + cart total
  });
}