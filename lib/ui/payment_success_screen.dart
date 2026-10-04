import 'package:flutter/material.dart';

import 'package:gundam_pos/logic/money.dart' as money;
import 'package:gundam_pos/ui/theme.dart';

/// P19 — Payment success.
class PaymentSuccessScreen extends StatelessWidget {
  const PaymentSuccessScreen({
    super.key,
    required this.receiptId,
    required this.total,
    this.change = 0,
    this.tipsPending = 0,
    this.currency = '',
  });

  final String receiptId;
  final dynamic total;
  final double change;
  final double tipsPending;

  /// Outlet currency label from the server config (display only).
  final String currency;

  String get _total => total == null ? '—' : (total is num ? _fmt((total as num).toDouble()) : total.toString());

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: PosTheme.mist,
      appBar: AppBar(title: const Text('Payment complete')),
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              Container(
                width: 96,
                height: 96,
                decoration: const BoxDecoration(color: PosTheme.ok, shape: BoxShape.circle),
                child: const Icon(Icons.check_rounded, color: Colors.white, size: 56),
              ),
              const SizedBox(height: 24),
              const Text('Paid in full', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: PosTheme.ink)),
              const SizedBox(height: 8),
              Text('Receipt $receiptId', textAlign: TextAlign.center, style: const TextStyle(color: PosTheme.slate, fontSize: 15)),
              const SizedBox(height: 24),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14), border: Border.all(color: PosTheme.line)),
                child: Column(children: [
                  _row('Total', _total),
                  if (change > 0) _row('Cash change', _fmt(change)),
                  if (tipsPending > 0) _row('Pending tip', _fmt(tipsPending)),
                ]),
              ),
              const SizedBox(height: 28),
              const Text('Order closed — table is free.', style: TextStyle(color: PosTheme.slate)),
              const SizedBox(height: 16),
              SizedBox(width: 260, height: PosTheme.minTouch + 8, child: FilledButton(
                onPressed: () => Navigator.of(context).pop(), // → PaymentScreen → popUntil tables
                child: const Text('Done'),
              )),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _row(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text(label, style: const TextStyle(color: PosTheme.slate, fontSize: 15)),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17, color: PosTheme.petrol)),
        ]),
      );

  String _fmt(double v) => money.moneyLabel(v, currency);
}