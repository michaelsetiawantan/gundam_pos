import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gundam_pos/models/config_models.dart';
import 'package:gundam_pos/state/app_session.dart';
import 'package:gundam_pos/state/session_store.dart';
import 'package:gundam_pos/ui/approvals_screen.dart';
import 'package:gundam_pos/ui/theme.dart';

import 'support/fake_backend.dart';

// P27 — POS Approvals. The tablet decides PENDING cancel/void/refund/discount
// requests; TIP approval is web-only and must NOT appear here. The server is
// the authority (group-scoped list, role-gated decide), so the screen is honest
// about a 403 and never applies a decision optimistically.

Map<String, dynamic> _appr({
  required String id,
  required String actionType,
  String? reason,
  String requester = 'Cashier One',
  String? receiptId,
  String? orderId,
  String? tableName,
}) =>
    {
      'id': id,
      'actionType': actionType,
      'status': 'PENDING',
      'reason': reason,
      'createdAt': DateTime.now().toIso8601String(),
      'requester': {'id': 'u1', 'fullName': requester},
      if (receiptId != null) 'transaction': {'id': 'txn', 'receiptId': receiptId},
      if (orderId != null)
        'order': {'id': orderId, 'status': 'OPEN', if (tableName != null) 'tableName': tableName},
    };

Future<AppSession> _sessionWith(FakeBackend backend) async {
  final store = InMemorySessionStore();
  await store.save(const PosContext()
      .withRedeem({'deviceToken': 'dev', 'groupId': 'g1', 'tenantId': 't1', 'shortcode': 'NSTAR-POS1'})
      .withSession({
        'sessionId': 'sess-1',
        'user': {'id': 'u1', 'fullName': 'Cashier One'},
        'outlet': {'id': 't1', 'name': 'Northstar'},
      })
      .copyWith(deviceId: 'device-1'));
  final session = backend.createSession(store: store);
  await session.init();
  return session;
}

Widget _wrap(Widget child) => MaterialApp(theme: PosTheme.theme(), home: child);

