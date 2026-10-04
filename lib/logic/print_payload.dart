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
  int qty;

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
    this.menu = '',
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

  /// What makes two rows "the same line" ON PAPER: item + price level + batch +
  /// the exact modifier set (name + price + qty). Two picks of the same item
  /// with the same options collapse into one row whose qty is the sum.
  String get printSignature {
    final mods = [
      for (final m in modifiers) '${m.name}:${m.price}:${m.qty}',
    ]..sort();
    return '$itemId|$priceLevelIndex|$batchIndex|${mods.join(",")}';
  }
  int qty; // mutable: identical picks merge into one printed row
  final double unitPrice;
  double? lineTotal;
  final List<PrintModifier> modifiers;
  final int priceLevelIndex;
  final String priceLevelLabel;
  final int batchIndex;

  /// MENU (category) name this line belongs to — drives the grouped kitchen
  /// header. Filled by the print dispatcher from the synced catalog (the cart
  /// line itself carries no category).
  String menu;

  Map<String, dynamic> toJson() => {
        'name': name,
        'qty': qty,
        'price': unitPrice,
        'lineTotal': lineTotal ?? unitPrice * qty,
        'priceLevelIndex': priceLevelIndex,
        'priceLevel': priceLevelLabel,
        'batchIndex': batchIndex,
        if (menu.isNotEmpty) 'menu': menu,
        if (modifiers.isNotEmpty) 'modifiers': [for (final m in modifiers) m.toJson()],
      };
}

/// Header/context values shared by every ticket type (store, device, cashier,
/// table, print metadata). Each field maps to a server-registry token; anything
/// the POS has no source for is still emitted as an EMPTY string by [tokens]
/// (never absent) so the renderer's `show_if_present` / empty-VAR skip applies
/// instead of printing a literal `{token}` to a customer.
class TicketContext {
  TicketContext({
    this.storeName = '',
    this.storeShortcode = '',
    this.storeAddress = '',
    this.storePhone = '',
    this.storeSocial = '',
    this.storeInstagram = '',
    this.storeTiktok = '',
    this.storeEmail = '',
    this.groupName = '',
    this.groupShortcode = '',
    this.cashier = '',
    this.tableName = '',
    this.guestName = '',
    this.ticketType = 'BILL',
    this.printerName = '',
    this.printerWidthMm = 80,
    this.currencyLabel = '',
    this.timezone = '',
    this.deviceShortcode = '',
    this.deviceLabel = '',
    this.posClientId = '',
    this.formatName = '',
    this.formatVersion = '',
    this.transactionKind = 'SALE',
    this.notes = '',
    this.pax = '',
    this.orderNo = '',
    this.openedAt = '',
    this.batchLabel = '',
    this.copyLabel = '',
    this.reprintLabel = '',
    this.canceledLabel = '',
    this.cancelReason = '',
    this.actionType = '',
    this.qrContent = '',
    this.thankYouMessage = '',
    this.legalFooter = '',
    this.custom1 = '',
    this.custom2 = '',
    this.custom3 = '',
    this.custom4 = '',
    this.tableNumber = '',
    this.openedBy = '',
    this.closedBy = '',
    this.closedAt = '',
    this.vatPercent = '',
    this.scPercent = '',
    DateTime? at,
  }) : at = at ?? DateTime.now();

  final String storeName;
  final String storeShortcode;
  final String storeAddress;
  final String storePhone;
  final String storeSocial;
  final String storeInstagram;
  final String storeTiktok;
  final String storeEmail;
  final String groupName;
  final String groupShortcode;
  final String cashier;
  final String tableName;
  final String guestName;
  final String ticketType;
  final String printerName;
  final int printerWidthMm;
  final String currencyLabel;
  final String timezone;
  final String deviceShortcode;

  /// Editable POS device display name (`{device_label}`); empty when unknown.
  final String deviceLabel;

  /// Device identifier for support (`{pos_client_id}`).
  final String posClientId;

  /// Published format name/version currently bound (`{format_name}` / `{format_version}`).
  final String formatName;
  final String formatVersion;

