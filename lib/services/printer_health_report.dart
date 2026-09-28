/// Reports device-observed printer health to the server
/// (`POST /api/pos/printers/health`, web `app/api/pos/printers/health/route.ts`).
///
/// Body: `{ tenantId, assetId, checkedAt, reports: [{ printerId, status }] }`
/// where `status` is one of the PRD-defined labels (see
/// [printerHealthStatusName]). The Android POS is the only health source — the
/// cloud never probes a printer. Best-effort: any failure returns false rather
/// than throwing, so a health upload can never block a sale.
library;

import 'package:gundam_pos/api/api_client.dart';

class PrinterHealthReporter {
  PrinterHealthReporter({required this.client, DateTime Function()? now}) : _now = now ?? DateTime.now;

  final ApiClient client;
  final DateTime Function() _now;

  /// [statusesByPrinterId] maps a synced printer id to its PRD status label.
  /// Returns true when the server accepted the batch.
  Future<bool> report({
    required String tenantId,
    required String assetId,
    required Map<String, String> statusesByPrinterId,
    DateTime? checkedAt,
  }) async {
    if (statusesByPrinterId.isEmpty) return false;
    try {
      await client.post('/api/pos/printers/health', body: {
        'tenantId': tenantId,
        'assetId': assetId,
        'checkedAt': (checkedAt ?? _now()).toUtc().toIso8601String(),
        'reports': [
          for (final e in statusesByPrinterId.entries) {'printerId': e.key, 'status': e.value},
        ],
      });
      return true;
    } catch (_) {
      return false; // honest: the report did not land, but nothing is broken.
    }
  }
}
