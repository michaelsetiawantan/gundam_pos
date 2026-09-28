/// Printer link health — transport-level check, reported by the POS (never the
/// cloud). Per PRD, only a model with real-time ESC/POS status can claim
/// Healthy; otherwise we report `unknown` instead of asserting health.
library;

import 'dart:io';

import 'package:gundam_pos/services/bluetooth_printer_channel.dart';
import 'package:gundam_pos/services/usb_printer_channel.dart';

/// PRD §4.28 connection statuses. `permissionRequired` and `disconnected` are
/// additions the Bluetooth and USB transports need beyond the original set.
enum PrinterLinkState {
  ready,
  offline,
  notPaired,
  bluetoothOff,
  permissionRequired,
  disconnected,
  unsupported,
  unknown,
}

class PrinterLink {
  PrinterLink(this.state, {this.detail = ''});

  final PrinterLinkState state;
  final String detail;

  bool get isUsable => state == PrinterLinkState.ready || state == PrinterLinkState.unknown;
}

/// Map a Kotlin platform-channel status code to a [PrinterLinkState]. An unknown
/// code is reported as [PrinterLinkState.unknown] — never guessed as healthy.
PrinterLinkState printerLinkStateFromCode(String? code) {
  switch ((code ?? '').toLowerCase()) {
    case 'ready':
      return PrinterLinkState.ready;
    case 'offline':
      return PrinterLinkState.offline;
    case 'disconnected':
      return PrinterLinkState.disconnected;
    case 'not_paired':
    case 'notpaired':
      return PrinterLinkState.notPaired;
    case 'bluetooth_off':
    case 'bluetoothoff':
      return PrinterLinkState.bluetoothOff;
    case 'permission_required':
    case 'permissionrequired':
      return PrinterLinkState.permissionRequired;
    case 'unsupported':
      return PrinterLinkState.unsupported;
    default:
      return PrinterLinkState.unknown;
  }
}

/// A type alias for the reachability probe so tests can inject a fake (the
/// default opens a TCP socket to the printer's :9100 endpoint).
typedef Reachability = Future<bool> Function(String host, int port);

/// The PRD §4.28 status label for a link state — the exact strings the server
/// accepts at `POST /api/pos/printers/health` (web `PRINTER_HEALTH_STATUSES`).
String printerHealthStatusName(PrinterLinkState state) {
  switch (state) {
    case PrinterLinkState.ready:
      return 'Ready';
    case PrinterLinkState.offline:
      return 'Offline';
    case PrinterLinkState.notPaired:
      return 'Not paired';
    case PrinterLinkState.bluetoothOff:
      return 'Bluetooth off';
    case PrinterLinkState.permissionRequired:
      return 'Permission required';
    case PrinterLinkState.disconnected:
      return 'Disconnected';
    case PrinterLinkState.unsupported:
      return 'Unsupported';
    case PrinterLinkState.unknown:
      return 'Unknown';
  }
}

/// Bluetooth SPP probe: adapter → permission → bonded → RFCOMM connect. The
/// default talks to the Android platform channel; tests inject a fake.
typedef BluetoothProbe = Future<PrinterLink> Function(String mac, bool supportsDeviceStatus);

/// USB Host probe: host → device present (VID/PID or chip) → permission →
/// interface/endpoint open. The default talks to the Android platform channel;
/// tests inject a fake.
typedef UsbProbe = Future<PrinterLink> Function(String vidPid, String chip, bool supportsDeviceStatus);

class PrinterHealthChecker {
  PrinterHealthChecker({Reachability? connect, BluetoothProbe? bluetooth, UsbProbe? usb})
      : _connect = connect ?? _tcpProbe,
        _bluetooth = bluetooth ?? defaultBluetoothProbe,
        _usb = usb ?? defaultUsbProbe;

  final Reachability _connect;
  final BluetoothProbe _bluetooth;
  final UsbProbe _usb;

  /// Check a printer by its configured transport.
  /// - NETWORK: TCP connect to host:port → ready (or offline).
  /// - BLUETOOTH: adapter/permission/bonded-MAC/RFCOMM-SPP (PRD §4.28).
  /// - USB: Android USB Host — device present / permission / chip match /
  ///   interface claim (PRD §4.28).
  /// If the printer model cannot surface real-time status, we mark the link
  /// `unknown` rather than claim healthy (PRD printer-health rule).
  Future<PrinterLink> check({
    required String transport,
    String? host,
    int port = 9100,
    String? bluetoothMac,
    String? usbVidPid,
    String? usbChip,
    bool supportsDeviceStatus = false,
  }) async {
    switch (transport.toUpperCase()) {
      case 'BLUETOOTH':
        if (bluetoothMac == null || bluetoothMac.isEmpty) {
          return PrinterLink(PrinterLinkState.notPaired, detail: 'No Bluetooth MAC configured for this printer.');
        }
        return _bluetooth(bluetoothMac, supportsDeviceStatus);
      case 'USB':
        if ((usbVidPid == null || usbVidPid.isEmpty) && (usbChip == null || usbChip.isEmpty)) {
          return PrinterLink(PrinterLinkState.offline, detail: 'No USB VID:PID or chip configured for this printer.');
        }
        return _usb(usbVidPid ?? '', usbChip ?? '', supportsDeviceStatus);
      case 'NETWORK':
      default:
        final reachable = host == null ? false : await _connect(host, port);
        if (!reachable) return PrinterLink(PrinterLinkState.offline, detail: '${host ?? '?'}:$port unreachable.');
        // Reachable is not the same as Healthy: without real-time device status
        // we must not claim Healthy (PRD).
        return supportsDeviceStatus
            ? PrinterLink(PrinterLinkState.ready, detail: '$host:$port OK.')
            : PrinterLink(PrinterLinkState.unknown, detail: '$host:$port reachable; device status unknown.');
    }
  }

