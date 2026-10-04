import 'package:flutter/material.dart';

import 'package:gundam_pos/logic/money.dart' as money;
import 'package:gundam_pos/models/config_models.dart';
import 'package:gundam_pos/state/payment_controller.dart';
import 'package:gundam_pos/ui/money_input.dart';
import 'package:gundam_pos/ui/payment_success_screen.dart';
import 'package:gundam_pos/ui/pricing_panel.dart';
import 'package:gundam_pos/ui/theme.dart';
import 'package:gundam_pos/ui/widgets.dart';

/// P16/P17/P18 — Payment & split. Outlet-active methods from config; allocate
/// against the fixed payable (rounded once, never re-rounded). Cash overpay →
/// change; non-cash overpay → confirm pending-tip before settle.
class PaymentScreen extends StatefulWidget {
  const PaymentScreen({super.key, required this.controller});

  final PaymentController controller;

  @override
  State<PaymentScreen> createState() => _PaymentScreenState();
}

class _PaymentScreenState extends State<PaymentScreen> {
  PaymentController get c => widget.controller;

  Future<void> _add(OutletPaymentMethod method) async {
    final amount = await showModalBottomSheet<double>(
      context: context,
      builder: (_) => _AmountSheet(
        method: method, maxSuggested: c.remaining, currency: c.config.shift.currencyLabel),
    );
    if (amount == null || amount <= 0 || !mounted) return;
    setState(() => c.addPayment(method, amount));
  }

  Future<void> _settle() async {
    // Non-cash overpay becomes a pending tip — confirm before settling.
    if (c.hasNonCashOverpay) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Overpayment'),
          content: Text('${_fmt(c.tipsPending)} will be recorded as a pending tip. Continue?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Continue')),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }

    final done = await c.settle();
    if (!mounted) return;
    if (!done) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(c.error ?? 'Settlement failed')));
      return;
    }
    // A print warning never blocks the sale — mention it, then still show the
    // receipt (the operator must never be left without proof of payment).
    if (c.printAlerts.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(c.printAlerts.first)));
    }
    // Success → receipt; close the order stack back to Open Tables. The bill is
    // parsed defensively (a Decimal can arrive as a string) and the push is the
    // ONLY thing between a paid bill and the operator seeing it — a throw here
    // used to swallow the success page while the server had already settled.
    final bill = c.settled;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PaymentSuccessScreen(
        receiptId: c.receiptId ?? '',
        total: bill?['total'] ?? c.payable,
        change: _num(bill?['change'] ?? c.change),
        tipsPending: _num(bill?['tipsPending'] ?? c.tipsPending),
        currency: c.config.shift.currencyLabel,
      ),
    ));
    if (!mounted) return;
    Navigator.of(context).popUntil((r) => r.isFirst);
  }

  /// Server Decimals may serialise as numbers OR strings — accept both.
  static double _num(Object? v) {
    if (v is num) return v.toDouble();
    return double.tryParse('${v ?? ''}') ?? 0;
  }

  @override
  Widget build(BuildContext context) {
    // The gate's verdict on THIS payment, consulted up front so the button and
    // the settle behaviour agree (a blocked settle can never be pressed).
    final block = c.paymentBlock;
    return Scaffold(
      appBar: AppBar(title: Text('Payment — ${c.tableName ?? 'order'}')),
      body: SafeArea(
        child: ListenableBuilder(
          listenable: c,
          builder: (_, __) => ListView(
            padding: const EdgeInsets.all(20),
            children: [
              if (block != null) ...[
                ErrorBanner(message: block, key: const Key('payment-gate-reason')),
                const SizedBox(height: 16),
              ],
              _TotalCard(controller: c),
              const SizedBox(height: 16),
              PricingPanel(controller: c.pricingController, currency: c.config.shift.currencyLabel),
              const SizedBox(height: 16),
              _ShipmentPanel(controller: c),
              const SizedBox(height: 16),
              if (c.payments.isNotEmpty) _PaymentsList(controller: c),
              const SizedBox(height: 16),
              const Text('Payment methods', style: TextStyle(fontWeight: FontWeight.w700, color: PosTheme.petrol, fontSize: 15)),
              const SizedBox(height: 10),
              Wrap(spacing: 10, runSpacing: 10, children: [
                for (final m in c.config.paymentMethods)
                  SizedBox(
                    width: 150,
                    child: OutlinedButton(
                      onPressed: () => _add(m),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 18),
                        side: BorderSide(color: m.type == money.PayType.cash ? PosTheme.petrol : PosTheme.teal, width: 1.5),
                      ),
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        Icon(m.type == money.PayType.cash ? Icons.payments : Icons.credit_card, color: PosTheme.petrol),
                        const SizedBox(height: 6),
                        Text(m.displayName, style: const TextStyle(fontSize: 14)),
                      ]),
                    ),
                  ),
              ]),
            ],
          ),
        ),
      ),
      bottomNavigationBar: c.covered && block == null
          ? SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: PrimaryButton(
                  label: 'Settle $balanceLabel',
                  busy: c.settling,
                  icon: Icons.check_circle_outline,
                  onPressed: c.settling ? null : _settle,
                ),
              ),
            )
          : null,
    );
  }

  String get balanceLabel {
    final ch = c.change;
    if (ch > 0) return '· change ${_fmt(ch)}';
    if (c.tipsPending > 0) return '· tip pending';
    return '';
  }
  String _fmt(double v) => money.moneyLabel(v, c.config.shift.currencyLabel);
}

