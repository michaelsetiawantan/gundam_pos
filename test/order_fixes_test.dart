import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gundam_pos/api/api_client.dart';
import 'package:gundam_pos/api/pos_api.dart';
import 'package:gundam_pos/logic/cart.dart';
import 'package:gundam_pos/logic/discount_voucher.dart' as dv;
import 'package:gundam_pos/logic/order_number.dart';
import 'package:gundam_pos/models/config_models.dart';
import 'package:gundam_pos/services/print_dispatcher.dart';
import 'package:gundam_pos/state/app_session.dart';
import 'package:gundam_pos/state/order_controller.dart';
import 'package:gundam_pos/state/payment_controller.dart';
import 'package:gundam_pos/state/session_store.dart';
import 'package:gundam_pos/ui/order_entry_screen.dart';
import 'package:gundam_pos/ui/theme.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/fake_backend.dart';
import 'support/print_support.dart';

/// Field fixes: a deleted line must really leave the bill (server-side), an
/// order with nothing sent must be cancellable, and untagged whole-bill
/// discounts/vouchers must be offered to the cashier.

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

Future<(FakeBackend, OrderController)> _order() async {
  final backend = FakeBackend();
  final session = await _readySession(backend);
  final c = OrderController(posApi: session.posApi, tenantId: 't1', config: _northstar(), deviceAssetId: 'device-1');
  await c.startOrder(tableId: 'tbl-a1', tableName: 'A1');
  return (backend, c);
}

/// A server that serialises its Decimals as STRINGS — Prisma/Postgres does
/// exactly this (Decimal → "45000"). The hard `as num?` cast in [addItem]
/// threw a TypeError on this payload, so the line never reached the cart and
/// the panel stayed empty until a manual Refresh (the reported field bug).
Future<(AppSession, TenantConfig, OrderController)> _stringDecimalOrder() async {
  final store = InMemorySessionStore();
  await store.save(const PosContext()
      .withRedeem({'deviceToken': 'dev', 'groupId': 'g1', 'tenantId': 't1', 'shortcode': 'NSTAR-POS1'})
      .withSession({
        'sessionId': 'sess-1',
        'user': {'id': 'u1', 'fullName': 'C1'},
        'outlet': {'id': 't1', 'name': 'Northstar'},
      })
      .copyWith(deviceId: 'device-1'));
  http.Response json(int status, Object body) =>
      http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});
  final client = ApiClient(
    baseUrl: 'http://fake.test',
    httpClient: MockClient((req) async {
      final path = req.url.path;
      if (req.method == 'POST' && path == '/api/pos/orders') {
        return json(201, {
          'order': {
            'id': 'order-1',
            'status': 'OPEN',
            'tableName': 'A1',
            'openedByName': 'C1',
            'openedAt': DateTime.now().toIso8601String(),
            'lines': <Map<String, dynamic>>[],
          },
        });
      }
      if (req.method == 'POST' && RegExp(r'^/api/pos/orders/[^/]+/lines/?$').hasMatch(path)) {
        return json(201, {
          'line': {
            'id': 'line-1',
            'itemId': 'item-espresso',
            'itemName': 'Espresso',
            // The exact field payload: unitPrice/qty/priceLevelIndex as STRINGS.
            'qty': '2',
            'priceLevelIndex': '0',
            'unitPrice': '45000',
            'vatMode': 'EXCLUDE',
            'scMode': 'NONE',
            'sentToKitchen': false,
          },
        });
      }
      return json(404, {'error': 'not_found'});
    }),
  );
  final session = AppSession(posApi: PosApi(client), sessionStore: store);
  await session.init();
  final config = _northstar();
  final c = OrderController(posApi: session.posApi, tenantId: 't1', config: config, deviceAssetId: 'device-1');
  await c.startOrder(tableId: 'tbl-a1', tableName: 'A1');
  return (session, config, c);
}

