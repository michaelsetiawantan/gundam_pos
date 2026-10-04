import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gundam_pos/data/print_format_store.dart';
import 'package:gundam_pos/logic/print_payload.dart';
import 'package:gundam_pos/models/config_models.dart';
import 'package:gundam_pos/state/app_session.dart';
import 'package:gundam_pos/state/order_controller.dart';
import 'package:gundam_pos/state/session_store.dart';
import 'package:gundam_pos/ui/captain_preview_screen.dart';
import 'package:gundam_pos/ui/order_entry_screen.dart';
import 'package:gundam_pos/ui/theme.dart';

import 'support/fake_backend.dart';

/// The order screen used to offer only a BILL preview. It now offers a
/// "Printout preview" that lets the operator choose BILL or CAPTAIN ORDER, and
/// the captain sheet is rendered from the SAME payload the printer sends.
void main() {
  List<Map<String, dynamic>> captainPayloads({String item = 'Espresso'}) => const TicketPayloadBuilder()
      .captainOrderSheets(
    ctx: TicketContext(tableName: 'A1', tableNumber: '1', storeName: 'NORTHSTAR'),
    items: [PrintItem(name: item, qty: 2, unitPrice: 25000, itemId: 'item-espresso', menu: 'Beverages')],
  );

  Map<String, dynamic> serverFormats() => {
        'formats': [
          {
            'formatId': 'f-cap', 'name': 'Agreed Captain', 'ticketType': 'CAPTAIN_ORDER',
            'version': 1, 'widthMm': 80,
            'blocks': [
              {'id': 'a', 'type': 'TEXT', 'text': 'AGREED CAPTAIN', 'align': 'CENTER'},
              {'id': 'b', 'type': 'VAR', 'param': '{table_name}'},
              // The shape the outlet really publishes for a captain sheet.
              {
                'id': 'c', 'type': 'ITEM_LIST', 'wrap': true, 'columns': 'NAME_QTY_PRICE',
                'groupByMenu': true, 'withModifiers': true,
              },
            ],
          },
        ],
        'skipped': <Object>[],
      };

  test('captain preview uses the outlet CAPTAIN_ORDER format when published', () {
    final store = PrintFormatStore()..apply(serverFormats(), version: 4);
    final out = renderCaptainPreview(store: store, payloads: captainPayloads(), widthMm: 80);

    expect(out.usedServerFormat, isTrue);
    expect(out.text, contains('AGREED CAPTAIN'), reason: 'the server layout must be the one shown');
    // …and the real order content is in it: the menu group header and the item
    // (the renderer uppercases the group header).
    expect(out.text.toUpperCase(), contains('BEVERAGES'));
    expect(out.text, contains('Espresso'));
  });

  test('captain preview falls back to the built-in layout with an honest notice', () {
    final out = renderCaptainPreview(store: PrintFormatStore(), payloads: captainPayloads(), widthMm: 80);

    expect(out.usedServerFormat, isFalse);
    expect(out.notice, contains('No CAPTAIN_ORDER format from server yet'));
    // Still a real kitchen sheet: identity + table + item.
    expect(out.text, contains('NORTHSTAR'));
    expect(out.text, contains('Espresso'));
  });

  test('several batches preview as several labelled sheets', () {
    final sheets = const TicketPayloadBuilder().captainOrderSheets(
      ctx: TicketContext(tableName: 'A1'),
      items: [
        PrintItem(name: 'Espresso', qty: 1, unitPrice: 25000, itemId: 'item-espresso', batchIndex: 0),
        PrintItem(name: 'Nasi Goreng', qty: 1, unitPrice: 45000, itemId: 'item-nasi', batchIndex: 1),
      ],
    );
    expect(sheets, hasLength(2));
    final out = renderCaptainPreview(store: PrintFormatStore(), payloads: sheets, widthMm: 80);
    expect(out.text, contains('captain sheet 1 of 2'));
    expect(out.text, contains('captain sheet 2 of 2'));
    expect(out.text, contains('Espresso'));
    expect(out.text, contains('Nasi Goreng'));
  });

  testWidgets('the order screen offers BOTH printouts under one entry', (tester) async {
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
    await c.addItem(config.itemById('item-espresso')!);

    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: PosTheme.theme(),
      home: OrderEntryScreen(session: session, controller: c),
    ));
    await tester.pumpAndSettle();

    // The single entry is named for printouts, not just the bill.
    expect(find.text('Printout preview'), findsOneWidget);
    expect(find.text('Preview bill'), findsNothing);

    await tester.tap(find.byKey(const Key('panel-preview-printout')));
    await tester.pumpAndSettle();
    expect(find.text('Which printout?'), findsOneWidget);
    expect(find.byKey(const Key('preview-choice-bill')), findsOneWidget);
    expect(find.byKey(const Key('preview-choice-captain')), findsOneWidget);

    // Choosing the captain order opens the captain preview (not the bill one).
    await tester.tap(find.byKey(const Key('preview-choice-captain')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('captain-preview-text')), findsOneWidget);
    expect(find.text('Captain order preview'), findsOneWidget);

    // Re-open and take the bill: the bill preview is still there, unchanged.
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('panel-preview-printout')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('preview-choice-bill')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('bill-preview-text')), findsOneWidget);
  });
}
