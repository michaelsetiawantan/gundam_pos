/// SQLite-backed stores for the LOCAL-SCHEMA `receipt_sequence` + `pending_sync`
/// tables, so receipt numbering and the push outbox survive app restarts.
/// Interfaces are injectable: tests use the in-memory impls; the app wires the
/// sqflite impls (which degrade to memory when sqflite is unavailable).
library;

import 'dart:convert';

import 'package:gundam_pos/data/local_db.dart';
import 'package:sqflite/sqflite.dart' as sqf;

// ---------------------------------------------------------------------------
// Receipt sequence (LOCAL-SCHEMA `receipt_sequence`): per-device, per-day seq.
// ---------------------------------------------------------------------------

abstract class ReceiptSequenceStore {
  /// Next (1-based) sequence for (shortcode, date), atomically incremented so
  /// two concurrent settles can never mint the same id.
  Future<int> next(String shortcode, String date);
}

/// Per-process counter (the pre-sqflite MVP behavior). Resets at boot.
class MemoryReceiptSequenceStore implements ReceiptSequenceStore {
  final Map<String, int> _byKey = {};

  @override
  Future<int> next(String shortcode, String date) async {
    final key = '$shortcode\u0000$date';
    final seq = (_byKey[key] ?? 0) + 1;
    _byKey[key] = seq;
    return seq;
  }
}

// ---------------------------------------------------------------------------
// Push outbox (LOCAL-SCHEMA `pending_sync`): deferred offline pushes.
// ---------------------------------------------------------------------------

abstract class PushStore {
  int get count;
  Future<List<Map<String, dynamic>>> pending();
  Future<void> enqueue(String entityType, String entityId, Object payload, [int? createdAt]);
  Future<void> drain();

  /// Remove ONE queued item (per-entity ack). Used by the diagnostics outbox so
  /// a single accepted report leaves the queue without draining the rest.
  Future<void> remove(String entityType, String entityId);
}

/// In-memory outbox (the pre-sqflite MVP behavior). Cleared on restart.
class MemoryPushStore implements PushStore {
  final List<Map<String, dynamic>> _queue = [];

  @override
  int get count => _queue.length;

  @override
  Future<List<Map<String, dynamic>>> pending() async => _queue.toList();

  @override
  Future<void> enqueue(String entityType, String entityId, Object payload, [int? createdAt]) async {
    // Upsert on (entity_type, entity_id), matching the sqflite
    // `idx_pending_dedupe` UNIQUE index — re-enqueueing the same key (e.g. a
    // re-committed settlement) replaces the payload, it never duplicates.
    _queue.removeWhere((i) => i['type'] == entityType && i['id'] == entityId);
    _queue.add({'type': entityType, 'id': entityId, 'payload_json': payload, 'created_at': createdAt});
  }

  @override
  Future<void> drain() async => _queue.clear();

  @override
  Future<void> remove(String entityType, String entityId) async {
    _queue.removeWhere((i) => i['type'] == entityType && i['id'] == entityId);
  }
}

// ---------------------------------------------------------------------------
// sqflite-backed implementations (persist across restarts).
// ---------------------------------------------------------------------------

/// Shared SQLite gateway for the persisted stores. Opens the local DB lazily
/// (once) through the injected [LocalDb] (its factory/real path decide where
/// the file lives). Falls back to in-memory behavior if sqflite is unavailable
/// or no platform path resolves, so the same code path runs under `flutter test`.
class SqlitePosStore implements ReceiptSequenceStore, PushStore {
  SqlitePosStore({
    required LocalDb localDb,
    String? path,
    Future<String> Function()? pathProvider,
    bool inMemory = false,
  })  : _localDb = localDb,
        _path = path,
        _pathProvider = pathProvider,
        _inMemory = inMemory;

  final LocalDb _localDb;
  final String? _path;
  final Future<String> Function()? _pathProvider;
  final bool _inMemory;

  sqf.Database? _db;
  MemoryReceiptSequenceStore? _fallbackSeq;
  MemoryPushStore? _fallbackPush;
  int _memCount = 0;

  Future<sqf.Database> _open() async {
    if (_db == null) {
      var dbPath = _path;
      final provider = _pathProvider;
      if (dbPath == null && provider != null) {
        try {
          dbPath = await provider();
        } catch (_) {/* no platform dir → in-memory below */}
      }
      if (dbPath == null || dbPath.isEmpty) {
        _db = await _localDb.open(':memory:', inMemory: true);
      } else {
        _db = await _localDb.open(dbPath, inMemory: _inMemory);
      }
      // Hydrate the outbox display count from the persisted table when reachable.
      final db = _db!;
      try {
        final rows = await db.rawQuery('SELECT COUNT(*) AS n FROM pending_sync');
        _memCount = rows.isNotEmpty && rows.first['n'] is int ? rows.first['n'] as int : 0;
      } catch (_) {/* stay at 0 */}
    }
    return _db!;
  }

