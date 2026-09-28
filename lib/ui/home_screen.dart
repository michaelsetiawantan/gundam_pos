import 'package:flutter/material.dart';

import 'package:gundam_pos/logic/shift_window.dart';
import 'package:gundam_pos/models/config_models.dart';
import 'package:gundam_pos/state/app_session.dart';
import 'package:gundam_pos/state/session_store.dart';
import 'package:gundam_pos/ui/more_screen.dart';
import 'package:gundam_pos/ui/open_tables_screen.dart';
import 'package:gundam_pos/ui/shift_screen.dart';
import 'package:gundam_pos/ui/theme.dart';
import 'package:gundam_pos/ui/today_transactions_screen.dart';
import 'package:gundam_pos/ui/widgets.dart';

/// P04 — POS home/dashboard: outlet/device/user/shift context + quick actions.
/// Sign-out is intentionally simple (PRD): only real blockers are warned about
/// (unsafe unsynced queue / active payment); open tables are NOT a blocker.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key, required this.session});

  final AppSession session;

  Future<void> _signOut(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sign out?'),
        content: const Text('You can sign out safely — open tables stay open on the server and can be continued later.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: PosTheme.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );
    if (ok == true) await session.logout();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final ctx = session.context;
        final shiftGate = ShiftGate(session.config?.shift ?? ShiftConfig.defaultValue());
        return Scaffold(
          appBar: AppBar(
            title: Text(ctx.outletName ?? 'Gundam POS'),
            actions: [
              IconButton(
                tooltip: 'Refresh config',
                onPressed: session.syncing ? null : () => session.refreshConfig(),
                icon: Icon(session.syncing ? Icons.sync : Icons.sync),
              ),
              PopupMenuButton<String>(
                onSelected: (v) {
                  if (v == 'signout') _signOut(context);
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'signout', child: Text('Sign out')),
                ],
              ),
            ],
          ),
          body: Padding(
            padding: const EdgeInsets.all(20),
            child: ListView(
              children: [
                if (session.showLicenseReminder) ...[
                  _LicenseReminder(session: session),
                  const SizedBox(height: 20),
                ],
                _ContextCard(ctx: ctx, lastSync: session.lastSyncAt, config: session.config != null),
                const SizedBox(height: 20),
                GridView.count(
                  crossAxisCount: 3,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  mainAxisSpacing: 16,
                  crossAxisSpacing: 16,
                  childAspectRatio: 1.25,
                  children: [
                    HomeTile(icon: Icons.table_restaurant, title: 'Open Tables', subtitle: 'Server-synced hanging orders', onTap: () => _openTables(context)),
                    HomeTile(icon: Icons.receipt_long, title: "Today's Orders", subtitle: 'Same-day transactions', onTap: () => _open(context, TodayTransactionsScreen(session: session))),
                    HomeTile(icon: Icons.payments_outlined, title: shiftGate.startLabel, subtitle: shiftGate.isAutomatic ? 'Meal-shift cash count' : 'Open the cashier shift', onTap: () => _openShift(context)),
                    HomeTile(icon: Icons.settings_outlined, title: 'More', subtitle: 'Sync, health, update', onTap: () => _open(context, MoreScreen(session: session))),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _open(BuildContext context, Widget screen) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
  }

  void _openTables(BuildContext context) {
    final config = session.config;
    if (config == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Menu config not ready yet — pull it via the sync icon first.')),
      );
      return;
    }
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => OpenTablesScreen(session: session, config: config),
    ));
  }

  void _openShift(BuildContext context) {
    final config = session.config;
    if (config == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Sync the config first (refresh icon), then start a shift.')),
      );
      return;
    }
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ShiftScreen(session: session, config: config),
    ));
  }
}

class _ContextCard extends StatelessWidget {
  const _ContextCard({required this.ctx, required this.lastSync, required this.config});

  final PosContext ctx;
  final DateTime? lastSync;
  final bool config;

