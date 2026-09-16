import 'package:flutter_test/flutter_test.dart';
import 'package:gundam_pos/logic/receipt.dart';

void main() {
  group('makeReceiptId', () {
    test('matches server RECEIPT_RE exactly once', () {
      final at = DateTime(2026, 9, 17, 14, 5);
      final id = makeReceiptId(shortcode: 'NSTAR-POS1', at: at, seq: 1);
      expect(id, 'NSTAR-POS1-20260917-14:05-0000001');
      expect(isValidReceiptId(id), isTrue);
      expect(receiptRe.allMatches(id), hasLength(1));
    });
  });

  group('isValidReceiptId', () {
    test('accepts a generated id', () {
      expect(isValidReceiptId('NSTAR-POS1-20260917-14:05-0000001'), isTrue);
    });

    test('rejects malformed ids', () {
      expect(isValidReceiptId('NSTAR-POS1-20260917-1405-0000001'), isFalse); // no colon
      expect(isValidReceiptId('NSTAR-POS1-20260917-14:05-000001'), isFalse); // seq too short
      expect(isValidReceiptId(''), isFalse);
      expect(isValidReceiptId('a b c'), isFalse);
    });
  });

  group('dateStamp', () {
    test('pads to YYYYMMDD', () {
      expect(dateStamp(DateTime(2026, 1, 2, 0, 0)), '20260102');
    });
  });
}