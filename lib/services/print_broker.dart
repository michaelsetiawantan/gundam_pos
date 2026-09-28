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

import 'dart:convert';
import 'dart:io';

import 'package:gundam_pos/data/print_format_store.dart';
import 'package:gundam_pos/logic/print_format.dart';
import 'package:gundam_pos/logic/print_format_render.dart';

/// Transport descriptor for one printer (subset of the server `Printer`).
class PrintPrinter {
  const PrintPrinter({
    required this.name,
    this.host,
    this.port = 9100,
    this.transport = 'NETWORK',
    this.widthMm = 80,
    this.supportsRasterImage = false,
    this.retryCount = 3,
    this.retryTimeoutSec = 20,
  });

  final String name;
  final String? host;
  final int port;
  final String transport; // NETWORK | BLUETOOTH | USB
  final int widthMm;
  final bool supportsRasterImage;
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

/// TCP :9100 transport (network printers) — plain-text/ESC-POS-safe bytes.
class NetworkPrintTransport implements PrintTransport {
  const NetworkPrintTransport();

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
      socket.add(_bytes(job));
      await socket.flush();
    } finally {
      await socket.close();
    }
  }

  /// Text lines, then a text stand-in per QR/BARCODE/IMAGE entry, then feed+cut.
  /// ponytail: no raster/QR encoder dependency — graphics render as labelled
  /// text until an ESC/POS encoder is added.
  List<int> _bytes(PrintJob job) {
    final out = <int>[];
    for (final l in job.lines) {
      out
        ..addAll(utf8.encode(l))
        ..add(0x0A);
    }
    for (final e in job.entries) {
      out
        ..addAll(utf8.encode('[${e.kind.name.toUpperCase()}] ${e.content}'))
        ..add(0x0A);
    }
    out.addAll(const [0x1B, 0x64, 0x03, 0x1D, 0x56, 0x00]); // feed 3 + cut
    return out;
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
        return TicketRender(lines: r.lines, entries: r.entries, usedFormat: true);
      } catch (e) {
        return _builtin(ticketType, payload, widthMm, 'configured format failed ($e)');
      }
    }
    return _builtin(ticketType, payload, widthMm, _store.notice ?? 'no format configured');
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
    return TicketRender(lines: r.lines, entries: r.entries, usedFormat: false, fallbackReason: reason);
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
        {'id': 'f', 'type': 'ITEM_LIST', 'columns': 'NAME_QTY', 'wrap': true},
        {'id': 'g', 'type': 'MODIFIER_LIST', 'indent': 2},
        {'id': 'h', 'type': 'FEED', 'lines': 2},
      ]);
    case 'BEV_LABEL':
      return make([
        {'id': 'a', 'type': 'TEXT', 'text': '{store_name}', 'align': 'CENTER'},
        {'id': 'b', 'type': 'SEPARATOR'},
        {'id': 'c', 'type': 'TEXT', 'text': 'Table {table_name}   {batch_label}'},
        {'id': 'd', 'type': 'SEPARATOR'},
        {'id': 'e', 'type': 'ITEM_LIST', 'columns': 'NAME_QTY', 'wrap': true},
        {'id': 'f', 'type': 'MODIFIER_LIST', 'indent': 2},
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
        {'id': 'h', 'type': 'ITEM_LIST', 'columns': 'NAME_QTY_PRICE', 'nameMax': 20},
        {'id': 'i', 'type': 'MODIFIER_LIST', 'indent': 2, 'withPrice': true},
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
