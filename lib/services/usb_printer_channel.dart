/// Thin client for the `gundam/printer/usb` Android platform channel — the USB
/// Host transport with the common serial bridge chips built into the APK
/// (CDC-ACM, CH340/CH341, PL2303, FTDI, CP210x) plus direct raw-bulk printing
/// for USB printer-class (0x07) and vendor-specific (0xFF) printers.
///
/// Pure plumbing in the same shape as [BluetoothPrinterChannel]: it never throws
/// on a printer fault — the Kotlin side answers every call with a typed
/// `{state, detail}` map, and a missing plugin (non-Android host) degrades to
/// `unsupported`.
///
/// The chip → device-id table below mirrors `UsbSerialDrivers.kt` so the Dart
/// side can (a) pick the driver the config asks for and (b) refuse a configured
/// chip that does not match the attached device — never a silent wrong-chip
/// write.
library;

import 'package:flutter/services.dart';
import 'package:gundam_pos/services/bluetooth_printer_channel.dart' show PrinterChannelResult;

/// One attached USB device as reported by the channel.
class UsbDeviceInfo {
  const UsbDeviceInfo({
    required this.vid,
    required this.pid,
    this.name = '',
    this.chip = '',
    this.serial,
    this.granted = false,
  });

  final int vid;
  final int pid;
  final String name;

  /// Canonical chip id the Kotlin side resolved (`CDC_ACM`|`CH340`|`PL2303`|
  /// `FTDI`|`CP210X`|`USB_PRINTER_CLASS`|`USB_VENDOR_SPECIFIC`), or '' when the
  /// device is not a supported bridge.
  final String chip;
  final String? serial;
  final bool granted;

  static UsbDeviceInfo? fromJson(Map<String, dynamic> j) {
    final vid = (j['vid'] as num?)?.toInt();
    final pid = (j['pid'] as num?)?.toInt();
    if (vid == null || pid == null) return null;
    return UsbDeviceInfo(
      vid: vid,
      pid: pid,
      name: (j['name'] as String?) ?? '',
      chip: (j['chip'] as String?) ?? '',
      serial: j['serial'] as String?,
      granted: (j['granted'] as bool?) ?? false,
    );
  }

  /// `1A86:7523` — the same shape the web `usbVidPid` field stores.
  String get vidPid => '${vid.toRadixString(16).toUpperCase().padLeft(4, '0')}:'
      '${pid.toRadixString(16).toUpperCase().padLeft(4, '0')}';
}

/// The chips this build drives, and the vendor/product ids each answers to.
/// Mirrors `UsbSerialDrivers.kt` — keep the two in step.
const Map<String, List<(int, int)>> kUsbChipDeviceIds = {
  'CH340': [(0x1A86, 0x7523), (0x1A86, 0x5523), (0x1A86, 0x7522), (0x1A86, 0x55D4)],
  'PL2303': [
    (0x067B, 0x2303), (0x067B, 0x2304), (0x067B, 0x23A3), (0x067B, 0x23B3),
    (0x067B, 0x23C3), (0x067B, 0x23D3), (0x067B, 0x23E3), (0x067B, 0x23F3),
  ],
  'FTDI': [(0x0403, 0x6001), (0x0403, 0x6015), (0x0403, 0x6014), (0x0403, 0x6010), (0x0403, 0x6011)],
  'CP210X': [(0x10C4, 0xEA60), (0x10C4, 0xEAB0), (0x10C4, 0xEA70), (0x10C4, 0xEA71), (0x10C4, 0xEA63)],
};

/// Vendors whose CDC-ACM (class 0x02/0x0A) interfaces this build drives.
const Set<int> kCdcAcmVendorIds = {0x2341, 0x2A03, 0x1A86, 0x0483, 0x303A, 0x1EAF, 0x239A, 0x1915, 0x1209};

/// The USB chip codes the WEB vocabulary ships (web `USB_CHIPS`), in canonical
/// order. Every one of these MUST resolve — via [canonicalUsbChip] — to an id in
/// [kUsbDriverIds] (a driver this APK really carries); the drift-guard manifest
/// `pos/tool/printer-vocabulary.json` is generated from this list.
const List<String> kUsbChipWebCodes = [
  'CDC_ACM',
  'CH340_CH341',
  'PL2303',
  'FTDI_FT232R',
  'FTDI_FT231X',
  'CP210X',
  'USB_PRINTER_CLASS',
  'USB_VENDOR_SPECIFIC',
];

/// The canonical driver ids this build drives — mirrors `UsbSerialDrivers.all`
/// in `UsbSerialDrivers.kt`. A configured chip that canonicalises to anything
/// else is a typed, reported error on the Kotlin side, never a wrong-driver
/// write.
const Set<String> kUsbDriverIds = {
  'CDC_ACM',
  'CH340',
  'PL2303',
  'FTDI',
  'CP210X',
  'USB_PRINTER_CLASS',
  'USB_VENDOR_SPECIFIC',
};

