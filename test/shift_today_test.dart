import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gundam_pos/logic/cart.dart';
import 'package:gundam_pos/logic/money.dart' as money;
import 'package:gundam_pos/logic/shift_window.dart';
import 'package:gundam_pos/models/config_models.dart';
import 'package:gundam_pos/state/app_session.dart';
import 'package:gundam_pos/state/order_controller.dart';
import 'package:gundam_pos/state/payment_controller.dart';
import 'package:gundam_pos/state/session_store.dart';
import 'package:gundam_pos/state/shift_controller.dart';
import 'package:gundam_pos/ui/shift_screen.dart';
import 'package:gundam_pos/ui/theme.dart';
import 'package:gundam_pos/ui/today_transactions_screen.dart';

import 'support/fake_backend.dart';

TenantConfig _northstar() =>
    TenantConfig.fromSyncPayloads(FakeBackend.northstarMaster(), FakeBackend.northstarOutlet());

ShiftConfig _manualCfg() => ShiftConfig.fromJson({'shiftType': 'MANUAL'});

ShiftConfig _autoCfg({List<Map<String, dynamic>> windows = const [], Map<String, dynamic>? recap}) =>
    ShiftConfig.fromJson({
      'shiftType': 'AUTOMATIC',
      if (windows.isNotEmpty) 'mealShiftWindows': windows,
      if (recap != null) 'recapWindow': recap,
    });

Map<String, dynamic> _win(String name, int sh, int sm, int eh, int em) =>
    {'name': name, 'startHour': sh, 'startMinute': sm, 'endHour': eh, 'endMinute': em, 'enabled': true};

TenantConfig _autoTenant({List<Map<String, dynamic>> windows = const [], Map<String, dynamic>? recap}) {
  final outlet = FakeBackend.northstarOutlet();
  outlet['shift'] = {
    'shiftType': 'AUTOMATIC',
    'defaultHouseBank': '500000',
    'roundingMode': 'UP',
    if (windows.isNotEmpty) 'mealShiftWindows': windows,
    if (recap != null) 'recapWindow': recap,
  };
  return TenantConfig.fromSyncPayloads(FakeBackend.northstarMaster(), outlet);
}

Cart _espressoCart() {
  final cart = Cart();
  cart.addLine(CartLine(
    itemId: 'item-espresso',
    name: 'Espresso',
    sku: 'NSTAR-NS-ESP',
    qty: 1,
    priceLevelIndex: 0,
    unitPrice: 25000,
    vatMode: money.VatScMode.exclude,
    scMode: money.VatScMode.none,
  ));
  return cart;
}

