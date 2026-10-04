import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:gundam_pos/data/print_log_store.dart';
import 'package:gundam_pos/services/diagnostic_report.dart';
import 'package:gundam_pos/services/print_log.dart';
import 'package:gundam_pos/state/app_session.dart';
import 'package:gundam_pos/ui/theme.dart';

/// 'Print diagnostics' — the local print-attempt audit, newest first, with
/// filters, per-outcome counts, a detail view (error detail, warnings, dialect /
/// code-page + fallback info, bounded rendered text), a retry-upload action and
/// a copy/share action so a technician can forward one entry.
class PrintDiagnosticsScreen extends StatefulWidget {
  const PrintDiagnosticsScreen({super.key, required this.session});

  final AppSession session;

  @override
  State<PrintDiagnosticsScreen> createState() => _PrintDiagnosticsScreenState();
}

class _PrintDiagnosticsScreenState extends State<PrintDiagnosticsScreen> {
  String? _outcomeFilter;
  String? _ticketFilter;
  Duration? _ageFilter;
  List<PrintLogRow> _rows = const [];
  Map<String, int> _counts = const {};
  bool _loading = true;
  bool _uploading = false;
  final TextEditingController _description = TextEditingController();
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _reload();
    widget.session.refreshDiagnosticPending();
  }

  @override
  void dispose() {
    _description.dispose();
    super.dispose();
  }

  /// Collect one bundle (device context + print summary + recent log lines +
  /// this description) and ship it. Offline it is queued in the outbox and goes
  /// on the next sync — never lost.
  Future<void> _sendDiagnostics() async {
    final desc = _description.text.trim();
    if (desc.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Describe the issue in a few words before sending.')),
      );
      return;
    }
    setState(() => _sending = true);
    final res = await widget.session.sendDiagnostics(description: desc);
    if (!mounted) return;
    setState(() => _sending = false);
    if (res.sent > 0) _description.clear();
    final why = widget.session.lastDiagnosticFailure;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(res.sent > 0
          ? 'Diagnostic report sent to the server.'
          : 'Report queued (${res.pending} pending)'
              '${why == null ? '' : ' — $why'}. It retries on the next sync.'),
    ));
  }

  Future<void> _reload() async {
    setState(() => _loading = true);
    final store = widget.session.printLogs;
    final filter = PrintLogFilter(
      outcome: _outcomeFilter,
      ticketType: _ticketFilter,
      since: _ageFilter == null ? null : DateTime.now().subtract(_ageFilter!),
    );
    final rows = await store.list(filter: filter, limit: 200);
    final counts = await store.outcomeCounts();
    await widget.session.refreshPrintLogPending();
    if (!mounted) return;
    setState(() {
      _rows = rows;
      _counts = counts;
      _loading = false;
    });
  }

  Future<void> _retryUpload() async {
    setState(() => _uploading = true);
    await widget.session.uploadPrintLogs();
    if (!mounted) return;
    setState(() => _uploading = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(_uploadMessage(widget.session.lastPrintLogUpload)),
    ));
    await _reload();
  }

  /// Honest result text. Never confuses a server rejection or an unreachable
  /// server with the *printer* being offline — this uploads log rows over HTTP,
  /// it has nothing to do with printer connectivity.
  String _uploadMessage(PrintLogUploadResult? res) {
    final pending = widget.session.printLogPending;
    if (res == null) {
      return pending == 0
          ? 'Nothing to upload — no print logs are pending.'
          : 'Upload did not run — re-activate or re-login this tablet, then retry. $pending print log(s) still queued.';
    }
    if (res.remaining == 0 && res.uploaded == 0 && res.failed == 0) {
      return 'Nothing to upload — no print logs are pending.';
    }
    if (res.offline) {
      return 'Could not reach the server — ${res.remaining} print log(s) still queued. '
          'They upload automatically on the next sync. (This is a server/network issue, not the printer.)';
    }
    if (res.failed > 0) {
      final why = res.rejectedCodes.isEmpty ? 'server rejected them' : 'rejected: ${res.rejectedCodes.join(', ')}';
      return '${res.uploaded} uploaded, ${res.failed} $why. ${res.remaining} still queued.';
    }
    return res.remaining == 0
        ? '${res.uploaded} print log(s) uploaded. Queue is empty.'
        : '${res.uploaded} print log(s) uploaded — ${res.remaining} still queued.';
  }

  String _entryText(PrintLogRow r) {
    final buf = StringBuffer()
      ..writeln('Print log ${r.clientLogId}')
      ..writeln('${r.outcome} · ${r.ticketType} · ${r.printerName ?? r.printerId ?? '(no printer)'} '
          '(${r.printerTransport ?? 'n/a'})')
      ..writeln('attempts: ${r.attemptCount}  duration: ${r.durationMs ?? '-'}ms  bytes: ${r.byteLength ?? '-'}')
      ..writeln('dialect: ${r.dialectCode ?? '-'}${r.dialectFallback ? ' (fallback)' : ''}  codePage: ${r.codePageCode ?? '-'}');
    if (r.errorCode != null) buf.writeln('error: ${r.errorCode} — ${r.errorDetail ?? ''}');
    if (r.warnings.isNotEmpty) {
      buf.writeln('warnings:');
      for (final w in r.warnings) {
        buf.writeln('  - $w');
      }
    }
    if (r.renderedText != null) {
      buf.writeln('--- rendered text (bounded) ---');
      buf.writeln(r.renderedText);
    }
    return buf.toString();
  }

  Future<void> _copy(PrintLogRow r) async {
    await Clipboard.setData(ClipboardData(text: _entryText(r)));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Entry copied to the clipboard.')));
  }

  void _openDetail(PrintLogRow r) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${r.outcome} · ${r.ticketType}'),
        content: SingleChildScrollView(child: SelectableText(_entryText(r))),
        actions: [
          TextButton(onPressed: () => _copy(r), child: const Text('Copy / share entry')),
          FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
        ],
      ),
    );
  }

  Color _outcomeColor(String outcome) => switch (outcome) {
        kOutcomeOk => PosTheme.petrol,
        kOutcomeFallback => Colors.orange.shade800,
        _ => PosTheme.danger,
      };

  @override
  Widget build(BuildContext context) {
    final ticketTypes = {for (final r in _rows) r.ticketType}.toList()..sort();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Print diagnostics'),
        actions: [IconButton(onPressed: _reload, icon: const Icon(Icons.refresh), tooltip: 'Reload')],
      ),
      body: SafeArea(
        child: ListenableBuilder(
          listenable: widget.session,
          builder: (_, __) => ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _card(
                title: 'Upload',
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Pending upload: ${widget.session.printLogPending} of ${_counts.values.fold<int>(0, (a, b) => a + b)} local row(s)',
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  const Text('Rows upload to the server (POST /api/pos/print-logs) in id-keyed batches — '
                      'this is a server upload, unrelated to printer connectivity. Nothing is lost while the network is down.',
                      style: TextStyle(color: PosTheme.slate, fontSize: 12)),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: _uploading ? null : _retryUpload,
                    icon: _uploading
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.cloud_upload),
                    label: const Text('Retry upload'),
                  ),
                ]),
              ),
              _card(
                title: 'Report issue to server',
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Pending diagnostic reports: ${widget.session.diagnosticPending}',
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  const Text('Bundles the device context, the print-log summary and recent app log lines with your note, then ships it to the super-admin for analysis. Offline, it is queued and sent on the next sync.',
                      style: TextStyle(color: PosTheme.slate, fontSize: 12)),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _description,
                    maxLength: kDiagMaxDescriptionLen,
                    minLines: 2,
                    maxLines: 4,
                    decoration: const InputDecoration(
                      labelText: 'What went wrong?',
                      hintText: 'e.g. Kitchen printer prints blank tickets since this morning.',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  FilledButton.icon(
                    onPressed: _sending ? null : _sendDiagnostics,
                    icon: _sending
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.send),
                    label: const Text('Send diagnostics'),
                  ),
                ]),
              ),
              _card(
                title: 'Summary',
                child: Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final outcome in kPrintOutcomes)
                    Chip(
                      backgroundColor: _outcomeColor(outcome).withValues(alpha: 0.12),
                      label: Text('$outcome: ${_counts[outcome] ?? 0}'),
                    ),
                ]),
              ),
              _card(
                title: 'Filters',
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  _dropdown<String?>(
                    label: 'Outcome',
                    value: _outcomeFilter,
                    items: [null, ...kPrintOutcomes],
                    labelOf: (v) => v ?? 'All',
                    onChanged: (v) {
                      _outcomeFilter = v;
                      _reload();
                    },
                  ),
                  _dropdown<String?>(
                    label: 'Ticket type',
                    value: _ticketFilter,
                    items: [null, ...ticketTypes],
                    labelOf: (v) => v ?? 'All',
                    onChanged: (v) {
                      _ticketFilter = v;
                      _reload();
                    },
                  ),
                  _dropdown<Duration?>(
                    label: 'Date',
                    value: _ageFilter,
                    items: const [null, Duration(days: 1), Duration(days: 7), Duration(days: 30)],
                    labelOf: (v) => v == null
                        ? 'All'
                        : v.inDays == 1
                            ? 'Today'
                            : 'Last ${v.inDays} days',
                    onChanged: (v) {
                      _ageFilter = v;
                      _reload();
                    },
                  ),
                ]),
              ),
              if (_loading)
                const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
              else if (_rows.isEmpty)
                const Padding(padding: EdgeInsets.all(24), child: Text('No print attempts recorded.', style: TextStyle(color: PosTheme.slate)))
              else
                for (final r in _rows) _row(r),
            ],
          ),
        ),
      ),
    );
  }

  Widget _row(PrintLogRow r) => Card(
        margin: const EdgeInsets.only(bottom: 8),
        child: ListTile(
          onTap: () => _openDetail(r),
          leading: CircleAvatar(
            backgroundColor: _outcomeColor(r.outcome).withValues(alpha: 0.15),
            child: Text(r.outcome.substring(0, 1), style: TextStyle(color: _outcomeColor(r.outcome), fontWeight: FontWeight.w800)),
          ),
          title: Text('${r.ticketType} · ${r.printerName ?? '(no printer)'}'),
          subtitle: Text([
            r.outcome,
            if (r.errorCode != null) r.errorCode!,
            if (r.warnings.isNotEmpty) '${r.warnings.length} warning(s)',
            r.uploadState == kPrintLogSent ? 'sent' : 'pending upload',
          ].join(' · ')),
          trailing: Text(r.createdAt.toIso8601String().substring(11, 19), style: const TextStyle(color: PosTheme.slate, fontSize: 12)),
        ),
      );

  Widget _card({required String title, required Widget child}) => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: PosTheme.line),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w800, color: PosTheme.petrol)),
          const SizedBox(height: 10),
          child,
        ]),
      );

  Widget _dropdown<T>({
    required String label,
    required T value,
    required List<T> items,
    required String Function(T) labelOf,
    required void Function(T) onChanged,
  }) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: InputDecorator(
          decoration: InputDecoration(labelText: label, isDense: true, border: const OutlineInputBorder()),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<T>(
              isExpanded: true,
              value: value,
              items: [for (final i in items) DropdownMenuItem<T>(value: i, child: Text(labelOf(i)))],
              onChanged: (v) => onChanged(v as T),
            ),
          ),
        ),
      );
}
