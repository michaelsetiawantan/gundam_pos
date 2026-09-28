import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gundam_pos/api/api_client.dart';
import 'package:gundam_pos/services/printer_health_report.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('posts the PRD status set to the device printer-health route', () async {
    String? method;
    String? path;
    Map<String, dynamic>? body;
    final client = ApiClient(
      baseUrl: 'http://fake.test',
      httpClient: MockClient((req) async {
        method = req.method;
        path = req.url.path;
        body = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response('{"updated":2}', 200);
      }),
      authProvider: () => null,
    );

    final ok = await PrinterHealthReporter(client: client).report(
      tenantId: 't1',
      assetId: 'a1',
      statusesByPrinterId: {'p1': 'Ready', 'p2': 'Not paired'},
      checkedAt: DateTime.utc(2026, 9, 28),
    );

    expect(ok, isTrue);
    expect(method, 'POST');
    expect(path, '/api/pos/printers/health');
    expect(body!['tenantId'], 't1');
    expect(body!['assetId'], 'a1');
    expect(body!['checkedAt'], '2026-09-28T00:00:00.000Z');
    final reports = body!['reports'] as List;
    expect(reports, containsAll([
      {'printerId': 'p1', 'status': 'Ready'},
      {'printerId': 'p2', 'status': 'Not paired'},
    ]));
  });

  test('an empty report skips the call entirely', () async {
    var called = false;
    final client = ApiClient(
      baseUrl: 'http://fake.test',
      httpClient: MockClient((req) async {
        called = true;
        return http.Response('{}', 200);
      }),
    );
    expect(await PrinterHealthReporter(client: client).report(tenantId: 't1', assetId: 'a1', statusesByPrinterId: {}), isFalse);
    expect(called, isFalse);
  });

  test('a server error returns false and never throws', () async {
    final client = ApiClient(
      baseUrl: 'http://fake.test',
      httpClient: MockClient((req) async => http.Response('{"error":"not_found"}', 404)),
    );
    final ok = await PrinterHealthReporter(client: client)
        .report(tenantId: 't1', assetId: 'a1', statusesByPrinterId: {'p1': 'Ready'});
    expect(ok, isFalse);
  });
}
