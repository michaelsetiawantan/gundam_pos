/// Thermal raster image encoding — ESC/POS `GS v 0`, one bitmap → bytes.
///
/// Dependency-free: the only decoder used is Flutter's own (`dart:ui`
/// `instantiateImageCodec` → raw RGBA). Everything after decoding — grayscale,
/// scale to the printable width, 1-bit dither/threshold, pack into the `GS v 0`
/// command — is pure Dart over plain byte lists, so it is unit-testable without
/// real files or a real printer.
///
/// Width source: the encoder's own paper vocabulary is 58 mm → 32 cells and
/// 80 mm → 48 cells (see `cellsForEncoderWidth` / `cellsForWidthMm`). At the
/// 8 dots/mm (≈203 dpi) thermal head Epson rasters are specified for, the same
/// two papers are 58 mm → **384 dots** and 80 mm → **576 dots**; [rasterWidthDots]
/// keeps the identical 80 mm boundary so text and graphics agree on one width.
///
/// 1-bit choice: **Floyd–Steinberg error diffusion** by default (the PRD asks
/// for "1-bit/dither"). Logos and photos on a 1-bit head lose all mid-tones
/// under a flat threshold; FS distributes the quantisation error so gradients
/// stay smooth at print size. A plain threshold is still available
/// (`dither: false`) for hard line-art where dither noise would only grain the
/// edges — it is also the deterministic path the packing tests assert exactly.
///
/// `GS v 0` layout emitted (Epson raster bit-image, monochrome):
///   GS v 0 m xL xH yL yH d1…dk
///   m  = 0x00 (normal density)
///   xL/xH = bytes per row = ceil(widthDots / 8), little-endian
///   yL/yH = height in dots, little-endian
///   data: row-major, MSB = leftmost dot, bit 1 = dot fired (black)
library;

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

/// Dots per mm at the 203 dpi head the receipt widths are defined against.
const int kDotsPerMm = 8;

/// Printable raster width in dots for a paper width: 58 mm → 384, 80 mm → 576.
/// Same 80 mm boundary as the text grid (see `cellsForEncoderWidth`).
int rasterWidthDots(int widthMm) => widthMm >= 80 ? 576 : 384;

/// Hard spool-safety cap on raster height, in dots (256 mm at 8 dots/mm). A
/// taller image is cropped at the bottom and the clamp is reported; a runaway
/// logo can never flood the print spool. Matches the PRD's "size/height dibatasi
/// agar spool aman".
const int kMaxRasterHeightDots = 2048;

/// Default luminance cut for 1-bit conversion (8-bit grey, 0 black … 255 white).
const int kDefaultRasterThreshold = 128;

/// A decoded bitmap: raw 8-bit RGBA, `width * height * 4` bytes, row-major.
/// Produced by a [PrintImageDecoder]; tests build it directly with synthetic
/// pixels.
class ImageBitmap {
  ImageBitmap({required this.width, required this.height, required List<int> rgba})
      : assert(width > 0 && height > 0),
        assert(rgba.length == width * height * 4),
        rgba = Uint8List.fromList(rgba);

  final int width;
  final int height;
  final Uint8List rgba;
}

/// Decoded RGBA → 8-bit luminance (Rec. 601: 0.299 R + 0.587 G + 0.114 B).
/// Nothing fancy: the thermal head is monochrome, the eye weights green most.
Uint8List luminance8(ImageBitmap img) {
  final out = Uint8List(img.width * img.height);
  final src = img.rgba;
  for (var i = 0, p = 0; i < out.length; i++, p += 4) {
    out[i] = (0.299 * src[p] + 0.587 * src[p + 1] + 0.114 * src[p + 2]).round().clamp(0, 255);
  }
  return out;
}

