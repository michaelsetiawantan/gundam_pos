import 'package:flutter/material.dart';

import 'package:gundam_pos/services/print_routing.dart';
import 'package:gundam_pos/services/printer_health.dart';
import 'package:gundam_pos/ui/theme.dart';

/// Honest per-printer status chip — the PRD §4.28 status set, rendered the same
/// way on the shift and More surfaces.
class PrinterResultCard extends StatelessWidget {
  const PrinterResultCard({super.key, required this.link});

  final PrinterLink link;

  @override
  Widget build(BuildContext context) {
    final (color, label) = switch (link.state) {
      PrinterLinkState.ready => (PosTheme.ok, 'Ready'),
      PrinterLinkState.offline => (PosTheme.danger, 'Offline'),
      PrinterLinkState.unsupported => (PosTheme.warn, 'Unsupported'),
      PrinterLinkState.notPaired => (PosTheme.warn, 'Not paired'),
      PrinterLinkState.bluetoothOff => (PosTheme.warn, 'Bluetooth off'),
      PrinterLinkState.permissionRequired => (PosTheme.warn, 'Permission required'),
      PrinterLinkState.disconnected => (PosTheme.danger, 'Disconnected'),
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

/// One configured Bluetooth printer with its honest status and a MANUAL Test
/// Print button (never an automatic test).
class BluetoothPrinterRow extends StatelessWidget {
  const BluetoothPrinterRow({
    super.key,
    required this.printer,
    required this.status,
    required this.busy,
    required this.onCheck,
    required this.onTest,
    this.showCheck = true,
  });

  final ClientPrinter printer;
  final PrinterLink? status;
  final bool busy;
  final VoidCallback onCheck;
  final VoidCallback onTest;
  final bool showCheck;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: PosTheme.mist, borderRadius: BorderRadius.circular(10), border: Border.all(color: PosTheme.line)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('${printer.name}  ·  ${printer.bluetoothMac ?? 'no MAC'}',
            style: const TextStyle(fontWeight: FontWeight.w700)),
        if (status != null) ...[
          const SizedBox(height: 8),
          PrinterResultCard(link: status!),
        ],
        const SizedBox(height: 8),
        Row(children: [
          if (showCheck) ...[
            OutlinedButton(onPressed: busy ? null : onCheck, child: const Text('Check status')),
            const SizedBox(width: 10),
          ],
          FilledButton(onPressed: busy ? null : onTest, child: const Text('Test print')),
        ]),
      ]),
    );
  }
}