/// An inited [AppSession] (tenant `t1`, device `dev`) so the SESSION-held
/// ShiftController + `gateFor` can be exercised — the real app path.
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

    // Default housebank prefilled → start shift (MANUAL labels).
    expect(find.text('Start Shift'), findsWidgets);
    expect(find.text('Start Shift Cash Count'), findsNothing);
    // total-only cash count is stated up front.
    expect(find.textContaining('single total'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Start Shift'));
    await tester.pumpAndSettle();
    expect(find.text('Shift open'), findsOneWidget);

    // Counted cash → end shift.
    await tester.enterText(find.byType(TextField).last, '600000');
    await tester.tap(find.widgetWithText(FilledButton, 'End Shift'));
    await tester.pumpAndSettle();

    // Closing report.
    expect(find.text('Shift closed'), findsOneWidget);
    expect(find.textContaining('-20000'), findsOneWidget);
    expect(find.text('Done'), findsOneWidget);
  });

  group('ShiftGate — labels by configured shift type', () {
    test('MANUAL offers exactly Start Shift / End Shift', () {
      final g = ShiftGate(_manualCfg());
      expect(g.startLabel, 'Start Shift');
      expect(g.endLabel, 'End Shift');
      expect(g.isAutomatic, isFalse);
      expect(g.windowNotConfigured, isFalse);
    });

    test('AUTOMATIC offers exactly the cash-count labels', () {
      final g = ShiftGate(_autoCfg(windows: [_win('Lunch', 10, 0, 15, 0)]));
      expect(g.startLabel, 'Start Shift Cash Count');
      expect(g.endLabel, 'End Shift Cash Count');
      expect(g.windowNotConfigured, isFalse);
    });

    test('AUTOMATIC with no synced window is "not configured" and gates nothing', () {
      final g = ShiftGate(_autoCfg());
      expect(g.windowNotConfigured, isTrue);
      expect(g.blockNewTransactionAt(DateTime(2026, 9, 28, 3, 0)), isNull);
    });
  });

  group('ShiftGate — meal-shift window', () {
    test('a transaction outside the window is blocked, naming the window', () {
      final g = ShiftGate(_autoCfg(windows: [_win('Lunch', 10, 0, 15, 0)]));
      final msg = g.blockNewTransactionAt(DateTime(2026, 9, 28, 9, 0));
      expect(msg, isNotNull);
      expect(msg, contains('10:00'));
      expect(msg, contains('15:00'));
    });

    test('a transaction inside the window is allowed', () {
      final g = ShiftGate(_autoCfg(windows: [_win('Lunch', 10, 0, 15, 0)]));
      expect(g.blockNewTransactionAt(DateTime(2026, 9, 28, 12, 0)), isNull);
    });

    test('MANUAL is never window-gated', () {
      final g = ShiftGate(_manualCfg());
      expect(g.blockNewTransactionAt(DateTime(2026, 9, 28, 3, 0)), isNull);
    });
  });

  group('ShiftGate — recap window / pre-midnight hanging order', () {
    ShiftConfig cfg() => _autoCfg(
          windows: [_win('Dinner', 18, 0, 23, 30)],
          recap: {'startHour': 0, 'startMinute': 0, 'durationMin': 10},
        );
    final opened = DateTime(2026, 9, 27, 23, 40);

    test('a pre-midnight hanging order is blocked inside the recap window with the alert', () {
      final now = DateTime(2026, 9, 28, 0, 5);
      final g = ShiftGate(cfg(), now: () => now);
      final msg = g.blockPaymentAt(now, opened);
      expect(msg, isNotNull);
      expect(msg, contains('NOT be counted as yesterday'));
      expect(msg, contains('recap window'));
      // the in-app clock path agrees.
      expect(g.blockPayment(opened), msg);
    });

    test('the same hanging order is payable after the recap window', () {
      final now = DateTime(2026, 9, 28, 0, 15);
      final g = ShiftGate(cfg(), now: () => now);
      expect(g.blockPayment(opened), isNull);
    });

    test('an order opened today is not treated as a midnight crossing', () {
      final g = ShiftGate(cfg());
      expect(g.hangingBlockAt(DateTime(2026, 9, 28, 12, 0), DateTime(2026, 9, 28, 11, 0)), isNull);
    });
  });

  test('next-day rule: a config change mid-shift keeps the running shift plan', () async {
    final c = ShiftController(posApi: FakeBackend().createSession().posApi, tenantId: 't1', deviceAssetId: 'd1');
    final manual = _manualCfg();
    expect(await c.open(housebank: 100000, config: manual), isTrue);
    final auto = _autoCfg(windows: [_win('Lunch', 10, 0, 15, 0)]);
    // synced config changed while the shift runs → flagged, but pinned.
    expect(c.configChangedSinceStart(auto), isTrue);
    expect(c.effectiveConfig(auto).shiftType, 'MANUAL');
    // once the shift resets, the new config applies.
    c.reset();
    expect(c.configChangedSinceStart(auto), isFalse);
    expect(c.effectiveConfig(auto).shiftType, 'AUTOMATIC');
  });

  test('a new transaction cannot start outside the meal-shift window', () async {
    final config = _autoTenant(windows: [_win('Lunch', 10, 0, 15, 0)]);
    final c = OrderController(
      posApi: FakeBackend().createSession().posApi,
      tenantId: 't1',
      config: config,
      deviceAssetId: 'dev',
      shiftGate: ShiftGate(config.shift, now: () => DateTime(2026, 9, 28, 9, 0)),
    );
    expect(await c.startOrder(tableId: 'tbl-a1', tableName: 'A1'), isFalse);
    expect(c.orderId, isNull);
    expect(c.error, contains('10:00'));
  });

  test('a payment in the recap window for a pre-midnight hanging order is blocked with the alert', () async {
    final config = _autoTenant(
      windows: [_win('Dinner', 18, 0, 23, 30)],
      recap: {'startHour': 0, 'startMinute': 0, 'durationMin': 10},
    );
    final c = PaymentController(
      posApi: FakeBackend().createSession().posApi,
      tenantId: 't1',
      config: config,
      orderId: 'order-1',
      tableName: 'A1',
      cart: _espressoCart(),
      deviceAssetId: 'dev',
      shortcode: 'N',
      openedAt: DateTime(2026, 9, 27, 23, 40),
      shiftGate: ShiftGate(config.shift, now: () => DateTime(2026, 9, 28, 0, 5)),
    );
    c.addPayment(config.paymentMethods.firstWhere((m) => m.type == money.PayType.cash), 1000000);
    expect(c.covered, isTrue);
    expect(await c.settle(), isFalse);
    expect(c.receiptId, isNull);
    expect(c.error, contains('NOT be counted as yesterday'));
  });

  // --- the app-wide gate (session-held controller) --------------------------

  test('meal-shift block fires on the real order path through the session gate', () async {
    final config = _autoTenant(windows: [_win('Lunch', 10, 0, 15, 0)]);
    final session = await _readySession(FakeBackend());
    // Exactly what NewOrderScreen builds: the session's effective gate.
    final c = OrderController(
      posApi: session.posApi,
      tenantId: session.tenantId!,
      config: config,
      deviceAssetId: session.context.deviceId,
      shiftGate: session.gateFor(config, now: () => DateTime(2026, 9, 28, 9, 0)),
    );
    expect(await c.startOrder(tableId: 'tbl-a1', tableName: 'A1'), isFalse);
    expect(c.orderId, isNull);
    expect(c.error, contains('10:00'));
    expect(c.error, contains('15:00'));
  });

  test('openedAt from createOrder reaches PaymentController and the recap alert fires', () async {
    final config = _autoTenant(
      windows: [_win('Dinner', 18, 0, 23, 59)],
      recap: {'startHour': 0, 'startMinute': 0, 'durationMin': 10},
    );
    final backend = FakeBackend()..openOrderOpenedAt = DateTime(2026, 9, 27, 23, 40);
    final session = await _readySession(backend);
    final oc = OrderController(
      posApi: session.posApi,
      tenantId: session.tenantId!,
      config: config,
      deviceAssetId: session.context.deviceId,
      shiftGate: session.gateFor(config, now: () => DateTime(2026, 9, 27, 23, 40)),
    );
    expect(await oc.startOrder(tableId: 'tbl-a1', tableName: 'A1'), isTrue);
    // The server row's openedAt is parsed onto the controller…
    expect(oc.openedAt, DateTime(2026, 9, 27, 23, 40));

    // …and handed to the payment flow exactly as OrderEntryScreen does it.
    final pc = PaymentController(
      posApi: session.posApi,
      tenantId: session.tenantId!,
      config: config,
      orderId: oc.orderId!,
      tableName: 'A1',
      cart: _espressoCart(),
      deviceAssetId: session.context.deviceId,
      shortcode: session.shortcode,
      openedAt: oc.openedAt,
      shiftGate: session.gateFor(config, now: () => DateTime(2026, 9, 28, 0, 5)),
    );
    pc.addPayment(config.paymentMethods.firstWhere((m) => m.type == money.PayType.cash), 1000000);
    expect(pc.covered, isTrue);
    expect(pc.paymentBlock, isNotNull);
    expect(await pc.settle(), isFalse);
    expect(pc.receiptId, isNull);
    expect(pc.error, contains('NOT be counted as yesterday'));
    expect(pc.error, contains('recap window'));
  });

  test('next-day rule holds app-wide: the session gate keeps the pinned config', () async {
    final session = await _readySession(FakeBackend());
    final manual = _manualCfg();
    expect(await session.shiftController.open(housebank: 100000, config: manual), isTrue);

    // The live config changes to AUTOMATIC mid-shift.
    final autoLive = _autoTenant(windows: [_win('Lunch', 10, 0, 15, 0)]);
    expect(session.shiftController.configChangedSinceStart(autoLive.shift), isTrue);

    // The app-wide gate still reports the shift's pinned MANUAL rules…
    final g = session.gateFor(autoLive);
    expect(g.isAutomatic, isFalse);
    expect(g.startLabel, 'Start Shift');
    // …so the live AUTOMATIC window gates nothing while this shift runs.
    expect(g.blockNewTransactionAt(DateTime(2026, 9, 28, 9, 0)), isNull);
  });

  test('MANUAL with no windows configured: the session gate never blocks', () async {
    final session = await _readySession(FakeBackend());
    final g = session.gateFor(_northstar(), now: () => DateTime(2026, 9, 28, 3, 0));
    expect(g.windowNotConfigured, isFalse);
    expect(g.blockNewTransaction(), isNull);
    expect(g.blockPayment(DateTime(2026, 9, 27, 23, 40)), isNull);
  });

  testWidgets('AUTOMATIC shift offers only the cash-count function', (tester) async {
    final backend = FakeBackend();
    final store = InMemorySessionStore();
    await store.save(const PosContext()
        .withRedeem({'deviceToken': 'd', 'groupId': 'g1', 'tenantId': 't1', 'shortcode': 'N'})
        .withSession({'sessionId': 's1', 'user': {'id': 'u1', 'fullName': 'C1'}, 'outlet': {'id': 't1', 'name': 'NS'}})
        .copyWith(deviceId: 'dev'));
    final session = backend.createSession(store: store);
    await session.init();

    await tester.pumpWidget(MaterialApp(
      theme: PosTheme.theme(),
      home: ShiftScreen(session: session, config: _autoTenant(windows: [_win('Lunch', 10, 0, 15, 0)])),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Start Shift Cash Count'), findsWidgets);
    expect(find.text('Start Shift'), findsNothing);
    expect(find.text('End Shift'), findsNothing);
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