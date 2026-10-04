/// ESC/POS command encoder — dependency-free.
///
/// Turns a rendered ticket (plain text lines + structured QR/BARCODE/IMAGE
/// entries) into real ESC/POS bytes for a thermal printer. Shared by the
/// network :9100 transport and the Bluetooth SPP / USB transports.
///
/// Vocabulary the APK carries (the web config only chooses which entry is used):
///
///   * **Dialects** ([kEscPosDialects]) — a registry of printer command sets.
///     `ESC/POS` (Epson) and `ESC/POS-CLONE` (generic clone) really differ
///     (init, cut, supported code pages, capabilities). `STAR` (Star Line Mode)
///     is a genuinely DIFFERENT command set (its own init/emphasis/size/align/
///     feed/cut/code-page commands — `ESC a n` feeds, `ESC GS a n` aligns, `ESC
///     d n` cuts) and is encoded for real. `CITIZEN` is ESC/POS-compatible: its
///     documented ESC/POS command set is byte-identical to Epson for every
///     command we emit, so it shares those bytes and only its code-page table is
///     dialect-specific. All four are implemented; any code still absent from the
///     registry falls back to the default ESC/POS output and is reported — never
///     pretending to speak a protocol the build cannot.
///   * **Code pages** ([kEscPosCodePages]) — character encoding selection via
///     `ESC t n`, with a real byte map per page. Characters a page cannot
///     represent are transliterated to ASCII, else substituted with `?`, and
///     always counted — a broken byte is never emitted.
///   * **Capabilities** — native QR (`GS ( k`), native barcode (`GS k`), cutter
///     and raster. The dialect supplies the default; the printer config may
///     override each one. Every fallback is labelled and reported.
///
/// Commands used (Epson-compatible ESC/POS):
///   ESC @        initialise
///   ESC 2        select default line spacing (generic-clone init)
///   ESC t n      code page
///   ESC a n      align (0 left / 1 centre / 2 right)
///   ESC E n      bold
///   GS  ! n      character size (0x00 normal, 0x11 double w+h)
///   ESC d n      feed n lines
///   GS V m       cut (0 full, 1 partial)  — Epson
///   GS V 66 0    feed-and-cut              — generic clone
///   GS ( k …     QR code (model 2) — real bytes, no dependency
///   GS k m n …   barcode (CODE128 / CODE39 / EAN13)
///
/// Commands used for Star Line Mode (a different command set — see
/// [kStarLineModeDialect]):
///   ESC @        initialise (command initialization)
///   ESC z n      line feed amount (0 = 3 mm, 1 = 4 mm)
///   ESC GS t n   code page (Star's own selector table)
///   ESC GS a n   align (0 left / 1 centre / 2 right)
///   ESC E / ESC F  emphasis on / off
///   ESC i n1 n2  character expansion (n1 = high ×, n2 = wide ×)
///   ESC a n      feed n lines
///   ESC d n      auto-cutter (0 full / 1 partial / 2 feed+full / 3 feed+partial)
/// Star's own QR (`ESC GS y …`) and barcode (`ESC b … RS`) commands are NOT
/// emitted by this build, so Star's QR/barcode capability stays false and those
/// blocks use the labelled text fallback.
///   GS v 0 …     raster bit-image (1-bit) — see `print_image.dart`
///
/// IMAGE blocks print as real `GS v 0` raster bytes when the printer's effective
/// `supportsRasterImage` is true AND the asset can be resolved and decoded (see
/// [encodePrintJobWithImages]). Otherwise the block is a clearly-labelled
/// `[IMAGE <assetKey>]` text line — never silently dropped, always reported.
library;

import 'package:gundam_pos/logic/print_format_render.dart';

import 'print_broker.dart';
import 'print_image.dart';

const int _esc = 0x1B;
const int _gs = 0x1D;
const int _lf = 0x0A;

/// Cell width this encoder was built for (58 mm = 32 cells, 80 mm = 48). Used by
/// callers that need the printable width; the renderer already pads lines.
int cellsForEncoderWidth(int widthMm) => widthMm >= 80 ? 48 : 32;

// ---------------------------------------------------------------------------
// dialect registry
// ---------------------------------------------------------------------------

/// What a dialect can do natively. The printer config may override each flag;
/// this is the dialect's own default.
class EscPosCapabilities {
  const EscPosCapabilities({
    required this.nativeQr,
    required this.nativeBarcode,
    required this.cutter,
    required this.raster,
  });

  /// Native 2-D barcode (`GS ( k`, model 2).
  final bool nativeQr;

  /// Native 1-D barcode (`GS k`).
  final bool nativeBarcode;

  /// Physical cutter; when false no cut command is emitted.
  final bool cutter;

  /// Can accept a raster image block.
  final bool raster;
}

/// One printer command set. `implemented` false means the app knows the family
/// by name but cannot speak it: [effectiveDialect] then returns the default
/// ESC/POS spec so output is never a pretence.
class EscPosDialect {
  const EscPosDialect({
    required this.code,
    required this.label,
    required this.implemented,
    required this.capabilities,
    required this.initBytes,
    required this.cutFull,
    this.cutPartial,
    required this.codePageSelectors,
    required this.codePagePrefix,
    required this.alignPrefix,
    required this.boldOn,
    required this.boldOff,
    required this.sizeNormal,
    required this.sizeDouble,
    required this.feedPrefix,
  });

  final String code;
  final String label;
  final bool implemented;
  final EscPosCapabilities capabilities;

  /// Reset sequence used by [EscPosEncoder.init].
  final List<int> initBytes;

  /// Full cut. `null` when the dialect has no cutter command.
  final List<int> cutFull;

  /// Partial cut; `null` → the dialect can only full-cut (downgraded + reported).
  final List<int>? cutPartial;

  /// Code-page code → THIS dialect's own selector byte. Star Line Mode numbers
  /// the code pages differently from Epson and selects them with `ESC GS t n`,
  /// so the mapping is per dialect rather than a shared `ESC t n` index. A page
  /// absent from this map has no equivalent on the dialect: the encoder falls
  /// back to CP437 and reports it rather than sending a wrong selector.
  final Map<String, int> codePageSelectors;

  /// Bytes before the selector byte of the code-page command
  /// (Epson/Citizen `ESC t`, Star `ESC GS t`).
  final List<int> codePagePrefix;

  /// Bytes before the alignment byte (Epson/Citizen `ESC a`, Star `ESC GS a`).
  final List<int> alignPrefix;

  /// Complete emphasis-ON sequence (Epson/Citizen `ESC E 1`, Star `ESC E`).
  final List<int> boldOn;

  /// Complete emphasis-OFF sequence (Epson/Citizen `ESC E 0`, Star `ESC F`).
  final List<int> boldOff;

  /// Complete normal-size sequence (Epson/Citizen `GS ! 0`, Star `ESC i 0 0`).
  final List<int> sizeNormal;

  /// Complete double width+height sequence (Epson/Citizen `GS ! 0x11`,
  /// Star `ESC i 1 1`).
  final List<int> sizeDouble;

  /// Bytes before the line count of the feed command
  /// (Epson/Citizen `ESC d`, Star `ESC a`).
  final List<int> feedPrefix;
}

/// The documented default ESC/POS dialect. Every printer without a recognised
/// `protocol` string is encoded with this.
const String kDefaultEscPosDialect = 'ESC/POS';

