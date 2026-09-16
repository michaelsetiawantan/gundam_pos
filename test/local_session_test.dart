import 'package:flutter_test/flutter_test.dart';
import 'package:gundam_pos/data/local_db.dart';
import 'package:gundam_pos/state/session_store.dart';

void main() {
  group('local SQLite schema', () {
    test('user_version contract is 2 (migration-ready)', () {
      expect(schemaVersion, 2);
    });

    test('v1 migration creates all LOCAL-SCHEMA tables idempotently', () {
      final ddl = migrationUpStatements(1).join('\n');
      for (final table in const [
        'config_store',
        'config_checkpoint',
        'receipt_sequence',
        'local_transactions',
        'local_transaction_items',
        'local_money_lines',
        'pending_sync',
        'local_shifts',
        'local_cash_count',
        'local_tables',
        'config_snapshots',
        'local_guests',
        'local_media_assets',
      ]) {
        expect(ddl, contains('CREATE TABLE IF NOT EXISTS $table'));
      }
    });

    test('migration adds the receipt-idempotency and queue indexes', () {
      final ddl = migrationUpStatements(1).join('\n');
      expect(ddl, contains('idx_pending_dedupe'));
      expect(ddl, contains('idx_tx_sync'));
      expect(ddl, contains('idx_media_key'));
    });
  });

  group('SessionStore', () {
    test('in-memory store roundtrips activation + session context', () async {
      final store = InMemorySessionStore();
      var ctx = const PosContext();
      expect(ctx.activated, isFalse);

      ctx = ctx.withRedeem({'deviceToken': 'tok', 'groupId': 'g1', 'tenantId': 't1', 'shortcode': 'NSTAR-POS1'});
      expect(ctx.activated, isTrue);

      ctx = ctx.withSession({
        'sessionId': 'sess-1',
        'user': {'id': 'u1', 'email': 'a@x', 'fullName': 'Ana'},
        'outlet': {'id': 't1', 'name': 'Northstar'},
      });
      expect(ctx.loggedIn, isTrue);
      expect(ctx.userName, 'Ana');
      expect(ctx.outletName, 'Northstar');

      await store.save(ctx);
      final loaded = await store.load();
      expect(loaded.deviceToken, 'tok');
      expect(loaded.tenantId, 't1');
      expect(loaded.sessionId, 'sess-1');

      await store.clear();
      expect((await store.load()).activated, isFalse);
    });

    test('redeem preserves prior data', () async {
      final ctx = const PosContext()
              .withRedeem({'deviceToken': 'tok', 'groupId': 'g1', 'tenantId': 't1'})
              .withSession({'sessionId': 's1', 'user': {'id': 'u'}, 'outlet': {'id': 't'}});
          expect(ctx.activated, isTrue);
          expect(ctx.sessionId, 's1');
    });
  });
}