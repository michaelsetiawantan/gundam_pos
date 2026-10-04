import 'package:flutter/material.dart';
import 'package:gundam_pos/logic/money.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gundam_pos/models/config_models.dart';
import 'package:gundam_pos/state/app_session.dart';
import 'package:gundam_pos/state/session_store.dart';
import 'package:gundam_pos/state/shift_controller.dart';
import 'package:gundam_pos/ui/shift_screen.dart';
import 'package:gundam_pos/ui/theme.dart';

import 'support/fake_backend.dart';

TenantConfig _northstar() =>
    TenantConfig.fromSyncPayloads(FakeBackend.northstarMaster(), FakeBackend.northstarOutlet());

Map<String, dynamic> _openShift({double housebank = 375000}) => {
      'id': 'shift-restored',
      'tenantId': 't1',
      'userId': 'u1',
      'shiftType': 'MANUAL',
      'startAt': DateTime.now().toIso8601String(),
      'openHousebank': housebank,
      'status': 'OPEN',
    };

Future<AppSession> _readySession(FakeBackend backend) async {
  final store = InMemorySessionStore();
  await store.save(const PosContext()
      .withRedeem({'deviceToken': 'd', 'groupId': 'g1', 'tenantId': 't1', 'shortcode': 'N'})
      .withSession({'sessionId': 's1', 'user': {'id': 'u1', 'fullName': 'C1'}, 'outlet': {'id': 't1', 'name': 'NS'}})
      .copyWith(deviceId: 'dev'));
  final session = backend.createSession(store: store);
  await session.init();
  return session;
}

void main() {
  group('ShiftController — housebank lifecycle', () {
    test('open sends the TYPED opening cash to the server and keeps it', () async {
      final backend = FakeBackend();
      final c = ShiftController(posApi: backend.createSession().posApi, tenantId: 't1', deviceAssetId: 'dev');
      expect(await c.open(housebank: 375000), isTrue);
      // the value the operator typed actually reaches the server (was dropped before).
      expect(backend.lastShiftOpenBody!['openHousebank'], 375000);
      expect(c.startHousebank, 375000);
      expect(c.openingHousebank, 375000);
    });

    test('restore recovers an OPEN shift after a restart', () async {
      final backend = FakeBackend()..activeShiftBody = _openShift();
      final c = ShiftController(posApi: backend.createSession().posApi, tenantId: 't1', deviceAssetId: 'dev');
      expect(c.isOpen, isFalse);

      await c.restore();
      expect(c.isOpen, isTrue);
      expect(c.openingHousebank, 375000);
      expect(c.startHousebank, 375000);
    });

    test('restore with no active shift leaves the controller closed', () async {
      final backend = FakeBackend();
      final c = ShiftController(posApi: backend.createSession().posApi, tenantId: 't1');
      await c.restore();
      expect(c.isOpen, isFalse);
      expect(c.isClosed, isFalse);
    });

    test('a shift that is CLOSED/AUTO_CLOSED on the server is not shown as active', () async {
      final backend = FakeBackend()..activeShiftBody = _openShift();
      final c = ShiftController(posApi: backend.createSession().posApi, tenantId: 't1');
      await c.open(housebank: 100000);
      expect(c.isOpen, isTrue);

      // server now has no OPEN shift → restore clears the stale local state.
      backend.activeShiftBody = null;
      await c.restore();
      expect(c.isOpen, isFalse);
    });
  });

  testWidgets('start → end: the typed opening cash survives into the end panel', (tester) async {
    final backend = FakeBackend();
    final session = await _readySession(backend);

    await tester.pumpWidget(MaterialApp(
      theme: PosTheme.theme(),
      home: ShiftScreen(session: session, config: _northstar()),
    ));
    await tester.pumpAndSettle();

    // Type a NON-default opening cash, then start the shift.
    await tester.enterText(find.byType(TextField).first, '375000');
    await tester.tap(find.widgetWithText(FilledButton, 'Start Shift'));
    await tester.pumpAndSettle();

    // The end panel shows the value the operator typed (not the tenant default).
    expect(find.text('Shift open'), findsOneWidget);
    expect(find.textContaining(moneyLabel(375000, 'Rp')), findsWidgets);
    expect(backend.lastShiftOpenBody!['openHousebank'], 375000);
  });

  testWidgets('reopened app: an OPEN shift on the server opens straight into the end panel', (tester) async {
    final backend = FakeBackend()..activeShiftBody = _openShift(housebank: 250000);
    final session = await _readySession(backend);

    await tester.pumpWidget(MaterialApp(
      theme: PosTheme.theme(),
      home: ShiftScreen(session: session, config: _northstar()),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Shift open'), findsOneWidget);
    expect(find.text('Start Shift'), findsNothing);
    expect(find.textContaining(moneyLabel(250000, 'Rp')), findsWidgets);
  });
}
