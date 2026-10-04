/// BILL preview — shows EXACTLY what the BILL ticket will print, using the SAME
/// engine as the printer ([renderPrintFormat]) and the outlet's published BILL
/// format when present, else the built-in layout ([builtinFormat]).
///
/// A bill that is not paid yet is a PREVIEW: money lines run subtotal → total
/// WITHOUT paid/change, and a footnote states the server computes the final
/// amounts at settle. The preview must never lie, so it makes the same
/// store-vs-builtin decision the printer makes.
library;

import 'package:flutter/material.dart';

import 'package:gundam_pos/data/print_format_store.dart';
import 'package:gundam_pos/logic/cart.dart';
import 'package:gundam_pos/logic/discount_voucher.dart' as dv;
import 'package:gundam_pos/logic/money.dart' as money;
import 'package:gundam_pos/logic/print_format_render.dart';
import 'package:gundam_pos/logic/print_payload.dart';
import 'package:gundam_pos/models/config_models.dart';
import 'package:gundam_pos/services/print_broker.dart';
import 'package:gundam_pos/state/app_session.dart';
import 'package:gundam_pos/state/order_controller.dart';
import 'package:gundam_pos/state/pricing_controller.dart';
import 'package:gundam_pos/ui/preview_chrome.dart';

/// Result of a preview render: the plain-text bill + which layout produced it.
class BillPreviewRender {
  BillPreviewRender({required this.text, required this.usedServerFormat, this.notice});

  final String text;

  /// true → the outlet's published BILL format was used; false → built-in.
  final bool usedServerFormat;

  /// Honest explanation when the built-in layout is shown (or a format notice).
  final String? notice;
}

/// Pure: render the BILL preview text. Uses the published BILL format from
/// [store] when present, else the built-in layout — the same decision the
/// printer ([PrintBroker.renderTicket]) makes.
BillPreviewRender renderBillPreview({
  required PrintFormatStore? store,
  required Map<String, dynamic> payload,
  required int widthMm,
}) {
  final configured = store?.formatFor('BILL');
  final builtin = builtinFormat('BILL', widthMm: widthMm);
  if (configured != null) {
    try {
      final r = renderPrintFormat(format: configured, ticketPayload: payload, widthMm: widthMm);
      return BillPreviewRender(text: r.lines.join('\n'), usedServerFormat: true, notice: store?.notice);
    } catch (e) {
      // Mirror the printer ([PrintBroker.renderTicket]): a configured format
      // that fails to render falls back to the built-in layout with an honest
      // notice, instead of crashing or silently showing the wrong ticket.
      final r = renderPrintFormat(format: builtin, ticketPayload: payload, widthMm: widthMm);
      return BillPreviewRender(
        text: r.lines.join('\n'),
        usedServerFormat: false,
        notice: 'Server BILL format failed to render ($e) — showing the built-in layout.',
      );
    }
  }
  final r = renderPrintFormat(format: builtin, ticketPayload: payload, widthMm: widthMm);
  return BillPreviewRender(
    text: r.lines.join('\n'),
    usedServerFormat: false,
    notice: 'No BILL format from server yet — showing the built-in layout.',
  );
}

