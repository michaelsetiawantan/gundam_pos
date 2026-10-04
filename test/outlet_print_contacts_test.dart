import 'package:flutter_test/flutter_test.dart';
import 'package:gundam_pos/logic/cart.dart';
import 'package:gundam_pos/logic/print_format.dart';
import 'package:gundam_pos/logic/print_format_render.dart';
import 'package:gundam_pos/logic/print_payload.dart';
import 'package:gundam_pos/models/config_models.dart';
import 'package:gundam_pos/ui/bill_preview_screen.dart';

import 'support/fake_backend.dart';

/// The outlet's Instagram / TikTok / email are print variables. They ship in the
/// OUTLET config domain and must resolve on the tablet — both in the BILL preview
/// payload and in the printed ticket.
void main() {
  test('outlet Instagram/TikTok/email resolve as print tokens for a BILL', () {
    final config = TenantConfig.fromSyncPayloads(
      FakeBackend.northstarMaster(),
      FakeBackend.northstarOutlet(),
    );
    expect(config.outlet.instagram, '@northstar.id');
    expect(config.outlet.tiktok, '@northstar');
    expect(config.outlet.email, 'hello@northstar.id');

    final o = config.outlet;
    final payload = buildBillPreviewPayload(
      cart: Cart(),
      config: config,
      storeName: o.name,
      storeAddress: o.address,
      storePhone: o.phone,
      storeInstagram: o.instagram,
      storeTiktok: o.tiktok,
      storeEmail: o.email,
      cashier: 'Cashier One',
      tableName: 'A1',
    );

    final tokens = payload['tokens'] as Map<String, dynamic>;
    expect(tokens['store_instagram'], '@northstar.id');
    expect(tokens['store_tiktok'], '@northstar');
    expect(tokens['store_email'], 'hello@northstar.id');

    // …and they actually hit the paper when the format references them.
    final fmt = PrintFormat.fromJson({
      'formatId': 'f-contacts',
      'name': 'With contacts',
      'ticketType': 'BILL',
      'version': 1,
      'widthMm': 80,
      'blocks': [
        {'id': 'a', 'type': 'VAR', 'param': '{store_instagram}', 'align': 'CENTER'},
        {'id': 'b', 'type': 'VAR', 'param': '{store_tiktok}', 'align': 'CENTER'},
        {'id': 'c', 'type': 'VAR', 'param': '{store_email}', 'align': 'CENTER'},
      ],
    });
    final text = renderPrintFormat(format: fmt, ticketPayload: payload, widthMm: 80).lines.join('\n');
    expect(text, contains('@northstar.id'));
    expect(text, contains('@northstar'));
    expect(text, contains('hello@northstar.id'));
  });
}
