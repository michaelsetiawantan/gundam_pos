import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:gundam_pos/logic/discount_voucher.dart' as dv;
import 'package:gundam_pos/logic/money.dart' as money;
import 'package:gundam_pos/models/config_models.dart';
import 'package:gundam_pos/state/payment_controller.dart';
import 'package:gundam_pos/ui/payment_success_screen.dart';
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
      builder: (_) => _AmountSheet(method: method, maxSuggested: c.remaining),
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
          content: Text('${c.tipsPending.toStringAsFixed(0)} will be recorded as a pending tip. Continue?'),
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
    // Success → receipt; close the order stack back to Open Tables.
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PaymentSuccessScreen(
        receiptId: c.receiptId ?? '',
        total: c.settled?['total'] ?? c.payable,
        change: ((c.settled?['change'] ?? c.change) as num).toDouble(),
        tipsPending: ((c.settled?['tipsPending'] ?? c.tipsPending) as num).toDouble(),
      ),
    ));
    if (!mounted) return;
    Navigator.of(context).popUntil((r) => r.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Payment — ${c.tableName ?? 'order'}')),
      body: SafeArea(
        child: ListenableBuilder(
          listenable: c,
          builder: (_, __) => ListView(
            padding: const EdgeInsets.all(20),
            children: [
              _TotalCard(controller: c),
              const SizedBox(height: 16),
              _PricingPanel(controller: c),
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
      bottomNavigationBar: c.covered
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
    if (ch > 0) return '· change ${ch.toStringAsFixed(0)}';
    if (c.tipsPending > 0) return '· tip pending';
    return '';
  }
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

  static String _fmt(double v) => v == v.roundToDouble() ? '${v.toInt()}' : v.toStringAsFixed(2);
}

/// Inline discount / voucher panel. Offers the eligible masters for the cart
/// (category-inherited), enforces one-per-bill, and can cancel the applied one.
class _PricingPanel extends StatelessWidget {
  const _PricingPanel({required this.controller});
  final PaymentController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final dm = c.appliedDiscount;
    final vm = c.appliedVoucher;
    final discounts = c.availableDiscounts;
    final vouchers = c.availableVouchers;
    if (dm == null && vm == null && discounts.isEmpty && vouchers.isEmpty && !c.pricingPending) {
      return const SizedBox.shrink();
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: PosTheme.line),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Discount / Voucher', style: TextStyle(fontWeight: FontWeight.w700, color: PosTheme.petrol, fontSize: 15)),
        const SizedBox(height: 10),
        if (c.pricingPending)
          const Padding(
            padding: EdgeInsets.only(bottom: 10),
            child: Row(children: [
              Icon(Icons.hourglass_top, size: 18, color: PosTheme.slate),
              SizedBox(width: 8),
              Expanded(
                child: Text('Awaiting approval — no discount applied yet.',
                    style: TextStyle(fontWeight: FontWeight.w700, color: PosTheme.slate)),
              ),
            ]),
          ),
        if (dm != null || vm != null)
          Row(children: [
            Expanded(
              child: Text(
                dm != null ? 'Discount: ${dm.name}' : 'Voucher: ${vm!.name}',
                style: const TextStyle(fontWeight: FontWeight.w700, color: PosTheme.ink),
              ),
            ),
            Text('− ${_fmt(c.discountAmount)}', style: const TextStyle(fontWeight: FontWeight.w700, color: PosTheme.ok)),
            const SizedBox(width: 8),
            IconButton(
              tooltip: 'Cancel discount/voucher',
              onPressed: c.pricingBusy ? null : () => _run(context, c, c.cancelPricing),
              icon: const Icon(Icons.close, color: PosTheme.danger),
            ),
          ])
        else if (!c.pricingPending) ...[
          if (discounts.isNotEmpty) ...[
            const Text('Discounts', style: TextStyle(color: PosTheme.slate, fontSize: 13)),
            const SizedBox(height: 6),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final d in discounts)
                ActionChip(
                  label: Text('${d.name} (${_label(d)})'),
                  onPressed: c.pricingBusy ? null : () => _run(context, c, () => c.applyDiscount(d)),
                ),
            ]),
            const SizedBox(height: 10),
          ],
          if (vouchers.isNotEmpty) ...[
            const Text('Vouchers', style: TextStyle(color: PosTheme.slate, fontSize: 13)),
            const SizedBox(height: 6),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final v in vouchers)
                ActionChip(
                  label: Text('${v.name} (${_label(v)})'),
                  onPressed: c.pricingBusy ? null : () => _run(context, c, () => c.applyVoucher(v)),
                ),
            ]),
          ],
        ],
      ]),
    );
  }

  /// Runs a server-backed pricing action; surfaces a readable message on failure.
  static Future<void> _run(BuildContext context, PaymentController c, Future<bool> Function() action) async {
    final ok = await action();
    if (!context.mounted || ok) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(c.error ?? 'Could not change the discount/voucher.')),
    );
  }

  static String _label(dv.PricingMaster m) =>
      m.kind == dv.PricingKind.percentage ? '${_fmt(m.value)}%' : _fmt(m.value);
  static String _fmt(double v) => v == v.roundToDouble() ? '${v.toInt()}' : v.toStringAsFixed(2);
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

  static String _fmt(double v) => v == v.roundToDouble() ? '${v.toInt()}' : v.toStringAsFixed(2);
}

class _AmountSheet extends StatefulWidget {
  const _AmountSheet({required this.method, required this.maxSuggested});
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
    _amount.text = widget.maxSuggested > 0 ? '${widget.maxSuggested.round()}' : '';
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
              controller: _amount,
              autofocus: true,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800),
              decoration: const InputDecoration(prefixText: 'Rp '),
            ),
            const SizedBox(height: 20),
            PrimaryButton(
              label: 'Add payment',
              onPressed: () => Navigator.pop(context, double.tryParse(_amount.text.trim()) ?? 0),
            ),
          ]),
        ),
      ),
    );
  }
}