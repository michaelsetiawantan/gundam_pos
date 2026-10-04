/// Print path — decides between a tenant's published print format and the
/// built-in fallback, renders, and feeds the per-device sequential queue.
///
/// Flow per ticket:
///   1. a published format for the ticket type (from [PrintFormatStore]) is
///      rendered with `renderPrintFormat`;
///   2. otherwise the built-in default blocks are rendered with the same engine
///      (last-known-good: a missing or malformed format never blocks printing);
///   3. the resulting text lines + QR/BARCODE/IMAGE entries are submitted to the
///      per-device queue, which fires sequentially and retries per printer
///      (PRD §4.32: attempt `retryCount` times, `retryTimeoutSec` each).
library;

import 'dart:io';

import 'package:gundam_pos/data/print_format_store.dart';
import 'package:gundam_pos/logic/print_format.dart';
import 'package:gundam_pos/logic/print_format_render.dart';
import 'package:gundam_pos/services/escpos.dart';
import 'package:gundam_pos/services/print_image.dart';

/// Transport descriptor for one printer (subset of the server `Printer`).
class PrintPrinter {
  const PrintPrinter({
    required this.name,
    this.host,
    this.port = 9100,
    this.transport = 'NETWORK',
    this.bluetoothMac,
    this.usbVidPid,
    this.usbChip,
    this.widthMm = 80,
    this.supportsRasterImage = false,
    this.dialect = kDefaultEscPosDialect,
    this.codePage,
    this.supportsCutter,
    this.supportsNativeQr,
    this.supportsNativeBarcode,
    this.retryCount = 3,
    this.retryTimeoutSec = 20,
  });

  final String name;
  final String? host;
  final int port;
  final String transport; // NETWORK | BLUETOOTH | USB
  final String? bluetoothMac; // BLUETOOTH SPP target (bonded device MAC)

  /// USB addressing: the configured `VID:PID` and the bridge chip the web config
  /// asks for (`CDC_ACM`|`CH340`|`PL2303`|`FTDI`, or null/`AUTO`). Both are null
  /// on older payloads — the USB transport then derives the chip from the device.
  final String? usbVidPid;
  final String? usbChip;
  final int widthMm;
  final bool supportsRasterImage;

  /// Effective ESC/POS dialect (canonicalised). Unknown or declared-but-not-
  /// implemented dialects still print with the default and are reported.
  final String dialect;

  /// Configured code page (`CP437`, `CP850`, `CP1252`, `KATAKANA`, …). Absent
  /// (null) → the encoder's documented default CP437.
  final String? codePage;

  /// Capability overrides from the printer/model config. null → the dialect's
  /// own default decides.
  final bool? supportsCutter;
  final bool? supportsNativeQr;
  final bool? supportsNativeBarcode;

  final int retryCount;
  final int retryTimeoutSec;
}

/// One queued print job: already-rendered text + structured graphics entries.
class PrintJob {
  PrintJob({
    required this.ticketType,
    required this.lines,
    required this.entries,
    required this.printer,
  });

  final String ticketType;
  final List<String> lines;
  final List<PrintableEntry> entries;
  final PrintPrinter printer;
}

/// Result of a render decision — what will actually be printed and why.
class TicketRender {
  TicketRender({
    required this.lines,
    required this.entries,
    required this.usedFormat,
    this.fallbackReason,
  });

  final List<String> lines;
  final List<PrintableEntry> entries;

  /// true → a tenant-configured format was rendered; false → built-in.
  final bool usedFormat;
  final String? fallbackReason;
}

/// Low-level byte sink. The real one opens the printer; tests inject a fake.
abstract class PrintTransport {
  Future<void> send(PrintJob job);
}

/// TCP :9100 transport (network printers) — real ESC/POS bytes.
class NetworkPrintTransport implements PrintTransport {
  const NetworkPrintTransport({PrintImageSource? Function()? imageSourceProvider})
      : _imageSourceProvider = imageSourceProvider;

