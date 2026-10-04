import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gundam_pos/data/local_db.dart';
import 'package:gundam_pos/data/pos_store.dart';
import 'package:gundam_pos/state/session_store.dart';

import 'support/fake_backend.dart';

/// Item 2 — a settlement the server REFUSED must still read FAILED (with the
/// same error code) after the app restarts. The status lives on the DURABLE
/// outbox row, not only in memory. Every assertion is falsifiable: removing the
/// markFailed/hydration wiring makes it fail.

const String _key = 'NSTAR-POS1-20261004-12:00-0000007';

Map<String, dynamic> _settlePayload(String key) => {
      'clientSettlementKey': key,
      'orderId': 'order-1',
      'receiptId': key,
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

void main() {
  group('PushStore durable failure state', () {
    test('MemoryPushStore: markFailed stores status+code, clearFailure resets', () async {
      final s = MemoryPushStore();
      await s.enqueue('order_settle', _key, _settlePayload(_key));
      expect((await s.pending()).single['status'], isNull);

      await s.markFailed('order_settle', _key, 'totals_mismatch');
      final row = (await s.pending()).single;
      expect(row['status'], 'failed');
      expect(row['error_code'], 'totals_mismatch');

      await s.clearFailure('order_settle', _key);
      final reset = (await s.pending()).single;
      expect(reset['status'], isNull);
      expect(reset['error_code'], isNull);
    });

    test('SqlitePosStore: markFailed stores status+code in pending, clearFailure resets', () async {
      // On a device this is real SQLite; on the test host sqflite is unavailable
      // and the store degrades to its in-memory fallback (the same code path the
      // app exercises there). The SQL itself is proven by the migration test.
      final dbPath =
          '${Directory.systemTemp.path}/gundam_fail_${DateTime.now().microsecondsSinceEpoch}.db';
      final store = SqlitePosStore(localDb: LocalDb(), path: dbPath);
      await store.enqueue('order_settle', _key, _settlePayload(_key));
      expect((await store.pending()).single['status'], isNull);

      await store.markFailed('order_settle', _key, 'totals_mismatch');
      final row = (await store.pending()).single;
      expect(row['status'], 'failed');
      expect(row['error_code'], 'totals_mismatch');

      await store.clearFailure('order_settle', _key);
      final reset = (await store.pending()).single;
      expect(reset['status'], isNull);
      expect(reset['error_code'], isNull);
    });
  });

  group('AppSession hydrates FAILED settlements from the durable outbox', () {
    test('a refused settlement reads FAILED + its code after a restart', () async {
      final push = MemoryPushStore();
      await push.enqueue('order_settle', _key, _settlePayload(_key));
      await push.markFailed('order_settle', _key, 'totals_mismatch');

      final backend = FakeBackend();
      final store = InMemorySessionStore();
      await store.save(await _readyContext());
      final session = backend.createSession(store: store, pushStore: push);
      await session.init();

      final rec = session.settlementFor(_key)!;
      expect(rec.failed, isTrue, reason: 'hydrated from the row, not lost with the app');
      expect(rec.errorCode, 'totals_mismatch');
      expect(session.failedSettlementCount, 1);
      expect(session.pendingSettlements.single.bill['receiptId'], _key);
    });

    test('accepting the settlement removes the row → no stale FAILED on restart', () async {
      final push = MemoryPushStore();
      await push.enqueue('order_settle', _key, _settlePayload(_key));
      await push.markFailed('order_settle', _key, 'totals_mismatch');

      final backend = FakeBackend();
      final store = InMemorySessionStore();
      await store.save(await _readyContext());
      final session = backend.createSession(store: store, pushStore: push);
      await session.init();
      expect(session.settlementFor(_key)!.failed, isTrue);

      // The server accepts the re-committed settlement.
      expect(await session.recommitSettlement(_key), isTrue);
      expect(await push.pending(), isEmpty, reason: 'accepted → dropped from the outbox');

      // Restart: nothing to hydrate.
      final restarted = backend.createSession(store: store, pushStore: push);
      await restarted.init();
      expect(restarted.settlementFor(_key), isNull);
    });
  });
}