class _TotalCard extends StatelessWidget {
  const _TotalCard({required this.controller});
  final PaymentController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(colors: [PosTheme.petrol, PosTheme.petrolDark]),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Payable', style: TextStyle(color: PosTheme.tealSoft, fontSize: 13)),
        Text(_fmt(c.payable), style: const TextStyle(color: Colors.white, fontSize: 30, fontWeight: FontWeight.w800)),
        const SizedBox(height: 12),
        if (c.discountAmount > 0)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text('Discount − ${_fmt(c.discountAmount)}', style: const TextStyle(color: PosTheme.tealSoft, fontWeight: FontWeight.w700)),
          ),
        if (c.shipmentAmount > 0)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text('Shipment + ${_fmt(c.shipmentAmount)}${c.shipment?.isMaster == true ? ' (${c.shipment!.description})' : ''}',
                style: const TextStyle(color: PosTheme.tealSoft, fontWeight: FontWeight.w700)),
          ),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text('Paid ${_fmt(c.paid)}', style: const TextStyle(color: PosTheme.tealSoft)),
          Text(c.covered ? 'Covered ✓' : 'Remaining ${_fmt(c.remaining)}',
              style: TextStyle(
                  color: c.covered ? PosTheme.tealSoft : Colors.white,
                  fontWeight: FontWeight.w700)),
        ]),
        if (c.change > 0)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text('Cash change: ${_fmt(c.change)}', style: const TextStyle(color: PosTheme.tealSoft, fontWeight: FontWeight.w700)),
          ),
      ]),
    );
  }

  String _fmt(double v) => money.moneyLabel(v, controller.config.shift.currencyLabel);
}

/// Shipment step — a SEPARATE revenue line (outside discount/voucher, VAT, SC;
/// added after SC and before rounding). The cashier types an OPEN amount (0 or
/// empty = no line; non-numeric/negative rejected) and, when the server has
/// actually shipped masters in config, may pick one (precise amount). Settable
/// before payment; cancellable until settle.
class _ShipmentPanel extends StatefulWidget {
  const _ShipmentPanel({required this.controller});
  final PaymentController controller;

  @override
  State<_ShipmentPanel> createState() => _ShipmentPanelState();
}

