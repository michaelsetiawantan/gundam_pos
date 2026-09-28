/// ESC/POS command encoder — dependency-free.
///
/// Turns a rendered ticket (plain text lines + structured QR/BARCODE/IMAGE
/// entries) into real ESC/POS bytes for a thermal printer. Shared by the
/// network :9100 transport and the Bluetooth SPP transport.
///
/// Commands used (Epson-compatible):
///   ESC @        initialise
///   ESC t n      code page
///   ESC a n      align (0 left / 1 centre / 2 right)
///   ESC E n      bold
///   GS  ! n      character size (0x00 normal, 0x11 double w+h)
///   ESC d n      feed n lines
///   GS V m       cut (0 full, 1 partial)
///   GS ( k …     QR code (model 2) — real bytes, no dependency
///   GS k m n …   barcode (CODE128 / CODE39 / EAN13)
///
/// IMAGE blocks cannot be rasterised without an image dependency, so they emit
/// a clearly-labelled `[IMAGE <assetKey>]` text line rather than nothing.
library;

import 'package:gundam_pos/logic/print_format_render.dart';
import 'print_broker.dart';

const int _esc = 0x1B;
const int _gs = 0x1D;
const int _lf = 0x0A;

/// Cell width this encoder was built for (58 mm = 32 cells, 80 mm = 48). Used by
/// callers that need the printable width; the renderer already pads lines.
int cellsForEncoderWidth(int widthMm) => widthMm >= 80 ? 48 : 32;

/// The documented default ESC/POS dialect. Every printer without a recognised
/// `protocol` string is encoded with this.
const String kDefaultEscPosDialect = 'ESC/POS';

/// Dialects this build can actually encode. Only the Epson-compatible default is
/// implemented; a printer reporting anything else still prints with the default
/// (never blocked) and the unknown value is surfaced through the alert path.
const Set<String> kKnownDialects = {kDefaultEscPosDialect};

/// Canonicalise a printer `protocol`/`dialect` string. `ESCPOS`, `EPSON` and
/// `ESC/POS` all mean the default; empty/absent means the default; anything else
/// is returned as-is (upper-cased) so it can be reported, not silently ignored.
String normalizeDialect(String? raw) {
  final v = (raw ?? '').trim().toUpperCase().replaceAll(RegExp(r'[_\s]+'), '/').replaceAll(RegExp(r'/+'), '/');
  if (v.isEmpty) return kDefaultEscPosDialect;
  if (v == 'ESCPOS' || v == 'EPSON') return kDefaultEscPosDialect;
  return v;
}

bool isKnownDialect(String dialect) => kKnownDialects.contains(dialect);

/// Result of encoding a ticket: the bytes plus what the encoder had to decide
/// (dialect it selected, and how many image blocks it skipped for lack of raster
/// support) so the caller can report honestly instead of guessing.
class EscPosEncode {
  const EscPosEncode({required this.bytes, required this.dialect, required this.dialectKnown, this.skippedImages = 0});

  final List<int> bytes;
  final String dialect;
  final bool dialectKnown;
  final int skippedImages;
}

/// A fluent ESC/POS byte builder. Every method appends and returns `this`.
class EscPosEncoder {
  EscPosEncoder({this.widthMm = 80, this.dialect = kDefaultEscPosDialect});

  final int widthMm;

  /// Selected dialect. Only [kDefaultEscPosDialect] changes byte output today;
  /// an unknown value falls back to the default behaviour.
  final String dialect;
  final List<int> _b = <int>[];

  List<int> get bytes => List<int>.unmodifiable(_b);

  /// ESC @ — reset the printer to its power-on defaults.
  EscPosEncoder init() {
    _b.addAll(const [_esc, 0x40]);
    return this;
  }

  /// ESC t n — select a code page (e.g. 0 = CP437). n is 0..255.
  EscPosEncoder codePage(int n) {
    _b.addAll([_esc, 0x74, n & 0xFF]);
    return this;
  }

  /// ESC a n — 0 left, 1 centre, 2 right.
  EscPosEncoder align(int n) {
    _b.addAll([_esc, 0x61, n.clamp(0, 2)]);
    return this;
  }

  /// ESC E n — bold on/off.
  EscPosEncoder bold(bool on) {
    _b.addAll([_esc, 0x45, on ? 1 : 0]);
    return this;
  }

  /// GS ! n — character size. Use [sizeDouble] / [sizeNormal].
  EscPosEncoder size(int n) {
    _b.addAll([_gs, 0x21, n & 0xFF]);
    return this;
  }

  /// GS ! 0x11 — double width AND height (the CONTRACT `size: DOUBLE`).
  EscPosEncoder doubleSize() => size(0x11);

  /// GS ! 0x00 — normal size.
  EscPosEncoder normalSize() => size(0x00);

  /// Raw text with no trailing feed. Non-Latin-1 runes become `?`.
  EscPosEncoder raw(String text) {
    _b.addAll(_encodeText(text));
    return this;
  }

  /// A text line: the encoded text followed by LF.
  EscPosEncoder line(String text) {
    _b.addAll(_encodeText(text));
    _b.add(_lf);
    return this;
  }

  /// ESC d n — print and feed n lines.
  EscPosEncoder feed([int lines = 1]) {
    _b.addAll([_esc, 0x64, lines.clamp(0, 255)]);
    return this;
  }

  /// GS V m — cut. `partial` selects a partial cut where the model supports it.
  EscPosEncoder cut({bool partial = false}) {
    _b.addAll([_gs, 0x56, partial ? 0x01 : 0x00]);
    return this;
  }

