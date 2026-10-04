import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gundam_pos/logic/cart.dart';
import 'package:gundam_pos/models/config_models.dart';
import 'package:gundam_pos/state/app_session.dart';
import 'package:gundam_pos/state/order_controller.dart';
import 'package:gundam_pos/state/session_store.dart';
import 'package:gundam_pos/ui/order_entry_screen.dart';
import 'package:gundam_pos/ui/theme.dart';

import 'support/fake_backend.dart';

/// Field symptom: after picking items the operator cannot go on — Payment is
/// dead (the cart has "unsent" lines) and, when the send-cart call is rejected
/// or its response is lost, nothing ever clears that gate. These tests pin the
/// two traps: a permanent `nothing_to_send` latch and an unexpected throw that
/// is swallowed with no message.
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

void main() {
  group('send-cart recovery — the operator must never be trapped', () {
    test('nothing_to_send reconciles: server already sent → payment unlocks', () async {
      final backend = FakeBackend();
      final session = await _readySession(backend);
      final config = _northstar();
      final c = OrderController(posApi: session.posApi, tenantId: 't1', config: config, deviceAssetId: 'device-1');
      await c.startOrder(tableId: 'tbl-a1', tableName: 'A1');
      await c.addItem(config.itemById('item-espresso')!);

      // The first send succeeded on the server but its response was lost; the
      // operator taps Send cart again and the server (authoritative) says there
      // is nothing unsent.
      backend.sendCartError = 'nothing_to_send';

      expect(c.hasUnsentLines, isTrue, reason: 'local state still looks unsent');
      expect(c.canPay, isFalse);

      final ok = await c.sendCart();

      expect(ok, isTrue, reason: 'a no-op send must still let the flow continue');
      expect(c.hasUnsentLines, isFalse, reason: 'local lines reconciled with the server');
      expect(c.canPay, isTrue, reason: 'Payment must unlock instead of staying dead');
      expect(c.error, isNull);
    });

    test('server rejection is surfaced and never leaves a silent dead end', () async {
      final backend = FakeBackend()..sendCartError = 'shift_required';
      final session = await _readySession(backend);
      final config = _northstar();
      final c = OrderController(posApi: session.posApi, tenantId: 't1', config: config, deviceAssetId: 'device-1');
      await c.startOrder(tableId: 'tbl-a1', tableName: 'A1');
      await c.addItem(config.itemById('item-espresso')!);

      expect(await c.sendCart(), isFalse);
      expect(c.error, isNotNull, reason: 'the cause must be visible, not swallowed');
      expect(c.error, contains('Start a shift'), reason: 'the server cause is explained, not a raw code');
    });

    test('network loss is surfaced, not swallowed', () async {
      final backend = FakeBackend()..sendCartOffline = true;
      final session = await _readySession(backend);
      final config = _northstar();
      final c = OrderController(posApi: session.posApi, tenantId: 't1', config: config, deviceAssetId: 'device-1');
      await c.startOrder(tableId: 'tbl-a1', tableName: 'A1');
      await c.addItem(config.itemById('item-espresso')!);

      expect(await c.sendCart(), isFalse);
      expect(c.error, isNotNull);
      expect(c.error!.toLowerCase(), contains('network'));
    });

    test('a send with no server order id fails loudly instead of throwing', () async {
      final backend = FakeBackend();
      final session = await _readySession(backend);
      final c = OrderController(
        posApi: session.posApi,
        tenantId: 't1',
        config: _northstar(),
        deviceAssetId: 'device-1',
      );
      // Cart has a line but the order was never linked to the server (orderId null).
      c.cart.addLine(CartLine(
        itemId: 'item-espresso',
        name: 'Espresso',
        sku: 'ESP',
        qty: 1,
        priceLevelIndex: 0,
        unitPrice: 25000,
      ));

      // Before the fix this threw a null-check error that no UI layer caught.
      expect(await c.sendCart(), isFalse);
      expect(c.error, isNotNull, reason: 'the operator must see why nothing happened');
    });
  });

  testWidgets('send-cart failure is visible and offers a way back to the tables', (tester) async {
    final backend = FakeBackend()..sendCartError = 'shift_required';
    final session = await _readySession(backend);
    final config = _northstar();
    final c = OrderController(posApi: session.posApi, tenantId: 't1', config: config, deviceAssetId: 'device-1');
    await c.startOrder(tableId: 'tbl-a1', tableName: 'A1');
    await c.addItem(config.itemById('item-espresso')!);

    await tester.pumpWidget(_wrap(OrderEntryScreen(session: session, controller: c)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Send cart'));
    await tester.pumpAndSettle();

    // The refusal is shown on the screen (persistent banner) AND in the snackbar,
    // with a named way out instead of a dead end.
    expect(find.textContaining('Start a shift'), findsWidgets);
    expect(find.text('Back to tables'), findsOneWidget);
    expect(c.canPay, isFalse);
  });
}
