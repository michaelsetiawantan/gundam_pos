/// Print dispatcher — turns the synced routing into actual broker submissions
/// at the real POS moments (send-cart, settle, same-day reprint).
///
/// It resolves a ticket type to printer(s) from [PrinterRouting], renders the
/// payload with [TicketPayloadBuilder], and hands jobs to the [PrintBroker]
/// queue. It NEVER throws and NEVER blocks a sale: a missing printer or an
/// unsupported transport becomes an honest [PrintOutcome.alerts] entry instead.
///
/// Transports: NETWORK :9100, Classic Bluetooth SPP, and USB Host (the four
/// common serial bridge chips are built into the APK) write bytes on this build.
library;

import 'package:gundam_pos/logic/money.dart' as money;
import 'package:gundam_pos/logic/print_format_render.dart';
import 'package:gundam_pos/logic/print_payload.dart';
import 'package:gundam_pos/services/escpos.dart';
import 'package:gundam_pos/services/print_broker.dart';
import 'package:gundam_pos/services/print_log.dart';
import 'package:gundam_pos/services/print_routing.dart';
import 'package:gundam_pos/services/printer_health.dart';

/// What a dispatch attempt produced: the rendered jobs it queued, plus any
/// honest warnings (no printer configured, unsupported transport, link error).
class PrintOutcome {
  const PrintOutcome({this.printed = const [], this.alerts = const []});

  final List<TicketRender> printed;
  final List<String> alerts;

  bool get ok => alerts.isEmpty;

  static const PrintOutcome none = PrintOutcome();
}

/// Same-day reprint memory for one receipt (bill args + the whole-order items).
class _Reprint {
  const _Reprint({
    required this.items,
    required this.receiptId,
    required this.flow,
    required this.split,
    required this.methodNames,
    required this.tableName,
    this.discountName = '',
    this.voucherName = '',
    this.discountAmount,
    this.voucherAmount,
  });

  final List<PrintItem> items;
  final String receiptId;
  final money.MoneyFlow flow;
  final money.SplitResult split;
  final Map<String, String> methodNames;
  final String? tableName;
  final String discountName;
  final String voucherName;
  final double? discountAmount;
  final double? voucherAmount;
}

class PrintDispatcher {
  PrintDispatcher({
    required this.broker,
    required this.routing,
    TicketContext? context,
    TicketPayloadBuilder payloads = const TicketPayloadBuilder(),
    PrinterHealthChecker? health,
    PrintLogAudit? logs,
  })  : context = context ?? TicketContext(),
        _payloads = payloads,
        _health = health ?? PrinterHealthChecker(),
        _logs = logs;

  /// Local print-attempt audit (null → logging disabled). Additive: the
  /// dispatcher's alerts and never-throw contract are unchanged.
  PrintLogAudit? _logs;

  /// Live broker (swapped when the format store / transport is rebuilt).
  PrintBroker broker;

  /// Routing model, re-set on each config refresh.
  PrinterRouting routing;

  /// Base ticket context (store/cashier/device); per-ticket fields are copied.
  TicketContext context;

  /// Swap the audit wired into the print path (mirrors broker/routing reset).
  set logs(PrintLogAudit? value) => _logs = value;

  final TicketPayloadBuilder _payloads;
  final PrinterHealthChecker _health;

  final Map<String, _Reprint> _reprints = {};

  bool hasReprint(String receiptId) => _reprints.containsKey(receiptId);

  /// Known-but-unsupported printers on this outlet (reported, not dropped).
  List<ClientPrinter> get unsupportedPrinters => routing.unsupportedPrinters;

  /// Transport-level link check per active printer, reported the way the rest
  /// of the app reports it ([PrinterLink] — unknown, never a false "healthy").
  Future<Map<String, PrinterLink>> checkHealth() async {
    final out = <String, PrinterLink>{};
    for (final p in routing.activePrinters) {
      out[p.id] = await _health.check(
        transport: p.transport,
        host: p.ip,
        port: p.port,
        bluetoothMac: p.bluetoothMac,
        usbVidPid: p.usbVidPid,
        usbChip: p.usbChip,
      );
    }
    return out;
  }

  // ------------------------------------------------------------------ BILL ---