  /// Resolves an IMAGE block's `assetKey` to cached bytes; null → placeholder.
  /// Wired explicitly for every transport (network included) by the app factory,
  /// so there is no global seam and no transport-specific gap.
  final PrintImageSource? Function()? _imageSourceProvider;

  /// IMAGE entries need the async resolver (decode + dither); a ticket without
  /// them takes the synchronous encoder exactly as before.
  Future<List<int>> _encode(PrintJob job) async {
    final source = _imageSourceProvider?.call();
    final needsRaster = source != null &&
        job.printer.supportsRasterImage &&
        job.entries.any((e) => e.kind == PrintableKind.image);
    if (needsRaster) {
      return (await encodePrintJobWithImages(job, source: source, widthMm: job.printer.widthMm)).bytes;
    }
    return encodePrintJob(job, widthMm: job.printer.widthMm);
  }

  @override
  Future<void> send(PrintJob job) async {
    if (job.printer.transport != 'NETWORK' || job.printer.host == null) {
      throw UnsupportedError('${job.printer.transport} transport not wired on this build');
    }
    final socket = await Socket.connect(
      job.printer.host!,
      job.printer.port,
      timeout: const Duration(seconds: 3),
    );
    try {
      socket.add(await _encode(job));
      await socket.flush();
    } finally {
      await socket.close();
    }
  }
}

/// Dispatches a job to the transport bound to its printer type. The queue keeps
/// a single transport; this lets NETWORK and BLUETOOTH share one queue.
class PrintTransportRouter implements PrintTransport {
  const PrintTransportRouter(this.byTransport);

  final Map<String, PrintTransport> byTransport;

  @override
  Future<void> send(PrintJob job) {
    final transport = byTransport[job.printer.transport];
    if (transport == null) {
      throw UnsupportedError('${job.printer.transport} transport not wired on this build');
    }
    return transport.send(job);
  }
}

/// Raised when a job exhausts every retry. The queue chain survives it.
class PrintJobFailed implements Exception {
  PrintJobFailed(this.ticketType, this.attempts, this.lastError);
  final String ticketType;
  final int attempts;
  final Object? lastError;

  @override
  String toString() => 'PrintJobFailed($ticketType after $attempts attempts: $lastError)';
}

/// Per-device sequential queue. Jobs fire in submission order; each job retries
/// per its printer's policy. A failing job never breaks the chain.
class PrintQueue {
  PrintQueue({required this.transport});

  final PrintTransport transport;
  Future<void> _tail = Future<void>.value();

  /// Enqueue [job]; resolves when its delivery attempt completes (or throws
  /// [PrintJobFailed] after all retries). Ordering is guaranteed.
  Future<void> submit(PrintJob job) {
    final next = _tail.then((_) => _deliver(job));
    _tail = next.catchError((_) {});
    return next;
  }

  Future<void> _deliver(PrintJob job) async {
    final attempts = job.printer.retryCount < 1 ? 1 : job.printer.retryCount;
    final timeout = Duration(seconds: job.printer.retryTimeoutSec);
    Object? last;
    for (var i = 0; i < attempts; i++) {
      try {
        await transport.send(job).timeout(timeout);
        return;
      } catch (e) {
        last = e;
      }
    }
    throw PrintJobFailed(job.ticketType, attempts, last);
  }
}

/// The print path entry point.
class PrintBroker {
  PrintBroker({required PrintFormatStore store, required PrintQueue queue})
      : _store = store,
        _queue = queue;

  final PrintFormatStore _store;
  final PrintQueue _queue;

  /// true when the outlet has ANY published format — used by the dispatcher to
  /// tell "this ticket type fell back" apart from "no formats at all".
  bool get hasPublishedFormats => _store.hasFormats;