  // ---------------------------------------------------------------- sequence --
  @override
  Future<int> next(String shortcode, String date) async {
    try {
      final db = await _open();
      await db.rawInsert(
          'INSERT INTO receipt_sequence (device_shortcode, date_yyyymmdd, last_seq) '
          'VALUES (?, ?, 1) '
          'ON CONFLICT(device_shortcode, date_yyyymmdd) DO UPDATE SET last_seq = last_seq + 1',
          [shortcode, date]);
      final rows = await db.rawQuery(
          'SELECT last_seq FROM receipt_sequence '
          'WHERE device_shortcode = ? AND date_yyyymmdd = ?',
          [shortcode, date]);
      return rows.isNotEmpty ? rows.first['last_seq'] as int : 1;
    } catch (_) {
      final fallback = _fallbackSeq ??= MemoryReceiptSequenceStore();
      return fallback.next(shortcode, date);
    }
  }

  // ------------------------------------------------------------------ push --
  @override
  int get count => _memCount;

  @override
  Future<List<Map<String, dynamic>>> pending() async {
    try {
      final db = await _open();
      final rows = await db.rawQuery(
          'SELECT entity_type AS type, entity_id AS id, payload_json, created_at '
          'FROM pending_sync ORDER BY created_at ASC, id ASC');
      _memCount = rows.length;
      return rows.map((r) {
        final out = <String, dynamic>{'type': r['type'], 'id': r['id'], 'created_at': r['created_at']};
        final raw = r['payload_json'];
        if (raw is String) {
          try {
            out['payload_json'] = jsonDecode(raw);
          } catch (_) {
            out['payload_json'] = raw;
          }
        } else {
          out['payload_json'] = raw;
        }
        return out;
      }).toList();
    } catch (_) {
      final fallback = _fallbackPush ??= MemoryPushStore();
      _memCount = fallback.count;
      return fallback.pending();
    }
  }

  @override
  Future<void> enqueue(String entityType, String entityId, Object payload, [int? createdAt]) async {
    try {
      final db = await _open();
      final now = createdAt ?? DateTime.now().millisecondsSinceEpoch;
      final json = payload is String ? payload : jsonEncode(payload);
      // Upsert on (entity_type, entity_id): the UNIQUE `idx_pending_dedupe`
      // forbids duplicates, so a failed INSERT becomes an UPDATE (also covers
      // a concurrent-insert race on a brand-new id).
      int inserted;
      try {
        inserted = await db.rawInsert(
            'INSERT INTO pending_sync (entity_type, entity_id, payload_json, created_at) '
            'VALUES (?, ?, ?, ?)',
            [entityType, entityId, json, now]);
      } catch (_) {
        inserted = 0;
        await db.rawUpdate(
            'UPDATE pending_sync SET payload_json = ?, created_at = ? '
            'WHERE entity_type = ? AND entity_id = ?',
            [json, now, entityType, entityId]);
      }
      if (inserted > 0) _memCount++;
    } catch (_) {
      final fallback = _fallbackPush ??= MemoryPushStore();
      await fallback.enqueue(entityType, entityId, payload, createdAt);
      _memCount = fallback.count;
    }
  }

  @override
  Future<void> drain() async {
    try {
      final db = await _open();
      await db.rawDelete('DELETE FROM pending_sync WHERE synced_at IS NULL');
      _memCount = 0;
    } catch (_) {
      final fallback = _fallbackPush ??= MemoryPushStore();
      await fallback.drain();
      _memCount = fallback.count;
    }
  }

  @override
  Future<void> remove(String entityType, String entityId) async {
    try {
      final db = await _open();
      await db.rawDelete(
          'DELETE FROM pending_sync WHERE entity_type = ? AND entity_id = ?',
          [entityType, entityId]);
      final rows = await db.rawQuery('SELECT COUNT(*) AS n FROM pending_sync');
      _memCount = rows.isNotEmpty && rows.first['n'] is int ? rows.first['n'] as int : 0;
    } catch (_) {
      final fallback = _fallbackPush ??= MemoryPushStore();
      await fallback.remove(entityType, entityId);
      _memCount = fallback.count;
    }
  }
}