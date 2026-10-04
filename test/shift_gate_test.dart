import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gundam_pos/models/config_models.dart';
import 'package:gundam_pos/state/app_session.dart';
import 'package:gundam_pos/state/session_store.dart';
import 'package:gundam_pos/ui/open_tables_screen.dart';
import 'package:gundam_pos/ui/theme.dart';

import 'support/fake_backend.dart';

/// PRD: a cashier may NOT enter an active table or open a new one without an
/// OPEN shift. The gate blocks the entry points with a clear message + a direct
/// Start Shift path; read-only browsing of Open Tables stays allowed.

TenantConfig _northstar() =>
    TenantConfig.fromSyncPayloads(FakeBackend.northstarMaster(), FakeBackend.northstarOutlet());

Widget _wrap(Widget child) => MaterialApp(theme: PosTheme.theme(), home: child);

Future<AppSession> _readySession(FakeBackend backend) async {
  final store = InMemorySessionStore();
  await store.save(const PosContext()
      .withRedeem({'deviceToken': 'dev', 'groupId': 'g1', 'tenantId': 't1', 'shortcode': 'NSTAR-POS1'})
      .withSession({
        'sessionId': 'sess-1',
        'user': {'id': 'u1', 'fullName': 'C1'},
        'outlet': {'id': 't1', 'name': 'Northstar'},
      })
      .copyWith(deviceId: 'device-1'));
  final session = backend.createSession(store: store);
  await session.init();
  return session;
}

Map<String, dynamic> _hangingOrder() => {
      'id': 'order-hang-1',
      'status': 'OPEN',
      'tableId': 'tbl-a1',
      'tableName': 'A1',
      'openedById': 'u1',
      'openedByName': 'Cashier One',
      'openedAt': DateTime.now().toIso8601String(),
      'lines': const [],
    };

void main() {
  testWidgets('no shift → New order is blocked with a Start Shift prompt', (tester) async {
    final backend = FakeBackend(); // activeShiftBody null → no OPEN shift
    final session = await _readySession(backend);

    await tester.pumpWidget(_wrap(OpenTablesScreen(session: session, config: _northstar())));
    await tester.pumpAndSettle();

    await tester.tap(find.text('New order'));
    await tester.pumpAndSettle();

    // The blocking dialog appears; the New Order screen is NOT reached.
    expect(find.text('Start a shift first'), findsOneWidget);
    expect(find.text('Start order'), findsNothing);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Start a shift first'), findsNothing);
  });

  testWidgets('no shift → entering an active table is blocked too', (tester) async {
    final backend = FakeBackend()..openOrders = [_hangingOrder()];
    final session = await _readySession(backend);

    await tester.pumpWidget(_wrap(OpenTablesScreen(session: session, config: _northstar())));
    await tester.pumpAndSettle();
    expect(find.text('A1'), findsOneWidget); // browsing the list is allowed

    await tester.tap(find.text('A1'));
    await tester.pumpAndSettle();

    expect(find.text('Start a shift first'), findsOneWidget);
    // Order entry (Payment action) must not have opened.
    expect(find.widgetWithText(OutlinedButton, 'Payment'), findsNothing);
  });

  testWidgets('shift open → New order proceeds', (tester) async {
    final backend = FakeBackend()
      ..activeShiftBody = {
        'id': 'shift-1',
        'tenantId': 't1',
        'userId': 'u1',
        'shiftType': 'MANUAL',
        'startAt': DateTime.now().toIso8601String(),
        'openHousebank': 500000,
        'status': 'OPEN',
      };
    final session = await _readySession(backend);
    await session.shiftController.restore(); // recover the OPEN shift
    expect(session.shiftController.isOpen, isTrue);

    await tester.pumpWidget(_wrap(OpenTablesScreen(session: session, config: _northstar())));
    await tester.pumpAndSettle();

    await tester.tap(find.text('New order'));
    await tester.pumpAndSettle();

    expect(find.text('Start order'), findsOneWidget); // New Order screen reached
    expect(find.text('Start a shift first'), findsNothing);
  });
}