  /// Real Bluetooth probe: adapter on, permission held, device bonded, then an
  /// SPP connect. Every stop is a typed [PrinterLink], never an exception.
  static Future<PrinterLink> defaultBluetoothProbe(String mac, bool supportsDeviceStatus) async {
    final channel = BluetoothPrinterChannel();
    final status = await channel.status();
    switch (status.state) {
      case 'unsupported':
        return PrinterLink(PrinterLinkState.unsupported, detail: status.detail);
      case 'bluetooth_off':
        return PrinterLink(PrinterLinkState.bluetoothOff, detail: status.detail);
      case 'permission_required':
        return PrinterLink(PrinterLinkState.permissionRequired, detail: status.detail);
    }
    final target = mac.toUpperCase();
    final bonded = await channel.listBonded();
    final known = bonded.any((d) => (d['mac'] as String?)?.toUpperCase() == target);
    if (!known) {
      return PrinterLink(PrinterLinkState.notPaired, detail: '$mac is not paired with this device.');
    }
    final conn = await channel.connect(mac);
    final state = printerLinkStateFromCode(conn.state);
    if (state != PrinterLinkState.ready) {
      return PrinterLink(state, detail: conn.detail);
    }
    return PrinterLink(
      PrinterLinkState.ready,
      detail: supportsDeviceStatus
          ? '${conn.detail} Device status reported.'
          : '${conn.detail} Device status: Unknown.',
    );
  }

  /// Real USB Host probe: host → device present (VID/PID or chip) → permission →
  /// chip match → interface/endpoint open. Every stop is a typed [PrinterLink],
  /// never an exception.
  static Future<PrinterLink> defaultUsbProbe(String vidPid, String chip, bool supportsDeviceStatus) async {
    final channel = UsbPrinterChannel();
    final status = await channel.status();
    if (status.state == 'unsupported') {
      return PrinterLink(PrinterLinkState.unsupported, detail: status.detail);
    }
    final devices = await channel.listDevices();
    final target = parseUsbVidPid(vidPid);
    final configured = canonicalUsbChip(chip);

    UsbDeviceInfo? dev;
    if (target != null) {
      for (final d in devices) {
        if (d.vid == target.$1 && d.pid == target.$2) {
          dev = d;
          break;
        }
      }
    } else if (configured != null) {
      for (final d in devices) {
        if (d.chip == configured) {
          dev = d;
          break;
        }
      }
    } else {
      for (final d in devices) {
        if (d.chip.isNotEmpty) {
          dev = d;
          break;
        }
      }
    }
    if (dev == null) {
      return PrinterLink(
        PrinterLinkState.offline,
        detail: 'Configured USB printer is not attached'
            '${vidPid.isEmpty ? '' : ' ($vidPid)'}.',
      );
    }
    if (!dev.granted) {
      return PrinterLink(PrinterLinkState.permissionRequired, detail: 'USB permission has not been granted.');
    }
    final attached = dev.chip.isNotEmpty
        ? dev.chip
        : (usbChipForVidPid(dev.vid, dev.pid, cdcByClass: true) ?? '');
    if (configured != null && attached != configured) {
      return PrinterLink(
        PrinterLinkState.unsupported,
        detail: 'Configured chip $configured does not match the attached device '
            '(${dev.vidPid}, ${attached.isEmpty ? 'unsupported chip' : attached}).',
      );
    }
    final open = await channel.open(
      vid: dev.vid,
      pid: dev.pid,
      chip: attached.isEmpty ? (configured ?? '') : attached,
    );
    if (!open.ok) {
      return PrinterLink(printerLinkStateFromCode(open.state), detail: open.detail);
    }
    await channel.close(); // free the interface for the real print path
    return PrinterLink(
      PrinterLinkState.ready,
      detail: supportsDeviceStatus
          ? '${open.detail} Device status reported.'
          : '${open.detail} Device status: Unknown.',
    );
  }

  static Future<bool> _tcpProbe(String host, int port) async {
    try {
      final s = await Socket.connect(host, port, timeout: const Duration(seconds: 3));
      await s.close();
      return true;
    } catch (_) {
      return false;
    }
  }
}
