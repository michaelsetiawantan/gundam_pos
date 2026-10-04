import 'package:flutter_test/flutter_test.dart';
import 'package:gundam_pos/logic/print_format.dart';
import 'package:gundam_pos/logic/print_format_render.dart';

// Grouped kitchen ticket: ONE ticket can carry several menus when stations are
// merged, so each menu gets its own rule and the modifiers sit under their own
// item (a flat MODIFIER_LIST at the ticket end detaches them from the dish).

PrintRenderResult renderGrouped(
  List<Map<String, dynamic>> blocks,
  List<Map<String, dynamic>> items, {
  int widthMm = 80,
}) =>
    renderPrintFormat(
      format: PrintFormat.fromJson({
        'formatId': 'f1', 'name': 'Captain', 'ticketType': 'CAPTAIN_ORDER',
        'version': 1, 'widthMm': widthMm, 'blocks': blocks,
      }),
      ticketPayload: {'tokens': {'ticket_type': 'CAPTAIN_ORDER'}, 'items': items, 'payments': []},
    );

final groupedItems = <Map<String, dynamic>>[
  {'name': 'Latte', 'qty': 1, 'price': 30000, 'menu': 'Coffee', 'modifiers': [{'name': 'Oat', 'price': 8000}]},
  {'name': 'Americano', 'qty': 2, 'price': 25000, 'menu': 'Coffee'},
  {'name': 'Nasi Goreng', 'qty': 1, 'price': 45000, 'menu': 'Food', 'modifiers': [{'name': 'Telur', 'price': 5000}]},
  {'name': 'Extra', 'qty': 1, 'price': 1000},
];

const menuList = <Map<String, dynamic>>[
  {'id': 'i', 'type': 'ITEM_LIST', 'columns': 'NAME_QTY', 'groupByMenu': true, 'withModifiers': true},
];

void main() {
  test('prints one menu rule per group, in first-seen order', () {
    final lines = renderGrouped(menuList, groupedItems).lines;
    final coffee = lines.indexWhere((l) => l.contains(' COFFEE '));
    final food = lines.indexWhere((l) => l.contains(' FOOD '));
    expect(coffee, greaterThanOrEqualTo(0));
    expect(food, greaterThan(coffee));
    // the rule fills the printable width with the header char
    expect(lines[coffee].length, cellsForWidthMm(80));
    expect(lines[coffee].startsWith('-- COFFEE'), isTrue);
    // an item never leaks into the other menu's section
    expect(lines.sublist(coffee, food).join(' '), contains('Latte'));
    expect(lines.sublist(coffee, food).join(' '), isNot(contains('Nasi Goreng')));
  });

  test('nests each item modifiers directly under it', () {
    final lines = renderGrouped(menuList, groupedItems).lines;
    final latte = lines.indexWhere((l) => l.contains('Latte'));
    expect(lines[latte + 1].trim(), '+ Oat');
  });

  test('a line with no menu prints without a header', () {
    final lines = renderGrouped(menuList, groupedItems).lines;
    expect(lines.where((l) => l.trim().isEmpty), isEmpty);
    expect(lines.any((l) => l.contains('Extra')), isTrue);
  });

  test('groupByMenu off keeps the flat list byte-for-byte compatible', () {
    final flat = renderGrouped(
      const [{'id': 'i', 'type': 'ITEM_LIST', 'columns': 'NAME_QTY'}],
      groupedItems,
    ).lines.join('\n');
    expect(flat, isNot(contains('COFFEE')));
    expect(flat, contains('Latte'));
    expect(flat, contains('Nasi Goreng'));
  });

  test('a custom menuChar is honoured', () {
    final lines = renderGrouped(
      const [{'id': 'i', 'type': 'ITEM_LIST', 'columns': 'NAME_QTY', 'groupByMenu': true, 'menuChar': '='}],
      groupedItems,
    ).lines;
    expect(lines.firstWhere((l) => l.contains('COFFEE')).startsWith('== COFFEE'), isTrue);
  });

  test('the built-in captain format carries the grouped header', () {
    // The device default must match the web builder default, or the preview lies.
    final builtin = PrintFormat.fromJson({
      'formatId': 'builtin:CAPTAIN_ORDER', 'name': 'Built-in', 'ticketType': 'CAPTAIN_ORDER',
      'version': 0, 'widthMm': 80,
      'blocks': const [
        {'id': 'f', 'type': 'ITEM_LIST', 'columns': 'NAME_QTY', 'wrap': true, 'groupByMenu': true, 'withModifiers': true},
      ],
    });
    final out = renderPrintFormat(
      format: builtin,
      ticketPayload: {'tokens': {}, 'items': groupedItems, 'payments': []},
    ).lines.join('\n');
    expect(out, contains('COFFEE'));
    expect(out, contains('FOOD'));
  });
}
