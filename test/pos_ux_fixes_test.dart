import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gundam_pos/api/api_client.dart';
import 'package:gundam_pos/models/config_models.dart';
import 'package:gundam_pos/state/app_session.dart';
import 'package:gundam_pos/state/order_controller.dart';
import 'package:gundam_pos/state/session_store.dart';
import 'package:gundam_pos/ui/money_input.dart';
import 'package:gundam_pos/ui/order_entry_screen.dart';
import 'package:gundam_pos/ui/theme.dart';

import 'support/fake_backend.dart';

void main() {
  group('money fields show thousand separators, the value stays plain', () {
    TextEditingValue type(String text) => const ThousandsInputFormatter()
        .formatEditUpdate(const TextEditingValue(), TextEditingValue(text: text));

    test('typing 1000 displays 1.000 and parses back to 1000', () {
      expect(type('1000').text, '1.000');
      expect(parseMoneyInput('1.000'), 1000);
      expect(parseMoneyInput(''), 0);
    });

    test('big numbers group correctly and paste is cleaned', () {
      expect(type('1234567').text, '1.234.567');
      expect(parseMoneyInput('1.234.567'), 1234567);
      // A pasted string with currency/letters keeps only the digits.
      expect(type('Rp 1.234.567').text, '1.234.567');
      expect(parseIntInput('45.000'), 45000);
      expect(formatMoneyInput(1234567), '1.234.567');
    });

    test('empty input stays empty (never "0")', () {
      expect(type('').text, '');
      expect(type('.').text, '');
    });
  });

  group('approval / void / cancel errors say what to DO', () {
    test('a wrong approver password keeps the request pending and says so', () {
      final t = posErrorText('Approval', 'invalid_credentials');
      expect(t, contains('wrong username or password'));
      expect(t, contains('stays pending'), reason: 'the operator must know it is still hanging');
      // …and the raw code stays visible so support can grep it.
      expect(t, contains('invalid_credentials'));
    });

    test('the void guards explain the real reason', () {
      expect(posErrorText('Void failed', 'not_paid'), contains('not PAID'));
      expect(posErrorText('Void failed', 'void_outside_trading_day'),
          contains('different trading day'));
      expect(posErrorText('Cancel order', 'reason_required'), contains('reason is required'));
      expect(posErrorText('Cancel item', 'line_not_sent'), contains('never sent to the kitchen'));
      expect(posErrorText('Approval', 'approval_denied'), contains('not allowed to approve'));
      expect(posErrorText('Approval', 'already_decided'), contains('already decided'));
    });

    test('every approval-critical code avoids the bare-code fallback', () {
      const critical = [
        'invalid_credentials', 'invalid_credential', 'approval_denied', 'already_decided',
        'invalid_action_type', 'not_paid', 'void_outside_trading_day', 'no_transaction',
        'nothing_to_cancel', 'reason_required', 'line_not_sent', 'line_already_sent',
        'line_not_found', 'invalid_qty', 'order_not_found', 'require_send_cart',
        'discount_expired', 'voucher_expired', 'voucher_exhausted', 'insufficient_payment',
        'counted_total_required', 'shift_closed', 'table_locked', 'table_hanging',
      ];
      for (final code in critical) {
        final t = posErrorText('Action', code);
        expect(t, isNot(contains('($code · ')), reason: '$code still shows as a bare code');
        expect(t.length, greaterThan(25), reason: '$code has no useful explanation');
      }
    });

    test('an unknown code still names itself and the HTTP status', () {
      final t = posErrorText('Could not add item', 'weird_code', status: 418);
      expect(t, contains('weird_code'));
      expect(t, contains('418'));
    });
  });

  group('cancelling an EMPTY cart needs no reason', () {
    Future<(FakeBackend, AppSession, TenantConfig, OrderController)> ready() async {
      final backend = FakeBackend();
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
      final config = TenantConfig.fromSyncPayloads(FakeBackend.northstarMaster(), FakeBackend.northstarOutlet());
      final c = OrderController(posApi: session.posApi, tenantId: 't1', config: config, deviceAssetId: 'device-1');
      await c.startOrder(tableId: 'tbl-a1', tableName: 'A1');
      return (backend, session, config, c);
    }

    testWidgets('empty cart: cancel goes straight through (no reason dialog)', (tester) async {
      final (_, session, _, c) = await ready();
      expect(c.cart.isEmpty, isTrue);
      expect(c.canCancel, isTrue);

      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        theme: PosTheme.theme(),
        home: OrderEntryScreen(session: session, controller: c),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Cancel order'));
      await tester.pumpAndSettle();

      // No dialog asking for a reason — the order just closes.
      expect(find.text('Reason for cancelling this order'), findsNothing);
      expect(find.textContaining('Order cancelled'), findsOneWidget);
    });

    testWidgets('a cart WITH items still asks for a reason', (tester) async {
      final (_, session, config, c) = await ready();
      await c.addItem(config.itemById('item-espresso')!);
      expect(c.cart.isEmpty, isFalse);

      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        theme: PosTheme.theme(),
        home: OrderEntryScreen(session: session, controller: c),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Cancel order'));
      await tester.pumpAndSettle();
      expect(find.text('Reason for cancelling this order'), findsOneWidget);
    });
  });
}
