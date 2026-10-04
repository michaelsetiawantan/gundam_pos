import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gundam_pos/api/api_client.dart';
import 'package:gundam_pos/api/pos_api.dart';
import 'package:gundam_pos/data/pos_store.dart';
import 'package:gundam_pos/data/print_log_store.dart';
import 'package:gundam_pos/services/diagnostic_report.dart';
import 'package:gundam_pos/services/print_log.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

PrintLogRow _row({String id = 'plog-1', String outcome = 'FAILED', String? err}) => PrintLogRow(
      clientLogId: id,
      ticketType: 'BILL',
      outcome: outcome,
      errorCode: err,
      attemptCount: 2,
      createdAt: DateTime.utc(2026, 1, 2, 3, 4, 5),
    );

Map<String, dynamic> _bundle() => buildDiagnosticBundle(
      clientReportId: 'diag-test-1',
      generatedAt: DateTime.utc(2026, 1, 2, 3, 4, 5),
      description: 'kitchen printer blank',
      appVersionName: '0.3.3',
      appVersionCode: 6,
      schemaVersion: 3,
      deviceId: 'dev-1',
      shortcode: 'POS-01',
      tenantId: 'ten-1',
      recentPrintRows: [_row()],
      printOutcomeCounts: const {'OK': 3, 'FALLBACK': 1, 'FAILED': 2},
      printTotal: 6,
      printPendingUpload: 1,
      logLines: [_log('error', 'print', 'timeout after 20s')],
    );

LogLine _log(String level, String tag, String msg) =>
    LogLine(at: DateTime.utc(2026, 1, 2, 3, 4, 5), level: level, tag: tag, message: msg);

/// A tiny fake API whose behaviour flips with [online].
PosApi _api(bool Function() online, {List<Map<String, dynamic>>? captured}) => PosApi(
      ApiClient(
        baseUrl: 'http://fake.test',
        httpClient: MockClient((req) async {
          if (!online()) throw Exception('offline');
          if (captured != null) captured.add(jsonDecode(req.body) as Map<String, dynamic>);
          return http.Response(jsonEncode({'accepted': true, 'alreadySeen': false}),
              200, headers: {'content-type': 'application/json'});
        }),
      ),
    );

