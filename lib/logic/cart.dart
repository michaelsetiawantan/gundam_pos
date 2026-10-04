/// Cart model for the POS order-entry flow. The cart is a thin execution
/// surface; the server re-prices and enforces business at add-line/settle.
/// This mirror of `web/lib/pricing.ts lineUnitPrice` is used only for the
/// live totals shown before the server recomputes.
library;

import 'package:gundam_pos/logic/money.dart' as money;

/// A paid modifier on a cart line (price always ≥ 0; open-mod text is price 0).
class CartModifier {
  CartModifier({this.modifierId, required this.name, this.price = 0, this.qty = 1, this.openText});

  final String? modifierId;
  final String name;
  final double price;
  final int qty;
  final String? openText;

  double get subtotal => money.round2(price * qty);

  String get signature => modifierId ?? 'open:$openText';
}

class CartLine {
  CartLine({
    required this.itemId,
    required this.name,
    required this.sku,
    required this.qty,
    required this.priceLevelIndex,
    required this.unitPrice, // base unit price (level price before mods)
    this.lineId, // server OrderLine id (null = purely local, never server-backed)
    this.modifiers = const [],
    this.vatMode = money.VatScMode.none,
    this.scMode = money.VatScMode.none,
    this.sent = false,
    this.pending = false, // local-only: queued to the outbox, not yet confirmed
    this.failed = false, // local-only: server rejected this add
    this.localKey, // stable local identity for the outbox (entityId)
    this.syncedQty = 0, // qty already confirmed on the server for this line
  });

  /// Server line id (`OrderLine.id`). The server is authoritative for lines, so
  /// removing a line must target THIS id via DELETE /orders/[id]/lines/[lineId].
  /// Null only for a line the server never acknowledged. Mutated when an
  /// optimistically-added line is adopted from the server response.
  String? lineId;

  final String itemId;
  final String name;
  final String sku;
  int qty;
  final int priceLevelIndex;

  /// Base unit price (level price before mods) while [pending]; the server's
  /// modifier-INCLUSIVE unit price after adoption (modifiers then dropped).
  double unitPrice;
  List<CartModifier> modifiers;
  final money.VatScMode vatMode;
  final money.VatScMode scMode;
  bool sent; // already send-cart → never reprinted

  /// Local-only sync flags: [pending] = queued in the outbox, awaiting the
  /// server; [failed] = the server rejected the add (operator must remove it).
  bool pending;
  bool failed;

  /// Stable local identity used as the outbox `entityId` for this add, so a
  /// queued push can be matched back to this line. Null for lines that never
  /// went through the offline path (server-adopted at load time).
  final String? localKey;

  /// Qty already confirmed by the server for this line. `qty - syncedQty` is the
  /// unconfirmed delta to push (the server SUMS by client line key, so a re-add
  /// of an adopted line must carry only the delta, never the running total).
  int syncedQty;

  /// Modifier-inclusive unit price (server: lineUnitPrice = base + Σ mods).
  double get unitPriceWithMods => money.round2(unitPrice + modifiers.fold<double>(0, (s, m) => s + m.subtotal));

  double get lineSubtotal => money.round2(unitPriceWithMods * qty);

  /// Identity for merging: same item + price level + same modifier picks.
  String signature() {
    final mods = modifiers.map((m) => m.signature).toList()..sort((a, b) => a.compareTo(b));
    return '$itemId|$priceLevelIndex|${mods.join(',')}';
  }
}

class CartError implements Exception {
  CartError(this.message);
  final String message;
}

/// The active order's cart. Lines merge unless the pricing pick differs.
class Cart {
  final List<CartLine> lines = [];

  double get total => money.round2(lines.fold<double>(0, (s, l) => s + l.lineSubtotal));

  int get itemCount => lines.fold<int>(0, (s, l) => s + l.qty);

  bool get isEmpty => lines.isEmpty;

  /// Add a line. `merge` folds an identical UNSENT line into one row (pure
  /// local convenience). Order sync passes `merge: false`: the server keeps one
  /// OrderLine per add, so the local cart must stay 1:1 with it or a later
  /// delete/removal targets the wrong row.
  void addLine(CartLine line, {bool merge = true}) {
    if (merge) {
      for (final l in lines) {
        if (l.signature() == line.signature() && !l.sent) {
          l.qty += line.qty;
          return;
        }
      }
    }
    lines.add(line);
  }

  /// Remove an unsent line; a sent line resists removal (cancel path instead).
  void removeLine(CartLine line, {int qty = 1}) {
    if (line.sent) throw CartError('line_already_sent');
    line.qty -= qty;
    if (line.qty <= 0) lines.remove(line);
  }

  void clear({bool keepSent = true}) {
    if (!keepSent) {
      lines.clear();
      return;
    }
    lines.removeWhere((l) => !l.sent);
  }
}