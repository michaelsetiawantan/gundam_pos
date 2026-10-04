import 'package:flutter/material.dart';
import 'package:gundam_pos/logic/money.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gundam_pos/models/config_models.dart';
import 'package:gundam_pos/state/app_session.dart';
import 'package:gundam_pos/state/order_controller.dart';
import 'package:gundam_pos/state/session_store.dart';
import 'package:gundam_pos/ui/open_tables_screen.dart';
import 'package:gundam_pos/ui/theme.dart';

import 'support/fake_backend.dart';

/// A hanging ("temporarily closed") order in the server's list shape: an OPEN
/// order on A1 with two SENT espresso lines — the operator must be able to open
/// it again from Open Tables and continue.
Map<String, dynamic> _hangingOrder() => {
      'id': 'order-hang-1',
      'status': 'OPEN',
      'tableId': 'tbl-a1',
      'tableName': 'A1',
      'openedById': 'u1',
      'openedByName': 'Cashier One',
      'openedAt': DateTime.now().toIso8601String(),
      'lines': [
        {
          'id': 'line-1',
          'orderId': 'order-hang-1',
          'itemId': 'item-espresso',
          'priceLevelIndex': 0,
          'itemName': 'Espresso',
          'qty': 2,
          'unitPrice': 25000,
          'vatMode': 'EXCLUDE',
          'scMode': 'NONE',
          'sentToKitchen': true,
          'mods': <Map<String, dynamic>>[],
        },
      ],
    };

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
  group('resume a hanging order (temporarily closed)', () {
    test('OrderController.resumeFrom adopts the existing bill + its lines', () async {
      final backend = FakeBackend();
      final session = await _readySession(backend);
      final c = OrderController(posApi: session.posApi, tenantId: 't1', config: _northstar(), deviceAssetId: 'device-1');

      expect(c.resumeFrom(_hangingOrder()), isTrue);
      expect(c.orderId, 'order-hang-1');
      expect(c.tableName, 'A1');
      expect(c.openedByName, 'Cashier One');
      expect(c.started, isTrue);
      // The already-sent server lines are folded into the local cart, still sent.
      expect(c.cart.lines, hasLength(1));
      expect(c.cart.itemCount, 2);
      expect(c.cart.total, 50000);
      expect(c.cart.lines.single.sent, isTrue);
      expect(c.hasUnsentLines, isFalse);
      expect(c.canPay, isTrue);
    });

    test('resumeFrom refuses a payload without an order id', () async {
      final backend = FakeBackend();
      final session = await _readySession(backend);
      final c = OrderController(posApi: session.posApi, tenantId: 't1', config: _northstar());
      expect(c.resumeFrom({'tableName': 'A1', 'lines': const []}), isFalse);
      expect(c.orderId, isNull);
      expect(c.started, isFalse);
    });
  });

  testWidgets('open tables: tapping a hanging order continues it in order entry', (tester) async {
    final backend = FakeBackend()..openOrders = [_hangingOrder()];
    final session = await _readySession(backend);
    final config = _northstar();

    await tester.pumpWidget(_wrap(OpenTablesScreen(session: session, config: config)));
    await tester.pumpAndSettle();
    expect(find.text('A1'), findsOneWidget); // the hanging order is listed

    await tester.tap(find.text('A1'));
    await tester.pumpAndSettle();

    // Order entry for the SAME bill: its table, its existing lines, payment unlocked.
    expect(find.text('Beverages'), findsOneWidget);
    expect(find.text('Main Dishes'), findsOneWidget);
    expect(find.text('2 item(s)'), findsOneWidget);
    expect(find.text(moneyLabel(50000, 'Rp')), findsWidgets);
    final pay = tester.widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Payment'));
    expect(pay.onPressed, isNotNull, reason: 'resumed all-sent order can go straight to payment');
  });

  testWidgets('open tables shows a locally-opened (unsynced) order while offline', (tester) async {
    final backend = FakeBackend()..ordersOffline = true;
    final session = await _readySession(backend);
    const cid = 'NSTAR-POS1-20261003-1430-000201';
    await session.enqueuePush('order_create', cid, {
      'orderId': cid, 'tenantId': 't1', 'tableName': 'A1',
      'openedAt': DateTime.now().toIso8601String(),
    });

    await tester.pumpWidget(_wrap(OpenTablesScreen(session: session, config: _northstar())));
    await tester.pumpAndSettle();

    expect(find.text('A1'), findsOneWidget, reason: 'local order must be visible with no server');
    expect(find.textContaining('1 open'), findsOneWidget);
  });

  testWidgets('a synced local order is NOT duplicated in open tables', (tester) async {
    const cid = 'NSTAR-POS1-20261003-1430-000202';
    final backend = FakeBackend()
      ..openOrders = [
        {
          'id': cid, 'status': 'OPEN', 'tableName': 'A1',
          'openedAt': DateTime.now().toIso8601String(), 'lines': const [],
        },
      ];
    final session = await _readySession(backend);
    await session.enqueuePush('order_create', cid, {'orderId': cid, 'tenantId': 't1', 'tableName': 'A1'});

    await tester.pumpWidget(_wrap(OpenTablesScreen(session: session, config: _northstar())));
    await tester.pumpAndSettle();

    expect(find.text('A1'), findsOneWidget, reason: 'server row + same-id local entry dedupe to one');
    expect(find.textContaining('1 open'), findsOneWidget);
  });
}
