import 'package:flutter_test/flutter_test.dart';
import 'package:gundam_pos/services/escpos.dart';
import 'package:gundam_pos/services/print_routing.dart';

import 'support/fake_backend.dart';

void main() {
  group('PrinterRouting.parse — tolerant config parsing', () {
    test('parses printers, routing and itemRoutes from the OUTLET payload', () {
      final r = PrinterRouting.parse(FakeBackend.northstarPrintModel());
      expect(r.printers, hasLength(4));
      final front = r.printerById('pr-front')!;
      expect(front.transport, 'NETWORK');
      expect(front.ip, '10.0.0.9');
      expect(front.port, 9100);
      expect(front.widthMm, 80);
      expect(front.shared, isTrue);
      expect(front.retryCount, 3);
      expect(r.itemRoutes['item-espresso']!.captainPrinterId, 'pr-captain');
      expect(r.itemRoutes['item-espresso']!.bevPrinterId, 'pr-bev');
    });

    test('missing keys → empty, never throws', () {
      final r = PrinterRouting.parse({'paymentMethods': []});
      expect(r.printers, isEmpty);
      expect(r.routing, isEmpty);
      expect(r.itemRoutes, isEmpty);
      expect(r.billPrinters(), isEmpty);
    });

    test('non-map / garbage payload → empty, never throws', () {
      expect(PrinterRouting.parse(null).printers, isEmpty);
      expect(PrinterRouting.parse('not a map {{{').printers, isEmpty);
      expect(PrinterRouting.parse(42).printers, isEmpty);
    });

    test('unknown transport → the printer is skipped', () {
      final r = PrinterRouting.parse({
        'printers': [
          {'id': 'p1', 'name': 'X', 'transport': 'CARRIER_PIGEON'},
          {'id': 'p2', 'name': 'OK', 'transport': 'NETWORK', 'ip': '10.0.0.1'},
        ],
      });
      expect(r.printers.map((p) => p.id), ['p2']);
    });

    test('a printer with no id is skipped; malformed rows are dropped', () {
      final r = PrinterRouting.parse({
        'printers': [
          {'name': 'no id'},
          'not a map',
        ],
        'itemRoutes': ['bad', {'itemId': ''}],
      });
      expect(r.printers, isEmpty);
      expect(r.itemRoutes, isEmpty);
    });
  });

  group('PrinterRouting — ticket-to-printer resolution', () {
    late PrinterRouting r;
    setUp(() => r = PrinterRouting.parse(FakeBackend.northstarPrintModel()));

    test('BILL resolves to every outlet-level printer (multi-printer)', () {
      final r2 = PrinterRouting.parse({
        'printers': [
          {'id': 'a', 'name': 'A', 'transport': 'NETWORK', 'ip': '1.1.1.1'},
          {'id': 'b', 'name': 'B', 'transport': 'NETWORK', 'ip': '1.1.1.2'},
        ],
        'routing': {
          'BILL': [
            {'printerId': 'a'},
            {'printerId': 'b'},
          ],
        },
      });
      expect(r2.billPrinters().map((p) => p.id), ['a', 'b']);
    });

    test('captain order is strict item-level (itemRoutes, no category fallback)', () {
      expect(r.captainPrinterForItem('item-espresso')!.id, 'pr-captain');
      expect(r.captainPrinterForItem('item-nasi')!.id, 'pr-captain');
      // an unassigned item yields nothing — never the item's category
      expect(r.captainPrinterForItem('item-unknown'), isNull);
    });

    test('captain batchStep is honoured on the outlet routing', () {
      final r2 = PrinterRouting.parse({
        'printers': [
          {'id': 'p0', 'name': 'P0', 'transport': 'NETWORK', 'ip': '1.1.1.1'},
          {'id': 'p1', 'name': 'P1', 'transport': 'NETWORK', 'ip': '1.1.1.2'},
          {'id': 'pdef', 'name': 'Def', 'transport': 'NETWORK', 'ip': '1.1.1.3'},
        ],
        'routing': {
          'CAPTAIN_ORDER': [
            {'printerId': 'p0', 'batchStep': 0},
            {'printerId': 'p1', 'batchStep': 1},
            {'printerId': 'pdef', 'batchStep': null},
          ],
        },
      });
      expect(r2.captainPrintersForStep(0).map((p) => p.id), ['p0']);
      expect(r2.captainPrintersForStep(1).map((p) => p.id), ['p1']);
      // no exact step → the step-less default
      expect(r2.captainPrintersForStep(7).map((p) => p.id), ['pdef']);
    });

    test('bev label is strict item-level', () {
      expect(r.bevPrinterForItem('item-espresso')!.id, 'pr-bev');
      expect(r.bevPrinterForItem('item-nasi'), isNull);
    });

    test('an inactive printer does not resolve', () {
      final r2 = PrinterRouting.parse({
        'printers': [
          {'id': 'a', 'name': 'A', 'transport': 'NETWORK', 'ip': '1.1.1.1', 'active': false},
        ],
        'routing': {
          'BILL': [
            {'printerId': 'a'},
          ],
        },
      });
      expect(r2.billPrinters(), isEmpty);
    });

    test('BLUETOOTH is supported on this build; USB is reported, not dropped', () {
      final unsupported = r.unsupportedPrinters;
      expect(r.printerById('pr-bt')!.supported, isTrue); // Bluetooth SPP is wired
      expect(r.printerById('pr-front')!.supported, isTrue);
      expect(unsupported, isEmpty); // the northstar model has no USB printer

      final withUsb = PrinterRouting.parse({
        'printers': [
          {'id': 'usb', 'name': 'USB', 'transport': 'USB', 'usbVidPid': '04b8:0e15'},
        ],
      });
      expect(withUsb.unsupportedPrinters.single.id, 'usb');
      expect(withUsb.printerById('usb')!.supported, isFalse);
    });
  });

  group('printer-model metadata — optional + tolerant', () {
    test('flat model metadata is consumed; dialect + effective raster resolve', () {
      final r = PrinterRouting.parse({
        'printers': [
          {
            'id': 'p', 'name': 'P', 'transport': 'NETWORK', 'ip': '1.1.1.1', 'widthMm': 58,
            'supportsRasterImage': false, 'modelId': 'm1', 'brand': 'Epson', 'model': 'TM-T82',
            'protocol': 'ESC/POS', 'modelSupportsRasterImage': true,
          },
        ],
      });
      final p = r.printerById('p')!;
      expect(p.modelId, 'm1');
      expect(p.brand, 'Epson');
      expect(p.model, 'TM-T82');
      expect(p.dialect, kDefaultEscPosDialect);
      expect(p.dialectRecognized, isTrue);
      expect(p.effectiveRasterSupport, isTrue); // printer false OR model true
      expect(p.toPrintPrinter().supportsRasterImage, isTrue);
      expect(p.toPrintPrinter().dialect, kDefaultEscPosDialect);
    });

    test('nested printerModel metadata is honoured', () {
      final r = PrinterRouting.parse({
        'printers': [
          {
            'id': 'p', 'name': 'P', 'transport': 'NETWORK', 'ip': '1.1.1.1',
            'printerModel': {'id': 'm2', 'brand': 'Star', 'name': 'TSP100', 'protocol': 'ESC/POS', 'supportsRasterImage': true},
          },
        ],
      });
      final p = r.printerById('p')!;
      expect(p.modelId, 'm2');
      expect(p.brand, 'Star');
      expect(p.model, 'TSP100');
      expect(p.effectiveRasterSupport, isTrue);
    });

    test('absent metadata → previous behaviour: default dialect, own raster flag', () {
      final p = PrinterRouting.parse({
        'printers': [
          {'id': 'p', 'name': 'P', 'transport': 'NETWORK', 'ip': '1.1.1.1', 'supportsRasterImage': true},
        ],
      }).printerById('p')!;
      expect(p.protocol, isNull);
      expect(p.dialect, kDefaultEscPosDialect);
      expect(p.dialectRecognized, isTrue);
      expect(p.effectiveRasterSupport, isTrue);
      expect(p.model, isNull);
    });

    test('an unknown dialect is kept (canonicalised) so it can be reported', () {
      final p = PrinterRouting.parse({
        'printers': [
          {'id': 'p', 'name': 'P', 'transport': 'NETWORK', 'ip': '1.1.1.1', 'protocol': 'ZPL'},
        ],
      }).printerById('p')!;
      expect(p.dialect, 'ZPL');
      expect(p.dialectRecognized, isFalse);
    });

    test('a malformed metadata value never throws (tolerant parse)', () {
      final r = PrinterRouting.parse({
        'printers': [
          {'id': 'p', 'name': 'P', 'transport': 'NETWORK', 'ip': '1.1.1.1', 'modelId': 42, 'protocol': 7},
        ],
      });
      expect(r.printers, hasLength(1));
      expect(r.printerById('p')!.dialect, '7');
    });
  });
}
