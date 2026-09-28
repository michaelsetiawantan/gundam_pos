/// Local print-attempt audit store (LOCAL-SCHEMA v3 `print_log`).
///
/// One row per print attempt, written BEFORE the transport is invoked (so a
/// crash mid-print still leaves evidence) and finalized after. Rows carry a
/// local upload state (`pending` / `sent` / `failed`) and a stable
/// `client_log_id` the server dedupes on.
///
/// Interfaces are injectable (mirrors `pos_store.dart`): the app wires the
/// sqflite impl (which degrades to memory when sqflite/platform is unavailable),
/// tests use the memory impl.
library;

import 'dart:convert';

import 'package:gundam_pos/data/local_db.dart';
import 'package:sqflite/sqflite.dart' as sqf;

/// Local upload states.
const String kPrintLogPending = 'pending';
const String kPrintLogSent = 'sent';
const String kPrintLogFailed = 'failed';

/// One print-attempt record — the exact shape uploaded to
/// `POST /api/pos/print-logs` plus local upload state.
class PrintLogRow {
  PrintLogRow({
    required this.clientLogId,
    required this.ticketType,
    this.receiptId,
    this.orderId,
    this.printerId,
    this.printerName,
    this.printerTransport,
    required this.outcome,
    this.attemptCount = 0,
    this.errorCode,
    this.errorDetail,
    this.durationMs,
    this.byteLength,
    this.dialectCode,
    this.dialectFallback = false,
    this.codePageCode,
    this.warnings = const [],
    this.renderedText,
    required this.createdAt,
    this.uploadState = kPrintLogPending,
    this.uploadAttempts = 0,
    this.lastUploadError,
    this.sentAt,
  });

  final String clientLogId;
  final String ticketType;
  final String? receiptId;
  final String? orderId;
  final String? printerId;
  final String? printerName;
  final String? printerTransport;

  /// FAILED | FALLBACK | OK (or `FAILED`/`incomplete` while still in flight).
  final String outcome;
  final int attemptCount;
  final String? errorCode;
  final String? errorDetail;
  final int? durationMs;
  final int? byteLength;
  final String? dialectCode;
  final bool dialectFallback;
  final String? codePageCode;
  final List<String> warnings;
  final String? renderedText;

  /// Wall clock when the attempt started.
  final DateTime createdAt;

  final String uploadState;
  final int uploadAttempts;
  final String? lastUploadError;
  final DateTime? sentAt;

  bool get uploaded => uploadState == kPrintLogSent;

  /// The upload entry — keys match the server contract exactly.
  Map<String, dynamic> toUploadJson() => {
        'clientLogId': clientLogId,
        'ticketType': ticketType,
        if (receiptId != null) 'receiptId': receiptId,
        if (orderId != null) 'orderId': orderId,
        if (printerId != null) 'printerId': printerId,
        if (printerName != null) 'printerName': printerName,
        if (printerTransport != null) 'printerTransport': printerTransport,
        'outcome': outcome,
        'attemptCount': attemptCount,
        if (errorCode != null) 'errorCode': errorCode,
        if (errorDetail != null) 'errorDetail': errorDetail,
        if (durationMs != null) 'durationMs': durationMs,
        if (byteLength != null) 'byteLength': byteLength,
        if (dialectCode != null) 'dialectCode': dialectCode,
        'dialectFallback': dialectFallback,
        if (codePageCode != null) 'codePageCode': codePageCode,
        'warnings': warnings,
        if (renderedText != null) 'renderedText': renderedText,
        'createdAt': createdAt.toUtc().toIso8601String(),
      };

