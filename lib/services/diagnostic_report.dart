/// POS Client diagnostics capture — a single operator-triggered bundle with the
/// device context, the local print-log summary and the recent in-app log lines,
/// shipped to `POST /api/pos/diagnostics` so a super-admin can analyse it.
///
/// Offline tolerance reuses the EXISTING outbox ([PushStore] `pending_sync`):
/// [DiagnosticReporter.submit] enqueues the bundle FIRST (durable) and only then
/// tries to flush, so a crash or a dead network loses nothing — the next sync
/// picks the item up. Idempotent on `clientReportId` (the server dedupes).
library;

import 'dart:math';

import 'package:gundam_pos/api/api_client.dart';
import 'package:gundam_pos/api/pos_api.dart';
import 'package:gundam_pos/data/pos_store.dart';
import 'package:gundam_pos/data/print_log_store.dart';

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
  const LogLine({required this.at, required this.level, required this.tag, required this.message});

  final DateTime at;
  final String level; // debug | info | warn | error
  final String tag;
  final String message;

  Map<String, dynamic> toJson() => {
        'at': at.toUtc().toIso8601String(),
        'level': level,
        'tag': tag,
        'message': _bound(message, kDiagMaxTextLen),
      };
}

/// Bounded, in-memory, newest-last log buffer. Deliberately NOT persisted: a
/// diagnostic bundle is a point-in-time snapshot of what the device just did.
class DiagnosticLog {
  DiagnosticLog({this.capacity = kDiagMaxLogLines});

  final int capacity;
  final List<LogLine> _lines = [];

  DateTime Function() now = DateTime.now;

  void add(String level, String tag, String message) {
    _lines.add(LogLine(at: now(), level: level, tag: tag, message: message));
    if (_lines.length > capacity) _lines.removeRange(0, _lines.length - capacity);
  }

  void debug(String tag, String message) => add('debug', tag, message);
  void info(String tag, String message) => add('info', tag, message);
  void warn(String tag, String message) => add('warn', tag, message);
  void error(String tag, String message) => add('error', tag, message);

  List<LogLine> snapshot() => List<LogLine>.unmodifiable(_lines);

  int get length => _lines.length;

  void clear() => _lines.clear();
}

/// Process-wide buffer. Screens/tests may create their own instance, but the app
/// wires this one so every layer writes to the same stream.
final DiagnosticLog diagnosticLog = DiagnosticLog();

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
