/// Client-born ORDER number for offline order creation. Unique per POS device
/// because it embeds the POS shortcode; two tablets can never mint the same id.
/// Pattern: `[POS-shortcode]-[YYYYMMDD]-[HHMM]-[NNNNNN]`.
///
/// The server accepts the id verbatim and is idempotent on retry — it never
/// invents one when the tablet supplies `clientOrderId`.
library;

import 'package:gundam_pos/data/pos_store.dart';
import 'package:gundam_pos/logic/receipt.dart';

/// Server-side shape check (`web/lib/pos/orders.ts` CLIENT_ORDER_ID_RE).
final RegExp clientOrderIdRe = RegExp(r'^[A-Za-z0-9][A-Za-z0-9:._-]{5,63}$');

/// Composes an order number from a device shortcode, a timestamp and a 1-based
/// per-(device, day) sequence. [HHMM] uses the device local clock.
String makeOrderNumber({
  required String shortcode,
  required DateTime at,
  required int seq,
}) {
  assert(seq >= 1, 'seq must be >= 1');
  final y = at.year.toString().padLeft(4, '0');
  final m = at.month.toString().padLeft(2, '0');
  final d = at.day.toString().padLeft(2, '0');
  final hh = at.hour.toString().padLeft(2, '0');
  final mm = at.minute.toString().padLeft(2, '0');
  return '$shortcode-$y$m$d-$hh$mm-${seq.toString().padLeft(6, '0')}';
}

bool isValidClientOrderId(String raw) => clientOrderIdRe.hasMatch(raw);

/// Mints order numbers for THIS device. Reuses the durable
/// [ReceiptSequenceStore] (sqflite `receipt_sequence`) so the per-(device, day)
/// counter survives a restart and stays strictly increasing — two orders on one
/// device can never collide.
class OrderNumberGenerator {
  OrderNumberGenerator({required ReceiptSequenceStore store, DateTime Function()? now})
      : _store = store,
        _now = now ?? DateTime.now;

  final ReceiptSequenceStore _store;
  final DateTime Function() _now;

  Future<String> next(String shortcode, {DateTime? at}) async {
    final now = at ?? _now();
    final seq = await _store.next(shortcode, dateStamp(now));
    return makeOrderNumber(shortcode: shortcode, at: now, seq: seq);
  }
}
