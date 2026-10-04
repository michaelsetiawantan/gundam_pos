/// POS Client diagnostics capture — a single operator-triggered bundle with the
/// device context, the local print-log summary and the recent in-app log lines,
/// shipped to `POST /api/pos/diagnostics` so a super-admin can analyse it.
///
/// Offline tolerance reuses the EXISTING outbox ([PushStore] `pending_sync`):
/// [DiagnosticReporter.submit] enqueues the bundle FIRST (durable) and only then
/// tries to flush, so a crash or a dead network loses nothing — the next sync
/// picks the item up. Idempotent on `clientReportId` (the server dedupes).
library;

import 'dart:async';
import 'dart:math';

import 'package:gundam_pos/api/api_client.dart';
import 'package:gundam_pos/api/pos_api.dart';
import 'package:gundam_pos/data/local_db.dart';
import 'package:gundam_pos/data/pos_store.dart';
import 'package:gundam_pos/data/print_log_store.dart';
import 'package:sqflite/sqflite.dart' as sqf;

// ---------------------------------------------------------------------------
// Caps — the ONE place binds stay bounded (a rogue log must never bloat a POST).
// ---------------------------------------------------------------------------
const int kDiagMaxLogLines = 200;
const int kDiagMaxRecentPrintRows = 25;
const int kDiagMaxDescriptionLen = 500;
const int kDiagMaxTextLen = 2000;

/// The outbox entity type for a queued diagnostic report.
const String kDiagnosticEntityType = 'diagnostic_report';

String _bound(String? s, int max) {
  if (s == null) return '';
  return s.length <= max ? s : '${s.substring(0, max)}…[truncated]';
}

// ---------------------------------------------------------------------------
// In-app log ring buffer.
// ---------------------------------------------------------------------------

class LogLine {
  const LogLine({
    required this.at,
    required this.level,
    required this.tag,
    required this.message,
    this.fromPreviousSession = false,
  });

  final DateTime at;
  final String level; // debug | info | warn | error
  final String tag;
  final String message;

  /// True when this line was RECOVERED from the durable store (a previous
  /// session / a crash), so the bundle can mark it as prior-session evidence.
  final bool fromPreviousSession;

  LogLine asPreviousSession() => LogLine(
        at: at,
        level: level,
        tag: tag,
        message: message,
        fromPreviousSession: true,
      );

  Map<String, dynamic> toJson() => {
        'at': at.toUtc().toIso8601String(),
        'level': level,
        'tag': tag,
        'message': _bound(message, kDiagMaxTextLen),
        if (fromPreviousSession) 'previousSession': true,
      };
}

/// Bounded log buffer. Newest-last. When a [persist] sink is attached (the app
/// wiring does this) every `warn`/`error` line is ALSO written to the durable
/// store (fire-and-forget) so a crash/restart does not erase the evidence; the
/// sink is capped by row count and age (see [DiagnosticLogStore]).
class DiagnosticLog {
  DiagnosticLog({this.capacity = kDiagMaxLogLines});

  final int capacity;
  final List<LogLine> _lines = [];

  DateTime Function() now = DateTime.now;

  /// Optional durable sink for `warn`/`error` lines. Null in tests / screens
  /// that build their own log, and never allowed to break logging.
  DiagnosticLogStore? persist;

  void add(String level, String tag, String message) {
    final line = LogLine(at: now(), level: level, tag: tag, message: message);
    _lines.add(line);
    if (_lines.length > capacity) _lines.removeRange(0, _lines.length - capacity);
    final sink = persist;
    if (sink != null && (level == 'warn' || level == 'error')) {
      // Fire-and-forget: a store failure must never surface or throw here.
      unawaited(sink.append(line).catchError((Object _) {}));
    }
  }

  void debug(String tag, String message) => add('debug', tag, message);
  void info(String tag, String message) => add('info', tag, message);
  void warn(String tag, String message) => add('warn', tag, message);
  void error(String tag, String message) => add('error', tag, message);