  /// Choose + render a ticket. Never throws: falls back to the built-in layout.
  TicketRender renderTicket({
    required String ticketType,
    required Map<String, dynamic> payload,
    int? widthMm,
  }) {
    final configured = _store.formatFor(ticketType);
    if (configured != null) {
      try {
        final r = renderPrintFormat(format: configured, ticketPayload: payload, widthMm: widthMm);
        return _withDrawerPulse(TicketRender(lines: r.lines, entries: r.entries, usedFormat: true), payload);
      } catch (e) {
        return _builtin(ticketType, payload, widthMm, 'configured format failed ($e)');
      }
    }
    return _builtin(ticketType, payload, widthMm, _store.notice ?? 'no format configured');
  }

  /// A settle that took CASH asks for the drawer to pop: the pulse rides the SAME
  /// job (one connection, same queue/retry), appended after the last line.
  TicketRender _withDrawerPulse(TicketRender r, Map<String, dynamic> payload) {
    if (payload['drawer_pulse'] != true) return r;
    return TicketRender(
      lines: r.lines,
      entries: [
        ...r.entries,
        PrintableEntry(kind: PrintableKind.pulse, atLine: r.lines.length),
      ],
      usedFormat: r.usedFormat,
      fallbackReason: r.fallbackReason,
    );
  }

  /// Render then hand the job to the sequential queue.
  Future<TicketRender> printTicket({
    required String ticketType,
    required Map<String, dynamic> payload,
    required PrintPrinter printer,
    int? widthMm,
  }) async {
    final rendered = renderTicket(
      ticketType: ticketType,
      payload: payload,
      widthMm: widthMm ?? printer.widthMm,
    );
    await _queue.submit(PrintJob(
      ticketType: ticketType,
      lines: rendered.lines,
      entries: rendered.entries,
      printer: printer,
    ));
    return rendered;
  }

  TicketRender _builtin(String ticketType, Map<String, dynamic> payload, int? widthMm, String reason) {
    final r = renderPrintFormat(
      format: builtinFormat(ticketType, widthMm: widthMm ?? 80),
      ticketPayload: payload,
      widthMm: widthMm,
    );
    return _withDrawerPulse(
      TicketRender(lines: r.lines, entries: r.entries, usedFormat: false, fallbackReason: reason),
      payload,
    );
  }
}

