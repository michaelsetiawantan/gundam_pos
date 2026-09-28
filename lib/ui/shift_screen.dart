import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:gundam_pos/logic/shift_window.dart';
import 'package:gundam_pos/models/config_models.dart';
import 'package:gundam_pos/services/bluetooth_print_transport.dart';
import 'package:gundam_pos/services/print_routing.dart';
import 'package:gundam_pos/services/printer_health.dart';
import 'package:gundam_pos/state/app_session.dart';
import 'package:gundam_pos/state/shift_controller.dart';
import 'package:gundam_pos/ui/printer_status.dart';
import 'package:gundam_pos/ui/theme.dart';
import 'package:gundam_pos/ui/widgets.dart';

/// P05/P27/P28 — Shift open (total-only housebank cash count) + close
/// (+ variance-closing). TOTAL-ONLY: a single nominal, no denomination input.
class ShiftScreen extends StatefulWidget {
  const ShiftScreen({super.key, required this.session, required this.config});

  final AppSession session;
  final TenantConfig config;

  @override
  State<ShiftScreen> createState() => _ShiftScreenState();
}

class _ShiftScreenState extends State<ShiftScreen> {
  final _housebank = TextEditingController();
  final _counted = TextEditingController();

  /// The app-wide controller held by the session — pinned config applies
  /// everywhere (order/payment flow included), not just this screen.
  ShiftController get c => widget.session.shiftController;

  /// The shift rules the POS currently runs on. Pinned to the config the
  /// running shift started with (config change applies next day only).
  ShiftGate get gate => widget.session.gateFor(widget.config);

  /// Configured Bluetooth printers (PRD: opening shift shows the affected
  /// printers) and their honest status. Test Print stays MANUAL.
  final _bluetooth = BluetoothPrintTransport();
  final _btStatus = <String, PrinterLink>{};
  String? _busyPrinterId;

  List<ClientPrinter> get _bluetoothPrinters => [
        for (final p in widget.session.printRouting?.printers ?? const <ClientPrinter>[])
          if (p.transport == 'BLUETOOTH') p,
      ];

  Future<void> _checkBluetooth(ClientPrinter printer) async {
    setState(() => _busyPrinterId = printer.id);
    final link = await PrinterHealthChecker().check(transport: 'BLUETOOTH', bluetoothMac: printer.bluetoothMac);
    if (!mounted) return;
    setState(() {
      _btStatus[printer.id] = link;
      _busyPrinterId = null;
    });
  }

  Future<void> _testPrint(ClientPrinter printer) async {
    setState(() => _busyPrinterId = printer.id);
    var link = await _bluetooth.testPrint(
      mac: printer.bluetoothMac ?? '',
      widthMm: printer.widthMm,
      printerName: printer.name,
    );
    if (link.state == PrinterLinkState.permissionRequired) {
      await _bluetooth.requestPermission();
      link = await _bluetooth.testPrint(
        mac: printer.bluetoothMac ?? '',
        widthMm: printer.widthMm,
        printerName: printer.name,
      );
    }
    if (!mounted) return;
    setState(() {
      _btStatus[printer.id] = link;
      _busyPrinterId = null;
    });
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${printer.name}: ${link.detail}')));
  }

