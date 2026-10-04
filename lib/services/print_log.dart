/// Print-attempt audit at the real print path + upload to the server.
///
/// The dispatcher calls [PrintLogAudit.begin] BEFORE handing a job to the queue
/// (so a crash mid-print still leaves a row) and finalizes the outcome after.
/// Failures, fallbacks and successes are all recorded; `renderedText` is only
/// retained for FAILED / FALLBACK (bounded), never for OK.
///
/// [PrintLogUploader] ships pending rows in id-keyed batches to
/// `POST /api/pos/print-logs`. Idempotent: each row carries a stable
/// `clientLogId` the server dedupes on, so a re-upload after a crash can never
/// duplicate server-side.
library;

import 'dart:async';
import 'dart:math';

import 'package:gundam_pos/api/api_client.dart';
import 'package:gundam_pos/api/pos_api.dart';
import 'package:gundam_pos/data/print_log_store.dart';
import 'package:gundam_pos/services/bluetooth_print_transport.dart';
import 'package:gundam_pos/services/escpos.dart';
import 'package:gundam_pos/services/print_routing.dart';
import 'package:gundam_pos/services/usb_print_transport.dart';

// ---------------------------------------------------------------------------
// Caps — the ONE place local retention/batching is configured.
// ---------------------------------------------------------------------------

/// Retained local rows (newest-first). Unsent rows are always kept past this.
const int kPrintLogMaxRows = 500;

/// Retained age for already-uploaded rows.
const Duration kPrintLogMaxAge = Duration(days: 14);

/// Rows per upload request.
const int kPrintLogUploadBatchSize = 50;

/// Bounded rendered text stored for FAILED / FALLBACK rows (~4 KB).
const int kPrintLogRenderedTextCap = 4096;

const String kOutcomeOk = 'OK';
const String kOutcomeFallback = 'FALLBACK';
const String kOutcomeFailed = 'FAILED';

/// The three outcomes the server understands.
const List<String> kPrintOutcomes = [kOutcomeOk, kOutcomeFallback, kOutcomeFailed];

String boundRenderedText(List<String> lines) {
  final text = lines.join('\n');
  if (text.length <= kPrintLogRenderedTextCap) return text;
  return '${text.substring(0, kPrintLogRenderedTextCap)}\n…[truncated at $kPrintLogRenderedTextCap chars]';
}

final _rand = Random();
String _defaultClientLogId(DateTime now) =>
    'plog-${now.microsecondsSinceEpoch}-${_rand.nextInt(1 << 32).toRadixString(16)}';

/// Typed error code for a transport fault, without leaking a stack trace.
String printErrorCode(Object error) {
  if (error is BluetoothPrintException) return 'bluetooth_${error.state.name}';
  if (error is UsbChipMismatchException) return 'usb_chip_mismatch';
  if (error is UsbPrintException) return 'usb_${error.state.name}';
  if (error is UnsupportedError) return 'unsupported_transport';
  if (error is TimeoutException || error.toString().contains('TimeoutException')) return 'timeout';
  return 'print_failed';
}

/// A begun attempt, finalized after the transport call.
class PrintAttempt {
  PrintAttempt._({
    required this.store,
    required this.clientLogId,
    required this.ticketType,
    required this.renderedLines,
    required this.encoderWarnings,
    required this.fallback,
    required this.byteLength,
    required this.createdAt,
    required this.startedAtMs,
  });

  final PrintLogStore store;
  final String clientLogId;
  final String ticketType;
  final List<String> renderedLines;
  final List<String> encoderWarnings;

  /// A fallback was observed (dialect/code-page/QR/barcode/image/format) — a
  /// transported-but-downgraded print is FALLBACK, not OK.
  final bool fallback;
  final int byteLength;
  final DateTime createdAt;
  final int startedAtMs;

  int get _durationMs {
    final d = DateTime.now().millisecondsSinceEpoch - startedAtMs;
    return d < 0 ? 0 : d;
  }

  Future<void> completeOk({int attemptCount = 1}) =>
      _finish(kOutcomeOk, attemptCount: attemptCount, errorCode: null, errorDetail: null, extraWarnings: const []);

  Future<void> completeFallback({
    int attemptCount = 1,
    List<String> extraWarnings = const [],
    String? errorCode,
    String? errorDetail,
  }) =>
      _finish(kOutcomeFallback,
          attemptCount: attemptCount,
          errorCode: errorCode ?? 'fallback',
          errorDetail: errorDetail ?? extraWarnings.join(' '),
          extraWarnings: extraWarnings);

  Future<void> completeFailed({
    required int attemptCount,
    required String errorCode,
    required String errorDetail,
  }) =>
      _finish(kOutcomeFailed, attemptCount: attemptCount, errorCode: errorCode, errorDetail: errorDetail, extraWarnings: const []);