/// Epson ESC/POS — the full reference implementation.
const EscPosDialect kEpsonEscPosDialect = EscPosDialect(
  code: 'ESC/POS',
  label: 'Epson ESC/POS',
  implemented: true,
  capabilities: EscPosCapabilities(nativeQr: true, nativeBarcode: true, cutter: true, raster: true),
  initBytes: [_esc, 0x40],
  cutFull: [_gs, 0x56, 0x00],
  cutPartial: [_gs, 0x56, 0x01],
  codePageSelectors: {
    'CP437': 0, 'KATAKANA': 1, 'CP850': 2, 'CP860': 3, 'CP863': 4, 'CP865': 5,
    'CP1252': 16, 'CP866': 17, 'CP852': 18, 'CP858': 19,
  },
  codePagePrefix: [_esc, 0x74],
  alignPrefix: [_esc, 0x61],
  boldOn: [_esc, 0x45, 0x01],
  boldOff: [_esc, 0x45, 0x00],
  sizeNormal: [_gs, 0x21, 0x00],
  sizeDouble: [_gs, 0x21, 0x11],
  feedPrefix: [_esc, 0x64],
);

/// Generic clone ESC/POS (Xprinter/Gainscha/cheap 58 mm BLE printers). Differs
/// from Epson where it actually does:
///   * `ESC @` alone does not restore 1/6" line spacing on many clones → `ESC 2`;
///   * the cutter needs the `GS V 66 0` feed-and-cut form and cannot partial-cut;
///   * no native QR / barcode on most models (text fallback instead);
///   * only a reduced code-page set (`ESC t` 0/2/17/18/19).
const EscPosDialect kGenericCloneDialect = EscPosDialect(
  code: 'ESC/POS-CLONE',
  label: 'Generic clone ESC/POS',
  implemented: true,
  capabilities: EscPosCapabilities(nativeQr: false, nativeBarcode: false, cutter: true, raster: false),
  initBytes: [_esc, 0x40, _esc, 0x32],
  cutFull: [_gs, 0x56, 0x42, 0x00],
  cutPartial: null,
  codePageSelectors: {'CP437': 0, 'CP850': 2, 'CP866': 17, 'CP852': 18, 'CP858': 19},
  codePagePrefix: [_esc, 0x74],
  alignPrefix: [_esc, 0x61],
  boldOn: [_esc, 0x45, 0x01],
  boldOff: [_esc, 0x45, 0x00],
  sizeNormal: [_gs, 0x21, 0x00],
  sizeDouble: [_gs, 0x21, 0x11],
  feedPrefix: [_esc, 0x64],
);

/// Star Line Mode — a genuinely different command set (Star Micronics "STAR
/// Line Mode Command Specifications"), NOT an ESC/POS alias. Every byte below is
/// from that spec:
///   * init `ESC @` (command initialization) + `ESC z 1` — Star's line feed
///     amount is a memory-switch setting, so pin it to the documented 4 mm (the
///     Star value nearest ESC/POS's 1/6" ≈ 4.23 mm) for deterministic output;
///   * emphasis `ESC E` (on) / `ESC F` (off) — note: NO count byte, unlike
///     ESC/POS `ESC E n`;
///   * size `ESC i n1 n2` (n1 = high ×, n2 = wide ×) — `1 1` is double w+h;
///   * align `ESC GS a n` (Star's `ESC a n` is NOT alignment — it feeds paper);
///   * feed `ESC a n` (n lines);
///   * cut `ESC d n` (0 full at position, 1 partial at position; 2/3 feed to the
///     cut position first) — Star's cutter, not Epson's `GS V`;
///   * code page `ESC GS t n` with Star's OWN selector numbers.
///
/// Star's own 2-D/1-D code commands (`ESC GS y …` QR, `ESC b … RS` barcode) are
/// deliberately NOT emitted by this build, so QR / barcode capability is false
/// and those blocks fall back to the labelled text form rather than sending
/// Epson `GS ( k` / `GS k` bytes a Star printer would misread.
const EscPosDialect kStarLineModeDialect = EscPosDialect(
  code: 'STAR',
  label: 'Star Line Mode',
  implemented: true,
  // Cutter is real (`ESC d n`). QR/barcode are false (see above); raster is
  // false too: no Star raster bytes are emitted.
  capabilities: EscPosCapabilities(nativeQr: false, nativeBarcode: false, cutter: true, raster: false),
  initBytes: [_esc, 0x40, _esc, 0x7A, 0x01],
  cutFull: [_esc, 0x64, 0x00],
  cutPartial: [_esc, 0x64, 0x01],
  // Star's own `ESC GS t n` numbers. CP850 has NO Star equivalent (Star carries
  // CP858 — a different table — not CP850), so it is deliberately absent: the
  // encoder falls back to CP437 (n=1) and reports the gap rather than picking a
  // near-miss page and corrupting accented characters.
  codePageSelectors: {
    'CP437': 1, 'KATAKANA': 2, 'CP858': 4, 'CP852': 5, 'CP860': 6, 'CP863': 8,
    'CP865': 9, 'CP866': 10, 'CP1252': 32,
  },
  codePagePrefix: [_esc, 0x1D, 0x74],
  alignPrefix: [_esc, 0x1D, 0x61],
  boldOn: [_esc, 0x45],
  boldOff: [_esc, 0x46],
  sizeNormal: [_esc, 0x69, 0x00, 0x00],
  sizeDouble: [_esc, 0x69, 0x01, 0x01],
  feedPrefix: [_esc, 0x61],
);

/// Citizen — its documented ESC/POS command set (Citizen "Command Reference").
/// Citizen's ESC/POS emulation is byte-identical to Epson for every command this
/// encoder emits, so the sequences below are Epson's and there is no Citizen
/// deviation to guess at:
///   * init `ESC @` — same 1B 40 (Citizen's ESC @ restores STANDARD MODE too,
///     which is the state we print in);
///   * emphasis `ESC E n`, size `GS ! n`, align `ESC a n`, feed `ESC d n` — all
///     identical to Epson's documented forms;
///   * cut `GS V m` — same full (`m=0`) / partial (`m=1`); Citizen adds the
///     `GS V 65/66 n` feed-to-cut form, which we do not use;
///   * code page `ESC t n` — Citizen's own table (below). It lists CP1252 at
///     both 9 and 16, CP866 at 7 and 17, CP852 at 6 and 18; we emit the index
///     that matches Epson so the stream stays identical.
///
/// Documented Citizen nuances deliberately NOT turned into bytes here, because
/// neither changes the byte we send: `ESC a n` (align) and `GS V` (cut) are only
/// honoured at the start of a line (the encoder emits both at line start), and
/// Citizen's `ESC 2` may follow MSW5-2 (3.75 mm) instead of forcing 1/6" on newer
/// models — we never emit `ESC 2` for Citizen.
const EscPosDialect kCitizenDialect = EscPosDialect(
  code: 'CITIZEN',
  label: 'Citizen',
  implemented: true,
  // Citizen documents native QR (`GS ( k`, cn=49 fn=65/67/69/80/81 — exactly the
  // model-2 byte form this encoder emits), native barcode (`GS k`), a real
  // cutter and raster support.
  capabilities: EscPosCapabilities(nativeQr: true, nativeBarcode: true, cutter: true, raster: true),
  initBytes: [_esc, 0x40],
  cutFull: [_gs, 0x56, 0x00],
  cutPartial: [_gs, 0x56, 0x01],
  codePageSelectors: {
    'CP437': 0, 'KATAKANA': 1, 'CP850': 2, 'CP860': 3, 'CP863': 4, 'CP865': 5,
    'CP1252': 16, 'CP866': 17, 'CP852': 18, 'CP858': 19,
  },
  codePagePrefix: [_esc, 0x74],
  alignPrefix: [_esc, 0x61],
  boldOn: [_esc, 0x45, 0x01],
  boldOff: [_esc, 0x45, 0x00],
  sizeNormal: [_gs, 0x21, 0x00],
  sizeDouble: [_gs, 0x21, 0x11],
  feedPrefix: [_esc, 0x64],
);

