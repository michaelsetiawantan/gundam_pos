import 'package:flutter_test/flutter_test.dart';
import 'package:gundam_pos/data/print_format_store.dart';
import 'package:gundam_pos/logic/cart.dart';
import 'package:gundam_pos/logic/money.dart' as money;
import 'package:gundam_pos/logic/print_payload.dart';
import 'package:gundam_pos/services/print_broker.dart';

// ---------------------------------------------------------------------------
// Fixtures — a representative settled bill built through the canonical money
// helper (never hand-computed).
// ---------------------------------------------------------------------------

CartLine _espresso() => CartLine(
      itemId: 'item-espresso',
      name: 'Espresso',
      sku: 'NSTAR-NS-ESP',
      qty: 2,
      priceLevelIndex: 1,
      unitPrice: 22000,
      vatMode: money.VatScMode.exclude,
      modifiers: [CartModifier(modifierId: 'mod-shot', name: 'Extra Shot', price: 3000)],
    );

CartLine _icedTea() => CartLine(
      itemId: 'item-tea',
      name: 'Iced Tea',
      sku: 'NSTAR-NS-TEA',
      qty: 1,
      priceLevelIndex: 0,
      unitPrice: 11000,
    );

money.MoneyFlow _flow(List<CartLine> lines, {double discount = 0}) => money.computeMoneyFlow(
      [
        for (final l in lines)
          money.MoneyLine(
            subtotal: l.lineSubtotal,
            vatMode: l.vatMode,
            vatRate: l.vatMode == money.VatScMode.exclude ? 11 : null,
            scMode: money.VatScMode.none,
          ),
      ],
      discount,
      0,
      money.RoundingMode.none,
    );

TicketContext _ctx({String type = 'BILL'}) => TicketContext(
      storeName: 'Northstar Cafe',
      storeAddress: 'Jl. Sudirman 18',
      cashier: 'Rina',
      tableName: 'A1',
      ticketType: type,
      printerName: 'Front Receipt 01',
      printerWidthMm: 80,
      thankYouMessage: 'Thank you',
      at: DateTime(2026, 9, 28, 14, 5, 0),
    );

