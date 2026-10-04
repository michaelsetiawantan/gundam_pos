import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gundam_pos/logic/cart.dart';
import 'package:gundam_pos/logic/money.dart' as money;
import 'package:gundam_pos/models/config_models.dart';
import 'package:gundam_pos/services/print_dispatcher.dart';
import 'package:gundam_pos/state/app_session.dart';
import 'package:gundam_pos/state/order_controller.dart';
import 'package:gundam_pos/state/payment_controller.dart';
import 'package:gundam_pos/state/session_store.dart';
import 'package:gundam_pos/ui/theme.dart';
import 'package:gundam_pos/ui/today_transactions_screen.dart';

import 'support/fake_backend.dart';
import 'support/print_support.dart';

/// Offline-first POS: (1) settle without a server, (2) send-cart without a
/// server, (3) deferred push with FAILED handling, (4) PAID vs PAID - Offline.
/// Every assertion is falsifiable against the FakeBackend's real request log.

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

Cart _singleEspresso() {
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

Future<List<Map<String, dynamic>>> _settleQueue(AppSession s) async =>
    (await s.pushStore.pending()).where((i) => i['type'] == 'order_settle').toList();

void main() {
  late FakeBackend backend;
  late AppSession session;
  late TenantConfig config;

  setUp(() async {
    backend = FakeBackend();
    session = await _readySession(backend);
    config = _northstar();
  });

  PaymentController pay(Cart cart, {PrintDispatcher? printer}) => PaymentController(
        posApi: session.posApi,
        tenantId: 't1',
        config: config,
        orderId: 'order-1',
        tableName: 'A1',
        cart: cart,
        deviceAssetId: 'device-1',
        shortcode: 'NSTAR-POS1',
        receipts: session.receipts,
        pushStore: session.pushStore,
        onSettled: session.noteSettled,
        printer: printer,
      );

  OutletPaymentMethod cash() => config.paymentMethods.firstWhere((m) => m.type == money.PayType.cash);

  // (a) settle with an unreachable server still completes the sale locally.
  test('(a) settle offline → sale PAID locally + 1 order_settle queued + bill printed', () async {
    backend.settleOffline = true;
    final d = GatedDispatcher();
    final c = pay(_singleEspresso(), printer: d);
    c.addPayment(cash(), 28000);

    expect(await c.settle(), isTrue, reason: 'a dead network must never fail the sale');
    expect(c.error, isNull);
    expect(c.offlineSettled, isTrue);
    expect(c.receiptId, startsWith('NSTAR-POS1-'), reason: 'device-minted receipt id');
    expect(d.billCalls, 1, reason: 'the bill still prints on the LOCAL path');
    d.gate.complete();

    final queued = await _settleQueue(session);
    expect(queued, hasLength(1), reason: 'exactly one deferred settlement queued');
    final key = queued.single['id'] as String;
    expect(key, c.receiptId, reason: 'key = the device receipt id (unique per settle)');
    final payload = queued.single['payload_json'] as Map;
    expect(payload['receiptId'], c.receiptId);
    expect(payload['orderId'], 'order-1');
    expect((payload['lines'] as List), hasLength(1));
    expect(((payload['totals'] as Map)['total']), 28000);

    // Session shows it as a LOCAL (not-yet-synced) settlement.
    expect(session.pendingSettlements, hasLength(1));
    expect(session.pendingSettlements.single.status, 'pending');
    expect(session.todayBills.single['offline'], isTrue);
  });

  // (b) a successful push flips the local settlement to synced (PAID).
  test('(b) push success → queue drained + settlement synced (PAID)', () async {
    backend.settleOffline = true;
    final d = GatedDispatcher();
    final c = pay(_singleEspresso(), printer: d);
    c.addPayment(cash(), 28000);
    await c.settle();
    d.gate.complete();
    final key = c.receiptId!;

    backend.settleOffline = false;
    expect(await session.flushSettlements(), 1);

    expect(await _settleQueue(session), isEmpty, reason: 'accepted → dropped from the queue');
    expect(session.settlementFor(key)!.status, 'synced');
    expect(session.failedSettlementCount, 0);
    expect(session.pendingSettlements, isEmpty);
    expect(session.todayBills.single['offline'], isFalse, reason: 'local bill flips to server-PAID');
  });

  // (c) a 4xx refusal is FAILED + code + cashier notice; re-commit sends the NEW payload.
  test('(c) push 4xx → FAILED + code stored + notified; re-commit sends the fresh payload', () async {
    backend.settleOffline = true;
    final d = GatedDispatcher();
    final c = pay(_singleEspresso(), printer: d);
    c.addPayment(cash(), 28000);
    await c.settle();
    d.gate.complete();
    final key = c.receiptId!;

    backend.settleOffline = false;
    backend.settleDeferredError = 'totals_mismatch';
    expect(await session.flushSettlements(), 0, reason: 'refused — nothing accepted');

    final rec = session.settlementFor(key)!;
    expect(rec.status, 'failed');
    expect(rec.errorCode, 'totals_mismatch', reason: 'the server code is stored, never swallowed');
    expect(session.failedSettlementCount, 1);
    expect(session.settlementNotices, isNotEmpty, reason: 'the cashier is told, never silent');
    expect(await _settleQueue(session), hasLength(1), reason: 'a refused settle stays queued, not lost');

    // Auto-push must NOT blind-retry a refused settlement...
    expect(await session.flushSettlements(), 0);
    expect(backend.settleDeferredCalls, 1, reason: 'no auto-retry until the cashier re-commits');

    // ...until the cashier commits again WITH the corrected, latest details.
    final old = Map<String, dynamic>.from((await _settleQueue(session)).single['payload_json'] as Map);
    final fresh = {...old, 'paidAt': '2099-01-01T00:00:00.000Z'};
    backend.settleDeferredError = null;
    expect(await session.recommitSettlement(key, payload: fresh), isTrue);

    expect(backend.lastSettleDeferredBody!['paidAt'], '2099-01-01T00:00:00.000Z',
        reason: 'the re-commit sends the NEW snapshot, not the stale one');
    expect(session.settlementFor(key)!.status, 'synced');
    expect(await _settleQueue(session), isEmpty);
  });

  // (d) send-cart with an unreachable server: lines sent locally + print now.
  test('(d) send cart offline → lines sent + captain printed + settle unblocked', () async {
    final d = GatedDispatcher();
    final c = OrderController(
      posApi: session.posApi,
      tenantId: 't1',
      config: config,
      deviceAssetId: 'device-1',
      pushStore: session.pushStore,
      printer: d,
    );
    await c.startOrder(tableId: 'tbl-a1', tableName: 'A1');
    backend.addLineOffline = true;
    await c.addItem(config.itemById('item-espresso')!);
    expect(c.canPay, isFalse, reason: 'unsent line blocks payment');

    expect(await c.sendCart(), isTrue, reason: 'no server needed to allow the send');
    expect(c.hasUnsentLines, isFalse, reason: 'lines marked sent LOCALLY');
    expect(c.canPay, isTrue, reason: 'payment gate reads LOCAL sent state');
    expect(d.sendCartCalls, 1, reason: 'captain/bev printed on the LOCAL path NOW');
    d.gate.complete();

    final sends = (await session.pushStore.pending()).where((i) => i['type'] == 'order_send');
    expect(sends, hasLength(1), reason: 'one order_send queued for the next push');
  });

  // (e) idempotency: a settle pushed twice with the same key never duplicates.
  test('(e) same clientSettlementKey pushed twice → no duplicate', () async {
    backend.settleOffline = true;
    final d = GatedDispatcher();
    final c = pay(_singleEspresso(), printer: d);
    c.addPayment(cash(), 28000);
    await c.settle();
    d.gate.complete();
    final key = c.receiptId!;

    // Re-enqueueing the same key must NOT add a second queue row (dedupe).
    final payload = (await _settleQueue(session)).single['payload_json'] as Object;
    await session.enqueuePush('order_settle', key, payload);
    expect(await _settleQueue(session), hasLength(1), reason: 'upsert on the same key');

    backend.settleOffline = false;
    expect(await session.flushSettlements(), 1);
    expect(backend.settleDeferredCalls, 1, reason: 'one POST for one settlement');
    // A second flush finds nothing — no repeat, no duplicate sale.
    expect(await session.flushSettlements(), 0);
    expect(backend.settleDeferredCalls, 1);
    expect(await _settleQueue(session), isEmpty);
  });

  // (4) Today's list labels: PAID - Offline while local, FAILED with the reason.
  testWidgets('(4) Today shows PAID - Offline, then FAILED with the server reason', (tester) async {
    session.noteSettled({
      'orderId': 'order-9',
      'receiptId': 'NSTAR-POS1-20261004-12:00-0000007',
      'status': 'PAID',
      'total': 28000,
      'paidAt': DateTime.now().toUtc().toIso8601String(),
      'offline': true,
      'clientSettlementKey': 'NSTAR-POS1-20261004-12:00-0000007',
    });
    final key = 'NSTAR-POS1-20261004-12:00-0000007';
    expect(session.settlementFor(key)!.status, 'pending');

    await tester.pumpWidget(MaterialApp(theme: PosTheme.theme(), home: TodayTransactionsScreen(session: session)));
    await tester.pumpAndSettle();
    expect(find.text('PAID - Offline'), findsOneWidget, reason: 'local-only sale is labelled honestly');

    // The server refuses a later push: the row becomes FAILED with its code.
    session.settlementFor(key)!
      ..status = 'failed'
      ..errorCode = 'totals_mismatch';
    // Re-mount (fresh State) so the list rebuilds from the updated status.
    await tester.pumpWidget(MaterialApp(
      theme: PosTheme.theme(),
      home: TodayTransactionsScreen(key: UniqueKey(), session: session),
    ));
    await tester.pumpAndSettle();
    expect(find.text('FAILED'), findsOneWidget);
    expect(find.textContaining('totals_mismatch'), findsOneWidget, reason: 'the cashier sees WHY');
  });
}
