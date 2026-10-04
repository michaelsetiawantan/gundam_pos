import 'package:flutter_test/flutter_test.dart';
import 'package:gundam_pos/logic/cart.dart';
import 'package:gundam_pos/logic/print_format.dart';
import 'package:gundam_pos/logic/print_format_render.dart';
import 'package:gundam_pos/logic/print_payload.dart';
import 'package:gundam_pos/models/config_models.dart';
import 'package:gundam_pos/state/order_controller.dart';
import 'package:gundam_pos/state/session_store.dart';

import 'support/fake_backend.dart';

/// Field reports: identical picks stayed as separate cart rows AND separate
/// printed rows; and the money column on paper was not straight.
void main() {
  TenantConfig config() =>
      TenantConfig.fromSyncPayloads(FakeBackend.northstarMaster(), FakeBackend.northstarOutlet());

  Future<(FakeBackend, OrderController)> ready() async {
    final backend = FakeBackend();
    final store = InMemorySessionStore();
    await store.save(const PosContext()
        .withRedeem({'deviceToken': 'dev', 'groupId': 'g1', 'tenantId': 't1', 'shortcode': 'NSTAR-POS1'})
        .withSession({
          'sessionId': 'sess-1',
          'user': {'id': 'u1', 'fullName': 'C1'},
          'outlet': {'id': 't1', 'name': 'Northstar'},
        })
        .copyWith(deviceId: 'device-1'));
    final session = backend.createSession(store: store);
    await session.init();
    // The production wiring: a push store means the OFFLINE-FIRST add path (the
    // one that merges) is the one under test.
    final c = OrderController(
      posApi: session.posApi, tenantId: 't1', config: config(), deviceAssetId: 'device-1',
      pushStore: session.pushStore,
    );
    await c.startOrder(tableId: 'tbl-a1', tableName: 'A1');
    return (backend, c);
  }

  group('the cart merges identical picks (qty summed)', () {
    test('same item + same modifiers → ONE row, qty 2', () async {
      final (_, c) = await ready();
      final item = c.config.itemById('item-espresso')!;
      final mod = CartModifier(modifierId: 'mod-oat', name: 'Oat milk', price: 5000);
      await c.addItem(item, mods: [mod]);
      await c.addItem(item, mods: [mod]);
      expect(c.cart.lines, hasLength(1), reason: 'identical picks must merge');
      expect(c.cart.lines.single.qty, 2);
    });

    test('a different modifier set stays a SECOND line', () async {
      final (_, c) = await ready();
      final item = c.config.itemById('item-espresso')!;
      await c.addItem(item, mods: [CartModifier(modifierId: 'mod-oat', name: 'Oat milk', price: 5000)]);
      await c.addItem(item); // plain — different signature
      expect(c.cart.lines, hasLength(2));
    });

    test('a line already sent to the kitchen is never merged into', () async {
      final (_, c) = await ready();
      final item = c.config.itemById('item-espresso')!;
      await c.addItem(item);
      c.cart.lines.single.sent = true; // already on the kitchen ticket
      await c.addItem(item);
      expect(c.cart.lines, hasLength(2), reason: 'the sent line must stay untouched');
    });
  });

  group('printed rows merge identical picks (qty summed)', () {
    PrintItem it(String id, int qty, {int batch = 0, List<PrintModifier> mods = const [], double price = 1000}) =>
        PrintItem(name: id, itemId: id, qty: qty, unitPrice: price, lineTotal: price * qty,
            batchIndex: batch, modifiers: mods);

    test('same item + modifiers in one batch → one row with the summed qty', () {
      final merged = mergePrintItems([it('espresso', 1), it('espresso', 2), it('nasi', 1)]);
      expect(merged, hasLength(2));
      expect(merged.first.qty, 3);
      expect(merged.first.lineTotal, 3000);
    });

    test('different modifiers are NOT merged; different batches stay separate', () {
      final withMod = mergePrintItems([
        it('espresso', 1, mods: [PrintModifier(name: 'Oat', price: 5000)]),
        it('espresso', 1),
      ]);
      expect(withMod, hasLength(2), reason: 'plain vs modified are different lines');

      final twoBatches = mergePrintItems([it('espresso', 1, batch: 0), it('espresso', 1, batch: 1)]);
      expect(twoBatches, hasLength(2), reason: 'a captain ticket still breaks down per batch');
    });

    test('the rendered bill shows the merged qty ONCE', () {
      final fmt = PrintFormat.fromJson({
        'ticketType': 'BILL', 'widthMm': 80,
        'blocks': [
          {'id': 'a', 'type': 'ITEM_LIST', 'columns': 'NAME_QTY_PRICE'},
        ],
      });
      final out = renderPrintFormat(
        format: fmt,
        ticketPayload: {
          'tokens': {'currency_label': 'Rp'},
          'items': [
            for (final i in mergePrintItems([it('Espresso', 1), it('Espresso', 1)]))
              i.toJson(),
          ],
          'payments': <Object>[],
        },
        widthMm: 80,
      );
      expect(out.lines, hasLength(1), reason: 'one row on paper, not two');
      expect(out.lines.single, contains('2'));
    });
  });

  group('money rows keep the currency in ONE column', () {
    test('every currency label starts at the same index, whatever the amount', () {
      final fmt = PrintFormat.fromJson({
        'ticketType': 'BILL', 'widthMm': 80,
        'blocks': [
          {'id': 'c', 'type': 'MONEY_LINES', 'lines': ['SUBTOTAL', 'DISCOUNT', 'VAT', 'TOTAL']},
        ],
      });
      final out = renderPrintFormat(
        format: fmt,
        ticketPayload: {
          'tokens': {
            'currency_label': 'Rp', 'discount_name': 'HAPPY',
            'subtotal': 1000, 'discount_amount': 95, 'vat_amount': 100, 'total': 1234567,
          },
          'items': <Object>[], 'payments': <Object>[],
        },
        widthMm: 80,
      );
      expect(out.lines, hasLength(4));
      final at = [for (final l in out.lines) l.indexOf('Rp')];
      expect(at.toSet(), hasLength(1),
          reason: 'the currency must sit in ONE column (got $at)');
      // …and every amount ends at the same right edge.
      final ends = [for (final l in out.lines) l.length];
      expect(ends.toSet(), hasLength(1), reason: 'rows are the full paper width');
    });
  });
}
