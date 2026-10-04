import 'package:flutter_test/flutter_test.dart';
import 'package:gundam_pos/logic/money.dart';
import 'package:gundam_pos/ui/money_input.dart';

/// Money is DISPLAYED with the server's currency label, thousand separators and
/// two decimals — while the value itself stays a plain number.
void main() {
  test('label + grouping + two decimals', () {
    expect(moneyLabel(1000, 'Rp'), 'Rp. 1.000,00');
    expect(moneyLabel(0, 'Rp'), 'Rp. 0,00');
    expect(moneyLabel(1234567, 'Rp'), 'Rp. 1.234.567,00');
    expect(moneyLabel(45000, 'IDR'), 'IDR. 45.000,00');
  });

  test('fractional amounts round to two decimals without drift', () {
    expect(moneyLabel(1000.5, 'Rp'), 'Rp. 1.000,50');
    expect(moneyLabel(1000.05, 'Rp'), 'Rp. 1.000,05');
    expect(moneyLabel(1.999, 'Rp'), 'Rp. 2,00');
    expect(moneyLabel(27450.0, 'Rp'), 'Rp. 27.450,00');
  });

  test('negative and empty labels behave', () {
    expect(moneyLabel(-1500, 'Rp'), '-Rp. 1.500,00');
    expect(moneyLabel(2500, ''), '2.500,00');
    // A label that already carries the dot does not get a second one.
    expect(moneyLabel(2500, 'Rp.'), 'Rp. 2.500,00');
  });

  test('the value is NOT changed by formatting (display only)', () {
    final amount = 1000;
    expect(moneyLabel(amount, 'Rp'), 'Rp. 1.000,00');
    expect(amount, 1000);
    expect(parseMoneyInput('1.000'), 1000, reason: 'parse and display stay inverse');
  });
}