  @override
  Widget build(BuildContext context) {
    final name = ctx.userName ?? 'Cashier';
    final shortcode = ctx.shortcode ?? '-';
    final outlet = ctx.outletName ?? '';
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: const LinearGradient(colors: [PosTheme.petrol, PosTheme.petrolDark]),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const CircleAvatar(backgroundColor: PosTheme.teal, child: Icon(Icons.person, color: PosTheme.petrol)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(name, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700)),
              Text(outlet, style: const TextStyle(color: PosTheme.tealSoft, fontSize: 13)),
            ]),
          ),
        ]),
        const SizedBox(height: 14),
        const Divider(color: PosTheme.tealSoft, height: 1),
        const SizedBox(height: 12),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          _Fact(icon: Icons.devices, label: 'Device', value: shortcode),
          _Fact(icon: Icons.timelapse, label: 'Last sync', value: lastSync == null ? 'never' : _ago(lastSync!)),
          _Fact(icon: Icons.menu_book, label: 'Menu', value: config ? 'ready' : '—'),
        ]),
      ]),
    );
  }

  String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes}m ago';
    return '${d.inHours}h ago';
  }
}

class _Fact extends StatelessWidget {
  const _Fact({required this.icon, required this.label, required this.value});

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, color: PosTheme.tealSoft, size: 18),
      const SizedBox(width: 6),
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: const TextStyle(color: PosTheme.tealSoft, fontSize: 11)),
        Text(value, style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600)),
      ]),
    ]);
  }
}

/// BIG dismissible licence reminder (PRD §4.6). Informational only: it NEVER
/// blocks an ACTIVE/GRACE session — the hard lock is enforced server-side at the
/// grace cutoff, which refuses login (403 license_locked). Red for GRACE, amber
/// for ACTIVE-nearing-expiry.
class _LicenseReminder extends StatelessWidget {
  const _LicenseReminder({required this.session});

  final AppSession session;

  static String _fmt(DateTime? d) {
    if (d == null) return '—';
    final l = d.toLocal();
    String two(int v) => v < 10 ? '0$v' : '$v';
    return '${l.year}-${two(l.month)}-${two(l.day)}';
  }

  @override
  Widget build(BuildContext context) {
    final l = session.license!;
    final grace = l.isGrace;
    final accent = grace ? PosTheme.danger : PosTheme.warn;
    final title = grace ? 'Licence in grace period' : 'Licence expiring soon';
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.08),
        border: Border(left: BorderSide(color: accent, width: 6)),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(grace ? Icons.warning_amber_rounded : Icons.schedule, color: accent, size: 32),
          const SizedBox(width: 12),
          Expanded(
            child: Text(title, style: TextStyle(color: accent, fontSize: 22, fontWeight: FontWeight.w800)),
          ),
          IconButton(
            tooltip: 'Dismiss',
            onPressed: session.dismissLicenseReminder,
            icon: const Icon(Icons.close),
          ),
        ]),
        const SizedBox(height: 8),
        Text('Official coverage: ${_fmt(l.validFrom)} → ${_fmt(l.validTo)}',
            style: const TextStyle(fontSize: 16, color: PosTheme.ink, fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        if (grace) ...[
          Text('Grace window: ${_fmt(l.graceStart)} → ${_fmt(l.graceEndsAt)} (${l.graceDays ?? 0} days)',
              style: const TextStyle(fontSize: 16, color: PosTheme.slate)),
          const SizedBox(height: 10),
          const Text('POS sales are BLOCKED once the grace ends. The owner must renew from the web app to keep selling.',
              style: TextStyle(fontSize: 16, color: PosTheme.ink, fontWeight: FontWeight.w600)),
        ] else ...[
          const Text('Renew from the web app before the coverage ends to avoid interruption.',
              style: TextStyle(fontSize: 16, color: PosTheme.ink, fontWeight: FontWeight.w600)),
        ],
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerRight,
          child: OutlinedButton.icon(
            onPressed: session.dismissLicenseReminder,
            icon: const Icon(Icons.check),
            label: const Text('I understand'),
          ),
        ),
      ]),
    );
  }
}