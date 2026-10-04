import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gundam_pos/api/api_client.dart';
import 'package:gundam_pos/api/pos_api.dart';
import 'package:gundam_pos/state/app_session.dart';
import 'package:gundam_pos/state/session_store.dart';
import 'package:gundam_pos/ui/theme.dart';
import 'package:gundam_pos/ui/today_transactions_screen.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

// P26 — Today's transactions. Regression: a cancelled (never-paid) order used to
// vanish (todayBills only held local settles). Now the screen reads the server's
// today feed with full status (PAID / CANCELED / VOIDED / REFUNDED) and falls
// back to the local settles only when offline. Void/Reprint are PAID-only.

Map<String, dynamic> _row({
  required String orderId,
  required String status,
  String? receiptId,
  num? total,
  String? tableName,
  String? paidByName,
  String? at,
  String? statusReason,
  String? statusChangedAt,
  String? statusRequestedByName,
  String? statusDecidedByName,
  String? statusDecision,
}) =>
    {
      'orderId': orderId,
      'status': status,
      'receiptId': receiptId,
      'total': total,
      'tableName': tableName,
      'paidByName': paidByName,
      'at': at ?? DateTime.now().toIso8601String(),
      'statusReason': statusReason,
      'statusChangedAt': statusChangedAt,
      'statusRequestedByName': statusRequestedByName,
      'statusDecidedByName': statusDecidedByName,
      'statusDecision': statusDecision,
    };

/// Mock backend for `GET /api/pos/orders/today` only. [offline] throws a
/// transport error so the session must fall back — no network.
MockClient _todayBackend(List<Map<String, dynamic>> orders, {bool offline = false}) =>
    MockClient((req) async {
      if (offline) throw http.ClientException('offline');
      if (req.url.path == '/api/pos/orders/today') {
        return http.Response(jsonEncode({'orders': orders}), 200,
            headers: {'content-type': 'application/json'});
      }
      return http.Response(jsonEncode({'error': 'not_found'}), 404,
          headers: {'content-type': 'application/json'});
    });

Future<AppSession> _readySession(http.Client client) async {
  final store = InMemorySessionStore();
  await store.save(const PosContext()
      .withRedeem({'deviceToken': 'dev', 'groupId': 'g1', 'tenantId': 't1', 'shortcode': 'NSTAR-POS1'})
      .withSession({
        'sessionId': 'sess-1',
        'user': {'id': 'u1', 'fullName': 'Cashier One'},
        'outlet': {'id': 't1', 'name': 'Northstar'},
      })
      .copyWith(deviceId: 'device-1'));
  final api = PosApi(ApiClient(baseUrl: 'http://fake.test', httpClient: client, authProvider: () => null));
  final session = AppSession(posApi: api, sessionStore: store);
  await session.init();
  return session;
}

Widget _wrap(Widget child) => MaterialApp(theme: PosTheme.theme(), home: child);

