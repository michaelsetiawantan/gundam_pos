import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gundam_pos/api/api_client.dart';
import 'package:gundam_pos/api/pos_api.dart';
import 'package:gundam_pos/models/config_models.dart';
import 'package:gundam_pos/state/app_session.dart';
import 'package:gundam_pos/state/order_controller.dart';
import 'package:gundam_pos/state/session_store.dart';
import 'package:gundam_pos/ui/order_entry_screen.dart';
import 'package:gundam_pos/ui/theme.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/fake_backend.dart';

/// Layout + navigation regressions for order entry:
///   - the persistent right-hand cart panel on tablet landscape (mockup 10);
///   - cross-node product search;
///   - back climbs ONE menu level (hardware back + AppBar leading);
///   - per-item cancel of an already-sent line.

TenantConfig _config() =>
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

Future<(FakeBackend, AppSession, TenantConfig, OrderController)> _order() async {
  final backend = FakeBackend();
  final session = await _readySession(backend);
  final config = _config();
  final c = OrderController(posApi: session.posApi, tenantId: 't1', config: config, deviceAssetId: 'device-1');
  await c.startOrder(tableId: 'tbl-a1', tableName: 'A1');
  return (backend, session, config, c);
}

/// A backend whose `addLine` response is DELAYED — the field case the operator
/// hit: pick a product, the server takes a moment, and once it answers the row
/// must still appear in the right-hand panel with NO manual Refresh. Built on a
/// private MockClient so the delay is real (an awaited Future), not a frame trick.
Future<(AppSession, TenantConfig, OrderController)> _delayedOrder({
  Duration delay = const Duration(milliseconds: 400),
}) async {
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
        await Future<void>.delayed(delay); // server latency
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        final itemId = body['itemId'] as String?;
        final espresso = itemId == 'item-espresso';
        return json(201, {
          'line': {
            'id': 'line-$itemId',
            'itemId': itemId,
            'itemName': espresso ? 'Espresso' : 'Nasi Goreng Special',
            'qty': body['qty'] ?? 1,
            'unitPrice': espresso ? 25000 : 45000,
            'vatMode': espresso ? 'EXCLUDE' : 'INCLUDE',
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
  final config = _config();
  final c = OrderController(posApi: session.posApi, tenantId: 't1', config: config, deviceAssetId: 'device-1');
  await c.startOrder(tableId: 'tbl-a1', tableName: 'A1');
  return (session, config, c);
}

Widget _wrap(AppSession session, OrderController c) =>
    MaterialApp(theme: PosTheme.theme(), home: OrderEntryScreen(session: session, controller: c));

void main() {
  void useLandscape(WidgetTester tester) {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1280, 800);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  void useSize(WidgetTester tester, Size size) {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = size;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  // The two-column layout must survive the smaller logical widths a scaled 10"
  // tablet reports (~853 logical) — the old flat 900px gate dropped the panel.
  for (final size in const [Size(900, 600), Size(1280, 800), Size(853, 533)]) {
    testWidgets('right cart panel shows on a narrow tablet at $size', (tester) async {
      useSize(tester, size);

      final (_, session, config, c) = await _order();
      await tester.pumpWidget(_wrap(session, c));
      await tester.pumpAndSettle();

      // Empty panel state is honest before anything is added.
      expect(find.text('No items yet.'), findsOneWidget);

      // Adding an item MUST surface a row in the right-hand panel at once.
      await c.addItem(config.itemById('item-espresso')!);
      await tester.pumpAndSettle();

      expect(find.textContaining('1× Espresso'), findsOneWidget);
      expect(find.byKey(const Key('cart-unsent-tag')), findsOneWidget);
      expect(find.text('No items yet.'), findsNothing);
      // Menu still beside it (two columns, not the sheet).
      expect(find.text('Beverages'), findsOneWidget);
    });
  }

  testWidgets('cancelling an order returns to the screen beneath (Open Tables)', (tester) async {
    useLandscape(tester);

    final (backend, session, config, c) = await _order();
    backend.cancelPending = false; // nothing sent → server cancels immediately
    // A cart WITH items still needs a reason (only an empty cart skips it).
    await c.addItem(config.itemById('item-espresso')!);

    // Simulate Open Tables as the route below order entry.
    await tester.pumpWidget(MaterialApp(
      theme: PosTheme.theme(),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              key: const Key('open-order'),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => OrderEntryScreen(session: session, controller: c)),
              ),
              child: const Text('OPEN TABLES'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.byKey(const Key('open-order')));
    await tester.pumpAndSettle();
    expect(find.text('Cart · A1'), findsOneWidget);

    await tester.tap(find.byKey(const Key('order-cancel')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('reason-field')), 'Guest left');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();

    // Back on Open Tables — the order screen is gone (was stuck before).
    expect(find.text('OPEN TABLES'), findsOneWidget);
    expect(find.text('Cart · A1'), findsNothing);
  });

  testWidgets('tablet landscape shows the persistent right cart panel', (tester) async {
    useLandscape(tester);

    final (_, session, config, c) = await _order();
    await c.addItem(config.itemById('item-espresso')!);

    await tester.pumpWidget(_wrap(session, c));
    await tester.pumpAndSettle();

    // Header + unsent tag + line + subtotal + actions, all at once beside menu.
    expect(find.text('Cart · A1'), findsOneWidget);
    expect(find.byKey(const Key('cart-unsent-tag')), findsOneWidget);
    expect(find.textContaining('1 UNSENT'), findsOneWidget);
    expect(find.text('Subtotal'), findsOneWidget);
    expect(find.byKey(const Key('panel-send-cart')), findsOneWidget);
    expect(find.byKey(const Key('panel-payment')), findsOneWidget);
    // The menu grid is still there alongside it.
    expect(find.text('Beverages'), findsOneWidget);
  });

  testWidgets('product search spans all nodes and returns matching tiles', (tester) async {
    final (_, session, _, c) = await _order();
    await tester.pumpWidget(_wrap(session, c));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('menu-search')), 'nasi');
    await tester.pumpAndSettle();

    // Match by name across nodes, without drilling into the node first.
    expect(find.text('Nasi Goreng Special'), findsOneWidget);
    expect(find.text('Espresso'), findsNothing);

    // Also matches by SKU/itemcode, case-insensitive.
    await tester.enterText(find.byKey(const Key('menu-search')), 'esp');
    await tester.pumpAndSettle();
    expect(find.text('Espresso'), findsOneWidget);
    expect(find.text('Nasi Goreng Special'), findsNothing);

    // Empty query returns to the drill-down (roots).
    await tester.enterText(find.byKey(const Key('menu-search')), '');
    await tester.pumpAndSettle();
    expect(find.text('Beverages'), findsOneWidget);
  });

  testWidgets('back climbs one menu level, hardware back included', (tester) async {
    final (_, session, _, c) = await _order();
    await tester.pumpWidget(_wrap(session, c));
    await tester.pumpAndSettle();

    // Root: no level-back button, no explicit root button.
    expect(find.byKey(const Key('menu-back')), findsNothing);
    expect(find.byKey(const Key('menu-root')), findsNothing);

    await tester.tap(find.text('Beverages'));
    await tester.pumpAndSettle();
    expect(find.text('Espresso'), findsOneWidget);
    expect(find.byKey(const Key('menu-back')), findsOneWidget);

    // AppBar leading climbs one level (NOT straight to Open Tables).
    await tester.tap(find.byKey(const Key('menu-back')));
    await tester.pumpAndSettle();
    expect(find.text('Beverages'), findsOneWidget);
    expect(find.byKey(const Key('menu-back')), findsNothing);

    // Drill again, then hardware back also climbs a level instead of popping.
    await tester.tap(find.text('Beverages'));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('menu-back')), findsNothing);
    expect(find.text('Beverages'), findsOneWidget);

    // Explicit 'All menus' button jumps straight to root once drilled.
    await tester.tap(find.text('Beverages'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('menu-root')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('menu-back')), findsNothing);
  });

  group('product lands in the right cart panel (no manual refresh)', () {
    // The field bug: after picking a product the row did NOT appear until the
    // operator hit Refresh. The panel is driven by a ListenableBuilder, so these
    // drive the REAL menu→sheet→Add path, never c.addItem directly.
    Future<void> pick(WidgetTester tester, String node, String item) async {
      await tester.tap(find.text(node));
      await tester.pumpAndSettle();
      await tester.tap(find.text(item));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Add ·'));
      await tester.pumpAndSettle();
    }

    testWidgets('picking a product shows it in the right panel at once', (tester) async {
      useLandscape(tester);
      final (_, session, _, c) = await _order();
      await tester.pumpWidget(_wrap(session, c));
      await tester.pumpAndSettle();

      await pick(tester, 'Beverages', 'Espresso');

      expect(find.textContaining('1× Espresso'), findsOneWidget);
      expect(find.text('No items yet.'), findsNothing);
      expect(find.textContaining('1 UNSENT'), findsOneWidget);
    });

    testWidgets('a DELAYED addLine still lands in the panel, without tapping Refresh', (tester) async {
      useLandscape(tester);
      final (session, _, c) = await _delayedOrder(delay: const Duration(milliseconds: 400));
      await tester.pumpWidget(_wrap(session, c));
      await tester.pumpAndSettle();

      await pick(tester, 'Beverages', 'Espresso');

      // pumpAndSettle ran through the 400 ms latency; the row is there and the
      // Refresh action was never touched.
      expect(find.textContaining('1× Espresso'), findsOneWidget);
      expect(find.text('No items yet.'), findsNothing);
    });

    testWidgets('a SECOND product keeps updating the panel (stable listenable)', (tester) async {
      useLandscape(tester);
      final (_, session, _, c) = await _order();
      await tester.pumpWidget(_wrap(session, c));
      await tester.pumpAndSettle();

      await pick(tester, 'Beverages', 'Espresso');
      expect(find.textContaining('1× Espresso'), findsOneWidget);

      // Back to the menu forest, then add a second line from another node.
      await tester.tap(find.byKey(const Key('menu-root')));
      await tester.pumpAndSettle();
      await pick(tester, 'Main Dishes', 'Nasi Goreng Special');

      // Both lines present at once — a merge object recreated every build used
      // to drop the second notification.
      expect(find.textContaining('1× Espresso'), findsOneWidget);
      expect(find.textContaining('1× Nasi Goreng Special'), findsOneWidget);
      expect(find.textContaining('2 UNSENT'), findsOneWidget);
    });

    testWidgets('the panel listenable is STABLE across rebuilds', (tester) async {
      useLandscape(tester);
      final (_, session, _, c) = await _order();
      await tester.pumpWidget(_wrap(session, c));
      await tester.pumpAndSettle();

      final panel = find.ancestor(
        of: find.textContaining('Cart ·'),
        matching: find.byType(ListenableBuilder),
      );
      final first = tester.widget<ListenableBuilder>(panel.first).listenable;

      // Force the screen's build() to run again — this used to mint a brand-new
      // Listenable.merge every frame, detaching/re-attaching the panel listener.
      await tester.enterText(find.byKey(const Key('menu-search')), 'esp');
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('menu-search')), '');
      await tester.pumpAndSettle();

      final second = tester.widget<ListenableBuilder>(panel.first).listenable;
      expect(identical(first, second), isTrue);
    });
  });

  group('per-item cancel (sent line)', () {
    test('cancelLine sends lineId + qty + reason; approval → pending', () async {
      final (backend, _, config, c) = await _order();
      await c.addItem(config.itemById('item-espresso')!, qty: 3);
      await c.sendCart();
      final line = c.cart.lines.single;
      expect(line.sent, isTrue);

      backend.cancelPending = true;
      final r = await c.cancelLine(line, qty: 1, reason: 'Guest changed order');

      expect(r, 'pending');
      expect(backend.lastCancelBody, {
        'reason': 'Guest changed order',
        'lineId': 'line-item-espresso',
        'qty': 1,
      });
      // The local line is NOT removed — the web console owns a sent line.
      expect(c.cart.lines.single, same(line));
    });

    test('cancelLine reports immediate cancel when nothing was sent server-side', () async {
      final (backend, _, config, c) = await _order();
      await c.addItem(config.itemById('item-nasi')!);
      await c.sendCart();
      final line = c.cart.lines.single;

      backend.cancelPending = false;
      expect(await c.cancelLine(line, qty: 1, reason: 'wrong item'), 'canceled');
      expect(backend.lastCancelBody!['lineId'], 'line-item-nasi');
    });

    testWidgets('the cart panel cancel action opens qty+reason and requests cancel', (tester) async {
      useLandscape(tester);

      final (backend, session, config, c) = await _order();
      await c.addItem(config.itemById('item-nasi')!, qty: 3);
      await c.sendCart();
      backend.cancelPending = true;

      await tester.pumpWidget(_wrap(session, c));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('line-cancel-line-item-nasi')));
      await tester.pumpAndSettle();
      expect(find.text('Cancel sent item'), findsOneWidget);
      expect(find.text('/ 3'), findsOneWidget);

      // Confirm stays disabled until a reason is typed.
      final confirm = tester.widget<FilledButton>(find.byKey(const Key('cancel-line-confirm')));
      expect(confirm.onPressed, isNull);

      await tester.enterText(find.byKey(const Key('cancel-line-reason')), 'Guest changed order');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('cancel-line-confirm')));
      await tester.pumpAndSettle();

      expect(backend.lastCancelBody!['lineId'], 'line-item-nasi');
      expect(backend.lastCancelBody!['qty'], 3);
      expect(backend.lastCancelBody!['reason'], 'Guest changed order');
      expect(find.textContaining('awaiting approval'), findsOneWidget);
    });
  });

  group('menu tiles enlarged (bigger, better proportioned)', () {
    for (final size in const [Size(1280, 800), Size(900, 600), Size(853, 533)]) {
      testWidgets('@$size: tile grid is 255px columns at ratio 0.98, no overflow', (tester) async {
        useSize(tester, size);

        final (_, session, _, c) = await _order();
        await tester.pumpWidget(_wrap(session, c));
        await tester.pumpAndSettle();

        // A node tile renders its label → grid laid out (an overflow would have
        // thrown during pumpAndSettle).
        expect(find.text('Beverages'), findsOneWidget);

        final grid = tester.widget<GridView>(find.byType(GridView).first);
        final delegate = grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
        // Taller-than-wide cells: room for an UPLOADED tile image (was 1.15).
        expect(delegate.childAspectRatio, 0.98);
        // 1280 logical − cart column (380+12+4) = 884 → floor(884/255) = 3,
        // where the old 215px rule produced 4. Bigger tiles, fewer columns.
        if (size.width >= 1280) expect(delegate.crossAxisCount, 3);
        expect(delegate.crossAxisCount, lessThanOrEqualTo(3));
      });
    }
  });
}
