import 'package:flutter_test/flutter_test.dart';
import 'package:gundam_pos/logic/cart.dart';
import 'package:gundam_pos/logic/money.dart' as money;
import 'package:gundam_pos/logic/print_format_render.dart';
import 'package:gundam_pos/logic/print_payload.dart';
import 'package:gundam_pos/services/escpos.dart';
import 'package:gundam_pos/services/print_broker.dart';

import 'support/print_support.dart';

/// A CASH sale must pop the drawer wired to the receipt printer (ESC/POS pulse),
/// and a card sale must not. The kick rides the bill job itself, so it works
/// offline and survives the queue/retry path like any other line.
void main() {
  const pulse = [0x1B, 0x70, 0x00, 0x19, 0xFA];

  money.MoneyFlow flow() => money.computeMoneyFlow(
        [money.MoneyLine(subtotal: 45000, vatMode: money.VatScMode.none, scMode: money.VatScMode.none)],
        0, 0, money.RoundingMode.none,
      );
  money.SplitResult split() => money.finalizePayments(flow().total, [
        money.PaymentInput(outletMethodId: 'pm-cash', type: money.PayType.cash, amount: flow().total),
      ]);
  List<CartLine> lines() => [
        CartLine(itemId: 'item-nasi', name: 'Nasi Goreng', sku: 'S', qty: 1, priceLevelIndex: 0, unitPrice: 45000),
      ];

  test('the encoder puts the real ESC/POS drawer pulse on the wire', () {
    final job = PrintJob(
      ticketType: 'BILL',
      lines: const ['x'],
      entries: [PrintableEntry(kind: PrintableKind.pulse, atLine: 1)],
      printer: buildDispatcher(RecordingTransport()).routing.billPrinters().first.toPrintPrinter(),
    );
    final bytes = encodePrintJob(job, widthMm: 80);
    // The 5-byte pulse is present, in order.
    expect(_indexOfSeq(bytes, pulse), greaterThanOrEqualTo(0),
        reason: 'ESC p must reach the printer');
  });

  test('a CASH bill job carries the pulse entry; a card bill does not', () async {
    final cash = RecordingTransport();
    await buildDispatcher(cash).printBill(
      items: [PrintItem.fromCartLine(lines().single)],
      receiptId: 'NSTAR-POS1-20260928-14:05-0000001',
      flow: flow(), split: split(), tableName: 'A1',
      openDrawer: true,
    );
    expect(cash.jobs.single.entries.any((e) => e.kind == PrintableKind.pulse), isTrue,
        reason: 'cash → the drawer pops with the bill');

    final card = RecordingTransport();
    await buildDispatcher(card).printBill(
      items: [PrintItem.fromCartLine(lines().single)],
      receiptId: 'NSTAR-POS1-20260928-14:06-0000002',
      flow: flow(), split: split(), tableName: 'A1',
      openDrawer: false,
    );
    expect(card.jobs.single.entries.any((e) => e.kind == PrintableKind.pulse), isFalse,
        reason: 'card → no kick');
  });

  test('a REPRINT does not open the drawer', () async {
    final rec = RecordingTransport();
    await buildDispatcher(rec).printBill(
      items: [PrintItem.fromCartLine(lines().single)],
      receiptId: 'NSTAR-POS1-20260928-14:07-0000003',
      flow: flow(), split: split(), tableName: 'A1',
      reprint: true, // reprint never passes openDrawer
    );
    expect(rec.jobs.single.entries.any((e) => e.kind == PrintableKind.pulse), isFalse);
  });
}

int _indexOfSeq(List<int> hay, List<int> needle) {
  for (var i = 0; i + needle.length <= hay.length; i++) {
    var ok = true;
    for (var j = 0; j < needle.length; j++) {
      if (hay[i + j] != needle[j]) { ok = false; break; }
    }
    if (ok) return i;
  }
  return -1;
}