  Future<void> _finish(
    String outcome, {
    required int attemptCount,
    required String? errorCode,
    required String? errorDetail,
    required List<String> extraWarnings,
  }) async {
    final warnings = [...encoderWarnings, ...extraWarnings];
    await store.finish(
      clientLogId,
      outcome: outcome,
      attemptCount: attemptCount,
      errorCode: errorCode,
      errorDetail: errorDetail,
      durationMs: _durationMs,
      byteLength: byteLength,
      warnings: warnings,
      // Only FAILED / FALLBACK keep the receipt text; OK stays metadata-only.
      renderedText: outcome == kOutcomeOk ? null : boundRenderedText(renderedLines),
    );
  }
}

/// Creates the audit rows. A null audit (no store wired) means no logging.
class PrintLogAudit {
  PrintLogAudit({required this.store, DateTime Function()? now, String Function(DateTime)? idFactory})
      : _now = now ?? DateTime.now,
        _idFactory = idFactory ?? _defaultClientLogId;

  final PrintLogStore store;
  final DateTime Function() _now;
  final String Function(DateTime) _idFactory;

  /// Insert the pre-attempt row, then return a handle to finalize it. Called
  /// BEFORE the transport is invoked so a crash still leaves evidence.
  Future<PrintAttempt> begin({
    required String ticketType,
    required ClientPrinter printer,
    required EscPosEncode encode,
    required List<String> renderedLines,
    bool usedFormat = true,
    String? formatFallbackReason,
    String? receiptId,
    String? orderId,
  }) async {
    final now = _now();
    final id = _idFactory(now);
    final dialectFallback = !encode.dialectImplemented || !encode.dialectKnown;
    final codePageFallback = !(encode.codePageKnown && encode.codePageSupportedByDialect);
    final warnings = [
      ...encode.warnings,
      if (!usedFormat && formatFallbackReason != null) 'built-in layout used: $formatFallbackReason',
    ];
    final fallback = dialectFallback ||
        codePageFallback ||
        encode.qrFallbacks > 0 ||
        encode.barcodeFallbacks > 0 ||
        encode.skippedImages > 0;

    await store.insert(PrintLogRow(
      clientLogId: id,
      ticketType: ticketType,
      receiptId: receiptId,
      orderId: orderId,
      printerId: printer.id,
      printerName: printer.name,
      printerTransport: printer.transport,
      // Pre-attempt state: if the process dies before completion this row stays
      // `FAILED` / `incomplete` — the honest record that the print never landed.
      outcome: kOutcomeFailed,
      attemptCount: 0,
      errorCode: 'incomplete',
      errorDetail: 'print attempt did not complete (in flight when recorded)',
      byteLength: encode.bytes.length,
      dialectCode: encode.dialect,
      dialectFallback: dialectFallback,
      codePageCode: encode.codePage,
      warnings: warnings,
      renderedText: null,
      createdAt: now,
      uploadState: kPrintLogPending,
    ));

    return PrintAttempt._(
      store: store,
      clientLogId: id,
      ticketType: ticketType,
      renderedLines: renderedLines,
      encoderWarnings: warnings,
      fallback: fallback,
      byteLength: encode.bytes.length,
      createdAt: now,
      startedAtMs: now.millisecondsSinceEpoch,
    );
  }

  /// Record a fallback that never reached a transport (no printer configured,
  /// unsupported transport). Creates a complete row in one step.
  Future<void> recordFallback({
    required String ticketType,
    String? printerId,
    String? printerName,
    String? printerTransport,
    required String errorCode,
    required List<String> warnings,
    List<String> renderedLines = const [],
    String? receiptId,
    String? orderId,
  }) async {
    final now = _now();
    await store.insert(PrintLogRow(
      clientLogId: _idFactory(now),
      ticketType: ticketType,
      receiptId: receiptId,
      orderId: orderId,
      printerId: printerId,
      printerName: printerName,
      printerTransport: printerTransport,
      outcome: kOutcomeFallback,
      attemptCount: 0,
      errorCode: errorCode,
      errorDetail: warnings.join(' '),
      warnings: warnings,
      renderedText: renderedLines.isEmpty ? null : boundRenderedText(renderedLines),
      createdAt: now,
      uploadState: kPrintLogPending,
    ));
  }
}

/// Outcome of one upload pass.
///
/// [uploaded] rows the server accepted (or had already seen), [failed] rows it
/// rejected, [remaining] rows still queued locally. [rejectedCodes] carries the
/// server's per-row error codes so the UI can say *why* instead of blaming the
/// printer. [offline] is true only when the request never reached the server —
/// distinct from a server that answered and rejected a row.
class PrintLogUploadResult {
  const PrintLogUploadResult({
    required this.uploaded,
    required this.failed,
    required this.remaining,
    this.rejectedCodes = const [],
    this.offline = false,
  });

  final int uploaded;
  final int failed;
  final int remaining;
  final List<String> rejectedCodes;
  final bool offline;

  bool get allUploaded => remaining == 0;
}

/// Uploads pending rows in batches. Never throws — a network outage leaves rows
/// pending for the next pass (nothing is lost).
class PrintLogUploader {
  PrintLogUploader({required this.api, required this.store, this.batchSize = kPrintLogUploadBatchSize});

  final PosApi api;
  final PrintLogStore store;
  final int batchSize;

