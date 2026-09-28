/// Print-Format ENGINE — pure-Dart renderer (CONTRACT.md §5).
///
/// Input: a parsed [PrintFormat] + a ticket payload + a printer width.
/// Output: printable plain-text [PrintRenderResult.lines] plus structured
/// [PrintableEntry]s for the QR/BARCODE/IMAGE blocks the transport layer must
/// encode itself.
///
/// Rules implemented exactly:
///  1. Unknown `{token}` prints LITERALLY (bad config stays visible).
///  2. Known token with no value → empty string; a block whose every row is
///     empty is skipped entirely (no dangling separator). FEED/SEPARATOR are
///     structural and always emit.
///  3. Width: 58 mm = 32 cells, 80 mm = 48 cells; DOUBLE halves the cells.
///  4. Money: 2 decimals, no thousands separator (via `money.round2`).
///  5. Data-driven only — the renderer knows ONLY [BlockType] from §2. No eval,
///     no JS, no network.
///  6. Blocks render in array order; CONDITIONAL/BATCH render children in place.
///
/// Ticket payload shape this renderer consumes (all keys optional):
/// ```
/// {
///   "tokens":   { "total": 125000.0, "payment_type": "CASH", ... },
///   "items":    [ { "name":"Espresso", "qty":2, "price":22000.0,
///                   "batchIndex":0, "modifiers":[{"name":"Extra","price":5000.0}] } ],
///   "payments": [ { "name":"Cash", "type":"cash", "amount":100000.0,
///                   "reference": null, "code":"CASH" } ]
/// }
/// ```
library;

import 'package:gundam_pos/logic/money.dart' as money;

import 'print_format.dart';

/// Monospace cells available for a printer width in mm (CONTRACT §3).
/// 80 mm and wider → 48 cells; anything narrower → 32.
int cellsForWidthMm(int widthMm) => widthMm >= 80 ? 48 : 32;

/// Kind of non-text block the transport layer must render natively.
enum PrintableKind { qr, barcode, image }

/// A structured, non-text print instruction (QR/BARCODE/IMAGE). [atLine] is the
/// index in [PrintRenderResult.lines] where it sits in the block flow, so the
/// transport can interleave text and graphics in order.
class PrintableEntry {
  PrintableEntry({
    required this.kind,
    required this.atLine,
    this.content = '',
    this.sizeMm,
    this.symbology,
    this.assetKey,
    this.maxHeightMm,
  });

  final PrintableKind kind;
  final int atLine;
  final String content;
  final int? sizeMm;
  final String? symbology;
  final String? assetKey;
  final int? maxHeightMm;
}

/// Result of a render: text [lines] plus structured [entries]. Entries are also
/// ordered by [PrintableEntry.atLine].
class PrintRenderResult {
  PrintRenderResult({required this.lines, required this.entries});

  final List<String> lines;
  final List<PrintableEntry> entries;
}

/// Default money-line labels (CONTRACT §2 lists only the line keys, not labels,
/// so the POS owns the canonical captions).
const Map<String, String> kMoneyLineLabels = {
  'SUBTOTAL': 'Subtotal',
  'DISCOUNT': 'Discount',
  'VOUCHER': 'Voucher',
  'VAT': 'VAT',
  'SC': 'Service Charge',
  'SHIPMENT': 'Shipment',
  'ROUNDING': 'Rounding',
  'TIPS': 'Tips',
  'TOTAL': 'Total',
  'PAID': 'Paid',
  'CHANGE': 'Change',
};

/// Render [format] against [ticketPayload]. [widthMm] overrides the format's
/// own width when supplied (e.g. the routed printer is narrower).
PrintRenderResult renderPrintFormat({
  required PrintFormat format,
  required Map<String, dynamic> ticketPayload,
  int? widthMm,
}) {
  final baseCells = cellsForWidthMm(widthMm ?? format.widthMm);
  final ctx = _Ctx(
    tokens: _normalizeTokens(ticketPayload['tokens']),
    items: _rows(ticketPayload['items']),
    payments: _rows(ticketPayload['payments']),
    baseCells: baseCells,
  );
  final out = _Out();
  _renderBlocks(format.blocks, ctx, out);
  return PrintRenderResult(lines: out.lines, entries: out.entries);
}

