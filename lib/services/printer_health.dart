/// Printer link health — transport-level check, reported by the POS (never the
/// cloud). Per PRD, only a model with real-time ESC/POS status can claim
/// Healthy; otherwise we report `unknown` instead of asserting health.
library;

import 'dart:io';

enum PrinterLinkState { ready, offline, notPaired, bluetoothOff, unsupported, unknown }

class PrinterLink {
  PrinterLink(this.state, {this.detail = ''});

  final PrinterLinkState state;
  final String detail;

  bool get isUsable => state == PrinterLinkState.ready || state == PrinterLinkState.unknown;
}

/// A type alias for the reachability probe so tests can inject a fake (the
/// default opens a TCP socket to the printer's :9100 endpoint).
typedef Reachability = Future<bool> Function(String host, int port);

class PrinterHealthChecker {
  PrinterHealthChecker({Reachability? connect}) : _connect = connect ?? _tcpProbe;

  final Reachability _connect;

  /// Check a printer by its configured transport.
  /// - NETWORK: TCP connect to host:port → ready (or offline).
  /// - BLUETOOTH / USB: not implemented on this build → unsupported.
  /// If the printer model cannot surface real-time status, we mark the link
  /// `unknown` rather than claim healthy (PRD printer-health rule).
  Future<PrinterLink> check({
    required String transport,
    String? host,
    int port = 9100,
    bool supportsDeviceStatus = false,
  }) async {
    switch (transport) {
      case 'BLUETOOTH':
        return PrinterLink(PrinterLinkState.unsupported, detail: 'Bluetooth transport is not wired on this build yet.');
      case 'USB':
        return PrinterLink(PrinterLinkState.unsupported, detail: 'USB transport is not wired on this build yet.');
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