/// The whole dialect vocabulary the APK carries, by canonical code.
const Map<String, EscPosDialect> kEscPosDialects = {
  'ESC/POS': kEpsonEscPosDialect,
  'ESC/POS-CLONE': kGenericCloneDialect,
  'STAR': kStarLineModeDialect,
  'CITIZEN': kCitizenDialect,
};

/// Every dialect code the registry knows (implemented or declared).
final Set<String> kKnownDialects = kEscPosDialects.keys.toSet();

/// Config spellings → canonical dialect code. `normalizeDialect` has already
/// upper-cased and collapsed `_`/whitespace/hyphen runs to `/` before lookup, so
/// every web spelling of a drifted code lands on one canonical value:
///   * `ESC/POS-GENERIC`  → `ESC/POS-CLONE`
///   * `STAR-LINE-MODE`   → `STAR`
///   * `CITIZEN-ESCPOS`   → `CITIZEN`
const Map<String, String> kDialectAliases = {
  'ESCPOS': 'ESC/POS',
  'EPSON': 'ESC/POS',
  'ESC/POS/EPSON': 'ESC/POS',
  'EPSON/ESCPOS': 'ESC/POS',
  'CLONE': 'ESC/POS-CLONE',
  'GENERIC': 'ESC/POS-CLONE',
  'ESCPOS/CLONE': 'ESC/POS-CLONE',
  'ESCPOS/GENERIC': 'ESC/POS-CLONE',
  'ESC/POS/CLONE': 'ESC/POS-CLONE',
  'ESC/POS/GENERIC': 'ESC/POS-CLONE',
  'XPRINTER': 'ESC/POS-CLONE',
  'GAINSCHA': 'ESC/POS-CLONE',
  'STAR/LINE': 'STAR',
  'STAR/LINE/MODE': 'STAR',
  'STARLINE': 'STAR',
  'STAR/LINE/MODE/PRINTER': 'STAR',
  'CITIZEN/ESCPOS': 'CITIZEN',
  'CITIZEN/SYSTEM': 'CITIZEN',
};

/// Canonicalise a printer `protocol`/`dialect` string. `ESCPOS`, `EPSON` and
/// `ESC/POS` mean the default; known families map to their registry code;
/// empty/absent means the default; anything else is returned as-is (upper-cased)
/// so it can be reported, not silently ignored.
///
/// `_`, whitespace and `-` all collapse to `/`, so `ESC/POS-GENERIC`,
/// `esc pos generic`, `STAR-LINE-MODE` and `CITIZEN-ESCPOS` (the web spellings)
/// resolve to the same canonical codes as the POS ones.
String normalizeDialect(String? raw) {
  final v = (raw ?? '')
      .trim()
      .toUpperCase()
      .replaceAll(RegExp(r'[_\s-]+'), '/')
      .replaceAll(RegExp(r'/+'), '/');
  if (v.isEmpty) return kDefaultEscPosDialect;
  return kDialectAliases[v] ?? v;
}

/// true when the registry carries this code (implemented OR declared).
bool isKnownDialect(String dialect) => kEscPosDialects.containsKey(dialect);

/// true only when this build really encodes the dialect.
bool isImplementedDialect(String dialect) => kEscPosDialects[dialect]?.implemented ?? false;

/// The registry entry for [code], or null for an unrecognised dialect.
EscPosDialect? dialectSpecFor(String code) => kEscPosDialects[code];

/// The dialect spec actually used to encode [code]: the entry itself when it is
/// implemented, otherwise the default ESC/POS spec. Declared-but-unimplemented
/// and unknown dialects therefore produce honest ESC/POS bytes; the caller
/// reports the gap via [isKnownDialect] / [isImplementedDialect].
EscPosDialect effectiveDialect(String code) {
  final d = kEscPosDialects[code];
  return (d != null && d.implemented) ? d : kEpsonEscPosDialect;
}

// ---------------------------------------------------------------------------
// code pages
// ---------------------------------------------------------------------------

/// The documented default code page when the config carries none (also the
/// ESC/POS power-on default).
const String kDefaultCodePage = 'CP437';

/// One character-encoding table: the `ESC t n` selector plus the byte for every
/// rune above ASCII the page can represent.
class EscPosCodePage {
  const EscPosCodePage({required this.code, required this.selector, required this.high});

  final String code;

  /// `ESC t n` value; null → the page has no selector and cannot be selected
  /// (e.g. UTF-8, which ESC/POS cannot express at all).
  final int? selector;

  /// true when ESC/POS can actually select this page (it has an `ESC t n` index).
  bool get implemented => selector != null;

  /// rune → byte for runes above 0x7F. Runecount outside this map are
  /// transliterated or substituted by the encoder.
  final Map<int, int> high;
}

/// `chars[i]` → `firstByte + i` (used to spell out the standard tables readably).
Map<int, int> _page(String chars, int firstByte) {
  final m = <int, int>{};
  final runes = chars.runes.toList();
  for (var i = 0; i < runes.length; i++) {
    m[runes[i]] = firstByte + i;
  }
  return m;
}

/// CP437 (Epson `ESC t 0`) — Latin letters only; the rest of the high range is
/// box-drawing/Greek and irrelevant to receipts.
final Map<int, int> _cp437 = {
  ..._page('ÇüéâäàåçêëèïîìÄÅ', 0x80),
  ..._page('ÉæÆôöòûùÿÖÜ¢£¥₧ƒ', 0x90),
  ..._page('áíóúñÑªº¿¬½¼¡«»', 0xA0),
};

/// CP850 (multilingual Latin-1, `ESC t 2`).
final Map<int, int> _cp850 = {
  ..._page('ÇüéâäàåçêëèïîìÄÅ', 0x80),
  ..._page('ÉæÆôöòûùÿÖÜø£Ø×ƒ', 0x90),
  ..._page('áíóúñÑªº¿®¬½¼¡«»', 0xA0),
  ..._page('ÓßÔÕõµþÞÚÛÙýÝ', 0xE0),
};

/// CP852 (Latin-2, `ESC t 18`) — the Latin letters, not the box-drawing range.
final Map<int, int> _cp852 = {
  ..._page('ÇüéâäůćçłëŐőîŹÄČ', 0x80),
  ..._page('ÉĹĺôöĽľŚśÖÜŤťŁ×č', 0x90),
  ..._page('áíóúąę', 0xA0),
};

/// CP860 (Portuguese, `ESC t 3`).
final Map<int, int> _cp860 = {
  ..._page('ÇüéâãàÁçê', 0x80),
  ..._page('É', 0x90),
  ..._page('ôõòÚù', 0x93),
  ..._page('ÕÜ', 0x99),
  ..._page('Ó', 0x9F),
  ..._page('áíóúñÑªº¿', 0xA0),
};