// ---------------------------------------------------------------------------
// internals
// ---------------------------------------------------------------------------

class _Ctx {
  _Ctx({
    required this.tokens,
    required this.items,
    required this.payments,
    required this.baseCells,
  });

  final Map<String, Object?> tokens;
  final List<Map<String, dynamic>> items;
  final List<Map<String, dynamic>> payments;
  final int baseCells;

  /// A scoped copy sharing tokens/payments but with a different item list
  /// (used by BATCH grouping).
  _Ctx withItems(List<Map<String, dynamic>> items) =>
      _Ctx(tokens: tokens, items: items, payments: payments, baseCells: baseCells);
}

class _Out {
  final List<String> lines = [];
  final List<PrintableEntry> entries = [];
}

List<Map<String, dynamic>> _rows(Object? v) => (v is List)
    ? v.whereType<Map<String, dynamic>>().toList()
    : const [];

/// Normalize `{total}` / `total` keys to bare names.
Map<String, Object?> _normalizeTokens(Object? v) {
  final out = <String, Object?>{};
  if (v is Map) {
    v.forEach((k, val) {
      final name = k.toString().replaceAll(RegExp(r'[{}]'), '').trim();
      if (name.isNotEmpty) out[name] = val;
    });
  }
  return out;
}

final RegExp _tokenRe = RegExp(r'\{([A-Za-z0-9_]+)\}');

/// Resolve `{token}` occurrences (CONTRACT §5 rules 1-2). [extra] supplies
/// local keys (e.g. row-scoped item params) that shadow global tokens.
String _resolve(String input, Map<String, Object?> tokens, {Map<String, Object?>? extra}) {
  return input.replaceAllMapped(_tokenRe, (m) {
    final name = m.group(1)!;
    if (extra != null && extra.containsKey(name)) {
      return _stringify(extra[name]);
    }
    if (tokens.containsKey(name)) {
      return _stringify(tokens[name]);
    }
    return m.group(0)!; // unknown token → literal
  });
}

String _stringify(Object? v) => v?.toString() ?? '';

/// Apply one or more comma-separated format options (CONTRACT §3 safe set).
String _applyFormat(String value, String? format) {
  if (format == null || format.isEmpty) return value;
  var out = value;
  for (final raw in format.split(',')) {
    final opt = raw.trim();
    final colon = opt.indexOf(':');
    final name = (colon >= 0 ? opt.substring(0, colon) : opt).toLowerCase();
    final arg = colon >= 0 ? opt.substring(colon + 1) : '';
    switch (name) {
      case 'money':
        out = _money(double.tryParse(out));
        break;
      case 'decimal':
        break; // already plain decimal text
      case 'date':
        out = _date(out, withTime: false);
        break;
      case 'datetime':
        out = _date(out, withTime: true);
        break;
      case 'uppercase':
        out = out.toUpperCase();
        break;
      case 'lowercase':
        out = out.toLowerCase();
        break;
      case 'truncate':
        final n = int.tryParse(arg);
        if (n != null && n >= 0 && out.length > n) out = out.substring(0, n);
        break;
      case 'wrap':
      case 'show_if_present':
        break; // handled by the caller
    }
  }
  return out;
}

/// Money: 2 decimals, no thousands separator — reuses `money.round2`.
String _money(double? v) => money.round2(v ?? 0).toStringAsFixed(2);

String _date(String raw, {required bool withTime}) {
  final dt = DateTime.tryParse(raw);
  if (dt == null) return raw;
  String two(int n) => n.toString().padLeft(2, '0');
  final d = '${dt.year}-${two(dt.month)}-${two(dt.day)}';
  return withTime ? '$d ${two(dt.hour)}:${two(dt.minute)}' : d;
}

/// Number-ish token read (num, or numeric string) for MONEY_LINES.
double? _asNum(Object? v) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v);
  return null;
}

