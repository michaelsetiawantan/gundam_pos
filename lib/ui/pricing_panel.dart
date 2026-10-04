import 'package:flutter/material.dart';

import 'package:gundam_pos/logic/discount_voucher.dart' as dv;
import 'package:gundam_pos/logic/money.dart' as money;
import 'package:gundam_pos/state/pricing_controller.dart';
import 'package:gundam_pos/ui/theme.dart';

/// Inline discount / voucher panel, driven by a [PricingController]. Offers the
/// eligible masters for the cart (category-inherited), enforces one-per-bill,
/// and can cancel the applied one. Shared by order entry and payment so the two
/// screens can never disagree about the bill's discount.
class PricingPanel extends StatelessWidget {
  const PricingPanel({super.key, required this.controller, this.currency = ''});

  final PricingController controller;

  /// Outlet currency label from the server config (display only).
  final String currency;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final dm = c.selection.discount;
    final vm = c.selection.voucher;
    final discounts = c.availableDiscounts;
    final vouchers = c.availableVouchers;
    if (dm == null && vm == null && discounts.isEmpty && vouchers.isEmpty && !c.pending) {
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
        if (c.pending)
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
            Text('− ${_fmt(_amount(c))}', style: const TextStyle(fontWeight: FontWeight.w700, color: PosTheme.ok)),
            const SizedBox(width: 8),
            IconButton(
              tooltip: 'Cancel discount/voucher',
              onPressed: c.busy ? null : () => _run(context, c, c.cancelPricing),
              icon: const Icon(Icons.close, color: PosTheme.danger),
            ),
          ])
        else if (!c.pending) ...[
          if (discounts.isNotEmpty) ...[
            const Text('Discounts', style: TextStyle(color: PosTheme.slate, fontSize: 13)),
            const SizedBox(height: 6),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final d in discounts)
                ActionChip(
                  label: Text('${d.name} (${_label(d)})'),
                  onPressed: c.busy ? null : () => _run(context, c, () => c.applyDiscount(d)),
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
                  onPressed: c.busy ? null : () => _run(context, c, () => c.applyVoucher(v)),
                ),
            ]),
          ],
        ],
      ]),
    );
  }

  /// Applied amount for the current pre-tax subtotal (rounded for display only).
  static double _amount(PricingController c) => money.round2(c.amountFor(c.cart.total));

  /// Runs a server-backed pricing action; surfaces a readable message on failure.
  static Future<void> _run(BuildContext context, PricingController c, Future<bool> Function() action) async {
    final ok = await action();
    if (!context.mounted || ok) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(c.error ?? 'Could not change the discount/voucher.')),
    );
  }

  String _label(dv.PricingMaster m) =>
      m.kind == dv.PricingKind.percentage ? '${_fmt(m.value)}%' : _fmt(m.value);
  String _fmt(double v) => money.moneyLabel(v, currency);
}