  /// Insert lines RECOVERED from a previous session at the FRONT of the buffer
  /// (they happened first), keeping capacity. Used at session start.
  void restore(List<LogLine> lines) {
    if (lines.isEmpty) return;
    _lines.insertAll(0, lines);
    if (_lines.length > capacity) _lines.removeRange(0, _lines.length - capacity);
  }

  List<LogLine> snapshot() => List<LogLine>.unmodifiable(_lines);

  int get length => _lines.length;

  void clear() => _lines.clear();
}

/// Process-wide buffer. Screens/tests may create their own instance, but the app
/// wires this one so every layer writes to the same stream.
final DiagnosticLog diagnosticLog = DiagnosticLog();

// ---------------------------------------------------------------------------
// Durable log store — crash/restart survival for the warn/error stream.
// ---------------------------------------------------------------------------

/// Row cap + age cap for the persisted stream — the ONE place the on-disk log
/// stays bounded. Only `warn`/`error` lines are persisted (that is the evidence
/// a technician needs after a crash), so this never bloats.
const int kDiagMaxPersistedRows = 200;
const Duration kDiagMaxPersistedAge = Duration(days: 7);

/// Durable sink for the diagnostic log. Mirrors `PrintLogStore`: injectable,
/// with an in-memory impl (tests + platform fallback) and a sqflite impl.
abstract class DiagnosticLogStore {
  Future<void> append(LogLine line);
  Future<List<LogLine>> recent({int limit});
  Future<void> prune({required int maxRows, required Duration maxAge});
}

/// In-memory impl (tests + fallback when sqflite/platform is unavailable).
class MemoryDiagnosticLogStore implements DiagnosticLogStore {
  MemoryDiagnosticLogStore({DateTime Function()? now}) : _now = now ?? DateTime.now;

  final DateTime Function() _now;
  final List<LogLine> _rows = [];

  @override
  Future<void> append(LogLine line) async {
    _rows.add(line);
    if (_rows.length > kDiagMaxPersistedRows) {
      _rows.removeRange(0, _rows.length - kDiagMaxPersistedRows);
    }
  }

  @override
  Future<List<LogLine>> recent({int limit = kDiagMaxPersistedRows}) async {
    if (_rows.length <= limit) return _rows.toList();
    return _rows.sublist(_rows.length - limit);
  }

  @override
  Future<void> prune({required int maxRows, required Duration maxAge}) async {
    final cutoff = _now().subtract(maxAge);
    _rows.removeWhere((l) => l.at.isBefore(cutoff));
  }
}