void main() {
  test('loadTodayOrders stores server rows with their full status', () async {
    final session = await _readySession(_todayBackend([
      _row(orderId: 'o-cancel', status: 'CANCELED', total: 30000, tableName: 'T2'),
      _row(orderId: 'o-paid', status: 'PAID', receiptId: 'NSTAR-TAB1-1', total: 45000, tableName: 'T1', paidByName: 'Cashier One'),
    ]));

    final rows = await session.loadTodayOrders();
    expect(rows, isNotNull);
    expect(session.todayLedger, hasLength(2));
    expect(session.todayLedger.map((r) => r['status']), containsAll(['PAID', 'CANCELED']));
  });

  test('offline returns null and keeps the last-known ledger untouched', () async {
    final session = await _readySession(_todayBackend(const [], offline: true));
    expect(await session.loadTodayOrders(), isNull);
    expect(session.todayLedger, isEmpty);
  });

  testWidgets('lists CANCELED + PAID rows and offers actions on PAID only', (tester) async {
    final session = await _readySession(_todayBackend([
      _row(orderId: 'o-cancel', status: 'CANCELED', total: 30000, tableName: 'T2'),
      _row(orderId: 'o-paid', status: 'PAID', receiptId: 'NSTAR-TAB1-0000001', total: 45000, tableName: 'T1', paidByName: 'Cashier One'),
    ]));

    await tester.pumpWidget(_wrap(TodayTransactionsScreen(session: session)));
    await tester.pumpAndSettle();

    expect(find.text('CANCELED'), findsOneWidget); // the cancelled order shows
    expect(find.text('PAID'), findsOneWidget);
    expect(find.text('NSTAR-TAB1-0000001'), findsOneWidget);
    // Reprint/Void only on the PAID row — the CANCELED row has no action menu.
    expect(find.byType(PopupMenuButton<String>), findsOneWidget);
  });

  testWidgets('void accepts a bill settled just after local midnight (UTC server timestamp)', (tester) async {
    // The bug: the server sends UTC ISO-8601, so a bill at 00:02 WIB parsed as
    // UTC read as the previous day and same-day void wrongly refused it. The
    // instant is built from LOCAL wall-clock midnight so the parse+toLocal
    // round-trip is exercised on any host zone.
    final n = DateTime.now();
    final justAfterMidnight = DateTime(n.year, n.month, n.day, 0, 2);
    final session = await _readySession(_todayBackend([
      _row(orderId: 'o-paid', status: 'PAID', receiptId: 'R-1', total: 1000,
          at: justAfterMidnight.toUtc().toIso8601String()),
    ]));

    await tester.pumpWidget(_wrap(TodayTransactionsScreen(session: session)));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Void (same-day)'));
    await tester.pumpAndSettle();

    expect(find.text('Void this bill?'), findsOneWidget); // same-day path, not the past-day refusal
    expect(find.textContaining('past-day'), findsNothing);
  });

  testWidgets('void auto-applies when the server returns voided:true — success + reload', (tester) async {
    // The server AUTO-APPLIES for an entitled requester and answers
    // {voided:true,status:'VOIDED'} with NO `approval` block. The old code read
    // only `approval.status` and told the operator "pending approval" for a bill
    // already voided until a manual refresh. Now: success copy + auto-reload.
    var todayCalls = 0;
    final client = MockClient((req) async {
      if (req.url.path == '/api/pos/orders/today') {
        todayCalls++;
        return http.Response(
            jsonEncode({'orders': [_row(orderId: 'o-paid', status: 'PAID', receiptId: 'R-1', total: 1000)]}), 200,
            headers: {'content-type': 'application/json'});
      }
      if (req.method == 'POST' && req.url.path.endsWith('/void')) {
        return http.Response(jsonEncode({'voided': true, 'status': 'VOIDED'}), 200,
            headers: {'content-type': 'application/json'});
      }
      return http.Response(jsonEncode({'error': 'not_found'}), 404,
          headers: {'content-type': 'application/json'});
    });
    final session = await _readySession(client);

    await tester.pumpWidget(_wrap(TodayTransactionsScreen(session: session)));
    await tester.pumpAndSettle();
    expect(todayCalls, 1);

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Void (same-day)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Request void'));
    await tester.pumpAndSettle();

    expect(find.text('Void applied — the bill is now VOIDED.'), findsOneWidget);
    expect(find.textContaining('approval'), findsNothing);
    expect(todayCalls, 2); // the list reloaded itself — no manual refresh
  });

  testWidgets('offline falls back to the local settled bills', (tester) async {
    final session = await _readySession(_todayBackend(const [], offline: true));
    session.noteSettled({'orderId': 'o-local', 'receiptId': 'LOCAL-0001', 'total': 12000});

    await tester.pumpWidget(_wrap(TodayTransactionsScreen(session: session)));
    await tester.pumpAndSettle();

    expect(find.text('LOCAL-0001'), findsOneWidget);
    expect(find.textContaining('No network'), findsOneWidget);
  });

  testWidgets('tapping a CANCELED row opens the trace popup with requester, approver and reason', (tester) async {
    final at = DateTime(2026, 10, 4, 14, 5).toUtc().toIso8601String();
    final session = await _readySession(_todayBackend([
      _row(orderId: 'o-cancel', status: 'CANCELED', total: 30000, tableName: 'T2',
          statusReason: 'kitchen wrong', statusChangedAt: at,
          statusRequestedByName: 'Cashier One', statusDecidedByName: 'Manager Maya', statusDecision: 'APPROVED'),
    ]));

    await tester.pumpWidget(_wrap(TodayTransactionsScreen(session: session)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('CANCELED'));
    await tester.pumpAndSettle();

    expect(find.text('Transaction trace'), findsOneWidget);
    expect(find.text('Requested by'), findsOneWidget);
    expect(find.text('Cashier One'), findsOneWidget);
    expect(find.text('Manager Maya'), findsOneWidget);
    expect(find.text('kitchen wrong'), findsOneWidget);
  });

  testWidgets('AUTO decision shows the auto-approve line; legacy nulls show "-"', (tester) async {
    final session = await _readySession(_todayBackend([
      _row(orderId: 'o-void', status: 'VOIDED', receiptId: 'R-AUTO', total: 45000,
          statusChangedAt: DateTime(2026, 10, 4, 9, 30).toUtc().toIso8601String(),
          statusRequestedByName: 'Supervisor Ada', statusDecision: 'AUTO'),
      _row(orderId: 'o-legacy', status: 'VOIDED', receiptId: 'R-OLD', total: 20000), // old row: no audit at all
    ]));

    await tester.pumpWidget(_wrap(TodayTransactionsScreen(session: session)));
    await tester.pumpAndSettle();

    // AUTO row → the requester's own role carried the right.
    await tester.tap(find.text('R-AUTO'));
    await tester.pumpAndSettle();
    expect(find.text('Auto-approved — Supervisor Ada (role-nya berhak)'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    // Legacy row → every trace line is '-'.
    await tester.tap(find.text('R-OLD'));
    await tester.pumpAndSettle();
    expect(find.text('-'), findsNWidgets(4)); // at, requested by, authorized by, reason
  });
}