/// Nearest-neighbour scale of a grey plane to [targetWidth] px, aspect ratio
/// kept (`height = round(srcHeight * targetWidth / srcWidth)`, at least 1).
/// Nearest-neighbour because a receipt logo is scaled once and never animates:
/// cheapest correct choice, and integer-exact so the packing tests are stable.
({Uint8List gray, int width, int height}) scaleGrayNearest(
  Uint8List gray,
  int srcWidth,
  int srcHeight,
  int targetWidth,
) {
  assert(targetWidth > 0);
  final dstHeight = ((srcHeight * targetWidth) / srcWidth).round().clamp(1, 1 << 20);
  final out = Uint8List(targetWidth * dstHeight);
  for (var y = 0; y < dstHeight; y++) {
    final sy = (y * srcHeight) ~/ dstHeight;
    final srow = sy * srcWidth;
    final drow = y * targetWidth;
    for (var x = 0; x < targetWidth; x++) {
      out[drow + x] = gray[srow + (x * srcWidth) ~/ targetWidth];
    }
  }
  return (gray: out, width: targetWidth, height: dstHeight);
}

/// Bytes per packed row for a dot width.
int rasterRowBytes(int widthDots) => (widthDots + 7) >> 3;

/// `GS v 0` bitmap command: header + MSB-first packed rows (bit 1 = dot fired).
Uint8List gsV0Command(Uint8List packedRows, int widthDots, int heightDots) {
  final rowBytes = rasterRowBytes(widthDots);
  final out = BytesBuilder();
  out.add(<int>[
    0x1D, 0x76, 0x30, 0x00, // GS v 0 m=0 (normal density)
    rowBytes & 0xFF,
    (rowBytes >> 8) & 0xFF,
    heightDots & 0xFF,
    (heightDots >> 8) & 0xFF,
  ]);
  out.add(packedRows);
  return out.toBytes();
}

/// Flat threshold: `gray < threshold` → black dot (bit 1).
Uint8List packThreshold1Bit(List<int> gray, int width, int height, {int threshold = kDefaultRasterThreshold}) {
  final rowBytes = rasterRowBytes(width);
  final out = Uint8List(rowBytes * height);
  for (var y = 0; y < height; y++) {
    final srow = y * width;
    final drow = y * rowBytes;
    for (var x = 0; x < width; x++) {
      if (gray[srow + x] < threshold) out[drow + (x >> 3)] |= 0x80 >> (x & 7);
    }
  }
  return out;
}

/// Floyd–Steinberg: diffuse the quantisation error (7/16 right, 3/16 below-left,
/// 5/16 below, 1/16 below-right) so gradients survive on a 1-bit head.
Uint8List packFloydSteinberg1Bit(
  List<int> gray,
  int width,
  int height, {
  int threshold = kDefaultRasterThreshold,
}) {
  final rowBytes = rasterRowBytes(width);
  final out = Uint8List(rowBytes * height);
  // Rolling error rows; +2 guards the left/right neighbours after the shift.
  // Float64 matches the double arithmetic the packing tests assert exactly.
  var cur = Float64List(width + 2);
  var next = Float64List(width + 2);
  for (var y = 0; y < height; y++) {
    final srow = y * width;
    final drow = y * rowBytes;
    for (var x = 0; x < width; x++) {
      final v = gray[srow + x] + cur[x + 1];
      final bool black = v < threshold;
      if (black) out[drow + (x >> 3)] |= 0x80 >> (x & 7);
      final err = v - (black ? 0 : 255);
      cur[x + 2] += err * 7 / 16;
      next[x] += err * 3 / 16;
      next[x + 1] += err * 5 / 16;
      next[x + 2] += err * 1 / 16;
    }
    final swap = cur;
    cur = next;
    next = swap;
    next.fillRange(0, next.length, 0);
  }
  return out;
}

/// A finished raster block: the full `GS v 0` bytes plus what was decided.
class RasterImage {
  RasterImage({
    required this.bytes,
    required this.widthDots,
    required this.heightDots,
    this.clamped = false,
    this.warnings = const [],
  });

  /// Complete `GS v 0` command, header included.
  final Uint8List bytes;
  final int widthDots;
  final int heightDots;

  /// true when the image was cropped to respect a height limit.
  final bool clamped;

  /// Human-readable honesty lines (a clamp, always reported).
  final List<String> warnings;
}

