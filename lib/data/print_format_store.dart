/// Published print-format store — reads the synced FORMAT config domain
/// defensively and keeps the LAST-KNOWN-GOOD set (CONTRACT §5 rule 7).
///
/// Tolerances, all deliberate:
///  * a string payload is decoded, a `{formats:[...]}` map or a bare list is
///    accepted, anything unrecognized is reported and the good set is kept;
///  * an individual malformed format is skipped, the rest still apply;
///  * unknown block types are already dropped by the model (BlockType.unknown,
///    which the renderer refuses to evaluate);
///  * a stale version (lower than the current good one) is rejected with a
///    notice, so the POS never regresses to an older published format.
library;

import 'dart:convert';

import 'package:gundam_pos/data/config_cache.dart';
import 'package:gundam_pos/logic/print_format.dart';

/// A parsed batch of published formats plus what had to be tolerated.
class PrintFormatSet {
  PrintFormatSet(this.formats, {this.version = 0, this.notice});

  static final PrintFormatSet empty = PrintFormatSet(const [], notice: 'no published formats');

  final List<PrintFormat> formats;
  final int version;
  final String? notice;

  bool get isEmpty => formats.isEmpty;

  /// Parse the FORMAT domain payload. Never throws.
  static PrintFormatSet parse(Object? payload, {int version = 0}) {
    final decoded = payload is String ? _tryDecode(payload) : payload;
    final List<Object?>? raw = decoded is List
        ? decoded
        : decoded is Map
            ? decoded['formats'] as List?
            : null;
    if (raw == null) {
      return PrintFormatSet(const [], version: version, notice: 'format payload unrecognized — kept last-known-good');
    }
    final out = <PrintFormat>[];
    var skipped = 0;
    for (final e in raw) {
      if (e is! Map) {
        skipped++;
        continue;
      }
      try {
        final f = PrintFormat.fromJson(Map<String, dynamic>.from(e));
        if (f.formatId.isEmpty && f.blocks.isEmpty) {
          skipped++;
          continue;
        }
        out.add(f);
      } catch (_) {
        skipped++;
      }
    }
    return PrintFormatSet(
      out,
      version: version,
      notice: skipped > 0 ? '$skipped published format(s) skipped (malformed)' : null,
    );
  }

  /// The published format for [ticketType], highest version wins.
  PrintFormat? forTicket(String ticketType) {
    final t = ticketType.toUpperCase();
    PrintFormat? best;
    for (final f in formats) {
      if (f.ticketType != t) continue;
      if (best == null || f.version > best.version) best = f;
    }
    return best;
  }

  static Object? _tryDecode(String s) {
    try {
      return jsonDecode(s);
    } catch (_) {
      return null;
    }
  }
}

/// Holds the currently-trusted [PrintFormatSet]. New payloads are validated
/// before they replace it; a rejected payload leaves the previous trust intact.
class PrintFormatStore {
  PrintFormatStore({ConfigCache? cache}) : _cache = cache;

  final ConfigCache? _cache;
  PrintFormatSet _good = PrintFormatSet.empty;

  PrintFormatSet get current => _good;
  String? get notice => _good.notice;
  bool get hasFormats => _good.formats.isNotEmpty;

  /// The published format for [ticketType], or null → caller uses the built-in.
  PrintFormat? formatFor(String ticketType) => _good.forTicket(ticketType);

  /// Apply a freshly synced FORMAT payload. Returns true when it is adopted;
  /// false (last-known-good kept) when the payload is unrecognized or stale.
  bool apply(Object? payload, {int version = 0}) {
    final incoming = PrintFormatSet.parse(payload, version: version);
    if (incoming.notice != null && incoming.notice!.startsWith('format payload unrecognized')) {
      _good = PrintFormatSet(_good.formats, version: _good.version, notice: incoming.notice);
      return false;
    }
    if (incoming.version > 0 && incoming.version < _good.version) {
      _good = PrintFormatSet(_good.formats, version: _good.version, notice: 'stale format version v${incoming.version} < v${_good.version} — kept last-known-good');
      return false;
    }
    _good = incoming;
    return true;
  }

  /// Read + apply the persisted FORMAT domain from the synced config cache.
  Future<bool> loadFromCache() async {
    final cache = _cache;
    if (cache == null) return false;
    try {
      final key = await cache.read('FORMAT');
      final payload = key?.jsonPayload;
      if (payload == null) return false;
      return apply(payload, version: key?.version ?? 0);
    } catch (_) {
      return false; // last-known-good stays
    }
  }
}