  /// Print the settled bill to every outlet-level BILL printer.
  Future<PrintOutcome> printBill({
    required List<PrintItem> items,
    required String receiptId,
    required money.MoneyFlow flow,
    required money.SplitResult split,
    Map<String, String> methodNames = const {},
    String? tableName,
    String? tableNumber,
    String? openedBy,
    DateTime? paidAt,
    bool reprint = false,
    String discountName = '',
    String voucherName = '',
    double? discountAmount,
    double? voucherAmount,
    /// The settle took CASH → ask the receipt printer to pop the drawer.
    bool openDrawer = false,
  }) async {
      final ctx = context.copyWith(
        ticketType: 'BILL',
        tableName: tableName ?? context.tableName,
        tableNumber: tableNumber ?? context.tableNumber,
        openedBy: openedBy ?? context.openedBy,
        reprintLabel: reprint ? 'REPRINT' : '',
      );
    final payload = _payloads.bill(
      ctx: ctx,
      items: items,
      receiptId: receiptId,
      flow: flow,
      split: split,
      methodNames: methodNames,
      paidAt: paidAt,
      discountName: discountName,
      voucherName: voucherName,
      discountAmount: discountAmount,
      voucherAmount: voucherAmount,
    );
    // The drawer kick rides the bill job itself (same connection, same queue).
    if (openDrawer) payload['drawer_pulse'] = true;
    if (!reprint) {
      _reprints[receiptId] = _Reprint(
        items: items,
        receiptId: receiptId,
        flow: flow,
        split: split,
        methodNames: methodNames,
        tableName: tableName,
        discountName: discountName,
        voucherName: voucherName,
        discountAmount: discountAmount,
        voucherAmount: voucherAmount,
      );
    }
    return _print(ticketType: 'BILL', payload: payload, printers: routing.billPrinters(), receiptId: receiptId, orderId: null);
  }

  // ------------------------------------------- captain order + bev labels ---

  /// The send-cart moment: one captain sheet per batch, then a bev label per
  /// beverage item.
  Future<PrintOutcome> printSendCart({
    required List<PrintItem> items,
    String? tableName,
    String? tableNumber,
    String? openedBy,
  }) async {
    // Captain sheets MERGE identical rows (per batch); BEV labels never do — a
    // beverage label printer makes ONE label per product, so qty 2 means two
    // labels, not one label reading "2".
    final captain = await printCaptainOrder(
      items: mergePrintItems(items),
      tableName: tableName, tableNumber: tableNumber, openedBy: openedBy,
    );
    final bev = await printBevLabels(items: items, tableName: tableName);
    return PrintOutcome(
      printed: [...captain.printed, ...bev.printed],
      alerts: [...captain.alerts, ...bev.alerts],
    );
  }

  /// One captain sheet per batch (grouped by [PrintItem.batchIndex]), to the
  /// item-level captain printer, else the outlet batch-step routing. NEVER
  /// prints bev labels — that is [printBevLabels], so a captain reprint cannot
  /// re-trigger them.
  Future<PrintOutcome> printCaptainOrder({
    required List<PrintItem> items,
    String? tableName,
    String? tableNumber,
    String? openedBy,
  }) async {
    final ctx = context.copyWith(
      ticketType: 'CAPTAIN_ORDER',
      tableName: tableName ?? context.tableName,
      tableNumber: tableNumber ?? context.tableNumber,
      openedBy: openedBy ?? context.openedBy,
    );
    final printed = <TicketRender>[];
    final alerts = <String>[];

    final groups = <int, List<PrintItem>>{};
    for (final i in items) {
      // MENU label for the grouped header: the cart line carries no category, so
      // it is resolved here from the synced catalog via the printer routing.
      if (i.menu.isEmpty) i.menu = routing.menuForItem(i.itemId);
      groups.putIfAbsent(i.batchIndex, () => []).add(i);
    }
    final indices = groups.keys.toList()..sort();

    for (final idx in indices) {
      final batchItems = groups[idx]!;
      final targets = _captainTargets(batchItems, idx);
      final sheets = _payloads.captainOrderSheets(ctx: ctx, items: batchItems);
      if (targets.isEmpty) {
        alerts.add('No captain printer configured for this batch — sheet not printed.');
        continue;
      }
      for (final payload in sheets) {
        final out = await _print(ticketType: 'CAPTAIN_ORDER', payload: payload, printers: targets);
        printed.addAll(out.printed);
        alerts.addAll(out.alerts);
      }
    }
    return PrintOutcome(printed: printed, alerts: alerts);
  }

