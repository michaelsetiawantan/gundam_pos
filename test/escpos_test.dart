import 'package:flutter_test/flutter_test.dart';
import 'package:gundam_pos/logic/print_format_render.dart';
import 'package:gundam_pos/services/escpos.dart';
import 'package:gundam_pos/services/print_broker.dart';

PrintJob _job(
  List<String> lines, {
  List<PrintableEntry> entries = const [],
  int widthMm = 80,
  String transport = 'BLUETOOTH',
  String? mac = 'AA:BB:CC:DD:EE:FF',
  String dialect = kDefaultEscPosDialect,
  bool supportsRasterImage = false,
}) =>
    PrintJob(
      ticketType: 'BILL',
      lines: lines,
      entries: entries,
      printer: PrintPrinter(
        name: 'BT',
        transport: transport,
        bluetoothMac: mac,
        widthMm: widthMm,
        dialect: dialect,
        supportsRasterImage: supportsRasterImage,
      ),
    );

/// Locate a byte sub-sequence; returns its start index or -1.
int _indexOf(List<int> haystack, List<int> needle) {
  outer:
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) continue outer;
    }
    return i;
  }
  return -1;
}

void main() {
  group('EscPosEncoder — raw command sequences', () {
    test('init / code page / align / bold / size / feed / cut', () {
      final bytes = (EscPosEncoder()
            ..init()
            ..codePage(0)
            ..align(1)
            ..bold(true)
            ..doubleSize()
            ..line('AB')
            ..normalSize()
            ..bold(false)
            ..feed(3)
            ..cut())
          .bytes;

      expect(bytes.sublist(0, 2), [0x1B, 0x40]); // ESC @
      expect(_indexOf(bytes, [0x1B, 0x74, 0x00]), greaterThanOrEqualTo(0)); // ESC t 0
      expect(_indexOf(bytes, [0x1B, 0x61, 0x01]), greaterThanOrEqualTo(0)); // ESC a 1 (centre)
      expect(_indexOf(bytes, [0x1B, 0x45, 0x01]), greaterThanOrEqualTo(0)); // ESC E 1 (bold on)
      expect(_indexOf(bytes, [0x1D, 0x21, 0x11]), greaterThanOrEqualTo(0)); // GS ! 0x11 (double w+h)
      expect(_indexOf(bytes, [0x1B, 0x45, 0x00]), greaterThanOrEqualTo(0)); // bold off
      expect(_indexOf(bytes, [0x1D, 0x21, 0x00]), greaterThanOrEqualTo(0)); // normal size
    });

    test('a text line is the Latin-1 bytes followed by LF', () {
      final bytes = (EscPosEncoder()..line('Hi')).bytes;
      expect(bytes, [0x48, 0x69, 0x0A]);
    });

    test('non-Latin-1 runes degrade to "?" instead of throwing', () {
      final bytes = (EscPosEncoder()..line('café ☕')).bytes;
      expect(bytes, [0x63, 0x61, 0x66, 0xE9, 0x20, 0x3F, 0x0A]);
    });

    test('feed and cut emit ESC d n and GS V m', () {
      final feed = (EscPosEncoder()..feed(4)).bytes;
      expect(feed, [0x1B, 0x64, 0x04]);
      expect((EscPosEncoder()..cut()).bytes, [0x1D, 0x56, 0x00]);
      expect((EscPosEncoder()..cut(partial: true)).bytes, [0x1D, 0x56, 0x01]);
    });
  });

  group('encodePrintJob — a rendered ticket', () {
    test('starts with init + code page, then the text line, then feed + cut', () {
      final bytes = encodePrintJob(_job(['HELLO']));
      expect(bytes.sublist(0, 8),
          [0x1B, 0x40, 0x1B, 0x74, 0x00, 0x1B, 0x61, 0x00]); // init, codepage, align left
      expect(_indexOf(bytes, [0x48, 0x45, 0x4C, 0x4C, 0x4F, 0x0A]), greaterThanOrEqualTo(0));
      expect(bytes.sublist(bytes.length - 6), [0x1B, 0x64, 0x03, 0x1D, 0x56, 0x00]);
    });

    test('a QR entry emits real ESC/POS QR bytes (GS ( k)', () {
      final bytes = encodePrintJob(_job(
        ['RECEIPT'],
        entries: [PrintableEntry(kind: PrintableKind.qr, atLine: 0, content: 'NSTAR-1', sizeMm: 20)],
      ));
      // model-2 select: GS ( k 04 00 31 41 32 00
      expect(_indexOf(bytes, [0x1D, 0x28, 0x6B, 0x04, 0x00, 0x31, 0x41, 50, 0]), greaterThanOrEqualTo(0));
      // print command: GS ( k 03 00 31 51 30
      expect(_indexOf(bytes, [0x1D, 0x28, 0x6B, 0x03, 0x00, 0x31, 0x51, 0x30]), greaterThanOrEqualTo(0));
      // the payload is stored
      expect(_indexOf(bytes, 'NSTAR-1'.codeUnits), greaterThanOrEqualTo(0));
    });

    test('a CODE128 barcode emits GS k 73 n data', () {
      final bytes = encodePrintJob(_job(
        ['X'],
        entries: [PrintableEntry(kind: PrintableKind.barcode, atLine: 0, content: '12345', symbology: 'CODE128')],
      ));
      expect(_indexOf(bytes, [0x1D, 0x6B, 73, 5, 0x31, 0x32, 0x33, 0x34, 0x35]), greaterThanOrEqualTo(0));
    });

    test('an IMAGE entry is a labelled placeholder when raster is supported', () {
      final bytes = encodePrintJob(_job(
        ['X'],
        entries: [PrintableEntry(kind: PrintableKind.image, atLine: 0, content: 'logo', assetKey: 'logo')],
        supportsRasterImage: true,
      ));
      expect(_indexOf(bytes, '[IMAGE logo]'.codeUnits), greaterThanOrEqualTo(0));
    });

    test('an IMAGE entry is skipped + counted when the printer has no raster support', () {
      final result = encodePrintJobDetailed(_job(
        ['X'],
        entries: [PrintableEntry(kind: PrintableKind.image, atLine: 0, content: 'logo', assetKey: 'logo')],
      ));
      expect(result.skippedImages, 1);
      expect(_indexOf(result.bytes, '[IMAGE logo skipped: no raster support]'.codeUnits), greaterThanOrEqualTo(0));
    });

    test('entries are interleaved at their atLine offset', () {
      final bytes = encodePrintJob(_job(
        ['ONE', 'TWO'],
        entries: [PrintableEntry(kind: PrintableKind.barcode, atLine: 1, content: 'Z')],
      ));
      final one = _indexOf(bytes, 'ONE'.codeUnits);
      final bar = _indexOf(bytes, [0x1D, 0x6B]);
      final two = _indexOf(bytes, 'TWO'.codeUnits);
      expect(one, greaterThanOrEqualTo(0));
      expect(bar, greaterThan(one)); // after line 0
      expect(two, greaterThan(bar)); // line 1 follows its entry
    });

    test('width comes from the printer config (58 mm vs 80 mm)', () {
      expect(cellsForEncoderWidth(58), 32);
      expect(cellsForEncoderWidth(80), 48);
      expect(EscPosEncoder(widthMm: 58).widthMm, 58);
    });
  });

  group('ESC/POS dialect selection (printer-model protocol)', () {
    test('dialect absent → the documented default ESC/POS', () {
      final r = encodePrintJobDetailed(_job(['X'], dialect: ''));
      expect(r.dialect, kDefaultEscPosDialect);
      expect(r.dialectKnown, isTrue);
      expect(r.bytes.sublist(0, 2), [0x1B, 0x40]); // encoded with the default
    });

    test('dialect present (ESC/POS) → selected', () {
      final r = encodePrintJobDetailed(_job(['X'], dialect: 'ESC/POS'));
      expect(r.dialect, 'ESC/POS');
      expect(r.dialectKnown, isTrue);
    });

    test('spelling variants ESCPOS / EPSON normalise to the default', () {
      expect(normalizeDialect('escpos'), kDefaultEscPosDialect);
      expect(normalizeDialect('Epson'), kDefaultEscPosDialect);
      expect(normalizeDialect('  '), kDefaultEscPosDialect);
      expect(normalizeDialect(null), kDefaultEscPosDialect);
    });

    test('dialect unknown → documented default bytes + reported, never blocked', () {
      final r = encodePrintJobDetailed(_job(['X'], dialect: 'ZPL'));
      expect(r.dialect, 'ZPL'); // the unknown value is surfaced, not hidden
      expect(r.dialectKnown, isFalse);
      expect(r.bytes.sublist(0, 2), [0x1B, 0x40]); // still prints with the default
      expect(r.bytes, isNotEmpty);
    });
  });
}
