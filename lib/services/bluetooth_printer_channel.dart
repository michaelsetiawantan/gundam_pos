/// Thin client for the `gundam/printer` Android platform channel (Classic
/// Bluetooth SPP/RFCOMM). Pure plumbing: it never throws on a printer fault —
/// the Kotlin side answers every call with a typed `{state, detail}` map, and a
/// missing plugin (non-Android host) degrades to `unsupported`.
library;

import 'package:flutter/services.dart';

/// Result of a channel call: a PRD status code plus a human detail.
class PrinterChannelResult {
  const PrinterChannelResult(this.state, this.detail);

  final String state; // ready | offline | disconnected | not_paired |
  //                     bluetooth_off | permission_required | unsupported
  final String detail;

  bool get ok => state == 'ready';
}

class BluetoothPrinterChannel {
  BluetoothPrinterChannel({MethodChannel? channel, this.timeoutMs = 8000})
      : _channel = channel ?? const MethodChannel(channelName);

  static const String channelName = 'gundam/printer';

  final MethodChannel _channel;
  final int timeoutMs;

  /// Adapter state + permission state, as a typed result.
  Future<PrinterChannelResult> status() async => _result(await _invoke('status'));

  /// Bonded devices: `{name, mac}`. Empty when unavailable or not permitted.
  Future<List<Map<String, dynamic>>> listBonded() async {
    final raw = await _invoke('listBonded');
    if (raw is! List) return const [];
    return [
      for (final e in raw)
        if (e is Map) Map<String, dynamic>.from(e),
    ];
  }

  /// Ask the OS for a runtime Bluetooth permission (Android 12+). Resolves with
  /// `true` when granted. Pre-12 it is install-time and resolves immediately.
  Future<bool> requestPermission() async => (await _invoke('requestPermission')) == true;

  /// Open an SPP socket to a bonded [mac] and wait up to [timeoutMs].
  Future<PrinterChannelResult> connect(String mac, {int? timeoutMs}) async =>
      _result(await _invoke('connect', {'mac': mac, 'timeoutMs': timeoutMs ?? this.timeoutMs}));

  /// Write raw ESC/POS bytes to the open socket.
  Future<PrinterChannelResult> write(List<int> bytes) async =>
      _result(await _invoke('write', {'bytes': Uint8List.fromList(bytes)}));

  Future<bool> close() async {
    try {
      return (await _channel.invokeMethod('close')) == true;
    } catch (_) {
      return true;
    }
  }

  Future<bool> isConnected() async {
    try {
      return (await _channel.invokeMethod('isConnected')) == true;
    } catch (_) {
      return false;
    }
  }

  Future<Object?> _invoke(String method, [Map<String, Object?>? args]) async {
    try {
      return await _channel.invokeMethod(method, args);
    } on MissingPluginException {
      return {'state': 'unsupported', 'detail': 'Bluetooth platform channel is unavailable on this host.'};
    } on PlatformException catch (e) {
      return {'state': e.code, 'detail': e.message ?? e.code};
    } catch (e) {
      return {'state': 'unsupported', 'detail': '$e'};
    }
  }

  static PrinterChannelResult _result(Object? raw) {
    if (raw is Map) {
      final m = Map<String, dynamic>.from(raw);
      return PrinterChannelResult(
        (m['state'] as String?) ?? 'unknown',
        (m['detail'] as String?) ?? '',
      );
    }
    return const PrinterChannelResult('unknown', 'Unrecognised platform reply.');
  }
}