/// sqflite impl (survives restart). Degrades to memory when the platform path
/// is unavailable, exactly like the other local stores.
class SqliteDiagnosticLogStore implements DiagnosticLogStore {
  SqliteDiagnosticLogStore({
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
  MemoryDiagnosticLogStore? _fallback;

  MemoryDiagnosticLogStore get _mem => _fallback ??= MemoryDiagnosticLogStore();

  Future<sqf.Database> _open() async {
    if (_db == null) {
      var dbPath = _path;
      final provider = _pathProvider;
      if (dbPath == null && provider != null) {
        try {
          dbPath = await provider();
        } catch (_) {}
      }
      _db = (dbPath == null || dbPath.isEmpty)
          ? await _localDb.open(':memory:', inMemory: true)
          : await _localDb.open(dbPath, inMemory: _inMemory);
    }
    return _db!;
  }

  @override
  Future<void> append(LogLine line) async {
    try {
      final db = await _open();
      await db.rawInsert(
          'INSERT OR REPLACE INTO device_log (at, level, tag, message) VALUES (?,?,?,?)',
          [line.at.millisecondsSinceEpoch, line.level, line.tag, line.message]);
      // Keep the table bounded at every write (never grows without limit).
      await db.rawDelete(
          'DELETE FROM device_log WHERE id NOT IN '
          '(SELECT id FROM device_log ORDER BY id DESC LIMIT ?)',
          [kDiagMaxPersistedRows]);
    } catch (_) {
      await _mem.append(line);
    }
  }

  @override
  Future<List<LogLine>> recent({int limit = kDiagMaxPersistedRows}) async {
    try {
      final db = await _open();
      final rows = await db.rawQuery(
          'SELECT at, level, tag, message FROM device_log ORDER BY id DESC LIMIT ?',
          [limit]);
      // DESC gives newest-first; reverse to chronological (oldest-first) so the
      // recovered lines read in the order they happened.
      return rows.reversed.map(_fromRow).toList();
    } catch (_) {
      return _mem.recent(limit: limit);
    }
  }

  @override
  Future<void> prune({required int maxRows, required Duration maxAge}) async {
    try {
      final db = await _open();
      final cutoff = DateTime.now().subtract(maxAge).millisecondsSinceEpoch;
      await db.rawDelete('DELETE FROM device_log WHERE at < ?', [cutoff]);
    } catch (_) {
      await _mem.prune(maxRows: maxRows, maxAge: maxAge);
    }
  }

  LogLine _fromRow(Map<String, Object?> r) => LogLine(
        at: DateTime.fromMillisecondsSinceEpoch(((r['at'] as num?)?.toInt()) ?? 0),
        level: (r['level'] as String?) ?? 'error',
        tag: (r['tag'] as String?) ?? '',
        message: (r['message'] as String?) ?? '',
      );
}

// ---------------------------------------------------------------------------
// Bundle builder (pure → unit-testable without network or platform).
// ---------------------------------------------------------------------------

/// Fields that expose an error/exception-looking signal. `error`/`warn` levels
/// always count; any line whose text matches a fault keyword counts too (a
/// `print_failed` info line is still evidence the technician wants highlighted).
final RegExp _faultRe = RegExp(
  r'error|exception|fail|timeout|refused|unreachable|panic|traceback|denied|blocked',
  caseSensitive: false,
);

bool lineLooksLikeError(LogLine l) => l.level == 'error' || _faultRe.hasMatch(l.message) || _faultRe.hasMatch(l.tag);

/// Build the device diagnostic bundle. Every free-text field is bounded and the
/// row/line lists are capped, so the produced JSON has a predictable ceiling.
Map<String, dynamic> buildDiagnosticBundle({
  required String clientReportId,
  required DateTime generatedAt,
  required String description,
  required String appVersionName,
  required int appVersionCode,
  required int schemaVersion,
  String buildSha = '',
  String? deviceId,
  String? shortcode,
  String? groupId,
  String? tenantId,
  String? outletName,
  String? userName,
  String? serverAddress,
  DateTime? lastSyncAt,
  Map<String, dynamic> configVersions = const {},
  String? lastError,
  List<PrintLogRow> recentPrintRows = const [],
  Map<String, int> printOutcomeCounts = const {},
  int printTotal = 0,
  int printPendingUpload = 0,
  List<LogLine> logLines = const [],
  List<Map<String, dynamic>> printers = const [],
}) {
  final rows = recentPrintRows.take(kDiagMaxRecentPrintRows).map((r) => {
        'clientLogId': r.clientLogId,
        'ticketType': r.ticketType,
        'outcome': r.outcome,
        'printerName': r.printerName,
        'printerTransport': r.printerTransport,
        'errorCode': r.errorCode,
        'errorDetail': _bound(r.errorDetail, kDiagMaxTextLen),
        'attemptCount': r.attemptCount,
        'createdAt': r.createdAt.toUtc().toIso8601String(),
        'uploadState': r.uploadState,
      }).toList();

  final lines = logLines.take(kDiagMaxLogLines).map((l) => l.toJson()).toList();
  final levelCounts = <String, int>{'debug': 0, 'info': 0, 'warn': 0, 'error': 0};
  for (final l in logLines) {
    levelCounts[l.level] = (levelCounts[l.level] ?? 0) + 1;
  }
  final errorLineCount = logLines.where(lineLooksLikeError).length;

  return {
    'clientReportId': clientReportId,
    'generatedAt': generatedAt.toUtc().toIso8601String(),
    'description': _bound(description, kDiagMaxDescriptionLen),
    'appVersion': {
      'name': appVersionName,
      'code': appVersionCode,
      'schema': schemaVersion,
      if (buildSha.isNotEmpty) 'buildSha': _bound(buildSha, 80),
    },
    'device': {
      'deviceId': deviceId,
      'shortcode': shortcode,
      'groupId': groupId,
      'tenantId': tenantId,
      'outletName': outletName,
      'userName': userName,
    },
    'connection': {
      'serverAddress': serverAddress,
      'lastSyncAt': lastSyncAt?.toUtc().toIso8601String(),
      'configVersions': configVersions,
    },
    'lastError': _bound(lastError, kDiagMaxTextLen),
    'printSummary': {
      'ok': printOutcomeCounts['OK'] ?? 0,
      'fallback': printOutcomeCounts['FALLBACK'] ?? 0,
      'failed': printOutcomeCounts['FAILED'] ?? 0,
      'total': printTotal,
      'pendingUpload': printPendingUpload,
    },
    'recentPrintRows': rows,
    'printers': printers,
    'logLines': lines,
    'logLevelCounts': levelCounts,
    'errorLineCount': errorLineCount,
  };
}

final _rand = Random();
String newClientReportId(DateTime now) =>
    'diag-${now.microsecondsSinceEpoch}-${_rand.nextInt(1 << 32).toRadixString(16)}';

// ---------------------------------------------------------------------------
// Reporter — offline-first submit through the existing outbox.
// ---------------------------------------------------------------------------

class DiagnosticSendResult {
  const DiagnosticSendResult({required this.sent, required this.pending, required this.queued});

  /// Items accepted by the server on this pass.
  final int sent;

  /// Items still waiting in the outbox after the pass (offline / server error).
  final int pending;

  /// The bundle was enqueued before the upload attempt (never lost).
  final bool queued;
}

/// Enqueues a bundle then flushes the queue. Never throws: a network failure
/// leaves the item queued for the next sync.
class DiagnosticReporter {
  DiagnosticReporter({
    required this.api,
    required this.push,
    DateTime Function()? now,
    String Function(DateTime)? idFactory,
  })  : _now = now ?? DateTime.now,
        _idFactory = idFactory ?? newClientReportId;

  final PosApi api;
  final PushStore push;
  final DateTime Function() _now;
  final String Function(DateTime) _idFactory;

  String newId() => _idFactory(_now());

  /// Why the last [flush] could not deliver (null when it delivered). Lets the
  /// screen say "server rejected (404 asset_not_found)" instead of blaming the
  /// network — the two need completely different fixes.
  String? lastFailure;

  /// Build-and-send. [bundle] must already carry `clientReportId`.
  Future<DiagnosticSendResult> submit({
    required Map<String, dynamic> bundle,
    required String tenantId,
    required String assetId,
  }) async {
    final id = bundle['clientReportId'] as String;
    // Enqueue FIRST so an immediate crash / dead network still leaves evidence.
    await push.enqueue(kDiagnosticEntityType, id, bundle);
    final sent = await flush(tenantId: tenantId, assetId: assetId);
    return DiagnosticSendResult(sent: sent, pending: await pendingCount(), queued: true);
  }

  /// Post every queued report, removing each on success. Returns how many landed.
  Future<int> flush({required String tenantId, required String assetId}) async {
    List<Map<String, dynamic>> items;
    try {
      items = await push.pending();
    } catch (_) {
      return 0;
    }
    var sent = 0;
    for (final it in items.where((i) => i['type'] == kDiagnosticEntityType)) {
      final id = it['id'];
      final payload = it['payload_json'];
      if (id is! String || payload is! Map) continue;
      try {
        await api.postDiagnostics(
          tenantId: tenantId,
          assetId: assetId,
          report: Map<String, dynamic>.from(payload),
        );
        await push.remove(kDiagnosticEntityType, id);
        sent++;
      } catch (e) {
        lastFailure = e is PosApiException ? 'server rejected (${e.status} ${e.code})' : 'could not reach the server ($e)';
        // Offline / server error: leave it queued for the next sync.
      }
    }
    if (sent > 0) lastFailure = null;
    return sent;
  }

  Future<int> pendingCount() async {
    try {
      final items = await push.pending();
      return items.where((i) => i['type'] == kDiagnosticEntityType).length;
    } catch (_) {
      return 0;
    }
  }
}