  /// Real QR code (Epson GS ( k, model 2, EC level L). [sizeMm] picks a module
  /// size; the printer does the encoding.
  EscPosEncoder qr(String data, {int sizeMm = 20}) {
    if (data.isEmpty) return this;
    final payload = _encodeText(data);
    final module = (sizeMm ~/ 4).clamp(1, 8);
    _qrCmd(const [0x31, 0x41, 50, 0]); // model 2
    _qrCmd([0x31, 0x43, module]); // module size
    _qrCmd(const [0x31, 0x45, 48]); // error correction L
    final n = payload.length + 3;
    _b.addAll([_gs, 0x28, 0x6B, n & 0xFF, (n >> 8) & 0xFF, 0x31, 0x50, 0x30, ...payload]);
    _qrCmd(const [0x31, 0x51, 0x30]); // print
    return this;
  }

  /// Barcode via GS k. CODE128 (default), CODE39 and EAN13 are mapped; anything
  /// else falls back to a labelled text line so the value is never lost.
  EscPosEncoder barcode(String data, {String? symbology}) {
    if (data.isEmpty) return this;
    final m = switch ((symbology ?? 'CODE128').toUpperCase()) {
      'CODE128' => 73,
      'CODE39' => 69,
      'EAN13' => 67,
      _ => null,
    };
    if (m == null) return line('[BARCODE ${symbology ?? 'UNKNOWN'}] $data');
    final payload = _encodeText(data);
    final n = payload.length.clamp(1, 255);
    _b.addAll([_gs, 0x6B, m, n, ...payload]);
    _b.add(_lf);
    return this;
  }

  /// IMAGE without a rasteriser → a labelled placeholder, never silent.
  EscPosEncoder imagePlaceholder(String assetKey) => line('[IMAGE $assetKey]');

  /// IMAGE on a printer with no raster capability → skipped, labelled.
  EscPosEncoder imageSkipped(String assetKey) => line('[IMAGE $assetKey skipped: no raster support]');

  void _qrCmd(List<int> payload) {
    final n = payload.length;
    _b.addAll([_gs, 0x28, 0x6B, n & 0xFF, (n >> 8) & 0xFF, ...payload]);
  }
}

  /// Encode a rendered [job] as one ESC/POS byte stream: the printer is reset and
  /// configured, text lines and graphics entries are interleaved at their
  /// [PrintableEntry.atLine] offsets, then the paper is fed and cut.
  ///
  /// The dialect is taken from `job.printer.dialect` (see [normalizeDialect]); an
  /// unknown dialect still encodes with the default and is reported in the result.
  /// IMAGE entries are gated on `job.printer.supportsRasterImage` (the effective
  /// capability) and counted in [EscPosEncode.skippedImages] when skipped.
  EscPosEncode encodePrintJobDetailed(PrintJob job, {int? widthMm}) {
    final dialect = normalizeDialect(job.printer.dialect);
    final encoder = EscPosEncoder(
      widthMm: widthMm ?? job.printer.widthMm,
      dialect: dialect,
    )
      ..init()
      ..codePage(0) // CP437
      ..align(0)
      ..bold(false)
      ..normalSize();

    final entries = [...job.entries]..sort((a, b) => a.atLine.compareTo(b.atLine));
    var skippedImages = 0;
    var ei = 0;
    for (var i = 0; i < job.lines.length; i++) {
      while (ei < entries.length && entries[ei].atLine <= i) {
        skippedImages += _emitEntry(encoder, entries[ei], job.printer.supportsRasterImage);
        ei++;
      }
      encoder.line(job.lines[i]);
    }
    while (ei < entries.length) {
      skippedImages += _emitEntry(encoder, entries[ei], job.printer.supportsRasterImage);
      ei++;
    }

    encoder
      ..feed(3)
      ..cut(); // ponytail: full cut; a model without a cutter ignores it harmlessly.
    return EscPosEncode(
      bytes: encoder.bytes,
      dialect: dialect,
      dialectKnown: isKnownDialect(dialect),
      skippedImages: skippedImages,
    );
  }

  /// Convenience: just the bytes (default ESC/POS dialect, documented fallback).
  List<int> encodePrintJob(PrintJob job, {int? widthMm}) => encodePrintJobDetailed(job, widthMm: widthMm).bytes;

  /// One structural entry → ESC/POS bytes (or a labelled text fallback). Returns 1
  /// when an IMAGE block was skipped for lack of raster support, else 0.
  int _emitEntry(EscPosEncoder encoder, PrintableEntry entry, bool supportsRasterImage) {
    switch (entry.kind) {
      case PrintableKind.qr:
        encoder.qr(entry.content, sizeMm: entry.sizeMm ?? 20);
        return 0;
      case PrintableKind.barcode:
        encoder.barcode(entry.content, symbology: entry.symbology);
        return 0;
      case PrintableKind.image:
        final key = entry.assetKey ?? entry.content;
        if (!supportsRasterImage) {
          encoder.imageSkipped(key);
          return 1;
        }
        // Raster needs an image dependency the POS deliberately avoids; the block
        // is labelled so the value is never silently dropped.
        encoder.imagePlaceholder(key);
        return 0;
    }
  }

/// Latin-1 safe text encoding: every rune above 0xFF becomes `?` (never throws).
List<int> _encodeText(String s) {
  final out = <int>[];
  for (final r in s.runes) {
    out.add(r <= 0xFF ? r : 0x3F);
  }
  return out;
}