/// The built-in fallback layout per ticket type — expressed as ordinary blocks
/// and rendered by the same engine, so the fallback can never diverge from the
/// contract renderer.
PrintFormat builtinFormat(String ticketType, {int widthMm = 80}) {
  PrintFormat make(List<Map<String, dynamic>> blocks) => PrintFormat.fromJson({
        'formatId': 'builtin:${ticketType.toUpperCase()}',
        'name': 'Built-in $ticketType',
        'ticketType': ticketType.toUpperCase(),
        'version': 0,
        'widthMm': widthMm,
        'blocks': blocks,
      });

  switch (ticketType.toUpperCase()) {
    case 'CAPTAIN_ORDER':
    case 'CANCELED_ORDER':
      return make([
        {'id': 'a', 'type': 'TEXT', 'text': '{store_name}', 'align': 'CENTER', 'bold': true, 'size': 'DOUBLE'},
        {'id': 'b', 'type': 'SEPARATOR'},
        {'id': 'c', 'type': 'TEXT', 'text': 'Table {table_name}   Batch {batch_label}'},
        {'id': 'd', 'type': 'TEXT', 'text': '{canceled_label}'},
        {'id': 'e', 'type': 'SEPARATOR'},
        // groupByMenu: a merged station still gets one section per menu (the
        // header line the kitchen sorts by). withModifiers nests each item's
        // modifiers under it — a flat list at the ticket end detaches them.
        {'id': 'f', 'type': 'ITEM_LIST', 'columns': 'NAME_QTY', 'wrap': true, 'groupByMenu': true, 'withModifiers': true},
        {'id': 'h', 'type': 'FEED', 'lines': 2},
      ]);
    case 'BEV_LABEL':
      return make([
        {'id': 'a', 'type': 'TEXT', 'text': '{store_name}', 'align': 'CENTER'},
        {'id': 'b', 'type': 'SEPARATOR'},
        {'id': 'c', 'type': 'TEXT', 'text': 'Table {table_name}   {batch_label}'},
        {'id': 'd', 'type': 'SEPARATOR'},
        // withModifiers nests each item's modifiers directly under it; the old
        // separate MODIFIER_LIST detached them to the bottom of the label.
        {'id': 'e', 'type': 'ITEM_LIST', 'columns': 'NAME_QTY', 'wrap': true, 'groupByMenu': true, 'withModifiers': true},
        {'id': 'g', 'type': 'FEED', 'lines': 2},
      ]);
    case 'SHIFT_OPEN':
    case 'SHIFT_CLOSE':
    case 'Z_REPORT':
      final isZ = ticketType.toUpperCase() == 'Z_REPORT';
      return make([
        {'id': 'a', 'type': 'TEXT', 'text': isZ ? 'Z REPORT' : 'SHIFT', 'align': 'CENTER', 'bold': true, 'size': 'DOUBLE'},
        {'id': 'b', 'type': 'VAR', 'param': '{store_name}', 'align': 'CENTER'},
        {'id': 'c', 'type': 'SEPARATOR'},
        {'id': 'd', 'type': 'VAR', 'param': '{z_report_date}'},
        {'id': 'e', 'type': 'VAR', 'param': '{shift_id}'},
        {'id': 'f', 'type': 'SEPARATOR'},
        {'id': 'g', 'type': 'VAR', 'param': '{transaction_count}', 'format': 'decimal'},
        {'id': 'h', 'type': 'VAR', 'param': '{total_sales}', 'format': 'money'},
        {'id': 'i', 'type': 'VAR', 'param': '{cash_variance}', 'format': 'money'},
        {'id': 'j', 'type': 'SEPARATOR'},
        {'id': 'k', 'type': 'VAR', 'param': '{cashier_name}', 'align': 'CENTER'},
        {'id': 'l', 'type': 'FEED', 'lines': 1},
      ]);
    default: // BILL / RECEIPT_COPY
      return make([
        {'id': 'a', 'type': 'TEXT', 'text': '{store_name}', 'align': 'CENTER', 'bold': true, 'size': 'DOUBLE'},
        {'id': 'b', 'type': 'VAR', 'param': '{store_address}', 'align': 'CENTER'},
        {'id': 'c', 'type': 'SEPARATOR'},
        {'id': 'd', 'type': 'VAR', 'param': '{receipt_id}'},
        {'id': 'e', 'type': 'VAR', 'param': '{paid_at}'},
        {'id': 'f', 'type': 'VAR', 'param': '{table_name}'},
        {'id': 'g', 'type': 'SEPARATOR'},
        // ONE item list that carries each item's modifiers under its own line
        // (a separate MODIFIER_LIST printed every product first, then every
        // modifier at the bottom — detached from the dish).
        {'id': 'h', 'type': 'ITEM_LIST', 'columns': 'NAME_QTY_PRICE', 'nameMax': 20, 'withModifiers': true, 'withPrice': true},
        {'id': 'j', 'type': 'SEPARATOR'},
        {
          'id': 'k',
          'type': 'MONEY_LINES',
          'lines': ['SUBTOTAL', 'DISCOUNT', 'VAT', 'SC', 'SHIPMENT', 'ROUNDING', 'TIPS', 'TOTAL', 'PAID', 'CHANGE'],
        },
        {'id': 'l', 'type': 'PAYMENT_LINES', 'showReference': true},
        {'id': 'm', 'type': 'FEED', 'lines': 1},
        {'id': 'n', 'type': 'TEXT', 'text': '{thank_you_message}', 'align': 'CENTER'},
        {'id': 'o', 'type': 'QR', 'content': '{receipt_id}', 'sizeMm': 20},
      ]);
  }
}
