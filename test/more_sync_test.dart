import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gundam_pos/services/printer_health.dart';
import 'package:gundam_pos/state/session_store.dart';
import 'package:gundam_pos/ui/more_screen.dart';
import 'package:gundam_pos/ui/theme.dart';

import 'support/fake_backend.dart';

void main() {
  group('PrinterHealthChecker', () {
    PrinterHealthChecker checker({required bool reachable}) => PrinterHealthChecker(
          connect: (_, __) async => reachable,
        );

    test('reachable network + device status support → ready', () async {
      final link = await checker(reachable: true).check(transport: 'NETWORK', host: '10.0.0.5', port: 9100, supportsDeviceStatus: true);
      expect(link.state, PrinterLinkState.ready);
      expect(link.isUsable, isTrue);
    });

    test('reachable but no device-status support → unknown (never claim healthy)', () async {
      final link = await checker(reachable: true).check(transport: 'NETWORK', host: '10.0.0.5', port: 9100, supportsDeviceStatus: false);
      expect(link.state, PrinterLinkState.unknown);
    });

    test('unreachable network → offline', () async {
      final link = await checker(reachable: false).check(transport: 'NETWORK', host: '10.0.0.5', port: 9100);
      expect(link.state, PrinterLinkState.offline);
      expect(link.isUsable, isFalse);
    });

    test('bluetooth without a MAC → not paired; usb without addressing → offline', () async {
      final c = checker(reachable: true);
      expect((await c.check(transport: 'BLUETOOTH')).state, PrinterLinkState.notPaired);
      // USB Host is wired now; a printer with no VID:PID/chip is reported offline.
      expect((await c.check(transport: 'USB')).state, PrinterLinkState.offline);
    });

    test('bluetooth with a MAC probes the SPP link (injected)', () async {
      final c = PrinterHealthChecker(
        bluetooth: (mac, _) async => PrinterLink(PrinterLinkState.permissionRequired, detail: 'denied'),
      );
      final link = await c.check(transport: 'BLUETOOTH', bluetoothMac: 'AA:BB:CC:DD:EE:FF');
      expect(link.state, PrinterLinkState.permissionRequired);
      expect(link.isUsable, isFalse);
    });
  });

  testWidgets('More screen shows sync, printer health, update, sign out', (tester) async {
    final backend = FakeBackend();
    final store = InMemorySessionStore();
    await store.save(const PosContext()
        .withRedeem({'deviceToken': 'd', 'groupId': 'g1', 'tenantId': 't1', 'shortcode': 'NSTAR-POS1'})
        .withSession({'sessionId': 's1', 'user': {'id': 'u1', 'fullName': 'C1'}, 'outlet': {'id': 't1', 'name': 'Northstar'}})
        .copyWith(deviceId: 'device-1'));
    final session = backend.createSession(store: store);
    await session.init();

    await tester.pumpWidget(MaterialApp(theme: PosTheme.theme(), home: MoreScreen(session: session)));
    await tester.pumpAndSettle();

    expect(find.text('Sync'), findsOneWidget);
    expect(find.textContaining('0 item(s)'), findsOneWidget); // pending push empty
    // 'Printer health' may sit below the fold (new Server section above it).
    await tester.scrollUntilVisible(find.text('Printer health'), 300, scrollable: find.byType(Scrollable).first);
    expect(find.text('Printer health'), findsOneWidget);

    // Scroll to the lower sections (sign-out + update) which are below the fold.
    await tester.scrollUntilVisible(find.text('Sign out of this device'), 300, scrollable: find.byType(Scrollable).first);
    expect(find.text('Sign out of this device'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Client update'), -300, scrollable: find.byType(Scrollable).first);
    expect(find.text('Client update'), findsOneWidget);

    // Refresh pulls the Northstar config via the fake backend.
    // Drag until the button is built, then ensureVisible positions it fully —
    // a fixed scroll delta can park it under the app bar when sections grow.
    final scrollable = find.byType(Scrollable).first;
    await tester.dragUntilVisible(find.text('Refresh config'), scrollable, const Offset(0, 200));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Refresh config'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Refresh config'));
    await tester.pumpAndSettle();
    expect(session.config, isNotNull);
    expect(session.pendingPushCount, 0);
    expect(find.textContaining('Config synced'), findsOneWidget);
  });
}