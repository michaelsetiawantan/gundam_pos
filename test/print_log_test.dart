import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gundam_pos/api/api_client.dart';
import 'package:gundam_pos/api/pos_api.dart';
import 'package:gundam_pos/data/local_db.dart';
import 'package:gundam_pos/data/print_log_store.dart';
import 'package:gundam_pos/logic/money.dart' as money;
import 'package:gundam_pos/logic/print_payload.dart';
import 'package:gundam_pos/services/escpos.dart';
import 'package:gundam_pos/services/print_broker.dart';
import 'package:gundam_pos/services/print_log.dart';
import 'package:gundam_pos/services/print_routing.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/fake_backend.dart';
import 'support/print_support.dart';

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

PrintItem _item() => PrintItem(name: 'Nasi', itemId: 'item-nasi', qty: 1, unitPrice: 45000, batchIndex: 0);

money.MoneyFlow _flow() => money.computeMoneyFlow(
      [money.MoneyLine(subtotal: 45000, vatMode: money.VatScMode.exclude, vatRate: 11, scMode: money.VatScMode.none)],
      0,
      0,
      money.RoundingMode.none,
    );

money.SplitResult _split(money.MoneyFlow f) => money.finalizePayments(f.total, [
      money.PaymentInput(outletMethodId: 'pm-cash', type: money.PayType.cash, amount: f.total),
    ]);

Map<String, dynamic> _outlet({required List<Map<String, dynamic>> printers, Map<String, dynamic>? routing}) => {
      'printers': printers,
      'routing': routing ?? {'BILL': [for (final p in printers) {'printerId': p['id']}]},
    };

Future<PrintLogRow> _onlyRow(PrintLogStore store) async {
  final rows = await store.list();
  expect(rows, hasLength(1));
  return rows.single;
}

