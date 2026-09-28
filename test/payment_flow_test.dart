import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gundam_pos/logic/cart.dart';
import 'package:gundam_pos/logic/money.dart' as money;
import 'package:gundam_pos/logic/shift_window.dart';
import 'package:gundam_pos/models/config_models.dart';
import 'package:gundam_pos/state/payment_controller.dart';
import 'package:gundam_pos/ui/payment_screen.dart';
import 'package:gundam_pos/ui/theme.dart';

import 'support/fake_backend.dart';

TenantConfig _northstar() =>
    TenantConfig.fromSyncPayloads(FakeBackend.northstarMaster(), FakeBackend.northstarOutlet());

/// AUTOMATIC outlet with a Dinner meal-shift window + a 00:00 recap window.
TenantConfig _autoConfig() {
  final outlet = FakeBackend.northstarOutlet();
  outlet['shift'] = {
    'shiftType': 'AUTOMATIC',
    'defaultHouseBank': '500000',
    'roundingMode': 'UP',
    'mealShiftWindows': [
      {'name': 'Dinner', 'startHour': 18, 'startMinute': 0, 'endHour': 23, 'endMinute': 30, 'enabled': true},
    ],
    'recapWindow': {'startHour': 0, 'startMinute': 0, 'durationMin': 10},
  };
  return TenantConfig.fromSyncPayloads(FakeBackend.northstarMaster(), outlet);
}

PaymentController _controller({FakeBackend? backend}) {
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
    posApi: (backend ?? FakeBackend()).createSession().posApi,
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
    await tester.enterText(find.byKey(const Key('payment-amount')), '40000');
    await tester.tap(find.text('Add payment'));
    await tester.pumpAndSettle();

    expect(c.change, 12000);
    expect(find.textContaining('change'), findsWidgets);
  });

  testWidgets('non-cash overpay is confirmed as a pending tip, then settles', (tester) async {
    final c = _controller();
    await tester.pumpWidget(MaterialApp(theme: PosTheme.theme(), home: PaymentScreen(controller: c)));
    await tester.pumpAndSettle();

    // Visa (non-cash) overpays the 28000 payable by 4000.
    await tester.tap(find.text('Visa'));
    await tester.pumpAndSettle();
    expect(find.text('Visa amount'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('payment-amount')), '32000');
    await tester.tap(find.text('Add payment'));
    await tester.pumpAndSettle();

    // No cash change — the overpay is a pending tip.
    expect(c.covered, isTrue);
    expect(c.change, 0);
    expect(c.tipsPending, 4000);
    expect(c.hasNonCashOverpay, isTrue);

    // Settle must confirm the pending tip first.
    await tester.tap(find.textContaining('Settle'));
    await tester.pumpAndSettle();
    expect(find.text('Overpayment'), findsOneWidget);
    expect(find.textContaining('pending tip'), findsOneWidget);

    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    expect(find.text('Paid in full'), findsOneWidget);
    expect(c.receiptId, startsWith('NSTAR-POS1-'));
  });

  testWidgets('shipment step: open amount joins the payable and is cancellable', (tester) async {
    final c = _controller();
    await tester.pumpWidget(MaterialApp(theme: PosTheme.theme(), home: PaymentScreen(controller: c)));
    await tester.pumpAndSettle();

    expect(find.text('Shipment'), findsOneWidget);
    // Masters are not shipped in config → the master option is unavailable.
    expect(find.byKey(const Key('shipment-master-unavailable')), findsOneWidget);

    await tester.enterText(find.byKey(const Key('shipment-amount')), '5000');
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();

    expect(c.shipmentAmount, 5000);
    expect(c.payable, 33000);
    expect(find.textContaining('Shipment + 5000'), findsWidgets);

    await tester.tap(find.byTooltip('Cancel shipment'));
    await tester.pumpAndSettle();
    expect(c.shipment, isNull);
    expect(c.payable, 28000);
  });

  testWidgets('shipment step rejects a non-numeric / negative amount', (tester) async {
    final c = _controller();
    await tester.pumpWidget(MaterialApp(theme: PosTheme.theme(), home: PaymentScreen(controller: c)));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('shipment-amount')), '-50');
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    expect(c.shipment, isNull);
    expect(c.payable, 28000);

    await tester.enterText(find.byKey(const Key('shipment-amount')), 'abc');
    await tester.pumpAndSettle();
    expect(c.shipment, isNull);
  });

  testWidgets('a blocked shift window disables Settle and shows the reason', (tester) async {
    final config = _autoConfig();
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
    final c = PaymentController(
      posApi: FakeBackend().createSession().posApi,
      tenantId: 't1',
      config: config,
      orderId: 'order-1',
      tableName: 'A1',
      cart: cart,
      deviceAssetId: 'device-1',
      shortcode: 'NSTAR-POS1',
      // Opened before midnight, now inside the recap window.
      openedAt: DateTime(2026, 9, 27, 23, 40),
      shiftGate: ShiftGate(config.shift, now: () => DateTime(2026, 9, 28, 0, 5)),
    );
    c.addPayment(config.paymentMethods.firstWhere((m) => m.type == money.PayType.cash), 1000000);
    expect(c.covered, isTrue);

    await tester.pumpWidget(MaterialApp(theme: PosTheme.theme(), home: PaymentScreen(controller: c)));
    await tester.pumpAndSettle();

    // Covered, but the gate blocks: no Settle button, the reason is shown.
    expect(find.textContaining('Settle'), findsNothing);
    expect(find.byKey(const Key('payment-gate-reason')), findsOneWidget);
    expect(find.textContaining('NOT be counted as yesterday'), findsOneWidget);
    expect(find.textContaining('recap window'), findsOneWidget);
  });
}