/// The canonical chip id for a configured `usbChip` value, or null when unset /
/// `AUTO` (the documented fallback: derive the chip from the attached device).
///
/// Accepts both the web vocabulary codes (`CH340_CH341`, `FTDI_FT232R`,
/// `FTDI_FT231X`, `CP210X`, `USB_PRINTER_CLASS`, `USB_VENDOR_SPECIFIC`) and the
/// shorter canonical ids the drivers use (`CH340`, `FTDI`, …).
String? canonicalUsbChip(String? raw) {
  final v = (raw ?? '').trim().toUpperCase().replaceAll(RegExp(r'[-\s]+'), '_');
  switch (v) {
    case '':
    case 'AUTO':
    case 'ANY':
      return null;
    case 'CDC':
    case 'CDCACM':
    case 'ACM':
    case 'CDC_ACM':
      return 'CDC_ACM';
    case 'CH340':
    case 'CH341':
    case 'CH340G':
    case 'CH341A':
    case 'CH34X':
    case 'CH340_CH341':
    case 'CH340_341':
      return 'CH340';
    case 'PL2303':
    case 'PL2303HX':
    case 'PL2303HXA':
    case 'PL2303HXD':
    case 'PROLIFIC':
      return 'PL2303';
    case 'FTDI':
    case 'FT232':
    case 'FT232R':
    case 'FT231':
    case 'FT231X':
    case 'FTDI_FT232R':
    case 'FTDI_FT231X':
    case 'FT234X':
      return 'FTDI';
    case 'CP210X':
    case 'CP2101':
    case 'CP2102':
    case 'CP2102N':
    case 'CP2103':
    case 'CP2104':
    case 'CP2105':
    case 'CP2108':
    case 'SILABS':
    case 'SILICON_LABS':
    case 'SI_LABS':
      return 'CP210X';
    case 'USB_PRINTER_CLASS':
    case 'PRINTER_CLASS':
    case 'USB_PRINTER':
    case 'PRINTER':
    case 'RAW_USB':
      return 'USB_PRINTER_CLASS';
    case 'USB_VENDOR_SPECIFIC':
    case 'VENDOR_SPECIFIC':
    case 'USB_VENDOR':
    case 'VENDOR':
      return 'USB_VENDOR_SPECIFIC';
    default:
      return v; // an unrecognised value is kept so it can be reported, not guessed
  }
}

/// The chip a vendor/product id belongs to, or null when unsupported.
String? usbChipForVidPid(int vid, int pid, {bool cdcByClass = false}) {
  for (final e in kUsbChipDeviceIds.entries) {
    if (e.value.any((d) => d.$1 == vid && d.$2 == pid)) return e.key;
  }
  if (cdcByClass && kCdcAcmVendorIds.contains(vid)) return 'CDC_ACM';
  return null;
}

/// Parse a `usbVidPid` config string (`1A86:7523`, `0x1A86:0x7523`, `1a86-7523`).
/// Returns null when absent or malformed — never throws.
(int, int)? parseUsbVidPid(String? raw) {
  final v = (raw ?? '').trim();
  if (v.isEmpty) return null;
  final m = RegExp(r'^(?:0x)?([0-9a-fA-F]{1,4})\s*[:\-]\s*(?:0x)?([0-9a-fA-F]{1,4})$').firstMatch(v);
  if (m == null) return null;
  final vid = int.tryParse(m.group(1)!, radix: 16);
  final pid = int.tryParse(m.group(2)!, radix: 16);
  if (vid == null || pid == null) return null;
  return (vid, pid);
}

class UsbPrinterChannel {
  UsbPrinterChannel({MethodChannel? channel, this.permissionTimeoutMs = 15000})
      : _channel = channel ?? const MethodChannel(channelName);

  static const String channelName = 'gundam/printer/usb';

  final MethodChannel _channel;
  final int permissionTimeoutMs;

  /// Host state (adapter present, any device attached), as a typed result.
  Future<PrinterChannelResult> status() async => _result(await _invoke('status'));

  /// Every attached USB device with the chip this build would drive it with.
  Future<List<UsbDeviceInfo>> listDevices() async {
    final raw = await _invoke('listDevices');
    if (raw is! List) return const [];
    final out = <UsbDeviceInfo>[];
    for (final e in raw) {
      if (e is! Map) continue;
      final d = UsbDeviceInfo.fromJson(Map<String, dynamic>.from(e));
      if (d != null) out.add(d);
    }
    return out;
  }

  Future<bool> hasPermission({int? vid, int? pid}) async =>
      (await _invoke('hasPermission', {'vid': vid, 'pid': pid})) == true;

  /// Ask the OS to open the configured device; resolves with the user's answer.
  Future<bool> requestPermission({int? vid, int? pid}) async =>
      (await _invoke('requestPermission', {'vid': vid, 'pid': pid, 'timeoutMs': permissionTimeoutMs})) == true;

  /// Claim the interface and run the chip init sequence.
  Future<PrinterChannelResult> open({required int vid, required int pid, required String chip, int baud = 9600}) async =>
      _result(await _invoke('open', {'vid': vid, 'pid': pid, 'chip': chip, 'baud': baud}));

  /// Write raw ESC/POS bytes over bulk OUT.
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
      return {'state': 'unsupported', 'detail': 'USB host platform channel is unavailable on this host.'};
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
