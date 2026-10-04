import 'package:flutter_test/flutter_test.dart';
import 'package:gundam_pos/data/print_format_store.dart';
import 'package:gundam_pos/data/print_log_store.dart';
import 'package:gundam_pos/logic/cart.dart';
import 'package:gundam_pos/logic/money.dart' as money;
import 'package:gundam_pos/logic/print_payload.dart';
import 'package:gundam_pos/models/config_models.dart';
import 'package:gundam_pos/services/print_log.dart';
import 'package:gundam_pos/services/printer_health.dart';
import 'package:gundam_pos/state/order_controller.dart';
import 'package:gundam_pos/state/payment_controller.dart';

import 'support/fake_backend.dart';
import 'support/print_support.dart';

TenantConfig _northstar() =>
    TenantConfig.fromSyncPayloads(FakeBackend.northstarMaster(), FakeBackend.northstarOutlet());

List<String> _types(List<dynamic> jobs) => [for (final j in jobs) j.ticketType as String];

void main() {
  group('PrintDispatcher — send-cart (captain per batch + bev per item)', () {
    test('one captain job per batch and one bev label PER UNIT', () async {
      final rec = RecordingTransport();
      final d = buildDispatcher(rec);
      final items = [
        PrintItem(name: 'Espresso', itemId: 'item-espresso', qty: 1, unitPrice: 25000, batchIndex: 0),
        PrintItem(name: 'Nasi Goreng', itemId: 'item-nasi', qty: 1, unitPrice: 45000, batchIndex: 0),
        PrintItem(name: 'Espresso', itemId: 'item-espresso', qty: 2, unitPrice: 25000, batchIndex: 1),
      ];
      final out = await d.printSendCart(items: items, tableName: 'A1');
      expect(out.alerts, isEmpty);
      // 2 batches → 2 captain jobs; the espresso is a bev item and labels print
      // PER UNIT: 1 (batch 0) + 2 (batch 1, qty 2) = 3 labels.
      expect(_types(rec.jobs).where((t) => t == 'CAPTAIN_ORDER').length, 2);
      expect(_types(rec.jobs).where((t) => t == 'BEV_LABEL').length, 3);
      expect(rec.jobs.where((j) => j.ticketType == 'CAPTAIN_ORDER').every((j) => j.printer.name == 'Captain Station'), isTrue);
      expect(rec.jobs.where((j) => j.ticketType == 'BEV_LABEL').every((j) => j.printer.name == 'Bar Label'), isTrue);
    });

    test('captain reprint does NOT emit bev-label jobs', () async {
      final rec = RecordingTransport();
      final d = buildDispatcher(rec);
      final items = [
        PrintItem(name: 'Espresso', itemId: 'item-espresso', qty: 1, unitPrice: 25000, batchIndex: 0),
      ];
      await d.printCaptainOrder(items: items, tableName: 'A1');
      expect(_types(rec.jobs), ['CAPTAIN_ORDER']);
    });
  });

  group('PrintDispatcher — BILL + honest alerts', () {
    final lines = [
      CartLine(itemId: 'item-espresso', name: 'Espresso', sku: 'X', qty: 1, priceLevelIndex: 0, unitPrice: 25000, vatMode: money.VatScMode.exclude),
    ];
    money.MoneyFlow flow() => money.computeMoneyFlow(
          [money.MoneyLine(subtotal: 25000, vatMode: money.VatScMode.exclude, vatRate: 11, scMode: money.VatScMode.none)],
          0,
          0,
          money.RoundingMode.none,
        );
    money.SplitResult split() => money.finalizePayments(flow().total, [
          money.PaymentInput(outletMethodId: 'pm-cash', type: money.PayType.cash, amount: flow().total),
        ]);

    test('settle path prints one bill job to the outlet BILL printer', () async {
      final rec = RecordingTransport();
      final d = buildDispatcher(rec);
      final out = await d.printBill(
        items: [PrintItem.fromCartLine(lines.single)],
        receiptId: 'NSTAR-POS1-20260928-14:05-0000001',
        flow: flow(),
        split: split(),
        tableName: 'A1',
      );
      expect(out.alerts, isEmpty);
      expect(_types(rec.jobs), ['BILL']);
      expect(rec.jobs.single.printer.name, 'Front Receipt');
    });

    test('no printer configured for a ticket type → honest alert, no crash', () async {
      final rec = RecordingTransport();
      final d = buildDispatcher(rec, outlet: {'printers': [], 'routing': {}});
      final out = await d.printBill(
        items: [PrintItem.fromCartLine(lines.single)],
        receiptId: 'R-1',
        flow: flow(),
        split: split(),
      );
      expect(out.printed, isEmpty);
      expect(out.alerts.single, contains('No printer configured for BILL'));
      expect(rec.jobs, isEmpty);
    });

    test('USB printer is wired on this build — the job reaches the transport', () async {
      final rec = RecordingTransport();
      final d = buildDispatcher(rec, outlet: {
        'printers': [
          {'id': 'usb', 'name': 'USB Label', 'transport': 'USB', 'usbVidPid': '04b8:0e15', 'usbChip': 'CH340'},
        ],
        'routing': {
          'BILL': [
            {'printerId': 'usb'},
          ],
        },
      });
      final out = await d.printBill(
        items: [PrintItem.fromCartLine(lines.single)],
        receiptId: 'R-1',
        flow: flow(),
        split: split(),
      );
      expect(out.alerts, isEmpty);
      expect(rec.jobs.single.printer.transport, 'USB');
      expect(rec.jobs.single.printer.usbVidPid, '04b8:0e15');
      expect(rec.jobs.single.printer.usbChip, 'CH340');
      expect(d.unsupportedPrinters, isEmpty);
    });

    test('same-day reprint: bill reprints; captain reprints whole order without bev', () async {
      final rec = RecordingTransport();
      final d = buildDispatcher(rec);
      final items = [
        PrintItem(name: 'Espresso', itemId: 'item-espresso', qty: 1, unitPrice: 25000, batchIndex: 0),
        PrintItem(name: 'Nasi', itemId: 'item-nasi', qty: 1, unitPrice: 45000, batchIndex: 0),
      ];
      const receipt = 'NSTAR-POS1-20260928-14:05-0000001';
      await d.printBill(items: items, receiptId: receipt, flow: flow(), split: split(), tableName: 'A1');
      expect(_types(rec.jobs), ['BILL']);

      final billReprint = await d.reprintBill(receipt);
      expect(billReprint.alerts, isEmpty);
      expect(_types(rec.jobs), ['BILL', 'BILL']);

      rec.jobs.clear();
      final captainReprint = await d.reprintCaptain(receipt);
      expect(captainReprint.alerts, isEmpty);
      expect(_types(rec.jobs), ['CAPTAIN_ORDER']); // NO bev labels
    });

    test('reprint for an unknown receipt → honest alert', () async {
      final rec = RecordingTransport();
      final d = buildDispatcher(rec);
      final out = await d.reprintBill('nope');
      expect(out.printed, isEmpty);
      expect(out.alerts.single, contains('No same-day print record'));
    });
  });

  group('OrderController → send-cart prints (controller wiring)', () {
    test('sendCart submits a captain job per batch and bev-label per item', () async {
      final backend = FakeBackend();
      final session = backend.createSession();
      final config = _northstar();
      final rec = RecordingTransport();
      final d = buildDispatcher(rec);
      final c = OrderController(
        posApi: session.posApi,
        tenantId: 't1',
        config: config,
        deviceAssetId: 'device-1',
        printer: d,
      );
      expect(await c.startOrder(tableId: 'tbl-a1', tableName: 'A1'), isTrue);
      expect(await c.addItem(config.itemById('item-espresso')!), isNotNull);
      expect(await c.sendCart(), isTrue);
      await pumpEventQueue();
      expect(c.printAlerts, isEmpty);
      expect(_types(rec.jobs).contains('CAPTAIN_ORDER'), isTrue);
      expect(_types(rec.jobs).contains('BEV_LABEL'), isTrue);
      expect(_types(rec.jobs).where((t) => t == 'CAPTAIN_ORDER').length, 1);
      expect(_types(rec.jobs).where((t) => t == 'BEV_LABEL').length, 1);

      // a second send-cart produces its own batch sheet
      expect(await c.addItem(config.itemById('item-nasi')!), isNotNull);
      expect(await c.sendCart(), isTrue);
      await pumpEventQueue();
      expect(_types(rec.jobs).where((t) => t == 'CAPTAIN_ORDER').length, 2);
    });
  });

  group('PaymentController → settle prints the bill (controller wiring)', () {
    test('settle submits a BILL job', () async {
      final backend = FakeBackend();
      final session = backend.createSession();
      final config = _northstar();
      final rec = RecordingTransport();
      final d = buildDispatcher(rec);
      final cart = Cart()
        ..addLine(CartLine(
          itemId: 'item-espresso',
          name: 'Espresso',
          sku: 'NSTAR-NS-ESP',
          qty: 1,
          priceLevelIndex: 0,
          unitPrice: 25000,
          vatMode: money.VatScMode.exclude,
        ));
      final c = PaymentController(
        posApi: session.posApi,
        tenantId: 't1',
        config: config,
        orderId: 'order-1',
        tableName: 'A1',
        cart: cart,
        deviceAssetId: 'device-1',
        shortcode: 'NSTAR-POS1',
        printer: d,
      );
      c.addPayment(config.paymentMethods.firstWhere((m) => m.type == money.PayType.cash), c.payable);
      expect(await c.settle(), isTrue);
      await pumpEventQueue();
      expect(c.printAlerts, isEmpty);
      expect(_types(rec.jobs), ['BILL']);
      // same-day reprint of that receipt works off the dispatcher cache
      expect(d.hasReprint(c.receiptId!), isTrue);
    });
  });

  group('PrinterHealthChecker surface stays honest', () {
    test('BLUETOOTH probes the SPP link; an unreachable NETWORK printer is offline', () async {
      final rec = RecordingTransport();
      final d = buildDispatcher(rec);
      final links = await d.checkHealth();
      // pr-bt is a Bluetooth printer: the probe reports its SPP link (stubbed ready).
      expect(links['pr-bt']!.state, PrinterLinkState.ready);
      expect(links['pr-front']!.state, PrinterLinkState.offline);
    });

    test('USB stays unsupported on this build', () async {
      final rec = RecordingTransport();
      final d = buildDispatcher(rec, outlet: {
        'printers': [
          {'id': 'usb', 'name': 'USB', 'transport': 'USB', 'usbVidPid': '04b8:0e15'},
        ],
      });
      final links = await d.checkHealth();
      expect(links['usb']!.state, PrinterLinkState.unsupported);
    });
  });

  group('print audit — the real print path records locally', () {
    money.MoneyFlow flow() => money.computeMoneyFlow(
          [money.MoneyLine(subtotal: 45000, vatMode: money.VatScMode.exclude, vatRate: 11, scMode: money.VatScMode.none)],
          0,
          0,
          money.RoundingMode.none,
        );
    money.SplitResult split(money.MoneyFlow f) => money.finalizePayments(f.total, [
          money.PaymentInput(outletMethodId: 'pm-cash', type: money.PayType.cash, amount: f.total),
        ]);

    test('a failed bill print lands in the local log with its error and attempt count', () async {
      final store = MemoryPrintLogStore();
      final d = buildDispatcher(AlwaysFailingTransport(), logs: PrintLogAudit(store: store));
      final f = flow();
      final out = await d.printBill(items: [PrintItem(name: 'Nasi', itemId: 'item-nasi', qty: 1, unitPrice: 45000, batchIndex: 0)], receiptId: 'R-1', flow: f, split: split(f));
      expect(out.alerts, isNotEmpty);
      final row = (await store.list()).single;
      expect(row.outcome, kOutcomeFailed);
      expect(row.ticketType, 'BILL');
      expect(row.receiptId, 'R-1');
      expect(row.printerTransport, 'NETWORK');
      expect(row.attemptCount, 3); // the Northstar BILL printer's retryCount
      expect(row.uploadState, kPrintLogPending);
    });

    test('a successful bill print is recorded as OK (metadata only)', () async {
      final store = MemoryPrintLogStore();
      final d = buildDispatcher(RecordingTransport(), logs: PrintLogAudit(store: store));
      final f = flow();
      await d.printBill(items: [PrintItem(name: 'Nasi', itemId: 'item-nasi', qty: 1, unitPrice: 45000, batchIndex: 0)], receiptId: 'R-1', flow: f, split: split(f));
      final row = (await store.list()).single;
      expect(row.outcome, kOutcomeOk);
      expect(row.renderedText, isNull);
    });
  });

  group('printer-model dialect + raster are reported, not guessed', () {
    money.MoneyFlow flow() => money.computeMoneyFlow(
          [money.MoneyLine(subtotal: 45000, vatMode: money.VatScMode.exclude, vatRate: 11, scMode: money.VatScMode.none)],
          0,
          0,
          money.RoundingMode.none,
        );
    money.SplitResult split() => money.finalizePayments(flow().total, [
          money.PaymentInput(outletMethodId: 'pm-cash', type: money.PayType.cash, amount: flow().total),
        ]);

    test('unknown protocol → an alert naming the dialect, job still prints', () async {
      final rec = RecordingTransport();
      final d = buildDispatcher(rec, outlet: {
        'printers': [
          {'id': 'p', 'name': 'Odd', 'transport': 'NETWORK', 'ip': '1.1.1.1', 'protocol': 'ZPL'},
        ],
        'routing': {
          'BILL': [
            {'printerId': 'p'},
          ],
        },
      });
      final out = await d.printBill(
        items: [PrintItem(name: 'Nasi', itemId: 'item-nasi', qty: 1, unitPrice: 45000, batchIndex: 0)],
        receiptId: 'R-1',
        flow: flow(),
        split: split(),
      );
      expect(out.printed, hasLength(1)); // never blocked by an unknown dialect
      expect(out.alerts.any((a) => a.contains('ZPL')), isTrue);
      expect(out.alerts.any((a) => a.contains('default ESC/POS')), isTrue);
    });

    test('an IMAGE block on a non-raster printer is reported as skipped', () async {
      final store = PrintFormatStore();
      store.apply({
        'formats': [
          {
            'formatId': 'f-img', 'name': 'Img Bill', 'ticketType': 'BILL', 'version': 1, 'widthMm': 80,
            'blocks': [
              {'id': 'a', 'type': 'TEXT', 'text': 'RECEIPT'},
              {'id': 'b', 'type': 'IMAGE', 'assetKey': 'logo'},
            ],
          },
        ],
      });
      final rec = RecordingTransport();
      final d = buildDispatcher(rec, store: store, outlet: {
        'printers': [
          {'id': 'p', 'name': 'Plain', 'transport': 'NETWORK', 'ip': '1.1.1.1', 'supportsRasterImage': false},
        ],
        'routing': {
          'BILL': [
            {'printerId': 'p'},
          ],
        },
      });
      final out = await d.printBill(
        items: [PrintItem(name: 'Nasi', itemId: 'item-nasi', qty: 1, unitPrice: 45000, batchIndex: 0)],
        receiptId: 'R-1',
        flow: flow(),
        split: split(),
      );
      expect(out.alerts.any((a) => a.contains('raster support')), isTrue);
    });
  });
}
