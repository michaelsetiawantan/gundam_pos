import 'package:flutter_test/flutter_test.dart';
import 'package:gundam_pos/data/print_format_store.dart';
import 'package:gundam_pos/logic/cart.dart';
import 'package:gundam_pos/logic/money.dart' as money;
import 'package:gundam_pos/logic/print_format_render.dart';
import 'package:gundam_pos/models/config_models.dart';
import 'package:gundam_pos/ui/bill_preview_screen.dart';

TenantConfig _config() => TenantConfig(
      items: [
        MenuItem(
          id: 'i1',
          name: 'Flat White',
          itemcode: 'FW',
          sku: 'S-FW',
          categoryId: 'c1',
          active: true,
          vatMode: money.VatScMode.none,
          scMode: money.VatScMode.none,
        ),
      ],
      categories: const [],
      menuLayouts: const [],
      paymentMethods: const [],
      shift: ShiftConfig.defaultValue(),
      tables: const [],
    );

Map<String, dynamic> _payload({String storeName = 'NORTHSTAR', String itemName = 'Flat White'}) {
  final cart = Cart()
    ..addLine(
      CartLine(
        itemId: 'i1',
        name: itemName,
        sku: 'S-FW',
        qty: 2,
        priceLevelIndex: 0,
        unitPrice: 38000,
        sent: true,
      ),
      merge: false,
    );
  return buildBillPreviewPayload(
    cart: cart,
    config: _config(),
    storeName: storeName,
    tableName: 'A1',
    cashier: 'Rina',
    openedBy: 'Rina',
    now: DateTime(2026, 10, 3, 12, 34),
  );
}

void main() {
  group('bill preview render', () {
    test('(a) built-in preview shows the item name and the total', () {
      final r = renderBillPreview(store: null, payload: _payload(), widthMm: 80);
      expect(r.text, contains('Flat White'));
      expect(r.text, contains('76.000,00')); // 2 × 38000
      expect(r.text, contains('Total'));
      // unpaid → no paid/change lines
      expect(r.text, isNot(contains('Paid')));
      expect(r.text, isNot(contains('Change')));
    });

    test('(b) honours a server BILL format injected through the store', () {
      final store = PrintFormatStore();
      store.apply([
        {
          'formatId': 'bill-custom',
          'name': 'Custom BILL',
          'ticketType': 'BILL',
          'version': 1,
          'widthMm': 80,
          'blocks': [
            {'id': 'h', 'type': 'TEXT', 'text': '== MY BILL =='},
            {'id': 'i', 'type': 'ITEM_LIST', 'columns': 'NAME_QTY_PRICE'},
          ],
        },
      ]);
      final r = renderBillPreview(store: store, payload: _payload(), widthMm: 80);
      expect(r.usedServerFormat, isTrue);
      expect(r.text, contains('== MY BILL =='));
      expect(r.text, contains('Flat White'));
    });

    test('(c) no server format → built-in layout + honest note', () {
      final r = renderBillPreview(store: PrintFormatStore(), payload: _payload(), widthMm: 80);
      expect(r.usedServerFormat, isFalse);
      expect(r.notice, contains('No BILL format from server yet'));
      expect(r.text, contains('NORTHSTAR')); // built-in header

      final r2 = renderBillPreview(store: null, payload: _payload(), widthMm: 80);
      expect(r2.usedServerFormat, isFalse);
      expect(r2.notice, contains('No BILL format from server yet'));
    });

    test('(d) 58mm renders in 32 cells, no line wider than the paper', () {
      expect(cellsForWidthMm(58), 32);
      final r = renderBillPreview(
        store: null,
        payload: _payload(storeName: 'NORTHSTAR CAFE AND BAKERY', itemName: 'Flat White Extra Large Cup'),
        widthMm: 58,
      );
      final lines = r.text.split('\n');
      expect(lines, isNotEmpty);
      expect(lines.every((l) => l.length <= 32), isTrue);
      expect(r.text, contains('76.000,00'));
    });
  });
}