  /// One label per item that has a strict bev printer assigned.
  Future<PrintOutcome> printBevLabels({
    required List<PrintItem> items,
    String? tableName,
  }) async {
    final ctx = context.copyWith(ticketType: 'BEV_LABEL', tableName: tableName ?? context.tableName);
    final printed = <TicketRender>[];
    final alerts = <String>[];
    for (final item in items) {
      final printer = routing.bevPrinterForLine(item.itemId);
      if (printer == null) continue; // not a beverage item — no label by design
      // ONE LABEL PER UNIT: each cup gets its own sticker, so a line of qty N
      // prints N labels (never a merged line reading "N").
      for (var unit = 0; unit < item.qty; unit++) {
        final one = PrintItem(
          name: item.name, itemId: item.itemId, qty: 1,
          unitPrice: item.unitPrice, lineTotal: item.unitPrice,
          priceLevelIndex: item.priceLevelIndex, batchIndex: item.batchIndex,
          menu: item.menu, modifiers: item.modifiers,
        );
        final out = await _print(
          ticketType: 'BEV_LABEL',
          payload: _payloads.bevLabel(ctx: ctx, item: one),
          printers: [printer],
        );
        printed.addAll(out.printed);
        alerts.addAll(out.alerts);
      }
    }
    return PrintOutcome(printed: printed, alerts: alerts);
  }

  // --------------------------------------------------------------- reprint ---

  /// Same-day bill reprint — re-renders the cached bill with a REPRINT label.
  Future<PrintOutcome> reprintBill(String receiptId, {String? tableName}) async {
    final rec = _reprints[receiptId];
    if (rec == null) {
      return PrintOutcome(alerts: ['No same-day print record for $receiptId — reprint from the web-app.']);
    }
    return printBill(
      items: rec.items,
      receiptId: rec.receiptId,
      flow: rec.flow,
      split: rec.split,
      methodNames: rec.methodNames,
      tableName: tableName ?? rec.tableName,
      reprint: true,
      discountName: rec.discountName,
      voucherName: rec.voucherName,
      discountAmount: rec.discountAmount,
      voucherAmount: rec.voucherAmount,
    );
  }

  /// Captain reprint — the WHOLE order, no bev labels.
  Future<PrintOutcome> reprintCaptain(String receiptId, {String? tableName}) async {
    final rec = _reprints[receiptId];
    if (rec == null) {
      return PrintOutcome(alerts: ['No same-day print record for $receiptId — reprint from the web-app.']);
    }
    return printCaptainOrder(items: rec.items, tableName: tableName ?? rec.tableName);
  }

  // ---------------------------------------------------------------- internals -

  /// Item-level captain printers for the batch; if no item carries one, fall
  /// back to the outlet batch-step routing.
  List<ClientPrinter> _captainTargets(List<PrintItem> batchItems, int step) {
    final byId = <String, ClientPrinter>{};
    for (final i in batchItems) {
      final p = routing.captainPrinterForLine(i.itemId);
      if (p != null) byId[p.id] = p;
    }
    if (byId.isNotEmpty) return byId.values.toList();
    return routing.captainPrintersForStep(step);
  }

