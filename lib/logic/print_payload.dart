/// Ticket-payload builder — maps real POS data into the print-format renderer's
/// ticketPayload shape ({tokens, items, payments}) for every ticket type the
/// POS prints. Money-flow values are taken straight from the canonical money
/// helper ([money.MoneyFlow] / [money.SplitResult]); nothing is recomputed here.
///
/// Token names follow the server parameter registry, and the MONEY_LINES keys
/// (CONTRACT §2) are additionally shipped under their short names
/// (`discount`/`vat`/`sc`/`shipment`/`rounding`/`tips`/`paid`) because the
/// renderer resolves a money line by `key.toLowerCase()`.
library;

import 'package:gundam_pos/logic/cart.dart';
import 'package:gundam_pos/logic/money.dart' as money;

/// A printable modifier row (decoupled from [CartModifier]).
class PrintModifier {
  PrintModifier({required this.name, this.price = 0, this.qty = 1});

  final String name;
  final double price;
  final int qty;

  Map<String, dynamic> toJson() => {'name': name, 'price': price, 'qty': qty};
}

/// A printable item row, usable for bill, captain-order and bev-label tickets.
class PrintItem {
  PrintItem({
    required this.name,
    required this.qty,
    required this.unitPrice,
    this.itemId = '',
    this.lineTotal,
    this.modifiers = const [],
    this.priceLevelIndex = 0,
    this.priceLevelLabel = '',
    this.batchIndex = 0,
  });

  /// Map a live cart line (the canonical sellable row).
  factory PrintItem.fromCartLine(CartLine l, {int batchIndex = 0, String priceLevelLabel = ''}) =>
      PrintItem(
        name: l.name,
        itemId: l.itemId,
        qty: l.qty,
        unitPrice: l.unitPrice,
        lineTotal: l.lineSubtotal,
        priceLevelIndex: l.priceLevelIndex,
        priceLevelLabel: priceLevelLabel,
        batchIndex: batchIndex,
        modifiers: [for (final m in l.modifiers) PrintModifier(name: m.name, price: m.price, qty: m.qty)],
      );

  final String name;

  /// Catalog id of the sold item — the strict key the print router uses for
  /// item-level captain/bev routing (never the category).
  final String itemId;
  final int qty;
  final double unitPrice;
  final double? lineTotal;
  final List<PrintModifier> modifiers;
  final int priceLevelIndex;
  final String priceLevelLabel;
  final int batchIndex;

  Map<String, dynamic> toJson() => {
        'name': name,
        'qty': qty,
        'price': unitPrice,
        'lineTotal': lineTotal ?? unitPrice * qty,
        'priceLevelIndex': priceLevelIndex,
        'priceLevel': priceLevelLabel,
        'batchIndex': batchIndex,
        if (modifiers.isNotEmpty) 'modifiers': [for (final m in modifiers) m.toJson()],
      };
}

/// Header/context values shared by every ticket type (store, device, cashier,
/// table, print metadata). All optional — missing keys just render empty.
class TicketContext {
  TicketContext({
    this.storeName = '',
    this.storeShortcode = '',
    this.storeAddress = '',
    this.cashier = '',
    this.tableName = '',
    this.guestName = '',
    this.ticketType = 'BILL',
    this.printerName = '',
    this.printerWidthMm = 80,
    this.currencyLabel = '',
    this.timezone = '',
    this.deviceShortcode = '',
    this.batchLabel = '',
    this.copyLabel = '',
    this.reprintLabel = '',
    this.canceledLabel = '',
    this.cancelReason = '',
    this.actionType = '',
    this.qrContent = '',
    this.thankYouMessage = '',
    DateTime? at,
  }) : at = at ?? DateTime.now();

  final String storeName;
  final String storeShortcode;
  final String storeAddress;
  final String cashier;
  final String tableName;
  final String guestName;
  final String ticketType;
  final String printerName;
  final int printerWidthMm;
  final String currencyLabel;
  final String timezone;
  final String deviceShortcode;
  final String batchLabel;
  final String copyLabel;
  final String reprintLabel;
  final String canceledLabel;
  final String cancelReason;
  final String actionType;
  final String qrContent;
  final String thankYouMessage;
  final DateTime at;