  PrintLogRow copyWith({
    String? outcome,
    int? attemptCount,
    String? errorCode,
    String? errorDetail,
    int? durationMs,
    int? byteLength,
    List<String>? warnings,
    String? renderedText,
    String? uploadState,
    int? uploadAttempts,
    String? lastUploadError,
    DateTime? sentAt,
    bool clearError = false,
  }) =>
      PrintLogRow(
        clientLogId: clientLogId,
        ticketType: ticketType,
        receiptId: receiptId,
        orderId: orderId,
        printerId: printerId,
        printerName: printerName,
        printerTransport: printerTransport,
        outcome: outcome ?? this.outcome,
        attemptCount: attemptCount ?? this.attemptCount,
        errorCode: clearError && outcome != null ? null : (errorCode ?? this.errorCode),
        errorDetail: clearError && outcome != null ? null : (errorDetail ?? this.errorDetail),
        durationMs: durationMs ?? this.durationMs,
        byteLength: byteLength ?? this.byteLength,
        dialectCode: dialectCode,
        dialectFallback: dialectFallback,
        codePageCode: codePageCode,
        warnings: warnings ?? this.warnings,
        renderedText: renderedText ?? this.renderedText,
        createdAt: createdAt,
        uploadState: uploadState ?? this.uploadState,
        uploadAttempts: uploadAttempts ?? this.uploadAttempts,
        lastUploadError: lastUploadError ?? this.lastUploadError,
        sentAt: sentAt ?? this.sentAt,
      );
}

/// Filters for the diagnostics list.
class PrintLogFilter {
  const PrintLogFilter({this.outcome, this.ticketType, this.since});

  final String? outcome;
  final String? ticketType;
  final DateTime? since;
}

abstract class PrintLogStore {
  /// Insert the pre-attempt row (crash evidence). Idempotent on clientLogId.
  Future<void> insert(PrintLogRow row);

  /// Finalize an attempt's outcome.
  Future<void> finish(
    String clientLogId, {
    required String outcome,
    required int attemptCount,
    String? errorCode,
    String? errorDetail,
    int? durationMs,
    int? byteLength,
    List<String>? warnings,
    String? renderedText,
  });

  /// Newest-first, filtered.
  Future<List<PrintLogRow>> list({PrintLogFilter? filter, int? limit});

  /// Per-outcome counts (OK / FALLBACK / FAILED).
  Future<Map<String, int>> outcomeCounts();

  /// Rows not yet accepted by the server (oldest first), capped by [limit].
  Future<List<PrintLogRow>> dueForUpload({int limit});

  Future<int> pendingUploadCount();

  Future<int> totalCount();

  Future<void> markSent(List<String> clientLogIds, {DateTime? at});

  Future<void> markFailed(List<String> clientLogIds, String error);

  /// Prune ONLY already-uploaded rows. Never deletes pending/failed rows.
  /// Rule: a `sent` row is dropped when it is older than [maxAge] OR when it
  /// falls outside the newest [maxRows] rows. Returns the number deleted.
  Future<int> pruneUploaded({required int maxRows, required Duration maxAge});
}

// ---------------------------------------------------------------------------
// In-memory impl (tests + fallback when sqflite/platform is unavailable).
// ---------------------------------------------------------------------------

class MemoryPrintLogStore implements PrintLogStore {
  MemoryPrintLogStore({DateTime Function()? now}) : _now = now ?? DateTime.now;

  final DateTime Function() _now;
  final List<PrintLogRow> _rows = [];

  @override
  Future<void> insert(PrintLogRow row) async {
    // Idempotent on clientLogId: a replayed insert never duplicates a row.
    final i = _rows.indexWhere((r) => r.clientLogId == row.clientLogId);
    if (i >= 0) {
      _rows[i] = row;
    } else {
      _rows.add(row);
    }
  }

  @override
  Future<void> finish(
    String clientLogId, {
    required String outcome,
    required int attemptCount,
    String? errorCode,
    String? errorDetail,
    int? durationMs,
    int? byteLength,
    List<String>? warnings,
    String? renderedText,
  }) async {
    final i = _rows.indexWhere((r) => r.clientLogId == clientLogId);
    if (i < 0) return;
    _rows[i] = _rows[i].copyWith(
      outcome: outcome,
      attemptCount: attemptCount,
      errorCode: errorCode,
      errorDetail: errorDetail,
      durationMs: durationMs,
      byteLength: byteLength,
      warnings: warnings,
      renderedText: renderedText,
      clearError: outcome == 'OK',
    );
  }

  @override
  Future<List<PrintLogRow>> list({PrintLogFilter? filter, int? limit}) async {
    final f = filter ?? const PrintLogFilter();
    var out = _rows.where((r) {
      if (f.outcome != null && r.outcome != f.outcome) return false;
      if (f.ticketType != null && r.ticketType != f.ticketType) return false;
      if (f.since != null && r.createdAt.isBefore(f.since!)) return false;
      return true;
    }).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    if (limit != null && out.length > limit) out = out.sublist(0, limit);
    return out;
  }

