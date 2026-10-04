/// Persisted media cache index (`local_media_assets`) — the mapping the IMAGE
/// block resolves through: `asset_key → local_path`, with the sha256/size the
/// download was verified against.
///
/// Mirrors `print_log_store.dart`: an injectable interface with a sqflite impl
/// that degrades to memory when the platform channel or the path is unavailable
/// (CI / test host), so nothing in the print path ever throws over storage.
library;

import 'package:gundam_pos/data/local_db.dart';
import 'package:gundam_pos/services/media_sync.dart';
import 'package:sqflite/sqflite.dart' as sqf;

class SqliteMediaCacheStore implements MediaCacheStore {
  SqliteMediaCacheStore({
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
  MemoryMediaCacheStore? _fallback;

  Future<sqf.Database> _open() async {
    if (_db == null) {
      var dbPath = _path;
      final provider = _pathProvider;
      if (dbPath == null && provider != null) {
        try {
          dbPath = await provider();
        } catch (_) {/* no platform dir → memory below */}
      }
      _db = (dbPath == null || dbPath.isEmpty)
          ? await _localDb.open(':memory:', inMemory: true)
          : await _localDb.open(dbPath, inMemory: _inMemory);
    }
    return _db!;
  }

  MemoryMediaCacheStore get _mem => _fallback ??= MemoryMediaCacheStore();

  @override
  Future<MediaCacheRow?> find(String assetKey) async {
    try {
      final db = await _open();
      final rows = await db.query('local_media_assets',
          where: 'asset_key = ?', whereArgs: [assetKey], limit: 1);
      if (rows.isEmpty) return null;
      return _row(rows.first);
    } catch (_) {
      return _mem.find(assetKey);
    }
  }

  /// One row per key: the previous hash for the same key is replaced, so a
  /// re-published asset never leaves two candidate paths behind.
  @override
  Future<void> upsert(MediaCacheRow row) async {
    try {
      final db = await _open();
      await db.delete('local_media_assets', where: 'asset_key = ?', whereArgs: [row.assetKey]);
      await db.insert('local_media_assets', {
        'asset_key': row.assetKey,
        'local_path': row.localPath,
        'sha256': row.sha256,
        'size': row.size,
        'media_version': row.mediaVersion,
        'kind': row.kind,
        'critical': row.critical ? 1 : 0,
        'downloaded_at': (row.downloadedAt ?? DateTime.now()).millisecondsSinceEpoch,
      });
    } catch (_) {
      await _mem.upsert(row);
    }
  }

  @override
  Future<List<String>> keys() async {
    try {
      final db = await _open();
      final rows = await db.query('local_media_assets', columns: ['asset_key']);
      return [for (final r in rows) r['asset_key'] as String];
    } catch (_) {
      return _mem.keys();
    }
  }

  @override
  Future<void> remove(String assetKey) async {
    try {
      final db = await _open();
      await db.delete('local_media_assets', where: 'asset_key = ?', whereArgs: [assetKey]);
    } catch (_) {
      await _mem.remove(assetKey);
    }
  }

  static MediaCacheRow _row(Map<String, Object?> r) => MediaCacheRow(
        assetKey: r['asset_key'] as String,
        localPath: r['local_path'] as String,
        sha256: (r['sha256'] as String? ?? '').toLowerCase(),
        size: (r['size'] as num?)?.toInt() ?? 0,
        mediaVersion: (r['media_version'] as num?)?.toInt() ?? 0,
        kind: r['kind'] as String?,
        critical: (r['critical'] as num?)?.toInt() == 1,
        downloadedAt: r['downloaded_at'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch((r['downloaded_at'] as num).toInt()),
      );
}