void main() {
  final lines = [_espresso(), _icedTea()];
  final flow = _flow(lines);
  final split = money.finalizePayments(flow.total, [
    money.PaymentInput(outletMethodId: 'pm-cash', type: money.PayType.cash, amount: 100000, reference: 'DRAWER-1'),
  ]);
  const receiptId = 'NSTAR-POS1-20260928-14:05-0000001';
  const builder = TicketPayloadBuilder();

  List<PrintItem> billItems() => [
        PrintItem.fromCartLine(lines[0], batchIndex: 0, priceLevelLabel: 'Double'),
        PrintItem.fromCartLine(lines[1], batchIndex: 0),
      ];

  Map<String, dynamic> billPayload() => builder.bill(
        ctx: _ctx(),
        items: billItems(),
        receiptId: receiptId,
        flow: flow,
        split: split,
        methodNames: {'pm-cash': 'Cash'},
        paidAt: DateTime(2026, 9, 28, 14, 5, 0),
      );

  group('TicketPayloadBuilder.bill — settled bill', () {
    test('tokens carry receipt id, table, cashier and money flow from the helper', () {
      final t = billPayload()['tokens'] as Map<String, dynamic>;
      expect(t['receipt_id'], receiptId);
      expect(t['table_name'], 'A1');
      expect(t['cashier_name'], 'Rina');
      expect(t['store_name'], 'Northstar Cafe');
      // money flow values are the canonical helper outputs, never recomputed
      expect(t['subtotal'], flow.subtotal);
      expect(t['vat_amount'], flow.vatAmount);
      expect(t['vat'], flow.vatAmount);
      expect(t['total'], flow.total);
      expect(t['paid_amount'], split.paid);
      expect(t['paid'], split.paid);
      expect(t['change'], split.change);
      expect(t['discount_amount'], flow.discountAmount);
      expect(t['payment_type'], 'CASH');
      expect(flow.vatAmount, greaterThan(0)); // 11% exclude on the espresso line
    });

    test('items carry modifiers and price level', () {
      final items = billPayload()['items'] as List;
      expect(items, hasLength(2));
      final esp = items[0] as Map<String, dynamic>;
      expect(esp['name'], 'Espresso');
      expect(esp['qty'], 2);
      expect(esp['lineTotal'], lines[0].lineSubtotal); // modifier-inclusive
      expect(esp['priceLevelIndex'], 1);
      expect(esp['priceLevel'], 'Double');
      final mods = esp['modifiers'] as List;
      expect(mods.single['name'], 'Extra Shot');
      expect(mods.single['price'], 3000);
    });

    test('payments list reflects the split allocations', () {
      final payments = billPayload()['payments'] as List;
      expect(payments, hasLength(1));
      final p = payments.single as Map<String, dynamic>;
      expect(p['name'], 'Cash');
      expect(p['type'], 'CASH');
      expect(p['amount'], 100000.0);
      expect(p['allocated'], flow.total);
      expect(p['change'], split.change);
      expect(p['reference'], 'DRAWER-1');
      expect(p['splitIndex'], 1);
    });
  });

  group('TicketPayloadBuilder — captain order batches (A/B/C sheets)', () {
    List<PrintItem> batches() => [
          PrintItem(name: 'Nasi Goreng', qty: 1, unitPrice: 45000, batchIndex: 0),
          PrintItem(name: 'Mie Goreng', qty: 2, unitPrice: 40000, batchIndex: 0),
          PrintItem(name: 'Es Teh', qty: 3, unitPrice: 8000, batchIndex: 1),
          PrintItem(name: 'Kopi', qty: 1, unitPrice: 25000, batchIndex: 2),
        ];

    test('one sheet per batch, labelled A/B/C, items scoped to their batch', () {
      final sheets = builder.captainOrderSheets(ctx: _ctx(type: 'CAPTAIN_ORDER'), items: batches());
      expect(sheets, hasLength(3));
      expect((sheets[0]['tokens'] as Map)['batch_label'], 'A');
      expect((sheets[1]['tokens'] as Map)['batch_label'], 'B');
      expect((sheets[2]['tokens'] as Map)['batch_label'], 'C');
      expect((sheets[0]['items'] as List).map((i) => i['name']), ['Nasi Goreng', 'Mie Goreng']);
      expect((sheets[1]['items'] as List).single['name'], 'Es Teh');
      expect((sheets[2]['items'] as List).single['name'], 'Kopi');
      // min 1 item per batch
      expect(sheets.every((s) => (s['items'] as List).isNotEmpty), isTrue);
    });

    test('captainOrder filters a single batch; canceledOrder labels it', () {
      final a = builder.captainOrder(ctx: _ctx(type: 'CAPTAIN_ORDER'), items: batches(), batchIndex: 0);
      expect((a['items'] as List), hasLength(2));
      expect((a['tokens'] as Map)['ticket_type'], 'CAPTAIN_ORDER');

      final canceled = builder.canceledOrder(
        ctx: TicketContext(canceledLabel: '*** CANCELED ***', cancelReason: 'Customer left', tableName: 'A1'),
        items: batches(),
        batchIndex: 1,
      );
      expect((canceled['items'] as List).single['name'], 'Es Teh');
      expect((canceled['tokens'] as Map)['ticket_type'], 'CANCELED_ORDER');
      expect((canceled['tokens'] as Map)['canceled_label'], '*** CANCELED ***');
      expect((canceled['tokens'] as Map)['cancel_reason'], 'Customer left');
    });
  });

  group('TicketPayloadBuilder.bevLabel — single item', () {
    test('one item, no payments, BEV_LABEL type', () {
      final p = builder.bevLabel(
        ctx: _ctx(type: 'BEV_LABEL'),
        item: PrintItem.fromCartLine(lines[1], batchIndex: 2, priceLevelLabel: 'Large'),
      );
      expect((p['items'] as List), hasLength(1));
      expect((p['items'] as List).single['name'], 'Iced Tea');
      expect((p['payments'] as List), isEmpty);
      expect((p['tokens'] as Map)['ticket_type'], 'BEV_LABEL');
    });
  });

  group('TicketPayloadBuilder.shiftReport', () {
    test('maps the closing report onto shift tokens', () {
      final p = builder.shiftReport(
        ctx: _ctx(type: 'Z_REPORT'),
        shiftId: 'SHF-1',
        totalSales: 4820000,
        transactionCount: 57,
        cashVariance: 5000,
        reportDate: DateTime(2026, 9, 28),
      );
      final t = p['tokens'] as Map;
      expect(t['shift_id'], 'SHF-1');
      expect(t['total_sales'], 4820000);
      expect(t['transaction_count'], 57);
      expect(t['z_report_date'], '2026-09-28');
    });
  });

  group('print formats wired into the print path', () {
    PrintFormatStore emptyStore() => PrintFormatStore();
    late List<PrintJob> sent;
    late PrintQueue queue;
    late PrintBroker broker;

    setUp(() {
      sent = [];
      queue = PrintQueue(transport: _Recording(sent));
      broker = PrintBroker(store: emptyStore(), queue: queue);
    });

    const printer = PrintPrinter(name: 'Front', host: '10.0.0.9');

    test('no format configured → built-in fallback, never blocks', () {
      final r = broker.renderTicket(ticketType: 'BILL', payload: billPayload());
      expect(r.usedFormat, isFalse);
      expect(r.fallbackReason, isNotNull);
      final joined = r.lines.join('\n');
      expect(joined, contains(receiptId)); // receipt id present
      expect(joined, contains(money.moneyLabel(flow.total, ''))); // total present, money-formatted
    });

    test('malformed payload falls back and never throws', () {
      final store = emptyStore();
      expect(store.apply('not json at all {{{'), isFalse);
      expect(store.formatFor('BILL'), isNull);
      final b = PrintBroker(store: store, queue: queue);
      late TicketRender r;
      expect(() => r = b.renderTicket(ticketType: 'BILL', payload: billPayload()), returnsNormally);
      expect(r.usedFormat, isFalse);
      expect(store.notice, isNotNull);
    });

    test('configured format is rendered and its lines carry receipt id + total', () {
      final store = emptyStore();
      final ok = store.apply({
        'formats': [
          {
            'formatId': 'f-bill',
            'name': 'Custom Bill',
            'ticketType': 'BILL',
            'version': 2,
            'widthMm': 80,
            'blocks': [
              {'id': 'a', 'type': 'TEXT', 'text': 'RECEIPT {receipt_id}'},
              {'id': 'b', 'type': 'MONEY_LINES', 'lines': ['SUBTOTAL', 'VAT', 'TOTAL']},
            ],
          },
        ],
      });
      expect(ok, isTrue);
      final b = PrintBroker(store: store, queue: queue);
      final r = b.renderTicket(ticketType: 'BILL', payload: billPayload());
      expect(r.usedFormat, isTrue);
      final joined = r.lines.join('\n');
      expect(joined, contains(receiptId));
      expect(joined, contains(money.moneyLabel(flow.total, '')));
    });

    test('wrong ticket type → built-in for that type', () {
      final store = emptyStore();
      store.apply({
        'formats': [
          {'formatId': 'f-bev', 'ticketType': 'BEV_LABEL', 'version': 1, 'widthMm': 80, 'blocks': [
            {'id': 'a', 'type': 'TEXT', 'text': 'X'},
          ]},
        ],
      });
      final b = PrintBroker(store: store, queue: queue);
      final r = b.renderTicket(ticketType: 'BILL', payload: billPayload());
      expect(r.usedFormat, isFalse);
    });

    test('printTicket renders then queues the job sequentially', () async {
      await broker.printTicket(ticketType: 'BILL', payload: billPayload(), printer: printer);
      await broker.printTicket(
        ticketType: 'CAPTAIN_ORDER',
        payload: builder.captainOrder(ctx: _ctx(type: 'CAPTAIN_ORDER'), items: billItems()),
        printer: printer,
      );
      expect(sent, hasLength(2));
      expect(sent[0].ticketType, 'BILL');
      expect(sent[1].ticketType, 'CAPTAIN_ORDER');
      expect(sent[0].lines, isNotEmpty);
    });
  });

  group('PrintFormatStore — last-known-good + versioning', () {
    test('keeps the good set when a later payload is unrecognized', () {
      final store = PrintFormatStore();
      store.apply({
        'formats': [
          {'formatId': 'f1', 'ticketType': 'BILL', 'version': 1, 'widthMm': 80, 'blocks': [
            {'id': 'a', 'type': 'TEXT', 'text': 'OV1'},
          ]},
        ],
      }, version: 1);
      expect(store.formatFor('BILL')!.name, isNotNull);
      final before = store.formatFor('BILL')!.formatId;
      expect(store.apply('{broken', version: 2), isFalse);
      expect(store.formatFor('BILL')!.formatId, before); // last-known-good intact
    });

    test('rejects a stale version and reports it', () {
      final store = PrintFormatStore();
      store.apply({'formats': [
        {'formatId': 'f2', 'ticketType': 'BILL', 'version': 2, 'widthMm': 80, 'blocks': [
          {'id': 'a', 'type': 'TEXT', 'text': 'V2'},
        ]},
      ]}, version: 3);
      expect(store.apply({'formats': <Object>[]}, version: 1), isFalse);
      expect(store.current.version, 3);
      expect(store.notice, contains('stale'));
    });
  });

  group('PrintQueue — sequential + retry', () {
    test('jobs fire in order', () async {
      final order = <String>[];
      final q = PrintQueue(transport: _Ordered(order));
      await Future.wait([
        q.submit(_job('A', const PrintPrinter(name: 'p', host: 'h'))),
        q.submit(_job('B', const PrintPrinter(name: 'p', host: 'h'))),
        q.submit(_job('C', const PrintPrinter(name: 'p', host: 'h'))),
      ]);
      expect(order, ['A', 'B', 'C']);
    });

    test('retries up to the printer retryCount then succeeds', () async {
      final t = _Flaky(failures: 2);
      final q = PrintQueue(transport: t);
      await q.submit(_job('A', const PrintPrinter(name: 'p', host: 'h', retryCount: 3)));
      expect(t.attempts, 3);
    });

    test('exhausting retries throws PrintJobFailed but the chain survives', () async {
      final t = _Flaky(failures: 99);
      final q = PrintQueue(transport: t);
      await expectLater(
        q.submit(_job('A', const PrintPrinter(name: 'p', host: 'h', retryCount: 3, retryTimeoutSec: 1))),
        throwsA(isA<PrintJobFailed>()),
      );
      expect(t.attempts, 3);
      // a following job still runs
      final ok = _Recording([]);
      final q2 = PrintQueue(transport: ok);
      await q2.submit(_job('B', const PrintPrinter(name: 'p', host: 'h')));
      expect(ok.jobs.single.ticketType, 'B');
    });
  });
}

PrintJob _job(String type, PrintPrinter printer) =>
    PrintJob(ticketType: type, lines: [type], entries: const [], printer: printer);

class _Recording implements PrintTransport {
  _Recording(this.jobs);
  final List<PrintJob> jobs;
  @override
  Future<void> send(PrintJob job) async => jobs.add(job);
}

class _Ordered implements PrintTransport {
  _Ordered(this.order);
  final List<String> order;
  @override
  Future<void> send(PrintJob job) async {
    await Future<void>.delayed(const Duration(milliseconds: 5));
    order.add(job.ticketType);
  }
}

class _Flaky implements PrintTransport {
  _Flaky({required this.failures});
  final int failures;
  int attempts = 0;
  @override
  Future<void> send(PrintJob job) async {
    attempts++;
    if (attempts <= failures) throw StateError('offline');
  }
}
