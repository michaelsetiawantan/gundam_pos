import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:gundam_pos/services/diagnostic_report.dart';
import 'package:gundam_pos/state/app_session.dart';
import 'package:gundam_pos/ui/theme.dart';

/// 'Device log' — the in-app diagnostic stream made VISIBLE on the tablet
/// (time, level, tag, message), newest first, filterable by level, with a Copy
/// action and a 'Send to server' button that ships the same bundle the
/// diagnostics path uses. Not realtime: it loads on open and on Refresh.
class DeviceLogScreen extends StatefulWidget {
  const DeviceLogScreen({super.key, required this.session});

  final AppSession session;

  @override
  State<DeviceLogScreen> createState() => _DeviceLogScreenState();
}

class _DeviceLogScreenState extends State<DeviceLogScreen> {
  String? _levelFilter; // null = all
  List<LogLine> _lines = const [];
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    final all = widget.session.diagnostics.snapshot().toList().reversed.toList(); // newest first
    setState(() {
      _lines = _levelFilter == null ? all : [for (final l in all) if (l.level == _levelFilter) l];
    });
  }

  int get _errorCount => _lines.where((l) => l.level == 'error').length;
  int get _warnCount => _lines.where((l) => l.level == 'warn').length;

  String _lineText(LogLine l) {
    final t = l.at.toIso8601String();
    final ts = t.length >= 19 ? t.substring(11, 19) : t;
    return '$ts [${l.level.toUpperCase()}] ${l.tag}${l.fromPreviousSession ? ' (prior session)' : ''}: ${l.message}';
  }

  Future<void> _copyAll() async {
    final body = _lines.isEmpty ? '(no log lines)' : _lines.map(_lineText).join('\n');
    await Clipboard.setData(ClipboardData(text: body));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Copied ${_lines.length} log line(s) to the clipboard.')),
    );
  }

  /// Auto-fill the description from the visible stream so the operator does not
  /// have to type one, then reuse the existing durable send path.
  Future<void> _send() async {
    setState(() => _sending = true);
    final desc = 'Device log export · $_errorCount error, $_warnCount warn line(s)'
        '${_levelFilter == null ? '' : ' · filter=$_levelFilter'}';
    final res = await widget.session.sendDiagnostics(description: desc);
    if (!mounted) return;
    setState(() => _sending = false);
    final why = widget.session.lastDiagnosticFailure;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(res.sent > 0
          ? 'Device log sent to the server.'
          : 'Report queued (${res.pending} pending)${why == null ? '' : ' — $why'}. It retries on the next sync.'),
    ));
  }

  Color _levelColor(String level) => switch (level) {
        'error' => PosTheme.danger,
        'warn' => Colors.orange.shade800,
        'debug' => PosTheme.slate,
        _ => PosTheme.petrol,
      };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Device log'),
        actions: [IconButton(onPressed: _reload, icon: const Icon(Icons.refresh), tooltip: 'Refresh')],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Row(children: [
              Expanded(
                child: Text(
                  '${_lines.length} line(s) · $_errorCount error, $_warnCount warn',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              OutlinedButton.icon(
                onPressed: _lines.isEmpty ? null : _copyAll,
                icon: const Icon(Icons.copy, size: 18),
                label: const Text('Copy'),
              ),
            ]),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: _sending ? null : _send,
              icon: _sending
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.send, size: 18),
              label: const Text('Send to server'),
            ),
            const SizedBox(height: 8),
            const Text(
              'The most recent app log lines (warnings and errors from this and the previous session). '
              'Send to server bundles them with the device context and print summary; offline it is queued for the next sync.',
              style: TextStyle(color: PosTheme.slate, fontSize: 12),
            ),
            const SizedBox(height: 12),
            Wrap(spacing: 8, children: [
              for (final lvl in const [null, 'debug', 'info', 'warn', 'error'])
                ChoiceChip(
                  label: Text(lvl ?? 'All'),
                  selected: _levelFilter == lvl,
                  onSelected: (_) {
                    _levelFilter = lvl;
                    _reload();
                  },
                ),
            ]),
            const SizedBox(height: 8),
            if (_lines.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Text('No log lines recorded.', style: TextStyle(color: PosTheme.slate)),
              )
            else
              for (final l in _lines)
                Card(
                  margin: const EdgeInsets.only(bottom: 6),
                  child: ListTile(
                    dense: true,
                    leading: Text(l.level.toUpperCase(),
                        style: TextStyle(color: _levelColor(l.level), fontWeight: FontWeight.w800, fontSize: 11)),
                    title: Text(l.message),
                    subtitle: Text('${l.at.toIso8601String().substring(11, 19)} · ${l.tag}'
                        '${l.fromPreviousSession ? ' · prior session' : ''}'),
                  ),
                ),
          ],
        ),
      ),
    );
  }
}