  @override
  Future<Map<String, int>> outcomeCounts() async {
    final m = <String, int>{};
    for (final r in _rows) {
      m[r.outcome] = (m[r.outcome] ?? 0) + 1;
    }
    return m;
  }

  @override
  Future<List<PrintLogRow>> dueForUpload({int limit = 50}) async {
    final out = _rows.where((r) => r.uploadState != kPrintLogSent).toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return out.length > limit ? out.sublist(0, limit) : out;
  }

  @override
  Future<int> pendingUploadCount() async =>
      _rows.where((r) => r.uploadState != kPrintLogSent).length;

  @override
  Future<int> totalCount() async => _rows.length;

  @override
  Future<void> markSent(List<String> clientLogIds, {DateTime? at}) async {
    final ids = clientLogIds.toSet();
    for (var i = 0; i < _rows.length; i++) {
      if (ids.contains(_rows[i].clientLogId)) {
        _rows[i] = _rows[i].copyWith(
          uploadState: kPrintLogSent,
          sentAt: (at ?? _now()),
          uploadAttempts: _rows[i].uploadAttempts + 1,
        );
      }
    }
  }

  @override
  Future<void> markFailed(List<String> clientLogIds, String error) async {
    final ids = clientLogIds.toSet();
    for (var i = 0; i < _rows.length; i++) {
      if (ids.contains(_rows[i].clientLogId)) {
        _rows[i] = _rows[i].copyWith(
          uploadState: kPrintLogFailed,
          lastUploadError: error,
          uploadAttempts: _rows[i].uploadAttempts + 1,
        );
      }
    }
  }

  @override
  Future<int> pruneUploaded({required int maxRows, required Duration maxAge}) async {
    final cutoff = _now().subtract(maxAge);
    var removed = _rows.removeWhereCount(
      (r) => r.uploaded && (r.createdAt.isBefore(cutoff) || r.sentAt?.isBefore(cutoff) == true),
    );
    // Row-count cap: drop the oldest UPLOADED rows beyond the cap; unsent rows
    // are always kept.
    final newestFirst = _rows.toList()..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final keep = newestFirst.take(maxRows).map((r) => r.clientLogId).toSet();
    removed += _rows.removeWhereCount((r) => r.uploaded && !keep.contains(r.clientLogId));
    return removed;
  }
}

extension _RemoveWhereCount<T> on List<T> {
  int removeWhereCount(bool Function(T) test) {
    final before = length;
    removeWhere(test);
    return before - length;
  }
}

// ---------------------------------------------------------------------------
// sqflite impl (persist across restarts).
// ---------------------------------------------------------------------------

class SqlitePrintLogStore implements PrintLogStore {
  SqlitePrintLogStore({required LocalDb localDb, String? path, Future<String> Function()? pathProvider, bool inMemory = false})
      : _localDb = localDb,
        _path = path,
        _pathProvider = pathProvider,
        _inMemory = inMemory;

  final LocalDb _localDb;
  final String? _path;
  final Future<String> Function()? _pathProvider;
  final bool _inMemory;

  sqf.Database? _db;
  MemoryPrintLogStore? _fallback;

  final DateTime Function() _now = DateTime.now;

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

  /// Fall back to memory (unavailable platform channel / no path).
  MemoryPrintLogStore get _mem => _fallback ??= MemoryPrintLogStore(now: _now);

  @override
  Future<void> insert(PrintLogRow row) async {
    try {
      final db = await _open();
      await db.rawInsert(
          'INSERT OR REPLACE INTO print_log (client_log_id, ticket_type, receipt_id, order_id, printer_id, printer_name, '
          'printer_transport, outcome, attempt_count, error_code, error_detail, duration_ms, byte_length, dialect_code, '
          'dialect_fallback, code_page_code, warnings_json, rendered_text, created_at, upload_state, upload_attempts, '
          'last_upload_error, sent_at) '
          'VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
          [
            row.clientLogId, row.ticketType, row.receiptId, row.orderId, row.printerId, row.printerName,
            row.printerTransport, row.outcome, row.attemptCount, row.errorCode, row.errorDetail, row.durationMs,
            row.byteLength, row.dialectCode, row.dialectFallback ? 1 : 0, row.codePageCode,
            jsonEncode(row.warnings), row.renderedText, row.createdAt.millisecondsSinceEpoch, row.uploadState,
            row.uploadAttempts, row.lastUploadError, row.sentAt?.millisecondsSinceEpoch,
          ]);
    } catch (_) {
      await _mem.insert(row);
    }
  }