class _ShipmentPanelState extends State<_ShipmentPanel> {
  final _amount = TextEditingController();
  PaymentController get c => widget.controller;

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  void _addOpen() {
    // Strip the display grouping: the value must stay a plain number.
    final ok = c.setOpenShipment(_amount.text.replaceAll(kThousandsSeparator, ''));
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(c.error ?? 'Invalid shipment amount.')),
      );
      return;
    }
    setState(_amount.clear);
  }

  @override
  Widget build(BuildContext context) {
    final ship = c.shipment;
    final masters = c.config.shipmentMasters;
    final currency = c.config.shift.currencyLabel;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: PosTheme.line),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Shipment', style: TextStyle(fontWeight: FontWeight.w700, color: PosTheme.petrol, fontSize: 15)),
        const SizedBox(height: 10),
        if (ship != null)
          Row(children: [
            Expanded(
              child: Text(
                ship.isMaster ? 'Master: ${ship.masterName}' : 'Open shipment',
                style: const TextStyle(fontWeight: FontWeight.w700, color: PosTheme.ink),
              ),
            ),
            Text('+ ${_fmt(ship.amount)}', style: const TextStyle(fontWeight: FontWeight.w700, color: PosTheme.ok)),
            const SizedBox(width: 8),
            IconButton(
              tooltip: 'Cancel shipment',
              onPressed: c.cancelShipment,
              icon: const Icon(Icons.close, color: PosTheme.danger),
            ),
          ])
        else ...[
          Row(children: [
            Expanded(
              child: TextField(
                key: const Key('shipment-amount'),
                controller: _amount,
                keyboardType: TextInputType.number,
                inputFormatters: const [ThousandsInputFormatter()],
                decoration: InputDecoration(
                  isDense: true,
                  hintText: '0',
                  prefixText: currency.isEmpty ? null : '$currency ',
                  labelText: 'Open shipment amount',
                ),
              ),
            ),
            const SizedBox(width: 10),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: PosTheme.teal, foregroundColor: PosTheme.ink),
              onPressed: _addOpen,
              child: const Text('Add'),
            ),
          ]),
          const SizedBox(height: 6),
          const Text('Amounts of 0 (or empty) mean no shipment line.',
              style: TextStyle(color: PosTheme.slate, fontSize: 12)),
          const SizedBox(height: 10),
          if (masters.isEmpty)
            const Row(children: [
              Icon(Icons.block, size: 16, color: PosTheme.slate),
              SizedBox(width: 6),
              Expanded(
                child: Text(kShipmentMastersUnavailable,
                    key: Key('shipment-master-unavailable'),
                    style: TextStyle(color: PosTheme.slate, fontSize: 12)),
              ),
            ])
          else
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final m in masters)
                ActionChip(
                  label: Text('${m.name} (${_fmt(m.amount)})'),
                  onPressed: () => c.setMasterShipment(m),
                ),
            ]),
        ],
      ]),
    );
  }

  String _fmt(double v) => money.moneyLabel(v, c.config.shift.currencyLabel);
}

class _PaymentsList extends StatelessWidget {
  const _PaymentsList({required this.controller});
  final PaymentController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Split', style: TextStyle(fontWeight: FontWeight.w700, color: PosTheme.petrol, fontSize: 15)),
      const SizedBox(height: 6),
      for (var i = 0; i < c.payments.length; i++)
        ListTile(
          contentPadding: EdgeInsets.zero,
          tileColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          title: Text('${c.payments[i].type == money.PayType.cash ? 'Cash' : 'Card'} #${i + 1}'),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            Text(_fmt(c.payments[i].amount), style: const TextStyle(fontWeight: FontWeight.w700)),
            IconButton(onPressed: () => c.removePayment(i), icon: const Icon(Icons.close, color: PosTheme.danger)),
          ]),
        ),
      const SizedBox(height: 8),
    ]);
  }

  String _fmt(double v) => money.moneyLabel(v, controller.config.shift.currencyLabel);
}

class _AmountSheet extends StatefulWidget {
  const _AmountSheet({required this.method, required this.maxSuggested, required this.currency});

  /// Outlet currency label for the amount dialog prefix.
  final String currency;
  final OutletPaymentMethod method;
  final double maxSuggested;

  @override
  State<_AmountSheet> createState() => _AmountSheetState();
}

class _AmountSheetState extends State<_AmountSheet> {
  final _amount = TextEditingController();

  @override
  void initState() {
    super.initState();
    _amount.text = widget.maxSuggested > 0 ? formatMoneyInput(widget.maxSuggested) : '';
  }

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('${widget.method.displayName} amount', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 16),
            TextField(
              key: const Key('payment-amount'),
              controller: _amount,
              autofocus: true,
              keyboardType: TextInputType.number,
              inputFormatters: const [ThousandsInputFormatter()],
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800),
              decoration: InputDecoration(
                prefixText: widget.currency.trim().isEmpty ? null : '${widget.currency.trim()} ',
              ),
            ),
            const SizedBox(height: 20),
            PrimaryButton(
              label: 'Add payment',
              onPressed: () => Navigator.pop(context, parseMoneyInput(_amount.text)),
            ),
          ]),
        ),
      ),
    );
  }
}