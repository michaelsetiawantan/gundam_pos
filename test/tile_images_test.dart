import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gundam_pos/models/config_models.dart';
import 'package:gundam_pos/services/media_sync.dart';
import 'package:gundam_pos/state/app_session.dart';
import 'package:gundam_pos/state/order_controller.dart';
import 'package:gundam_pos/state/session_store.dart';
import 'package:gundam_pos/ui/order_entry_screen.dart';
import 'package:gundam_pos/ui/theme.dart';

import 'support/fake_backend.dart';

/// WEB POS now lets an outlet UPLOAD a tile image per menu node ("category") and
/// per product. When that image is on the tablet the order screen shows IT; when
/// it is missing (never uploaded, or not synced yet) the built-in icon stays.
/// A tile is never blank.
void main() {
  /// [withNode] adds a menu layout node ("category") holding the espresso item —
  /// that is what makes the order screen show NODE tiles. Without it the
  /// category fallback lists the PRODUCTS directly.
  TenantConfig configWith({String? itemImage, String? nodeImage, bool withNode = false}) {
    final m = Map<String, dynamic>.from(FakeBackend.northstarMaster());
    m['items'] = (m['items'] as List).map((raw) {
      final i = Map<String, dynamic>.from(raw as Map);
      if (i['id'] == 'item-espresso' && itemImage != null) i['imageKey'] = itemImage;
      return i;
    }).toList();
    if (withNode) {
      m['menuLayouts'] = [
        {
          'id': 'layout-1',
          'name': 'Main',
          'active': true,
          'nodes': [
            {
              'id': 'node-bev', 'parentId': null, 'name': 'Beverages', 'sortOrder': 0,
              'imageKey': nodeImage, 'assignments': [{'itemId': 'item-espresso'}],
            },
          ],
        },
      ];
    }
    return TenantConfig.fromSyncPayloads(m, FakeBackend.northstarOutlet());
  }

  Future<(AppSession, OrderController)> ready(TenantConfig config) async {
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
    final c = OrderController(posApi: session.posApi, tenantId: 't1', config: config, deviceAssetId: 'device-1');
    await c.startOrder(tableId: 'tbl-a1', tableName: 'A1');
    return (session, c);
  }

  Future<void> pump(
    WidgetTester tester,
    AppSession session,
    OrderController c, {
    Future<Uint8List?> Function(String)? mediaBytes,
  }) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: PosTheme.theme(),
      home: OrderEntryScreen(session: session, controller: c, mediaBytes: mediaBytes),
    ));
    await tester.pumpAndSettle();
  }

  /// The tile reads its bytes from DISK (the media cache), so a plain
  /// pumpAndSettle is not enough — let the real async I/O finish, then rebuild.
  Future<void> settleImages(WidgetTester tester) async {
    await tester.pumpAndSettle();
  }

  /// Products sit one level below the node ("category") tile: open it first.
  Future<void> drillToItems(WidgetTester tester) async {
    await tester.tap(find.text('Beverages'));
    await tester.pumpAndSettle();
  }

  test('imageKey is parsed from the menu payload; blank means "no image"', () {
    final withImg = configWith(itemImage: 'item-photo', nodeImage: 'node-photo', withNode: true);
    expect(withImg.itemById('item-espresso')!.imageKey, 'item-photo');
    expect(withImg.itemById('item-nasi')!.imageKey, isNull);
    // The node's image survives the tree assembly AND the item prune.
    final node = withImg.orderTree().first;
    expect(node.imageKey, 'node-photo');
    expect(node.itemIds, contains('item-espresso'));

    // A blank/whitespace key is NOT an image (it must fall back to the icon).
    final blank = configWith(itemImage: '   ', nodeImage: '', withNode: true);
    expect(blank.itemById('item-espresso')!.imageKey, isNull);
    expect(blank.orderTree().first.imageKey, isNull);
  });

  testWidgets('a product tile with NO uploaded image still draws the built-in icon', (tester) async {
    final (session, c) = await ready(configWith(withNode: true));
    await pump(tester, session, c);
    await drillToItems(tester);
    await settleImages(tester);

    expect(find.byType(Image), findsNothing, reason: 'nothing uploaded → icon, never blank');
    // The built-in icon for a product tile (food/bev, by its VAT/SC mode).
    expect(
      find.byIcon(Icons.fastfood_outlined).evaluate().isNotEmpty ||
          find.byIcon(Icons.local_dining).evaluate().isNotEmpty,
      isTrue,
      reason: 'the product tile must still draw its built-in icon',
    );
  });

  testWidgets('an uploaded, cached product image is drawn on the tile', (tester) async {
    final (session, c) = await ready(configWith(itemImage: 'item-photo', withNode: true));
    await pump(tester, session, c, mediaBytes: imageBytes({'item-photo': _png}));
    await drillToItems(tester);
    await settleImages(tester);

    expect(find.byType(Image), findsWidgets, reason: 'the uploaded product image must show');
  });

  testWidgets('an image whose bytes are NOT on the device falls back to the icon', (tester) async {
    final (session, c) = await ready(configWith(itemImage: 'not-synced-yet', withNode: true));
    await pump(tester, session, c, mediaBytes: imageBytes(const {}));
    await drillToItems(tester);
    await settleImages(tester);

    expect(find.byType(Image), findsNothing, reason: 'no bytes → the icon, never a blank tile');
    // The built-in icon for a product tile (food/bev, by its VAT/SC mode).
    expect(
      find.byIcon(Icons.fastfood_outlined).evaluate().isNotEmpty ||
          find.byIcon(Icons.local_dining).evaluate().isNotEmpty,
      isTrue,
      reason: 'the product tile must still draw its built-in icon',
    );
  });

  testWidgets('an uploaded, cached CATEGORY image is drawn on the node tile', (tester) async {
    final (session, c) = await ready(configWith(nodeImage: 'node-photo', withNode: true));
    await pump(tester, session, c, mediaBytes: imageBytes({'node-photo': _png}));
    await settleImages(tester);

    expect(find.byType(Image), findsWidgets, reason: 'the uploaded category image must show');
  });

  testWidgets('a category tile with no image keeps the folder icon', (tester) async {
    final (session, c) = await ready(configWith(withNode: true));
    await pump(tester, session, c);
    await settleImages(tester);

    expect(find.byType(Image), findsNothing);
    expect(find.byIcon(Icons.folder_outlined), findsWidgets);
  });
}

/// The tile's byte lookup, injected: keys present here are "already downloaded
/// on this tablet". No filesystem involved, so the test is deterministic.
Future<Uint8List?> Function(String) imageBytes(Map<String, Uint8List> available) =>
    (key) async => available[key];

/// A 2x2 PNG (real, decodable bytes) used as a stand-in uploaded tile image.
final Uint8List _png = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x02,
  0x08, 0x02, 0x00, 0x00, 0x00, 0xFD, 0xD4, 0x9A, 0x73, 0x00, 0x00, 0x00,
  0x16, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x62, 0xF8, 0xCF, 0xC0, 0xF0,
  0x1F, 0x84, 0xFF, 0x33, 0x30, 0x00, 0x00, 0x1E, 0x0A, 0x03, 0xFD, 0x2C,
  0x9A, 0x4B, 0x1F, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
]);
