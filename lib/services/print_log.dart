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
class PrintLogUploadResult {
  const PrintLogUploadResult({required this.uploaded, required this.failed, required this.remaining});

  final int uploaded;
  final int failed;
  final int remaining;

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
    final rows = await store.dueForUpload(limit: batchSize);
    if (rows.isEmpty) return const PrintLogUploadResult(uploaded: 0, failed: 0, remaining: 0);
    try {
      final res = await api.postPrintLogs(
        tenantId: tenantId,
        assetId: assetId,
        logs: [for (final r in rows) r.toUploadJson()],
      );
      final (sent, rejected) = _parse(res, rows);
      if (sent.isNotEmpty) await store.markSent(sent);
      if (rejected.isNotEmpty) await store.markFailed(rejected, 'rejected by server');
      final remaining = await store.pendingUploadCount();
      return PrintLogUploadResult(
        uploaded: sent.length,
        failed: rejected.length,
        remaining: remaining,
      );
    } catch (e) {
      // Offline / server error: keep every row pending for the next retry.
      await store.markFailed([for (final r in rows) r.clientLogId], e.toString());
      return PrintLogUploadResult(uploaded: 0, failed: rows.length, remaining: await store.pendingUploadCount());
    }
  }

  /// Tolerant response parse: honour per-log id lists when present, else treat a
  /// 2xx as accepting the whole id-keyed batch (the upload is idempotent, so a
  /// re-send is always safe).
  (List<String>, List<String>) _parse(Map<String, dynamic> res, List<PrintLogRow> rows) {
    final accepted = res['accepted'];
    final seen = res['alreadySeen'];
    final rejected = res['rejected'];
    final hasIdLists = accepted is List || seen is List || rejected is List;
    if (!hasIdLists) {
      // Count-only summary: acknowledge all when nothing was rejected.
      final rejCount = rejected is num ? rejected.toInt() : 0;
      if (rejCount > 0) return (const [], [for (final r in rows) r.clientLogId]);
      return ([for (final r in rows) r.clientLogId], const []);
    }
    final sent = <String>{..._ids(accepted), ..._ids(seen)};
    return (sent.toList(), _ids(rejected));
  }

  static List<String> _ids(Object? v) {
    if (v is! List) return const [];
    return [for (final e in v) if (e is String) e];
  }
}