void main() {
  group('DiagnosticLog ring buffer', () {
    test('caps at capacity and keeps the NEWEST lines', () {
      final log = DiagnosticLog(capacity: 3);
      for (var i = 1; i <= 5; i++) {
        log.info('t', 'line $i');
      }
      final snap = log.snapshot();
      expect(snap, hasLength(3));
      expect(snap.first.message, 'line 3');
      expect(snap.last.message, 'line 5');
    });
  });

  group('buildDiagnosticBundle', () {
    test('carries app version, print summary counts and log analysis', () {
      final log = DiagnosticLog()
        ..info('boot', 'app started')
        ..error('print', 'timeout after 20s');
      final b = buildDiagnosticBundle(
        clientReportId: 'diag-x',
        generatedAt: DateTime.utc(2026, 1, 2),
        description: 'note',
        appVersionName: '0.3.3',
        appVersionCode: 6,
        schemaVersion: 3,
        recentPrintRows: [_row()],
        printOutcomeCounts: const {'OK': 3, 'FALLBACK': 1, 'FAILED': 2},
        printTotal: 6,
        printPendingUpload: 1,
        logLines: log.snapshot(),
      );

      expect((b['appVersion'] as Map)['name'], '0.3.3');
      expect((b['appVersion'] as Map)['code'], 6);
      expect((b['appVersion'] as Map)['schema'], 3);
      final ps = b['printSummary'] as Map;
      expect(ps['ok'], 3);
      expect(ps['fallback'], 1);
      expect(ps['failed'], 2);
      expect(ps['total'], 6);
      expect((b['logLevelCounts'] as Map)['error'], 1);
      expect(b['errorLineCount'], 1); // the "timeout" info line also counts
    });

    test('does not crash on empty data and caps the description + row list', () {
      final b = buildDiagnosticBundle(
        clientReportId: 'diag-empty',
        generatedAt: DateTime.utc(2026, 1, 2),
        description: 'x' * (kDiagMaxDescriptionLen + 50),
        appVersionName: '0.0.0',
        appVersionCode: 0,
        schemaVersion: 3,
      );
      expect((b['recentPrintRows'] as List), isEmpty);
      expect((b['logLines'] as List), isEmpty);
      expect(b['errorLineCount'], 0);
      expect((b['printSummary'] as Map)['total'], 0);
      expect((b['description'] as String).length, lessThanOrEqualTo(kDiagMaxDescriptionLen + 16));

      final many = buildDiagnosticBundle(
        clientReportId: 'diag-many',
        generatedAt: DateTime.utc(2026, 1, 2),
        description: 'n',
        appVersionName: '0.0.0',
        appVersionCode: 0,
        schemaVersion: 3,
        recentPrintRows: [for (var i = 0; i < kDiagMaxRecentPrintRows + 10; i++) _row(id: 'r$i')],
      );
      expect((many['recentPrintRows'] as List), hasLength(kDiagMaxRecentPrintRows));
    });
  });

  group('DiagnosticReporter offline outbox', () {
    test('queues while offline and flushes + removes on the next sync', () async {
      final push = MemoryPushStore();
      var online = false;
      final api = _api(() => online);
      final reporter = DiagnosticReporter(api: api, push: push);

      // Offline: submit enqueues, upload fails → stays queued, nothing lost.
      final res = await reporter.submit(bundle: _bundle(), tenantId: 'ten-1', assetId: 'asset-1');
      expect(res.sent, 0);
      expect(res.queued, isTrue);
      expect(res.pending, 1);
      expect(await reporter.pendingCount(), 1);

      // Back online: the next sync flushes it and drops it from the queue.
      online = true;
      final sent = await reporter.flush(tenantId: 'ten-1', assetId: 'asset-1');
      expect(sent, 1);
      expect(await reporter.pendingCount(), 0);
    });

    test('posts the bundle to /api/pos/diagnostics with the operator description', () async {
      final push = MemoryPushStore();
      final captured = <Map<String, dynamic>>[];
      final reporter = DiagnosticReporter(api: _api(() => true, captured: captured), push: push);

      final res = await reporter.submit(bundle: _bundle(), tenantId: 'ten-1', assetId: 'asset-1');
      expect(res.sent, 1);
      expect(captured, hasLength(1));
      final report = captured.single['report'] as Map<String, dynamic>;
      expect(report['description'], 'kitchen printer blank');
      expect(report['clientReportId'], 'diag-test-1');
    });
  });

  group('print-log upload retry — honest, non-poisoning', () {
    test('a healthy 2-row upload drains the queue to zero', () async {
      final store = MemoryPrintLogStore();
      await store.insert(_uploadRow('a'));
      await store.insert(_uploadRow('b'));
      final uploader = PrintLogUploader(api: _printApi((_) => {'accepted': 2, 'alreadySeen': 0, 'rejected': 0, 'errors': []}), store: store);

      final res = await uploader.uploadPending(tenantId: 't1', assetId: 'dev-1');
      expect(res.uploaded, 2);
      expect(res.failed, 0);
      expect(res.remaining, 0);
      expect(res.offline, isFalse);
      expect(await store.pendingUploadCount(), 0);
    });

    test('one rejected row does NOT sink a 2-row batch (regression: retry used to error forever)', () async {
      // The real server rejects per row and names it in `errors[]`. The old
      // client saw only the `rejected` COUNT and marked the WHOLE batch failed,
      // so the accepted row stayed pending and every Retry reported 0 uploaded.
      final store = MemoryPrintLogStore();
      await store.insert(_uploadRow('bad')); // oldest first
      await store.insert(_uploadRow('good'));
      final uploader = PrintLogUploader(api: _printApi((_) => {
            'accepted': 1,
            'alreadySeen': 0,
            'rejected': 1,
            'errors': [
              {'index': 0, 'clientLogId': 'bad', 'error': 'invalid_printer'},
            ],
          }), store: store);

      final res = await uploader.uploadPending(tenantId: 't1', assetId: 'dev-1');
      expect(res.uploaded, 1); // the good row still shipped
      expect(res.failed, 1); // the bad row is reported, not silent
      expect(res.remaining, 1); // ...and kept (never discarded)
      expect(res.rejectedCodes, ['invalid_printer']); // reason surfaced
      final byId = {for (final r in await store.list()) r.clientLogId: r.uploadState};
      expect(byId['good'], kPrintLogSent);
      expect(byId['bad'], isNot(kPrintLogSent));
    });

    test('an unreachable server is reported as offline, keeping every row', () async {
      final store = MemoryPrintLogStore();
      await store.insert(_uploadRow('a'));
      await store.insert(_uploadRow('b'));
      final uploader = PrintLogUploader(
        api: _printApi((_) => throw Exception('no network')),
        store: store,
      );

      final res = await uploader.uploadPending(tenantId: 't1', assetId: 'dev-1');
      expect(res.offline, isTrue);
      expect(res.uploaded, 0);
      expect(res.remaining, 2); // nothing lost
      expect(await store.pendingUploadCount(), 2);
    });

    test('drains more than one batch in a single pass', () async {
      final store = MemoryPrintLogStore();
      for (var i = 0; i < 5; i++) {
        await store.insert(_uploadRow('r$i'));
      }
      final uploader = PrintLogUploader(
        batchSize: 2,
        api: _printApi((_) => {'accepted': 2, 'alreadySeen': 0, 'rejected': 0, 'errors': []}),
        store: store,
      );

      final res = await uploader.uploadPending(tenantId: 't1', assetId: 'dev-1');
      expect(res.uploaded, 5);
      expect(res.remaining, 0);
    });
  });
}

// ---------------------------------------------------------------------------
// print-log upload fixtures
// ---------------------------------------------------------------------------

PrintLogRow _uploadRow(String id) => PrintLogRow(
      clientLogId: id,
      ticketType: 'BILL',
      outcome: 'FAILED',
      attemptCount: 1,
      createdAt: DateTime.utc(2026, 1, 2, 3, 4, 5),
    );

/// A PosApi whose /api/pos/print-logs response is produced by [handler]; a
/// thrown exception models an unreachable server.
PosApi _printApi(Map<String, dynamic> Function(http.Request req) handler) => PosApi(
      ApiClient(
        baseUrl: 'http://fake.test',
        httpClient: MockClient((req) async {
          final body = handler(req);
          return http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json'});
        }),
      ),
    );
