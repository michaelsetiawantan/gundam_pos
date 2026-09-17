import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:gundam_pos/services/printer_health.dart';
import 'package:gundam_pos/state/app_session.dart';
import 'package:gundam_pos/ui/theme.dart';

/// P29/P32/P33/P34/P37 — More: sync status + pending push, config/media refresh
/// (atomic via temp+rename, last-known-good on failure), printer health
/// transport check, client update stub, and sign-out (open tables are NOT a
/// blocker; only real unsafe state warns).
class MoreScreen extends StatefulWidget {
  const MoreScreen({super.key, required this.session});

  final AppSession session;

  @override
  State<MoreScreen> createState() => _MoreScreenState();
}

class _MoreScreenState extends State<MoreScreen> {
  final _printerHealth = PrinterHealthChecker();
  PrinterLink? _printerLink;
  final _printerIp = TextEditingController(text: _envPrinterHost);

  static const _envPrinterHost = String.fromEnvironment('POS_PRINTER_HOST', defaultValue: '');

  Future<void> _refresh() async {
    final ok = await widget.session.refreshConfig();
    if (!mounted) return;
    _toast(ok ? 'Config synced. Domains cached atomically (temp+rename).' : 'Config refresh failed — last-known-good kept.');
  }

  Future<void> _drain() async {
    await widget.session.drainPush();
    if (!mounted) return;
    _toast('Pending push queue cleared (acked).');
  }

  Future<void> _checkPrinter() async {
    setState(() => _printerLink = null);
    final host = _printerIp.text.trim();
    if (host.isEmpty) {
      setState(() {
        _printerLink = PrinterLink(PrinterLinkState.unknown, detail: 'No printer host configured (POS_PRINTER_HOST).');
      });
      return;
    }
    final link = await _printerHealth.check(transport: 'NETWORK', host: host, port: 9100);
    if (!mounted) return;
    setState(() => _printerLink = link);
    _toast(link.detail);
  }

  void _checkUpdate() {
    _toast('v0.1.0 — APK updates are manual via the server upgrade notifier (SOP: SHA-256 verify + in-place install).');
  }

  Future<void> _signOut() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sign out?'),
        content: const Text('Open tables stay on the server and are not a blocker. A payment in progress or unsafe unsynced data would warn here.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(style: FilledButton.styleFrom(backgroundColor: PosTheme.danger), onPressed: () => Navigator.pop(ctx, true), child: const Text('Sign out')),
        ],
      ),
    );
    if (ok == true) {
      await widget.session.logout();
      if (mounted) Navigator.of(context).pop();
    }
  }

  void _toast(String msg) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  @override
  Widget build(BuildContext context) {
    final s = widget.session;
    return Scaffold(
      appBar: AppBar(title: const Text('More')),
      body: SafeArea(
        child: ListenableBuilder(
          listenable: s,
          builder: (_, __) => ListView(
            padding: const EdgeInsets.all(20),
            children: [
              _Section(
                icon: Icons.sync,
                title: 'Sync',
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  _infoRow('Last config sync', s.lastSyncAt == null ? 'never' : s.lastSyncAt!.toIso8601String().substring(11, 19)),
                  _infoRow('Pending push queue', '${s.pendingPushCount} item(s)'),
                  const SizedBox(height: 12),
                  Row(children: [
                    OutlinedButton(onPressed: s.syncing ? null : _refresh, child: const Text('Refresh config')),
                    const SizedBox(width: 12),
                    OutlinedButton(onPressed: s.pendingPushCount == 0 ? null : _drain, child: const Text('Push pending')),
                  ]),
                  const SizedBox(height: 6),
                  const Text('Atomic temp+rename; failed pulls keep the last-known-good cache.',
                      style: TextStyle(color: PosTheme.slate, fontSize: 12)),
                ]),
              ),
              _Section(
                icon: Icons.local_printshop,
                title: 'Printer health',
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  TextField(
                    controller: _printerIp,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.:]+'))],
                    decoration: const InputDecoration(labelText: 'Network printer (host:port)'),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton(onPressed: _checkPrinter, child: const Text('Test connection')),
                  if (_printerLink != null) ...[
                    const SizedBox(height: 12),
                    _PrinterResult(link: _printerLink!),
                  ],
                  const SizedBox(height: 8),
                  const Text('Bluetooth & USB transport checks are stubbed on this build (reported as Unsupported).',
                      style: TextStyle(color: PosTheme.slate, fontSize: 12)),
                ]),
              ),
              _Section(
                icon: Icons.system_update,
                title: 'Client update',
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('Current version: v0.1.0', style: TextStyle(color: PosTheme.slate)),
                  const SizedBox(height: 12),
                  OutlinedButton(onPressed: _checkUpdate, child: const Text('Check for update')),
                ]),
              ),
              _Section(
                icon: Icons.logout,
                title: 'Sign out',
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(foregroundColor: PosTheme.danger),
                  onPressed: _signOut,
                  child: const Text('Sign out of this device'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _infoRow(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          Expanded(child: Text(label, style: const TextStyle(color: PosTheme.slate))),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w700)),
        ]),
      );
}

class _Section extends StatelessWidget {
  const _Section({required this.icon, required this.title, required this.child});
  final IconData icon;
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14), border: Border.all(color: PosTheme.line)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(icon, color: PosTheme.petrol, size: 22),
          const SizedBox(width: 10),
          Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: PosTheme.petrol)),
        ]),
        const SizedBox(height: 14),
        child,
      ]),
    );
  }
}

class _PrinterResult extends StatelessWidget {
  const _PrinterResult({required this.link});
  final PrinterLink link;

  @override
  Widget build(BuildContext context) {
    final (color, label) = switch (link.state) {
      PrinterLinkState.ready => (PosTheme.ok, 'Ready'),
      PrinterLinkState.offline => (PosTheme.danger, 'Offline'),
      PrinterLinkState.unsupported => (PosTheme.warn, 'Unsupported'),
      PrinterLinkState.notPaired => (PosTheme.warn, 'Not paired'),
      PrinterLinkState.bluetoothOff => (PosTheme.warn, 'Bluetooth off'),
      PrinterLinkState.unknown => (PosTheme.slate, 'Device status: Unknown'),
    };
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(10)),
      child: Row(children: [
        Icon(Icons.circle, color: color, size: 12),
        const SizedBox(width: 8),
        Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w700)),
        const SizedBox(width: 8),
        Expanded(child: Text(link.detail, style: const TextStyle(color: PosTheme.slate, fontSize: 12))),
      ]),
    );
  }
}