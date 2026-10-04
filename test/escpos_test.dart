import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gundam_pos/logic/print_format_render.dart';
import 'package:gundam_pos/services/escpos.dart';
import 'package:gundam_pos/services/print_broker.dart';
import 'package:gundam_pos/services/print_image.dart';
import 'package:gundam_pos/services/print_routing.dart';

PrintJob _job(
  List<String> lines, {
  List<PrintableEntry> entries = const [],
  int widthMm = 80,
  String transport = 'BLUETOOTH',
  String? mac = 'AA:BB:CC:DD:EE:FF',
  String dialect = kDefaultEscPosDialect,
  String? codePage,
  bool supportsRasterImage = false,
  bool? supportsCutter,
  bool? supportsNativeQr,
  bool? supportsNativeBarcode,
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
        codePage: codePage,
        supportsRasterImage: supportsRasterImage,
        supportsCutter: supportsCutter,
        supportsNativeQr: supportsNativeQr,
        supportsNativeBarcode: supportsNativeBarcode,
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

    test('runes are mapped through the default code page (CP437); unmappable → "?"', () {
      // CP437: é = 0x82 (was 0xE9 under the old Latin-1 pass-through, which the
      // printer renders as garbage when ESC t 0 selects CP437).
      final bytes = (EscPosEncoder()..line('café ☕')).bytes;
      expect(bytes, [0x63, 0x61, 0x66, 0x82, 0x20, 0x3F, 0x0A]);
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
      expect(r.dialectImplemented, isFalse);
      expect(r.bytes.sublist(0, 2), [0x1B, 0x40]); // still prints with the default
      expect(r.bytes, isNotEmpty);
      expect(r.warnings.any((w) => w.contains('not in the dialect registry')), isTrue);
    });
  });

  group('dialect registry — implemented vs declared', () {
    test('Epson ESC/POS and generic clone are implemented, with their capabilities', () {
      expect(kEscPosDialects['ESC/POS']!.implemented, isTrue);
      expect(kEscPosDialects['ESC/POS-CLONE']!.implemented, isTrue);
      final epson = kEscPosDialects['ESC/POS']!.capabilities;
      expect([epson.nativeQr, epson.nativeBarcode, epson.cutter, epson.raster], [true, true, true, true]);
      final clone = kEscPosDialects['ESC/POS-CLONE']!.capabilities;
      expect([clone.nativeQr, clone.nativeBarcode, clone.cutter, clone.raster], [false, false, true, false]);
    });

    test('Star and Citizen are implemented, each with its real capability set', () {
      for (final code in ['STAR', 'CITIZEN']) {
        expect(isKnownDialect(code), isTrue, reason: code);
        expect(isImplementedDialect(code), isTrue, reason: code);
        expect(kEscPosDialects[code]!.initBytes, isNotEmpty, reason: code);
      }
      // Star Line Mode is a real dialect with a real cutter (`ESC d n`), but this
      // build emits no Star QR/barcode bytes, so those stay false and fall back
      // to the labelled text form.
      final star = kEscPosDialects['STAR']!.capabilities;
      expect([star.nativeQr, star.nativeBarcode, star.cutter, star.raster], [false, false, true, false]);
      // Citizen: QR (`GS ( k`), barcode (`GS k`) and cut (`GS V`) are all its
      // documented ESC/POS forms.
      final citizen = kEscPosDialects['CITIZEN']!.capabilities;
      expect([citizen.nativeQr, citizen.nativeBarcode, citizen.cutter, citizen.raster], [true, true, true, true]);
      // Every registry dialect is now implemented — the fallback path is only
      // reachable for codes the registry does not carry.
      expect(kEscPosDialects.values.every((d) => d.implemented), isTrue);
    });

    test('config spellings normalise to registry codes', () {
      expect(normalizeDialect('Clone'), 'ESC/POS-CLONE');
      expect(normalizeDialect('generic'), 'ESC/POS-CLONE');
      expect(normalizeDialect('Star Line Mode'), 'STAR');
      expect(normalizeDialect('citizen'), 'CITIZEN');
    });
  });

  group('per-dialect byte sequences', () {
    test('Epson: init ESC @, full cut GS V 0, partial GS V 1, align ESC a n', () {
      expect((EscPosEncoder(dialect: 'ESC/POS')..init()).bytes, [0x1B, 0x40]);
      expect((EscPosEncoder(dialect: 'ESC/POS')..cut()).bytes, [0x1D, 0x56, 0x00]);
      expect((EscPosEncoder(dialect: 'ESC/POS')..cut(partial: true)).bytes, [0x1D, 0x56, 0x01]);
      expect((EscPosEncoder(dialect: 'ESC/POS')..align(2)).bytes, [0x1B, 0x61, 0x02]);
    });

    test('generic clone: init ESC @ + ESC 2, cut GS V 66 0, partial downgraded', () {
      expect((EscPosEncoder(dialect: 'ESC/POS-CLONE')..init()).bytes, [0x1B, 0x40, 0x1B, 0x32]);
      expect((EscPosEncoder(dialect: 'ESC/POS-CLONE')..cut()).bytes, [0x1D, 0x56, 0x42, 0x00]);
      expect((EscPosEncoder(dialect: 'ESC/POS-CLONE')..cut(partial: true)).bytes, [0x1D, 0x56, 0x42, 0x00]);
      expect((EscPosEncoder(dialect: 'ESC/POS-CLONE')..align(1)).bytes, [0x1B, 0x61, 0x01]);
    });

    test('a whole ticket encodes with the clone dialect bytes', () {
      final clone = encodePrintJobDetailed(_job(['HELLO'], dialect: 'ESC/POS-CLONE'));
      expect(clone.bytes.sublist(0, 10), [0x1B, 0x40, 0x1B, 0x32, 0x1B, 0x74, 0x00, 0x1B, 0x61, 0x00]);
      expect(clone.bytes.sublist(clone.bytes.length - 7), [0x1B, 0x64, 0x03, 0x1D, 0x56, 0x42, 0x00]);
      expect(clone.dialectImplemented, isTrue);
    });

    test('every registry dialect is implemented — only unknown codes fall back', () {
      expect(kEscPosDialects.values.where((d) => !d.implemented), isEmpty);
      // effectiveDialect is the guard that keeps an unknown code honest: it
      // returns the default ESC/POS spec rather than a pretence.
      expect(effectiveDialect('ZPL'), same(kEpsonEscPosDialect));
      expect(effectiveDialect('STAR'), same(kStarLineModeDialect));
      expect(effectiveDialect('CITIZEN'), same(kCitizenDialect));
    });
  });

  group('Star Line Mode — real command bytes (not an ESC/POS alias)', () {
    EscPosEncoder star() => EscPosEncoder(dialect: 'STAR');

    test('init: ESC @ then ESC z 1 (line feed amount pinned to 4 mm)', () {
      expect(star().init().bytes, [0x1B, 0x40, 0x1B, 0x7A, 0x01]);
    });

    test('emphasis: ESC E on, ESC F off — no count byte', () {
      expect(star().bold(true).bytes, [0x1B, 0x45]);
      expect(star().bold(false).bytes, [0x1B, 0x46]);
    });

    test('character size: ESC i n1 n2 (high, wide); 1 1 is double w+h', () {
      expect(star().doubleSize().bytes, [0x1B, 0x69, 0x01, 0x01]);
      expect(star().normalSize().bytes, [0x1B, 0x69, 0x00, 0x00]);
    });

    test('alignment: ESC GS a n (Star ESC a n feeds paper, it does not align)', () {
      expect(star().align(0).bytes, [0x1B, 0x1D, 0x61, 0x00]);
      expect(star().align(1).bytes, [0x1B, 0x1D, 0x61, 0x01]);
      expect(star().align(2).bytes, [0x1B, 0x1D, 0x61, 0x02]);
    });

    test('feed n lines: ESC a n (ESC d is Star-s cutter, not a feed)', () {
      expect(star().feed(3).bytes, [0x1B, 0x61, 0x03]);
    });

    test('cut: ESC d n — full 0, partial 1 (Star-s cutter, not GS V)', () {
      expect(star().cut().bytes, [0x1B, 0x64, 0x00]);
      expect(star().cut(partial: true).bytes, [0x1B, 0x64, 0x01]);
    });

    test('a whole STAR ticket is Star bytes end to end', () {
      final r = encodePrintJobDetailed(_job(['HELLO'], dialect: 'STAR'));
      expect(r.dialectImplemented, isTrue);
      expect(r.dialect, 'STAR');
      expect(r.bytes, [
        0x1B, 0x40, 0x1B, 0x7A, 0x01, // ESC @ ESC z 1 (init)
        0x1B, 0x1D, 0x74, 0x01, // ESC GS t 1 (CP437 on Star)
        0x1B, 0x1D, 0x61, 0x00, // ESC GS a 0 (left)
        0x1B, 0x46, // ESC F (emphasis off)
        0x1B, 0x69, 0x00, 0x00, // ESC i 0 0 (normal size)
        0x48, 0x45, 0x4C, 0x4C, 0x4F, 0x0A, // HELLO + LF
        0x1B, 0x61, 0x03, // ESC a 3 (feed 3 lines)
        0x1B, 0x64, 0x00, // ESC d 0 (full cut)
      ]);
      expect(r.warnings, isEmpty);
    });

    test('code page: Star-s own ESC GS t n selectors', () {
      expect(star().selectCodePage('CP437').bytes, [0x1B, 0x1D, 0x74, 0x01]);
      expect(star().selectCodePage('KATAKANA').bytes, [0x1B, 0x1D, 0x74, 0x02]);
      expect(star().selectCodePage('CP858').bytes, [0x1B, 0x1D, 0x74, 0x04]);
      expect(star().selectCodePage('CP863').bytes, [0x1B, 0x1D, 0x74, 0x08]);
      expect(star().selectCodePage('CP866').bytes, [0x1B, 0x1D, 0x74, 0x0A]);
      expect(star().selectCodePage('CP1252').bytes, [0x1B, 0x1D, 0x74, 0x20]);
      expect((star()..selectCodePage('CP865')).activeCodePage.code, 'CP865');
    });

    test('CP850 has NO Star equivalent → CP437 selector 1, reported', () {
      final r = encodePrintJobDetailed(_job(['X'], dialect: 'STAR', codePage: 'CP850'));
      expect(r.codePage, 'CP437');
      expect(r.codePageKnown, isTrue);
      expect(r.codePageSupportedByDialect, isFalse);
      expect(_indexOf(r.bytes, [0x1B, 0x1D, 0x74, 0x01]), greaterThanOrEqualTo(0));
      expect(_indexOf(r.bytes, [0x1B, 0x1D, 0x74, 0x02]), -1); // never Epson-s n=2
      expect(r.warnings.any((w) => w.contains('not supported by dialect')), isTrue);
    });

    test('capability gating: no native QR/barcode, but the cutter still fires', () {
      final r = encodePrintJobDetailed(_job(
        ['X'],
        dialect: 'STAR',
        entries: [
          PrintableEntry(kind: PrintableKind.qr, atLine: 0, content: 'A'),
          PrintableEntry(kind: PrintableKind.barcode, atLine: 0, content: '12345', symbology: 'CODE128'),
        ],
      ));
      expect(_indexOf(r.bytes, [0x1D, 0x28, 0x6B]), -1); // no Epson QR into a Star
      expect(_indexOf(r.bytes, [0x1D, 0x6B]), -1); // no Epson barcode either
      expect(_indexOf(r.bytes, '[QR A]'.codeUnits), greaterThanOrEqualTo(0));
      expect(_indexOf(r.bytes, '[BARCODE CODE128] 12345'.codeUnits), greaterThanOrEqualTo(0));
      expect(r.qrFallbacks, 1);
      expect(r.barcodeFallbacks, 1);
      expect(r.cutEmitted, isTrue);
      expect(r.bytes.sublist(r.bytes.length - 3), [0x1B, 0x64, 0x00]);
    });

    test('aliases resolve to STAR with byte-identical output', () {
      for (final raw in const ['STAR', 'STAR-LINE-MODE', 'STARLINE', 'Star Line Mode', 'star/line/mode']) {
        expect(normalizeDialect(raw), 'STAR', reason: raw);
        expect(encodePrintJobDetailed(_job(['HELLO'], dialect: raw)).bytes,
            encodePrintJobDetailed(_job(['HELLO'], dialect: 'STAR')).bytes,
            reason: raw);
      }
    });
  });

  group('Citizen ESC/POS — its documented command bytes', () {
    EscPosEncoder citizen() => EscPosEncoder(dialect: 'CITIZEN');

    test('init / emphasis / size / align / feed / cut are Citizen-s forms', () {
      expect(citizen().init().bytes, [0x1B, 0x40]); // ESC @
      expect(citizen().bold(true).bytes, [0x1B, 0x45, 0x01]); // ESC E 1
      expect(citizen().bold(false).bytes, [0x1B, 0x45, 0x00]); // ESC E 0
      expect(citizen().doubleSize().bytes, [0x1D, 0x21, 0x11]); // GS ! 0x11
      expect(citizen().normalSize().bytes, [0x1D, 0x21, 0x00]); // GS ! 0
      expect(citizen().align(1).bytes, [0x1B, 0x61, 0x01]); // ESC a 1
      expect(citizen().feed(3).bytes, [0x1B, 0x64, 0x03]); // ESC d 3
      expect(citizen().cut().bytes, [0x1D, 0x56, 0x00]); // GS V 0 full
      expect(citizen().cut(partial: true).bytes, [0x1D, 0x56, 0x01]); // GS V 1 partial
    });

    test('code page: Citizen-s ESC t n table', () {
      expect(citizen().selectCodePage('CP437').bytes, [0x1B, 0x74, 0x00]);
      expect(citizen().selectCodePage('CP850').bytes, [0x1B, 0x74, 0x02]);
      expect(citizen().selectCodePage('CP863').bytes, [0x1B, 0x74, 0x04]);
      expect(citizen().selectCodePage('CP1252').bytes, [0x1B, 0x74, 0x10]);
      expect(citizen().selectCodePage('CP866').bytes, [0x1B, 0x74, 0x11]);
      expect(citizen().selectCodePage('CP852').bytes, [0x1B, 0x74, 0x12]);
      expect((citizen()..selectCodePage('CP865')).activeCodePage.code, 'CP865');
    });

    test('UTF-8 has no Citizen selector → CP437, reported, never multi-byte', () {
      final r = encodePrintJobDetailed(_job(['X'], dialect: 'CITIZEN', codePage: 'UTF-8'));
      expect(r.codePage, 'CP437');
      expect(r.codePageKnown, isTrue);
      expect(r.codePageSupportedByDialect, isFalse);
      expect(_indexOf(r.bytes, [0x1B, 0x74, 0x00]), greaterThanOrEqualTo(0));
      expect(r.warnings.any((w) => w.contains('no ESC/POS encoding')), isTrue);
    });

    test('capability gating: native QR and barcode fire, cutter fires', () {
      final r = encodePrintJobDetailed(_job(
        ['X'],
        dialect: 'CITIZEN',
        entries: [
          PrintableEntry(kind: PrintableKind.qr, atLine: 0, content: 'NSTAR-1', sizeMm: 20),
          PrintableEntry(kind: PrintableKind.barcode, atLine: 0, content: '12345', symbology: 'CODE128'),
        ],
      ));
      expect(_indexOf(r.bytes, [0x1D, 0x28, 0x6B, 0x04, 0x00, 0x31, 0x41, 50, 0]), greaterThanOrEqualTo(0));
      expect(_indexOf(r.bytes, [0x1D, 0x6B, 73, 5]), greaterThanOrEqualTo(0));
      expect(r.qrFallbacks, 0);
      expect(r.barcodeFallbacks, 0);
      expect(r.cutEmitted, isTrue);
      expect(r.bytes.sublist(r.bytes.length - 3), [0x1D, 0x56, 0x00]);
    });

    test('a whole CITIZEN ticket is byte-identical to Epson (documented emulation)', () {
      final citizen = encodePrintJobDetailed(_job(['HELLO'], dialect: 'CITIZEN'));
      final epson = encodePrintJobDetailed(_job(['HELLO'], dialect: 'ESC/POS'));
      expect(citizen.dialectImplemented, isTrue);
      expect(citizen.bytes.sublist(0, 8), [0x1B, 0x40, 0x1B, 0x74, 0x00, 0x1B, 0x61, 0x00]);
      expect(citizen.bytes, epson.bytes);
      expect(citizen.warnings, isEmpty);
    });

    test('aliases resolve to CITIZEN with byte-identical output', () {
      for (final raw in const ['CITIZEN', 'CITIZEN-ESCPOS', 'CITIZEN/SYSTEM', 'citizen']) {
        expect(normalizeDialect(raw), 'CITIZEN', reason: raw);
        expect(encodePrintJobDetailed(_job(['HELLO'], dialect: raw)).bytes,
            encodePrintJobDetailed(_job(['HELLO'], dialect: 'CITIZEN')).bytes,
            reason: raw);
      }
    });
  });

  group('code page selection (ESC t n)', () {
    test('selector bytes per page', () {
      const selectors = {
        'CP437': 0x00,
        'Katakana': 0x01,
        'CP850': 0x02,
        'CP860': 0x03,
        'CP1252': 0x10,
        'CP866': 0x11,
        'CP852': 0x12,
        'CP858': 0x13,
      };
      selectors.forEach((code, sel) {
        expect((EscPosEncoder()..selectCodePage(code)).bytes, [0x1B, 0x74, sel], reason: code);
        expect((EscPosEncoder()..selectCodePage(code)).activeCodePage.code, normalizeCodePage(code), reason: code);
      });
    });

    test('text is mapped to the chosen page', () {
      expect((EscPosEncoder(codePage: 'CP437')..line('é')).bytes, [0x82, 0x0A]);
      expect((EscPosEncoder(codePage: 'CP850')..line('é')).bytes, [0x82, 0x0A]);
      expect((EscPosEncoder(codePage: 'CP1252')..line('é')).bytes, [0xE9, 0x0A]);
      expect((EscPosEncoder(codePage: 'CP858')..line('€')).bytes, [0xD5, 0x0A]);
      expect((EscPosEncoder(codePage: 'CP866')..line('Ж')).bytes, [0x86, 0x0A]);
      expect((EscPosEncoder(codePage: 'Katakana')..line('ｱ')).bytes, [0xB1, 0x0A]);
    });

    test('unrepresentable runes: transliterate, else substitute, always report', () {
      final r = encodePrintJobDetailed(_job(['café ☕'], codePage: 'CP866'));
      expect(_indexOf(r.bytes, [0x63, 0x61, 0x66, 0x65, 0x20, 0x3F, 0x0A]), greaterThanOrEqualTo(0));
      expect(r.transliteratedChars, 1); // é → e
      expect(r.substitutedChars, 1); // ☕ → ?
      expect(r.warnings.any((w) => w.contains('transliterated')), isTrue);
      expect(r.warnings.any((w) => w.contains('substituted')), isTrue);
      expect(r.bytes.contains(0xE9), isFalse); // never the unmapped rune
    });

    test('a code page the dialect does not support falls back to CP437 and is reported', () {
      final r = encodePrintJobDetailed(_job(['é'], dialect: 'ESC/POS-CLONE', codePage: 'CP1252'));
      expect(r.codePage, 'CP437');
      expect(r.codePageKnown, isTrue);
      expect(r.codePageSupportedByDialect, isFalse);
      expect(_indexOf(r.bytes, [0x1B, 0x74, 0x00]), greaterThanOrEqualTo(0));
      expect(r.bytes.contains(0xE9), isFalse);
      expect(r.warnings.any((w) => w.contains('not supported by dialect')), isTrue);
    });

    test('an unknown code page falls back to CP437 and is reported', () {
      final r = encodePrintJobDetailed(_job(['X'], codePage: 'CP9999'));
      expect(r.codePage, 'CP437');
      expect(r.codePageKnown, isFalse);
      expect(_indexOf(r.bytes, [0x1B, 0x74, 0x00]), greaterThanOrEqualTo(0));
      expect(r.warnings.any((w) => w.contains('unknown')), isTrue);
    });

    test('absent config keeps the previous behaviour (default dialect + CP437)', () {
      final r = encodePrintJobDetailed(_job(['HELLO']));
      expect(r.dialect, kDefaultEscPosDialect);
      expect(r.codePage, kDefaultCodePage);
      expect(r.bytes.sublist(0, 8), [0x1B, 0x40, 0x1B, 0x74, 0x00, 0x1B, 0x61, 0x00]);
      expect(r.bytes.sublist(r.bytes.length - 6), [0x1B, 0x64, 0x03, 0x1D, 0x56, 0x00]);
      expect(r.warnings, isEmpty);
    });
  });

  group('capability-gated QR / barcode / cutter', () {
    test('native QR on a dialect that supports it', () {
      final r = encodePrintJobDetailed(_job(
        ['X'],
        entries: [PrintableEntry(kind: PrintableKind.qr, atLine: 0, content: 'NSTAR-1', sizeMm: 20)],
      ));
      expect(_indexOf(r.bytes, [0x1D, 0x28, 0x6B, 0x04, 0x00, 0x31, 0x41, 50, 0]), greaterThanOrEqualTo(0));
      expect(r.qrFallbacks, 0);
    });

    test('no native QR → the documented labelled text fallback, reported', () {
      final r = encodePrintJobDetailed(_job(
        ['X'],
        entries: [PrintableEntry(kind: PrintableKind.qr, atLine: 0, content: 'NSTAR-1')],
        dialect: 'ESC/POS-CLONE',
      ));
      expect(_indexOf(r.bytes, [0x1D, 0x28, 0x6B]), -1);
      expect(_indexOf(r.bytes, '[QR NSTAR-1]'.codeUnits), greaterThanOrEqualTo(0));
      expect(r.qrFallbacks, 1);
      expect(r.warnings.any((w) => w.contains('no native QR')), isTrue);
    });

    test('a printer override turns native QR off on an Epson', () {
      final r = encodePrintJobDetailed(_job(
        ['X'],
        entries: [PrintableEntry(kind: PrintableKind.qr, atLine: 0, content: 'A')],
        supportsNativeQr: false,
      ));
      expect(_indexOf(r.bytes, [0x1D, 0x28, 0x6B]), -1);
      expect(r.qrFallbacks, 1);
    });

    test('barcode: native on Epson, labelled text fallback on a clone', () {
      final native = encodePrintJobDetailed(_job(
        ['X'],
        entries: [PrintableEntry(kind: PrintableKind.barcode, atLine: 0, content: '12345', symbology: 'CODE128')],
      ));
      expect(_indexOf(native.bytes, [0x1D, 0x6B, 73, 5, 0x31, 0x32, 0x33, 0x34, 0x35]), greaterThanOrEqualTo(0));
      expect(native.barcodeFallbacks, 0);

      final clone = encodePrintJobDetailed(_job(
        ['X'],
        entries: [PrintableEntry(kind: PrintableKind.barcode, atLine: 0, content: '12345', symbology: 'CODE128')],
        dialect: 'ESC/POS-CLONE',
      ));
      expect(_indexOf(clone.bytes, [0x1D, 0x6B]), -1);
      expect(_indexOf(clone.bytes, '[BARCODE CODE128] 12345'.codeUnits), greaterThanOrEqualTo(0));
      expect(clone.barcodeFallbacks, 1);
    });

    test('cut: per dialect, and skipped entirely when no cutter is reported', () {
      final epson = encodePrintJobDetailed(_job(['X']));
      expect(epson.cutEmitted, isTrue);
      expect(epson.bytes.sublist(epson.bytes.length - 3), [0x1D, 0x56, 0x00]);

      final clone = encodePrintJobDetailed(_job(['X'], dialect: 'ESC/POS-CLONE'));
      expect(clone.cutEmitted, isTrue);
      expect(clone.bytes.sublist(clone.bytes.length - 4), [0x1D, 0x56, 0x42, 0x00]);

      final noCutter = encodePrintJobDetailed(_job(['X'], supportsCutter: false));
      expect(noCutter.cutEmitted, isFalse);
      expect(_indexOf(noCutter.bytes, [0x1D, 0x56]), -1);
      expect(noCutter.bytes.sublist(noCutter.bytes.length - 3), [0x1B, 0x64, 0x03]);
      expect(noCutter.warnings.any((w) => w.contains('no cutter')), isTrue);
    });

    test('all three capability overrides turn a dialect feature ON, not only off', () {
      final qr = PrintableEntry(kind: PrintableKind.qr, atLine: 0, content: 'A');
      final bar = PrintableEntry(kind: PrintableKind.barcode, atLine: 0, content: '12345', symbology: 'CODE128');

      // Clone defaults: no native QR/barcode — overridden on.
      final cloneNative = encodePrintJobDetailed(_job(
        ['X'],
        entries: [qr, bar],
        dialect: 'ESC/POS-CLONE',
        supportsNativeQr: true,
        supportsNativeBarcode: true,
      ));
      expect(_indexOf(cloneNative.bytes, [0x1D, 0x28, 0x6B, 0x04, 0x00, 0x31, 0x41, 50, 0]), greaterThanOrEqualTo(0));
      expect(_indexOf(cloneNative.bytes, [0x1D, 0x6B, 73, 5]), greaterThanOrEqualTo(0));
      expect(cloneNative.qrFallbacks, 0);
      expect(cloneNative.barcodeFallbacks, 0);

      // Cutter overridden ON for the same clone (it already cuts) vs OFF.
      expect(encodePrintJobDetailed(_job(['X'], dialect: 'ESC/POS-CLONE', supportsCutter: true)).cutEmitted, isTrue);
      expect(encodePrintJobDetailed(_job(['X'], dialect: 'ESC/POS-CLONE', supportsCutter: false)).cutEmitted, isFalse);
    });
  });

  group('drifted vocabulary — both web spellings, one behaviour', () {
    test('dialects: the web code and the POS code resolve to the same canonical value', () {
      for (final pair in const {
        'ESC/POS-GENERIC': 'ESC/POS-CLONE',
        'STAR-LINE-MODE': 'STAR',
        'CITIZEN-ESCPOS': 'CITIZEN',
      }.entries) {
        expect(normalizeDialect(pair.key), pair.value, reason: pair.key);
        expect(normalizeDialect(pair.value), pair.value, reason: pair.value);
      }
    });

    test('dialects: both spellings produce byte-identical output', () {
      for (final pair in const {
        'ESC/POS-GENERIC': 'ESC/POS-CLONE',
        'STAR-LINE-MODE': 'STAR',
        'CITIZEN-ESCPOS': 'CITIZEN',
      }.entries) {
        final web = encodePrintJobDetailed(_job(['HELLO'], dialect: pair.key));
        final pos = encodePrintJobDetailed(_job(['HELLO'], dialect: pair.value));
        expect(web.dialect, pair.value, reason: pair.key);
        expect(web.bytes, pos.bytes, reason: pair.key);
        expect(web.dialectKnown, pos.dialectKnown, reason: pair.key);
        expect(web.warnings, pos.warnings, reason: pair.key);
      }
      // The unrecognised value is still surfaced verbatim for the alert path.
      expect(normalizeDialect('ESC/POS-BOGUS'), 'ESC/POS/BOGUS');
      expect(encodePrintJobDetailed(_job(['X'], dialect: 'ESC/POS-BOGUS')).dialectKnown, isFalse);
    });

    test('code page: CP1252 and WPC1252 are the same page (`ESC t 16`)', () {
      expect(normalizeCodePage('WPC1252'), 'CP1252');
      expect(normalizeCodePage('CP1252'), 'CP1252');
      expect((EscPosEncoder()..selectCodePage('WPC1252')).bytes, [0x1B, 0x74, 0x10]);
      expect((EscPosEncoder()..selectCodePage('WPC1252')).bytes, (EscPosEncoder()..selectCodePage('CP1252')).bytes);
      expect((EscPosEncoder()..selectCodePage('WPC1252')).activeCodePage.code, 'CP1252');
      // Unknown pages are still surfaced, never guessed.
      expect(resolveCodePage('WPC1252').known, isTrue);
      expect(resolveCodePage('CP9999').known, isFalse);
      expect(resolveCodePage('CP9999').requested, 'CP9999');
    });
  });

  group('code pages the web vocabulary lists', () {
    test('CP863 (Canadian French) is `ESC t 4` and maps its letters', () {
      expect((EscPosEncoder()..selectCodePage('CP863')).bytes, [0x1B, 0x74, 0x04]);
      expect((EscPosEncoder()..selectCodePage('cp-863')).activeCodePage.code, 'CP863');
      final bytes = (EscPosEncoder(codePage: 'CP863')..line('àéçÉ')).bytes;
      expect(bytes, [0x85, 0x82, 0x87, 0x90, 0x0A]);
    });

    test('CP865 (Nordic) is `ESC t 5` and maps its letters', () {
      expect((EscPosEncoder()..selectCodePage('CP865')).bytes, [0x1B, 0x74, 0x05]);
      expect(resolveCodePage('NORDIC').page.code, 'CP865');
      final bytes = (EscPosEncoder(codePage: 'CP865')..line('øåØÆå')).bytes;
      expect(bytes, [0x9B, 0x86, 0x9D, 0x92, 0x86, 0x0A]);
    });

    test('both new pages are selectable on Epson and refused on the clone', () {
      for (final code in const ['CP863', 'CP865']) {
        final epson = encodePrintJobDetailed(_job(['X'], codePage: code));
        expect(epson.codePage, code, reason: code); // Epson exposes ESC t 4/5
        final clone = encodePrintJobDetailed(_job(['X'], dialect: 'ESC/POS-CLONE', codePage: code));
        expect(clone.codePage, 'CP437', reason: code);
        expect(clone.warnings.any((w) => w.contains('not supported by dialect')), isTrue, reason: code);
      }
    });
  });

  group('UTF-8 is honestly unsupported (ESC/POS has no UTF-8 page)', () {
    test('selecting UTF-8 falls back to CP437, reported, never multi-byte garbage', () {
      final r = encodePrintJobDetailed(_job(['X'], codePage: 'UTF-8'));
      expect(r.codePage, 'CP437');
      expect(r.codePageKnown, isTrue); // recognised — just not encodable
      expect(r.codePageSupportedByDialect, isFalse);
      expect(_indexOf(r.bytes, [0x1B, 0x74, 0x00]), greaterThanOrEqualTo(0)); // ESC t 0
      expect(r.warnings.any((w) => w.contains('no ESC/POS encoding')), isTrue);
      // 'X' stays one byte: no UTF-8 continuation bytes on the wire.
      expect(_indexOf(r.bytes, [0x58, 0x0A]), greaterThanOrEqualTo(0));
      expect(kEscPosCodePages['UTF-8']!.implemented, isFalse);
      expect(kEscPosCodePages['UTF-8']!.selector, isNull);
    });

    test('the other UTF-8 spellings normalise to the same refusal', () {
      for (final raw in const ['UTF-8', 'utf8', 'Unicode']) {
        expect(normalizeCodePage(raw), 'UTF-8', reason: raw);
        expect(encodePrintJobDetailed(_job(['X'], codePage: raw)).codePage, 'CP437', reason: raw);
      }
    });
  });

  group('capability keys from the config drive the encoder', () {
    const base = {
      'id': 'p',
      'name': 'P',
      'transport': 'USB',
    };

    ClientPrinter? parse(Map<String, dynamic> j) => ClientPrinter.fromJson(Map<String, dynamic>.from(j));

    test('flat, nested and short-alias capability keys all drive the gating', () {
      final flat = parse({...base, 'supportsNativeQr': true, 'supportsCutter': false, 'supportsNativeBarcode': true})!;
      final nested = parse({
        ...base,
        'printerModel': {'supportsNativeQr': true, 'supportsCutter': false, 'supportsNativeBarcode': true},
      })!;
      final alias = parse({...base, 'nativeQr': true, 'cutter': false, 'nativeBarcode': true})!;
      for (final p in [flat, nested, alias]) {
        final pp = p.toPrintPrinter();
        expect(pp.supportsNativeQr, isTrue);
        expect(pp.supportsCutter, isFalse);
        expect(pp.supportsNativeBarcode, isTrue);
      }
    });

    test('absent keys keep the dialect default (no behaviour change)', () {
      final p = parse({...base, 'protocol': 'ESC/POS-CLONE'})!;
      final pp = p.toPrintPrinter();
      expect(pp.supportsNativeQr, isNull);
      expect(pp.supportsCutter, isNull);
      expect(pp.supportsNativeBarcode, isNull);
      // No overrides → the clone still falls back to text QR and still cuts.
      final r = encodePrintJobDetailed(PrintJob(
        ticketType: 'BILL',
        lines: const ['X'],
        entries: [PrintableEntry(kind: PrintableKind.qr, atLine: 0, content: 'A')],
        printer: pp,
      ));
      expect(r.qrFallbacks, 1);
      expect(r.cutEmitted, isTrue);
    });
  });

  group('thermal raster image — GS v 0 through the encoder', () {
    // 4x2 synthetic bitmap (grey values, r=g=b).
    ImageBitmap bitmap() {
      final rgba = <int>[];
      for (final v in const [0, 100, 200, 255, 255, 0, 128, 127]) {
        rgba.addAll([v, v, v, 255]);
      }
      return ImageBitmap(width: 4, height: 2, rgba: rgba);
    }

    PrintableEntry image(String key, {int? maxHeightMm}) => PrintableEntry(
          kind: PrintableKind.image,
          atLine: 0,
          content: key,
          assetKey: key,
          maxHeightMm: maxHeightMm,
        );

    test('raster-capable printer + resolvable asset emits real GS v 0 bytes', () async {
      final r = await encodePrintJobWithImages(
        _job(['X'], entries: [image('logo')], supportsRasterImage: true, widthMm: 80),
        source: _FakeSource({'logo': Uint8List.fromList([1, 2, 3])}),
        decoder: _FakeDecoder(bitmap()),
      );
      expect(r.rasterImages, 1);
      expect(r.placeholderImages, 0);
      expect(r.skippedImages, 0);
      // GS v 0, row bytes = 72 (576 dots), 288 dots tall for a 4x2 source.
      expect(_indexOf(r.bytes, [0x1D, 0x76, 0x30, 0x00, 0x48, 0x00, 0x20, 0x01]), greaterThanOrEqualTo(0));
      expect(_indexOf(r.bytes, '[IMAGE logo]'.codeUnits), -1); // no placeholder text
      expect(r.warnings, isEmpty);
    });

    test('the 58 mm head emits the 384-dot (48 row-byte) raster', () async {
      final r = await encodePrintJobWithImages(
        _job(['X'], entries: [image('logo')], supportsRasterImage: true, widthMm: 58),
        source: _FakeSource({'logo': Uint8List.fromList([1])}),
        decoder: _FakeDecoder(bitmap()),
      );
      expect(_indexOf(r.bytes, [0x1D, 0x76, 0x30, 0x00, 0x30, 0x00]), greaterThanOrEqualTo(0));
    });

    test('a missing asset degrades to the labelled placeholder + a warning', () async {
      final r = await encodePrintJobWithImages(
        _job(['X'], entries: [image('logo')], supportsRasterImage: true),
        source: _FakeSource(const {'logo': null}), // not cached
        decoder: _FakeDecoder(bitmap()),
      );
      expect(r.placeholderImages, 1);
      expect(r.rasterImages, 0);
      expect(_indexOf(r.bytes, '[IMAGE logo]'.codeUnits), greaterThanOrEqualTo(0));
      expect(r.warnings.any((w) => w.contains('placeholder')), isTrue);
    });

    test('an unreadable/undecodable asset degrades to the placeholder + a warning', () async {
      final r = await encodePrintJobWithImages(
        _job(['X'], entries: [image('logo')], supportsRasterImage: true),
        source: _FakeSource({'logo': Uint8List.fromList([0xFF, 0x00])}),
        decoder: _FakeDecoder(null), // decode failed
      );
      expect(r.placeholderImages, 1);
      expect(_indexOf(r.bytes, '[IMAGE logo]'.codeUnits), greaterThanOrEqualTo(0));
      expect(r.warnings.any((w) => w.contains('missing, unreadable or not an image')), isTrue);
    });

    test('a non-raster printer skips the block, labelled and reported', () async {
      final r = await encodePrintJobWithImages(
        _job(['X'], entries: [image('logo')], supportsRasterImage: false),
        source: _FakeSource({'logo': Uint8List.fromList([1])}),
        decoder: _FakeDecoder(bitmap()),
      );
      expect(r.skippedImages, 1);
      expect(r.rasterImages, 0);
      expect(_indexOf(r.bytes, '[IMAGE logo skipped: no raster support]'.codeUnits), greaterThanOrEqualTo(0));
      expect(r.warnings.any((w) => w.contains('no raster support')), isTrue);
    });

    test('a declared maxHeightMm clamp surfaces as an encoder warning', () async {
      final r = await encodePrintJobWithImages(
        _job(['X'], entries: [image('logo', maxHeightMm: 1)], supportsRasterImage: true, widthMm: 80),
        source: _FakeSource({'logo': Uint8List.fromList([1])}),
        decoder: _FakeDecoder(bitmap()),
      );
      expect(r.rasterImages, 1);
      expect(r.warnings.any((w) => w.contains('cropped') && w.contains('maxHeightMm')), isTrue);
    });

    test('no IMAGE block → the text path is byte-identical', () {
      final job = _job(['ONE', 'TWO'], entries: [
        PrintableEntry(kind: PrintableKind.qr, atLine: 0, content: 'A'),
      ]);
      expect(encodePrintJobDetailed(job, rasterLookup: (_, __) => null).bytes, encodePrintJob(job));
      expect(encodePrintJobDetailed(job).bytes, encodePrintJob(job));
    });
  });
}

/// assetKey → raw bytes; null models a not-cached / unreadable asset.
class _FakeSource extends PrintImageSource {
  _FakeSource(this._byKey);
  final Map<String, Uint8List?> _byKey;
  @override
  Future<Uint8List?> bytesFor(String assetKey) async => _byKey[assetKey];
}

/// Models Flutter's decoder; null models bytes that are not an image.
class _FakeDecoder extends PrintImageDecoder {
  _FakeDecoder(this._bitmap);
  final ImageBitmap? _bitmap;
  @override
  Future<ImageBitmap?> decode(Uint8List bytes) async => _bitmap;
}