  /// Focused overrides for per-ticket context (table/batch/reprint labels).
  TicketContext copyWith({
    String? storeName,
    String? storeShortcode,
    String? storeAddress,
    String? cashier,
    String? tableName,
    String? guestName,
    String? ticketType,
    String? printerName,
    int? printerWidthMm,
    String? currencyLabel,
    String? timezone,
    String? deviceShortcode,
    String? batchLabel,
    String? copyLabel,
    String? reprintLabel,
    String? canceledLabel,
    String? cancelReason,
    String? actionType,
    String? qrContent,
    String? thankYouMessage,
    DateTime? at,
  }) =>
      TicketContext(
        storeName: storeName ?? this.storeName,
        storeShortcode: storeShortcode ?? this.storeShortcode,
        storeAddress: storeAddress ?? this.storeAddress,
        cashier: cashier ?? this.cashier,
        tableName: tableName ?? this.tableName,
        guestName: guestName ?? this.guestName,
        ticketType: ticketType ?? this.ticketType,
        printerName: printerName ?? this.printerName,
        printerWidthMm: printerWidthMm ?? this.printerWidthMm,
        currencyLabel: currencyLabel ?? this.currencyLabel,
        timezone: timezone ?? this.timezone,
        deviceShortcode: deviceShortcode ?? this.deviceShortcode,
        batchLabel: batchLabel ?? this.batchLabel,
        copyLabel: copyLabel ?? this.copyLabel,
        reprintLabel: reprintLabel ?? this.reprintLabel,
        canceledLabel: canceledLabel ?? this.canceledLabel,
        cancelReason: cancelReason ?? this.cancelReason,
        actionType: actionType ?? this.actionType,
        qrContent: qrContent ?? this.qrContent,
        thankYouMessage: thankYouMessage ?? this.thankYouMessage,
        at: at ?? this.at,
      );

  Map<String, Object?> tokens() => {
        'store_name': storeName,
        'store_shortcode': storeShortcode,
        'store_address': storeAddress,
        'outlet_name': storeName,
        'outlet_timezone': timezone,
        'currency_label': currencyLabel,
        'device_shortcode': deviceShortcode,
        'cashier_name': cashier,
        'cashier': cashier,
        'table_name': tableName,
        'guest_name': guestName,
        'ticket_type': ticketType,
        'printer_name': printerName,
        'printer_width_mm': printerWidthMm,
        'print_time': isoLocal(at),
        'batch_label': batchLabel,
        'copy_label': copyLabel,
        'reprint_flag': reprintLabel,
        'canceled_label': canceledLabel,
        'cancel_reason': cancelReason,
        'action_type': actionType,
        'qr_content': qrContent,
        'thank_you_message': thankYouMessage,
      };
}

/// `yyyy-MM-dd HH:mm:ss` in device-local time (renderer's date/datetime parser).
String isoLocal(DateTime t) {
  String p(int n) => n.toString().padLeft(2, '0');
  return '${t.year.toString().padLeft(4, '0')}-${p(t.month)}-${p(t.day)} ${p(t.hour)}:${p(t.minute)}:${p(t.second)}';
}

/// Builds ticket payloads. Pure; safe to unit-test without any transport.
class TicketPayloadBuilder {
  const TicketPayloadBuilder();

  /// BILL / RECEIPT_COPY payload. [flow] and [split] are the canonical money
  /// helper outputs; [receiptId] is the device-born id.
  Map<String, dynamic> bill({
    required TicketContext ctx,
    required List<PrintItem> items,
    required String receiptId,
    required money.MoneyFlow flow,
    required money.SplitResult split,
    Map<String, String> methodNames = const {},
    DateTime? paidAt,
  }) {
    final methodTypes = {for (final a in split.pay) a.outletMethodId: a.type};
    final primaryType = methodTypes.values.contains(money.PayType.cash) ? 'CASH' : 'NON_CASH';
    return {
      'tokens': {
        ...ctx.tokens(),
        'receipt_id': receiptId,
        'receipt_no': receiptId,
        'paid_at': isoLocal(paidAt ?? ctx.at),
        'transacted_at': isoLocal(paidAt ?? ctx.at),
        'item_count': items.fold<int>(0, (s, i) => s + i.qty),
        'payment_type': primaryType,
        // Money flow — canonical helper values, plus the short names the
        // renderer's MONEY_LINES block resolves by.
        'subtotal': flow.subtotal,
        'discount': flow.discountAmount,
        'discount_amount': flow.discountAmount,
        'voucher': 0.0,
        'voucher_amount': 0.0,
        'vat': flow.vatAmount,
        'vat_amount': flow.vatAmount,
        'sc': flow.scAmount,
        'sc_amount': flow.scAmount,
        'shipment': flow.shipmentAmount,
        'shipment_amount': flow.shipmentAmount,
        'rounding': flow.roundingAmount,
        'rounding_delta': flow.roundingAmount,
        'tips': split.tips,
        'tips_amount': split.tips,
        'total': flow.total,
        'paid': split.paid,
        'paid_amount': split.paid,
        'change': split.change,
      },
      'items': [for (final i in items) i.toJson()],
      'payments': [for (final a in split.pay) _payment(a, methodNames)],
    };
  }

  /// CAPTAIN_ORDER payload for one batch. When [batchIndex] is null the items
  /// are used as-is (single sheet).
  Map<String, dynamic> captainOrder({
    required TicketContext ctx,
    required List<PrintItem> items,
    int? batchIndex,
  }) =>
      _kitchenLike(ctx: ctx, items: items, batchIndex: batchIndex, ticketType: 'CAPTAIN_ORDER');

  /// CANCELED_ORDER payload (same captain-order route, labeled CANCELED).
  Map<String, dynamic> canceledOrder({
    required TicketContext ctx,
    required List<PrintItem> items,
    int? batchIndex,
  }) =>
      _kitchenLike(ctx: ctx, items: items, batchIndex: batchIndex, ticketType: 'CANCELED_ORDER');

