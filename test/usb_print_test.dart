import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gundam_pos/logic/money.dart' as money;
import 'package:gundam_pos/logic/print_payload.dart';
import 'package:gundam_pos/services/escpos.dart';
import 'package:gundam_pos/services/print_broker.dart';
import 'package:gundam_pos/services/print_routing.dart';
import 'package:gundam_pos/services/printer_health.dart';
import 'package:gundam_pos/services/usb_print_transport.dart';
import 'package:gundam_pos/services/usb_printer_channel.dart';

import 'support/print_support.dart';

const _channel = MethodChannel(UsbPrinterChannel.channelName);

void _mock(Future<Object?> Function(MethodCall call) handler) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, handler);
}

void _mockClear() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, null);
}

Map<String, Object?> _ok([String detail = 'ok']) => {'state': 'ready', 'detail': detail};

/// One attached CH340 the Kotlin side would resolve to chip `CH340`.
Map<String, Object?> _ch340({bool granted = true}) => {
      'vid': 0x1A86,
      'pid': 0x7523,
      'name': 'USB Thermal Printer',
      'chip': 'CH340',
      'granted': granted,
    };

PrintJob _usbJob({
  String vidPid = '1A86:7523',
  String? chip = 'CH340',
  int retryCount = 1,
}) =>
    PrintJob(
      ticketType: 'BILL',
      lines: ['HELLO'],
      entries: const [],
      printer: PrintPrinter(
        name: 'USB',
        transport: 'USB',
        usbVidPid: vidPid,
        usbChip: chip,
        retryCount: retryCount,
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('chip selection — the configured usbChip picks the driver', () {
    test('canonicalUsbChip normalises the web value and tolerates aliases', () {
      expect(canonicalUsbChip('ch340'), 'CH340');
      expect(canonicalUsbChip('CH341A'), 'CH340');
      expect(canonicalUsbChip('prolific'), 'PL2303');
      expect(canonicalUsbChip('ft232r'), 'FTDI');
      expect(canonicalUsbChip('cdc-acm'), 'CDC_ACM');
      expect(canonicalUsbChip(''), isNull); // documented fallback
      expect(canonicalUsbChip('AUTO'), isNull);
    });

    test('usbChipForVidPid maps vendor/product ids to a chip', () {
      expect(usbChipForVidPid(0x1A86, 0x7523), 'CH340');
      expect(usbChipForVidPid(0x067B, 0x2303), 'PL2303');
      expect(usbChipForVidPid(0x0403, 0x6001), 'FTDI');
      expect(usbChipForVidPid(0x0403, 0x6015), 'FTDI');
      expect(usbChipForVidPid(0x0483, 0x5740, cdcByClass: true), 'CDC_ACM');
      expect(usbChipForVidPid(0xDEAD, 0xBEEF), isNull);
    });

    test('parseUsbVidPid accepts the config shapes and rejects junk', () {
      expect(parseUsbVidPid('1A86:7523'), (0x1A86, 0x7523));
      expect(parseUsbVidPid('0x1a86:0x7523'), (0x1A86, 0x7523));
      expect(parseUsbVidPid('1a86-7523'), (0x1A86, 0x7523));
      expect(parseUsbVidPid('nope'), isNull);
      expect(parseUsbVidPid(''), isNull);
    });
  });

  group('UsbPrintTransport — the ready path writes ESC/POS bytes', () {
    test('a ready channel writes the encoder output (no reimplementation)', () async {
      final written = <List<int>>[];
      _mock((call) async {
        switch (call.method) {
          case 'status':
            return _ok('1 USB device');
          case 'listDevices':
            return [_ch340()];
          case 'open':
            return _ok('opened');
          case 'write':
            written.add(call.arguments['bytes'] as List<int>);
            return _ok();
        }
        return _ok();
      });

      final job = _usbJob();
      await UsbPrintTransport().send(job);
      expect(written, hasLength(1));
      expect(written.single.sublist(0, 2), [0x1B, 0x40]); // ESC @ from escpos.dart
      // Byte-for-byte identical to the shared encoder — no re-implementation.
      expect(written.single, encodePrintJob(job, widthMm: job.printer.widthMm));
      _mockClear();
    });

    test('open receives the configured chip and baud', () async {
      Map<String, dynamic>? openArgs;
      _mock((call) async {
        switch (call.method) {
          case 'status':
            return _ok();
          case 'listDevices':
            return [_ch340()];
          case 'open':
            openArgs = Map<String, dynamic>.from(call.arguments as Map);
            return _ok();
        }
        return _ok();
      });
      await UsbPrintTransport().send(_usbJob());
      expect(openArgs!['vid'], 0x1A86);
      expect(openArgs!['pid'], 0x7523);
      expect(openArgs!['chip'], 'CH340');
      expect(openArgs!['baud'], 9600);
      _mockClear();
    });
  });

  group('UsbPrintTransport — typed faults, never a silent wrong-chip write', () {
    test('a configured chip that does not match the device → UsbChipMismatchException', () async {
      var wrote = false;
      _mock((call) async {
        switch (call.method) {
          case 'status':
            return _ok();
          case 'listDevices':
            return [_ch340()]; // attached chip is CH340
          case 'write':
            wrote = true;
            return _ok();
        }
        return _ok();
      });
      await expectLater(
        UsbPrintTransport().send(_usbJob(chip: 'FTDI')), // config says FTDI
        throwsA(isA<UsbChipMismatchException>()
            .having((e) => e.state, 'state', PrinterLinkState.unsupported)
            .having((e) => e.configuredChip, 'configured', 'FTDI')
            .having((e) => e.attached, 'attached', 'CH340')),
      );
      expect(wrote, isFalse); // the mismatch never reached the wire
      _mockClear();
    });

    test('a configured VID:PID that is not attached → UsbChipMismatchException, no crash', () async {
      _mock((call) async {
        if (call.method == 'status') return _ok();
        if (call.method == 'listDevices') return [_ch340()];
        return _ok();
      });
      await expectLater(
        UsbPrintTransport().send(_usbJob(vidPid: '0403:6001', chip: 'FTDI')),
        throwsA(isA<UsbChipMismatchException>()
            .having((e) => e.state, 'state', PrinterLinkState.unsupported)),
      );
      _mockClear();
    });

    test('a missing USB permission → Permission required and no crash', () async {
      _mock((call) async {
        if (call.method == 'status') return _ok();
        if (call.method == 'listDevices') return [_ch340(granted: false)];
        return _ok();
      });
      await expectLater(
        UsbPrintTransport().send(_usbJob()),
        throwsA(isA<UsbPrintException>()
            .having((e) => e.state, 'state', PrinterLinkState.permissionRequired)),
      );
      _mockClear();
    });

    test('no device attached → Offline (device absent), never a wrong write', () async {
      _mock((call) async {
        if (call.method == 'status') return {'state': 'offline', 'detail': 'No USB device attached.'};
        return _ok();
      });
      await expectLater(
        UsbPrintTransport().send(_usbJob()),
        throwsA(isA<UsbPrintException>().having((e) => e.state, 'state', PrinterLinkState.offline)),
      );
      _mockClear();
    });

    test('USB host unavailable (non-Android) → Unsupported, no crash', () async {
      _mockClear();
      await expectLater(
        UsbPrintTransport().send(_usbJob()),
        throwsA(isA<UsbPrintException>().having((e) => e.state, 'state', PrinterLinkState.unsupported)),
      );
    });

    test('a non-USB job is refused, not faked', () async {
      _mockClear();
      final job = PrintJob(ticketType: 'BILL', lines: const [], entries: const [], printer: const PrintPrinter(name: 'X'));
      await expectLater(
        UsbPrintTransport().send(job),
        throwsA(isA<UsbPrintException>().having((e) => e.state, 'state', PrinterLinkState.unsupported)),
      );
    });

    test('a chip reported by the device but absent from config falls back to the device chip', () async {
      Map<String, dynamic>? openArgs;
      _mock((call) async {
        switch (call.method) {
          case 'status':
            return _ok();
          case 'listDevices':
            return [_ch340()];
          case 'open':
            openArgs = Map<String, dynamic>.from(call.arguments as Map);
            return _ok();
        }
        return _ok();
      });
      await UsbPrintTransport().send(_usbJob(chip: null)); // no usbChip in config
      expect(openArgs!['chip'], 'CH340'); // derived from the attached device
      _mockClear();
    });
  });

  group('UsbPrintTransport — manual test print and permission', () {
    test('testPrint returns a ready link on success and a typed link on failure', () async {
      _mock((call) async {
        switch (call.method) {
          case 'status':
            return _ok();
          case 'listDevices':
            return [_ch340()];
        }
        return _ok();
      });
      final ok = await UsbPrintTransport().testPrint(vidPid: '1A86:7523', chip: 'CH340');
      expect(ok.state, PrinterLinkState.ready);

      _mock((call) async {
        if (call.method == 'status') return _ok();
        if (call.method == 'listDevices') return [_ch340()];
        if (call.method == 'open') return {'state': 'offline', 'detail': 'claim failed'};
        return _ok();
      });
      final fail = await UsbPrintTransport().testPrint(vidPid: '1A86:7523', chip: 'CH340');
      expect(fail.state, PrinterLinkState.offline); // interface claim failure
      _mockClear();
    });

    test('testPrint prompts for permission then retries once granted', () async {
      var requests = 0;
      var granted = false;
      _mock((call) async {
        switch (call.method) {
          case 'status':
            return _ok();
          case 'listDevices':
            return [_ch340(granted: granted)];
          case 'requestPermission':
            requests++;
            granted = true;
            return true;
          case 'hasPermission':
            return granted;
        }
        return _ok();
      });
      final link = await UsbPrintTransport().testPrint(vidPid: '1A86:7523', chip: 'CH340');
      expect(requests, 1);
      expect(link.state, PrinterLinkState.ready);
      _mockClear();
    });
  });

  group('UsbPrintTransport maps every channel error to the right PrinterLinkState', () {
    test('open/write status codes map like Bluetooth', () async {
      for (final entry in {
        'offline': PrinterLinkState.offline,
        'disconnected': PrinterLinkState.disconnected,
        'permission_required': PrinterLinkState.permissionRequired,
        'unsupported': PrinterLinkState.unsupported,
      }.entries) {
        _mock((call) async {
          switch (call.method) {
            case 'status':
              return _ok();
            case 'listDevices':
              return [_ch340()];
            case 'open':
              return _ok();
            case 'write':
              return {'state': entry.key, 'detail': 'x'};
          }
          return _ok();
        });
        await expectLater(
          UsbPrintTransport().send(_usbJob()),
          throwsA(isA<UsbPrintException>().having((e) => e.state, 'state', entry.value)),
          reason: 'write code ${entry.key}',
        );
      }
      _mockClear();
    });
  });

  group('USB jobs keep the existing queue + retry semantics', () {
    test('a flaky open is retried up to retryCount by PrintQueue', () async {
      var opens = 0;
      _mock((call) async {
        switch (call.method) {
          case 'status':
            return _ok();
          case 'listDevices':
            return [_ch340()];
          case 'open':
            opens++;
            if (opens < 3) return {'state': 'offline', 'detail': 'flaky'};
            return _ok();
        }
        return _ok();
      });
      final queue = PrintQueue(transport: UsbPrintTransport());
      await queue.submit(_usbJob(retryCount: 3));
      expect(opens, 3); // two failures then success
      _mockClear();
    });

    test('exhausting retries throws PrintJobFailed and the chain survives', () async {
      _mock((call) async {
        switch (call.method) {
          case 'status':
            return _ok();
          case 'listDevices':
            return [_ch340()];
          case 'open':
            return {'state': 'offline', 'detail': 'down'};
        }
        return _ok();
      });
      final queue = PrintQueue(transport: UsbPrintTransport());
      await expectLater(queue.submit(_usbJob(retryCount: 2)), throwsA(isA<PrintJobFailed>()));
      _mockClear();
    });
  });

  group('PrinterHealthChecker — USB probe (PRD §4.28 statuses)', () {
    test('ready device → Ready', () async {
      _mock((call) async {
        switch (call.method) {
          case 'status':
            return _ok();
          case 'listDevices':
            return [_ch340()];
        }
        return _ok();
      });
      final link = await PrinterHealthChecker().check(transport: 'USB', usbVidPid: '1A86:7523', usbChip: 'CH340');
      expect(link.state, PrinterLinkState.ready);
      expect(link.detail, contains('Unknown')); // no real-time device status → not Healthy
      _mockClear();
    });

    test('device absent → Offline', () async {
      _mock((call) async {
        if (call.method == 'status') return _ok();
        if (call.method == 'listDevices') return [_ch340()];
        return _ok();
      });
      final link = await PrinterHealthChecker().check(transport: 'USB', usbVidPid: '0403:6001', usbChip: 'FTDI');
      expect(link.state, PrinterLinkState.offline);
      _mockClear();
    });

    test('missing permission → Permission required', () async {
      _mock((call) async {
        if (call.method == 'status') return _ok();
        if (call.method == 'listDevices') return [_ch340(granted: false)];
        return _ok();
      });
      final link = await PrinterHealthChecker().check(transport: 'USB', usbVidPid: '1A86:7523', usbChip: 'CH340');
      expect(link.state, PrinterLinkState.permissionRequired);
      _mockClear();
    });

    test('chip mismatch → Unsupported', () async {
      _mock((call) async {
        if (call.method == 'status') return _ok();
        if (call.method == 'listDevices') return [_ch340()];
        return _ok();
      });
      final link = await PrinterHealthChecker().check(transport: 'USB', usbVidPid: '1A86:7523', usbChip: 'PL2303');
      expect(link.state, PrinterLinkState.unsupported);
      _mockClear();
    });

    test('interface claim failure → Offline', () async {
      _mock((call) async {
        switch (call.method) {
          case 'status':
            return _ok();
          case 'listDevices':
            return [_ch340()];
          case 'open':
            return {'state': 'offline', 'detail': 'claim failed'};
        }
        return _ok();
      });
      final link = await PrinterHealthChecker().check(transport: 'USB', usbVidPid: '1A86:7523', usbChip: 'CH340');
      expect(link.state, PrinterLinkState.offline);
      _mockClear();
    });

    test('no USB host → Unsupported', () async {
      _mock((call) async => {'state': 'unsupported', 'detail': 'no usb host'});
      final link = await PrinterHealthChecker().check(transport: 'USB', usbVidPid: '1A86:7523');
      expect(link.state, PrinterLinkState.unsupported);
      _mockClear();
    });

    test('a printer with no USB addressing at all is Offline before any channel call', () async {
      _mockClear();
      final link = await PrinterHealthChecker().check(transport: 'USB', usbVidPid: null, usbChip: null);
      expect(link.state, PrinterLinkState.offline);
    });

    test('health status vocabulary matches the server (no invented values)', () async {
      expect(printerHealthStatusName(PrinterLinkState.ready), 'Ready');
      expect(printerHealthStatusName(PrinterLinkState.permissionRequired), 'Permission required');
      expect(printerHealthStatusName(PrinterLinkState.unsupported), 'Unsupported');
      expect(printerHealthStatusName(PrinterLinkState.offline), 'Offline');
      expect(printerHealthStatusName(PrinterLinkState.disconnected), 'Disconnected');
    });
  });

  group('PrintDispatcher routes tickets to the USB printer resolved from config', () {
    Map<String, dynamic> usbOutlet() => {
          'printers': [
            {
              'id': 'usb',
              'name': 'USB Receipt',
              'transport': 'USB',
              'usbVidPid': '1A86:7523',
              'usbChip': 'CH340',
              'widthMm': 58,
              'active': true,
            },
          ],
          'routing': {
            'BILL': [
              {'printerId': 'usb'},
            ],
            'CAPTAIN_ORDER': [
              {'printerId': 'usb'},
            ],
          },
          'itemRoutes': [
            {'itemId': 'item-bev', 'bevPrinterId': 'usb'},
          ],
        };

    test('the USB transport is supported and carries vid:pid + chip through to PrintPrinter', () {
      final routing = PrinterRouting.parse(usbOutlet());
      final p = routing.printerById('usb')!;
      expect(p.supported, isTrue);
      expect(routing.unsupportedPrinters, isEmpty);
      final pp = p.toPrintPrinter();
      expect(pp.usbVidPid, '1A86:7523');
      expect(pp.usbChip, 'CH340');
      expect(pp.widthMm, 58);
    });

    test('BILL + captain + bev labels all resolve to the USB printer', () async {
      final rec = RecordingTransport();
      final d = buildDispatcher(rec, outlet: usbOutlet());

      final bill = await d.printBill(
        items: [PrintItem(name: 'Nasi', itemId: 'item-nasi', qty: 1, unitPrice: 45000, batchIndex: 0)],
        receiptId: 'R-1',
        flow: flowOf(),
        split: splitOf(),
      );
      expect(bill.alerts, isEmpty);
      expect(rec.jobs.single.printer.transport, 'USB');
      expect(rec.jobs.single.printer.usbVidPid, '1A86:7523');
      expect(rec.jobs.single.printer.usbChip, 'CH340');
      expect(rec.jobs.single.printer.widthMm, 58);

      rec.jobs.clear();
      final captain = await d.printCaptainOrder(
        items: [PrintItem(name: 'Nasi', itemId: 'item-nasi', qty: 1, unitPrice: 45000, batchIndex: 0)],
      );
      expect(captain.alerts, isEmpty);
      expect(rec.jobs.single.printer.transport, 'USB');

      rec.jobs.clear();
      final bev = await d.printBevLabels(
        items: [PrintItem(name: 'Espresso', itemId: 'item-bev', qty: 1, unitPrice: 25000, batchIndex: 0)],
      );
      expect(bev.alerts, isEmpty);
      expect(rec.jobs.single.printer.transport, 'USB');
    });

    test('a USB printer with no chip passes null (tolerant parse, documented fallback)', () {
      final routing = PrinterRouting.parse({
        'printers': [
          {'id': 'usb', 'name': 'Old USB', 'transport': 'USB', 'usbVidPid': '1A86:7523', 'active': true},
        ],
      });
      final p = routing.printerById('usb')!;
      expect(p.usbChip, isNull);
      expect(p.toPrintPrinter().usbChip, isNull);
    });
  });

  // -------------------------------------------------------------------------
  // Widened coverage: CP210x + printers that need no serial bridge at all.
  // The Kotlin driver tables/init sequences are pure data verified by
  // inspection; these tests exercise the Dart-side selection, vocabulary and
  // typed-error plumbing that decides WHICH driver is handed to the channel.
  // -------------------------------------------------------------------------
  group('widened USB coverage — vocabulary (web codes → canonical ids)', () {
    test('canonicalUsbChip accepts the web vocabulary codes', () {
      expect(canonicalUsbChip('CH340_CH341'), 'CH340');
      expect(canonicalUsbChip('FTDI_FT232R'), 'FTDI');
      expect(canonicalUsbChip('FTDI_FT231X'), 'FTDI');
      expect(canonicalUsbChip('CP210X'), 'CP210X');
      expect(canonicalUsbChip('cp2102'), 'CP210X');
      expect(canonicalUsbChip('silabs'), 'CP210X');
      expect(canonicalUsbChip('USB_PRINTER_CLASS'), 'USB_PRINTER_CLASS');
      expect(canonicalUsbChip('usb-vendor-specific'), 'USB_VENDOR_SPECIFIC');
      expect(canonicalUsbChip('printer'), 'USB_PRINTER_CLASS');
      expect(canonicalUsbChip('bogus'), 'BOGUS'); // kept so it can be reported
    });

    test('usbChipForVidPid maps the CP210x ids and leaves unknown ids alone', () {
      expect(usbChipForVidPid(0x10C4, 0xEA60), 'CP210X');
      expect(usbChipForVidPid(0x10C4, 0xEAB0), 'CP210X');
      expect(usbChipForVidPid(0x10C4, 0xEA70), 'CP210X');
      expect(usbChipForVidPid(0x10C4, 0x9999), isNull);
    });

    test('EVERY chip code the web vocabulary ships maps to a driver that exists', () {
      // The web list is the contract; each code must canonicalise onto one of the
      // driver ids the APK really carries (`UsbSerialDrivers.all` in the Kotlin),
      // so the channel is never handed a driver id that does not exist.
      expect(kUsbChipWebCodes.toSet(), {
        'CDC_ACM',
        'CH340_CH341',
        'PL2303',
        'FTDI_FT232R',
        'FTDI_FT231X',
        'CP210X',
        'USB_PRINTER_CLASS',
        'USB_VENDOR_SPECIFIC',
      });
      for (final web in kUsbChipWebCodes) {
        final canonical = canonicalUsbChip(web);
        expect(canonical, isNotNull, reason: web);
        expect(kUsbDriverIds, contains(canonical), reason: '$web → $canonical has no driver');
        // The canonical id is itself accepted round-trip (configs written by
        // either version of the web app behave the same).
        expect(canonicalUsbChip(canonical), canonical, reason: canonical!);
      }
      // A value with no driver is kept verbatim so it is reported, never guessed
      // — the transport then refuses it with a typed error.
      expect(kUsbDriverIds, isNot(contains(canonicalUsbChip('BOGUS'))));
    });
  });

  group('widened USB coverage — transport selects the new chips and reports typed faults', () {
    Map<String, Object?> cp210x({bool granted = true}) => {
          'vid': 0x10C4,
          'pid': 0xEA60,
          'name': 'CP2102 Printer',
          'chip': 'CP210X',
          'granted': granted,
        };

    Map<String, Object?> printerClass({String chip = 'USB_PRINTER_CLASS', bool granted = true}) => {
          'vid': 0x0483,
          'pid': 0x5740,
          'name': 'USB Printer',
          'chip': chip,
          'granted': granted,
        };

    test('a CP210X device is selected and the open carries CP210X', () async {
      Map<String, dynamic>? openArgs;
      var wrote = false;
      _mock((call) async {
        switch (call.method) {
          case 'status':
            return _ok();
          case 'listDevices':
            return [cp210x()];
          case 'open':
            openArgs = Map<String, dynamic>.from(call.arguments as Map);
            return _ok('opened');
          case 'write':
            wrote = true;
            return _ok();
        }
        return _ok();
      });
      await UsbPrintTransport().send(_usbJob(vidPid: '10C4:EA60', chip: 'CP210X'));
      expect(openArgs!['chip'], 'CP210X');
      expect(openArgs!['vid'], 0x10C4);
      expect(openArgs!['pid'], 0xEA60);
      expect(wrote, isTrue);
      _mockClear();
    });

    test('no chip configured → derives USB_PRINTER_CLASS from the device report', () async {
      Map<String, dynamic>? openArgs;
      _mock((call) async {
        switch (call.method) {
          case 'status':
            return _ok();
          case 'listDevices':
            return [printerClass()];
          case 'open':
            openArgs = Map<String, dynamic>.from(call.arguments as Map);
            return _ok('opened');
        }
        return _ok();
      });
      await UsbPrintTransport().send(_usbJob(vidPid: '0483:5740', chip: null));
      expect(openArgs!['chip'], 'USB_PRINTER_CLASS');
      _mockClear();
    });

    test('no chip configured → derives USB_VENDOR_SPECIFIC from the device report', () async {
      Map<String, dynamic>? openArgs;
      _mock((call) async {
        switch (call.method) {
          case 'status':
            return _ok();
          case 'listDevices':
            return [printerClass(chip: 'USB_VENDOR_SPECIFIC')];
          case 'open':
            openArgs = Map<String, dynamic>.from(call.arguments as Map);
            return _ok('opened');
        }
        return _ok();
      });
      await UsbPrintTransport().send(_usbJob(vidPid: '0483:5740', chip: null));
      expect(openArgs!['chip'], 'USB_VENDOR_SPECIFIC');
      _mockClear();
    });

    test('a configured class chip against a serial device → UsbChipMismatchException, no write', () async {
      var wrote = false;
      _mock((call) async {
        switch (call.method) {
          case 'status':
            return _ok();
          case 'listDevices':
            return [_ch340()]; // attached is a CH340 serial bridge
          case 'write':
            wrote = true;
            return _ok();
        }
        return _ok();
      });
      await expectLater(
        UsbPrintTransport().send(_usbJob(chip: 'USB_VENDOR_SPECIFIC')),
        throwsA(isA<UsbChipMismatchException>()
            .having((e) => e.state, 'state', PrinterLinkState.unsupported)
            .having((e) => e.configuredChip, 'configured', 'USB_VENDOR_SPECIFIC')
            .having((e) => e.attached, 'attached', 'CH340')),
      );
      expect(wrote, isFalse);
      _mockClear();
    });

    test('an unknown chip code → typed Unsupported, never a silent write', () async {
      var wrote = false;
      _mock((call) async {
        switch (call.method) {
          case 'status':
            return _ok();
          case 'listDevices':
            return [
              {'vid': 0x1A86, 'pid': 0x7523, 'name': 'X', 'chip': 'BOGUS', 'granted': true},
            ];
          case 'open':
            return {'state': 'unsupported', 'detail': "Unsupported USB chip 'BOGUS'."};
          case 'write':
            wrote = true;
            return _ok();
        }
        return _ok();
      });
      await expectLater(
        UsbPrintTransport().send(_usbJob(chip: 'BOGUS')),
        throwsA(isA<UsbPrintException>().having((e) => e.state, 'state', PrinterLinkState.unsupported)),
      );
      expect(wrote, isFalse);
      _mockClear();
    });

    test('a device with no bulk OUT endpoint → Offline, no write', () async {
      var wrote = false;
      _mock((call) async {
        switch (call.method) {
          case 'status':
            return _ok();
          case 'listDevices':
            return [printerClass()];
          case 'open':
            return {'state': 'offline', 'detail': 'No bulk OUT endpoint on the USB printer interface.'};
          case 'write':
            wrote = true;
            return _ok();
        }
        return _ok();
      });
      await expectLater(
        UsbPrintTransport().send(_usbJob(vidPid: '0483:5740', chip: 'USB_PRINTER_CLASS')),
        throwsA(isA<UsbPrintException>().having((e) => e.state, 'state', PrinterLinkState.offline)),
      );
      expect(wrote, isFalse);
      _mockClear();
    });

    test('a BILL job still routes through PrintQueue to the USB printer resolved from config', () async {
      final written = <List<int>>[];
      _mock((call) async {
        switch (call.method) {
          case 'status':
            return _ok();
          case 'listDevices':
            return [cp210x()];
          case 'open':
            return _ok('opened');
          case 'write':
            written.add(call.arguments['bytes'] as List<int>);
            return _ok();
        }
        return _ok();
      });
      final queue = PrintQueue(transport: UsbPrintTransport());
      await queue.submit(_usbJob(vidPid: '10C4:EA60', chip: 'CP210X'));
      expect(written, hasLength(1));
      expect(written.single.sublist(0, 2), [0x1B, 0x40]); // ESC @
      _mockClear();
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
