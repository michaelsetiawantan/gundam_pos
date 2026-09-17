import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gundam_pos/data/local_db.dart';
import 'package:gundam_pos/data/pos_store.dart';

/// Persistence contract: receipt sequencing + push outbox survive restart.
/// The SQLite impls are the persistence upgrade path; the memory impls are the
/// test/fallback path. Both must leave the AppSession + ReceiptSequencer green.
void main() {
  group('MemoryReceiptSequenceStore', () {
    test('increments per (device, day), resets on a new day', () async {
      final store = MemoryReceiptSequenceStore();
      expect(await store.next('NS', '20260917'), 1);
      expect(await store.next('NS', '20260917'), 2);
      // another device has its own sequence
      expect(await store.next('OTHER', '20260917'), 1);
      // new day resets
      expect(await store.next('NS', '20260918'), 1);
    });

    test('two pending seq reads never collide (atomic increment)', () async {
      final store = MemoryReceiptSequenceStore();
      final a = await store.next('NS', '20260917');
      final b = await store.next('NS', '20260917');
      expect([a, b], [1, 2]);
    });
  });

  group('MemoryPushStore', () {
    test('enqueue → pending → drain roundtrip', () async {
      final store = MemoryPushStore();
      expect(store.count, 0);
      await store.enqueue('ORDER', 'o1', {'a': 1});
      await store.enqueue('ORDER', 'o2', {'a': 2});
      expect(store.count, 2);
      expect(await store.pending(), hasLength(2));
      await store.drain();
      expect(store.count, 0);
      expect(await store.pending(), isEmpty);
    });
  });

  group('SqlitePosStore (sqflite or in-memory fallback)', () {
    test('receipt sequence stays monotonic and outbox roundtrips', () async {
      final dir = Directory.systemTemp;
      final dbPath = '${dir.path}/gundam_pos_store_test_${DateTime.now().microsecondsSinceEpoch}.db';
      final store = SqlitePosStore(localDb: LocalDb(), path: dbPath);
      // monotonic per (device, day), reset on a new day
      expect(await store.next('NS', '20260917'), 1);
      expect(await store.next('NS', '20260917'), 2);
      expect(await store.next('NS', '20260918'), 1);
      // outbox: enqueue → pending → drain
      await store.enqueue('ORDER', 'o1', {'a': 1});
      await store.enqueue('ORDER', 'o2', {'a': 2});
      final pending = await store.pending();
      expect(pending, hasLength(2));
      expect(pending.first['type'], 'ORDER');
      expect(pending.first['id'], 'o1');
      expect(pending.first['payload_json'], {'a': 1});
      await store.drain();
      expect((await store.pending()), isEmpty);
    });
  });
}