  /// `{transaction_kind}`: SALE / REFUND / VOID_REVERSAL. Defaults to SALE.
  final String transactionKind;

  /// Cashier order notes (`{notes}`).
  final String notes;

  /// Guest count (`{pax}`) — string so an unset count prints nothing.
  final String pax;

  /// Hanging order number (`{order_no}`).
  final String orderNo;

  /// When the order was opened (`{opened_at}`) as local datetime; '' when unset.
  final String openedAt;

  final String batchLabel;
  final String copyLabel;
  final String reprintLabel;
  final String canceledLabel;
  final String cancelReason;
  final String actionType;
  final String qrContent;
  final String thankYouMessage;

  /// Legal/regulatory footer (`{legal_footer}`) and free per-outlet slots
  /// (`{custom_1..4}`). No server source exists yet → empty (never a literal).
  final String legalFooter;
  final String custom1;
  final String custom2;
  final String custom3;
  final String custom4;

  /// Numeric table NUMBER (`{table_number}`). Blank when the order's table label
  /// is not numeric (a free-text table like "Terrace" has no number).
  final String tableNumber;

  /// Cashier who OPENED the bill (`{cashier_name_opened_bill}`) — the order's
  /// opener, which is not always the payer on a shared table.
  final String openedBy;

  /// Cashier who CLOSED/settled the bill (`{cashier_name_closed_bill}`): the
  /// payer. Empty on a captain sheet, which prints BEFORE payment.
  final String closedBy;

  /// When the bill was closed (`{datetime_closed_bill}`), i.e. paid_at.
  final String closedAt;

  /// Effective outlet VAT / service-charge percent (`{vat_percent}`,
  /// `{sc_percent}`) — the rate the outlet master applies to tagged lines.
  final String vatPercent;
  final String scPercent;

  final DateTime at;

  /// Focused overrides for per-ticket context (table/batch/reprint labels).
  TicketContext copyWith({
    String? storeName,
    String? storeShortcode,
    String? storeAddress,
    String? storePhone,
    String? storeSocial,
    String? storeInstagram,
    String? storeTiktok,
    String? storeEmail,
    String? groupName,
    String? groupShortcode,
    String? cashier,
    String? tableName,
    String? guestName,
    String? ticketType,
    String? printerName,
    int? printerWidthMm,
    String? currencyLabel,
    String? timezone,
    String? deviceShortcode,
    String? deviceLabel,
    String? posClientId,
    String? formatName,
    String? formatVersion,
    String? transactionKind,
    String? notes,
    String? pax,
    String? orderNo,
    String? openedAt,
    String? batchLabel,
    String? copyLabel,
    String? reprintLabel,
    String? canceledLabel,
    String? cancelReason,
    String? actionType,
    String? qrContent,
    String? thankYouMessage,
    String? legalFooter,
    String? custom1,
    String? custom2,
    String? custom3,
    String? custom4,
    String? tableNumber,
    String? openedBy,
    String? closedBy,
    String? closedAt,
    String? vatPercent,
    String? scPercent,
    DateTime? at,
  }) =>
      TicketContext(
        storeName: storeName ?? this.storeName,
        storeShortcode: storeShortcode ?? this.storeShortcode,
        storeAddress: storeAddress ?? this.storeAddress,
        storePhone: storePhone ?? this.storePhone,
        storeSocial: storeSocial ?? this.storeSocial,
        storeInstagram: storeInstagram ?? this.storeInstagram,
        storeTiktok: storeTiktok ?? this.storeTiktok,
        storeEmail: storeEmail ?? this.storeEmail,
        groupName: groupName ?? this.groupName,
        groupShortcode: groupShortcode ?? this.groupShortcode,
        cashier: cashier ?? this.cashier,
        tableName: tableName ?? this.tableName,
        guestName: guestName ?? this.guestName,
        ticketType: ticketType ?? this.ticketType,
        printerName: printerName ?? this.printerName,
        printerWidthMm: printerWidthMm ?? this.printerWidthMm,
        currencyLabel: currencyLabel ?? this.currencyLabel,
        timezone: timezone ?? this.timezone,
        deviceShortcode: deviceShortcode ?? this.deviceShortcode,
        deviceLabel: deviceLabel ?? this.deviceLabel,
        posClientId: posClientId ?? this.posClientId,
        formatName: formatName ?? this.formatName,
        formatVersion: formatVersion ?? this.formatVersion,
        transactionKind: transactionKind ?? this.transactionKind,
        notes: notes ?? this.notes,
        pax: pax ?? this.pax,
        orderNo: orderNo ?? this.orderNo,
        openedAt: openedAt ?? this.openedAt,
        batchLabel: batchLabel ?? this.batchLabel,
        copyLabel: copyLabel ?? this.copyLabel,
        reprintLabel: reprintLabel ?? this.reprintLabel,
        canceledLabel: canceledLabel ?? this.canceledLabel,
        cancelReason: cancelReason ?? this.cancelReason,
        actionType: actionType ?? this.actionType,
        qrContent: qrContent ?? this.qrContent,
        thankYouMessage: thankYouMessage ?? this.thankYouMessage,
        legalFooter: legalFooter ?? this.legalFooter,
        custom1: custom1 ?? this.custom1,
        custom2: custom2 ?? this.custom2,
        custom3: custom3 ?? this.custom3,
        custom4: custom4 ?? this.custom4,
        tableNumber: tableNumber ?? this.tableNumber,
        openedBy: openedBy ?? this.openedBy,
        closedBy: closedBy ?? this.closedBy,
        closedAt: closedAt ?? this.closedAt,
        vatPercent: vatPercent ?? this.vatPercent,
        scPercent: scPercent ?? this.scPercent,
        at: at ?? this.at,
      );

