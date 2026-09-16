/// Receipt ID is born DEVICE-SIDE (server trusts the device timestamp):
/// `[shortcode]-[YYYYMMDD]-[HH:MM]-0000001`, seq resets at 00:00 per device.
library;

/// Server-truth validation pattern (`web/lib/pos/settle.ts` RECEIPT_RE).
final RegExp receiptRe = RegExp(r'^[A-Za-z0-9-]+-\d{8}-\d{2}:\d{2}-\d{7}$');

/// Compose a receipt id for the given device shortcode, date and 1-based seq.
/// `[hh:mm]` uses the device local clock.
String makeReceiptId({
  required String shortcode,
  required DateTime at,
  required int seq,
}) {
  assert(seq >= 1 && seq <= 9999999, 'seq must be 1..9999999');
  final y = at.year.toString().padLeft(4, '0');
  final m = at.month.toString().padLeft(2, '0');
  final d = at.day.toString().padLeft(2, '0');
  final hh = at.hour.toString().padLeft(2, '0');
  final mm = at.minute.toString().padLeft(2, '0');
  final date = '$y$m$d';
  final seqS = seq.toString().padLeft(7, '0');
  return '$shortcode-$date-$hh:$mm-$seqS';
}

bool isValidReceiptId(String raw) => receiptRe.hasMatch(raw);

/// Daily date stamp used to scope per-device sequence resets (00:00/device).
String dateStamp(DateTime at) {
  final y = at.year.toString().padLeft(4, '0');
  final m = at.month.toString().padLeft(2, '0');
  final d = at.day.toString().padLeft(2, '0');
  return '$y$m$d';
}