import 'package:flutter_test/flutter_test.dart';
import 'package:gundam_pos/logic/print_payload.dart';

// Bill-lifecycle tokens must exist on the DEVICE, not only in the web registry:
// a token the builder offers but the tablet never fills prints blank on paper.
// (cashier_name_closed_bill / datetime_closed_bill are filled by bill() from the
// payer + paid_at; the opener and the table number come from the order.)

TicketContext ctx() => TicketContext(
      storeName: 'WONK CAFE - POP MARKET',
      cashier: 'Rangga',
      tableName: 'T-12',
      tableNumber: '12',
      openedBy: 'Maya',
      closedBy: '',
      closedAt: '',
      vatPercent: '11.000',
      scPercent: '5.000',
    );

void main() {
  test('tokens() carries the four bill-lifecycle tokens', () {
    final t = ctx().tokens();
    expect(t['table_number'], '12');
    expect(t['cashier_name_opened_bill'], 'Maya');
    expect(t['cashier_name_closed_bill'], '');
    expect(t['datetime_closed_bill'], '');
  });

  test('tokens() carries the effective outlet tax rates', () {
    final t = ctx().tokens();
    expect(t['vat_percent'], '11.000');
    expect(t['sc_percent'], '5.000');
  });

  test('the numeric table rule: digits only, blank otherwise', () {
    String derive(String? table) {
      final t = (table ?? '').trim();
      return RegExp(r'^\d+$').hasMatch(t) ? t : '';
    }

    expect(derive('12'), '12');
    expect(derive(' T-12 '), ''); // a labelled table has no number
    expect(derive('Terrace'), '');
    expect(derive(null), '');
  });

  test('copyWith keeps the new fields when a ticket narrows its context', () {
    final narrowed = ctx().copyWith(ticketType: 'CAPTAIN_ORDER');
    final t = narrowed.tokens();
    expect(t['table_number'], '12');
    expect(t['cashier_name_opened_bill'], 'Maya');
    expect(t['vat_percent'], '11.000');
  });
}
