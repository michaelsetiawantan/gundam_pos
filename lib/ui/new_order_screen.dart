import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:gundam_pos/models/config_models.dart';
import 'package:gundam_pos/state/app_session.dart';
import 'package:gundam_pos/state/order_controller.dart';
import 'package:gundam_pos/ui/order_entry_screen.dart';
import 'package:gundam_pos/ui/shift_gate.dart';
import 'package:gundam_pos/ui/theme.dart';
import 'package:gundam_pos/ui/widgets.dart';

/// P07 — New order: pick an enabled table (or free-text ≤16 if the outlet
/// allows) then set pax + guest (name/email/phone optional). The hanging check
/// runs server-side; a table with an open order here returns table_hanging.
class NewOrderScreen extends StatefulWidget {
  const NewOrderScreen({super.key, required this.session, required this.config});

  final AppSession session;
  final TenantConfig config;

  @override
  State<NewOrderScreen> createState() => _NewOrderScreenState();
}

class _NewOrderScreenState extends State<NewOrderScreen> {
  String? _tableId;
  bool _freeText = false;
  final _tableText = TextEditingController();
  final _pax = TextEditingController(text: '1');
  final _name = TextEditingController();

  @override
  void dispose() {
    _tableText.dispose();
    _pax.dispose();
    _name.dispose();
    super.dispose();
  }

  bool get _hasTable => _freeText ? _tableText.text.trim().isNotEmpty : _tableId != null;

  Future<void> _start() async {
    // Defensive: never start an order without an OPEN shift (entry point is
    // gated too, but a direct build must not be able to slip past).
    if (!await ensureShiftOpen(context, widget.session, widget.config)) return;
    if (!mounted) return;
    final name = _freeText ? _tableText.text.trim() : null;
    final id = _freeText ? null : _tableId;
    final pax = int.tryParse(_pax.text.trim()) ?? 1;
    final controller = OrderController(
      posApi: widget.session.posApi,
      tenantId: widget.session.tenantId!,
      config: widget.config,
      deviceAssetId: widget.session.context.deviceId,
      printer: widget.session.printDispatcher,
      // The session's gate: pinned shift rules (config change applies next day).
      shiftGate: widget.session.gateFor(widget.config),
      pushStore: widget.session.pushStore,
      // Client-born order numbers + the POS shortcode they embed, so an offline
      // start mints a unique local id the server accepts idempotently.
      orderNumbers: widget.session.orderNumbers,
      shortcode: widget.session.shortcode,
      // Late print warnings (captain/bev) reach the operator via the shell.
      onPrintAlerts: widget.session.notePrintAlerts,
      // Continue this order's captain batch sequence (survives merge/split).
      batchTracker: widget.session.batchTracker,
    );
    final ok = await controller.startOrder(
      tableId: id,
      tableName: name,
      guest: {'name': _name.text.trim().isEmpty ? null : _name.text.trim(), 'pax': pax},
    );
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(controller.error ?? 'Could not start order')));
      return;
    }
    Navigator.of(context).pushReplacement(MaterialPageRoute(
      builder: (_) => OrderEntryScreen(session: widget.session, controller: controller),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final tables = widget.config.tables.where((t) => t.enabled).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('New order')),
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.all(20), children: [
          const Text('Table', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: PosTheme.petrol)),
          const SizedBox(height: 10),
          Wrap(spacing: 10, runSpacing: 10, children: [
            for (final t in tables)
              ChoiceChip(
                selected: !_freeText && _tableId == t.id,
                label: Text(t.name!),
                onSelected: (_) => setState(() {
                  _freeText = false;
                  _tableId = t.id;
                }),
              ),
            ChoiceChip(
              selected: _freeText,
              avatar: const Icon(Icons.edit_outlined, size: 18),
              label: const Text('Other table'),
              onSelected: (_) => setState(() => _freeText = !_freeText),
            ),
          ]),
          if (_freeText) ...[
            const SizedBox(height: 12),
            TextField(
              controller: _tableText,
              maxLength: 16,
              // Re-evaluate the Start button as the operator types: without this
              // the button stayed disabled until they tapped "Other table" again
              // (the tap was the only setState). As long as a name is typed, the
              // order can start.
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(labelText: 'Table name', counterText: ''),
              inputFormatters: [LengthLimitingTextInputFormatter(16)],
            ),
          ],
          const SizedBox(height: 24),
          const Text('Guests', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: PosTheme.petrol)),
          const SizedBox(height: 10),
          TextField(
            controller: _pax,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(labelText: 'Pax (count)', prefixIcon: Icon(Icons.group)),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _name,
            decoration: const InputDecoration(labelText: 'Guest name (optional)', prefixIcon: Icon(Icons.person_outline)),
          ),
          const SizedBox(height: 32),
          PrimaryButton(label: 'Start order', icon: Icons.play_arrow_rounded, onPressed: _hasTable ? _start : null),
        ]),
      ),
    );
  }
}