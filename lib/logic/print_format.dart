/// Print-Format ENGINE — POS-side model + parser for the PUBLISHED payload
/// (docs/print-format/CONTRACT.md §1-§4). Parsing is tolerant: missing/odd keys
/// fall back to defaults, unknown block types are kept as [BlockType.unknown]
/// (the renderer skips them — a bad config is dropped, never executed).
///
/// This file is DATA ONLY. All text production lives in
/// `print_format_render.dart`. No code, no eval, no network anywhere.
library;

/// Ticket types (CONTRACT §1). Unknown types still parse; routing decides.
const Set<String> kTicketTypes = {
  'BILL',
  'CAPTAIN_ORDER',
  'BEV_LABEL',
  'CANCELED_ORDER',
  'RECEIPT_COPY',
  'SHIFT_OPEN',
  'SHIFT_CLOSE',
  'Z_REPORT',
};

/// Closed block catalog (CONTRACT §2). `unknown` = server sent something the
/// POS does not know → renderer skips it (never evaluate).
enum BlockType {
  text('TEXT'),
  varBlock('VAR'),
  itemList('ITEM_LIST'),
  modifierList('MODIFIER_LIST'),
  moneyLines('MONEY_LINES'),
  paymentLines('PAYMENT_LINES'),
  separator('SEPARATOR'),
  feed('FEED'),
  qr('QR'),
  barcode('BARCODE'),
  image('IMAGE'),
  table('TABLE'),
  batch('BATCH'),
  conditional('CONDITIONAL'),
  unknown('');

  const BlockType(this.wire);

  /// The exact wire name in CONTRACT §2 (empty for [unknown]).
  final String wire;

  static BlockType parse(Object? s) {
    if (s is String) {
      for (final t in BlockType.values) {
        if (t.wire == s) return t;
      }
    }
    return unknown;
  }
}

enum BlockAlign {
  left,
  center,
  right;

  static BlockAlign parse(Object? s) => switch (s) {
        'CENTER' => center,
        'RIGHT' => right,
        _ => left,
      };
}

enum BlockSize {
  normal,
  double;

  static BlockSize parse(Object? s) => s == 'DOUBLE' ? double : normal;
}

/// ITEM_LIST column modes (CONTRACT §2).
enum ItemColumns {
  nameQtyPrice('NAME_QTY_PRICE'),
  nameQty('NAME_QTY'),
  full('FULL');

  const ItemColumns(this.wire);
  final String wire;

  static ItemColumns parse(Object? s) {
    if (s is String) {
      for (final c in ItemColumns.values) {
        if (c.wire == s) return c;
      }
    }
    return nameQtyPrice;
  }
}

/// Safe condition (CONTRACT §4). Never code: a param name, an operator from a
/// closed set, and a literal comparison value.
class PrintCondition {
  PrintCondition({required this.param, required this.op, this.value});

  factory PrintCondition.fromJson(Map<String, dynamic> j) => PrintCondition(
        param: (j['param'] as String?) ?? '',
        op: ((j['op'] as String?) ?? 'PRESENT').toUpperCase(),
        value: j['value'],
      );

  /// Token name — braces optional on the wire, normalized by [_name].
  final String param;

  /// One of EQ NE PRESENT ABSENT GT GTE LT LTE.
  final String op;

  final Object? value;

  String get _name => param.replaceAll(RegExp(r'[{}]'), '').trim();

  /// Evaluate against a normalized token map (keys WITHOUT braces).
  ///
  /// CONTRACT §4: a missing/unknown param makes the condition FALSE for every
  /// operator (so a bad config block is skipped silently, never executed).
  bool holds(Map<String, Object?> tokens) {
    if (!tokens.containsKey(_name)) return false;
    final raw = tokens[_name];
    final present = raw != null && raw.toString().isNotEmpty;
    switch (op) {
      case 'PRESENT':
        return present;
      case 'ABSENT':
        return !present;
      case 'EQ':
        return present && raw.toString() == value.toString();
      case 'NE':
        return raw?.toString() != value?.toString();
      case 'GT':
      case 'GTE':
      case 'LT':
      case 'LTE':
        final a = _num(raw);
        final b = _num(value);
        if (a == null || b == null) return false;
        return switch (op) {
          'GT' => a > b,
          'GTE' => a >= b,
          'LT' => a < b,
          _ => a <= b,
        };
      default:
        return false;
    }
  }

  static double? _num(Object? v) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v);
    return null;
  }
}

/// One TABLE column (CONTRACT §2). Schema-driven — a param name, a label, a
/// fixed cell width and an align; no expressions.
class TableColumn {
  TableColumn({
    required this.param,
    this.label = '',
    this.width = 0,
    this.align = BlockAlign.left,
  });

  factory TableColumn.fromJson(Map<String, dynamic> j) => TableColumn(
        param: (j['param'] as String?) ?? '',
        label: (j['label'] as String?) ?? '',
        width: _int(j['width']) ?? 0,
        align: BlockAlign.parse(j['align']),
      );

  final String param;
  final String label;

  /// Fixed cell width in monospace cells; 0 = share the leftover cells.
  final int width;

