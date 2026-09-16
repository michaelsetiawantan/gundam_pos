import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gundam_pos/models/config_models.dart';
import 'package:gundam_pos/state/session_store.dart';
import 'package:gundam_pos/state/shift_controller.dart';
import 'package:gundam_pos/ui/shift_screen.dart';
import 'package:gundam_pos/ui/theme.dart';
import 'package:gundam_pos/ui/today_transactions_screen.dart';

import 'support/fake_backend.dart';

TenantConfig _northstar() =>
    TenantConfig.fromSyncPayloads(FakeBackend.northstarMaster(), FakeBackend.northstarOutlet());

void main() {
  group('ShiftController', () {
    test('open total-only cash count then close computes variance', () async {
      final c = ShiftController(posApi: FakeBackend().createSession().posApi, tenantId: 't1', deviceAssetId: 'd1');
      expect(c.isOpen, isFalse);
      expect(await c.open(housebank: 500000), isTrue);
      expect(c.isOpen, isTrue);
      expect(c.openingHousebank, 500000);

      expect(await c.close(countedTotal: 600000), isTrue);
      expect(c.isClosed, isTrue);
      final cl = c.closing!;
      expect(cl['status'], 'CLOSED');
      expect(cl['variance'], -20000);
      // reported closing fields present
      expect(cl['cashSales'], 120000);
      expect(cl['expectedCash'], 620000);
    });

    test('close before open is rejected (open guard)', () async {
      final c = ShiftController(posApi: FakeBackend().createSession().posApi, tenantId: 't1');
      expect(await c.close(countedTotal: 10), isFalse);
    });
  });

  testWidgets('start shift → end shift → closing report with variance', (tester) async {
    final backend = FakeBackend();
    final store = InMemorySessionStore();
    await store.save(const PosContext()
        .withRedeem({'deviceToken': 'd', 'groupId': 'g1', 'tenantId': 't1', 'shortcode': 'N'})
        .withSession({'sessionId': 's1', 'user': {'id': 'u1', 'fullName': 'C1'}, 'outlet': {'id': 't1', 'name': 'NS'}})
        .copyWith(deviceId: 'dev'));
    final session = backend.createSession(store: store);
    await session.init();

    await tester.pumpWidget(MaterialApp(theme: PosTheme.theme(), home: ShiftScreen(session: session, config: _northstar())));
    await tester.pumpAndSettle();

    // Default housebank prefilled → start shift.
    expect(find.text('Start shift'), findsWidgets);
    await tester.tap(find.widgetWithText(FilledButton, 'Start shift'));
    await tester.pumpAndSettle();
    expect(find.text('Shift open'), findsOneWidget);

    // Counted cash → end shift.
    await tester.enterText(find.byType(TextField).last, '600000');
    await tester.tap(find.widgetWithText(FilledButton, 'End shift'));
    await tester.pumpAndSettle();

    // Closing report.
    expect(find.text('Shift closed'), findsOneWidget);
    expect(find.textContaining('-20000'), findsOneWidget);
    expect(find.text('Done'), findsOneWidget);
  });

  testWidgets('Today screen renders settled bills and past-day void routes to Web', (tester) async {
    final backend = FakeBackend();
    final store = InMemorySessionStore();
    await store.save(const PosContext()
        .withRedeem({'deviceToken': 'd', 'groupId': 'g1', 'tenantId': 't1', 'shortcode': 'N'})
        .withSession({'sessionId': 's1', 'user': {'id': 'u1', 'fullName': 'C1'}, 'outlet': {'id': 't1', 'name': 'NS'}})
        .copyWith(deviceId: 'dev'));
    final session = backend.createSession(store: store);
    await session.init();

    session.noteSettled({
      'receiptId': 'NSTAR-POS1-20260917-14:05-0000001',
      'total': 28000,
      'orderId': 'order-1',
      'paidAt': DateTime.now().toIso8601String(),
    });

    await tester.pumpWidget(MaterialApp(theme: PosTheme.theme(), home: TodayTransactionsScreen(session: session)));
    await tester.pumpAndSettle();
    expect(find.textContaining('NSTAR-POS1-20260917-14:05-0000001'), findsOneWidget);

    // Past-day bill → web refund note.
    session.noteSettled({
      'receiptId': 'N-OUT-00000000000000',
      'total': 10000,
      'orderId': 'order-past',
      'paidAt': DateTime(2026, 9, 10).toIso8601String(),
    });
    await tester.pumpAndSettle();
    expect(find.textContaining('N-OUT'), findsOneWidget);

    final pastCard = find.widgetWithText(Card, 'N-OUT-00000000000000');
    await tester.tap(find.descendant(of: pastCard, matching: find.byType(PopupMenuButton<String>)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Void (same-day)'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Web Past Bill'), findsOneWidget);
  });
}