  Future<PrintLogUploadResult> uploadPending({required String tenantId, required String assetId}) async {
    // Snapshot the whole backlog once, then ship it in id-keyed batches. A
    // snapshot (not a live query) means a row the server rejects is not
    // re-sent within the same pass — no loop.
    final rows = await store.dueForUpload(limit: _scanLimit);
    if (rows.isEmpty) return const PrintLogUploadResult(uploaded: 0, failed: 0, remaining: 0);

    var uploaded = 0;
    var failed = 0;
    var offline = false;
    final rejectedCodes = <String>{};

    for (var start = 0; start < rows.length; start += batchSize) {
      final batch = rows.sublist(start, min(start + batchSize, rows.length));
      final Map<String, dynamic> res;
      try {
        res = await api.postPrintLogs(
          tenantId: tenantId,
          assetId: assetId,
          logs: [for (final r in batch) r.toUploadJson()],
        );
      } catch (e) {
        // Two very different failures the operator must be able to tell apart:
        // the server ANSWERED and refused (e.g. asset_not_found — the reporting
        // identity was not recognised) vs we could not reach it at all. Calling
        // a server refusal "no network" sent people chasing the wrong problem.
        if (e is PosApiException) {
          rejectedCodes.add(e.code);
          await store.markFailed([for (final r in batch) r.clientLogId], '${e.status} ${e.code}');
          failed += batch.length;
          break;
        }
        offline = true;
        await store.markFailed([for (final r in batch) r.clientLogId], e.toString());
        failed += batch.length;
        break;
      }
      final parsed = _parse(res, batch);
      if (parsed.sent.isNotEmpty) await store.markSent(parsed.sent);
      if (parsed.rejected.isNotEmpty) {
        await store.markFailed(parsed.rejected, parsed.reason);
        rejectedCodes.addAll(parsed.codes);
      }
      uploaded += parsed.sent.length;
      failed += parsed.rejected.length;
    }

    return PrintLogUploadResult(
      uploaded: uploaded,
      failed: failed,
      remaining: await store.pendingUploadCount(),
      rejectedCodes: rejectedCodes.toList()..sort(),
      offline: offline,
    );
  }

  /// Tolerant response parse. The server answers per row: `accepted` /
  /// `alreadySeen` / `rejected` counts plus an `errors[]` list carrying the
  /// `clientLogId` and `error` code of each rejected row. A rejected row must
  /// NOT sink the whole batch — the accepted rows are marked sent, only the
  /// named rejects stay queued (with a reason). A response that lists ids
  /// directly (future shape) is honoured too.
  _ParsedUpload _parse(Map<String, dynamic> res, List<PrintLogRow> rows) {
    final rowIds = [for (final r in rows) r.clientLogId];
    final accepted = res['accepted'];
    final seen = res['alreadySeen'];
    final rejectedRaw = res['rejected'];

    final rejectedIds = <String>[];
    final codes = <String>[];
    final details = res['errors'];
    if (details is List) {
      for (final e in details) {
        if (e is! Map) continue;
        final id = e['clientLogId'];
        if (id is String && id.isNotEmpty && rowIds.contains(id)) rejectedIds.add(id);
        final code = e['error'];
        if (code is String && code.isNotEmpty) codes.add(code);
      }
    }

    final acceptedList = accepted is List ? _ids(accepted) : null;
    final seenList = seen is List ? _ids(seen) : null;
    final rejectedList = rejectedRaw is List ? _ids(rejectedRaw) : null;
    if (acceptedList != null || seenList != null || rejectedList != null) {
      final rejected = {...?rejectedList};
      final sent = [...?acceptedList, ...?seenList].where((id) => !rejected.contains(id)).toList();
      return _ParsedUpload(sent, rejected.toList(), codes, _reason(codes));
    }

    // Count-only summary.
    final rejCount = rejectedRaw is num ? rejectedRaw.toInt() : rejectedIds.length;
    if (rejCount == 0 && rejectedIds.isEmpty) {
      return _ParsedUpload(rowIds, const [], codes, _reason(codes));
    }
    // We know exactly which rows were rejected only when the server names them
    // in `errors[]`. Without that detail we cannot honestly mark any row sent,
    // so the whole batch stays queued (never silently discarded).
    final rejected = rejectedIds.isNotEmpty ? rejectedIds : rowIds;
    final rejectedSet = rejected.toSet();
    final sent = rowIds.where((id) => !rejectedSet.contains(id)).toList();
    return _ParsedUpload(sent, rejected, codes, _reason(codes));
  }

  static String _reason(List<String> codes) =>
      codes.isEmpty ? 'rejected by server' : 'rejected by server: ${codes.join(', ')}';

  static List<String> _ids(Object? v) {
    if (v is! List) return const [];
    return [for (final e in v) if (e is String && e.isNotEmpty) e];
  }

  static const int _scanLimit = 100000;
}

/// Internal parse result: the ids to mark sent / rejected plus the reason.
class _ParsedUpload {
  const _ParsedUpload(this.sent, this.rejected, this.codes, this.reason);

  final List<String> sent;
  final List<String> rejected;
  final List<String> codes;
  final String reason;
}
