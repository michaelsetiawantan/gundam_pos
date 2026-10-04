/// Media cache sync — pulls the tenant's media manifest into local files so the
/// IMAGE block can print OFFLINE.
///
/// The gap this closes: `GET /api/pos/media/manifest` already returns
/// `{key,url,sha256,size,version}`, the tablet already has a
/// `local_media_assets` table and `print_image.dart` already resolves an
/// `assetKey` through it — but nothing ever downloaded the bytes, so an IMAGE
/// block on a tablet without a live server had nothing to print.
///
/// Contract (mirrors `web/lib/config/clientContract.ts`):
///   * never a partial file — download to `<name>.part`, verify sha256 + size,
///     then rename into place;
///   * a hash mismatch is a FAILURE, not a silent overwrite;
///   * already-cached with the same sha256 and the file present → skip (the
///     tablet only re-downloads when the server's hash changes);
///   * an asset dropped from the manifest is pruned (row + file).
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:gundam_pos/services/print_image.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

/// One `assets[]` entry of the media manifest.
class MediaManifestEntry {
  MediaManifestEntry({
    required this.key,
    required this.url,
    required this.sha256,
    required this.size,
    required this.version,
    this.kind,
    this.variant,
  });

  final String key;
  final String url;
  final String sha256;
  final int size;
  final int version;
  final String? kind;
  final String? variant;

  static MediaManifestEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final key = raw['key'];
    final url = raw['url'];
    final hash = raw['sha256'];
    if (key is! String || key.isEmpty) return null;
    if (url is! String || url.isEmpty) return null;
    if (hash is! String || hash.isEmpty) return null;
    return MediaManifestEntry(
      key: key,
      url: url,
      sha256: hash.toLowerCase(),
      size: raw['size'] is int ? raw['size'] as int : 0,
      version: raw['version'] is int ? raw['version'] as int : 0,
      kind: raw['kind'] is String ? raw['kind'] as String : null,
      variant: raw['variant'] is String ? raw['variant'] as String : null,
    );
  }
}

/// A cached asset row (`local_media_assets`).
class MediaCacheRow {
  MediaCacheRow({
    required this.assetKey,
    required this.localPath,
    required this.sha256,
    required this.size,
    required this.mediaVersion,
    this.kind,
    this.critical = false,
    this.downloadedAt,
  });

  final String assetKey;
  final String localPath;
  final String sha256;
  final int size;
  final int mediaVersion;
  final String? kind;
  final bool critical;
  final DateTime? downloadedAt;
}

/// Storage seam — the app wires [SqliteMediaCacheStore], tests the memory one.
abstract class MediaCacheStore {
  Future<MediaCacheRow?> find(String assetKey);
  Future<void> upsert(MediaCacheRow row);
  Future<List<String>> keys();
  Future<void> remove(String assetKey);
}

class MemoryMediaCacheStore implements MediaCacheStore {
  MemoryMediaCacheStore();

  final Map<String, MediaCacheRow> _rows = {};

  @override
  Future<MediaCacheRow?> find(String assetKey) async => _rows[assetKey];

  @override
  Future<void> upsert(MediaCacheRow row) async => _rows[row.assetKey] = row;

  @override
  Future<List<String>> keys() async => _rows.keys.toList();

  @override
  Future<void> remove(String assetKey) async => _rows.remove(assetKey);
}

/// What one sync pass did — reported, never silent.
class MediaSyncReport {
  MediaSyncReport();

  final List<String> downloaded = [];
  final List<String> skipped = [];
  final List<String> failed = [];
  final List<String> pruned = [];

  bool get ok => failed.isEmpty;

  @override
  String toString() =>
      'media sync: ${downloaded.length} downloaded, ${skipped.length} cached, '
      '${failed.length} failed, ${pruned.length} pruned';
}

class MediaSync {
  MediaSync({
    required this.dir,
    required this.store,
    http.Client? httpClient,
    this.baseHeaders = const {},
  }) : _http = httpClient ?? http.Client();

  /// Media root for this tenant (e.g. `/app-data/media/{tenant}`).
  final Directory dir;
  final MediaCacheStore store;
  final http.Client _http;

