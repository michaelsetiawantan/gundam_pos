/// USB Host print transport — speaks to the existing [PrintTransport] contract
/// so [PrintQueue]/[PrintBroker]/[PrintDispatcher] keep their queue + retry
/// semantics unchanged.
///
/// The bridge chip is chosen from the web config (`printer.usbChip`): the driver
/// itself lives in the APK (Kotlin `UsbSerialDrivers`), and this class picks the
/// right one and refuses a mismatch. When the config carries no chip (or `AUTO`)
/// the chip is derived from the attached device — the documented fallback.
///
/// All failures surface as a typed [UsbPrintException] carrying a PRD
/// [PrinterLinkState]; a configured-vs-attached chip/VID-PID mismatch is a
/// distinct [UsbChipMismatchException] so it can never become a silent
/// wrong-chip write. The queue then retries per the printer's policy.
library;

import 'package:gundam_pos/services/escpos.dart';
import 'package:gundam_pos/services/print_broker.dart';
import 'package:gundam_pos/services/printer_health.dart';
import 'package:gundam_pos/services/usb_printer_channel.dart';

/// A USB fault, mapped to a PRD status. Never crashes the caller.
class UsbPrintException implements Exception {
  UsbPrintException(this.state, this.detail);

  final PrinterLinkState state;
  final String detail;

  @override
  String toString() => 'UsbPrintException(${state.name}: $detail)';
}

/// The configured chip does not match the attached device (VID/PID or driver).
/// A distinct type so it is impossible to mistake for a transient link fault.
class UsbChipMismatchException extends UsbPrintException {
  UsbChipMismatchException(this.configuredChip, this.attached, String detail)
      : super(PrinterLinkState.unsupported, detail);

  final String configuredChip;

  /// The attached device's chip id ('' when the device is not a supported bridge).
  final String attached;
}

class UsbPrintTransport implements PrintTransport {
  UsbPrintTransport({UsbPrinterChannel? channel, int baud = 9600})
      : _channel = channel ?? UsbPrinterChannel(),
        _baud = baud;

  final UsbPrinterChannel _channel;

  /// Line speed for the chip init. Config carries no baud; thermal printers are
  /// almost always 9600 8N1, so that is the documented default.
  final int _baud;

  /// Send one job: enumerate → resolve chip → permission → open → write ESC/POS
  /// bytes. Throws [UsbPrintException] (or [UsbChipMismatchException]) on fault.
  @override
  Future<void> send(PrintJob job) async {
    if (job.printer.transport.toUpperCase() != 'USB') {
      throw UsbPrintException(PrinterLinkState.unsupported, 'Printer is not a USB printer.');
    }
    final device = await _resolveDevice(job.printer.usbVidPid, job.printer.usbChip);
    if (!device.granted) {
      throw UsbPrintException(PrinterLinkState.permissionRequired, 'USB permission has not been granted.');
    }
    final chip = _effectiveChip(job.printer.usbChip, device);
    final opened = await _channel.open(vid: device.vid, pid: device.pid, chip: chip, baud: _baud);
    if (!opened.ok) {
      throw UsbPrintException(printerLinkStateFromCode(opened.state), opened.detail);
    }
    final result = await _channel.write(encodePrintJob(job, widthMm: job.printer.widthMm));
    if (!result.ok) {
      throw UsbPrintException(printerLinkStateFromCode(result.state), result.detail);
    }
  }