/// Wrap [text] so no line exceeds [cells]; splits on spaces where possible.
List<String> _wrap(String text, int cells) {
  if (cells <= 0) return [text];
  if (text.length <= cells) return [text];
  final out = <String>[];
  final words = text.split(' ');
  var cur = '';
  for (final w in words) {
    if (cur.isEmpty) {
      // A single word longer than the line: hard-split it.
      var word = w;
      while (word.length > cells) {
        out.add(word.substring(0, cells));
        word = word.substring(cells);
      }
      cur = word;
    } else if ('$cur $w'.length <= cells) {
      cur = '$cur $w';
    } else {
      out.add(cur);
      cur = w;
      while (cur.length > cells) {
        out.add(cur.substring(0, cells));
        cur = cur.substring(cells);
      }
    }
  }
  if (cur.isNotEmpty || out.isEmpty) out.add(cur);
  return out;
}

String _fit(String s, int cells, BlockAlign align) {
  if (s.length >= cells) return s.substring(0, cells);
  final pad = cells - s.length;
  switch (align) {
    case BlockAlign.right:
      return '${' ' * pad}$s';
    case BlockAlign.center:
      final l = pad ~/ 2;
      return '${' ' * l}$s${' ' * (pad - l)}';
    case BlockAlign.left:
      return '$s${' ' * pad}';
  }
}

// ---------------------------------------------------------------------------
// block rendering
// ---------------------------------------------------------------------------

void _renderBlocks(List<PrintBlock> blocks, _Ctx ctx, _Out out) {
  for (final b in blocks) {
    _renderBlock(b, ctx, out);
  }
}

void _renderBlock(PrintBlock b, _Ctx ctx, _Out out) {
  // Common `if` guard: a block whose condition does not hold is skipped
  // silently (CONTRACT §4), children included.
  if (b.condition != null && !b.condition!.holds(ctx.tokens)) return;

  final cells = b.size == BlockSize.double ? ctx.baseCells ~/ 2 : ctx.baseCells;

  switch (b.type) {
    case BlockType.text:
      _emitText(out, _resolve(b.text ?? '', ctx.tokens), cells, b.align);
      return;
    case BlockType.varBlock:
      _emitVar(b, ctx, out, cells);
      return;
    case BlockType.itemList:
      _emitItems(b, ctx, out, cells);
      return;
    case BlockType.modifierList:
      _emitModifiers(b, ctx, out, cells);
      return;
    case BlockType.moneyLines:
      _emitMoneyLines(b, ctx, out, ctx.baseCells);
      return;
    case BlockType.paymentLines:
      _emitPayments(b, ctx, out, ctx.baseCells);
      return;
    case BlockType.separator:
      final w = b.width ?? ctx.baseCells;
      final ch = b.char.isEmpty ? '-' : b.char[0];
      if (w > 0) out.lines.add(ch * w);
      return;
    case BlockType.feed:
      final n = b.feedLines.clamp(0, 10);
      for (var i = 0; i < n; i++) {
        out.lines.add('');
      }
      return;
    case BlockType.qr:
      _emitQr(b, ctx, out);
      return;
    case BlockType.barcode:
      _emitBarcode(b, ctx, out);
      return;
    case BlockType.image:
      _emitImage(b, ctx, out);
      return;
    case BlockType.table:
      _emitTable(b, ctx, out, ctx.baseCells);
      return;
    case BlockType.batch:
      _emitBatch(b, ctx, out);
      return;
    case BlockType.conditional:
      _renderBlocks(b.blocks, ctx, out);
      return;
    case BlockType.unknown:
      return; // never evaluate unknown types
  }
}

void _emitText(_Out out, String text, int cells, BlockAlign? align) {
  if (text.isEmpty) return;
  for (final line in _wrap(text, cells)) {
    out.lines.add(_fit(line, cells, align ?? BlockAlign.left));
  }
}

void _emitVar(PrintBlock b, _Ctx ctx, _Out out, int cells) {
  final param = b.param ?? '';
  final name = param.replaceAll(RegExp(r'[{}]'), '').trim();
  if (name.isEmpty) return;
  final String value;
  if (ctx.tokens.containsKey(name)) {
    value = _applyFormat(_stringify(ctx.tokens[name]), b.format);
  } else {
    value = '{$name}'; // unknown token → literal (rule 1)
  }
  if (value.isEmpty) return; // known token with no value → skipped (rule 2)
  for (final line in _wrap(value, cells)) {
    out.lines.add(_fit(line, cells, b.align ?? BlockAlign.left));
  }
}