void main() {
  group('print_log schema migration', () {
    test('replaying the migration set twice is a no-op (idempotent)', () {
      // Every step must be IF NOT EXISTS-guarded, so a second pass creates and
      // alters nothing.
      final once = migrationUpStatements(schemaVersion);
      for (final stmt in once) {
        if (stmt.trimLeft().toUpperCase().startsWith('CREATE')) {
          expect(stmt.toUpperCase(), contains('IF NOT EXISTS'), reason: stmt);
        }
      }
      final tablesFirst = _tables(once);
      final tablesSecond = _tables(migrationUpStatements(schemaVersion));
      expect(tablesSecond, tablesFirst);
      expect(tablesSecond, contains('print_log'));
    });
  });

  group('PrintLogAudit — capture at the print path', () {
    test('a failed job is recorded with error code, attempt count and warnings', () async {
      final store = MemoryPrintLogStore();
      final audit = PrintLogAudit(store: store);
      // A clone dialect: the built-in BILL layout carries a QR the clone cannot
      // do natively → the encode reports a QR fallback warning.
      final d = buildDispatcher(
        AlwaysFailingTransport(),
        logs: audit,
        outlet: _outlet(
          printers: [
            {'id': 'p', 'name': 'Clone', 'transport': 'NETWORK', 'ip': '1.1.1.1', 'protocol': 'ESC/POS-CLONE', 'retryCount': 2, 'retryTimeoutSec': 1},
          ],
        ),
      );
      final f = _flow();
      final out = await d.printBill(items: [_item()], receiptId: 'R-1', flow: f, split: _split(f));
      expect(out.alerts, isNotEmpty);
      final row = await _onlyRow(store);
      expect(row.outcome, kOutcomeFailed);
      expect(row.errorCode, 'print_failed');
      expect(row.errorDetail, contains('offline'));
      expect(row.attemptCount, 2); // the queue's retryCount was exhausted
      expect(row.printerName, 'Clone');
      expect(row.printerTransport, 'NETWORK');
      expect(row.warnings.any((w) => w.contains('no native QR')), isTrue);
      expect(row.renderedText, isNotNull); // FAILED keeps the bounded text
      expect(row.byteLength, greaterThan(0));
      expect(row.uploadState, kPrintLogPending);
    });

    test('a fallback (missing printer) is recorded as FALLBACK with the specific warning', () async {
      final store = MemoryPrintLogStore();
      final audit = PrintLogAudit(store: store);
      final d = buildDispatcher(RecordingTransport(), logs: audit, outlet: {'printers': [], 'routing': {}});
      final f = _flow();
      final out = await d.printBill(items: [_item()], receiptId: 'R-1', flow: f, split: _split(f));
      expect(out.alerts.single, contains('No printer configured for BILL'));
      final row = await _onlyRow(store);
      expect(row.outcome, kOutcomeFallback);
      expect(row.errorCode, 'no_printer');
      expect(row.warnings.single, contains('No printer configured'));
      expect(row.printerId, isNull);
    });

    test('an unsupported transport is recorded as FALLBACK', () async {
      final store = MemoryPrintLogStore();
      final audit = PrintLogAudit(store: store);
      final routing = PrinterRouting(
        printers: const [ClientPrinter(id: 'p', name: 'Serial', transport: 'SERIAL')],
        routing: const {
          'BILL': [RoutingEntry(printerId: 'p')],
        },
        itemRoutes: const {},
      );
      final d = buildDispatcher(RecordingTransport(), logs: audit, routing: routing);
      final f = _flow();
      await d.printBill(items: [_item()], receiptId: 'R-1', flow: f, split: _split(f));
      final row = await _onlyRow(store);
      expect(row.outcome, kOutcomeFallback);
      expect(row.errorCode, 'unsupported_transport');
      expect(row.printerTransport, 'SERIAL');
    });

    test('a dialect outside the registry is recorded as FALLBACK', () async {
      final store = MemoryPrintLogStore();
      final audit = PrintLogAudit(store: store);
      final d = buildDispatcher(
        RecordingTransport(),
        logs: audit,
        outlet: _outlet(
          printers: [
            {'id': 'p', 'name': 'Unknown', 'transport': 'NETWORK', 'ip': '1.1.1.1', 'protocol': 'ZPL'},
          ],
        ),
      );
      final f = _flow();
      await d.printBill(items: [_item()], receiptId: 'R-1', flow: f, split: _split(f));
      final row = await _onlyRow(store);
      expect(row.outcome, kOutcomeFallback);
      expect(row.dialectCode, 'ZPL');
      expect(row.dialectFallback, isTrue);
      expect(row.warnings.any((w) => w.contains('not in the dialect registry')), isTrue);
    });

    test('an implemented dialect (STAR) is NOT logged as a dialect fallback', () async {
      // Star really encodes with Star Line Mode bytes (`ESC GS t n` code page,
      // `ESC GS a n` align, `ESC i` size, `ESC d n` cut), so it is no longer a
      // *dialect* downgrade. This bill still lands in FALLBACK, but only because
      // this build implements no Star native QR: the receipt-id QR block degrades
      // to the labelled text line instead.
      final store = MemoryPrintLogStore();
      final audit = PrintLogAudit(store: store);
      final d = buildDispatcher(
        RecordingTransport(),
        logs: audit,
        outlet: _outlet(
          printers: [
            {'id': 'p', 'name': 'Star', 'transport': 'NETWORK', 'ip': '1.1.1.1', 'protocol': 'STAR'},
          ],
        ),
      );
      final f = _flow();
      await d.printBill(items: [_item()], receiptId: 'R-1', flow: f, split: _split(f));
      final row = await _onlyRow(store);
      expect(row.dialectCode, 'STAR');
      expect(row.dialectFallback, isFalse);
      expect(row.warnings.any((w) => w.contains('not implemented')), isFalse);
      expect(row.warnings.any((w) => w.contains('not in the dialect registry')), isFalse);
      expect(row.warnings.any((w) => w.contains('no native QR')), isTrue);
    });

    test('a code-page fallback is recorded as FALLBACK', () async {
      final store = MemoryPrintLogStore();
      final audit = PrintLogAudit(store: store);
      final d = buildDispatcher(
        RecordingTransport(),
        logs: audit,
        outlet: _outlet(
          printers: [
            {'id': 'p', 'name': 'Utf8', 'transport': 'NETWORK', 'ip': '1.1.1.1', 'codePage': 'UTF-8'},
          ],
        ),
      );
      final f = _flow();
      await d.printBill(items: [_item()], receiptId: 'R-1', flow: f, split: _split(f));
      final row = await _onlyRow(store);
      expect(row.outcome, kOutcomeFallback);
      expect(row.warnings.any((w) => w.contains('no ESC/POS encoding')), isTrue);
    });

    test('a successful escape-free job is recorded as OK with NO rendered text', () async {
      final store = MemoryPrintLogStore();
      final audit = PrintLogAudit(store: store);
      final d = buildDispatcher(RecordingTransport(), logs: audit); // default ESC/POS printer
      final f = _flow();
      final out = await d.printBill(items: [_item()], receiptId: 'R-1', flow: f, split: _split(f));
      expect(out.alerts, isEmpty);
      final row = await _onlyRow(store);
      expect(row.outcome, kOutcomeOk);
      expect(row.renderedText, isNull);
      expect(row.receiptId, 'R-1');
      expect(row.attemptCount, 1);
      expect(row.errorCode, isNull);
    });

    test('the pre-attempt row exists before completion (crash evidence)', () async {
      final store = MemoryPrintLogStore();
      final audit = PrintLogAudit(store: store);
      const printer = ClientPrinter(id: 'p', name: 'P', transport: 'NETWORK', ip: '1.1.1.1');
      final encode = encodePrintJobDetailed(PrintJob(
        ticketType: 'BILL',
        lines: const ['RECEIPT'],
        entries: const [],
        printer: printer.toPrintPrinter(),
      ));
      final attempt = await audit.begin(
        ticketType: 'BILL',
        printer: printer,
        encode: encode,
        renderedLines: const ['RECEIPT'],
      );
      var row = await _onlyRow(store);
      expect(row.outcome, kOutcomeFailed);
      expect(row.errorCode, 'incomplete');
      expect(row.renderedText, isNull);
      await attempt.completeOk();
      row = await _onlyRow(store);
      expect(row.outcome, kOutcomeOk);
      expect(row.uploadState, kPrintLogPending);
    });
  });

  group('PrintLogStore retention', () {
    test('prunes uploaded rows by age but never an unsent row', () async {
      final now = DateTime(2026, 9, 28, 12);
      final store = MemoryPrintLogStore(now: () => now);
      final old = now.subtract(const Duration(days: 30));
      await store.insert(_row('sent-old', created: old));
      await store.markSent(const ['sent-old']);
      await store.insert(_row('pending-old', created: old));

      final removed = await store.pruneUploaded(maxRows: 500, maxAge: const Duration(days: 7));
      expect(removed, 1);
      final ids = [for (final r in await store.list()) r.clientLogId];
      expect(ids, ['pending-old']); // the unsent (unuploaded) row survives
    });

    test('respects the row cap and keeps every unsent row', () async {
      final now = DateTime(2026, 9, 28, 12);
      final store = MemoryPrintLogStore(now: () => now);
      for (var i = 0; i < 5; i++) {
        final id = 'sent-$i';
        await store.insert(_row(id, created: now.subtract(Duration(minutes: i))));
        await store.markSent([id]);
      }
      await store.insert(_row('pending', created: now.subtract(const Duration(days: 90))));

      final removed = await store.pruneUploaded(maxRows: 2, maxAge: const Duration(days: 3650));
      expect(removed, 3); // oldest 3 uploaded rows dropped
      final ids = [for (final r in await store.list()) r.clientLogId];
      expect(ids, contains('pending')); // never pruned
      expect(ids.length, 3); // newest 2 sent + the pending row
    });
  });

  group('PrintLogUploader — batched, idempotent, retried', () {
    test('marks accepted rows sent with the exact contract body', () async {
      Map<String, dynamic>? body;
      final store = MemoryPrintLogStore();
      await store.insert(_row('a', created: DateTime(2026, 9, 28, 10)));
      await store.insert(_row('b', created: DateTime(2026, 9, 28, 11)));
      final uploader = PrintLogUploader(api: _api((req) {
        body = jsonDecode(req.body) as Map<String, dynamic>;
        return {'accepted': 2, 'alreadySeen': 0, 'rejected': 0};
      }), store: store);

      final res = await uploader.uploadPending(tenantId: 't1', assetId: 'dev-1');
      expect(res.uploaded, 2);
      expect(res.remaining, 0);
      expect(body!['tenantId'], 't1');
      expect(body!['assetId'], 'dev-1');
      final logs = body!['logs'] as List;
      expect(logs, hasLength(2));
      final first = logs.first as Map<String, dynamic>;
      expect(first.keys, containsAll(['clientLogId', 'ticketType', 'outcome', 'attemptCount', 'warnings', 'createdAt']));
      expect(await store.pendingUploadCount(), 0);
    });

    test('a network failure keeps rows pending for the next retry', () async {
      final store = MemoryPrintLogStore();
      await store.insert(_row('a', created: DateTime(2026, 9, 28, 10)));
      var calls = 0;
      final uploader = PrintLogUploader(api: _api((req) {
        calls++;
        if (calls == 1) throw PosNetworkException('offline');
        return {'accepted': 1, 'alreadySeen': 0, 'rejected': 0};
      }), store: store);

      final first = await uploader.uploadPending(tenantId: 't1', assetId: 'dev-1');
      expect(first.uploaded, 0);
      expect(await store.pendingUploadCount(), 1); // nothing lost

      final second = await uploader.uploadPending(tenantId: 't1', assetId: 'dev-1');
      expect(second.uploaded, 1);
      expect(await store.pendingUploadCount(), 0);
    });

    test('a SERVER refusal is NOT reported as "no network" (asset_not_found)', () async {
      // Field report: retry upload said "no network" while the network was fine —
      // the server had answered 404 because it did not recognise the reporting
      // identity. The two must never be conflated.
      final store = MemoryPrintLogStore();
      await store.insert(_row('a', created: DateTime(2026, 9, 28, 10)));
      final uploader = PrintLogUploader(
        api: PosApi(ApiClient(
          baseUrl: 'http://fake.test',
          httpClient: MockClient((_) async => http.Response(
                '{"error":"asset_not_found"}',
                404,
                headers: {'content-type': 'application/json'},
              )),
        )),
        store: store,
      );

      final res = await uploader.uploadPending(tenantId: 't1', assetId: 'dev-1');
      expect(res.offline, isFalse, reason: 'the server answered — not a network failure');
      expect(res.failed, 1);
      expect(res.rejectedCodes, contains('asset_not_found'));
      expect(await store.pendingUploadCount(), 1, reason: 'rows are kept for a later retry');
    });

    test('re-upload after a crash does not duplicate rows and keeps the clientLogId', () async {
      final store = MemoryPrintLogStore();
      final audit = PrintLogAudit(store: store);
      const printer = ClientPrinter(id: 'p', name: 'P', transport: 'NETWORK', ip: '1.1.1.1');
      final encode = encodePrintJobDetailed(PrintJob(
        ticketType: 'BILL',
        lines: const ['RECEIPT'],
        entries: const [],
        printer: printer.toPrintPrinter(),
      ));
      final attempt = await audit.begin(ticketType: 'BILL', printer: printer, encode: encode, renderedLines: const ['RECEIPT']);
      await attempt.completeFailed(attemptCount: 3, errorCode: 'timeout', errorDetail: 'timed out');
      final id = (await _onlyRow(store)).clientLogId;

      final sentIds = <String>[];
      final uploader = PrintLogUploader(api: _api((req) {
        final logs = (jsonDecode(req.body) as Map<String, dynamic>)['logs'] as List;
        sentIds.addAll([for (final l in logs) (l as Map)['clientLogId'] as String]);
        // Idempotent server: the second identical send is 'alreadySeen'.
        final seen = sentIds.where((x) => x == id).length > 1;
        return {'accepted': seen ? 0 : 1, 'alreadySeen': seen ? 1 : 0, 'rejected': 0};
      }), store: store);

      await uploader.uploadPending(tenantId: 't1', assetId: 'dev-1');
      // Simulate a restart that did not know the first send landed: send again.
      await store.insert((await _onlyRow(store))); // no-op replay of the same row
      final replay = await uploader.uploadPending(tenantId: 't1', assetId: 'dev-1');
      expect(replay.remaining, 0);
      expect(await store.totalCount(), 1); // never duplicated locally
      expect(sentIds.every((x) => x == id), isTrue); // same clientLogId every send
    });
  });

  group('AppSession wiring', () {
    test('uploadPrintLogs ships pending rows with the session tenant + device id', () async {
      final backend = FakeBackend();
      final session = backend.createSession();
      await session.init();
      expect(await session.redeem('CODE-1', assetLabel: 'Tablet 1'), isTrue);
      expect(await session.login(email: 'c@x.demo', password: 'pw'), isTrue);

      await session.printLogs.insert(_row('local-1', created: DateTime(2026, 9, 28, 9)));
      expect(await session.refreshPrintLogPending(), 1);

      final uploaded = await session.uploadPrintLogs();
      expect(uploaded, 1);
      expect(session.printLogPending, 0);
      expect(backend.lastPrintLogsBody!['tenantId'], 't1');
      expect(backend.lastPrintLogsBody!['assetId'], isNotNull);
      expect((backend.lastPrintLogsBody!['logs'] as List).single['clientLogId'], 'local-1');
    });
  });
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

PrintLogRow _row(String id, {required DateTime created}) => PrintLogRow(
      clientLogId: id,
      ticketType: 'BILL',
      outcome: kOutcomeFailed,
      attemptCount: 1,
      errorCode: 'print_failed',
      warnings: const ['boom'],
      createdAt: created,
    );

PosApi _api(Object? Function(http.Request req) handler) => PosApi(
      ApiClient(baseUrl: 'http://fake.test', httpClient: MockClient((req) async {
        final body = handler(req);
        return http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json'});
      })),
    );

Set<String> _tables(List<String> statements) {
  final re = RegExp(r'CREATE (?:TABLE|INDEX|UNIQUE INDEX) IF NOT EXISTS (\w+)', caseSensitive: false);
  final out = <String>{};
  for (final s in statements) {
    final m = re.firstMatch(s);
    if (m != null) out.add(m.group(1)!);
  }
  return out;
}
