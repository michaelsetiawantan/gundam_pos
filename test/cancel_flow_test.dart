import 'package:flutter_test/flutter_test.dart';
import 'package:gundam_pos/models/config_models.dart';
import 'package:gundam_pos/state/app_session.dart';
import 'package:gundam_pos/state/order_controller.dart';
import 'package:gundam_pos/state/session_store.dart';

import 'support/fake_backend.dart';

/// Two field reports: a cancelled item stayed on screen until a manual refresh,
/// and cancelling an emptied order demanded a reason it could not supply.
void main() {
  TenantConfig config() =>
      TenantConfig.fromSyncPayloads(FakeBackend.northstarMaster(), FakeBackend.northstarOutlet());

  Future<(FakeBackend, AppSession, OrderController)> ready() async {
    final backend = FakeBackend();
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
    final c = OrderController(posApi: session.posApi, tenantId: 't1', config: config(), deviceAssetId: 'device-1');
    await c.startOrder(tableId: 'tbl-a1', tableName: 'A1');
    return (backend, session, c);
  }

  Map<String, dynamic> sentOrder() => {
        'id': 'order-1',
        'tableName': 'A1',
        'openedAt': DateTime.now().toIso8601String(),
        'lines': [
          {
            'id': 'line-sent', 'itemId': 'item-espresso', 'itemName': 'Espresso',
            'qty': 2, 'priceLevelIndex': 0, 'unitPrice': 25000, 'sentToKitchen': true,
          },
        ],
      };

  test('a cancelled item disappears at once — no manual refresh', () async {
    final (backend, _, c) = await ready();
    backend.openOrders = [sentOrder()];
    expect(await c.reloadFromServer(), isTrue);
    expect(c.cart.lines, hasLength(1));

    final line = c.cart.lines.single;
    final r = await c.cancelLine(line, qty: 2, reason: 'wrong item');

    expect(r, 'canceled');
    expect(backend.lastCancelBody!['lineId'], 'line-sent',
        reason: 'the cancel must name the server line');
    // THE FIX: the tablet pulled the authoritative cart itself.
    expect(c.cart.lines, isEmpty, reason: 'the cancelled line must vanish without a refresh');
  });

  test('a pending cancel keeps the item (a rejection must not drop it)', () async {
    final (backend, _, c) = await ready();
    backend.cancelPending = true;
    backend.openOrders = [sentOrder()];
    await c.reloadFromServer();

    final r = await c.cancelLine(c.cart.lines.single, qty: 1, reason: 'wrong item');

    expect(r, 'pending');
    expect(c.cart.lines, hasLength(1), reason: 'still on the bill until an approver decides');
  });

  test('an emptied order cancels without inventing a reason — and retries if asked', () async {
    final (backend, _, c) = await ready();

    // The server still holds sent lines the cart no longer shows → it refuses
    // the empty reason ONCE, and the screen must be able to react to the code.
    backend.cancelNeedsReason = true;
    final refused = await c.cancelOrder('');
    expect(refused, isNull);
    expect(c.lastErrorCode, 'reason_required', reason: 'the screen needs the code to ask for a reason');

    // …and the very next attempt with a reason goes through.
    expect(await c.cancelOrder('guest left'), 'canceled');
    expect(c.lastErrorCode, isNull);
  });

  test('the empty-cart cancel sends an empty reason (the server decides)', () async {
    final (backend, _, c) = await ready();
    expect(c.cart.isEmpty, isTrue);

    expect(await c.cancelOrder(''), 'canceled');
    expect(backend.lastCancelBody!['reason'], '');
    expect(backend.lastCancelBody!.containsKey('lineId'), isFalse);
  });
}