  @override
  Future<void> finish(
    String clientLogId, {
    required String outcome,
    required int attemptCount,
    String? errorCode,
    String? errorDetail,
    int? durationMs,
    int? byteLength,
    List<String>? warnings,
    String? renderedText,
  }) async {
    final clearError = outcome == 'OK';
    try {
      final db = await _open();
      await db.rawUpdate(
          'UPDATE print_log SET outcome = ?, attempt_count = ?, error_code = ?, error_detail = ?, duration_ms = ?, '
          'byte_length = ?, warnings_json = ?, rendered_text = ? WHERE client_log_id = ?',
          [
            outcome, attemptCount, clearError ? null : errorCode, clearError ? null : errorDetail, durationMs,
            byteLength, warnings == null ? null : jsonEncode(warnings), renderedText, clientLogId,
          ]);
    } catch (_) {
      await _mem.finish(clientLogId,
          outcome: outcome,
          attemptCount: attemptCount,
          errorCode: errorCode,
          errorDetail: errorDetail,
          durationMs: durationMs,
          byteLength: byteLength,
          warnings: warnings,
          renderedText: renderedText);
    }
  }

  @override
  Future<List<PrintLogRow>> list({PrintLogFilter? filter, int? limit}) async {
    final f = filter ?? const PrintLogFilter();
    try {
      final db = await _open();
      final where = <String>[];
      final args = <Object?>[];
      if (f.outcome != null) {
        where.add('outcome = ?');
        args.add(f.outcome);
      }
      if (f.ticketType != null) {
        where.add('ticket_type = ?');
        args.add(f.ticketType);
      }
      if (f.since != null) {
        where.add('created_at >= ?');
        args.add(f.since!.millisecondsSinceEpoch);
      }
      final rows = await db.rawQuery(
          'SELECT * FROM print_log ${where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}'} '
          'ORDER BY created_at DESC, id DESC ${limit != null ? 'LIMIT $limit' : ''}',
          args);
      return rows.map(_fromRow).toList();
    } catch (_) {
      return _mem.list(filter: filter, limit: limit);
    }
  }

  @override
  Future<Map<String, int>> outcomeCounts() async {
    try {
      final db = await _open();
      final rows = await db.rawQuery('SELECT outcome, COUNT(*) AS n FROM print_log GROUP BY outcome');
      return {for (final r in rows) (r['outcome'] as String): ((r['n'] as num?)?.toInt() ?? 0)};
    } catch (_) {
      return _mem.outcomeCounts();
    }
  }

  @override
  Future<List<PrintLogRow>> dueForUpload({int limit = 50}) async {
    try {
      final db = await _open();
      final rows = await db.rawQuery(
          "SELECT * FROM print_log WHERE upload_state != '$kPrintLogSent' ORDER BY created_at ASC, id ASC LIMIT $limit");
      return rows.map(_fromRow).toList();
    } catch (_) {
      return _mem.dueForUpload(limit: limit);
    }
  }

  @override
  Future<int> pendingUploadCount() async {
    try {
      final db = await _open();
      final rows = await db.rawQuery("SELECT COUNT(*) AS n FROM print_log WHERE upload_state != '$kPrintLogSent'");
      return ((rows.first['n'] as num?)?.toInt()) ?? 0;
    } catch (_) {
      return _mem.pendingUploadCount();
    }
  }

  @override
  Future<int> totalCount() async {
    try {
      final db = await _open();
      final rows = await db.rawQuery('SELECT COUNT(*) AS n FROM print_log');
      return ((rows.first['n'] as num?)?.toInt()) ?? 0;
    } catch (_) {
      return _mem.totalCount();
    }
  }

  @override
  Future<void> markSent(List<String> clientLogIds, {DateTime? at}) async {
    if (clientLogIds.isEmpty) return;
    try {
      final db = await _open();
      final atMs = (at ?? _now()).millisecondsSinceEpoch;
      final marks = List.filled(clientLogIds.length, '?').join(',');
      await db.rawUpdate(
          "UPDATE print_log SET upload_state = '$kPrintLogSent', sent_at = ?, upload_attempts = upload_attempts + 1 "
          'WHERE client_log_id IN ($marks)',
          [atMs, ...clientLogIds]);
    } catch (_) {
      await _mem.markSent(clientLogIds, at: at);
    }
  }

  @override
  Future<void> markFailed(List<String> clientLogIds, String error) async {
    if (clientLogIds.isEmpty) return;
    try {
      final db = await _open();
      final marks = List.filled(clientLogIds.length, '?').join(',');
      await db.rawUpdate(
          "UPDATE print_log SET upload_state = '$kPrintLogFailed', last_upload_error = ?, "
          'upload_attempts = upload_attempts + 1 WHERE client_log_id IN ($marks)',
          [error, ...clientLogIds]);
    } catch (_) {
      await _mem.markFailed(clientLogIds, error);
    }
  }

  @override
  Future<int> pruneUploaded({required int maxRows, required Duration maxAge}) async {
    try {
      final db = await _open();
      final cutoff = _now().subtract(maxAge).millisecondsSinceEpoch;
      // Age rule (sent rows only).
      var removed = await db.rawDelete(
          "DELETE FROM print_log WHERE upload_state = '$kPrintLogSent' AND (created_at < ? OR sent_at < ?)",
          [cutoff, cutoff]);
      // Row-count rule: drop the oldest SENT rows beyond the cap; keep every
      // unsent row regardless (never lose evidence that has not shipped).
      final doomed = await db.rawQuery(
          "SELECT client_log_id FROM print_log WHERE upload_state = '$kPrintLogSent' AND client_log_id NOT IN "
          '(SELECT client_log_id FROM print_log ORDER BY created_at DESC, id DESC LIMIT ?)',
          [maxRows]);
      if (doomed.isNotEmpty) {
        removed += await db.rawDelete(
            'DELETE FROM print_log WHERE client_log_id IN (${List.filled(doomed.length, '?').join(',')})',
            [for (final r in doomed) r['client_log_id']]);
      }
      return removed;
    } catch (_) {
      return _mem.pruneUploaded(maxRows: maxRows, maxAge: maxAge);
    }
  }

  PrintLogRow _fromRow(Map<String, Object?> r) => PrintLogRow(
        clientLogId: r['client_log_id'] as String,
        ticketType: r['ticket_type'] as String,
        receiptId: r['receipt_id'] as String?,
        orderId: r['order_id'] as String?,
        printerId: r['printer_id'] as String?,
        printerName: r['printer_name'] as String?,
        printerTransport: r['printer_transport'] as String?,
        outcome: (r['outcome'] as String?) ?? 'FAILED',
        attemptCount: ((r['attempt_count'] as num?)?.toInt()) ?? 0,
        errorCode: r['error_code'] as String?,
        errorDetail: r['error_detail'] as String?,
        durationMs: (r['duration_ms'] as num?)?.toInt(),
        byteLength: (r['byte_length'] as num?)?.toInt(),
        dialectCode: r['dialect_code'] as String?,
        dialectFallback: ((r['dialect_fallback'] as num?)?.toInt() ?? 0) != 0,
        codePageCode: r['code_page_code'] as String?,
        warnings: _decodeWarnings(r['warnings_json']),
        renderedText: r['rendered_text'] as String?,
        createdAt: DateTime.fromMillisecondsSinceEpoch(((r['created_at'] as num?)?.toInt()) ?? 0),
        uploadState: (r['upload_state'] as String?) ?? kPrintLogPending,
        uploadAttempts: ((r['upload_attempts'] as num?)?.toInt()) ?? 0,
        lastUploadError: r['last_upload_error'] as String?,
        sentAt: r['sent_at'] == null ? null : DateTime.fromMillisecondsSinceEpoch((r['sent_at'] as num).toInt()),
      );

  static List<String> _decodeWarnings(Object? raw) {
    if (raw is! String || raw.isEmpty) return const [];
    try {
      final d = jsonDecode(raw);
      return d is List ? [for (final e in d) e.toString()] : const [];
    } catch (_) {
      return const [];
    }
  }
}