void main() {
  testWidgets('(a) renders PENDING non-tip approvals with table, requester, reason', (tester) async {
    final backend = FakeBackend()
      ..approvals = [
        _appr(id: 'a1', actionType: 'CANCEL', reason: 'Wrong item', receiptId: 'NSTAR-1'),
        _appr(id: 'a2', actionType: 'VOID', reason: 'Customer left', orderId: 'o9', tableName: 'A2'),
      ];
    final session = await _sessionWith(backend);

    await tester.pumpWidget(_wrap(ApprovalsScreen(session: session)));
    await tester.pumpAndSettle();

    expect(find.text('CANCEL'), findsOneWidget);
    expect(find.text('VOID'), findsOneWidget);
    expect(find.text('Wrong item'), findsOneWidget);
    // Table falls back to the receipt id when the order has no table name.
    expect(find.text('Table NSTAR-1'), findsOneWidget);
    expect(find.text('Table A2'), findsOneWidget);
    expect(find.text('Requested by Cashier One'), findsNWidgets(2));
    expect(find.text('Approve'), findsNWidgets(2));
    expect(find.text('Reject'), findsNWidgets(2));
    expect(find.textContaining('Last synced'), findsOneWidget);
  });

  testWidgets('(b) TIP approvals are filtered out of the POS list', (tester) async {
    final backend = FakeBackend()
      ..approvals = [
        _appr(id: 'a1', actionType: 'CANCEL', reason: 'Wrong item'),
        _appr(id: 'a2', actionType: 'TIPS', reason: 'Overpay tip'),
      ];
    final session = await _sessionWith(backend);

    await tester.pumpWidget(_wrap(ApprovalsScreen(session: session)));
    await tester.pumpAndSettle();

    expect(find.text('CANCEL'), findsOneWidget);
    expect(find.text('TIPS'), findsNothing);
    expect(find.text('Overpay tip'), findsNothing);
    expect(find.text('Approve'), findsOneWidget); // only the CANCEL row
  });

  testWidgets('(c) Approve calls decide then re-pulls the list', (tester) async {
    final backend = FakeBackend()
      ..approvals = [_appr(id: 'a1', actionType: 'CANCEL', reason: 'Wrong item')];
    final session = await _sessionWith(backend);

    await tester.pumpWidget(_wrap(ApprovalsScreen(session: session)));
    await tester.pumpAndSettle();
    expect(backend.approvalsListCalls, 1);

    await tester.tap(find.text('Approve'));
    await tester.pumpAndSettle();
    expect(find.text('Confirm approve'), findsOneWidget);

    await tester.tap(find.text('Confirm approve'));
    await tester.pumpAndSettle();

    expect(backend.lastDecideId, 'a1');
    expect(backend.lastDecideBody!['state'], 'APPROVED');
    expect(backend.approvalsListCalls, 2); // refreshed after the decision
    expect(find.text('No pending approvals.'), findsOneWidget);
  });

  testWidgets('(d) a 403 on load shows a friendly role message, not a dead-end', (tester) async {
    final backend = FakeBackend()..approvalsError = 'forbidden';
    final session = await _sessionWith(backend);

    await tester.pumpWidget(_wrap(ApprovalsScreen(session: session)));
    await tester.pumpAndSettle();

    expect(find.text('Your role is not allowed to decide approvals.'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('(e) honest empty state', (tester) async {
    final backend = FakeBackend()..approvals = [];
    final session = await _sessionWith(backend);

    await tester.pumpWidget(_wrap(ApprovalsScreen(session: session)));
    await tester.pumpAndSettle();

    expect(find.text('No pending approvals.'), findsOneWidget);
  });

  testWidgets('(f) resuming the app auto-reloads the approval list', (tester) async {
    final backend = FakeBackend()
      ..approvals = [_appr(id: 'a1', actionType: 'CANCEL', reason: 'Wrong item')];
    final session = await _sessionWith(backend);

    await tester.pumpWidget(_wrap(ApprovalsScreen(session: session)));
    await tester.pumpAndSettle();
    expect(backend.approvalsListCalls, 1);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    expect(backend.approvalsListCalls, 2); // refreshed on resume, no manual tap
  });

  testWidgets('(g) shows table, requester, time and a resolved discount label; reason is JSON-free', (tester) async {
    final backend = FakeBackend()
      ..approvals = [
        _appr(
          id: 'a1',
          actionType: 'DISCOUNT',
          reason: 'Happy hour ::{"discountId":"d1","voucherId":null}',
          requester: 'Cashier One',
          orderId: 'o1',
          tableName: 'A1',
        ),
      ];
    final session = await _sessionWith(backend);
    // Local master config so the DISCOUNT amount can be resolved on the tablet.
    session.config = TenantConfig.fromSyncPayloads(
      {
        'discounts': [
          {'id': 'd1', 'name': 'Happy Hour', 'kind': 'PERCENTAGE', 'value': 10},
        ],
      },
      {},
    );

    await tester.pumpWidget(_wrap(ApprovalsScreen(session: session)));
    await tester.pumpAndSettle();

    expect(find.text('Table A1'), findsOneWidget);
    expect(find.text('Requested by Cashier One'), findsOneWidget);
    expect(find.text('Happy Hour · 10%'), findsOneWidget); // resolved amount
    expect(find.text('Happy hour'), findsOneWidget); // cleaned reason (no payload)
    expect(find.textContaining('discountId'), findsNothing);
    expect(find.textContaining('voucherId'), findsNothing);
    expect(find.textContaining('::'), findsNothing);
    // HH:mm · yyyy-mm-dd local timestamp is present.
    final now = DateTime.now();
    final two = (int v) => v < 10 ? '0$v' : '$v';
    expect(find.textContaining('${two(now.hour)}:${two(now.minute)} · ${now.year}-'), findsOneWidget);
  });

  testWidgets('(h) an unknown master id renders a dash, never the raw json', (tester) async {
    final backend = FakeBackend()
      ..approvals = [
        _appr(id: 'a1', actionType: 'DISCOUNT', reason: 'VIP ::{"discountId":"missing"}', orderId: 'o1', tableName: 'B3'),
      ];
    final session = await _sessionWith(backend);
    session.config = TenantConfig.fromSyncPayloads({'discounts': []}, {});

    await tester.pumpWidget(_wrap(ApprovalsScreen(session: session)));
    await tester.pumpAndSettle();

    expect(find.text('Table B3'), findsOneWidget);
    expect(find.text('VIP'), findsOneWidget);
    expect(find.text('-'), findsOneWidget);
    expect(find.textContaining('discountId'), findsNothing);
  });

  testWidgets('(i) 403 on Approve opens the credential dialog; wrong creds re-ask, correct creds approve', (tester) async {
    final backend = FakeBackend()
      ..approvals = [_appr(id: 'a1', actionType: 'CANCEL', reason: 'Wrong item', tableName: 'A1')]
      ..decideRequiresCredentials = true
      ..validApproverEmail = 'boss@x.demo'
      ..validApproverPassword = 'Secret@1';
    final session = await _sessionWith(backend);

    await tester.pumpWidget(_wrap(ApprovalsScreen(session: session)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Approve'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Confirm approve'));
    await tester.pumpAndSettle();

    // Session 403 → delegation dialog.
    expect(find.text('Approval required'), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField).at(1)).obscureText, isTrue);

    // Wrong password → stays open, asks again.
    await tester.enterText(find.byType(TextField).at(0), 'boss@x.demo');
    await tester.enterText(find.byType(TextField).at(1), 'nope');
    await tester.tap(find.text('Authorise'));
    await tester.pumpAndSettle();
    expect(find.text('Approval required'), findsOneWidget);
    expect(find.textContaining('Invalid username or password'), findsOneWidget);
    expect(backend.approvalsListCalls, 1); // not applied yet

    // Correct password → the delegated decision succeeds and the list reloads.
    await tester.enterText(find.byType(TextField).at(0), 'boss@x.demo');
    await tester.enterText(find.byType(TextField).at(1), 'Secret@1');
    await tester.tap(find.text('Authorise'));
    await tester.pumpAndSettle();

    expect(backend.lastDecideBody!['approverEmail'], 'boss@x.demo');
    expect(backend.lastDecideBody!['approverPassword'], 'Secret@1');
    expect(backend.lastDecideBody!['state'], 'APPROVED');
    expect(find.text('No pending approvals.'), findsOneWidget);
    expect(backend.approvalsListCalls, 2);
  });

  testWidgets('(j) Reject does not dead-end on a 403: it offers the same credential dialog', (tester) async {
    final backend = FakeBackend()
      ..approvals = [_appr(id: 'a1', actionType: 'CANCEL', reason: 'Wrong item', tableName: 'A1')]
      ..decideRequiresCredentials = true
      ..validApproverEmail = 'boss@x.demo'
      ..validApproverPassword = 'Secret@1';
    final session = await _sessionWith(backend);

    await tester.pumpWidget(_wrap(ApprovalsScreen(session: session)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Reject'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Confirm reject'));
    await tester.pumpAndSettle();

    expect(find.text('Approval required'), findsOneWidget);
    await tester.enterText(find.byType(TextField).at(0), 'boss@x.demo');
    await tester.enterText(find.byType(TextField).at(1), 'Secret@1');
    await tester.tap(find.text('Authorise'));
    await tester.pumpAndSettle();

    expect(backend.lastDecideBody!['state'], 'REJECTED');
    expect(find.text('No pending approvals.'), findsOneWidget);
  });
}
