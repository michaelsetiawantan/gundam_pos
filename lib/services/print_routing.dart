/// Client printer model + routing resolver for the OUTLET config domain.
///
/// The server (`POST /api/pos/config/sync` → `full.OUTLET`) ships:
///   * `printers: [ClientPrinter]`  — transport + addressing + width + raster +
///     retry, scoped to the outlet;
///   * `routing: { BILL: [...], CAPTAIN_ORDER: [{printerId, batchStep}], BEV_LABEL: [...] }`;
///   * `itemRoutes: [{itemId, captainPrinterId, bevPrinterId}]` — the ONLY
///     source for per-item routing (never the item's category).
///
/// Parsing is tolerant: a missing key → empty, an unknown transport → the
/// printer is skipped, anything malformed is dropped. It never throws. A
/// KNOWN-but-unimplemented transport (BLUETOOTH/USB) is kept so the dispatcher
/// can report it honestly instead of pretending it printed.
library;

import 'dart:convert';

import 'package:gundam_pos/services/escpos.dart';
import 'package:gundam_pos/services/print_broker.dart';

/// Transports the model understands. Anything else is skipped on parse.
const Set<String> kKnownPrintTransports = {'NETWORK', 'BLUETOOTH', 'USB'};

/// Transports this build can actually write bytes to: raw TCP :9100, Classic
/// Bluetooth SPP (via the platform channel), and USB Host with the four common
/// serial bridge chips built in (CDC-ACM/CH340/PL2303/FTDI).
const Set<String> kSupportedPrintTransports = {'NETWORK', 'BLUETOOTH', 'USB'};

bool isTransportKnown(String transport) => kKnownPrintTransports.contains(transport.toUpperCase());

bool isTransportSupported(String transport) => kSupportedPrintTransports.contains(transport.toUpperCase());

/// One printer as synced from the outlet config.
///
/// Optional printer-model metadata (a parallel server change) is consumed
/// tolerantly: `modelId`, `brand`, `model`, `protocol`/`dialect`, and the
/// model's `supportsRasterImage`. The same keys are also accepted nested under a
/// `printerModel` (or a `model` object). When absent (older payloads) the
/// printer behaves exactly as before: default ESC/POS dialect and its own raster
/// flag.
class ClientPrinter {
  const ClientPrinter({
    required this.id,
    required this.name,
    this.type = '',
    this.transport = 'NETWORK',
    this.ip,
    this.port = 9100,
    this.bluetoothMac,
    this.usbVidPid,
    this.usbChip,
    this.widthMm = 80,
    this.supportsRasterImage = false,
    this.shared = false,
    this.active = true,
    this.retryCount = 3,
    this.retryTimeoutSec = 20,
    this.modelId,
    this.brand,
    this.model,
    this.protocol,
    this.modelSupportsRasterImage,
  });

  /// null → skipped (no id, or a transport the model does not know).
  static ClientPrinter? fromJson(Map<String, dynamic> j) {
    final id = (j['id'] as String?) ?? '';
    if (id.isEmpty) return null;
    final transport = ((j['transport'] as String?) ?? 'NETWORK').toUpperCase();
    if (!isTransportKnown(transport)) return null;
    // Model metadata may be flat or nested under `printerModel` / a `model` map.
    final nestedModel = j['printerModel'] is Map
        ? Map<String, dynamic>.from(j['printerModel'] as Map)
        : const <String, dynamic>{};
    final nestedLegacy = j['model'] is Map
        ? Map<String, dynamic>.from(j['model'] as Map)
        : const <String, dynamic>{};
    return ClientPrinter(
      id: id,
      name: (j['name'] as String?) ?? id,
      type: (j['type'] as String?) ?? '',
      transport: transport,
      ip: j['ip'] as String?,
      port: _int(j['port']) ?? 9100,
      bluetoothMac: _str(j['bluetoothMac']),
      usbVidPid: _str(j['usbVidPid']),
      // The bridge chip is a parallel (web) addition; absent → null (documented
      // fallback: the USB transport derives the chip from the attached device).
      usbChip: _str(j['usbChip'] ?? nestedModel['usbChip'] ?? nestedLegacy['usbChip']),
      widthMm: _int(j['widthMm']) ?? 80,
      supportsRasterImage: (j['supportsRasterImage'] as bool?) ?? false,
      shared: (j['shared'] as bool?) ?? false,
      active: (j['active'] as bool?) ?? true,
      retryCount: _int(j['retryCount']) ?? 3,
      retryTimeoutSec: _int(j['retryTimeoutSec']) ?? 20,
      modelId: _str(j['modelId'] ?? nestedModel['id'] ?? nestedLegacy['id']),
      brand: _str(j['brand'] ?? nestedModel['brand'] ?? nestedLegacy['brand']),
      model: _str(j['model'] is String
          ? j['model']
          : (nestedModel['name'] ?? nestedLegacy['name'] ?? nestedLegacy['model'])),
      protocol: _str(j['protocol'] ?? j['dialect'] ?? nestedModel['protocol'] ?? nestedLegacy['protocol']),
      modelSupportsRasterImage: _bool(
        j['modelSupportsRasterImage'] ?? nestedModel['supportsRasterImage'] ?? nestedLegacy['supportsRasterImage'],
      ),
    );
  }

