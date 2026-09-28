/// Bluetooth (Classic SPP/RFCOMM) print transport — speaks to the existing
/// [PrintTransport] contract so [PrintQueue]/[PrintBroker]/[PrintDispatcher]
/// keep their queue + retry semantics unchanged.
///
/// All failures surface as a typed [BluetoothPrintException] carrying the PRD
/// [PrinterLinkState]; the queue then retries per the printer's policy.
library;

import 'package:gundam_pos/services/bluetooth_printer_channel.dart';
import 'package:gundam_pos/services/escpos.dart';
import 'package:gundam_pos/services/print_broker.dart';
import 'package:gundam_pos/services/printer_health.dart';

/// A Bluetooth fault, mapped to a PRD status. Never crashes the caller.
class BluetoothPrintException implements Exception {
  BluetoothPrintException(this.state, this.detail);

  final PrinterLinkState state;
  final String detail;

  @override
  String toString() => 'BluetoothPrintException(${state.name}: $detail)';
}

class BluetoothPrintTransport implements PrintTransport {
  BluetoothPrintTransport({BluetoothPrinterChannel? channel, int? connectTimeoutMs})
      : _channel = channel ?? BluetoothPrinterChannel(),
        _connectTimeoutMs = connectTimeoutMs ?? 8000;

  final BluetoothPrinterChannel _channel;
  final int _connectTimeoutMs;

  /// Send one job: adapter/permission check → ensure SPP connected → write the
  /// ESC/POS bytes. Throws [BluetoothPrintException] on any fault.
  @override
  Future<void> send(PrintJob job) async {
    final mac = job.printer.bluetoothMac;
    if (job.printer.transport.toUpperCase() != 'BLUETOOTH' || mac == null || mac.isEmpty) {
      throw BluetoothPrintException(
        PrinterLinkState.notPaired,
        'Printer has no Bluetooth MAC configured.',
      );
    }
    await _ensureReady(mac);
    final result = await _channel.write(encodePrintJob(job, widthMm: job.printer.widthMm));
    if (!result.ok) {
      throw BluetoothPrintException(printerLinkStateFromCode(result.state), result.detail);
    }
  }

  /// Manual test print — the same path a real job takes, with a fixed ticket.
  /// Returns the resulting [PrinterLink] (ready on success) for the UI.
  Future<PrinterLink> testPrint({required String mac, int widthMm = 80, String printerName = ''}) async {
    try {
      await _ensureReady(mac);
      final encoder = EscPosEncoder(widthMm: widthMm)
        ..init()
        ..align(1)
        ..bold(true)
        ..doubleSize()
        ..line('TEST PRINT')
        ..normalSize()
        ..bold(false)
        ..line(printerName.isEmpty ? 'Gundam POS printer' : printerName)
        ..align(0)
        ..line('Bluetooth SPP / ESC-POS OK')
        ..feed(3)
        ..cut();
      final result = await _channel.write(encoder.bytes);
      final state = printerLinkStateFromCode(result.state);
      return PrinterLink(state, detail: result.detail);
    } on BluetoothPrintException catch (e) {
      return PrinterLink(e.state, detail: e.detail);
    } catch (e) {
      return PrinterLink(PrinterLinkState.unknown, detail: '$e');
    }
  }

  /// Adapter on + permission + SPP connected, else throws the typed fault.
  Future<void> _ensureReady(String mac) async {
    final status = await _channel.status();
    final state = printerLinkStateFromCode(status.state);
    if (state != PrinterLinkState.ready && state != PrinterLinkState.unknown) {
      throw BluetoothPrintException(state, status.detail);
    }
    final conn = await _channel.connect(mac, timeoutMs: _connectTimeoutMs);
    if (!conn.ok) {
      throw BluetoothPrintException(printerLinkStateFromCode(conn.state), conn.detail);
    }
  }

  Future<void> close() => _channel.close();

  /// Prompt for the Android 12+ runtime Bluetooth permission.
  Future<bool> requestPermission() => _channel.requestPermission();
}
