import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:gundam_pos/services/bluetooth_print_transport.dart';
import 'package:gundam_pos/services/diagnostic_report.dart';
import 'package:gundam_pos/services/print_routing.dart';
import 'package:gundam_pos/services/printer_health.dart';
import 'package:gundam_pos/services/update_service.dart';
import 'package:gundam_pos/services/usb_print_transport.dart';
import 'package:gundam_pos/state/app_session.dart';
import 'package:gundam_pos/ui/about_screen.dart';
import 'package:gundam_pos/ui/device_log_screen.dart';
import 'package:gundam_pos/ui/print_diagnostics_screen.dart';
import 'package:gundam_pos/ui/printer_status.dart';
import 'package:gundam_pos/ui/theme.dart';
import 'package:gundam_pos/ui/widgets.dart';

/// P29/P32/P33/P34/P37 — More: sync status + pending push, config/media refresh
/// (atomic via temp+rename, last-known-good on failure), printer health
/// transport check + a MANUAL Test Print for a configured Bluetooth or USB
/// printer, the client update notice (version identity + changelog, install on
/// the About screen), and sign-out (open tables are NOT a blocker; only real
/// unsafe state warns).
class MoreScreen extends StatefulWidget {
  const MoreScreen({super.key, required this.session, this.installer});

  final AppSession session;

  /// Injectable APK bridge, forwarded to the About screen (tests).
  final ApkInstallBridge? installer;

  @override
  State<MoreScreen> createState() => _MoreScreenState();
}

class _MoreScreenState extends State<MoreScreen> {
  final _printerHealth = PrinterHealthChecker();
  final _bluetooth = BluetoothPrintTransport();
  final _usb = UsbPrintTransport();
  PrinterLink? _printerLink;
  final _printerIp = TextEditingController(text: _envPrinterHost);

  /// Honest per-printer Bluetooth status, keyed by printer id.
  final Map<String, PrinterLink> _btStatus = {};

  /// Honest per-printer USB status, keyed by printer id.
  final Map<String, PrinterLink> _usbStatus = {};
  String? _busyPrinterId;

  /// True while a diagnostic bundle is being shipped, so the button is honest.
  bool _sendingDiag = false;

  static const _envPrinterHost = String.fromEnvironment('POS_PRINTER_HOST', defaultValue: '');

  @override
  void initState() {
    super.initState();
    // Refresh the pending print-log count so the entry below is honest.
    widget.session.refreshPrintLogPending();
  }

  Future<void> _refresh() async {
    final ok = await widget.session.refreshConfig();
    if (!mounted) return;
    _toast(ok ? 'Config synced. Domains cached atomically (temp+rename).' : 'Config refresh failed — last-known-good kept.');
  }

  /// Repair path: forget the applied domain versions and pull EVERY domain again.
  Future<void> _reSyncAll() async {
    final ok = await widget.session.forceFullConfigResync();
    if (!mounted) return;
    _toast(ok
        ? 'Full config re-sync done — menus, outlet details and print formats re-pulled.'
        : 'Re-sync failed — last-known-good kept.');
  }

  /// Send the queued order lines and dequeue them ONLY when the server accepted
  /// them. (The old "Push pending" called drainPush, which acks the whole queue
  /// without sending — that would silently drop queued order items.)
  Future<void> _syncQueue() async {
    final n = await widget.session.flushOrderQueue();
    if (!mounted) return;
    _toast(n > 0
        ? '$n queued item(s) synced to the server.'
        : 'Nothing synced — ${widget.session.orderQueuePending} still queued (offline?). It retries automatically.');
  }

