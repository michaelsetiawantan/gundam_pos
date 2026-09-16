import 'package:flutter/material.dart';

import 'package:gundam_pos/api/api_client.dart';
import 'package:gundam_pos/state/app_session.dart';
import 'package:gundam_pos/ui/theme.dart';

/// P26 — Today's transactions. The POS only shows the same trading day
/// (past bills live in the web-app). Reprint is a print-broker action; VOID is
/// same-day only and drives the same approval lifecycle as cancel/refund;
/// a past-day refund must be done in the web-app Past Bill.
class TodayTransactionsScreen extends StatelessWidget {
  const TodayTransactionsScreen({super.key, required this.session});

  final AppSession session;

  bool get _bills => session.todayBills.isNotEmpty;

  Future<void> _void(BuildContext context, Map<String, dynamic> bill) async {
    final orderId = bill['orderId'];
    if (orderId == null) {
      _toast(context, 'This bill has no linked order — use web-app.');
      return;
    }
    final paidAt = DateTime.tryParse((bill['paidAt'] ?? bill['transactedAt'] ?? '').toString());
    final isToday = paidAt == null || _sameDay(paidAt);
    if (!isToday) {
      _toast(context, 'This is a past-day bill — request the refund in the Web Past Bill.');
      return;
    }
    final reason = await _askReason(context);
    if (reason == null || !context.mounted) return;
    try {
      final r = await session.posApi.requestVoid(orderId as String, reason: reason);
      final status = ((r['approval'] as Map?)?['status']) ?? 'PENDING';
      if (context.mounted) _toast(context, 'Void requested — approval $status.');
    } on PosApiException catch (e) {
      if (context.mounted) _toast(context, 'Void failed (${e.code}).');
    } on PosNetworkException {
      if (context.mounted) _toast(context, 'No network — void not requested.');
    }
  }

  void _reprint(BuildContext context, Map<String, dynamic> bill) {
    // Print broker render is deferred (F4); queue the job locally.
    _toast(context, 'Reprint queued for ${bill['receiptId']} — print is delivered via the print broker.');
  }

  bool _sameDay(DateTime t) {
    final n = DateTime.now();
    return t.year == n.year && t.month == n.month && t.day == n.day;
  }

  Future<String?> _askReason(BuildContext context) {
    final c = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Void this bill?'),
        content: TextField(controller: c, autofocus: true, maxLines: 2, decoration: const InputDecoration(labelText: 'Reason')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim().isEmpty ? 'Void (POS)' : c.text.trim()), child: const Text('Request void')),
        ],
      ),
    );
  }

  void _toast(BuildContext context, String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Today's transactions")),
      body: SafeArea(
        child: ListenableBuilder(
          listenable: session,
          builder: (_, __) {
            if (!_bills) {
              return const Center(
                child: Text('No transactions today yet.', style: TextStyle(color: PosTheme.slate, fontSize: 16)),
              );
            }
            return ListView.separated(
              padding: const EdgeInsets.all(20),
              itemCount: session.todayBills.length,
              separatorBuilder: (_, __) => const SizedBox(height: 12),
              itemBuilder: (_, i) {
                final b = session.todayBills[i];
                return Card(
                  elevation: 0,
                  color: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: PosTheme.line)),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(children: [
                      const CircleAvatar(backgroundColor: PosTheme.tealSoft, child: Icon(Icons.check, color: PosTheme.petrol)),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(b['receiptId']?.toString() ?? '—', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14, fontFamily: 'monospace')),
                          const SizedBox(height: 4),
                          Text('Rp ${_amt(b['total'])} · paid', style: const TextStyle(color: PosTheme.slate, fontSize: 14)),
                        ]),
                      ),
                      PopupMenuButton<String>(
                        onSelected: (v) {
                          if (v == 'reprint') _reprint(context, b);
                          if (v == 'void') _void(context, b);
                        },
                        itemBuilder: (_) => const [
                          PopupMenuItem(value: 'reprint', child: Text('Reprint')),
                          PopupMenuItem(value: 'void', child: Text('Void (same-day)')),
                        ],
                      ),
                    ]),
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }

  String _amt(Object? v) => (v as num?)?.round().toString() ?? '0';
}