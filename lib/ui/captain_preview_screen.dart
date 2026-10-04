import 'package:flutter/material.dart';

import 'package:gundam_pos/data/print_format_store.dart';
import 'package:gundam_pos/logic/print_format_render.dart';
import 'package:gundam_pos/logic/print_payload.dart';
import 'package:gundam_pos/services/print_broker.dart';
import 'package:gundam_pos/state/app_session.dart';
import 'package:gundam_pos/state/order_controller.dart';
import 'package:gundam_pos/ui/preview_chrome.dart';

/// What one captain-order preview produced, and whether it is the outlet's own
/// published layout.
class CaptainPreviewRender {
  const CaptainPreviewRender({required this.text, required this.usedServerFormat, this.notice});

  final String text;
  final bool usedServerFormat;

  /// Honest explanation when the built-in layout is shown (never silent).
  final String? notice;
}

/// Pure: render the CAPTAIN_ORDER preview. Uses the outlet's published
/// CAPTAIN_ORDER format when there is one, else the built-in layout — the same
/// decision the printer makes, on the SAME payloads the printer sends
/// ([TicketPayloadBuilder.captainOrderSheets]), so preview and paper agree.
CaptainPreviewRender renderCaptainPreview({
  required PrintFormatStore? store,
  required List<Map<String, dynamic>> payloads,
  required int widthMm,
}) {
  final configured = store?.formatFor('CAPTAIN_ORDER');
  final builtin = builtinFormat('CAPTAIN_ORDER', widthMm: widthMm);
  var useBuiltin = configured == null;
  String? notice = configured == null
      ? 'No CAPTAIN_ORDER format from server yet — showing the built-in layout.'
      : store?.notice;

  final parts = <String>[];
  for (var i = 0; i < payloads.length; i++) {
    String body;
    final format = useBuiltin ? builtin : configured!;
    try {
      body = renderPrintFormat(format: format, ticketPayload: payloads[i], widthMm: widthMm)
          .lines
          .join('\n');
    } catch (e) {
      // A configured format that fails falls back honestly instead of crashing.
      useBuiltin = true;
      notice = 'Server CAPTAIN_ORDER format failed to render ($e) — showing the built-in layout.';
      body = renderPrintFormat(format: builtin, ticketPayload: payloads[i], widthMm: widthMm)
          .lines
          .join('\n');
    }
    if (parts.isNotEmpty) parts.add('');
    // Several batches print several sheets — say which one this is.
    if (payloads.length > 1) parts.add('— captain sheet ${i + 1} of ${payloads.length} —');
    parts.add(body);
  }

  return CaptainPreviewRender(
    text: parts.join('\n'),
    usedServerFormat: !useBuiltin,
    notice: notice,
  );
}

/// Full-screen CAPTAIN ORDER preview for the open order: exactly the sheets the
/// printer would send to the kitchen (grouped by batch, items grouped by menu).
class CaptainPreviewScreen extends StatefulWidget {
  const CaptainPreviewScreen({
    super.key,
    required this.session,
    required this.controller,
    this.initialWidthMm = 80,
  });

  final AppSession session;
  final OrderController controller;
  final int initialWidthMm;

  @override
  State<CaptainPreviewScreen> createState() => _CaptainPreviewScreenState();
}

class _CaptainPreviewScreenState extends State<CaptainPreviewScreen> {
  late int _widthMm = widget.initialWidthMm == 58 ? 58 : 80;

  /// Build the sheets through the SAME builder and context the printer uses.
  List<Map<String, dynamic>> _payloads() {
    final c = widget.controller;
    final d = widget.session.printDispatcher;
    final t = (c.tableName ?? '').trim();

    final items = <PrintItem>[];
    for (final l in c.cart.lines) {
      final it = PrintItem.fromCartLine(l);
      // The MENU label for the grouped header; the cart line carries no
      // category, so it is resolved exactly as the printer resolves it.
      it.menu = d?.routing.menuForItem(it.itemId) ?? '';
      items.add(it);
    }

    final base = d?.context ?? TicketContext();
    final ctx = base.copyWith(
      ticketType: 'CAPTAIN_ORDER',
      tableName: c.tableName ?? '',
      tableNumber: RegExp(r'^\d+$').hasMatch(t) ? t : '',
      openedBy: c.openedByName,
    );
    // Same rule as the printed ticket: identical rows merge per batch.
    return const TicketPayloadBuilder().captainOrderSheets(ctx: ctx, items: mergePrintItems(items));
  }

  @override
  Widget build(BuildContext context) {
    final preview = renderCaptainPreview(
      store: widget.session.printFormats,
      payloads: _payloads(),
      widthMm: _widthMm,
    );
    return PreviewChrome(
      prefix: 'captain',
      title: 'Captain order preview',
      ticketLabel: 'CAPTAIN_ORDER',
      widthMm: _widthMm,
      onWidthChanged: (w) => setState(() => _widthMm = w),
      text: preview.text,
      usedServerFormat: preview.usedServerFormat,
      notice: preview.notice,
      footer: 'Preview only — this is what the kitchen sheet will look like for '
          'the items currently in this order.',
    );
  }
}
