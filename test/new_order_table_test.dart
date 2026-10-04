import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gundam_pos/models/config_models.dart';
import 'package:gundam_pos/state/app_session.dart';
import 'package:gundam_pos/state/session_store.dart';
import 'package:gundam_pos/ui/new_order_screen.dart';
import 'package:gundam_pos/ui/theme.dart';

import 'support/fake_backend.dart';

/// Field bug: picking "Other table", typing a name and then tapping Start order
/// did nothing — the button only unlocked after tapping "Other table" AGAIN,
/// because the free-text field had no onChanged and the chip tap was the only
/// setState. A typed name alone must be enough.

TenantConfig _northstar() =>
    TenantConfig.fromSyncPayloads(FakeBackend.northstarMaster(), FakeBackend.northstarOutlet());

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

FilledButton _startButton(WidgetTester tester) =>
    tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Start order'));

void main() {
  testWidgets('free-text table: Start order unlocks as soon as a name is typed', (tester) async {
    final backend = FakeBackend();
    final session = await _readySession(backend);
    await tester.pumpWidget(MaterialApp(
      theme: PosTheme.theme(),
      home: NewOrderScreen(session: session, config: _northstar()),
    ));
    await tester.pumpAndSettle();

    // Nothing chosen yet → blocked.
    expect(_startButton(tester).onPressed, isNull);

    await tester.tap(find.text('Other table'));
    await tester.pumpAndSettle();
    expect(_startButton(tester).onPressed, isNull, reason: 'no name typed yet');

    // Type a name — WITHOUT touching the chip again the button must unlock.
    await tester.enterText(find.widgetWithText(TextField, 'Table name'), 'Terrace');
    await tester.pump();

    expect(_startButton(tester).onPressed, isNotNull,
        reason: 'a typed table name alone must enable Start order');
  });
}
