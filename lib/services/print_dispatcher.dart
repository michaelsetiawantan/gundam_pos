/// Print dispatcher — turns the synced routing into actual broker submissions
/// at the real POS moments (send-cart, settle, same-day reprint).
///
/// It resolves a ticket type to printer(s) from [PrinterRouting], renders the
/// payload with [TicketPayloadBuilder], and hands jobs to the [PrintBroker]
/// queue. It NEVER throws and NEVER blocks a sale: a missing printer or an
/// unsupported transport becomes an honest [PrintOutcome.alerts] entry instead.
///
/// Transports: NETWORK :9100 and Classic Bluetooth SPP write bytes on this
/// build. A USB printer is reported as unsupported, never pretended.
library;

import 'package:gundam_pos/logic/money.dart' as money;
import 'package:gundam_pos/logic/print_format_render.dart';
import 'package:gundam_pos/logic/print_payload.dart';
import 'package:gundam_pos/services/escpos.dart';
import 'package:gundam_pos/services/print_broker.dart';
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
  });

  final List<PrintItem> items;
  final String receiptId;
  final money.MoneyFlow flow;
  final money.SplitResult split;
  final Map<String, String> methodNames;
  final String? tableName;
}

class PrintDispatcher {
  PrintDispatcher({
    required this.broker,
    required this.routing,
    TicketContext? context,
    TicketPayloadBuilder payloads = const TicketPayloadBuilder(),
    PrinterHealthChecker? health,
  })  : context = context ?? TicketContext(),
        _payloads = payloads,
        _health = health ?? PrinterHealthChecker();

  /// Live broker (swapped when the format store / transport is rebuilt).
  PrintBroker broker;

  /// Routing model, re-set on each config refresh.
  PrinterRouting routing;

  /// Base ticket context (store/cashier/device); per-ticket fields are copied.
  TicketContext context;

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
    DateTime? paidAt,
    bool reprint = false,
  }) async {
      final ctx = context.copyWith(
        ticketType: 'BILL',
        tableName: tableName ?? context.tableName,
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
    );
    if (!reprint) {
      _reprints[receiptId] = _Reprint(
        items: items,
        receiptId: receiptId,
        flow: flow,
        split: split,
        methodNames: methodNames,
        tableName: tableName,
      );
    }
    return _print(ticketType: 'BILL', payload: payload, printers: routing.billPrinters());
  }

  // ------------------------------------------- captain order + bev labels ---

  /// The send-cart moment: one captain sheet per batch, then a bev label per
  /// beverage item.
  Future<PrintOutcome> printSendCart({
    required List<PrintItem> items,
    String? tableName,
  }) async {
    final captain = await printCaptainOrder(items: items, tableName: tableName);
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
  }) async {
    final ctx = context.copyWith(ticketType: 'CAPTAIN_ORDER', tableName: tableName ?? context.tableName);
    final printed = <TicketRender>[];
    final alerts = <String>[];

    final groups = <int, List<PrintItem>>{};
    for (final i in items) {
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
      final printer = routing.bevPrinterForItem(item.itemId);
      if (printer == null) continue; // not a beverage item — no label by design
      final out = await _print(
        ticketType: 'BEV_LABEL',
        payload: _payloads.bevLabel(ctx: ctx, item: item),
        printers: [printer],
      );
      printed.addAll(out.printed);
      alerts.addAll(out.alerts);
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
      final p = routing.captainPrinterForItem(i.itemId);
      if (p != null) byId[p.id] = p;
    }
    if (byId.isNotEmpty) return byId.values.toList();
    return routing.captainPrintersForStep(step);
  }

  Future<PrintOutcome> _print({
    required String ticketType,
    required Map<String, dynamic> payload,
    required List<ClientPrinter> printers,
  }) async {
    final printed = <TicketRender>[];
    final alerts = <String>[];
    if (printers.isEmpty) {
      alerts.add('No printer configured for $ticketType — nothing printed.');
      return PrintOutcome(printed: printed, alerts: alerts);
    }
    for (final p in printers) {
      if (!p.supported) {
        alerts.add("Printer '${p.name}' uses ${p.transport}, which this build cannot print to — skipped.");
        continue;
      }
      // Honest reporting: an unrecognised dialect still prints with the default.
      if (!p.dialectRecognized) {
        alerts.add(
          "Printer '${p.name}' reports protocol '${p.protocol}' — unknown; using the default $kDefaultEscPosDialect dialect.",
        );
      }
      try {
        final rendered = await broker.printTicket(
          ticketType: ticketType,
          payload: payload,
          printer: p.toPrintPrinter(),
          widthMm: p.widthMm,
        );
        printed.add(rendered);
        // IMAGE blocks need raster support; report when they were skipped.
        final images = rendered.entries.where((e) => e.kind == PrintableKind.image).length;
        if (images > 0 && !p.effectiveRasterSupport) {
          alerts.add("Printer '${p.name}' has no raster support — $images image block(s) skipped.");
        }
      } catch (e) {
        alerts.add("Printer '${p.name}' failed: $e");
      }
    }
    return PrintOutcome(printed: printed, alerts: alerts);
  }
}
