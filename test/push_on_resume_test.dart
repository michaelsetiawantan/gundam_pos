import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gundam_pos/app.dart';
import 'package:gundam_pos/state/session_store.dart';

import 'support/fake_backend.dart';

/// Item 1 — the queued outbox is pushed automatically when the app returns to
/// the foreground, and ONLY then: never when logged out, busy, or empty. Every
/// assertion is falsifiable — removing the observer / guard makes it fail.

const String _key = 'NSTAR-POS1-20261004-12:00-0000007';

Map<String, dynamic> _settlePayload() => {
      'clientSettlementKey': _key,
      'orderId': 'order-1',
      'receiptId': _key,
      'paidAt': '2026-10-04T12:00:00.000Z',
      'totals': {'total': 28000},
      'lines': <Map<String, dynamic>>[],
    };

Future<PosContext> _readyContext() async {
  final store = InMemorySessionStore();
  await store.save(const PosContext()
      .withRedeem({'deviceToken': 'dev', 'groupId': 'g1', 'tenantId': 't1', 'shortcode': 'NSTAR-POS1'})
      .withSession({
        'sessionId': 'sess-1',
        'user': {'id': 'u1', 'fullName': 'C1'},
        'outlet': {'id': 't1', 'name': 'Northstar'},
      })
      .copyWith(deviceId: 'device-1'));
  return store.load();
}

int _settlePosts(FakeBackend b) =>
    b.requested.where((u) => u.path.endsWith('settle-deferred')).length;

void main() {
  testWidgets('resume with a queued settlement pushes it (observer fires)', (tester) async {
    final backend = FakeBackend();
    final store = InMemorySessionStore();
    await store.save(await _readyContext());
    final session = backend.createSession(store: store);
    await session.init();
    await session.enqueuePush('order_settle', _key, _settlePayload());

    await tester.pumpWidget(PosApp(sessionProvider: () => session));
    await tester.pumpAndSettle();
    expect(_settlePosts(backend), 0, reason: 'nothing is pushed just by opening the app');

    // The tablet comes back to the foreground.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    expect(_settlePosts(backend), 1, reason: 'the queued settlement is pushed on resume');
  });

  testWidgets('resume with an EMPTY queue makes no request', (tester) async {
    final backend = FakeBackend();
    final store = InMemorySessionStore();
    await store.save(await _readyContext());
    final session = backend.createSession(store: store);
    await session.init();

    await tester.pumpWidget(PosApp(sessionProvider: () => session));
    await tester.pumpAndSettle();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    expect(_settlePosts(backend), 0, reason: 'no pointless traffic when there is nothing to push');
  });

  test('pushQueuedOnResume never pushes while logged out (not ready)', () async {
    final backend = FakeBackend();
    // No session context → stage = needActivation.
    final session = backend.createSession();
    await session.init();
    await session.enqueuePush('order_settle', _key, _settlePayload());

    await session.pushQueuedOnResume();

    expect(_settlePosts(backend), 0, reason: 'a logged-out tablet must not push');
    expect(await session.pushStore.pending(), hasLength(1), reason: 'the row is untouched');
  });

  test('pushQueuedOnResume pushes while READY with a queued item', () async {
    final backend = FakeBackend();
    final store = InMemorySessionStore();
    await store.save(await _readyContext());
    final session = backend.createSession(store: store);
    await session.init();
    await session.enqueuePush('order_settle', _key, _settlePayload());

    await session.pushQueuedOnResume();

    expect(_settlePosts(backend), 1);
    expect(await session.pushStore.pending(), isEmpty);
  });
}