  /// The FULL server-registry vocabulary for this ticket, as one map.
  ///
  /// SINGLE SOURCE: both the BILL preview ([buildBillPreviewPayload]) and the
  /// print path ([TicketPayloadBuilder]) build their token map on top of this,
  /// so preview and paper can never drift. Every token the server declares is
  /// present — sourced when the POS has it, EMPTY otherwise — so a block with
  /// `show_if_present` skips instead of printing a literal `{token}`.
  /// Ticket-specific money/payment/item tokens are overwritten by the builder.
  Map<String, Object?> tokens() => {
        // Store / outlet
        'store_name': storeName,
        'store_shortcode': storeShortcode,
        'store_address': storeAddress,
        'store_phone': storePhone,
        'store_social': storeSocial,
        'store_instagram': storeInstagram,
        'store_tiktok': storeTiktok,
        'store_email': storeEmail,
        'outlet_name': storeName,
        'outlet_timezone': timezone,
        'currency_label': currencyLabel,
        // Group / device
        'group_name': groupName,
        'group_shortcode': groupShortcode,
        'device_label': deviceLabel,
        'device_shortcode': deviceShortcode,
        'cashier_name': cashier,
        'cashier': cashier,
        'pos_client_id': posClientId,
        // Transaction
        'receipt_id': '',
        'receipt_no': '',
        'order_no': orderNo,
        'transacted_at': '',
        'opened_at': openedAt,
        'paid_at': '',
        'table_name': tableName,
        'table_number': tableNumber,
        'cashier_name_opened_bill': openedBy,
        'cashier_name_closed_bill': closedBy,
        'datetime_closed_bill': closedAt,
        'pax': pax,
        'transaction_kind': transactionKind.isEmpty ? 'SALE' : transactionKind,
        'notes': notes,
        'guest_name': guestName,
        // Item lines — row-scoped on the ticket; global '' so a stray VAR
        // never prints a literal token.
        'item_count': '',
        'item_name': '',
        'item_qty': '',
        'item_price': '',
        'item_line_total': '',
        'modifier_name': '',
        'modifier_price': '',
        'modifier_qty': '',
        'batch_label': batchLabel,
        // Money flow — filled per ticket by the builder.
        'subtotal': '',
        'discount_name': '',
        'discount_amount': '',
        'discount': '',
        'voucher_name': '',
        'voucher_amount': '',
        'voucher_code': '',
        'voucher': '',
        'vat_amount': '',
        'vat': '',
        'sc_amount': '',
        'sc': '',
        'shipment_amount': '',
        'shipment': '',
        'shipment_description': '',
        'rounding_delta': '',
        'rounding': '',
        'tips_amount': '',
        'tips': '',
        'gross_revenue': '',
        'total': '',
        'paid_amount': '',
        'paid': '',
        'change': '',
        // Payment — row-scoped, '' globally.
        'payment_type': '',
        'payment_method': '',
        'payment_amount': '',
        'payment_reference': '',
        'payment_tendered': '',
        'split_index': '',
        // Print / routing
        'ticket_type': ticketType,
        'format_name': formatName,
        'format_version': formatVersion,
        'printer_name': printerName,
        'printer_width_mm': printerWidthMm,
        'print_time': isoLocal(at),
        'reprint_flag': reprintLabel,
        'copy_label': copyLabel,
        // Shift / closing — only the shift-report builder fills these.
        'shift_id': '',
        'shift_open_at': '',
        'shift_close_at': '',
        'starting_housebank': '',
        'closing_housebank': '',
        'cash_received': '',
        'cash_variance': '',
        'payout_amount': '',
        'total_sales': '',
        'transaction_count': '',
        'z_report_date': '',
        // Approval / cancel / refund — POS prints cancel labels only; the
        // void/refund/approval tokens have no POS source (web-app only).
        'action_type': actionType,
        'canceled_label': canceledLabel,
        'cancel_reason': cancelReason,
        'void_reason': '',
        'refund_amount': '',
        'refund_reason': '',
        'approval_status': '',
        'requester_name': '',
        'approver_name': '',
        'approval_acted_at': '',
        // Tax / QR / legal / custom
        'vat_percent': vatPercent,
        'sc_percent': scPercent,
        'qr_content': qrContent,
        'legal_footer': legalFooter,
        'thank_you_message': thankYouMessage,
        'custom_1': custom1,
        'custom_2': custom2,
        'custom_3': custom3,
        'custom_4': custom4,
        'current_date': '',
        'current_time': '',
      };
}