/// CP863 (Canadian French, `ESC t 4`) — `fc/éâÂà¶ç…`, Œ/â/ô/û/ù/… accents and the
/// £/¢ glyphs on the receipt half of the page (box-drawing/Greek tail kept for
/// completeness: the table is derived from the code page itself).
final Map<int, int> _cp863 = {
  0xc7: 0x80, 0xfc: 0x81, 0xe9: 0x82, 0xe2: 0x83, 0xc2: 0x84, 0xe0: 0x85, 0xb6: 0x86, 0xe7: 0x87,
  0xea: 0x88, 0xeb: 0x89, 0xe8: 0x8a, 0xef: 0x8b, 0xee: 0x8c, 0x2017: 0x8d, 0xc0: 0x8e, 0xa7: 0x8f,
  0xc9: 0x90, 0xc8: 0x91, 0xca: 0x92, 0xf4: 0x93, 0xcb: 0x94, 0xcf: 0x95, 0xfb: 0x96, 0xf9: 0x97,
  0xa4: 0x98, 0xd4: 0x99, 0xdc: 0x9a, 0xa2: 0x9b, 0xa3: 0x9c, 0xd9: 0x9d, 0xdb: 0x9e, 0x192: 0x9f,
  0xa6: 0xa0, 0xb4: 0xa1, 0xf3: 0xa2, 0xfa: 0xa3, 0xa8: 0xa4, 0xb8: 0xa5, 0xb3: 0xa6, 0xaf: 0xa7,
  0xce: 0xa8, 0x2310: 0xa9, 0xac: 0xaa, 0xbd: 0xab, 0xbc: 0xac, 0xbe: 0xad, 0xab: 0xae, 0xbb: 0xaf,
  0x2591: 0xb0, 0x2592: 0xb1, 0x2593: 0xb2, 0x2502: 0xb3, 0x2524: 0xb4, 0x2561: 0xb5, 0x2562: 0xb6,
  0x2556: 0xb7, 0x2555: 0xb8, 0x2563: 0xb9, 0x2551: 0xba, 0x2557: 0xbb, 0x255d: 0xbc, 0x255c: 0xbd,
  0x255b: 0xbe, 0x2510: 0xbf, 0x2514: 0xc0, 0x2534: 0xc1, 0x252c: 0xc2, 0x251c: 0xc3, 0x2500: 0xc4,
  0x253c: 0xc5, 0x255e: 0xc6, 0x255f: 0xc7, 0x255a: 0xc8, 0x2554: 0xc9, 0x2569: 0xca, 0x2566: 0xcb,
  0x2560: 0xcc, 0x2550: 0xcd, 0x256c: 0xce, 0x2567: 0xcf, 0x2568: 0xd0, 0x2564: 0xd1, 0x2565: 0xd2,
  0x2559: 0xd3, 0x2558: 0xd4, 0x2552: 0xd5, 0x2553: 0xd6, 0x256b: 0xd7, 0x256a: 0xd8, 0x2518: 0xd9,
  0x250c: 0xda, 0x2588: 0xdb, 0x2584: 0xdc, 0x258c: 0xdd, 0x2590: 0xde, 0x2580: 0xdf, 0x3b1: 0xe0,
  0xdf: 0xe1, 0x393: 0xe2, 0x3c0: 0xe3, 0x3a3: 0xe4, 0x3c3: 0xe5, 0xb5: 0xe6, 0x3c4: 0xe7,
  0x3a6: 0xe8, 0x398: 0xe9, 0x3a9: 0xea, 0x3b4: 0xeb, 0x221e: 0xec, 0x3c6: 0xed, 0x3b5: 0xee,
  0x2229: 0xef, 0x2261: 0xf0, 0xb1: 0xf1, 0x2265: 0xf2, 0x2264: 0xf3, 0x2320: 0xf4, 0x2321: 0xf5,
  0xf7: 0xf6, 0x2248: 0xf7, 0xb0: 0xf8, 0x2219: 0xf9, 0xb7: 0xfa, 0x221a: 0xfb, 0x207f: 0xfc,
  0xb2: 0xfd, 0x25a0: 0xfe, 0xa0: 0xff,
};

/// CP865 (Nordic, `ESC t 5`) — the `ÆØÅæøå`/`ÖÜÿ` block a Danish/Norwegian
/// receipt needs (CP437 with the accent slots swapped for the Nordic letters).
final Map<int, int> _cp865 = {
  0xc7: 0x80, 0xfc: 0x81, 0xe9: 0x82, 0xe2: 0x83, 0xe4: 0x84, 0xe0: 0x85, 0xe5: 0x86, 0xe7: 0x87,
  0xea: 0x88, 0xeb: 0x89, 0xe8: 0x8a, 0xef: 0x8b, 0xee: 0x8c, 0xec: 0x8d, 0xc4: 0x8e, 0xc5: 0x8f,
  0xc9: 0x90, 0xe6: 0x91, 0xc6: 0x92, 0xf4: 0x93, 0xf6: 0x94, 0xf2: 0x95, 0xfb: 0x96, 0xf9: 0x97,
  0xff: 0x98, 0xd6: 0x99, 0xdc: 0x9a, 0xf8: 0x9b, 0xa3: 0x9c, 0xd8: 0x9d, 0x20a7: 0x9e, 0x192: 0x9f,
  0xe1: 0xa0, 0xed: 0xa1, 0xf3: 0xa2, 0xfa: 0xa3, 0xf1: 0xa4, 0xd1: 0xa5, 0xaa: 0xa6, 0xba: 0xa7,
  0xbf: 0xa8, 0x2310: 0xa9, 0xac: 0xaa, 0xbd: 0xab, 0xbc: 0xac, 0xa1: 0xad, 0xab: 0xae, 0xa4: 0xaf,
  0x2591: 0xb0, 0x2592: 0xb1, 0x2593: 0xb2, 0x2502: 0xb3, 0x2524: 0xb4, 0x2561: 0xb5, 0x2562: 0xb6,
  0x2556: 0xb7, 0x2555: 0xb8, 0x2563: 0xb9, 0x2551: 0xba, 0x2557: 0xbb, 0x255d: 0xbc, 0x255c: 0xbd,
  0x255b: 0xbe, 0x2510: 0xbf, 0x2514: 0xc0, 0x2534: 0xc1, 0x252c: 0xc2, 0x251c: 0xc3, 0x2500: 0xc4,
  0x253c: 0xc5, 0x255e: 0xc6, 0x255f: 0xc7, 0x255a: 0xc8, 0x2554: 0xc9, 0x2569: 0xca, 0x2566: 0xcb,
  0x2560: 0xcc, 0x2550: 0xcd, 0x256c: 0xce, 0x2567: 0xcf, 0x2568: 0xd0, 0x2564: 0xd1, 0x2565: 0xd2,
  0x2559: 0xd3, 0x2558: 0xd4, 0x2552: 0xd5, 0x2553: 0xd6, 0x256b: 0xd7, 0x256a: 0xd8, 0x2518: 0xd9,
  0x250c: 0xda, 0x2588: 0xdb, 0x2584: 0xdc, 0x258c: 0xdd, 0x2590: 0xde, 0x2580: 0xdf, 0x3b1: 0xe0,
  0xdf: 0xe1, 0x393: 0xe2, 0x3c0: 0xe3, 0x3a3: 0xe4, 0x3c3: 0xe5, 0xb5: 0xe6, 0x3c4: 0xe7,
  0x3a6: 0xe8, 0x398: 0xe9, 0x3a9: 0xea, 0x3b4: 0xeb, 0x221e: 0xec, 0x3c6: 0xed, 0x3b5: 0xee,
  0x2229: 0xef, 0x2261: 0xf0, 0xb1: 0xf1, 0x2265: 0xf2, 0x2264: 0xf3, 0x2320: 0xf4, 0x2321: 0xf5,
  0xf7: 0xf6, 0x2248: 0xf7, 0xb0: 0xf8, 0x2219: 0xf9, 0xb7: 0xfa, 0x221a: 0xfb, 0x207f: 0xfc,
  0xb2: 0xfd, 0x25a0: 0xfe, 0xa0: 0xff,
};