  /// Captain-order sheets — one payload per batch, ordered by batch index
  /// (A/B/C). [batchLabels] supplies the label per index (defaults A,B,C…).
  List<Map<String, dynamic>> captainOrderSheets({
    required TicketContext ctx,
    required List<PrintItem> items,
    Map<int, String> batchLabels = const {},
    bool canceled = false,
  }) {
    final groups = <int, List<PrintItem>>{};
    for (final i in items) {
      groups.putIfAbsent(i.batchIndex, () => []).add(i);
    }
    final indices = groups.keys.toList()..sort();
    final out = <Map<String, dynamic>>[];
    for (final idx in indices) {
      final label = batchLabels[idx] ?? _letter(idx);
      final sheetCtx = _withBatch(ctx, label);
      out.add(canceled
          ? canceledOrder(ctx: sheetCtx, items: groups[idx]!, batchIndex: idx)
          : captainOrder(ctx: sheetCtx, items: groups[idx]!, batchIndex: idx));
    }
    return out;
  }

  /// BEV_LABEL payload — a single item.
  Map<String, dynamic> bevLabel({required TicketContext ctx, required PrintItem item}) {
    final c = TicketContext(
      storeName: ctx.storeName,
      storeShortcode: ctx.storeShortcode,
      cashier: ctx.cashier,
      tableName: ctx.tableName,
      guestName: ctx.guestName,
      ticketType: 'BEV_LABEL',
      printerName: ctx.printerName,
      printerWidthMm: ctx.printerWidthMm,
      deviceShortcode: ctx.deviceShortcode,
      batchLabel: ctx.batchLabel,
      at: ctx.at,
    );
    return {
      'tokens': {...ctx.tokens(), ...c.tokens(), 'ticket_type': 'BEV_LABEL'},
      'items': [item.toJson()],
      'payments': const [],
    };
  }

  /// SHIFT_OPEN / SHIFT_CLOSE / Z_REPORT payload from the (server) closing
  /// report. `totalSales` etc. are canonical ledger aggregates.
  Map<String, dynamic> shiftReport({
    required TicketContext ctx,
    String shiftId = '',
    DateTime? openedAt,
    DateTime? closedAt,
    double startingHousebank = 0,
    double? closingHousebank,
    double? cashReceived,
    double? cashVariance,
    double? payoutAmount,
    double totalSales = 0,
    int transactionCount = 0,
    DateTime? reportDate,
  }) =>
      {
        'tokens': {
          ...ctx.tokens(),
          'shift_id': shiftId,
          'shift_open_at': openedAt == null ? '' : isoLocal(openedAt),
          'shift_close_at': closedAt == null ? '' : isoLocal(closedAt),
          'starting_housebank': startingHousebank,
          'closing_housebank': closingHousebank,
          'cash_received': cashReceived,
          'cash_variance': cashVariance,
          'payout_amount': payoutAmount,
          'total_sales': totalSales,
          'transaction_count': transactionCount,
          'z_report_date': isoLocal(reportDate ?? ctx.at).substring(0, 10),
        },
        'items': const [],
        'payments': const [],
      };

  Map<String, dynamic> _kitchenLike({
    required TicketContext ctx,
    required List<PrintItem> items,
    required String ticketType,
    int? batchIndex,
  }) {
    final scoped = batchIndex == null ? items : items.where((i) => i.batchIndex == batchIndex).toList();
    return {
      'tokens': {...ctx.tokens(), 'ticket_type': ticketType},
      'items': [for (final i in scoped) i.toJson()],
      'payments': const [],
    };
  }

  Map<String, dynamic> _payment(money.PaymentAllocation a, Map<String, String> names) {
    final type = a.type == money.PayType.cash ? 'CASH' : 'NON_CASH';
    return {
      'name': names[a.outletMethodId] ?? a.outletMethodId,
      'code': type,
      'type': type,
      'amount': a.amount,
      'allocated': a.allocated,
      'change': a.change,
      'splitIndex': a.splitIndex,
      'reference': a.reference,
    };
  }

  static TicketContext _withBatch(TicketContext ctx, String label) => TicketContext(
        storeName: ctx.storeName,
        storeShortcode: ctx.storeShortcode,
        storeAddress: ctx.storeAddress,
        cashier: ctx.cashier,
        tableName: ctx.tableName,
        guestName: ctx.guestName,
        ticketType: ctx.ticketType,
        printerName: ctx.printerName,
        printerWidthMm: ctx.printerWidthMm,
        currencyLabel: ctx.currencyLabel,
        timezone: ctx.timezone,
        deviceShortcode: ctx.deviceShortcode,
        batchLabel: label,
        copyLabel: ctx.copyLabel,
        reprintLabel: ctx.reprintLabel,
        canceledLabel: ctx.canceledLabel,
        cancelReason: ctx.cancelReason,
        actionType: ctx.actionType,
        qrContent: ctx.qrContent,
        thankYouMessage: ctx.thankYouMessage,
        at: ctx.at,
      );

  static String _letter(int i) {
    if (i < 0) return '?';
    if (i < 26) return String.fromCharCode(65 + i);
    return 'B$i';
  }
}