/// `yyyy-MM-dd HH:mm:ss` in device-local time (renderer's date/datetime parser).
String isoLocal(DateTime t) {
  String p(int n) => n.toString().padLeft(2, '0');
  return '${t.year.toString().padLeft(4, '0')}-${p(t.month)}-${p(t.day)} ${p(t.hour)}:${p(t.minute)}:${p(t.second)}';
}

String _two(int n) => n.toString().padLeft(2, '0');

/// Builds ticket payloads. Pure; safe to unit-test without any transport.
/// Merge identical rows for PRINT: same item + price level + batch + modifiers
/// collapse into ONE row with the summed qty (and line total). Captain tickets
/// are printed per batch, so a line can still break DOWN across batches — but
/// never twice inside the batch it renders.
List<PrintItem> mergePrintItems(Iterable<PrintItem> items) {
  final out = <PrintItem>[];
  final seen = <String, int>{};
  for (final it in items) {
    final at = seen[it.printSignature];
    if (at == null) {
      seen[it.printSignature] = out.length;
      out.add(it);
      continue;
    }
    final kept = out[at];
    kept.qty += it.qty;
    kept.lineTotal = money.round2((kept.lineTotal ?? 0) + (it.lineTotal ?? 0));
  }
  return out;
}

class TicketPayloadBuilder {
  const TicketPayloadBuilder();