/// Decode [src] to a raster block for [targetWidthDots] (≤ the printable width).
///
/// [maxHeightMm] is the block's declared limit; [maxHeightDots] an explicit dot
/// limit; the hard [kMaxRasterHeightDots] always applies. The lowest wins; a
/// crop is reported in [RasterImage.warnings] and never silent.
RasterImage encodeRasterImage(
  ImageBitmap src, {
  required int targetWidthDots,
  int? maxHeightMm,
  int? maxHeightDots,
  bool dither = true,
  int threshold = kDefaultRasterThreshold,
}) {
  final scaled = scaleGrayNearest(luminance8(src), src.width, src.height, targetWidthDots);
  final width = scaled.width;

  int? cap;
  var clampedBy = '';
  void consider(int dots, String why) {
    if (dots <= 0) return;
    if (cap == null || dots < cap!) {
      cap = dots;
      clampedBy = why;
    }
  }

  consider(kMaxRasterHeightDots, 'the $kMaxRasterHeightDots-dot spool-safety limit');
  if (maxHeightDots != null) consider(maxHeightDots, 'the declared maxHeightDots ($maxHeightDots dots)');
  if (maxHeightMm != null) consider(maxHeightMm * kDotsPerMm, 'the declared maxHeightMm (${maxHeightMm}mm)');

  var height = scaled.height;
  final warnings = <String>[];
  var clamped = false;
  if (cap != null && height > cap!) {
    warnings.add('image cropped to $cap dots ($clampedBy).');
    height = cap!;
    clamped = true;
  }

  final cropped = Uint8List.sublistView(scaled.gray, 0, width * height);
  final packed = dither
      ? packFloydSteinberg1Bit(cropped, width, height, threshold: threshold)
      : packThreshold1Bit(cropped, width, height, threshold: threshold);

  return RasterImage(
    bytes: gsV0Command(packed, width, height),
    widthDots: width,
    heightDots: height,
    clamped: clamped,
    warnings: warnings,
  );
}

// ---------------------------------------------------------------------------
// decode / asset seams
// ---------------------------------------------------------------------------

/// Raw encoded image bytes → pixels. The only seam that touches Flutter; tests
/// substitute a fake that returns synthetic [ImageBitmap]s.
abstract class PrintImageDecoder {
  const PrintImageDecoder();

  /// null when the bytes are not a decodable image (never throws).
  Future<ImageBitmap?> decode(Uint8List bytes);
}

/// Production decoder — Flutter's built-in codec, no pub dependency.
class FlutterPrintImageDecoder extends PrintImageDecoder {
  const FlutterPrintImageDecoder();

  @override
  Future<ImageBitmap?> decode(Uint8List bytes) async {
    ui.Codec? codec;
    ui.Image? image;
    try {
      codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      image = frame.image;
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (data == null) return null;
      return ImageBitmap(
        width: image.width,
        height: image.height,
        rgba: data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      );
    } catch (_) {
      return null;
    } finally {
      image?.dispose();
      codec?.dispose();
    }
  }
}

/// assetKey → encoded image bytes. The media cache owns the real mapping
/// (`local_media_assets.asset_key → local_path`); this seam keeps the encoder
/// free of the DB.
abstract class PrintImageSource {
  const PrintImageSource();

  /// null when the asset is not cached / unreadable (never throws).
  Future<Uint8List?> bytesFor(String assetKey);
}

/// Filesystem-backed source. [pathFor] is the hook for the media-cache index
/// (`local_media_assets`); without it, `assetKey` is treated as a path relative
/// to [baseDir] (the media root, e.g. `/app-data/media/{tenant}`).
class FilePrintImageSource extends PrintImageSource {
  FilePrintImageSource(this.baseDir, {this.pathFor});

  final Directory baseDir;
  final String Function(String assetKey)? pathFor;

  @override
  Future<Uint8List?> bytesFor(String assetKey) async {
    try {
      final path = pathFor?.call(assetKey) ?? '${baseDir.path}/$assetKey';
      final file = File(path);
      if (!await file.exists()) return null;
      return await file.readAsBytes();
    } catch (_) {
      return null;
    }
  }
}
