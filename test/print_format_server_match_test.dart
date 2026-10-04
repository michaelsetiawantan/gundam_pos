import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gundam_pos/data/print_format_store.dart';
import 'package:gundam_pos/logic/money.dart' as money;
import 'package:gundam_pos/logic/print_payload.dart';
import 'package:gundam_pos/services/print_broker.dart';
import 'package:gundam_pos/services/print_dispatcher.dart';
import 'package:gundam_pos/ui/bill_preview_screen.dart';

import 'support/print_support.dart';

// The EXACT shape web/lib/config/resync.ts buildFormats() returns for the FORMAT
// domain: { formats: [{formatId,name,ticketType,version,widthMm,blocks}], skipped }.
// ticketType uses the SAME strings the tablet asks for (BILL/CAPTAIN_ORDER/BEV_LABEL).
Map<String, dynamic> _serverFormatPayload() => jsonDecode(jsonEncode({
      'formats': [
        {
          'formatId': 'f-bill', 'name': 'Agreed Bill', 'ticketType': 'BILL',
          'version': 1, 'widthMm': 80,
          'blocks': [
            {'id': 'a', 'type': 'TEXT', 'text': 'AGREED BILL'},
            {'id': 'b', 'type': 'MONEY_LINES', 'lines': ['TOTAL']},
          ],
        },
        {
          'formatId': 'f-cap', 'name': 'Agreed Captain', 'ticketType': 'CAPTAIN_ORDER',
          'version': 1, 'widthMm': 80,
          'blocks': [ {'id': 'a', 'type': 'TEXT', 'text': 'AGREED CAPTAIN'} ],
        },
        {
          'formatId': 'f-bev', 'name': 'Agreed Bev', 'ticketType': 'BEV_LABEL',
          'version': 1, 'widthMm': 80,
          'blocks': [ {'id': 'a', 'type': 'TEXT', 'text': 'AGREED BEV'} ],
        },
      ],
      'skipped': <Object>[],
    })) as Map<String, dynamic>;

PrintFormatStore _serverStore() {
  final store = PrintFormatStore();
  expect(store.apply(_serverFormatPayload(), version: 5), isTrue);
  return store;
}

money.MoneyFlow _flow() => money.computeMoneyFlow(
      [money.MoneyLine(subtotal: 25000, vatMode: money.VatScMode.none, scMode: money.VatScMode.none)],
      0, 0, money.RoundingMode.none,
    );
money.SplitResult _split() =>
    money.finalizePayments(_flow().total, [money.PaymentInput(outletMethodId: 'pm-cash', type: money.PayType.cash, amount: _flow().total)]);

List<PrintItem> _items() => [
      PrintItem(name: 'Espresso', itemId: 'item-espresso', qty: 1, unitPrice: 25000, batchIndex: 0),
      PrintItem(name: 'Nasi', itemId: 'item-nasi', qty: 1, unitPrice: 45000, batchIndex: 0),
    ];

const _emptyPayload = {'tokens': <String, Object?>{}, 'items': <Object>[], 'payments': <Object>[]};

void main() {
  group('FORMAT domain mapping — server ticket types match the tablet', () {
    test('store parses server types; forTicket resolves each requested type', () {
      final store = _serverStore();
      expect(store.notice, isNull);
      for (final t in ['BILL', 'CAPTAIN_ORDER', 'BEV_LABEL']) {
        expect(store.formatFor(t), isNotNull, reason: 'server format for $t must resolve');
      }
    });
  });

  group('(a) BILL server format is used by BOTH preview and print', () {
    test('preview', () {
      final r = renderBillPreview(store: _serverStore(), payload: _emptyPayload, widthMm: 80);
      expect(r.usedServerFormat, isTrue);
      expect(r.text, contains('AGREED BILL'));
    });

    test('print path', () async {
      final rec = RecordingTransport();
      final d = buildDispatcher(rec, store: _serverStore());
      final out = await d.printBill(items: _items(), receiptId: 'R-1', flow: _flow(), split: _split());
      expect(out.printed, isNotEmpty);
      expect(out.printed.every((r) => r.usedFormat), isTrue);
      expect(rec.jobs.single.lines.join('\n'), contains('AGREED BILL'));
      expect(out.alerts.any((a) => a.contains('built-in')), isFalse);
    });
  });

  group('(b) CAPTAIN_ORDER and BEV_LABEL server formats are used', () {
    test('CAPTAIN_ORDER', () async {
      final rec = RecordingTransport();
      final d = buildDispatcher(rec, store: _serverStore());
      final out = await d.printCaptainOrder(items: _items(), tableName: 'A1');
      expect(out.printed, isNotEmpty);
      expect(out.printed.every((r) => r.usedFormat), isTrue);
      expect(rec.jobs.every((j) => j.lines.join('\n').contains('AGREED CAPTAIN')), isTrue);
    });

    test('BEV_LABEL', () async {
      final rec = RecordingTransport();
      final d = buildDispatcher(rec, store: _serverStore());
      final out = await d.printBevLabels(items: _items(), tableName: 'A1');
      expect(out.printed, isNotEmpty);
      expect(out.printed.every((r) => r.usedFormat), isTrue);
      expect(rec.jobs.every((j) => j.lines.join('\n').contains('AGREED BEV')), isTrue);
    });
  });

  group('(c) no/unknown server format → honest notice, never silent', () {
    test('broker reports usedFormat=false with a reason for an unknown type', () {
      final broker = PrintBroker(store: _serverStore(), queue: PrintQueue(transport: RecordingTransport()));
      final r = broker.renderTicket(ticketType: 'FOO', payload: _emptyPayload);
      expect(r.usedFormat, isFalse);
      expect(r.fallbackReason, isNotNull);
    });

    test('print path surfaces an honest built-in alert when the type is missing among published formats', () async {
      // The outlet published other formats but NOT a BILL one → the BILL must
      // NOT silently go out on the built-in layout.
      final store = PrintFormatStore();
      store.apply({
        'formats': [
          {'formatId': 'f-bev', 'ticketType': 'BEV_LABEL', 'version': 1, 'widthMm': 58,
            'blocks': [{'id': 'a', 'type': 'TEXT', 'text': 'AGREED BEV'}]},
        ],
      });
      final rec = RecordingTransport();
      final d = buildDispatcher(rec, store: store);
      final out = await d.printBill(items: _items(), receiptId: 'R-1', flow: _flow(), split: _split());
      expect(out.printed.single.usedFormat, isFalse);
      expect(out.alerts.any((a) => a.contains('built-in layout')), isTrue);
    });

    test('no formats published at all → built-in is the norm, no misleading alert', () async {
      final rec = RecordingTransport();
      final d = buildDispatcher(rec, store: PrintFormatStore());
      final out = await d.printBill(items: _items(), receiptId: 'R-1', flow: _flow(), split: _split());
      expect(out.printed.single.usedFormat, isFalse);
      expect(out.alerts.any((a) => a.contains('built-in layout')), isFalse);
    });
  });

  group('(d) regression — built-in layout still prints as a safe fallback', () {
    test('empty store: built-in BILL prints, never crashes', () {
      final broker = PrintBroker(store: PrintFormatStore(), queue: PrintQueue(transport: RecordingTransport()));
      final r = broker.renderTicket(ticketType: 'BILL', payload: {
        'tokens': {'receipt_id': 'R-9', 'store_name': 'NORTHSTAR'},
        'items': <Object>[],
        'payments': <Object>[],
      });
      expect(r.usedFormat, isFalse);
      expect(r.lines.join('\n'), contains('R-9'));
    });
  });
}