  final String id;
  final String name;
  final String type;
  final String transport;
  final String? ip;
  final int port;
  final String? bluetoothMac;
  final String? usbVidPid;

  /// Bridge chip the web config asks for (`CDC_ACM`|`CH340`|`PL2303`|`FTDI`).
  /// null when the field is absent (a parallel web change) — the USB transport
  /// then derives the chip from the attached device.
  final String? usbChip;
  final int widthMm;
  final bool supportsRasterImage;

  /// Optional printer-model identity + dialect (absent on older payloads).
  final String? modelId;
  final String? brand;
  final String? model;
  final String? protocol;
  final bool? modelSupportsRasterImage;

  /// A shared printer may be used by any device on the outlet.
  final bool shared;
  final bool active;
  final int retryCount;
  final int retryTimeoutSec;

  bool get supported => isTransportSupported(transport);

  /// Canonical ESC/POS dialect chosen from the printer/model `protocol`. No
  /// `protocol` → the documented default; an unrecognised value is kept so the
  /// alert path can report it (printing still uses the default).
  String get dialect => normalizeDialect(protocol);

  bool get dialectRecognized => isKnownDialect(dialect);

  /// Effective raster capability: the printer's own flag OR the model's.
  bool get effectiveRasterSupport => supportsRasterImage || (modelSupportsRasterImage ?? false);

  /// The broker's transport descriptor. NETWORK carries a host; BLUETOOTH
  /// carries the bonded device MAC.
  PrintPrinter toPrintPrinter() => PrintPrinter(
        name: name,
        host: ip,
        port: port,
        transport: transport,
        bluetoothMac: bluetoothMac,
        usbVidPid: usbVidPid,
        usbChip: usbChip,
        widthMm: widthMm,
        supportsRasterImage: effectiveRasterSupport,
        dialect: dialect,
        retryCount: retryCount,
        retryTimeoutSec: retryTimeoutSec,
      );
}

/// One routing row: a printer bound to a target, optionally per batch step
/// (captain-order batch A,B,C → step 0,1,2).
class RoutingEntry {
  const RoutingEntry({required this.printerId, this.batchStep});

  static RoutingEntry fromJson(Map<String, dynamic> j) =>
      RoutingEntry(printerId: (j['printerId'] as String?) ?? '', batchStep: _int(j['batchStep']));

  final String printerId;
  final int? batchStep;
}

/// Strict item-level captain/bev assignment (no category fallback).
class ItemRoute {
  const ItemRoute({required this.itemId, this.captainPrinterId, this.bevPrinterId});

  static ItemRoute fromJson(Map<String, dynamic> j) => ItemRoute(
        itemId: (j['itemId'] as String?) ?? '',
        captainPrinterId: j['captainPrinterId'] as String?,
        bevPrinterId: j['bevPrinterId'] as String?,
      );

  final String itemId;
  final String? captainPrinterId;
  final String? bevPrinterId;
}

/// Parsed outlet printer model + resolvers.
class PrinterRouting {
  PrinterRouting({required this.printers, required this.routing, required this.itemRoutes});

