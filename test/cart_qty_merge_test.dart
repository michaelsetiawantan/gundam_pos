// Regression: adding the SAME product repeatedly must (a) merge into ONE cart
// row whose qty sums, (b) push that qty to the server — without asking to sync
// and without reverting to the first input qty — and (c) send the FULL qty on
// SEND CART. The server merges by `clientLineKey` (same key → qty summed), so
// the tablet must re-send the key and, for an already-adopted line, only the
// DELTA.
import 'package:flutter_test/flutter_test.dart';
import 'package:gundam_pos/models/config_models.dart';
import 'package:gundam_pos/state/app_session.dart';
import 'package:gundam_pos/state/order_controller.dart';
import 'package:gundam_pos/state/session_store.dart';

import 'support/fake_backend.dart';

TenantConfig _northstar() =>
    TenantConfig.fromSyncPayloads(FakeBackend.northstarMaster(), FakeBackend.northstarOutlet());

Future<AppSession> _session(FakeBackend backend) async {
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

Future<(FakeBackend, OrderController)> _order() async {
  final backend = FakeBackend();
  final session = await _session(backend);
  final c = OrderController(
    posApi: session.posApi,
    tenantId: 't1',
    config: _northstar(),
    deviceAssetId: 'device-1',
    pushStore: session.pushStore,
  );
  await c.startOrder(tableId: 'tbl-a1', tableName: 'A1');
  return (backend, c);
}

void main() {
  test('adding the same item twice merges into one row and pushes the qty', () async {
    final (backend, c) = await _order();
    final item = _northstar().itemById('item-espresso')!;

    await c.addItem(item);
    await c.addItem(item);

    // ONE cart row, qty summed, NOT stuck pending (no "sync" prompt).
    expect(c.cart.lines, hasLength(1));
    expect(c.cart.lines.single.qty, 2);
    expect(c.cart.lines.single.pending, isFalse);
    expect(c.hasUnsyncedLines, isFalse);

    // The server got the client line key on BOTH adds (so it merges by key),
    // and only the DELTA on the second (the server sums it to 2).
    expect(backend.addedLineBodies, hasLength(2));
    final first = backend.addedLineBodies[0];
    final second = backend.addedLineBodies[1];
    expect(first['clientLineKey'], isNotNull);
    expect(second['clientLineKey'], first['clientLineKey']);
    expect(first['qty'], 1);
    expect(second['qty'], 1, reason: 'second add is a delta of 1, server sums to 2');
  });

  test('offline re-adds accumulate into ONE queued add carrying the TOTAL qty', () async {
    final (backend, c) = await _order();
    final item = _northstar().itemById('item-espresso')!;

    backend.addLineOffline = true;
    await c.addItem(item);
    await c.addItem(item);
    await c.addItem(item);

    // Still one row, qty 3, and exactly ONE queued line (upsert, never append).
    expect(c.cart.lines, hasLength(1));
    expect(c.cart.lines.single.qty, 3);
    expect(await c.pushStorePendingLines(), 1);

    // Network returns → the single queued add carries the TOTAL (3), so no units
    // are lost and the server never sees three separate lines.
    backend.addLineOffline = false;
    await c.flushPendingLines();
    expect(backend.addedLineBodies, hasLength(1));
    expect(backend.addedLineBodies.single['qty'], 3);
    expect(backend.addedLineBodies.single['clientLineKey'], isNotNull);
    expect(c.cart.lines.single.pending, isFalse);
  });
}

/// Count queued `order_line` entries for the controller's order (test helper).
extension on OrderController {
  Future<int> pushStorePendingLines() async {
    final store = pushStore;
    if (store == null) return 0;
    final items = await store.pending();
    return items.where((i) => i['type'] == 'order_line').length;
  }
}
