import 'package:flutter_test/flutter_test.dart';
import 'package:gundam_pos/logic/cart.dart';
import 'package:gundam_pos/logic/money.dart' as money;

void main() {
  group('CartLine pricing (server lineUnitPrice mirror)', () {
    test('unit price with paid modifier adds to the base', () {
      final line = CartLine(
        itemId: 'i1',
        name: 'Latte',
        sku: 'SKU',
        qty: 1,
        priceLevelIndex: 0,
        unitPrice: 25000,
        modifiers: [CartModifier(modifierId: 'm1', name: 'Extra shot', price: 5000)],
      );
      expect(line.unitPriceWithMods, 30000);
      expect(line.lineSubtotal, 30000);
    });

    test('quantity multiplies the modifier-inclusive price', () {
      final line = CartLine(
        itemId: 'i1',
        name: 'Latte',
        sku: 'S',
        qty: 3,
        priceLevelIndex: 0,
        unitPrice: 20000,
        modifiers: [CartModifier(modifierId: 'm1', name: 'Soy', price: 2000)],
      );
      expect(line.unitPriceWithMods, 22000);
      expect(line.lineSubtotal, 66000);
    });

    test('open-mod text costs 0', () {
      final line = CartLine(
        itemId: 'i1',
        name: 'Coffee',
        sku: 'S',
        qty: 1,
        priceLevelIndex: 0,
        unitPrice: 10000,
        modifiers: [CartModifier(name: 'Less sugar', openText: 'Less sugar', price: 0)],
      );
      expect(line.unitPriceWithMods, 10000);
    });
  });

  group('Cart merge + remove', () {
    test('identical picks merge quantities', () {
      final cart = Cart();
      cart.addLine(_line('i1', 1));
      cart.addLine(_line('i1', 1));
      expect(cart.lines, hasLength(1));
      expect(cart.lines.single.qty, 2);
      expect(cart.itemCount, 2);
    });

    test('different price level or modifiers do not merge', () {
      final cart = Cart();
      cart.addLine(_line('i1', 1, level: 0));
      cart.addLine(_line('i1', 1, level: 1));
      cart.addLine(_line('i1', 1, level: 0, mod: 'x'));
      expect(cart.lines, hasLength(3));
    });

    test('remove unsent line decrements and drops at zero', () {
      final cart = Cart();
      cart.addLine(_line('i1', 1));
      cart.addLine(_line('i2', 1));
      cart.removeLine(cart.lines.first, qty: 1);
      expect(cart.lines, hasLength(1));
    });

    test('sent line resists removal', () {
      final cart = Cart();
      final line = _line('i1', 1, sent: true);
      cart.addLine(line);
      expect(() => cart.removeLine(line), throwsA(isA<CartError>()));
    });
  });

  group('money rounding helper', () {
    test('round2 rounds to cents', () {
      expect(money.round2(1.005), 1.0);
      expect(money.round2(1.034), 1.03);
    });
  });

  group('offline sync flags default off (legacy lines unchanged)', () {
    test('a plain line is not pending/failed and has no localKey', () {
      final line = _line('i1', 1);
      expect(line.pending, isFalse);
      expect(line.failed, isFalse);
      expect(line.localKey, isNull);
      expect(line.unitPriceWithMods, 10000);
    });
  });
}

CartLine _line(String id, int qty, {int level = 0, String? mod, bool sent = false}) => CartLine(
      itemId: id,
      name: 'Item $id',
      sku: 'SKU-$id',
      qty: qty,
      priceLevelIndex: level,
      unitPrice: 10000,
      sent: sent,
      modifiers: mod == null ? const [] : [CartModifier(modifierId: mod, name: mod, price: 1000)],
    );