  /// Manual "Push now": flush the order create/line/send queue AND every
  /// deferred (offline) settlement, then report honestly — never silent.
  Future<void> _pushNow() async {
    final r = await widget.session.pushNow();
    if (!mounted) return;
    final parts = <String>[
      if (r.orderItems > 0) '${r.orderItems} order item(s)',
      if (r.settlements > 0) '${r.settlements} settlement(s)',
    ];
    if (r.failed > 0) {
      _toast('${r.failed} settlement(s) REFUSED by the server — open Today transactions to fix and commit again.');
    } else if (parts.isEmpty) {
      _toast(r.queued > 0
          ? 'Nothing accepted — ${r.queued} still queued (offline?). It retries automatically.'
          : 'Nothing to push — the queue is empty.');
    } else {
      _toast('Pushed ${parts.join(' + ')} to the server.');
    }
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

  List<ClientPrinter> get _bluetoothPrinters =>
      [for (final p in widget.session.printRouting?.printers ?? const <ClientPrinter>[]) if (p.transport == 'BLUETOOTH') p];

  /// Manual test print only — the PRD forbids an automatic test per shift.
  Future<void> _testPrint(ClientPrinter printer) async {
    final mac = printer.bluetoothMac;
    setState(() => _busyPrinterId = printer.id);
    var link = await _bluetooth.testPrint(mac: mac ?? '', widthMm: printer.widthMm, printerName: printer.name);
    // A missing runtime permission is recoverable: prompt once, then retry.
    if (link.state == PrinterLinkState.permissionRequired) {
      await _bluetooth.requestPermission();
      link = await _bluetooth.testPrint(mac: mac ?? '', widthMm: printer.widthMm, printerName: printer.name);
    }
    if (!mounted) return;
    setState(() {
      _btStatus[printer.id] = link;
      _busyPrinterId = null;
    });
    _toast('${printer.name}: ${link.detail}');
  }

  Future<void> _checkBluetooth(ClientPrinter printer) async {
    setState(() => _busyPrinterId = printer.id);
    final link = await _printerHealth.check(
      transport: 'BLUETOOTH',
      bluetoothMac: printer.bluetoothMac,
    );
    if (!mounted) return;
    setState(() {
      _btStatus[printer.id] = link;
      _busyPrinterId = null;
    });
    _toast('${printer.name}: ${link.detail}');
  }

  List<ClientPrinter> get _usbPrinters =>
      [for (final p in widget.session.printRouting?.printers ?? const <ClientPrinter>[]) if (p.transport == 'USB') p];

  /// Manual test print only — the PRD forbids an automatic test per shift.
  Future<void> _testPrintUsb(ClientPrinter printer) async {
    setState(() => _busyPrinterId = printer.id);
    final link = await _usb.testPrint(
      vidPid: printer.usbVidPid,
      chip: printer.usbChip,
      widthMm: printer.widthMm,
      printerName: printer.name,
    );
    if (!mounted) return;
    setState(() {
      _usbStatus[printer.id] = link;
      _busyPrinterId = null;
    });
    _toast('${printer.name}: ${link.detail}');
  }

  Future<void> _checkUsb(ClientPrinter printer) async {
    setState(() => _busyPrinterId = printer.id);
    final link = await _printerHealth.check(
      transport: 'USB',
      usbVidPid: printer.usbVidPid,
      usbChip: printer.usbChip,
    );
    if (!mounted) return;
    setState(() {
      _usbStatus[printer.id] = link;
      _busyPrinterId = null;
    });
    _toast('${printer.name}: ${link.detail}');
  }

  Future<void> _reportHealth() async {
    final ok = await widget.session.reportPrinterHealth();
    if (!mounted) return;
    _toast(ok ? 'Printer health reported to the server.' : 'Nothing to report (no printer routing synced).');
  }

  /// Ask for a short description, then bundle the device context + print-log
  /// summary + recent log lines and ship it. Honest result: it says whether the
  /// bundle reached the server or is queued offline, and surfaces the exact
  /// failure (e.g. a server refusal) rather than hiding it behind "no network".
  Future<void> _sendDiagnostics() async {
    final c = TextEditingController();
    final desc = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Send diagnostics to server'),
        content: TextField(
          controller: c,
          autofocus: true,
          maxLength: kDiagMaxDescriptionLen,
          minLines: 2,
          maxLines: 4,
          decoration: const InputDecoration(
            labelText: 'What went wrong?',
            hintText: 'e.g. Kitchen printer prints blank tickets since this morning.',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('Send')),
        ],
      ),
    );
    if (desc == null || !mounted) return;
    if (desc.isEmpty) {
      _toast('Describe the issue in a few words before sending.');
      return;
    }
    setState(() => _sendingDiag = true);
    final res = await widget.session.sendDiagnostics(description: desc);
    if (!mounted) return;
    setState(() => _sendingDiag = false);
    final why = widget.session.lastDiagnosticFailure;
    _toast(res.sent > 0
        ? 'Diagnostic report sent to the server.'
        : 'Report queued (${res.pending} pending)${why == null ? '' : ' — $why'}. It retries on the next sync.');
  }

  /// Manual, user-confirmed update check (the PRD's automatic check rides the
  /// config sync; this button is the operator's on-demand view).
  Future<void> _checkUpdate() async {
    await widget.session.checkForUpdate();
    if (!mounted) return;
    final s = widget.session;
    _toast(s.updateAvailable
        ? 'New version v${s.lastRelease!.version} available.'
        : s.lastUpdateCheckError != null
            ? 'Update check failed — staying silent (no new release confirmed).'
            : 'No newer release published by the server.');
  }

  void _openAbout() => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => AboutScreen(session: widget.session, installer: widget.installer),
        ),
      );

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
                icon: Icons.dns,
                title: 'Server',
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  _infoRow('In use', s.serverAddress),
                  const SizedBox(height: 12),
                  ServerAddressField(session: s, compact: true),
                  const SizedBox(height: 8),
                  const Text('Changing the server re-syncs the outlet config on the next refresh.',
                      style: TextStyle(color: PosTheme.slate, fontSize: 12)),
                ]),
              ),
              _Section(
                icon: Icons.sync,
                title: 'Sync',
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  _infoRow('Last config sync', s.lastSyncAt == null ? 'never' : s.lastSyncAt!.toIso8601String().substring(11, 19)),
                  _infoRow('Pending push queue', '${s.pendingPushCount} item(s)'),
                  _infoRow('Queued order items', '${s.orderQueuePending} waiting to sync'),
                  _infoRow('Local settlements waiting', '${s.pendingSettlements.length} (offline)'),
                  if (s.failedSettlementCount > 0)
                    _infoRow('Settlements refused by server', '${s.failedSettlementCount} — see Today transactions'),
                  const SizedBox(height: 12),
                  Row(children: [
                    OutlinedButton(onPressed: s.syncing ? null : _refresh, child: const Text('Refresh config')),
                    const SizedBox(width: 12),
                    OutlinedButton(
                        onPressed: s.busy ? null : _syncQueue,
                        child: const Text('Sync now')),
                  ]),
                  const SizedBox(height: 8),
                  Row(children: [
                    FilledButton.icon(
                        onPressed: s.busy ? null : _pushNow,
                        icon: const Icon(Icons.cloud_upload, size: 18),
                        label: const Text('Push now')),
                    const SizedBox(width: 12),
                    OutlinedButton(
                        onPressed: s.syncing ? null : _reSyncAll,
                        child: const Text('Re-sync everything')),
                  ]),
                  const SizedBox(height: 6),
                  const Text(
                      'Push now sends every queued order create/line/send AND every deferred (offline) settlement. '
                      'A settlement the server refuses is marked FAILED with its code and is NOT retried until you commit it again '
                      'from Today transactions. Atomic temp+rename; failed pulls keep the last-known-good cache.',
                      style: TextStyle(color: PosTheme.slate, fontSize: 12)),
                ]),
              ),
              _Section(
                icon: Icons.local_printshop,
                title: 'Printer health',
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  if (_bluetoothPrinters.isEmpty)
                    const Text('No Bluetooth printer configured for this outlet.',
                        style: TextStyle(color: PosTheme.slate, fontSize: 12))
                  else
                    for (final p in _bluetoothPrinters)
                      BluetoothPrinterRow(
                        printer: p,
                        status: _btStatus[p.id],
                        busy: _busyPrinterId == p.id,
                        onCheck: () => _checkBluetooth(p),
                        onTest: () => _testPrint(p),
                      ),
                  if (_usbPrinters.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    const Text('USB printers (bridge chip built in)',
                        style: TextStyle(fontWeight: FontWeight.w700, color: PosTheme.petrol)),
                    const SizedBox(height: 8),
                    for (final p in _usbPrinters)
                      UsbPrinterRow(
                        printer: p,
                        status: _usbStatus[p.id],
                        busy: _busyPrinterId == p.id,
                        onCheck: () => _checkUsb(p),
                        onTest: () => _testPrintUsb(p),
                      ),
                  ],
                  const SizedBox(height: 12),
                  TextField(
                    controller: _printerIp,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.:]+'))],
                    decoration: const InputDecoration(labelText: 'Network printer (host:port)'),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton(onPressed: _checkPrinter, child: const Text('Test network connection')),
                  if (_printerLink != null) ...[
                    const SizedBox(height: 12),
                    PrinterResultCard(link: _printerLink!),
                  ],
                  const SizedBox(height: 12),
                  OutlinedButton(onPressed: _reportHealth, child: const Text('Report all printer health')),
                  const SizedBox(height: 8),
                  const Text('Bluetooth prints over Classic SPP / ESC-POS. USB prints over Android USB Host (CDC-ACM / CH340 / PL2303 / FTDI drivers built in). Test Print is manual only — never automatic.',
                      style: TextStyle(color: PosTheme.slate, fontSize: 12)),
                ]),
              ),
              _Section(
                icon: Icons.bug_report,
                title: 'Diagnostics & support',
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  _infoRow('Pending upload', '${s.printLogPending} print log(s)'),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: _sendingDiag ? null : _sendDiagnostics,
                    icon: _sendingDiag
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.send),
                    label: const Text('Send diagnostics to server'),
                  ),
                  const SizedBox(height: 4),
                  const Text('Report a problem to the server: bundles the device context, the print-log summary and recent app log lines with your note. Offline it is queued and sent on the next sync.',
                      style: TextStyle(color: PosTheme.slate, fontSize: 12)),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(builder: (_) => DeviceLogScreen(session: s)),
                    ),
                    icon: const Icon(Icons.article_outlined, size: 18),
                    label: const Text('Open device log'),
                  ),
                  const SizedBox(height: 4),
                  const Text('See the recent app log lines on this tablet (time, level, tag, message) — warnings and errors from this and the previous session. Copy them or send them to the server.',
                      style: TextStyle(color: PosTheme.slate, fontSize: 12)),
                  const SizedBox(height: 12),
                  OutlinedButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(builder: (_) => PrintDiagnosticsScreen(session: s)),
                    ),
                    child: const Text('Open print diagnostics'),
                  ),
                  const SizedBox(height: 8),
                  const Text('Every print attempt (failure, fallback, success) is recorded locally, then shipped to the server as development material.',
                      style: TextStyle(color: PosTheme.slate, fontSize: 12)),
                ]),
              ),
              _Section(
                icon: Icons.system_update,
                title: 'Client update',
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  _infoRow('Installed', s.appVersion.display),
                  _infoRow('Schema version', '${s.appVersion.schemaVersion}'),
                  const SizedBox(height: 12),
                  if (s.updateAvailable && s.lastRelease != null)
                    UpdateNoticeCard(release: s.lastRelease!)
                  else
                    Text(
                      s.lastUpdateCheckError != null
                          ? 'Update check failed — recorded honestly on About, never shown to the cashier.'
                          : 'No newer release offered by the server.',
                      style: const TextStyle(color: PosTheme.slate, fontSize: 12),
                    ),
                  const SizedBox(height: 12),
                  Row(children: [
                    OutlinedButton(onPressed: _checkUpdate, child: const Text('Check for update')),
                    const SizedBox(width: 12),
                    OutlinedButton(onPressed: _openAbout, child: const Text('Version & updates')),
                  ]),
                  const SizedBox(height: 8),
                  const Text('APK upgrade = manual, user-confirmed, SHA-256 verified in-place install. Config deltas stay automatic.',
                      style: TextStyle(color: PosTheme.slate, fontSize: 12)),
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

/// One configured Bluetooth printer: honest status + a manual Test Print.
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