  /// The affected Bluetooth printers with a manual Test Print (never automatic).
  List<Widget> _printerSection() {
    final printers = _bluetoothPrinters;
    if (printers.isEmpty) return const [];
    return [
      const SizedBox(height: 24),
      const Text('Printers', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: PosTheme.petrol)),
      const SizedBox(height: 4),
      const Text('Manual Test Print only — never run automatically.',
          style: TextStyle(color: PosTheme.slate, fontSize: 12)),
      const SizedBox(height: 10),
      for (final p in printers)
        BluetoothPrinterRow(
          printer: p,
          status: _btStatus[p.id],
          busy: _busyPrinterId == p.id,
          onCheck: () => _checkBluetooth(p),
          onTest: () => _testPrint(p),
        ),
    ];
  }

  @override
  void initState() {
    super.initState();
    final def = widget.config.shift.defaultHouseBank;
    _housebank.text = def > 0 ? '${def.round()}' : '';
  }

  @override
  void dispose() {
    _housebank.dispose();
    _counted.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final ok = await c.open(
      housebank: double.tryParse(_housebank.text.trim()),
      config: widget.config.shift,
    );
    if (!mounted) return;
    if (!ok) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(c.error ?? 'Could not start shift')));
    if (ok) _counted.text = '0';
  }

  Future<void> _end() async {
    if ((double.tryParse(_counted.text.trim()) ?? -1) < 0) return;
    final ok = await c.close(countedTotal: double.tryParse(_counted.text.trim()) ?? 0);
    if (!mounted) return;
    if (!ok) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(c.error ?? 'Could not close shift')));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(c.isClosed ? 'Closing report' : (c.isOpen ? gate.endLabel : gate.startLabel))),
      body: SafeArea(
        child: ListenableBuilder(
          listenable: c,
          builder: (_, __) {
            if (c.isClosed) return _closing(context);
            return ListView(padding: const EdgeInsets.all(20), children: [
              if (!c.isOpen) ..._openForm() else ..._activeCard(),
              ..._printerSection(),
              if (c.error != null) ...[
                const SizedBox(height: 12),
                ErrorBanner(message: c.error),
              ],
            ]);
          },
        ),
      ),
    );
  }

  List<Widget> _openForm() {
    final g = gate;
    return [
      AuthHeader(
        title: g.startLabel,
        caption: g.isAutomatic
            ? 'Meal-shift cash count — count the opening cash drawer and record the single total.'
            : 'Count the opening cash drawer and record the total.',
      ),
      if (g.windowNotConfigured) ...[
        const ErrorBanner(message: 'Meal-shift window not configured — the outlet has not synced a shift range yet.'),
        const SizedBox(height: 12),
      ],
      TextField(
        controller: _housebank,
        enabled: !c.busy,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        decoration: const InputDecoration(labelText: 'Opening cash (total)', prefixIcon: Icon(Icons.account_balance_wallet_outlined), prefixText: 'Rp '),
      ),
      const SizedBox(height: 8),
      const Text('Cash count is a single total — no denomination input.', style: TextStyle(color: PosTheme.slate, fontSize: 13)),
      const SizedBox(height: 20),
      PrimaryButton(label: g.startLabel, busy: c.busy, icon: Icons.play_arrow_rounded, onPressed: c.busy ? null : _start),
    ];
  }

  List<Widget> _activeCard() {
    final g = gate;
    return [
      Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          gradient: const LinearGradient(colors: [PosTheme.petrol, PosTheme.petrolDark]),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Shift open', style: TextStyle(color: PosTheme.tealSoft, fontSize: 13)),
          const SizedBox(height: 6),
          Text('Opening cash: Rp ${c.openingHousebank.round()}',
              style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text('Type: ${(c.shift?['shiftType'] ?? 'MANUAL')}', style: const TextStyle(color: PosTheme.tealSoft)),
          if (g.isAutomatic)
            Text('Meal-shift window: ${g.windowSummary}', style: const TextStyle(color: PosTheme.tealSoft, fontSize: 12)),
        ]),
      ),
      if (c.configChangedSinceStart(widget.config.shift)) ...[
        const SizedBox(height: 12),
        const ErrorBanner(message: 'Shift config changed — the new rules apply from the NEXT day. This shift keeps the plan it started with.'),
      ],
      const SizedBox(height: 24),
      Text(g.endLabel, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: PosTheme.petrol)),
      const SizedBox(height: 10),
      TextField(
        controller: _counted,
        enabled: !c.busy,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        decoration: const InputDecoration(labelText: 'Counted cash (total)', prefixIcon: Icon(Icons.payments_outlined), prefixText: 'Rp '),
      ),
      const SizedBox(height: 20),
      PrimaryButton(label: g.endLabel, busy: c.busy, icon: Icons.logout, onPressed: c.busy ? null : _end),
    ];
  }

  Widget _closing(BuildContext context) {
    final cl = c.closing ?? const <String, dynamic>{};
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Center(child: Icon(Icons.verified, color: PosTheme.ok, size: 64)),
        const SizedBox(height: 8),
        const Center(child: Text('Shift closed', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800))),
        const SizedBox(height: 20),
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14), border: Border.all(color: PosTheme.line)),
          child: Column(children: [
            _row('Opening housebank', _n(cl['openHousebank'])),
            _row('Cash sales', _n(cl['cashSales'])),
            _row('Payout', _n(cl['payout'])),
            _row('Expected cash', _n(cl['expectedCash'])),
            const Divider(height: 20),
            _row('Counted cash', _n(cl['closeHousebank'])),
            _row('Variance', _n(cl['variance']), accent: true),
          ]),
        ),
        const SizedBox(height: 20),
        Text('Guests upserted: ${(cl['guestUpsert']?['upserted'] ?? 0)}', style: const TextStyle(color: PosTheme.slate)),
        const SizedBox(height: 24),
        PrimaryButton(
          label: 'Done',
          onPressed: () {
            c.reset();
            Navigator.of(context).pop();
          },
        ),
      ],
    );
  }

  Widget _row(String label, Object value, {bool accent = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(children: [
          Expanded(child: Text(label, style: const TextStyle(color: PosTheme.slate, fontSize: 15))),
          const SizedBox(width: 12),
          Flexible(
            child: Text('Rp ${_numStr(value)}',
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 16,
                  color: accent ? (numValue(value) >= 0 ? PosTheme.ok : PosTheme.danger) : PosTheme.petrol,
                )),
          ),
        ]),
      );

  Object _n(Object? v) => v ?? 0;

  String _numStr(Object v) => (numValue(v)).round().toString();
  static num numValue(Object v) => (v as num?) ?? 0;
}