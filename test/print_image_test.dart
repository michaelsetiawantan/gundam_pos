import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gundam_pos/services/print_image.dart';

/// Build an RGBA bitmap from a grey plane (r=g=b=value, a=255).
ImageBitmap _grayBitmap(List<int> gray, int width, int height) {
  final rgba = <int>[];
  for (final v in gray) {
    rgba.addAll([v, v, v, 255]);
  }
  return ImageBitmap(width: width, height: height, rgba: rgba);
}

void main() {
  group('width vocabulary (58 mm → 384 dots, 80 mm → 576 dots at 8 dots/mm)', () {
    test('rasterWidthDots matches the text grid boundary', () {
      expect(rasterWidthDots(58), 384);
      expect(rasterWidthDots(80), 576);
      expect(rasterWidthDots(76), 384); // any < 80 mm paper is the 58 mm head
      expect(rasterWidthDots(112), 576);
      expect(kDotsPerMm, 8);
    });

    test('row bytes are ceil(widthDots / 8)', () {
      expect(rasterRowBytes(384), 48);
      expect(rasterRowBytes(576), 72);
      expect(rasterRowBytes(4), 1);
      expect(rasterRowBytes(9), 2);
    });
  });

  group('decode → luminance', () {
    test('Rec. 601 weighting', () {
      final img = ImageBitmap(width: 3, height: 1, rgba: [
        255, 0, 0, 255, // pure red → 76
        0, 255, 0, 255, // pure green → 150
        0, 0, 255, 255, // pure blue → 29
      ]);
      expect(luminance8(img), [76, 150, 29]);
    });

    test('opaque-white is 255, black is 0', () {
      final img = _grayBitmap([255, 0], 2, 1);
      expect(luminance8(img), [255, 0]);
    });
  });

  group('1-bit packing', () {
    // 4x2 grey plane: row0 = 0,100,200,255  row1 = 255,0,128,127
    final gray = <int>[0, 100, 200, 255, 255, 0, 128, 127];

    test('threshold: gray < 128 → black, MSB = leftmost dot', () {
      // row0: 0✓ 100✓ 200✗ 255✗ → 1100 0000 = 0xC0
      // row1: 255✗ 0✓ 128✗(128 is not <128) 127✓ → 0101 0000 = 0x50
      expect(packThreshold1Bit(gray, 4, 2), [0xC0, 0x50]);
    });

    test('Floyd–Steinberg: exact bytes for a known 8-px ramp', () {
      // ramp 0,40,90,127,128,170,220,255 → FS diffs the error (0xE8) where a
      // flat threshold would fire the first four (0xF0).
      const ramp = [0, 40, 90, 127, 128, 170, 220, 255];
      expect(packThreshold1Bit(ramp, 8, 1), [0xF0]);
      expect(packFloydSteinberg1Bit(ramp, 8, 1), [0xE8]);
    });

    test('Floyd–Steinberg extremes stay flat (no spurious noise)', () {
      final white = List.filled(16, 255);
      final black = List.filled(16, 0);
      expect(packFloydSteinberg1Bit(white, 16, 1), [0x00, 0x00]);
      expect(packFloydSteinberg1Bit(black, 16, 1), [0xFF, 0xFF]);
    });

    test('a 4x2 plane dithers to the same packed bytes as the threshold here', () {
      expect(packFloydSteinberg1Bit(gray, 4, 2), [0xC0, 0x50]);
    });
  });

  group('GS v 0 command layout', () {
    test('header is GS v 0 m xL xH yL yH then the packed rows', () {
      final packed = packThreshold1Bit(<int>[0, 100, 200, 255, 255, 0, 128, 127], 4, 2);
      expect(gsV0Command(packed, 4, 2), [
        0x1D, 0x76, 0x30, 0x00, // GS v 0, m = 0 (normal)
        0x01, 0x00, // xL xH = 1 byte per row
        0x02, 0x00, // yL yH = 2 dots tall
        0xC0, 0x50,
      ]);
    });

    test('width in the header is the printable-width row count', () {
      expect(gsV0Command(Uint8List(0), 384, 0).sublist(0, 8), [0x1D, 0x76, 0x30, 0x00, 0x30, 0x00, 0x00, 0x00]);
      expect(gsV0Command(Uint8List(0), 576, 0).sublist(0, 8), [0x1D, 0x76, 0x30, 0x00, 0x48, 0x00, 0x00, 0x00]);
    });

    test('a two-byte height is little-endian', () {
      expect(gsV0Command(Uint8List(0), 8, 300).sublist(0, 8), [0x1D, 0x76, 0x30, 0x00, 0x01, 0x00, 0x2C, 0x01]);
    });
  });

  group('encodeRasterImage — scale, pack and clamp', () {
    // 4x2 source: row0 = 0,100,200,255  row1 = 255,0,128,127
    final src = _grayBitmap(<int>[0, 100, 200, 255, 255, 0, 128, 127], 4, 2);

    test('scales to the requested dot width, aspect kept', () {
      final r = encodeRasterImage(src, targetWidthDots: 8, dither: false);
      expect(r.widthDots, 8);
      expect(r.heightDots, 4); // round(2 * 8 / 4)
      expect(r.clamped, isFalse);
      expect(r.warnings, isEmpty);
      expect(r.bytes.sublist(0, 8), [0x1D, 0x76, 0x30, 0x00, 0x01, 0x00, 0x04, 0x00]);
      expect(r.bytes.length, 8 + 4); // 1 byte/row × 4 rows
    });

    test('a narrow source upscaled to 80 mm uses the full 576-dot head', () {
      final r = encodeRasterImage(src, targetWidthDots: rasterWidthDots(80), dither: false);
      expect(r.widthDots, 576);
      expect(r.bytes[4], 72); // 576/8 = 72 bytes per row
      expect(r.heightDots, 288); // round(2 * 576 / 4)
      expect(r.bytes.length, 8 + 72 * 288);
    });

    test('identical source scaled to a different width keeps the same aspect', () {
      final r384 = encodeRasterImage(src, targetWidthDots: rasterWidthDots(58), dither: false);
      expect(r384.widthDots, 384);
      expect(r384.heightDots, 192);
    });

    test('maxHeightMm crops and reports the clamp', () {
      // 4x2 source at the full 576-dot head is 288 dots tall; 1 mm = 8 dots wins.
      final r = encodeRasterImage(src, targetWidthDots: 576, maxHeightMm: 1, dither: false);
      expect(r.heightDots, 8); // 1 mm × 8 dots/mm
      expect(r.clamped, isTrue);
      expect(r.warnings.single, contains('maxHeightMm'));
      expect(r.bytes.sublist(0, 8), [0x1D, 0x76, 0x30, 0x00, 0x48, 0x00, 0x08, 0x00]);
    });

    test('maxHeightDots crops more aggressively than the mm limit', () {
      final capped = encodeRasterImage(src, targetWidthDots: 8, maxHeightMm: 4, maxHeightDots: 3, dither: false);
      expect(capped.heightDots, 3);
      expect(capped.warnings.single, contains('maxHeightDots'));
    });

    test('the hard spool-safety cap always applies and is reported', () {
      // 1x8 source scaled to 576 → 4608 dots tall, over the 2048-dot cap.
      final tall = _grayBitmap(List.filled(8, 0), 1, 8);
      final r = encodeRasterImage(tall, targetWidthDots: 576, dither: false);
      expect(r.heightDots, kMaxRasterHeightDots);
      expect(r.clamped, isTrue);
      expect(r.warnings.single, contains('spool-safety'));
    });
  });
}