void main() {
  group('cart lines mirror the server (delete must reach it)', () {
    test('addItem carries the server line id; repeated adds stay separate rows', () async {
      final (_, c) = await _order();
      final espresso = c.config.itemById('item-espresso')!;
      final l1 = await c.addItem(espresso);
      final l2 = await c.addItem(espresso);
      expect(l1!.lineId, isNotNull);
      expect(l2!.lineId, isNotNull);
      // Server keeps one OrderLine per add → the local cart must NOT merge.
      expect(c.cart.lines, hasLength(2));
      expect(c.cart.itemCount, 2);
    });

    test('removeFromCart DELETEs the server line, then drops the local row', () async {
      final (backend, c) = await _order();
      final line = (await c.addItem(c.config.itemById('item-espresso')!))!;

      expect(await c.removeFromCart(line), isTrue);
      expect(backend.removedLineIds, contains(line.lineId));
      expect(c.cart.lines, isEmpty);
      expect(c.error, isNull);
    });

    test('reloadFromServer rebuilds the cart from the server truth', () async {
      final backend = FakeBackend();
      final session = await _readySession(backend);
      final c = OrderController(posApi: session.posApi, tenantId: 't1', config: _northstar(), deviceAssetId: 'device-1');
      await c.startOrder(tableId: 'tbl-a1', tableName: 'A1');
      // A SERVER-confirmed line (has an id) the server no longer has — it must
      // be dropped by the reconcile. (A line WITHOUT an id is unsynced local
      // work and is deliberately preserved; see the next test.)
      c.cart.addLine(CartLine(
        lineId: 'line-stale',
        itemId: 'item-espresso', name: 'Espresso', sku: 'S', qty: 1, priceLevelIndex: 0, unitPrice: 25000,
      ));
      backend.openOrders = [
        {
          'id': 'order-1',
          'tableName': 'A1',
          'openedAt': DateTime.now().toIso8601String(),
          'lines': [
            {'id': 'line-real', 'itemId': 'item-nasi', 'itemName': 'Nasi Goreng Special', 'qty': 1, 'priceLevelIndex': 0, 'unitPrice': 45000, 'sentToKitchen': true},
          ],
        },
      ];

      expect(await c.reloadFromServer(), isTrue);
      expect(c.cart.lines, hasLength(1));
      expect(c.cart.lines.single.lineId, 'line-real');
      expect(c.hasUnsentLines, isFalse);
      expect(c.canPay, isTrue, reason: 'after reconcile the gate matches the server');
    });

    test('reloadFromServer PRESERVES items that were never synced (offline work)', () async {
      final backend = FakeBackend();
      final session = await _readySession(backend);
      final c = OrderController(posApi: session.posApi, tenantId: 't1', config: _northstar(), deviceAssetId: 'device-1');
      await c.startOrder(tableId: 'tbl-a1', tableName: 'A1');
      // Local-only work: no server id, still queued (offline add).
      c.cart.addLine(CartLine(
        itemId: 'item-espresso', name: 'Espresso', sku: 'S', qty: 2, priceLevelIndex: 0, unitPrice: 25000,
        pending: true, localKey: 'k1',
      ));
      backend.openOrders = [
        {
          'id': 'order-1',
          'tableName': 'A1',
          'openedAt': DateTime.now().toIso8601String(),
          'lines': [
            {'id': 'line-real', 'itemId': 'item-nasi', 'itemName': 'Nasi Goreng Special', 'qty': 1, 'priceLevelIndex': 0, 'unitPrice': 45000, 'sentToKitchen': true},
          ],
        },
      ];

      expect(await c.reloadFromServer(), isTrue);
      expect(c.cart.lines, hasLength(2), reason: 'server truth + the operator\'s unsynced work');
      expect(c.cart.lines.map((l) => l.lineId), contains('line-real'));
      expect(c.hasUnsyncedLines, isTrue);
    });
  });

  group('cancel an order that was never sent (nothing to void)', () {
    test('nothing sent → the server closes it immediately', () async {
      final (backend, c) = await _order();
      await c.addItem(c.config.itemById('item-espresso')!); // never send-cart

      expect(await c.cancelOrder('wrong table'), 'canceled');
      expect(backend.lastCancelBody!['reason'], 'wrong table');
      expect(c.error, isNull);
    });

    test('already sent → a PENDING approval is queued, nothing reversed', () async {
      final (backend, c) = await _order();
      await c.addItem(c.config.itemById('item-espresso')!);
      await c.sendCart();
      backend.cancelPending = true;

      expect(await c.cancelOrder('guest left'), 'pending');
    });

    test('canCancel is true once the order is linked to the server', () async {
      final (_, c) = await _order();
      expect(c.canCancel, isTrue);
    });
  });

  group('modifier display (modifiers belong WITH their item)', () {
    test('an adopted line keeps the modifier NAME with price 0 (no double count)', () async {
      final backend = FakeBackend();
      final session = await _readySession(backend);
      final c = OrderController(
        posApi: session.posApi, tenantId: 't1', config: _northstar(), deviceAssetId: 'device-1',
        pushStore: session.pushStore,
      );
      await c.startOrder(tableId: 'tbl-a1', tableName: 'A1');
      await c.addItem(
        c.config.itemById('item-nasi')!,
        mods: [CartModifier(modifierId: 'mod-egg', name: 'Add egg', price: 5000)],
      );
      await pumpEventQueue(); // let the optimistic add adopt the server line

      final line = c.cart.lines.single;
      expect(line.lineId, isNotNull, reason: 'adopted');
      expect(line.modifiers.map((m) => m.name), contains('Add egg'),
          reason: 'the picked modifier must stay on the line for display');
      expect(line.modifiers.single.price, 0,
          reason: 'server unitPrice is modifier-inclusive — a kept price would double-count');
      expect(line.lineSubtotal, 50000, reason: '45000 base + 5000 modifier, exactly once');
    });

    testWidgets('the right cart panel renders the modifiers under the item', (tester) async {
      final backend = FakeBackend();
      final session = await _readySession(backend);
      final config = _northstar();
      // No pushStore here: the add goes straight to the server, so the test
      // exercises the ADOPTED line (the shape the panel actually shows after a
      // sync) without leaving a background flush running under pumpAndSettle.
      final c = OrderController(
        posApi: session.posApi, tenantId: 't1', config: config, deviceAssetId: 'device-1',
      );
      await c.startOrder(tableId: 'tbl-a1', tableName: 'A1');
      await c.addItem(config.itemById('item-nasi')!, mods: [
        CartModifier(modifierId: 'mod-egg', name: 'Add egg', price: 5000),
        CartModifier(modifierId: 'mod-crackers', name: 'Crackers', price: 2000),
      ]);

      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(theme: PosTheme.theme(), home: OrderEntryScreen(session: session, controller: c)));
      await tester.pumpAndSettle();

      expect(find.textContaining('Add egg'), findsWidgets);
      expect(find.textContaining('Crackers'), findsWidgets);
    });
  });

  group('a discount applied on the SERVER is adopted locally', () {
    Map<String, dynamic> masterWithDiscount() {
      final m = Map<String, dynamic>.from(FakeBackend.northstarMaster());
      m['discounts'] = [
        {'id': 'd-fixed', 'name': 'Happy Hour', 'kind': 'FIXED', 'value': '300', 'target': 'WHOLE_BILL', 'active': true, 'categoryTags': <Map<String, dynamic>>[]},
      ];
      return m;
    }

    test('reloadFromServer picks up discountId from the order row', () async {
      final backend = FakeBackend();
      final session = await _readySession(backend);
      final config = TenantConfig.fromSyncPayloads(masterWithDiscount(), FakeBackend.northstarOutlet());
      final c = OrderController(posApi: session.posApi, tenantId: 't1', config: config, deviceAssetId: 'device-1');
      await c.startOrder(tableId: 'tbl-a1', tableName: 'A1');
      // The server already holds the applied discount (e.g. an approval that was
      // authorised on this POS by an approver's credentials).
      backend.openOrders = [
        {
          'id': 'order-1',
          'tableName': 'A1',
          'openedAt': DateTime.now().toIso8601String(),
          'discountId': 'd-fixed',
          'lines': [
            {'id': 'line-1', 'itemId': 'item-espresso', 'itemName': 'Espresso', 'qty': 1, 'priceLevelIndex': 0, 'unitPrice': 25000, 'vatMode': 'EXCLUDE', 'scMode': 'NONE', 'sentToKitchen': true, 'mods': <Map<String, dynamic>>[]},
          ],
        },
      ];

      expect(await c.reloadFromServer(), isTrue);
      expect(c.pricing!.applied?.id, 'd-fixed',
          reason: 'the order row carries discountId — without adopting it the bill shows no discount');

      // …and the payment preview mirrors it (25000 − 300 + 11% VAT = 27450).
      final pc = PaymentController(
        posApi: session.posApi, tenantId: 't1', config: config, orderId: 'order-1', tableName: 'A1',
        cart: c.cart, deviceAssetId: 'device-1', shortcode: 'NSTAR-POS1', pricingController: c.pricing,
      );
      expect(pc.discountAmount, 300);
      expect(pc.payable, 27450);
    });
  });

  group('untagged whole-bill discount/voucher is offered', () {
    Map<String, dynamic> untagged() {
      final m = Map<String, dynamic>.from(FakeBackend.northstarMaster());
      m['discounts'] = [
        {'id': 'd10', 'name': 'Discount 10%', 'kind': 'PERCENTAGE', 'value': '10', 'target': 'WHOLE_BILL', 'active': true, 'categoryTags': <Map<String, dynamic>>[]},
      ];
      m['vouchers'] = [
        {'id': 'v1', 'name': 'WNKANNIV', 'kind': 'PERCENTAGE', 'value': '10', 'qtyUse': 100, 'usedCount': 0, 'active': true, 'categoryTags': <Map<String, dynamic>>[]},
      ];
      return m;
    }

    test('a master with no category tag applies to the whole bill', () {
      final config = TenantConfig.fromSyncPayloads(untagged(), FakeBackend.northstarOutlet());
      final disc = dv.eligibleDiscounts(discounts: config.discounts, lineCategoryIds: ['cat-bev'], parentById: config.categoryParentId);
      final vouch = dv.eligibleVouchers(vouchers: config.vouchers, lineCategoryIds: ['cat-food'], parentById: config.categoryParentId);
      expect(disc.map((d) => d.id), contains('d10'));
      expect(vouch.map((v) => v.id), contains('v1'));
    });

    test('a master tagged to another category is still NOT offered', () {
      final m = untagged();
      (m['discounts'] as List).first['categoryTags'] = [
        {'categoryId': 'cat-nope', 'includesChildren': true},
      ];
      final config = TenantConfig.fromSyncPayloads(m, FakeBackend.northstarOutlet());
      final disc = dv.eligibleDiscounts(discounts: config.discounts, lineCategoryIds: ['cat-bev'], parentById: config.categoryParentId);
      expect(disc, isEmpty);
    });
  });

  group('server Decimals as JSON strings must not drop the line', () {
    test('addItem tolerates string qty/priceLevelIndex/unitPrice (regression)', () async {
      final (_, config, c) = await _stringDecimalOrder();

      // Before the fix this threw `type String is not a subtype of num?` and
      // returned null → nothing in the cart until a manual Refresh.
      final line = await c.addItem(config.itemById('item-espresso')!, qty: 2);

      expect(line, isNotNull, reason: 'a Decimal-string payload must not throw');
      expect(c.error, isNull);
      expect(c.cart.lines, hasLength(1));
      expect(line!.qty, 2);
      expect(line.unitPrice, 45000);
      expect(c.cart.total, 90000);
    });
  });

  group('offline optimistic add + outbox', () {
    Future<(FakeBackend, AppSession, OrderController)> offlineOrder() async {
      final backend = FakeBackend();
      final session = await _readySession(backend);
      final c = OrderController(
        posApi: session.posApi,
        tenantId: 't1',
        config: _northstar(),
        deviceAssetId: 'device-1',
        pushStore: session.pushStore,
      );
      await c.startOrder(tableId: 'tbl-a1', tableName: 'A1');
      return (backend, session, c);
    }

    test('offline add shows the line instantly, pending + queued', () async {
      final (backend, _, c) = await offlineOrder();
      backend.addLineOffline = true;

      final line = await c.addItem(c.config.itemById('item-espresso')!, qty: 2);

      expect(line, isNotNull);
      expect(c.cart.lines, hasLength(1), reason: 'line must appear without a server answer');
      expect(line!.pending, isTrue);
      expect(line.lineId, isNull);
      expect(line.localKey, isNotNull);
      expect(line.unitPrice, 25000, reason: 'local price-level preview');
      expect(c.cart.total, 50000);
      expect(c.hasUnsyncedLines, isTrue);
      // Offline-first: the send itself needs NO server — lines are marked sent
      // locally, captain/bev print now, and an `order_send` is queued for later.
      expect(await c.sendCart(), isTrue, reason: 'a dead network must not block the kitchen send');
      expect(c.hasUnsentLines, isFalse, reason: 'lines sent LOCALLY');
      expect(c.canPay, isTrue, reason: 'payment gate reads LOCAL sent state');
      expect(c.error, isNull);
    });

    test('when online again the queued line is adopted (id + server price)', () async {
      final (backend, _, c) = await offlineOrder();
      backend.addLineOffline = true;
      final line = await c.addItem(c.config.itemById('item-espresso')!, levelIndex: 1, qty: 2);
      expect(line!.pending, isTrue);

      backend.addLineOffline = false;
      expect(await c.retryUnsyncedLines(), isTrue);

      expect(line.lineId, isNotNull, reason: 'adopted the server line id');
      expect(line.pending, isFalse);
      expect(line.failed, isFalse);
      expect(line.unitPrice, 32000, reason: 'server (modifier-inclusive) price replaces preview');
      expect(c.hasUnsyncedLines, isFalse);
      expect(backend.addedLineBodies, hasLength(1), reason: 'flushed exactly once');
    });

    test('flush is idempotent — a re-flush never double-POSTs', () async {
      final (backend, _, c) = await offlineOrder();
      await c.addItem(c.config.itemById('item-nasi')!);
      await c.flushPendingLines();
      await c.flushPendingLines();
      expect(backend.addedLineBodies, hasLength(1));
    });

    test('server rejection marks the line failed and clears the queue', () async {
      final (backend, session, c) = await offlineOrder();
      backend.addLineError = 'item_inactive';

      final line = await c.addItem(c.config.itemById('item-espresso')!);

      expect(line!.failed, isTrue);
      expect(line.pending, isFalse);
      expect(line.lineId, isNull);
      expect(c.error, isNotNull);
      expect(await session.pushStore.pending(), isEmpty, reason: 'poison entry removed');
      // Operator can remove a failed line locally (no server delete).
      expect(await c.removeFromCart(line), isTrue);
      expect(c.cart.lines, isEmpty);
    });

    test('removing a pending line drops its outbox entry', () async {
      final (backend, session, c) = await offlineOrder();
      backend.addLineOffline = true;
      final line = await c.addItem(c.config.itemById('item-espresso')!);
      expect(await session.pushStore.pending(), isNotEmpty);

      expect(await c.removeFromCart(line!), isTrue);
      expect(c.cart.lines, isEmpty);
      expect(await session.pushStore.pending(), isEmpty);
    });

    test('AppSession.flushOrderQueue drains queued line adds', () async {
      final backend = FakeBackend();
      final session = await _readySession(backend);
      await session.enqueuePush('order_line', 'k1', {
        'orderId': 'order-1',
        'itemId': 'item-espresso',
        'priceLevelIndex': 0,
        'qty': 1,
        'mods': <Map<String, dynamic>>[],
      });

      expect(await session.flushOrderQueue(), 1);
      expect(session.orderQueuePending, 0);
      expect(await session.pushStore.pending(), isEmpty);
      expect(backend.addedLineBodies, hasLength(1));
    });

    test('AppSession.flushOrderQueue leaves the queue on network failure', () async {
      final backend = FakeBackend();
      final session = await _readySession(backend);
      backend.addLineOffline = true;
      await session.enqueuePush('order_line', 'k1', {
        'orderId': 'order-1', 'itemId': 'item-espresso', 'priceLevelIndex': 0, 'qty': 1, 'mods': <Map<String, dynamic>>[],
      });

      expect(await session.flushOrderQueue(), 0);
      expect(await session.pushStore.pending(), hasLength(1));
    });
  });

  group('offline order creation — client-minted id (Fase 3)', () {
    Future<(FakeBackend, AppSession, TenantConfig, OrderController)> offlineStart() async {
      final backend = FakeBackend();
      final session = await _readySession(backend);
      final config = _northstar();
      final c = OrderController(
        posApi: session.posApi,
        tenantId: 't1',
        config: config,
        deviceAssetId: 'device-1',
        pushStore: session.pushStore,
        orderNumbers: session.orderNumbers,
        shortcode: session.shortcode,
      );
      return (backend, session, config, c);
    }

    test('startOrder offline opens a LOCAL order and queues order_create', () async {
      final (backend, session, config, c) = await offlineStart();
      backend.createOrderOffline = true;

      expect(await c.startOrder(tableId: 'tbl-a1'), isTrue,
          reason: 'an unreachable server must not fail the start');
      expect(c.started, isTrue);
      expect(c.pendingCreate, isTrue);
      expect(c.orderId, isNotNull);
      expect(isValidClientOrderId(c.orderId!), isTrue, reason: 'id must pass the server shape check');
      expect(c.orderId, startsWith('NSTAR-POS1-'));
      expect(c.tableName, 'A1', reason: 'resolved from config when only tableId is given');

      final pending = await session.pushStore.pending();
      final creates = pending.where((i) => i['type'] == 'order_create').toList();
      expect(creates, hasLength(1));
      expect((creates.single['payload_json'] as Map)['orderId'], c.orderId);

      // Operator can add an item immediately — it queues as an order_line.
      final line = await c.addItem(config.itemById('item-espresso')!, qty: 2);
      expect(line, isNotNull);
      expect(line!.pending, isTrue);
      expect(c.cart.lines, hasLength(1));
      expect(c.hasUnsyncedLines, isTrue);
      final queued = await session.pushStore.pending();
      expect(queued.any((i) => i['type'] == 'order_line'), isTrue);
      expect(backend.orderEvents, isEmpty, reason: 'offline — nothing reached the server');
    });

    test('AppSession.flushOrderQueue creates the order FIRST, then its lines', () async {
      final backend = FakeBackend();
      final session = await _readySession(backend);
      const cid = 'NSTAR-POS1-20261003-1430-000101';
      await session.enqueuePush('order_create', cid, {
        'orderId': cid, 'tenantId': 't1', 'tableId': 'tbl-a1', 'tableName': 'A1',
      });
      await session.enqueuePush('order_line', 'k1', {
        'orderId': cid, 'itemId': 'item-espresso', 'priceLevelIndex': 0, 'qty': 1, 'mods': <Map<String, dynamic>>[],
      });

      expect(await session.flushOrderQueue(), 2);
      expect(backend.orderEvents, ['create:$cid', 'line:$cid']);
      expect(await session.pushStore.pending(), isEmpty);
      expect(session.orderQueuePending, 0);
    });

    test('a line whose order is not created yet is SKIPPED, not sent', () async {
      final backend = FakeBackend();
      final session = await _readySession(backend);
      backend.createOrderOffline = true;
      const cid = 'NSTAR-POS1-20261003-1431-000102';
      await session.enqueuePush('order_create', cid, {'orderId': cid, 'tenantId': 't1', 'tableName': 'B2'});
      await session.enqueuePush('order_line', 'k1', {
        'orderId': cid, 'itemId': 'item-espresso', 'priceLevelIndex': 0, 'qty': 1, 'mods': <Map<String, dynamic>>[],
      });

      expect(await session.flushOrderQueue(), 0);
      expect(backend.orderEvents, isEmpty, reason: 'no addLine against an uncreated order');
      expect(await session.pushStore.pending(), hasLength(2), reason: 'both stay queued');
    });

    test('controller flush creates the order then adopts its queued lines', () async {
      final (backend, _, config, c) = await offlineStart();
      backend.createOrderOffline = true;
      await c.startOrder(tableId: 'tbl-a1');
      final line = await c.addItem(config.itemById('item-espresso')!);
      expect(c.pendingCreate, isTrue);
      expect(line!.lineId, isNull);

      final cid = c.orderId!;
      backend.createOrderOffline = false;
      expect(await c.retryUnsyncedLines(), isTrue);

      expect(c.pendingCreate, isFalse);
      expect(c.orderId, cid, reason: 'the client id is kept — the server accepted it');
      expect(line.lineId, isNotNull, reason: 'line adopted after the create landed');
      expect(backend.orderEvents, ['create:$cid', 'line:$cid']);
      expect(c.hasUnsyncedLines, isFalse);
    });
  });

  group('sendCart does not wait for the printer (fire-and-forget)', () {
    Future<OrderController> ready(PrintDispatcher d, {void Function(List<String>)? onPrintAlerts}) async {
      final backend = FakeBackend();
      final session = await _readySession(backend);
      final c = OrderController(
        posApi: session.posApi,
        tenantId: 't1',
        config: _northstar(),
        deviceAssetId: 'device-1',
        printer: d,
        onPrintAlerts: onPrintAlerts,
      );
      await c.startOrder(tableId: 'tbl-a1', tableName: 'A1');
      await c.addItem(c.config.itemById('item-espresso')!);
      return c;
    }

    test('sendCart returns with lines committed BEFORE the captain print finishes', () async {
      final d = GatedDispatcher();
      final c = await ready(d);

      expect(await c.sendCart(), isTrue);
      expect(c.hasUnsentLines, isFalse, reason: 'send committed without the print');
      expect(d.sendCartCalls, 1, reason: 'print STARTED, not awaited');
      expect(d.gate.isCompleted, isFalse);
      expect(c.printAlerts, isEmpty, reason: 'print not finished → no warnings yet');

      d.gate.complete();
      await pumpEventQueue();
      expect(c.printAlerts, contains('CAPTAIN printer offline — test.'));
    });

    test('late warnings are delivered through onPrintAlerts', () async {
      final d = GatedDispatcher();
      final got = <String>[];
      final c = await ready(d, onPrintAlerts: got.addAll);

      await c.sendCart();
      expect(got, isEmpty);

      d.gate.complete();
      await pumpEventQueue();
      expect(got, ['CAPTAIN printer offline — test.']);
    });

    test('a print failure never fails the send', () async {
      final d = buildDispatcher(AlwaysFailingTransport());
      final c = await ready(d);

      expect(await c.sendCart(), isTrue, reason: 'a dead printer must not block the kitchen send');
      await pumpEventQueue();
      expect(c.error, isNull);
      expect(c.printAlerts, isNotEmpty);
    });
  });
}
