import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gundam_pos/state/app_session.dart';
import 'package:gundam_pos/state/session_store.dart';
import 'package:gundam_pos/ui/activation_screen.dart';
import 'package:gundam_pos/ui/home_screen.dart';
import 'package:gundam_pos/ui/login_screen.dart';
import 'package:gundam_pos/ui/theme.dart';

import 'support/fake_backend.dart';

Widget _wrap(Widget child) => MaterialApp(theme: PosTheme.theme(), home: child);

void main() {
  testWidgets('activation redeem → stage advances to login screen', (tester) async {
    final backend = FakeBackend();
    final store = InMemorySessionStore();
    final session = backend.createSession(store: store);
    await session.init(); // empty store → needActivation, deviceId assigned
    expect(session.stage, PosStage.needActivation);

    await tester.pumpWidget(_wrap(ActivationScreen(session: session)));
    expect(find.text('Activate this device'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextField, 'Activation code'), 'x' * 64);
    await tester.tap(find.text('Activate'));
    await tester.pumpAndSettle();

    expect(session.stage, PosStage.login);
    expect(session.context.deviceToken, 'dev-token-abc');
    expect(session.context.shortcode, 'NSTAR-POS1');
    // UI now routes to login.
    await tester.pumpWidget(_wrap(LoginScreen(session: session)));
    expect(find.text('Sign in to POS'), findsOneWidget);
  });

  testWidgets('login success → session ready, home shows outlet + cashier', (tester) async {
    final backend = FakeBackend();
    final store = InMemorySessionStore();
    final session = backend.createSession(store: store);
    // Simulate an already-activated device at login stage.
    await store.save(const PosContext()
        .withRedeem({'deviceToken': 'dev', 'groupId': 'g1', 'tenantId': 't1', 'shortcode': 'NSTAR-POS1'})
        .copyWith(deviceId: 'device-1'));
    await session.init();
    expect(session.stage, PosStage.login);

    await tester.pumpWidget(_wrap(LoginScreen(session: session)));
    await tester.enterText(find.widgetWithText(TextField, 'Email'), 'c@x.demo');
    await tester.enterText(find.widgetWithText(TextField, 'Password'), 'Pass1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();

    expect(session.isReady, isTrue);
    expect(session.context.outletName, 'Northstar');
    expect(session.context.userName, 'Cashier One');
    expect(session.context.roleName, 'Cashier');

    await tester.pumpWidget(_wrap(HomeScreen(session: session)));
    expect(find.text('Northstar'), findsWidgets); // app bar
    expect(find.text('Cashier One'), findsOneWidget);
    // The card under the user name shows the ROLE, not the outlet name.
    expect(find.text('Cashier'), findsOneWidget);
    expect(find.byKey(const Key('user-role')), findsOneWidget);
    expect(find.text('Open Tables'), findsOneWidget);
  });

  testWidgets('login single-active conflict → distinct error shown, stays on login', (tester) async {
    final backend = FakeBackend();
    backend.loginError = ('session_active_other_device', 409);
    final store = InMemorySessionStore();
    final session = backend.createSession(store: store);
    await store.save(const PosContext()
        .withRedeem({'deviceToken': 'dev', 'groupId': 'g1', 'tenantId': 't1', 'shortcode': 'NSTAR-POS1'})
        .copyWith(deviceId: 'device-1'));
    await session.init();

    await tester.pumpWidget(_wrap(LoginScreen(session: session)));
    await tester.enterText(find.widgetWithText(TextField, 'Email'), 'c@x.demo');
    await tester.enterText(find.widgetWithText(TextField, 'Password'), 'Pass1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();

    expect(session.isReady, isFalse);
    expect(session.stage, PosStage.login);
    expect(session.lastError, isNotNull, reason: 'login must surface a clear error');
    expect(find.textContaining('another device'), findsOneWidget);
  });

  testWidgets('sign-out from home returns to login and keeps activation', (tester) async {
    final backend = FakeBackend();
    final store = InMemorySessionStore();
    final session = backend.createSession(store: store);
    await store.save(const PosContext()
        .withRedeem({'deviceToken': 'dev', 'groupId': 'g1', 'tenantId': 't1', 'shortcode': 'NSTAR-POS1'})
        .withSession({
          'sessionId': 'sess-9',
          'user': {'id': 'u1', 'fullName': 'A'},
          'outlet': {'id': 't1', 'name': 'NS'},
        })
        .copyWith(deviceId: 'device-1'));
    await session.init();
    expect(session.stage, PosStage.ready);

    await tester.pumpWidget(_wrap(HomeScreen(session: session)));
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sign out'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sign out')); // confirm dialog
    await tester.pumpAndSettle();

    expect(session.stage, PosStage.login);
    expect(session.context.activated, isTrue, reason: 'activation outlives a session');
  });

  testWidgets('GRACE licence → BIG reminder on home, dismiss hides it (never blocks)', (tester) async {
    final backend = FakeBackend();
    backend.licenseBody = {
      'state': 'GRACE', 'grace': true,
      'validFrom': '2025-09-01T00:00:00.000Z',
      'validTo': '2026-09-01T00:00:00.000Z',
      'graceStart': '2026-09-02T00:00:00.000Z',
      'graceDays': 7,
      'graceEndsAt': '2026-09-09T00:00:00.000Z',
    };
    final store = InMemorySessionStore();
    final session = backend.createSession(store: store);
    await store.save(const PosContext()
        .withRedeem({'deviceToken': 'dev', 'groupId': 'g1', 'tenantId': 't1', 'shortcode': 'NSTAR-POS1'})
        .copyWith(deviceId: 'device-1'));
    await session.init();

    await session.login(email: 'c@x.demo', password: 'Pass1234');
    expect(session.isReady, isTrue, reason: 'a GRACE licence must NOT block the session');
    expect(session.showLicenseReminder, isTrue);

    await tester.pumpWidget(_wrap(HomeScreen(session: session)));
    expect(find.text('Licence in grace period'), findsOneWidget);
    expect(find.textContaining('Official coverage'), findsOneWidget);
    expect(find.textContaining('Grace window'), findsOneWidget);
    expect(find.textContaining('POS sales are BLOCKED'), findsOneWidget);
    expect(find.textContaining('renew from the web app'), findsOneWidget);
    expect(session.isReady, isTrue, reason: 'reminder never blocks the session');

    await tester.tap(find.text('I understand'));
    await tester.pumpAndSettle();
    expect(session.showLicenseReminder, isFalse);
    expect(find.text('Licence in grace period'), findsNothing);
  });

  testWidgets('home dashboard fits ONE screen — nothing to scroll, all tiles present', (tester) async {
    // A modest tablet surface, banner included: the dashboard must still fit.
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final backend = FakeBackend();
    backend.licenseBody = FakeBackend.activeLicense(daysLeft: 5); // banner takes space too
    final store = InMemorySessionStore();
    final session = backend.createSession(store: store);
    await store.save(const PosContext()
        .withRedeem({'deviceToken': 'dev', 'groupId': 'g1', 'tenantId': 't1', 'shortcode': 'NSTAR-POS1'})
        .copyWith(deviceId: 'device-1'));
    await session.init();
    await session.login(email: 'c@x.demo', password: 'Pass1234');
    expect(session.showLicenseReminder, isTrue);

    await tester.pumpWidget(_wrap(HomeScreen(session: session)));
    await tester.pumpAndSettle();

    for (final t in ['Open Tables', "Today's Orders", 'Approvals', 'More']) {
      expect(find.text(t), findsOneWidget, reason: '$t must be on the dashboard');
    }
    // The grid is the only scrollable: it must have NOTHING to scroll, i.e. the
    // page is exactly one screen (the operator asked for no scrolling).
    final scrollable = tester.state<ScrollableState>(
      find.descendant(of: find.byType(GridView), matching: find.byType(Scrollable)),
    );
    expect(scrollable.position.maxScrollExtent, 0,
        reason: 'the home dashboard must fit the screen — no scroll, no bottom overflow');
    expect(find.byType(ListView), findsNothing,
        reason: 'the dashboard is a single fixed page, not a scrolling list');
    expect(tester.takeException(), isNull, reason: 'no overflow while fitting the screen');
  });

  testWidgets('ACTIVE licence nearing expiry → informational reminder', (tester) async {
    final backend = FakeBackend();
    backend.licenseBody = FakeBackend.activeLicense(daysLeft: 5);
    final store = InMemorySessionStore();
    final session = backend.createSession(store: store);
    await store.save(const PosContext()
        .withRedeem({'deviceToken': 'dev', 'groupId': 'g1', 'tenantId': 't1', 'shortcode': 'NSTAR-POS1'})
        .copyWith(deviceId: 'device-1'));
    await session.init();

    await session.login(email: 'c@x.demo', password: 'Pass1234');
    expect(session.isReady, isTrue);
    expect(session.showLicenseReminder, isTrue);

    await tester.pumpWidget(_wrap(HomeScreen(session: session)));
    expect(find.text('Licence expiring soon'), findsOneWidget);
    expect(find.textContaining('before the coverage ends'), findsOneWidget);
  });

  testWidgets('ACTIVE licence far from expiry → no reminder', (tester) async {
    final backend = FakeBackend();
    final store = InMemorySessionStore();
    final session = backend.createSession(store: store);
    await store.save(const PosContext()
        .withRedeem({'deviceToken': 'dev', 'groupId': 'g1', 'tenantId': 't1', 'shortcode': 'NSTAR-POS1'})
        .copyWith(deviceId: 'device-1'));
    await session.init();

    await session.login(email: 'c@x.demo', password: 'Pass1234');
    expect(session.showLicenseReminder, isFalse);

    await tester.pumpWidget(_wrap(HomeScreen(session: session)));
    expect(find.textContaining('Licence'), findsNothing);
  });
}