/// CP866 (Cyrillic DOS, `ESC t 17`): А–Я at 0x80, а–п at 0xA0, р–я at 0xE0,
/// Ё/ё at 0xF0/0xF1.
final Map<int, int> _cp866 = () {
  final m = <int, int>{};
  const upper = 'АБВГДЕЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯ';
  const lower1 = 'абвгдежзийклмноп';
  const lower2 = 'рстуфхцчшщъыьэюя';
  for (var i = 0; i < 32; i++) {
    m[upper.runes.elementAt(i)] = 0x80 + i;
  }
  for (var i = 0; i < 16; i++) {
    m[lower1.runes.elementAt(i)] = 0xA0 + i;
  }
  for (var i = 0; i < 16; i++) {
    m[lower2.runes.elementAt(i)] = 0xE0 + i;
  }
  m[0x0401] = 0xF0; // Ё
  m[0x0451] = 0xF1; // ё
  return m;
}();

/// CP858 = CP850 with € at 0xD5 (`ESC t 19`).
final Map<int, int> _cp858 = {..._cp850, 0x20AC: 0xD5};

/// WPC1252 / CP1252 (`ESC t 16`): identical to Latin-1 in 0xA0–0xFF plus the
/// 0x80–0x9F typographic block.
final Map<int, int> _cp1252 = () {
  final m = <int, int>{};
  for (var r = 0xA0; r <= 0xFF; r++) {
    m[r] = r;
  }
  m[0x20AC] = 0x80; // €
  m[0x201A] = 0x82; // ‚
  m[0x0192] = 0x83; // ƒ
  m[0x201E] = 0x84; // „
  m[0x2026] = 0x85; // …
  m[0x2020] = 0x86; // †
  m[0x2021] = 0x87; // ‡
  m[0x02C6] = 0x88; // ˆ
  m[0x2030] = 0x89; // ‰
  m[0x0160] = 0x8A; // Š
  m[0x2039] = 0x8B; // ‹
  m[0x0152] = 0x8C; // Œ
  m[0x017D] = 0x8E; // Ž
  m[0x2018] = 0x91; // ‘
  m[0x2019] = 0x92; // ’
  m[0x201C] = 0x93; // “
  m[0x201D] = 0x94; // ”
  m[0x2022] = 0x95; // •
  m[0x2013] = 0x96; // –
  m[0x2014] = 0x97; // —
  m[0x02DC] = 0x98; // ˜
  m[0x2122] = 0x99; // ™
  m[0x0161] = 0x9A; // š
  m[0x203A] = 0x9B; // ›
  m[0x0153] = 0x9C; // œ
  m[0x017E] = 0x9E; // ž
  m[0x0178] = 0x9F; // Ÿ
  return m;
}();

/// ESC/POS Katakana (`ESC t 1`): half-width katakana U+FF61–U+FF9F → 0xA1–0xDF
/// (JIS X 0201).
final Map<int, int> _katakana = () {
  final m = <int, int>{};
  for (var i = 0; i <= 0x3E; i++) {
    m[0xFF61 + i] = 0xA1 + i;
  }
  return m;
}();

/// The code-page vocabulary the APK carries, by canonical code.
///
/// UTF-8 is DECLARED and honestly NOT implemented: ESC/POS selects a single-byte
/// code page with `ESC t n` and has no UTF-8 page, so a config that asks for it
/// is reported and falls back to CP437 rather than emitting multi-byte garbage.
final Map<String, EscPosCodePage> kEscPosCodePages = {
  'CP437': EscPosCodePage(code: 'CP437', selector: 0, high: _cp437),
  'KATAKANA': EscPosCodePage(code: 'KATAKANA', selector: 1, high: _katakana),
  'CP850': EscPosCodePage(code: 'CP850', selector: 2, high: _cp850),
  'CP860': EscPosCodePage(code: 'CP860', selector: 3, high: _cp860),
  'CP863': EscPosCodePage(code: 'CP863', selector: 4, high: _cp863),
  'CP865': EscPosCodePage(code: 'CP865', selector: 5, high: _cp865),
  'CP866': EscPosCodePage(code: 'CP866', selector: 17, high: _cp866),
  'CP852': EscPosCodePage(code: 'CP852', selector: 18, high: _cp852),
  'CP858': EscPosCodePage(code: 'CP858', selector: 19, high: _cp858),
  'CP1252': EscPosCodePage(code: 'CP1252', selector: 16, high: _cp1252),
  // No ESC/POS index: unfixable by design, reported and never selected.
  'UTF-8': const EscPosCodePage(code: 'UTF-8', selector: null, high: {}),
};

/// Config spellings → canonical code page (looked up after stripping `-`/spaces).
const Map<String, String> kCodePageAliases = {
  'PC437': 'CP437',
  '437': 'CP437',
  'IBM437': 'CP437',
  'PC850': 'CP850',
  '850': 'CP850',
  'DOSLATIN1': 'CP850',
  'PC852': 'CP852',
  '852': 'CP852',
  'PC858': 'CP858',
  '858': 'CP858',
  'CP850EURO': 'CP858',
  'PC860': 'CP860',
  '860': 'CP860',
  'PC863': 'CP863',
  '863': 'CP863',
  'CANADIAN': 'CP863',
  'CANADIANFRENCH': 'CP863',
  'PC865': 'CP865',
  '865': 'CP865',
  'NORDIC': 'CP865',
  'PC866': 'CP866',
  '866': 'CP866',
  'PC1252': 'CP1252',
  'WPC1252': 'CP1252',
  '1252': 'CP1252',
  'WINDOWS1252': 'CP1252',
  'LATIN1': 'CP1252',
  'ISO88591': 'CP1252',
  'KANA': 'KATAKANA',
  'CP932': 'KATAKANA',
  'JIS': 'KATAKANA',
  // UTF-8 is recognised so it can be reported as unsupported, never silently
  // treated as a page the build could speak.
  'UTF8': 'UTF-8',
  'UTF': 'UTF-8',
  'UNICODE': 'UTF-8',
};

/// Canonicalise a configured code page string (`cp-437`, `Windows-1252`, …).
String normalizeCodePage(String? raw) {
  final v = (raw ?? '').toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
  if (v.isEmpty) return kDefaultCodePage;
  return kCodePageAliases[v] ?? v;
}

/// Outcome of resolving a configured code page: the page to use (CP437 when the
/// requested one is unknown), the canonical requested code, and whether it was
/// recognised.
class CodePageResolution {
  const CodePageResolution({required this.page, required this.requested, required this.known});

  final EscPosCodePage page;

  /// Canonical code requested by the config, or null when the config carried none.
  final String? requested;
  final bool known;
}

/// Resolve [raw] to a code page. Empty/absent → CP437 (documented default),
/// reported as `requested == null`; unknown → CP437 with `known == false`.
CodePageResolution resolveCodePage(String? raw) {
  final trimmed = (raw ?? '').trim();
  final fallback = kEscPosCodePages[kDefaultCodePage]!;
  if (trimmed.isEmpty) {
    return CodePageResolution(page: fallback, requested: null, known: true);
  }
  final code = normalizeCodePage(trimmed);
  final page = kEscPosCodePages[code];
  return CodePageResolution(page: page ?? fallback, requested: code, known: page != null);
}