void _emitItems(PrintBlock b, _Ctx ctx, _Out out, int cells) {
  final nameMax = b.nameMax ?? 20;
  final rows = <String>[];
  for (final it in ctx.items) {
    final name = _stringify(it['name']);
    final qty = _stringify(it['qty'] ?? 1);
    final price = _asNum(it['price']) ?? 0;
    final lineTotal = _asNum(it['lineTotal']) ?? price * (_asNum(it['qty']) ?? 1);
    switch (b.columns) {
      case ItemColumns.nameQtyPrice:
        _itemNameQtyPrice(rows, name, qty, _money(lineTotal), cells, nameMax, b.wrap);
        break;
      case ItemColumns.nameQty:
        final nameW = (cells - 3).clamp(1, cells);
        rows.add(_fit(_clip(name, nameMax), nameW, BlockAlign.left) +
            _fit(qty, 3, BlockAlign.right));
        break;
      case ItemColumns.full:
        final qtyName = '$qty x $name';
        rows.add(_fit(_clip(qtyName, cells), cells - 12, BlockAlign.left) +
            _fit(_money(lineTotal), 12, BlockAlign.right));
        for (final m in _rows(it['modifiers'])) {
          final mn = '  + ${_stringify(m['name'])}';
          if (b.withPrice) {
            rows.add(_fit(mn, cells - 12, BlockAlign.left) +
                _fit(_money(_asNum(m['price'])), 12, BlockAlign.right));
          } else {
            rows.add(_fit(mn, cells, BlockAlign.left));
          }
        }
        break;
    }
  }
  _emitBlockLines(out, rows);
}

void _itemNameQtyPrice(
    List<String> rows, String name, String qty, String money, int cells, int nameMax, bool wrap) {
  const qtyW = 3;
  const priceW = 12;
  final nameW = (cells - qtyW - priceW).clamp(1, cells);
  final shown = _clip(name, nameMax);
  if (!wrap || shown.length <= nameW) {
    rows.add(_fit(shown, nameW, BlockAlign.left) +
        _fit(qty, qtyW, BlockAlign.right) +
        _fit(money, priceW, BlockAlign.right));
    return;
  }
  final parts = _wrap(shown, nameW);
  for (var i = 0; i < parts.length; i++) {
    if (i == 0) {
      rows.add(_fit(parts[i], nameW, BlockAlign.left) +
          _fit(qty, qtyW, BlockAlign.right) +
          _fit(money, priceW, BlockAlign.right));
    } else {
      rows.add(_fit(parts[i], cells, BlockAlign.left));
    }
  }
}

void _emitModifiers(PrintBlock b, _Ctx ctx, _Out out, int cells) {
  final rows = <String>[];
  final indent = ' ' * b.indent;
  for (final it in ctx.items) {
    for (final m in _rows(it['modifiers'])) {
      final label = '$indent${_stringify(m['name'])}';
      if (b.withPrice) {
        final w = (cells - 12).clamp(1, cells);
        rows.add(_fit(label, w, BlockAlign.left) + _fit(_money(_asNum(m['price'])), 12, BlockAlign.right));
      } else {
        rows.add(_fit(label, cells, BlockAlign.left));
      }
    }
  }
  _emitBlockLines(out, rows);
}

void _emitMoneyLines(PrintBlock b, _Ctx ctx, _Out out, int cells) {
  final keys = b.moneyLineKeys.isEmpty ? kMoneyLineLabels.keys.toList() : b.moneyLineKeys;
  final rows = <String>[];
  for (final key in keys) {
    final token = key.toLowerCase();
    final raw = ctx.tokens[token];
    final amount = _asNum(raw) ?? 0;
    if (money.round2(amount) == 0) continue; // only non-zero lines print
    final label = kMoneyLineLabels[key] ?? key;
    final value = _money(amount);
    final labelW = (cells - value.length).clamp(1, cells);
    rows.add(_fit(label, labelW, BlockAlign.left) + value);
  }
  _emitBlockLines(out, rows);
}

void _emitPayments(PrintBlock b, _Ctx ctx, _Out out, int cells) {
  final rows = <String>[];
  for (final p in ctx.payments) {
    final name = _stringify(p['name'] ?? p['code']);
    final value = _money(_asNum(p['amount']));
    final labelW = (cells - value.length).clamp(1, cells);
    rows.add(_fit(name, labelW, BlockAlign.left) + value);
    if (b.showReference) {
      final ref = _stringify(p['reference']);
      if (ref.isNotEmpty) rows.add(_fit('  ref: $ref', cells, BlockAlign.left));
    }
  }
  _emitBlockLines(out, rows);
}

