import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gundam_pos/logic/cart.dart';
import 'package:gundam_pos/logic/money.dart' as money;
import 'package:gundam_pos/models/config_models.dart';
import 'package:gundam_pos/state/payment_controller.dart';
import 'package:gundam_pos/ui/payment_screen.dart';
import 'package:gundam_pos/ui/theme.dart';

import 'support/fake_backend.dart';

TenantConfig _northstar() =>
    TenantConfig.fromSyncPayloads(FakeBackend.northstarMaster(), FakeBackend.northstarOutlet());

PaymentController _controller() {
  final config = _northstar();
  final cart = Cart();
  cart.addLine(CartLine(
    itemId: 'item-espresso',
    name: 'Espresso',
    sku: 'S',
    qty: 1,
    priceLevelIndex: 0,
    unitPrice: 25000,
    vatMode: money.VatScMode.exclude,
    scMode: money.VatScMode.none,
  ));
  return PaymentController(
    posApi: FakeBackend().createSession().posApi,
    tenantId: 't1',
    config: config,
    orderId: 'order-1',
    tableName: 'A1',
    cart: cart,
    deviceAssetId: 'device-1',
    shortcode: 'NSTAR-POS1',
  );
}

void main() {
  testWidgets('cash payment → settle → success shows receipt', (tester) async {
    final c = _controller();
    await tester.pumpWidget(MaterialApp(theme: PosTheme.theme(), home: PaymentScreen(controller: c)));
    await tester.pumpAndSettle();

    expect(find.textContaining('Payable'), findsOneWidget);

    // Add cash payment.
    await tester.tap(find.text('Cash'));
    await tester.pumpAndSettle();
    expect(find.text('Cash amount'), findsOneWidget);
    await tester.tap(find.text('Add payment'));
    await tester.pumpAndSettle();

    // Now covered → settle button appears.
    expect(c.covered, isTrue);
    expect(find.textContaining('Settle'), findsWidgets);

    await tester.tap(find.textContaining('Settle'));
    await tester.pumpAndSettle();

    // Success screen.
    expect(find.text('Paid in full'), findsOneWidget);
    expect(find.textContaining('Receipt'), findsOneWidget);
    expect(c.receiptId, startsWith('NSTAR-POS1-'));
  });

  testWidgets('cash overpay shows change on the payment screen', (tester) async {
    final c = _controller();
    await tester.pumpWidget(MaterialApp(theme: PosTheme.theme(), home: PaymentScreen(controller: c)));

    await tester.tap(find.text('Cash'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '40000');
    await tester.tap(find.text('Add payment'));
    await tester.pumpAndSettle();

    expect(c.change, 12000);
    expect(find.textContaining('change'), findsWidgets);
  });
}