/// ASCII fold used when the chosen page cannot represent a rune (transliterate
/// before substituting `?`). Covers the Latin-1 letters a receipt may carry.
const Map<int, String> kAsciiFold = {
  0x00C0: 'A', 0x00C1: 'A', 0x00C2: 'A', 0x00C3: 'A', 0x00C4: 'A', 0x00C5: 'A', 0x00C6: 'AE',
  0x00C7: 'C', 0x00C8: 'E', 0x00C9: 'E', 0x00CA: 'E', 0x00CB: 'E', 0x00CC: 'I', 0x00CD: 'I',
  0x00CE: 'I', 0x00CF: 'I', 0x00D1: 'N', 0x00D2: 'O', 0x00D3: 'O', 0x00D4: 'O', 0x00D5: 'O',
  0x00D6: 'O', 0x00D8: 'O', 0x00D9: 'U', 0x00DA: 'U', 0x00DB: 'U', 0x00DC: 'U', 0x00DD: 'Y',
  0x00DF: 'ss',
  0x00E0: 'a', 0x00E1: 'a', 0x00E2: 'a', 0x00E3: 'a', 0x00E4: 'a', 0x00E5: 'a', 0x00E6: 'ae',
  0x00E7: 'c', 0x00E8: 'e', 0x00E9: 'e', 0x00EA: 'e', 0x00EB: 'e', 0x00EC: 'i', 0x00ED: 'i',
  0x00EE: 'i', 0x00EF: 'i', 0x00F1: 'n', 0x00F2: 'o', 0x00F3: 'o', 0x00F4: 'o', 0x00F5: 'o',
  0x00F6: 'o', 0x00F8: 'o', 0x00F9: 'u', 0x00FA: 'u', 0x00FB: 'u', 0x00FC: 'u', 0x00FD: 'y',
  0x00FF: 'y',
};

// ---------------------------------------------------------------------------
// encoder
// ---------------------------------------------------------------------------

/// Result of encoding a ticket: the bytes plus everything the encoder had to
/// decide (dialect, code page, substitutions, skipped/failed blocks) so the
/// caller can report honestly instead of guessing.
class EscPosEncode {
  const EscPosEncode({
    required this.bytes,
    required this.dialect,
    required this.dialectKnown,
    required this.dialectImplemented,
    required this.codePage,
    required this.codePageKnown,
    required this.codePageSupportedByDialect,
    this.transliteratedChars = 0,
    this.substitutedChars = 0,
    this.qrFallbacks = 0,
    this.barcodeFallbacks = 0,
    this.skippedImages = 0,
    this.rasterImages = 0,
    this.placeholderImages = 0,
    this.cutEmitted = false,
    this.warnings = const [],
  });

  final List<int> bytes;

  /// Canonical dialect requested by the config.
  final String dialect;

  /// The code is in the registry (implemented or declared).
  final bool dialectKnown;

  /// This build really encodes the dialect.
  final bool dialectImplemented;

  /// Canonical code page actually used.
  final String codePage;

  /// The requested code page was in the registry.
  final bool codePageKnown;

  /// The dialect exposes the requested page's `ESC t n` selector.
  final bool codePageSupportedByDialect;

  /// Runes replaced by an ASCII fold (page could not represent them).
  final int transliteratedChars;

  /// Runes replaced by `?` (no fold available).
  final int substitutedChars;

  /// QR entries rendered as a labelled text line (no native QR).
  final int qrFallbacks;

  /// Barcode entries rendered as a labelled text line (no native barcode).
  final int barcodeFallbacks;

  /// IMAGE blocks skipped for lack of raster support.
  final int skippedImages;

  /// IMAGE blocks emitted as real `GS v 0` raster bytes.
  final int rasterImages;

  /// IMAGE blocks that fell back to a labelled placeholder (raster-capable
  /// printer, but the asset was missing/unreadable/undecodable).
  final int placeholderImages;

  /// Whether a cutter command reached the stream.
  final bool cutEmitted;

  /// Human-readable honesty lines (unknown dialect/page, substitutions, …).
  final List<String> warnings;
}

/// A fluent ESC/POS byte builder. Every method appends and returns `this`.
class EscPosEncoder {
  EscPosEncoder({this.widthMm = 80, String dialect = kDefaultEscPosDialect, String? codePage})
      : dialect = normalizeDialect(dialect),
        dialectSpec = effectiveDialect(normalizeDialect(dialect)) {
    _applyCodePage(resolveCodePage(codePage));
  }

  final int widthMm;

  /// Canonical dialect code requested (may be unknown/unimplemented).
  final String dialect;

  /// The spec actually driving byte output (default ESC/POS for unknown or
  /// declared-but-unimplemented dialects).
  final EscPosDialect dialectSpec;

  final List<int> _b = <int>[];

  EscPosCodePage _codePage = kEscPosCodePages[kDefaultCodePage]!;
  String? _requestedCodePage;
  EscPosCodePage? _requestedPage;
  bool _codePageKnown = true;
  bool _codePageSupportedByDialect = true;

  /// The selector byte to emit for [_codePage] in this dialect's code-page
  /// command (the dialect's own numbering, not the Epson `ESC t n` index).
  int _codePageSelector = 0;
  int _transliterated = 0;
  int _substituted = 0;

  List<int> get bytes => List<int>.unmodifiable(_b);

  /// The code page currently mapping text.
  EscPosCodePage get activeCodePage => _codePage;

  /// Runes transliterated to ASCII so far.
  int get transliteratedChars => _transliterated;

  /// Runes substituted with `?` so far.
  int get substitutedChars => _substituted;

  /// ESC @ — reset the printer to its power-on defaults (dialect-specific; the
  /// generic clone also restores its default line spacing).
  EscPosEncoder init() {
    _b.addAll(dialectSpec.initBytes);
    return this;
  }

  /// Select a raw code page index using the dialect's code-page command
  /// (Epson/Citizen `ESC t n`, Star `ESC GS t n`). Prefer [selectCodePage], which
  /// resolves the configured code and the dialect's supported set.
  EscPosEncoder codePage(int n) {
    _b.addAll([...dialectSpec.codePagePrefix, n & 0xFF]);
    return this;
  }

  /// Resolve the configured code page (tolerant: absent → CP437, unknown →
  /// CP437, unsupported by the dialect → CP437) and emit its selector in the
  /// dialect's code-page command. Never throws.
  EscPosEncoder selectCodePage(String? raw) {
    _applyCodePage(resolveCodePage(raw));
    _b.addAll([...dialectSpec.codePagePrefix, _codePageSelector & 0xFF]);
    return this;
  }

  /// Align — 0 left, 1 centre, 2 right. Epson/Citizen `ESC a n`; Star
  /// `ESC GS a n` (Star's `ESC a n` feeds paper, not aligns it).
  EscPosEncoder align(int n) {
    _b.addAll([...dialectSpec.alignPrefix, n.clamp(0, 2)]);
    return this;
  }

  /// Emphasis on/off. Epson/Citizen `ESC E n`; Star `ESC E` / `ESC F`.
  EscPosEncoder bold(bool on) {
    _b.addAll(on ? dialectSpec.boldOn : dialectSpec.boldOff);
    return this;
  }

  /// Character size as raw ESC/POS `GS ! n`. This is the ESC/POS form only —
  /// Star Line Mode has no `GS !` and expresses size with `ESC i n1 n2`, so use
  /// [doubleSize] / [normalSize], which are dialect-aware.
  EscPosEncoder size(int n) {
    _b.addAll([_gs, 0x21, n & 0xFF]);
    return this;
  }

  /// Double width AND height (the CONTRACT `size: DOUBLE`):
  /// `GS ! 0x11` on Epson/Citizen, `ESC i 1 1` on Star.
  EscPosEncoder doubleSize() {
    _b.addAll(dialectSpec.sizeDouble);
    return this;
  }

  /// Normal size: `GS ! 0x00` on Epson/Citizen, `ESC i 0 0` on Star.
  EscPosEncoder normalSize() {
    _b.addAll(dialectSpec.sizeNormal);
    return this;
  }

  /// Raw text with no trailing feed, encoded with the active code page.
  EscPosEncoder raw(String text) {
    _b.addAll(_encode(text));
    return this;
  }

  /// A text line: the encoded text followed by LF.
  EscPosEncoder line(String text) {
    _b.addAll(_encode(text));
    _b.add(_lf);
    return this;
  }

