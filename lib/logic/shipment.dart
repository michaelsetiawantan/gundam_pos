import 'package:gundam_pos/logic/money.dart' as money;

/// Shipment step (PRD 'Shipment / Delivery fee'): a SEPARATE revenue line —
/// outside discount/voucher, VAT and SC — added after SC and before rounding.
/// Two shapes:
///  * OPEN shipment: the cashier types the amount (0..unlimited; never
///    negative). Needs no master.
///  * MASTER shipment: a precise amount from a config-shipped master. Only
///    usable when the server actually ships `shipmentMasters` (see
///    [kShipmentMastersUnavailable]); today it does not.
///
/// An empty or 0 amount means there is NO shipment line (nothing prints).
class ShipmentLine {
  const ShipmentLine.open(this.amount, {this.description = 'Shipment'})
      : masterId = null,
        masterName = null;

  const ShipmentLine.master({
    required this.masterId,
    required this.masterName,
    required this.amount,
  }) : description = masterName ?? 'Shipment';

  final double amount; // > 0 when a line exists
  final String description; // short desc, prints as its own line
  final String? masterId; // set when chosen from a master
  final String? masterName;

  bool get isMaster => masterId != null;

  /// Settle-body fragment in the shape the server expects
  /// (`web/lib/pos/settle.ts`: `{ amount?, description?, masterShipmentId? }`).
  Map<String, dynamic> toSettleBody() => {
        'description': description,
        if (isMaster) 'masterShipmentId': masterId else 'amount': amount,
      };
}

/// Parse a cashier-typed OPEN shipment amount.
/// Returns null when the input is not a valid amount (non-numeric or
/// negative — a shipment can never be negative). Empty and 0 return 0, meaning
/// "no shipment line".
double? parseShipmentAmount(Object? raw) {
  if (raw is num) return raw < 0 ? null : money.round2(raw.toDouble());
  final t = (raw ?? '').toString().trim();
  if (t.isEmpty) return 0;
  final v = double.tryParse(t);
  if (v == null || v < 0) return null;
  return money.round2(v);
}
