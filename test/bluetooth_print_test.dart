import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gundam_pos/logic/money.dart' as money;
import 'package:gundam_pos/logic/print_payload.dart';
import 'package:gundam_pos/services/bluetooth_print_transport.dart';
import 'package:gundam_pos/services/bluetooth_printer_channel.dart';
import 'package:gundam_pos/services/print_broker.dart';
import 'package:gundam_pos/services/printer_health.dart';

import 'support/print_support.dart';

const _channel = MethodChannel(BluetoothPrinterChannel.channelName);

/// Install a mock handler for the `gundam/printer` platform channel.
void _mock(Future<Object?> Function(MethodCall call) handler) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, handler);
}

void _mockClear() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, null);
}

/// A ready reply helper.
Map<String, Object?> _ok([String detail = 'ok']) => {'state': 'ready', 'detail': detail};

PrintJob _btJob({String mac = 'AA:BB:CC:DD:EE:FF', int retryCount = 1}) => PrintJob(
      ticketType: 'BILL',
      lines: ['HELLO'],
      entries: const [],
      printer: PrintPrinter(name: 'BT', transport: 'BLUETOOTH', bluetoothMac: mac, retryCount: retryCount),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('printerLinkStateFromCode — every Kotlin status maps to a PRD state', () {
    test('exact mapping', () {
      expect(printerLinkStateFromCode('ready'), PrinterLinkState.ready);
      expect(printerLinkStateFromCode('offline'), PrinterLinkState.offline);
      expect(printerLinkStateFromCode('disconnected'), PrinterLinkState.disconnected);
      expect(printerLinkStateFromCode('not_paired'), PrinterLinkState.notPaired);
      expect(printerLinkStateFromCode('bluetooth_off'), PrinterLinkState.bluetoothOff);
      expect(printerLinkStateFromCode('permission_required'), PrinterLinkState.permissionRequired);
      expect(printerLinkStateFromCode('unsupported'), PrinterLinkState.unsupported);
    });

    test('an unknown or null code is never guessed as healthy', () {
      expect(printerLinkStateFromCode('wat'), PrinterLinkState.unknown);
      expect(printerLinkStateFromCode(null), PrinterLinkState.unknown);
    });
  });

  group('PrinterHealthChecker — Bluetooth probe', () {
    test('missing permission → Permission required (never a crash)', () async {
      _mock((call) async {
        if (call.method == 'status') return {'state': 'permission_required', 'detail': 'no perm'};
        return _ok();
      });
      final link = await PrinterHealthChecker.defaultBluetoothProbe('AA:BB', false);
      expect(link.state, PrinterLinkState.permissionRequired);
      _mockClear();
    });

    test('adapter off → Bluetooth off', () async {
      _mock((call) async => {'state': 'bluetooth_off', 'detail': 'off'});
      final link = await PrinterHealthChecker.defaultBluetoothProbe('AA:BB', false);
      expect(link.state, PrinterLinkState.bluetoothOff);
      _mockClear();
    });

    test('a MAC that is not in the bonded list → Not paired', () async {
      _mock((call) async {
        if (call.method == 'status') return _ok();
        if (call.method == 'listBonded') {
          return [
            {'name': 'Other', 'mac': '11:22:33:44:55:66'},
          ];
        }
        return _ok();
      });
      final link = await PrinterHealthChecker.defaultBluetoothProbe('AA:BB:CC:DD:EE:FF', false);
      expect(link.state, PrinterLinkState.notPaired);
      _mockClear();
    });

    test('bonded + connect ready → Ready, device status unknown', () async {
      _mock((call) async {
        if (call.method == 'status') return _ok();
        if (call.method == 'listBonded') {
          return [
            {'name': 'Printer', 'mac': 'AA:BB:CC:DD:EE:FF'},
          ];
        }
        if (call.method == 'connect') return _ok('Connected');
        return _ok();
      });
      final link = await PrinterHealthChecker.defaultBluetoothProbe('aa:bb:cc:dd:ee:ff', false);
      expect(link.state, PrinterLinkState.ready);
      expect(link.detail, contains('Unknown'));
      _mockClear();
    });

    test('check() rejects a printer with no MAC before any channel call', () async {
      _mockClear();
      final link = await PrinterHealthChecker().check(transport: 'BLUETOOTH', bluetoothMac: null);
      expect(link.state, PrinterLinkState.notPaired);
    });
  });

  group('BluetoothPrintTransport — Kotlin errors become typed faults', () {
    test('a ready channel writes the ESC/POS bytes and does not throw', () async {
      final written = <List<int>>[];
      _mock((call) async {
        if (call.method == 'status') return _ok();
        if (call.method == 'connect') return _ok();
        if (call.method == 'write') {
          written.add(call.arguments['bytes'] as List<int>);
          return _ok();
        }
        return _ok();
      });
      await BluetoothPrintTransport().send(_btJob());
      expect(written, hasLength(1));
      expect(written.single.sublist(0, 2), [0x1B, 0x40]); // ESC @
      _mockClear();
    });

    test('permission_required → BluetoothPrintException(permissionRequired)', () async {
      _mock((call) async {
        if (call.method == 'status') return {'state': 'permission_required', 'detail': 'denied'};
        return _ok();
      });
      await expectLater(
        BluetoothPrintTransport().send(_btJob()),
        throwsA(isA<BluetoothPrintException>().having((e) => e.state, 'state', PrinterLinkState.permissionRequired)),
      );
      _mockClear();
    });

    test('not-bonded MAC → BluetoothPrintException(notPaired)', () async {
      _mock((call) async {
        if (call.method == 'status') return _ok();
        if (call.method == 'connect') return {'state': 'not_paired', 'detail': 'no'};
        return _ok();
      });
      await expectLater(
        BluetoothPrintTransport().send(_btJob()),
        throwsA(isA<BluetoothPrintException>().having((e) => e.state, 'state', PrinterLinkState.notPaired)),
      );
      _mockClear();
    });

    test('a transport mismatch is refused, not faked', () async {
      _mockClear();
      final job = PrintJob(ticketType: 'BILL', lines: const [], entries: const [], printer: const PrintPrinter(name: 'X'));
      await expectLater(
        BluetoothPrintTransport().send(job),
        throwsA(isA<BluetoothPrintException>().having((e) => e.state, 'state', PrinterLinkState.notPaired)),
      );
    });

    test('testPrint returns a ready link on success and a typed link on failure', () async {
      _mock((call) async {
        if (call.method == 'status') return _ok();
        if (call.method == 'connect') return _ok();
        return _ok('wrote');
      });
      final ok = await BluetoothPrintTransport().testPrint(mac: 'AA:BB');
      expect(ok.state, PrinterLinkState.ready);

      _mock((call) async => {'state': 'bluetooth_off', 'detail': 'off'});
      final fail = await BluetoothPrintTransport().testPrint(mac: 'AA:BB');
      expect(fail.state, PrinterLinkState.bluetoothOff);
      _mockClear();
    });
  });

  group('Bluetooth jobs keep the existing queue + retry semantics', () {
    test('a flaky link is retried up to retryCount by PrintQueue', () async {
      var connects = 0;
      _mock((call) async {
        if (call.method == 'status') return _ok();
        if (call.method == 'connect') {
          connects++;
          if (connects < 3) return {'state': 'offline', 'detail': 'flaky'};
          return _ok();
        }
        return _ok();
      });
      final queue = PrintQueue(transport: BluetoothPrintTransport());
      await queue.submit(_btJob(retryCount: 3));
      expect(connects, 3); // two failures then success
      _mockClear();
    });

    test('exhausting retries throws PrintJobFailed and the chain survives', () async {
      _mock((call) async {
        if (call.method == 'status') return _ok();
        if (call.method == 'connect') return {'state': 'offline', 'detail': 'down'};
        return _ok();
      });
      final queue = PrintQueue(transport: BluetoothPrintTransport());
      await expectLater(queue.submit(_btJob(retryCount: 2)), throwsA(isA<PrintJobFailed>()));
      _mockClear();
    });
  });

  group('PrintDispatcher routes tickets to the Bluetooth printer from config', () {
    Map<String, dynamic> btOutlet() => {
          'printers': [
            {'id': 'bt', 'name': 'BT Receipt', 'transport': 'BLUETOOTH', 'bluetoothMac': 'AA:BB:CC:DD:EE:FF', 'widthMm': 58, 'active': true},
          ],
          'routing': {
            'BILL': [
              {'printerId': 'bt'},
            ],
            'CAPTAIN_ORDER': [
              {'printerId': 'bt'},
            ],
          },
          'itemRoutes': [
            {'itemId': 'item-bev', 'bevPrinterId': 'bt'},
          ],
        };

    test('BILL + captain + bev labels all resolve to the Bluetooth printer', () async {
      final rec = RecordingTransport();
      final d = buildDispatcher(rec, outlet: btOutlet());

      final bill = await d.printBill(
        items: [PrintItem(name: 'Nasi', itemId: 'item-nasi', qty: 1, unitPrice: 45000, batchIndex: 0)],
        receiptId: 'R-1',
        flow: flowOf(),
        split: splitOf(),
      );
      expect(bill.alerts, isEmpty);
      expect(rec.jobs.single.printer.transport, 'BLUETOOTH');
      expect(rec.jobs.single.printer.bluetoothMac, 'AA:BB:CC:DD:EE:FF');
      expect(rec.jobs.single.printer.widthMm, 58);

      rec.jobs.clear();
      final captain = await d.printCaptainOrder(
        items: [PrintItem(name: 'Nasi', itemId: 'item-nasi', qty: 1, unitPrice: 45000, batchIndex: 0)],
      );
      expect(captain.alerts, isEmpty);
      expect(rec.jobs.single.printer.transport, 'BLUETOOTH');

      rec.jobs.clear();
      final bev = await d.printBevLabels(
        items: [PrintItem(name: 'Espresso', itemId: 'item-bev', qty: 1, unitPrice: 25000, batchIndex: 0)],
      );
      expect(bev.alerts, isEmpty);
      expect(rec.jobs.single.printer.transport, 'BLUETOOTH');
    });
  });
}

// Minimal money fixtures for the BILL dispatch (no hand-computed totals).
money.MoneyFlow flowOf() => money.computeMoneyFlow(
      [money.MoneyLine(subtotal: 45000, vatMode: money.VatScMode.exclude, vatRate: 11, scMode: money.VatScMode.none)],
      0,
      0,
      money.RoundingMode.none,
    );

money.SplitResult splitOf() => money.finalizePayments(flowOf().total, [
      money.PaymentInput(outletMethodId: 'pm-cash', type: money.PayType.cash, amount: flowOf().total),
    ]);