  Future<PrintOutcome> _print({
    required String ticketType,
    required Map<String, dynamic> payload,
    required List<ClientPrinter> printers,
    String? receiptId,
    String? orderId,
  }) async {
    final printed = <TicketRender>[];
    final alerts = <String>[];
    final audit = _logs;
    if (printers.isEmpty) {
      alerts.add('No printer configured for $ticketType — nothing printed.');
      await audit?.recordFallback(
        ticketType: ticketType,
        errorCode: 'no_printer',
        warnings: ['No printer configured for $ticketType — nothing printed.'],
        receiptId: receiptId,
        orderId: orderId,
      );
      return PrintOutcome(printed: printed, alerts: alerts);
    }
    for (final p in printers) {
      if (!p.supported) {
        alerts.add("Printer '${p.name}' uses ${p.transport}, which this build cannot print to — skipped.");
        await audit?.recordFallback(
          ticketType: ticketType,
          printerId: p.id,
          printerName: p.name,
          printerTransport: p.transport,
          errorCode: 'unsupported_transport',
          warnings: ["Printer '${p.name}' uses ${p.transport}, which this build cannot print to — skipped."],
          receiptId: receiptId,
          orderId: orderId,
        );
        continue;
      }
      // Honest reporting: an unknown or declared-but-unimplemented dialect
      // still prints with the default.
      if (!p.dialectImplemented) {
        alerts.add(p.dialectRecognized
            ? "Printer '${p.name}' reports protocol '${p.protocol}' — '${p.dialect}' is declared but not implemented by this build; using the default $kDefaultEscPosDialect dialect."
            : "Printer '${p.name}' reports protocol '${p.protocol}' — unknown; using the default $kDefaultEscPosDialect dialect.");
      }
      final alertsBefore = alerts.length;
      final attempt = await _beginAudit(ticketType: ticketType, payload: payload, p: p, receiptId: receiptId, orderId: orderId);
      try {
        final rendered = await broker.printTicket(
          ticketType: ticketType,
          payload: payload,
          printer: p.toPrintPrinter(),
          widthMm: p.widthMm,
        );
        printed.add(rendered);
        // Honest reporting: the outlet HAS published formats, yet none matched
        // this ticket type (or its format failed to render) → the ticket went
        // out on the built-in layout. The operator must know: otherwise a
        // divergent ticket is indistinguishable from the agreed one. (No
        // formats published at all is the expected built-in state — not an alert.)
        if (!rendered.usedFormat && broker.hasPublishedFormats) {
          final note = '$ticketType printed with the built-in layout — '
              'no published server format applied (${rendered.fallbackReason ?? 'no format configured'}).';
          if (!alerts.contains(note)) alerts.add(note);
        }
        // IMAGE blocks need raster support; report when they were skipped.
        final images = rendered.entries.where((e) => e.kind == PrintableKind.image).length;
        if (images > 0 && !p.effectiveRasterSupport) {
          alerts.add("Printer '${p.name}' has no raster support — $images image block(s) skipped.");
        }
        const attemptCount = 1;
        if (attempt?.fallback ?? false) {
          await attempt!.completeFallback(attemptCount: attemptCount, extraWarnings: alerts.sublist(alertsBefore));
        } else {
          await attempt?.completeOk(attemptCount: attemptCount);
        }
      } catch (e) {
        alerts.add("Printer '${p.name}' failed: $e");
        final attempts = e is PrintJobFailed ? e.attempts : 1;
        await attempt?.completeFailed(
          attemptCount: attempts,
          errorCode: printErrorCode(e is PrintJobFailed ? (e.lastError ?? e) : e),
          errorDetail: '$e',
        );
      }
    }
    return PrintOutcome(printed: printed, alerts: alerts);
  }

  /// Insert the pre-attempt audit row (encode preview supplies the encoder
  /// warnings, byte length, dialect + code-page fallback flags) and return the
  /// handle finalized after the transport call. Null when logging is off.
  Future<PrintAttempt?> _beginAudit({
    required String ticketType,
    required Map<String, dynamic> payload,
    required ClientPrinter p,
    String? receiptId,
    String? orderId,
  }) async {
    final audit = _logs;
    if (audit == null) return null;
    try {
      final rendered = broker.renderTicket(ticketType: ticketType, payload: payload, widthMm: p.widthMm);
      final encode = encodePrintJobDetailed(
        PrintJob(ticketType: ticketType, lines: rendered.lines, entries: rendered.entries, printer: p.toPrintPrinter()),
        widthMm: p.widthMm,
      );
      return await audit.begin(
        ticketType: ticketType,
        printer: p,
        encode: encode,
        renderedLines: rendered.lines,
        usedFormat: rendered.usedFormat,
        formatFallbackReason: rendered.fallbackReason,
        receiptId: receiptId,
        orderId: orderId,
      );
    } catch (_) {
      return null; // audit is additive — never block a print
    }
  }
}