  /// Print and feed n lines. Epson/Citizen `ESC d n`; Star `ESC a n` (Star's
  /// `ESC d n` is the auto-cutter, so the two commands swap roles).
  EscPosEncoder feed([int lines = 1]) {
    _b.addAll([...dialectSpec.feedPrefix, lines.clamp(0, 255)]);
    return this;
  }

  /// Cut. The dialect supplies the byte sequence; a dialect that cannot
  /// partial-cut is downgraded to its full cut.
  /// Kick the cash drawer (ESC p m t1 t2). Standard pulse: pin 2, ~100 ms on /
  /// ~500 ms off — the sequence every RJ11 drawer expects.
  EscPosEncoder pulse() {
    // Standard ESC/POS drawer pulse (pin 2, ~100ms on / ~500ms off).
    _b.addAll(const [0x1B, 0x70, 0x00, 0x19, 0xFA]);
    return this;
  }

  EscPosEncoder cut({bool partial = false}) {
    final seq = (partial ? dialectSpec.cutPartial : null) ?? dialectSpec.cutFull;
    if (seq.isNotEmpty) _b.addAll(seq);
    return this;
  }

  /// Real QR code (ESC/POS `GS ( k`, model 2, EC level L). [sizeMm] picks a
  /// module size; the printer does the encoding. Star Line Mode's own QR
  /// commands are not emitted by this build, so its capability gates this off
  /// and [qrTextFallback] is used instead.
  EscPosEncoder qr(String data, {int sizeMm = 20}) {
    if (data.isEmpty) return this;
    final payload = _encode(data);
    final module = (sizeMm ~/ 4).clamp(1, 8);
    _qrCmd(const [0x31, 0x41, 50, 0]); // model 2
    _qrCmd([0x31, 0x43, module]); // module size
    _qrCmd(const [0x31, 0x45, 48]); // error correction L
    final n = payload.length + 3;
    _b.addAll([_gs, 0x28, 0x6B, n & 0xFF, (n >> 8) & 0xFF, 0x31, 0x50, 0x30, ...payload]);
    _qrCmd(const [0x31, 0x51, 0x30]); // print
    return this;
  }

  /// QR on a printer with no native QR support → a labelled text line, so the
  /// value is never silently dropped.
  EscPosEncoder qrTextFallback(String data) => line('[QR $data]');

  /// Barcode via `GS k`. CODE128 (default), CODE39 and EAN13 are mapped; anything
  /// else falls back to a labelled text line so the value is never lost. Star
  /// Line Mode's own `ESC b` command is not emitted by this build, so its
  /// capability gates this off and [barcodeTextFallback] is used instead.
  EscPosEncoder barcode(String data, {String? symbology}) {
    if (data.isEmpty) return this;
    final sym = (symbology ?? 'CODE128').toUpperCase();
    final m = switch (sym) {
      'CODE128' => 73,
      'CODE39' => 69,
      'EAN13' => 67,
      _ => null,
    };
    if (m == null) return line('[BARCODE $sym] $data');
    final payload = _encode(data);
    final n = payload.length.clamp(1, 255);
    _b.addAll([_gs, 0x6B, m, n, ...payload]);
    _b.add(_lf);
    return this;
  }

  /// Barcode on a printer with no native barcode support → a labelled text line.
  EscPosEncoder barcodeTextFallback(String data, {String? symbology}) =>
      line('[BARCODE ${(symbology ?? 'CODE128').toUpperCase()}] $data');

  /// IMAGE without a rasteriser → a labelled placeholder, never silent.
  EscPosEncoder imagePlaceholder(String assetKey) => line('[IMAGE $assetKey]');

  /// IMAGE on a printer with no raster capability → skipped, labelled.
  EscPosEncoder imageSkipped(String assetKey) => line('[IMAGE $assetKey skipped: no raster support]');

  /// Appends a pre-encoded raster block (a full `GS v 0` command from
  /// [encodeRasterImage]). The caller owns the decode; see
  /// [encodePrintJobWithImages] for the async resolution path.
  EscPosEncoder raster(List<int> gsV0Bytes) {
    _b.addAll(gsV0Bytes);
    return this;
  }

  void _applyCodePage(CodePageResolution res) {
    _requestedCodePage = res.requested;
    _requestedPage = res.requested == null ? null : res.page;
    _codePageKnown = res.known;
    // The dialect's own selector for this page. A page the dialect cannot select
    // (unknown page, a page with no equivalent on the dialect — Star has no
    // CP850 — or UTF-8, which has no single-byte encoding at all) falls back to
    // CP437 and is reported by the caller rather than sending a wrong selector.
    final sel = res.known ? dialectSpec.codePageSelectors[res.page.code] : null;
    _codePageSupportedByDialect = sel != null;
    if (sel != null) {
      _codePage = res.page;
      _codePageSelector = sel;
    } else {
      _codePage = kEscPosCodePages[kDefaultCodePage]!;
      _codePageSelector = dialectSpec.codePageSelectors[kDefaultCodePage] ?? 0;
    }
  }

  /// Active code page → bytes. Never emits a byte the page cannot represent:
  /// a rune outside the page is ASCII-folded, else replaced by `?`, and counted.
  List<int> _encode(String s) {
    final out = <int>[];
    for (final r in s.runes) {
      if (r <= 0x7F) {
        out.add(r);
        continue;
      }
      final mapped = _codePage.high[r];
      if (mapped != null) {
        out.add(mapped);
        continue;
      }
      final fold = kAsciiFold[r];
      if (fold != null) {
        out.addAll(fold.codeUnits);
        _transliterated++;
      } else {
        out.add(0x3F);
        _substituted++;
      }
    }
    return out;
  }

  void _qrCmd(List<int> payload) {
    final n = payload.length;
    _b.addAll([_gs, 0x28, 0x6B, n & 0xFF, (n >> 8) & 0xFF, ...payload]);
  }

  /// Everything the encoder decided, for honest reporting by the caller.
  EscPosEncode result({List<String> warnings = const [], int qrFallbacks = 0, int barcodeFallbacks = 0, int skippedImages = 0, int rasterImages = 0, int placeholderImages = 0, bool cutEmitted = false}) =>
      EscPosEncode(
        bytes: bytes,
        dialect: dialect,
        dialectKnown: isKnownDialect(dialect),
        dialectImplemented: isImplementedDialect(dialect),
        codePage: _codePage.code,
        codePageKnown: _codePageKnown,
        codePageSupportedByDialect: _codePageSupportedByDialect,
        transliteratedChars: _transliterated,
        substitutedChars: _substituted,
        qrFallbacks: qrFallbacks,
        barcodeFallbacks: barcodeFallbacks,
        skippedImages: skippedImages,
        rasterImages: rasterImages,
        placeholderImages: placeholderImages,
        cutEmitted: cutEmitted,
        warnings: warnings,
      );
}

/// Resolves an IMAGE block's `assetKey` (and its declared `maxHeightMm`) to an
/// already-encoded raster, or null to fall back to the labelled placeholder.
/// Synchronous on purpose: the async decode belongs to [encodePrintJobWithImages].
typedef RasterLookup = RasterImage? Function(String assetKey, int? maxHeightMm);