  /// BILL / RECEIPT_COPY payload. [flow] and [split] are the canonical money
  /// helper outputs; [receiptId] is the device-born id.
  ///
  /// [settled] = false builds an UNPAID PREVIEW: paid/change/tips/paid_at and
  /// every payment token are sent as EMPTY (not absent) so the money-flow block
  /// skips them instead of printing the token literally. This is the SAME method
  /// the print path calls with `settled: true`, so preview and paper share one
  /// token builder and can never drift.
  ///
  /// Discount vs voucher are mutually exclusive (1 bill = 1 of them): pass the
  /// applied one so its caption/amount print on the right line.
  Map<String, dynamic> bill({
    required TicketContext ctx,
    required List<PrintItem> items,
    required String receiptId,
    required money.MoneyFlow flow,
    money.SplitResult? split,
    Map<String, String> methodNames = const {},
    DateTime? paidAt,
    bool settled = true,
    String discountName = '',
    String voucherName = '',
    double? discountAmount,
    double? voucherAmount,
  }) {
    final allocations = split?.pay ?? const <money.PaymentAllocation>[];
    final methodTypes = {for (final a in allocations) a.outletMethodId: a.type};
    final paidType = methodTypes.values.contains(money.PayType.cash) ? 'CASH' : 'NON_CASH';
    final primaryType = settled && split != null ? paidType : '';
    // A discount and a voucher are mutually exclusive; callers pass the one that
    // applied. Default the discount to the money-flow's before-tax amount (it IS
    // the applied discount/voucher) so a caller that omits the split still shows
    // the line correctly.
    final disc = discountAmount ?? (voucherAmount == null ? flow.discountAmount : 0.0);
    final voucher = voucherAmount ?? 0.0;
    final at = paidAt ?? ctx.at;
    return {
      'tokens': {
        ...ctx.tokens(),
        'receipt_id': receiptId,
        'receipt_no': receiptId,
        'paid_at': settled ? isoLocal(at) : '',
        'transacted_at': settled ? isoLocal(at) : '',
        // Bill-lifecycle: the CLOSER is the payer (cashier performance belongs to
        // paid_by) unless the caller supplied one; the close time is paid_at.
        'cashier_name_closed_bill': ctx.closedBy.isEmpty ? ctx.cashier : ctx.closedBy,
        'datetime_closed_bill': settled ? (ctx.closedAt.isEmpty ? isoLocal(at) : ctx.closedAt) : '',
        'current_date': settled ? '' : '${at.year.toString().padLeft(4, '0')}-${_two(at.month)}-${_two(at.day)}',
        'current_time': settled ? '' : '${_two(at.hour)}:${_two(at.minute)}',
        'item_count': items.fold<int>(0, (s, i) => s + i.qty),
        'payment_type': primaryType,
        // Money flow — canonical helper values, plus the short names the
        // renderer's MONEY_LINES block resolves by.
        'subtotal': flow.subtotal,
        'discount': disc,
        'discount_amount': disc,
        'discount_name': discountName,
        'voucher_name': voucherName,
        'voucher': voucher,
        'voucher_amount': voucher,
        'voucher_code': voucherName,
        'vat': flow.vatAmount,
        'vat_amount': flow.vatAmount,
        'sc': flow.scAmount,
        'sc_amount': flow.scAmount,
        'shipment': flow.shipmentAmount,
        'shipment_amount': flow.shipmentAmount,
        'rounding': flow.roundingAmount,
        'rounding_delta': flow.roundingAmount,
        'tips': split?.tips ?? '',
        'tips_amount': split?.tips ?? '',
        'gross_revenue': money.round2(flow.total - flow.shipmentAmount - flow.roundingAmount),
        'total': flow.total,
        'paid': split?.paid ?? '',
        'paid_amount': split?.paid ?? '',
        'change': split?.change ?? '',
      },
      'items': [for (final i in items) i.toJson()],
      'payments': [for (final a in allocations) _payment(a, methodNames)],
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

  /// BEV_LABEL payload — a single item. Uses [TicketContext.copyWith] (NOT a
  /// fresh context) so every identity token the caller supplied survives; a new
  /// context would silently blank store_address/store_phone/group_* here.
  Map<String, dynamic> bevLabel({required TicketContext ctx, required PrintItem item}) {
    final c = ctx.copyWith(ticketType: 'BEV_LABEL');
    return {
      'tokens': c.tokens(),
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

  static TicketContext _withBatch(TicketContext ctx, String label) => ctx.copyWith(batchLabel: label);

  static String _letter(int i) {
    if (i < 0) return '?';
    if (i < 26) return String.fromCharCode(65 + i);
    return 'B$i';
  }
}
