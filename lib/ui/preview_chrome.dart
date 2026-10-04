import 'package:flutter/material.dart';

import 'package:gundam_pos/logic/print_format_render.dart';
import 'package:gundam_pos/ui/theme.dart';

/// Shared chrome for every printout preview (bill, captain order): 58/80 mm
/// toggle, an honest fallback notice, a "which layout was used" line, the
/// monospace ticket body and a footer. ONE implementation so the two previews
/// cannot drift apart in look or in what they tell the operator.
///
/// Keys are derived from [prefix] (`<prefix>-preview-text`, …) so each screen
/// keeps stable, testable keys.
class PreviewChrome extends StatelessWidget {
  const PreviewChrome({
    super.key,
    required this.prefix,
    required this.title,
    required this.ticketLabel,
    required this.widthMm,
    required this.onWidthChanged,
    required this.text,
    required this.usedServerFormat,
    required this.footer,
    this.notice,
  });

  final String prefix;
  final String title;

  /// Human ticket name used in the source line ("BILL", "CAPTAIN_ORDER").
  final String ticketLabel;
  final int widthMm;
  final ValueChanged<int> onWidthChanged;
  final String text;
  final bool usedServerFormat;
  final String footer;
  final String? notice;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(children: [
            SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 58, label: Text('58 mm')),
                ButtonSegment(value: 80, label: Text('80 mm')),
              ],
              selected: {widthMm},
              onSelectionChanged: (s) => onWidthChanged(s.first),
            ),
            const Spacer(),
            Text('${cellsForWidthMm(widthMm)} columns',
                style: const TextStyle(color: PosTheme.slate, fontSize: 12)),
          ]),
        ),
        if (notice != null && notice!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: Text(notice!,
                key: Key('$prefix-preview-notice'),
                style: const TextStyle(color: PosTheme.slate, fontSize: 12)),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
          child: Text(
            usedServerFormat
                ? 'Rendered with the outlet $ticketLabel format from the server.'
                : 'Rendered with the built-in $ticketLabel layout.',
            key: Key('$prefix-preview-source'),
            style: const TextStyle(color: PosTheme.slate, fontSize: 12),
          ),
        ),
        Expanded(
          child: Container(
            margin: const EdgeInsets.all(16),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: PosTheme.line),
              borderRadius: BorderRadius.circular(10),
            ),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SingleChildScrollView(
                child: SelectableText(
                  text,
                  key: Key('$prefix-preview-text'),
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 13,
                    height: 1.35,
                    color: PosTheme.ink,
                  ),
                ),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Text(footer,
              key: Key('$prefix-preview-note'),
              style: const TextStyle(color: PosTheme.slate, fontSize: 12)),
        ),
      ]),
    );
  }
}