/// Encode a rendered [job] as one ESC/POS byte stream: the printer is reset and
/// configured, text lines and graphics entries are interleaved at their
/// [PrintableEntry.atLine] offsets, then the paper is fed and — when the
/// dialect/printer reports a cutter — cut.
///
/// The dialect is taken from `job.printer.dialect` (see [normalizeDialect]); an
/// unknown or declared-but-unimplemented dialect still encodes with the default
/// and is reported. The code page comes from `job.printer.codePage` (absent →
/// CP437). Capabilities come from the dialect unless the printer overrides them.
///
/// [rasterLookup] resolves an IMAGE block's `assetKey` to an already-encoded
/// raster (see [encodeRasterImage]); null → the labelled placeholder. This keeps
/// encoding synchronous and pure: decoding happens in [encodePrintJobWithImages],
/// which owns the async seam. With no IMAGE blocks the output is byte-identical
/// to the text-only path.
EscPosEncode encodePrintJobDetailed(PrintJob job, {int? widthMm, RasterLookup? rasterLookup}) {
  final dialect = normalizeDialect(job.printer.dialect);
  final encoder = EscPosEncoder(
    widthMm: widthMm ?? job.printer.widthMm,
    dialect: dialect,
  )
    ..init()
    ..selectCodePage(job.printer.codePage)
    ..align(0)
    ..bold(false)
    ..normalSize();

  final caps = encoder.dialectSpec.capabilities;
  // Capability resolution: dialect default, overridable per printer.
  final nativeQr = job.printer.supportsNativeQr ?? caps.nativeQr;
  final nativeBarcode = job.printer.supportsNativeBarcode ?? caps.nativeBarcode;
  final cutter = job.printer.supportsCutter ?? caps.cutter;
  final raster = job.printer.supportsRasterImage;

  final entries = [...job.entries]..sort((a, b) => a.atLine.compareTo(b.atLine));
  var skippedImages = 0;
  var rasterImages = 0;
  var placeholderImages = 0;
  var qrFallbacks = 0;
  var barcodeFallbacks = 0;
  final rasterWarnings = <String>[];
  var ei = 0;
  void emit(PrintableEntry e) {
    switch (e.kind) {
      case PrintableKind.pulse:
        encoder.pulse();
        break;
      case PrintableKind.qr:
        if (nativeQr) {
          encoder.qr(e.content, sizeMm: e.sizeMm ?? 20);
        } else {
          encoder.qrTextFallback(e.content);
          qrFallbacks++;
        }
        break;
      case PrintableKind.barcode:
        if (nativeBarcode) {
          encoder.barcode(e.content, symbology: e.symbology);
        } else {
          encoder.barcodeTextFallback(e.content, symbology: e.symbology);
          barcodeFallbacks++;
        }
        break;
      case PrintableKind.image:
        final key = e.assetKey ?? e.content;
        if (!raster) {
          encoder.imageSkipped(key);
          skippedImages++;
          break;
        }
        // Raster-capable: emit real GS v 0 bytes when the asset resolved and
        // decoded; otherwise a labelled placeholder (never a silent drop).
        final resolved = rasterLookup?.call(key, e.maxHeightMm);
        if (resolved != null) {
          encoder.raster(resolved.bytes);
          rasterImages++;
          rasterWarnings.addAll(resolved.warnings);
        } else {
          encoder.imagePlaceholder(key);
          placeholderImages++;
        }
        break;
    }
  }

  for (var i = 0; i < job.lines.length; i++) {
    while (ei < entries.length && entries[ei].atLine <= i) {
      emit(entries[ei]);
      ei++;
    }
    encoder.line(job.lines[i]);
  }
  while (ei < entries.length) {
    emit(entries[ei]);
    ei++;
  }

  encoder.feed(3);
  final cutEmitted = cutter && encoder.dialectSpec.cutFull.isNotEmpty;
  if (cutEmitted) encoder.cut();

  final warnings = <String>[];
  if (!isKnownDialect(dialect)) {
    warnings.add("protocol '$dialect' is not in the dialect registry — using the default $kDefaultEscPosDialect dialect.");
  } else if (!isImplementedDialect(dialect)) {
    warnings.add("dialect '$dialect' is declared but not implemented by this build — using the default $kDefaultEscPosDialect dialect.");
  }
  if (encoder._requestedCodePage != null && !encoder._codePageKnown) {
    warnings.add("code page '${encoder._requestedCodePage}' is unknown — using $kDefaultCodePage.");
  } else if (encoder._requestedCodePage != null && !encoder._codePageSupportedByDialect) {
    if (encoder._requestedPage?.implemented == false) {
      // Recognised but with no ESC/POS byte encoding at all (UTF-8): never emit
      // multi-byte garbage — fall back and say so.
      warnings.add(
        "code page '${encoder._requestedCodePage}' has no ESC/POS encoding — using $kDefaultCodePage.",
      );
    } else {
      warnings.add(
        "code page '${encoder._requestedCodePage}' is not supported by dialect '$dialect' — using $kDefaultCodePage.",
      );
    }
  }
  if (encoder.transliteratedChars > 0) {
    warnings.add('${encoder.transliteratedChars} character(s) transliterated for ${encoder.activeCodePage.code}.');
  }
  if (encoder.substitutedChars > 0) {
    warnings.add('${encoder.substitutedChars} character(s) not representable in ${encoder.activeCodePage.code} — substituted with "?".');
  }
  if (qrFallbacks > 0) {
    warnings.add('$qrFallbacks QR code(s) rendered as text (no native QR on this dialect/printer).');
  }
  if (barcodeFallbacks > 0) {
    warnings.add('$barcodeFallbacks barcode(s) rendered as text (no native barcode on this dialect/printer).');
  }
  if (skippedImages > 0) {
    warnings.add('$skippedImages image block(s) skipped — no raster support.');
  }
  if (placeholderImages > 0) {
    warnings.add(
      '$placeholderImages image block(s) rendered as a labelled placeholder — '
      'the asset was missing, unreadable or not an image.',
    );
  }
  warnings.addAll(rasterWarnings);
  if (!cutter) {
    warnings.add('no cutter reported for this dialect/printer — cut command skipped.');
  }

  return encoder.result(
    warnings: warnings,
    qrFallbacks: qrFallbacks,
    barcodeFallbacks: barcodeFallbacks,
    skippedImages: skippedImages,
    rasterImages: rasterImages,
    placeholderImages: placeholderImages,
    cutEmitted: cutEmitted,
  );
}

/// Convenience: just the bytes (default ESC/POS dialect, documented fallback).
List<int> encodePrintJob(PrintJob job, {int? widthMm}) => encodePrintJobDetailed(job, widthMm: widthMm).bytes;

/// Encode [job] with real IMAGE rasters: resolve each IMAGE block's `assetKey`
/// through [source], decode it with [decoder] (Flutter's built-in codec by
/// default), scale/dither/pack to the printable width, then hand the encoded
/// rasters to the synchronous [encodePrintJobDetailed].
///
/// Never throws and never blocks a sale: an unresolvable, unreadable or
/// undecodable asset (or a printer without raster support) leaves the labelled
/// placeholder + a warning. This is the one entry point a caller needs to wire —
/// the transports keep calling the sync [encodePrintJob].
Future<EscPosEncode> encodePrintJobWithImages(
  PrintJob job, {
  required PrintImageSource source,
  PrintImageDecoder decoder = const FlutterPrintImageDecoder(),
  int? widthMm,
}) async {
  final effectiveWidth = widthMm ?? job.printer.widthMm;
  final rasters = <String, RasterImage>{};
  if (job.printer.supportsRasterImage) {
    for (final e in job.entries) {
      if (e.kind != PrintableKind.image) continue;
      final key = e.assetKey ?? e.content;
      if (key.isEmpty || rasters.containsKey(key)) continue;
      final raw = await source.bytesFor(key);
      if (raw == null) continue; // missing/unreadable → placeholder + warning
      final bitmap = await decoder.decode(raw);
      if (bitmap == null) continue; // not an image → placeholder + warning
      rasters[key] = encodeRasterImage(
        bitmap,
        targetWidthDots: rasterWidthDots(effectiveWidth),
        maxHeightMm: e.maxHeightMm,
      );
    }
  }
  return encodePrintJobDetailed(
    job,
    widthMm: widthMm,
    rasterLookup: (key, _) => rasters[key],
  );
}
