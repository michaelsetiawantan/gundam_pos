import 'package:flutter_test/flutter_test.dart';
import 'package:gundam_pos/services/print_routing.dart';

// Station routing on the device: a MENU (category) points at the printer that
// prints its captain sheet / bev label; an item override still wins. The
// assignment is per outlet, and an unassigned line stays unrouted (never
// guessed) so the dispatcher's routing fallback keeps working.

Map<String, dynamic> printer(String id, {bool active = true}) => {
      'id': id, 'name': id, 'transport': 'NETWORK', 'ip': '10.0.0.5', 'port': 9100,
      'widthMm': 80, 'active': active,
    };

PrinterRouting routing() => PrinterRouting.parse({
      'printers': [printer('p-kitchen'), printer('p-bar'), printer('p-off', active: false)],
      'routing': {
        'CAPTAIN_ORDER': [
          {'printerId': 'p-kitchen', 'batchStep': 0},
        ],
      },
      'itemRoutes': [
        {'itemId': 'item-special', 'captainPrinterId': 'p-bar'},
      ],
      'categoryRoutes': [
        {'categoryId': 'cat-root', 'parentId': null, 'captainPrinterId': 'p-kitchen'},
        {'categoryId': 'cat-coffee', 'parentId': 'cat-root', 'bevPrinterId': 'p-bar'},
        {'categoryId': 'cat-latte', 'parentId': 'cat-coffee'},
        {'categoryId': 'cat-off', 'parentId': null, 'captainPrinterId': 'p-off'},
      ],
    });

void main() {
  test('parses categoryRoutes (per outlet) without touching itemRoutes', () {
    final r = routing();
    expect(r.categoryRoutes['cat-coffee']!.bevPrinterId, 'p-bar');
    expect(r.categoryRoutes['cat-latte']!.parentId, 'cat-coffee');
    expect(r.itemRoutes['item-special']!.captainPrinterId, 'p-bar');
  });

  test('inherits from the nearest ancestor that has a station', () {
    final r = routing()
      ..itemCategories = {'item-latte': 'cat-latte'};
    final t = r.stationForItem('item-latte');
    expect(t.captainPrinterId, 'p-kitchen'); // from cat-root
    expect(t.bevPrinterId, 'p-bar'); // from cat-coffee
    expect(r.captainPrinterForLine('item-latte')!.id, 'p-kitchen');
    expect(r.bevPrinterForLine('item-latte')!.id, 'p-bar');
  });

  test('an item override wins over its category', () {
    final r = routing()
      ..itemCategories = {'item-special': 'cat-latte'};
    expect(r.stationForItem('item-special').captainPrinterId, 'p-bar');
  });

  test('an inactive station printer resolves to null (never a dead target)', () {
    final r = routing()
      ..itemCategories = {'item-x': 'cat-off'};
    expect(r.stationForItem('item-x').captainPrinterId, 'p-off');
    expect(r.captainPrinterForLine('item-x'), isNull);
  });

  test('no assignment → null (the caller keeps its routing fallback)', () {
    final r = routing()
      ..itemCategories = {'item-y': 'cat-nope'};
    expect(r.stationForItem('item-y').captainPrinterId, isNull);
    expect(r.stationForItem('item-y').bevPrinterId, isNull);
    expect(r.captainPrintersForStep(0).map((p) => p.id), ['p-kitchen']);
  });

  test('a payload without categoryRoutes keeps the old item-only behaviour', () {
    final r = PrinterRouting.parse({
      'printers': [printer('p-bar')],
      'itemRoutes': [
        {'itemId': 'i1', 'captainPrinterId': 'p-bar'},
      ],
    });
    expect(r.categoryRoutes, isEmpty);
    expect(r.captainPrinterForLine('i1')!.id, 'p-bar');
    expect(r.captainPrinterForLine('i2'), isNull);
  });
}