  final BlockAlign align;

  /// Token name with braces stripped.
  String get name => param.replaceAll(RegExp(r'[{}]'), '').trim();
}

/// One block (CONTRACT §2). A single tolerant class: every type-specific key is
/// optional; only the keys the renderer needs for that [type] are read.
class PrintBlock {
  PrintBlock({
    required this.id,
    required this.type,
    this.align,
    this.bold = false,
    this.size = BlockSize.normal,
    this.condition,
    // TEXT / VAR
    this.text,
    this.param,
    this.format,
    // ITEM_LIST / MODIFIER_LIST
    this.columns = ItemColumns.nameQtyPrice,
    this.wrap = false,
    this.nameMax,
    this.indent = 0,
    this.withPrice = false,
    // MONEY_LINES
    this.moneyLineKeys = const [],
    // PAYMENT_LINES
    this.showReference = false,
    // SEPARATOR / FEED
    this.char = '-',
    this.width,
    this.feedLines = 1,
    // QR / BARCODE / IMAGE
    this.content,
    this.sizeMm,
    this.symbology = 'CODE128',
    this.assetKey,
    this.maxHeightMm,
    // TABLE
    this.tableColumns = const [],
    // BATCH
    this.batchIndex,
    // CONDITIONAL / BATCH children
    this.blocks = const [],
  });

  factory PrintBlock.fromJson(Map<String, dynamic> j) {
    final type = BlockType.parse(j['type']);
    final raw = j['if'];
    return PrintBlock(
      id: (j['id'] as String?) ?? '',
      type: type,
      align: j.containsKey('align') ? BlockAlign.parse(j['align']) : null,
      bold: (j['bold'] as bool?) ?? false,
      size: BlockSize.parse(j['size']),
      condition: raw is Map<String, dynamic> ? PrintCondition.fromJson(raw) : null,
      text: j['text'] as String?,
      param: j['param'] as String?,
      format: j['format'] as String?,
      columns: ItemColumns.parse(j['columns']),
      wrap: (j['wrap'] as bool?) ?? false,
      nameMax: _int(j['nameMax']),
      indent: _int(j['indent']) ?? 0,
      withPrice: (j['withPrice'] as bool?) ?? false,
      moneyLineKeys: (j['lines'] is List)
              ? (j['lines'] as List).map((e) => e.toString().toUpperCase()).toList()
              : const [],
      showReference: (j['showReference'] as bool?) ?? false,
      char: (j['char'] as String?) ?? '-',
      width: _int(j['width']),
      feedLines: _int(j['lines']) ?? 1,
      content: j['content'],
      sizeMm: _int(j['sizeMm']),
      symbology: (j['symbology'] as String?) ?? 'CODE128',
      assetKey: j['assetKey'] as String?,
      maxHeightMm: _int(j['maxHeightMm']),
      tableColumns: (j['columns'] is List)
          ? (j['columns'] as List)
              .whereType<Map<String, dynamic>>()
              .map(TableColumn.fromJson)
              .toList()
          : const [],
      batchIndex: _int(j['batchIndex']),
      blocks: (j['blocks'] is List)
              ? (j['blocks'] as List)
                  .whereType<Map<String, dynamic>>()
                  .map(PrintBlock.fromJson)
                  .toList()
              : const [],
    );
  }

  final String id;
  final BlockType type;
  final BlockAlign? align;
  final bool bold;
  final BlockSize size;

  /// Optional common `if` guard. `null` = always render (CONTRACT §4).
  final PrintCondition? condition;

  final String? text;
  final String? param;
  final String? format;

  final ItemColumns columns;
  final bool wrap;
  final int? nameMax;
  final int indent;
  final bool withPrice;

  final List<String> moneyLineKeys;

  final bool showReference;

  final String char;
  final int? width;
  final int feedLines;

  final Object? content;
  final int? sizeMm;
  final String symbology;
  final String? assetKey;
  final int? maxHeightMm;

  final List<TableColumn> tableColumns;

  final int? batchIndex;

  /// Child blocks (CONDITIONAL and BATCH grouping).
  final List<PrintBlock> blocks;
}

/// The published format payload (CONTRACT §1).
class PrintFormat {
  PrintFormat({
    required this.formatId,
    required this.name,
    required this.ticketType,
    required this.version,
    required this.widthMm,
    required this.blocks,
  });

  factory PrintFormat.fromJson(Map<String, dynamic> j) => PrintFormat(
        formatId: (j['formatId'] as String?) ?? '',
        name: (j['name'] as String?) ?? '',
        ticketType: ((j['ticketType'] as String?) ?? 'BILL').toUpperCase(),
        version: _int(j['version']) ?? 1,
        widthMm: _int(j['widthMm']) ?? 80,
        blocks: (j['blocks'] as List?)
                ?.whereType<Map<String, dynamic>>()
                .map(PrintBlock.fromJson)
                .toList() ??
            const [],
      );

  final String formatId;
  final String name;
  final String ticketType;
  final int version;
  final int widthMm;
  final List<PrintBlock> blocks;
}

int? _int(Object? v) {
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v);
  return null;
}
