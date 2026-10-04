import 'package:flutter/material.dart';

import 'package:gundam_pos/logic/money.dart' as money;
import 'package:gundam_pos/logic/shift_window.dart';
import 'package:gundam_pos/models/config_models.dart';
import 'package:gundam_pos/services/bluetooth_print_transport.dart';
import 'package:gundam_pos/services/print_routing.dart';
import 'package:gundam_pos/services/printer_health.dart';
import 'package:gundam_pos/services/usb_print_transport.dart';
import 'package:gundam_pos/state/app_session.dart';
import 'package:gundam_pos/state/shift_controller.dart';
import 'package:gundam_pos/ui/money_input.dart';
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
  /// One controller per END SHIFT count input, keyed by [EndCountField.key]
  /// (countedTotal / cash / cashless / outlet method id). Built lazily from the
  /// mode's field list so the dialog renders 1 / 2 / N inputs.
  final _counts = <String, TextEditingController>{};

  TextEditingController _countFor(String key) =>
      _counts.putIfAbsent(key, () => TextEditingController());

  /// The shift rules the running shift runs on (pinned config if pinned).
  ShiftConfig get _effectiveShift => c.effectiveConfig(widget.config.shift);

  /// The END SHIFT count inputs to render for the current mode.
  List<EndCountField> get _countFields =>
      endCountFields(_effectiveShift.endCountMode, widget.config.paymentMethods);

  /// The app-wide controller held by the session — pinned config applies
  /// everywhere (order/payment flow included), not just this screen.
  ShiftController get c => widget.session.shiftController;

  /// The shift rules the POS currently runs on. Pinned to the config the
  /// running shift started with (config change applies next day only).
  ShiftGate get gate => widget.session.gateFor(widget.config);

  /// Configured Bluetooth printers (PRD: opening shift shows the affected
  /// printers) and their honest status. Test Print stays MANUAL.
  final _bluetooth = BluetoothPrintTransport();
  final _usb = UsbPrintTransport();
  final _btStatus = <String, PrinterLink>{};
  final _usbStatus = <String, PrinterLink>{};
  String? _busyPrinterId;

  List<ClientPrinter> get _bluetoothPrinters => [
        for (final p in widget.session.printRouting?.printers ?? const <ClientPrinter>[])
          if (p.transport == 'BLUETOOTH') p,
      ];

  List<ClientPrinter> get _usbPrinters => [
        for (final p in widget.session.printRouting?.printers ?? const <ClientPrinter>[])
          if (p.transport == 'USB') p,
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

  Future<void> _checkUsb(ClientPrinter printer) async {
    setState(() => _busyPrinterId = printer.id);
    final link = await PrinterHealthChecker().check(
      transport: 'USB',
      usbVidPid: printer.usbVidPid,
      usbChip: printer.usbChip,
    );
    if (!mounted) return;
    setState(() {
      _usbStatus[printer.id] = link;
      _busyPrinterId = null;
    });
  }

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
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${printer.name}: ${link.detail}')));
  }

  /// The affected Bluetooth/USB printers with a manual Test Print (never automatic).
  List<Widget> _printerSection() {
    final printers = _bluetoothPrinters;
    final usb = _usbPrinters;
    if (printers.isEmpty && usb.isEmpty) return const [];
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
      for (final p in usb)
        UsbPrinterRow(
          printer: p,
          status: _usbStatus[p.id],
          busy: _busyPrinterId == p.id,
          onCheck: () => _checkUsb(p),
          onTest: () => _testPrintUsb(p),
        ),
    ];
  }

  @override
  void initState() {
    super.initState();
    // Seed from the controller's remembered count when a shift is already open
    // (restored), else the tenant default. The typed value lives on the
    // controller, not this disposable text field.
    final typed = c.startHousebank;
    final def = widget.config.shift.defaultHouseBank;
    _housebank.text = typed != null && typed > 0
        ? formatMoneyInput(typed)
        : (def > 0 ? formatMoneyInput(def) : '');
    // Recover a shift that is already OPEN on the server (app closed and
    // reopened) so the screen opens straight into the end-shift panel.
    c.restore();
  }

  @override
  void dispose() {
    _housebank.dispose();
    for (final ctrl in _counts.values) {
      ctrl.dispose();
    }
    super.dispose();
  }

  Future<void> _start() async {
    final ok = await c.open(
      housebank: _housebank.text.trim().isEmpty ? c.startHousebank : parseMoneyInput(_housebank.text),
      config: widget.config.shift,
    );
    if (!mounted) return;
    if (!ok) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(c.error ?? 'Could not start shift')));
    if (ok) _countFor('countedTotal').text = '0';
  }

  Future<void> _end() async {
    final mode = _effectiveShift.endCountMode;
    final fields = _countFields;
    double val(String key) => parseMoneyInput(_countFor(key).text);
    final ok = await switch (mode) {
      // ONLY_CASH: legacy single total. Empty → no-op.
      EndCountMode.onlyCash => _countFor('countedTotal').text.trim().isEmpty
          ? Future<bool>.value(false)
          : c.close(mode: mode, countedTotal: val('countedTotal')),
      EndCountMode.cashCashless => c.close(mode: mode, cash: val('cash'), cashless: val('cashless')),
      EndCountMode.crosscheckPerMethod => c.close(
          mode: mode,
          perMethod: [
            for (final f in fields)
              if (f.outletMethodId != null) {'outletMethodId': f.outletMethodId, 'counted': val(f.key)},
          ],
        ),
    };
    if (!mounted) return;
    if (!ok && c.error != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(c.error!)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: ListenableBuilder(
          listenable: c,
          builder: (_, __) =>
              Text(c.isClosed ? 'Closing report' : (c.isOpen ? gate.endLabel : gate.startLabel)),
        ),
      ),
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
        inputFormatters: const [ThousandsInputFormatter()],
        decoration: InputDecoration(labelText: 'Opening cash (total)', prefixIcon: const Icon(Icons.account_balance_wallet_outlined), prefixText: _prefixText),
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
          Text('Opening cash: ${_numStr(c.openingHousebank)}',
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
      // END SHIFT inputs: 1 (ONLY_CASH), 2 (CASH_CASHLESS), or one per ACTIVE
      // outlet method (CROSSCHECK_PER_METHOD). Labels come from the config mode.
      for (final f in _countFields) ...[
        TextField(
          controller: _countFor(f.key),
          enabled: !c.busy,
          keyboardType: TextInputType.number,
          inputFormatters: const [ThousandsInputFormatter()],
          decoration: InputDecoration(
            labelText: f.label,
            prefixIcon: const Icon(Icons.payments_outlined),
            prefixText: _prefixText,
          ),
        ),
        const SizedBox(height: 12),
      ],
      const SizedBox(height: 8),
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
            child: Text(_numStr(value),
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

  /// The currency label the server stores, as a field prefix.
  String get _prefixText {
    final l = widget.config.shift.currencyLabel.trim();
    return l.isEmpty ? '' : '$l ';
  }

  // Amounts read like everywhere else: label + grouping + 2 decimals.
  String _numStr(Object v) => money.moneyLabel(numValue(v), widget.config.shift.currencyLabel);
  static num numValue(Object v) => (v as num?) ?? 0;
}