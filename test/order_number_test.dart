import 'package:flutter_test/flutter_test.dart';
import 'package:gundam_pos/data/pos_store.dart';
import 'package:gundam_pos/logic/order_number.dart';

void main() {
  group('makeOrderNumber', () {
    test('embeds shortcode + YYYYMMDD + HHMM + 6-digit seq', () {
      final id = makeOrderNumber(
        shortcode: 'NSTAR-POS1',
        at: DateTime(2026, 10, 3, 14, 30),
        seq: 7,
      );
      expect(id, 'NSTAR-POS1-20261003-1430-000007');
      expect(isValidClientOrderId(id), isTrue);
    });

    test('matches the server-side shape guard', () {
      final id = makeOrderNumber(shortcode: 'ABC', at: DateTime(2026, 1, 1, 0, 0), seq: 999999);
      expect(clientOrderIdRe.hasMatch(id), isTrue);
      expect(id.length, lessThanOrEqualTo(64));
    });
  });

  group('OrderNumberGenerator', () {
    test('is monotonic and unique within one device', () async {
      final g = OrderNumberGenerator(
        store: MemoryReceiptSequenceStore(),
        now: () => DateTime(2026, 10, 3, 14, 30),
      );
      final ids = <String>[for (var i = 0; i < 50; i++) await g.next('NSTAR-POS1')];

      expect(ids.toSet(), hasLength(50), reason: 'no two orders share an id');
      for (final id in ids) {
        expect(isValidClientOrderId(id), isTrue);
      }
      for (var i = 1; i < ids.length; i++) {
        expect(ids[i].compareTo(ids[i - 1]), greaterThan(0),
            reason: 'order numbers are strictly increasing (zero-padded seq)');
      }
    });

    test('two POS devices can never collide (shortcode is in the id)', () async {
      final now = () => DateTime(2026, 10, 3, 14, 30);
      final a = OrderNumberGenerator(store: MemoryReceiptSequenceStore(), now: now);
      final b = OrderNumberGenerator(store: MemoryReceiptSequenceStore(), now: now);

      final idsA = <String>[for (var i = 0; i < 20; i++) await a.next('NSTAR-POS1')];
      final idsB = <String>[for (var i = 0; i < 20; i++) await b.next('NSTAR-POS2')];

      expect(idsA.toSet().intersection(idsB.toSet()), isEmpty);
    });
  });
}