  /// Manual test print — the same path a real job takes, with a fixed ticket.
  /// Returns the resulting [PrinterLink] (ready on success) for the UI.
  Future<PrinterLink> testPrint({
    String? vidPid,
    String? chip,
    int widthMm = 80,
    String printerName = '',
  }) async {
    try {
      final device = await _resolveDevice(vidPid, chip);
      if (!device.granted) {
        await requestPermission(vid: device.vid, pid: device.pid);
        if (!await _channel.hasPermission(vid: device.vid, pid: device.pid)) {
          return PrinterLink(PrinterLinkState.permissionRequired, detail: 'USB permission was not granted.');
        }
      }
      final effective = _effectiveChip(chip, device);
      final opened = await _channel.open(vid: device.vid, pid: device.pid, chip: effective, baud: _baud);
      if (!opened.ok) {
        return PrinterLink(printerLinkStateFromCode(opened.state), detail: opened.detail);
      }
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
        ..line('USB $effective / ESC-POS OK')
        ..feed(3)
        ..cut();
      final result = await _channel.write(encoder.bytes);
      return PrinterLink(printerLinkStateFromCode(result.state), detail: result.detail);
    } on UsbChipMismatchException catch (e) {
      return PrinterLink(e.state, detail: e.detail);
    } on UsbPrintException catch (e) {
      return PrinterLink(e.state, detail: e.detail);
    } catch (e) {
      return PrinterLink(PrinterLinkState.unknown, detail: '$e');
    }
  }

  Future<void> close() => _channel.close();

  /// Prompt for USB permission on the configured (or first) device.
  Future<bool> requestPermission({int? vid, int? pid}) => _channel.requestPermission(vid: vid, pid: pid);

  Future<PrinterLink> probe({String? vidPid, String? chip}) async {
    try {
      final device = await _resolveDevice(vidPid, chip);
      if (!device.granted) {
        return PrinterLink(PrinterLinkState.permissionRequired, detail: 'USB permission has not been granted.');
      }
      return PrinterLink(PrinterLinkState.ready, detail: '${device.chip} ${device.vidPid} attached.');
    } on UsbPrintException catch (e) {
      return PrinterLink(e.state, detail: e.detail);
    }
  }

  // -------------------------------------------------------------- internals ---

  /// Pick the attached device for a configured VID/PID (+chip), else the chip
  /// alone, else the first supported device. Throws a typed fault when nothing
  /// matches; never returns a wrong device.
  Future<UsbDeviceInfo> _resolveDevice(String? vidPid, String? chip) async {
    final status = await _channel.status();
    final state = printerLinkStateFromCode(status.state);
    if (state == PrinterLinkState.unsupported || state == PrinterLinkState.offline) {
      throw UsbPrintException(state, status.detail);
    }
    final devices = await _channel.listDevices();
    final configured = canonicalUsbChip(chip);
    final target = parseUsbVidPid(vidPid);

    UsbDeviceInfo? match;
    if (target != null) {
      for (final d in devices) {
        if (d.vid == target.$1 && d.pid == target.$2) {
          match = d;
          break;
        }
      }
    } else if (configured != null) {
      for (final d in devices) {
        if (d.chip == configured) {
          match = d;
          break;
        }
      }
    } else {
      for (final d in devices) {
        if (d.chip.isNotEmpty) {
          match = d;
          break;
        }
      }
      match ??= devices.isEmpty ? null : devices.first;
    }

    if (match == null) {
      if (target != null) {
        throw UsbChipMismatchException(
          configured ?? 'auto',
          '',
          'Configured USB printer $vidPid is not attached.',
        );
      }
      throw UsbPrintException(PrinterLinkState.offline, 'No supported USB printer attached.');
    }
    return match;
  }

  /// The chip to hand the Kotlin driver, or a typed mismatch error when the
  /// configured chip disagrees with what is attached.
  String _effectiveChip(String? configuredChip, UsbDeviceInfo device) {
    final configured = canonicalUsbChip(configuredChip);
    final attached = device.chip.isNotEmpty
        ? device.chip
        : (usbChipForVidPid(device.vid, device.pid, cdcByClass: true) ?? '');
    if (configured == null) {
      if (attached.isEmpty) {
        throw UsbChipMismatchException('auto', '', 'Attached USB device ${device.vidPid} is not a supported chip.');
      }
      return attached; // documented fallback: derive the chip from the device
    }
    if (attached != configured) {
      throw UsbChipMismatchException(
        configured,
        attached,
        'Configured chip $configured does not match the attached device '
            '(${device.vidPid}, ${attached.isEmpty ? 'unsupported chip' : attached}).',
      );
    }
    return configured;
  }
}
