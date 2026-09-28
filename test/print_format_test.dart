import 'package:flutter_test/flutter_test.dart';
import 'package:gundam_pos/logic/print_format.dart';
import 'package:gundam_pos/logic/print_format_render.dart';

/// Build a format from a block list (helper for the cases).
PrintFormat fmt(List<Map<String, dynamic>> blocks, {int widthMm = 80, String type = 'BILL'}) =>
    PrintFormat.fromJson({
      'formatId': 'f1',
      'name': 'Test',
      'ticketType': type,
      'version': 1,
      'widthMm': widthMm,
      'blocks': blocks,
    });

PrintRenderResult render(List<Map<String, dynamic>> blocks, Map<String, dynamic> payload,
        {int widthMm = 80}) =>
    renderPrintFormat(format: fmt(blocks, widthMm: widthMm), ticketPayload: payload);

void main() {
  group('width cells (CONTRACT §3)', () {
    test('58mm = 32 cells, 80mm = 48 cells', () {
      expect(cellsForWidthMm(58), 32);
      expect(cellsForWidthMm(80), 48);
    });
  });

  group('block ordering + unlimited count', () {
    test('blocks render in array order', () {
      final r = render([
        {'id': 'a', 'type': 'TEXT', 'text': 'FIRST'},
        {'id': 'b', 'type': 'TEXT', 'text': 'SECOND'},
        {'id': 'c', 'type': 'TEXT', 'text': 'THIRD'},
      ], {});
      expect(r.lines.map((l) => l.trimRight()).toList(), ['FIRST', 'SECOND', 'THIRD']);
    });

    test('unlimited block count (50 blocks all render)', () {
      final blocks = [
        for (var i = 0; i < 50; i++) {'id': 'b$i', 'type': 'TEXT', 'text': 'L$i'},
      ];
      final r = render(blocks, {});
      expect(r.lines, hasLength(50));
      expect(r.lines.first.trimRight(), 'L0');
      expect(r.lines.last.trimRight(), 'L49');
    });
  });

  group('token resolution (CONTRACT §5 rules 1-2)', () {
    test('unknown token prints literally', () {
      final r = render([
        {'id': 't', 'type': 'TEXT', 'text': 'Hi {nope} ok'},
      ], {
        'tokens': {'name': 'World'},
      });
      expect(r.lines.single.trimRight(), contains('{nope}'));
      expect(r.lines.single.trimRight(), 'Hi {nope} ok');
    });

    test('known token with no value → empty string', () {
      final r = render([
        {'id': 't', 'type': 'TEXT', 'text': 'X:{empty}:Y'},
      ], {
        'tokens': {'empty': ''},
      });
      expect(r.lines.single.trimRight(), 'X::Y');
    });

    test('known token resolves from a braced or bare key', () {
      final r = render([
        {'id': 't', 'type': 'TEXT', 'text': 'Hi {name}'},
      ], {
        'tokens': {'{name}': 'Ada'},
      });
      expect(r.lines.single.trimRight(), 'Hi Ada');
    });
  });

  group('CONDITIONAL (CONTRACT §4)', () {
    Map<String, dynamic> cond(List<Map<String, dynamic>> blocks) => {
          'id': 'c',
          'type': 'CONDITIONAL',
          'if': {'param': '{payment_type}', 'op': 'EQ', 'value': 'CASH'},
          'blocks': blocks,
        };
    final child = [
      {'id': 'k', 'type': 'TEXT', 'text': 'CASH ONLY'},
    ];

    test('EQ true prints the child block in place', () {
      final r = render([
        {'id': 'a', 'type': 'TEXT', 'text': 'BEFORE'},
        cond(child),
        {'id': 'z', 'type': 'TEXT', 'text': 'AFTER'},
      ], {
        'tokens': {'payment_type': 'CASH'},
      });
      expect(r.lines.map((l) => l.trimRight()).toList(), ['BEFORE', 'CASH ONLY', 'AFTER']);
    });

    test('EQ false skips the child block silently', () {
      final r = render([cond(child)], {
        'tokens': {'payment_type': 'CARD'},
      });
      expect(r.lines, isEmpty);
    });

    test('PRESENT true and false; missing param → false', () {
      final present = [
        {
          'id': 'p',
          'type': 'CONDITIONAL',
          'if': {'param': '{payment_type}', 'op': 'PRESENT'},
          'blocks': [
            {'id': 'k', 'type': 'TEXT', 'text': 'HAS'},
          ],
        },
      ];
      expect(render(present, {'tokens': {'payment_type': 'CASH'}}).lines.single.trimRight(), 'HAS');
      expect(render(present, {'tokens': {'payment_type': ''}}).lines, isEmpty);
      expect(render(present, {}).lines, isEmpty); // missing param → false
    });
  });

  group('MONEY_LINES (only non-zero lines print)', () {
    test('zero lines are skipped, non-zero printed with 2 decimals', () {
      final r = render([
        {
          'id': 'm',
          'type': 'MONEY_LINES',
          'lines': ['SUBTOTAL', 'DISCOUNT', 'TOTAL'],
        },
      ], {
        'tokens': {'subtotal': 50000, 'discount': 0, 'total': 50000},
      });
      String line(String label, String value) => label.padRight(48 - value.length) + value;
      expect(r.lines, hasLength(2));
      expect(r.lines[0], line('Subtotal', '50000.00'));
      expect(r.lines[1], line('Total', '50000.00'));
    });

    test('a MONEY_LINES block with every line zero is skipped entirely', () {
      final r = render([
        {'id': 's', 'type': 'SEPARATOR'},
        {'id': 'm', 'type': 'MONEY_LINES', 'lines': ['DISCOUNT', 'TIPS']},
      ], {
        'tokens': {'discount': 0, 'tips': 0},
      });
      expect(r.lines, hasLength(1)); // separator only, no dangling empty rows
    });
  });

  group('wrapping + DOUBLE size', () {
    final longText = List.filled(8, 'WWWW').join(' '); // 39 chars

    test('wraps at 32 cells (58mm)', () {
      final r = render([
        {'id': 't', 'type': 'TEXT', 'text': longText},
      ], {}, widthMm: 58);
      expect(r.lines.length, greaterThan(1));
      expect(r.lines.every((l) => l.length <= 32), isTrue);
      expect(r.lines.map((l) => l.trimRight()).join(' '), longText);
    });

    test('does not wrap at 48 cells (80mm)', () {
      final r = render([
        {'id': 't', 'type': 'TEXT', 'text': longText},
      ], {}, widthMm: 80);
      expect(r.lines, hasLength(1));
    });

    test('DOUBLE halves the available cells', () {
      final text = 'x' * 32; // fits 48 normal, must wrap at 24 double
      final normal = render([
        {'id': 't', 'type': 'TEXT', 'text': text},
      ], {});
      expect(normal.lines, hasLength(1));

      final dbl = render([
        {'id': 't', 'type': 'TEXT', 'text': text, 'size': 'DOUBLE'},
      ], {});
      expect(dbl.lines.length, 2);
      expect(dbl.lines.every((l) => l.length <= 24), isTrue);
    });
  });

  group('ITEM_LIST columns', () {
    test('NAME_QTY_PRICE row lines up name qty price in fixed columns', () {
      final r = render([
        {'id': 'i', 'type': 'ITEM_LIST', 'columns': 'NAME_QTY_PRICE'},
      ], {
        'items': [
          {'name': 'Espresso', 'qty': 2, 'price': 22000, 'lineTotal': 44000},
        ],
      });
      final row = r.lines.single;
      expect(row.length, 48);
      expect(row, 'Espresso'.padRight(33) + '2'.padLeft(3) + '44000.00'.padLeft(12));
    });

    test('NAME_QTY omits price', () {
      final r = render([
        {'id': 'i', 'type': 'ITEM_LIST', 'columns': 'NAME_QTY'},
      ], {
        'items': [
          {'name': 'Iced Tea', 'qty': 3},
        ],
      });
      expect(r.lines.single, 'Iced Tea'.padRight(45) + '3'.padLeft(3));
    });
  });

  group('TABLE block (CONTRACT §2)', () {
    test('header + one data row per item, respecting widths/align', () {
      final r = render([
        {
          'id': 'tbl',
          'type': 'TABLE',
          'columns': [
            {'param': '{name}', 'label': 'Item', 'width': 20, 'align': 'LEFT'},
            {'param': '{qty}', 'label': 'Qty', 'width': 3, 'align': 'RIGHT'},
          ],
        },
      ], {
        'items': [
          {'name': 'Espresso', 'qty': 2},
        ],
      });
      expect(r.lines, hasLength(2));
      expect(r.lines[0], 'Item'.padRight(20) + 'Qty'.padLeft(3));
      expect(r.lines[1], 'Espresso'.padRight(20) + '2'.padLeft(3));
    });
  });

  group('QR / BARCODE surface as structured entries', () {
    test('QR and BARCODE resolve content and keep line order', () {
      final r = render([
        {'id': 'a', 'type': 'TEXT', 'text': 'TOP'},
        {'id': 'q', 'type': 'QR', 'content': '{receipt_no}', 'sizeMm': 20},
        {'id': 'b', 'type': 'BARCODE', 'content': 'ABC123', 'symbology': 'CODE128'},
      ], {
        'tokens': {'receipt_no': 'R-1'},
      });
      expect(r.entries, hasLength(2));
      expect(r.entries[0].kind, PrintableKind.qr);
      expect(r.entries[0].content, 'R-1');
      expect(r.entries[0].sizeMm, 20);
      expect(r.entries[0].atLine, 1);
      expect(r.entries[1].kind, PrintableKind.barcode);
      expect(r.entries[1].content, 'ABC123');
      expect(r.entries[1].symbology, 'CODE128');
      expect(r.entries[1].atLine, 1);
    });

    test('empty QR content is skipped (no entry)', () {
      final r = render([
        {'id': 'q', 'type': 'QR', 'content': '{missing}'},
      ], {});
      // unknown token stays literal, so it is NOT empty → entry kept
      expect(r.entries, hasLength(1));
      expect(r.entries.single.content, '{missing}');

      final empty = render([
        {'id': 'q', 'type': 'QR', 'content': '{num}'},
      ], {
        'tokens': {'num': ''},
      });
      expect(empty.entries, isEmpty);
    });
  });

  group('real BILL ticket end-to-end', () {
    Map<String, dynamic> billPayload() => {
          'tokens': {
            'receipt_no': 'NSTAR-POS1-20260928-14:05-0000001',
            'table_name': 'A1',
            'cashier': 'Rina',
            'subtotal': 66000.0,
            'discount': 0.0,
            'vat': 6600.0,
            'total': 72600.0,
            'paid': 100000.0,
            'change': 27400.0,
            'payment_type': 'CASH',
          },
          'items': [
            {
              'name': 'Espresso',
              'qty': 2,
              'price': 22000.0,
              'lineTotal': 44000.0,
              'batchIndex': 0,
              'modifiers': [
                {'name': 'Extra Shot', 'price': 3000.0},
              ],
            },
            {'name': 'Iced Tea', 'qty': 2, 'price': 11000.0, 'lineTotal': 22000.0},
          ],
          'payments': [
            {'name': 'Cash', 'type': 'cash', 'amount': 100000.0, 'reference': 'DRAWER-1'},
          ],
        };

    List<Map<String, dynamic>> billBlocks() => [
          {'id': 'h', 'type': 'TEXT', 'text': 'NORTHSTAR CAFE', 'align': 'CENTER', 'bold': true},
          {'id': 'r', 'type': 'TEXT', 'text': 'Receipt: {receipt_no}'},
          {'id': 't', 'type': 'TEXT', 'text': 'Table {table_name} - {cashier}'},
          {'id': 'sp1', 'type': 'SEPARATOR'},
          {'id': 'items', 'type': 'ITEM_LIST', 'columns': 'NAME_QTY_PRICE'},
          {'id': 'mods', 'type': 'MODIFIER_LIST', 'indent': 2},
          {'id': 'sp2', 'type': 'SEPARATOR'},
          {'id': 'm', 'type': 'MONEY_LINES', 'lines': ['SUBTOTAL', 'DISCOUNT', 'VAT', 'TOTAL', 'PAID', 'CHANGE']},
          {'id': 'sp3', 'type': 'SEPARATOR'},
          {'id': 'pay', 'type': 'PAYMENT_LINES', 'showReference': true},
          {'id': 'feed', 'type': 'FEED', 'lines': 2},
          {'id': 'q', 'type': 'QR', 'content': '{receipt_no}', 'sizeMm': 20},
        ];

    test('renders a full BILL in order with money, items and QR', () {
      final r = renderPrintFormat(
        format: fmt(billBlocks(), widthMm: 80),
        ticketPayload: billPayload(),
      );
      final joined = r.lines.join('\n');

      // header block first (centered)
      expect(r.lines.first.trim(), 'NORTHSTAR CAFE');
      // item rows present in array order before money lines
      expect(joined.indexOf('Espresso'), lessThan(joined.indexOf('Subtotal')));
      expect(joined, contains('Espresso'));
      expect(joined, contains('44000.00'));
      expect(joined, contains('Extra Shot'));
      // money lines, discount (0) omitted
      expect(joined, matches(RegExp(r'Subtotal\s+66000\.00')));
      expect(joined, matches(RegExp(r'VAT\s+6600\.00')));
      expect(joined, matches(RegExp(r'Total\s+72600\.00')));
      expect(joined, matches(RegExp(r'Change\s+27400\.00')));
      expect(joined, isNot(contains('Discount')));
      // payment + reference
      expect(joined, contains('Cash'));
      expect(joined, contains('ref: DRAWER-1'));
      // blank FEED lines at the tail, then the QR entry at that position
      expect(r.lines.getRange(r.lines.length - 2, r.lines.length), ['', '']);
      expect(r.entries.single.kind, PrintableKind.qr);
      expect(r.entries.single.content, 'NSTAR-POS1-20260928-14:05-0000001');
      expect(r.entries.single.atLine, r.lines.length);
      // every line fits the printer width
      expect(r.lines.every((l) => l.length <= 48), isTrue);
    });

    test('58mm BILL wraps to 32 cells and keeps receipt id intact via QR', () {
      final r = renderPrintFormat(
        format: fmt(billBlocks(), widthMm: 58),
        ticketPayload: billPayload(),
      );
      expect(r.lines.every((l) => l.length <= 32), isTrue);
      expect(r.entries.single.content, 'NSTAR-POS1-20260928-14:05-0000001');
    });
  });
}
