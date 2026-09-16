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

    await tester.enterText(find.byType(TextField), 'x' * 64);
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
    await tester.enterText(find.byType(TextField).last, 'Pass1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();

    expect(session.isReady, isTrue);
    expect(session.context.outletName, 'Northstar');
    expect(session.context.userName, 'Cashier One');

    await tester.pumpWidget(_wrap(HomeScreen(session: session)));
    expect(find.text('Northstar'), findsWidgets); // app bar + context card
    expect(find.text('Cashier One'), findsOneWidget);
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
    await tester.enterText(find.byType(TextField).last, 'Pass1234');
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
}