void _emitQr(PrintBlock b, _Ctx ctx, _Out out) {
  final content = _resolveContent(b.content, ctx);
  if (content.isEmpty) return;
  out.entries.add(PrintableEntry(
    kind: PrintableKind.qr,
    atLine: out.lines.length,
    content: content,
    sizeMm: b.sizeMm,
  ));
}

void _emitBarcode(PrintBlock b, _Ctx ctx, _Out out) {
  final content = _resolveContent(b.content, ctx);
  if (content.isEmpty) return;
  out.entries.add(PrintableEntry(
    kind: PrintableKind.barcode,
    atLine: out.lines.length,
    content: content,
    symbology: b.symbology,
  ));
}

void _emitImage(PrintBlock b, _Ctx ctx, _Out out) {
  final key = _stringify(b.assetKey);
  if (key.isEmpty) return;
  out.entries.add(PrintableEntry(
    kind: PrintableKind.image,
    atLine: out.lines.length,
    content: key,
    assetKey: key,
    maxHeightMm: b.maxHeightMm,
  ));
}

/// `content` is either a literal or a `{param}` token (CONTRACT §2).
String _resolveContent(Object? content, _Ctx ctx) {
  if (content == null) return '';
  final raw = content.toString();
  return _resolve(raw, ctx.tokens);
}

void _emitTable(PrintBlock b, _Ctx ctx, _Out out, int cells) {
  final cols = b.tableColumns;
  if (cols.isEmpty) return;
  final widths = _columnWidths(cols, cells);
  final rows = <String>[];
  if (cols.any((c) => c.label.isNotEmpty)) {
    rows.add(_tableRow(cols.map((c) => c.label).toList(), widths, cols.map((c) => c.align).toList()));
  }
  for (final it in ctx.items) {
    final extra = <String, Object?>{};
    it.forEach((k, v) => extra[k] = v);
    final cellsVals = <String>[];
    for (final c in cols) {
      final raw = extra.containsKey(c.name) ? extra[c.name] : ctx.tokens[c.name];
      cellsVals.add(_stringify(raw));
    }
    rows.add(_tableRow(cellsVals, widths, cols.map((c) => c.align).toList()));
  }
  _emitBlockLines(out, rows);
}

List<int> _columnWidths(List<TableColumn> cols, int cells) {
  final fixed = cols.where((c) => c.width > 0).fold<int>(0, (s, c) => s + c.width);
  final flexible = cols.where((c) => c.width <= 0).length;
  final share = flexible > 0 ? ((cells - fixed) ~/ flexible).clamp(1, cells) : 0;
  return cols.map((c) => c.width > 0 ? c.width : share).toList();
}

String _tableRow(List<String> vals, List<int> widths, List<BlockAlign> aligns) {
  final buf = StringBuffer();
  for (var i = 0; i < vals.length; i++) {
    buf.write(_fit(vals[i], widths[i], aligns[i]));
  }
  return buf.toString();
}

void _emitBatch(PrintBlock b, _Ctx ctx, _Out out) {
  final idx = b.batchIndex;
  final scoped = idx == null
      ? ctx.items
      : ctx.items.where((it) => _asNum(it['batchIndex'])?.toInt() == idx).toList();
  final childCtx = ctx.withItems(scoped);
  if (b.blocks.isNotEmpty) {
    _renderBlocks(b.blocks, childCtx, out);
    return;
  }
  // No children declared → emit the batch's items as a plain item list.
  _emitItems(PrintBlock(id: b.id, type: BlockType.itemList), childCtx, out, ctx.baseCells);
}

/// Emit [rows] unless they are all blank (CONTRACT §5 rule 2: an empty block is
/// skipped entirely, no dangling separator).
void _emitBlockLines(_Out out, List<String> rows) {
  if (rows.isEmpty) return;
  if (rows.every((r) => r.trim().isEmpty)) return;
  out.lines.addAll(rows);
}

String _clip(String s, int max) => s.length <= max ? s : s.substring(0, max);
