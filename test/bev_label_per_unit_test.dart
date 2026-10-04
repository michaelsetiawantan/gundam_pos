import 'package:flutter_test/flutter_test.dart';
import 'package:gundam_pos/logic/print_payload.dart';

import 'support/print_support.dart';

/// BEV labels are a LABEL PRINTER: one product = one sticker. A line of qty 3
/// prints THREE labels — it must never merge into one label reading "3".
/// Captain sheets, by contrast, merge identical rows (qty summed) within a batch.
void main() {
  test('a beverage line of qty 3 prints THREE labels (one per unit)', () async {
    final rec = RecordingTransport();
    final d = buildDispatcher(rec);

    await d.printSendCart(
      items: [
        PrintItem(name: 'Espresso', itemId: 'item-espresso', qty: 3, unitPrice: 25000, batchIndex: 0),
      ],
      tableName: 'A1',
    );

    final labels = rec.jobs.where((j) => j.ticketType == 'BEV_LABEL').toList();
    expect(labels, hasLength(3), reason: '1 produk = 1 label, bukan digabung');
    for (final l in labels) {
      expect(l.lines.join('\n'), contains('Espresso'));
    }
    // …and the captain sheet for that batch is still ONE job.
    expect(rec.jobs.where((j) => j.ticketType == 'CAPTAIN_ORDER'), hasLength(1));
  });

  test('identical rows merge on the CAPTAIN sheet: one row, summed qty', () async {
    final rec = RecordingTransport();
    final d = buildDispatcher(rec);

    await d.printSendCart(
      items: [
        PrintItem(name: 'Espresso', itemId: 'item-espresso', qty: 1, unitPrice: 25000, batchIndex: 0),
        PrintItem(name: 'Espresso', itemId: 'item-espresso', qty: 2, unitPrice: 25000, batchIndex: 0),
      ],
      tableName: 'A1',
    );

    final cap = rec.jobs.firstWhere((j) => j.ticketType == 'CAPTAIN_ORDER');
    final rows = cap.lines.where((l) => l.contains('Espresso')).toList();
    expect(rows, hasLength(1), reason: 'seller yang sama digabung jadi satu baris');
    expect(rows.single, contains('3'), reason: 'qty dijumlah');
  });

  test('two SEPARATE batches still print their own captain sheet', () async {
    final rec = RecordingTransport();
    final d = buildDispatcher(rec);

    await d.printSendCart(
      items: [
        PrintItem(name: 'Espresso', itemId: 'item-espresso', qty: 1, unitPrice: 25000, batchIndex: 0),
        PrintItem(name: 'Espresso', itemId: 'item-espresso', qty: 1, unitPrice: 25000, batchIndex: 1),
      ],
      tableName: 'A1',
    );

    expect(rec.jobs.where((j) => j.ticketType == 'CAPTAIN_ORDER'), hasLength(2));
  });
}