  static final PrinterRouting empty =
      PrinterRouting(printers: const [], routing: const {}, itemRoutes: const {});

  final List<ClientPrinter> printers;
  final Map<String, List<RoutingEntry>> routing; // by target: BILL/CAPTAIN_ORDER/BEV_LABEL
  final Map<String, ItemRoute> itemRoutes; // by itemId

  /// Parse the OUTLET payload (or its `printers`/`routing`/`itemRoutes` keys).
  /// Never throws.
  static PrinterRouting parse(Object? outlet) {
    try {
      final payload = outlet is String ? _tryDecode(outlet) : outlet;
      if (payload is! Map) return empty;

      final printers = <ClientPrinter>[];
      final rawPrinters = payload['printers'];
      if (rawPrinters is List) {
        for (final e in rawPrinters) {
          if (e is! Map) continue;
          final p = ClientPrinter.fromJson(Map<String, dynamic>.from(e));
          if (p != null) printers.add(p);
        }
      }

      final routing = <String, List<RoutingEntry>>{};
      final rawRouting = payload['routing'];
      if (rawRouting is Map) {
        for (final target in const ['BILL', 'CAPTAIN_ORDER', 'BEV_LABEL']) {
          final list = rawRouting[target];
          if (list is List) {
            routing[target] = [
              for (final e in list)
                if (e is Map) RoutingEntry.fromJson(Map<String, dynamic>.from(e)),
            ]..removeWhere((r) => r.printerId.isEmpty);
          }
        }
      }

      final itemRoutes = <String, ItemRoute>{};
      final rawItems = payload['itemRoutes'];
      if (rawItems is List) {
        for (final e in rawItems) {
          if (e is! Map) continue;
          final r = ItemRoute.fromJson(Map<String, dynamic>.from(e));
          if (r.itemId.isNotEmpty) itemRoutes[r.itemId] = r;
        }
      }

      return PrinterRouting(printers: printers, routing: routing, itemRoutes: itemRoutes);
    } catch (_) {
      return empty;
    }
  }

  ClientPrinter? printerById(String? id) {
    if (id == null) return null;
    for (final p in printers) {
      if (p.id == id) return p;
    }
    return null;
  }

  List<ClientPrinter> get activePrinters => [for (final p in printers) if (p.active) p];

  /// Printers bound to a target that are active and resolvable.
  List<ClientPrinter> _resolve(List<RoutingEntry>? entries) {
    final out = <ClientPrinter>[];
    for (final e in entries ?? const []) {
      final p = printerById(e.printerId);
      if (p != null && p.active) out.add(p);
    }
    return out;
  }

  /// Outlet-level BILL routing — multi-printer, all active targets.
  List<ClientPrinter> billPrinters() => _resolve(routing['BILL']);

  /// Captain printers for a batch step: exact `batchStep` rows win, else the
  /// step-less rows (the outlet default).
  List<ClientPrinter> captainPrintersForStep(int step) {
    final entries = routing['CAPTAIN_ORDER'] ?? const [];
    final exact = _resolve([for (final e in entries) if (e.batchStep == step) e]);
    if (exact.isNotEmpty) return exact;
    return _resolve([for (final e in entries) if (e.batchStep == null) e]);
  }

  /// Strict item-level captain printer (itemRoutes only — no category fallback).
  ClientPrinter? captainPrinterForItem(String itemId) {
    final p = printerById(itemRoutes[itemId]?.captainPrinterId);
    return (p != null && p.active) ? p : null;
  }

  /// Strict item-level bev-label printer.
  ClientPrinter? bevPrinterForItem(String itemId) {
    final p = printerById(itemRoutes[itemId]?.bevPrinterId);
    return (p != null && p.active) ? p : null;
  }

  /// Known-transport printers this build cannot print to — reported, not dropped.
  List<ClientPrinter> get unsupportedPrinters =>
      [for (final p in printers) if (!p.supported) p];

  static Object? _tryDecode(String s) {
    try {
      return jsonDecode(s);
    } catch (_) {
      return null;
    }
  }
}

int? _int(Object? v) {
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v);
  return null;
}

String? _str(Object? v) => v == null ? null : (v is String ? v : v.toString());

bool? _bool(Object? v) => v is bool ? v : null;