/// Build the BILL ticket payload for an UNPAID order.
///
/// SINGLE SOURCE: it delegates to [TicketPayloadBuilder.bill] with
/// `settled: false` — the EXACT method the print path calls — so the preview
/// and the printed bill share one token builder and cannot drift. Paid and
/// change come back as EMPTY strings (not absent), so the money-flow block
/// skips them on an unpaid preview instead of printing a literal token.
Map<String, dynamic> buildBillPreviewPayload({
  required Cart cart,
  required TenantConfig config,
  PricingController? pricing,
  String storeName = '',
  String storeShortcode = '',
  String storeAddress = '',
  String storePhone = '',
  String storeSocial = '',
  String storeInstagram = '',
  String storeTiktok = '',
  String storeEmail = '',
  String groupName = '',
  String groupShortcode = '',
  String tableName = '',
  String guestName = '',
  String cashier = '',
  String openedBy = '',
  String deviceShortcode = '',
  String deviceLabel = '',
  String posClientId = '',
  String currencyLabel = '',
  String timezone = '',
  String receiptId = '',
  double shipmentAmount = 0,
  DateTime? now,
}) {
  final at = now ?? DateTime.now();
  final lines = <money.MoneyLine>[
    for (final l in cart.lines)
      money.MoneyLine(
        subtotal: l.lineSubtotal,
        vatMode: l.vatMode,
        vatRate: config.itemById(l.itemId)?.vatRate,
        scMode: l.scMode,
        scRate: config.itemById(l.itemId)?.scRate,
      ),
  ];
  final subtotal = lines.fold<double>(0, (s, l) => s + l.subtotal);
  final selection = pricing?.selection ?? dv.PricingSelection.none;
  final discountAmount = selection.amountFor(subtotal);
  final flow = money.computeMoneyFlow(lines, discountAmount, shipmentAmount, config.shift.roundingMode);

  final t = tableName.trim();
  final tableNumber = RegExp(r'^\d+$').hasMatch(t) ? t : '';
  final ctx = TicketContext(
    storeName: storeName,
    storeShortcode: storeShortcode,
    storeAddress: storeAddress,
    storePhone: storePhone,
    storeSocial: storeSocial,
    storeInstagram: storeInstagram,
    storeTiktok: storeTiktok,
    storeEmail: storeEmail,
    groupName: groupName,
    groupShortcode: groupShortcode,
    cashier: cashier,
    tableName: tableName,
    guestName: guestName,
    ticketType: 'BILL',
    deviceShortcode: deviceShortcode,
    deviceLabel: deviceLabel,
    posClientId: posClientId,
    currencyLabel: currencyLabel,
    timezone: timezone,
    tableNumber: tableNumber,
    openedBy: openedBy,
    at: at,
  );

  // A discount and a voucher are mutually exclusive — put the amount under the
  // one that is applied so MONEY_LINES prints exactly the right caption.
  final voucherAmount = selection.voucher != null ? discountAmount : 0.0;
  final discountOnly = selection.discount != null ? discountAmount : 0.0;

  return const TicketPayloadBuilder().bill(
    ctx: ctx,
    items: mergePrintItems([for (final l in cart.lines) PrintItem.fromCartLine(l)]),
    receiptId: receiptId,
    flow: flow,
    settled: false, // unpaid preview: paid/change/payment empty, not absent
    discountName: selection.discount?.name ?? '',
    // The POS voucher master carries no separate code — its name is all we have.
    voucherName: selection.voucher?.name ?? '',
    discountAmount: discountOnly,
    voucherAmount: voucherAmount,
    paidAt: at,
  );
}

/// Full-screen bill preview. Width toggles 58 mm (32 cells) / 80 mm (48 cells);
/// the text is monospace and scrollable exactly as it will hit the paper.
class BillPreviewScreen extends StatefulWidget {
  const BillPreviewScreen({
    super.key,
    required this.session,
    required this.controller,
    this.initialWidthMm = 80,
    this.now,
  });

  final AppSession session;
  final OrderController controller;
  final int initialWidthMm;

  /// Test seam for the printed date/time (defaults to the wall clock).
  final DateTime Function()? now;

  @override
  State<BillPreviewScreen> createState() => _BillPreviewScreenState();
}

class _BillPreviewScreenState extends State<BillPreviewScreen> {
  late int _widthMm = widget.initialWidthMm == 58 ? 58 : 80;

  Map<String, dynamic> _payload() {
    final c = widget.controller;
    final s = widget.session;
    final o = c.config.outlet;
    return buildBillPreviewPayload(
      cart: c.cart,
      config: c.config,
      pricing: c.pricing,
      storeName: o.name.isNotEmpty ? o.name : (s.ctx.outletName ?? ''),
      storeShortcode: o.shortcode,
      storeAddress: o.address,
      storePhone: o.phone,
      storeSocial: o.socialMedia,
      storeInstagram: o.instagram,
      storeTiktok: o.tiktok,
      storeEmail: o.email,
      groupName: c.config.group.name,
      groupShortcode: c.config.group.shortcode,
      cashier: s.ctx.userName ?? '',
      deviceShortcode: s.ctx.shortcode ?? '',
      deviceLabel: s.ctx.shortcode ?? '',
      posClientId: s.ctx.deviceId ?? '',
      currencyLabel: o.currencyLabel.isNotEmpty ? o.currencyLabel : c.config.shift.currencyLabel,
      timezone: c.config.shift.timezone ?? o.timezone,
      tableName: c.tableName ?? '',
      guestName: c.guestName ?? '',
      openedBy: c.openedByName,
      now: widget.now?.call(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final preview = renderBillPreview(
      store: widget.session.printFormats,
      payload: _payload(),
      widthMm: _widthMm,
    );
    return PreviewChrome(
      prefix: 'bill',
      title: 'Bill preview',
      ticketLabel: 'BILL',
      widthMm: _widthMm,
      onWidthChanged: (w) => setState(() => _widthMm = w),
      text: preview.text,
      usedServerFormat: preview.usedServerFormat,
      notice: preview.notice,
      footer: 'Preview only — the server calculates the final amounts when the bill is settled.',
    );
  }
}