  /// Auth headers for the manifest/download calls (refreshed per sync by the
  /// caller, so a re-login never leaves a stale token here).
  Map<String, String> baseHeaders;

  /// Local file name for a key — one file per key, the server decides the bytes.
  File fileFor(String assetKey) => File(p.join(dir.path, _safeName(assetKey)));

  static String _safeName(String key) =>
      key.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');

  /// Fetch the manifest, then bring every entry into the local cache.
  Future<MediaSyncReport> sync({required Uri manifestUri}) async {
    final report = MediaSyncReport();
    final List<MediaManifestEntry> entries;

    try {
      final res = await _http.get(manifestUri, headers: baseHeaders);
      if (res.statusCode != 200) {
        report.failed.add('manifest:${res.statusCode}');
        return report;
      }
      final body = jsonDecode(res.body);
      final raw = body is Map ? body['assets'] : null;
      entries = (raw is List ? raw : const [])
          .map(MediaManifestEntry.fromJson)
          .whereType<MediaManifestEntry>()
          .toList();
    } catch (e) {
      report.failed.add('manifest:$e');
      return report;
    }

    await dir.create(recursive: true);

    for (final entry in entries) {
      final cached = await store.find(entry.key);
      if (cached != null &&
          cached.sha256.toLowerCase() == entry.sha256 &&
          File(cached.localPath).existsSync()) {
        report.skipped.add(entry.key);
        continue;
      }
      final ok = await _download(entry, report);
      if (ok) report.downloaded.add(entry.key);
    }

    // Prune what the server no longer lists.
    final wanted = entries.map((e) => e.key).toSet();
    for (final key in await store.keys()) {
      if (wanted.contains(key)) continue;
      final row = await store.find(key);
      if (row != null) {
        final f = File(row.localPath);
        if (f.existsSync()) await f.delete();
      }
      await store.remove(key);
      report.pruned.add(key);
    }

    return report;
  }

  /// Download + verify + atomically rename + record. false → reported failure.
  Future<bool> _download(MediaManifestEntry entry, MediaSyncReport report) async {
    final target = fileFor(entry.key);
    final part = File('${target.path}.part');
    try {
      final res = await _http.get(Uri.parse(entry.url), headers: baseHeaders);
      if (res.statusCode != 200) {
        report.failed.add('${entry.key}:http${res.statusCode}');
        return false;
      }
      final bytes = res.bodyBytes;
      if (entry.size > 0 && bytes.length != entry.size) {
        report.failed.add('${entry.key}:size${bytes.length}!=${entry.size}');
        return false;
      }
      final digest = sha256.convert(bytes).toString();
      if (digest != entry.sha256) {
        report.failed.add('${entry.key}:sha256');
        return false;
      }
      await part.writeAsBytes(bytes, flush: true);
      await part.rename(target.path);
      await store.upsert(MediaCacheRow(
        assetKey: entry.key,
        localPath: target.path,
        sha256: digest,
        size: bytes.length,
        mediaVersion: entry.version,
        kind: entry.kind,
        downloadedAt: DateTime.now(),
      ));
      return true;
    } catch (e) {
      report.failed.add('${entry.key}:$e');
      return false;
    } finally {
      if (await part.exists()) {
        try {
          await part.delete();
        } catch (_) {/* best effort */}
      }
    }
  }

  /// Local bytes for an asset key. null when the asset is not cached (the
  /// renderer prints its labelled placeholder instead).
  Future<Uint8List?> bytesFor(String assetKey) async {
    final row = await store.find(assetKey);
    if (row == null) return null;
    final f = File(row.localPath);
    if (!await f.exists()) return null;
    return f.readAsBytes();
  }
}

/// Bridge to the print path: `encodePrintJobWithImages(job, source: ...)`
/// resolves an IMAGE block's `assetKey` through here. The app factory passes the
/// provider to EVERY transport (network included) — no global seam.
class MediaSyncPrintImageSource extends PrintImageSource {
  MediaSyncPrintImageSource(this._sync);

  final MediaSync _sync;

  @override
  Future<Uint8List?> bytesFor(String assetKey) => _sync.bytesFor(assetKey);
}
