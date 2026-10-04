import 'dart:async';

import 'package:gundam_pos/data/print_format_store.dart';
import 'package:gundam_pos/logic/money.dart' as money;
import 'package:gundam_pos/logic/print_payload.dart';
import 'package:gundam_pos/services/print_broker.dart';
import 'package:gundam_pos/services/print_dispatcher.dart';
import 'package:gundam_pos/services/print_log.dart';
import 'package:gundam_pos/services/print_routing.dart';
import 'package:gundam_pos/services/printer_health.dart';

import 'fake_backend.dart';

/// Records every job the broker actually hands to the transport.
class RecordingTransport implements PrintTransport {
  final List<PrintJob> jobs = [];

  @override
  Future<void> send(PrintJob job) async => jobs.add(job);
}

/// Blocks every print on a [Completer] gate: a test can prove a controller
/// returns BEFORE the printer finishes (settle/send-cart off the print path),
/// then release the gate and assert the late alert still arrives.
class GatedDispatcher extends PrintDispatcher {
  GatedDispatcher()
      : super(
          broker: PrintBroker(store: PrintFormatStore(), queue: PrintQueue(transport: RecordingTransport())),
          routing: PrinterRouting.parse(FakeBackend.northstarPrintModel()),
        );

  final Completer<void> gate = Completer<void>();
  int billCalls = 0;
  int sendCartCalls = 0;

  @override
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
    bool openDrawer = false,
  }) async {
    billCalls++;
    await gate.future;
    return const PrintOutcome(alerts: ['BILL printer offline — test.']);
  }

  @override
  Future<PrintOutcome> printSendCart({
    required List<PrintItem> items,
    String? tableName,
    String? tableNumber,
    String? openedBy,
  }) async {
    sendCartCalls++;
    await gate.future;
    return const PrintOutcome(alerts: ['CAPTAIN printer offline — test.']);
  }
}

/// Fails every send — used to exercise the FAILED audit row.
class AlwaysFailingTransport implements PrintTransport {
  @override
  Future<void> send(PrintJob job) async => throw StateError('offline');
}

TicketContext testContext({String type = 'BILL'}) => TicketContext(
      storeName: 'Northstar Cafe',
      storeAddress: 'Jl. Sudirman 18',
      cashier: 'Rina',
      ticketType: type,
      deviceShortcode: 'NSTAR-POS1',
      currencyLabel: 'Rp',
      timezone: 'Asia/Jakarta',
      at: DateTime(2026, 9, 28, 14, 5, 0),
    );

/// A dispatcher wired from the Northstar print model onto a recording
/// transport. The health probes are stubbed so tests never open a socket or a
/// platform channel.
PrintDispatcher buildDispatcher(
  PrintTransport transport, {
  Map<String, dynamic>? outlet,
  BluetoothProbe? bluetooth,
  PrintFormatStore? store,
  PrintLogAudit? logs,
  PrinterRouting? routing,
}) {
  final resolved = routing ?? PrinterRouting.parse(outlet ?? FakeBackend.northstarPrintModel());
  final broker = PrintBroker(store: store ?? PrintFormatStore(), queue: PrintQueue(transport: transport));
  return PrintDispatcher(
    broker: broker,
    routing: resolved,
    context: testContext(),
    logs: logs,
    health: PrinterHealthChecker(
      connect: (host, port) async => false,
      bluetooth: bluetooth ?? (mac, supportsDeviceStatus) async => PrinterLink(PrinterLinkState.ready, detail: '$mac (test)'),
    ),
  );
}
