import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gundam_pos/data/config_cache.dart';
import 'package:gundam_pos/models/config_models.dart';
import 'package:gundam_pos/state/app_session.dart';
import 'package:gundam_pos/state/order_controller.dart';
import 'package:gundam_pos/state/session_store.dart';
import 'package:gundam_pos/ui/open_tables_screen.dart';
import 'package:gundam_pos/ui/theme.dart';

import 'support/fake_backend.dart';

/// Two field reports: Open Tables blanked itself while offline (it must work
/// without internet), and a cancelled table kept showing until a sync.
void main() {
  TenantConfig config() =>
      TenantConfig.fromSyncPayloads(FakeBackend.northstarMaster(), FakeBackend.northstarOutlet());

  Future<AppSession> ready(FakeBackend backend) async {
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

  testWidgets('OFFLINE: the last-known list is painted, never a blank screen', (tester) async {
    final backend = FakeBackend()..ordersOffline = true; // no server reachable
    final session = await ready(backend);
    final cached = [
      {'id': 'order-1', 'tableName': 'A1', 'status': 'OPEN', 'openedAt': DateTime.now().toIso8601String(), 'lines': <Object>[]},
    ];

    await tester.pumpWidget(MaterialApp(
      theme: PosTheme.theme(),
      // The screen is handed what it had from last time (production reads this
      // from the on-disk cache) and the unreachable server must NOT blank it.
      home: OpenTablesScreen(session: session, config: config(), initialOrders: cached),
    ));
    await tester.pumpAndSettle();

    expect(find.text('A1'), findsOneWidget, reason: 'the cached table must stay visible offline');
  });

  test('the list cache round-trips on disk (offline-first source)', () async {
    final backend = FakeBackend();
    final session = await ready(backend);
    final dir = Directory.systemTemp.createTempSync('tables-cache');
    addTearDown(() => dir.deleteSync(recursive: true));
    session.attachConfigCache(ConfigCache(dir));

    final rows = [
      {'id': 'order-9', 'tableName': 'B2', 'status': 'OPEN', 'openedAt': DateTime.now().toIso8601String(), 'lines': <Object>[]},
    ];
    await session.cacheOpenOrders(rows);
    final back = await session.cachedOpenOrders();
    expect(back, isNotNull);
    expect(back!.single['tableName'], 'B2');
  });

  test('cancelling an order drops its queued create (no ghost table)', () async {
    final backend = FakeBackend();
    final session = await ready(backend);
    final c = OrderController(
      posApi: session.posApi, tenantId: 't1', config: config(), deviceAssetId: 'device-1',
      pushStore: session.pushStore,
    );
    await c.startOrder(tableId: 'tbl-a1', tableName: 'A1');
    final id = c.orderId!;
    // The order was created OFFLINE: its create is still queued, which is what
    // Open Tables surfaces as a local row.
    await session.pushStore.enqueue('order_create', id, {'orderId': id, 'tableName': 'A1'});
    expect((await session.pushStore.pending()).any((i) => i['id'] == id), isTrue);

    expect(await c.cancelOrder(''), 'canceled');

    expect((await session.pushStore.pending()).any((i) => i['id'] == id), isFalse,
        reason: 'the closed order must not resurrect in Open Tables from the outbox');
  });
}
