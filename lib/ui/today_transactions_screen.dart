import 'package:flutter/material.dart';

import 'package:gundam_pos/api/api_client.dart';
import 'package:gundam_pos/logic/money.dart' as money;
import 'package:gundam_pos/state/app_session.dart';
import 'package:gundam_pos/ui/theme.dart';

/// P26 — Today's transactions. The POS only shows the current trading day
/// (past bills live in the web-app). The list is the SERVER's today feed with
/// full status — PAID / CANCELED / VOIDED / REFUNDED — so a cancelled order
/// still appears (tagged CANCELED) instead of vanishing; offline it falls back
/// to the bills settled on this tablet. Reprint/Void are offered for PAID bills
/// only. Reprint is a print-broker action; VOID is same-day only and drives the
/// same approval lifecycle as cancel/refund; a past-day refund lives in the
/// Web Past Bill.
class TodayTransactionsScreen extends StatefulWidget {
  const TodayTransactionsScreen({super.key, required this.session});

  final AppSession session;

  @override
  State<TodayTransactionsScreen> createState() => _TodayTransactionsScreenState();
}

class _TodayTransactionsScreenState extends State<TodayTransactionsScreen> with WidgetsBindingObserver {
  bool _loading = true;
  bool _serverOk = false;
  String? _offlineNote;
  DateTime? _lastSyncedAt;

  AppSession get _session => widget.session;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Auto-refresh when the screen becomes visible again (back from another
  /// screen or the app resuming) — the operator must never need the manual
  /// Refresh to see a void/decision that already landed server-side.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_loading) _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _offlineNote = null;
    });
    final rows = await _session.loadTodayOrders();
    if (!mounted) return;
    setState(() {
      _loading = false;
      _serverOk = rows != null;
      _offlineNote = rows == null ? 'No network — showing bills settled on this tablet.' : null;
      if (rows != null) _lastSyncedAt = DateTime.now();
    });
  }

  Widget _filterBar() {
    const options = [('ALL', 'All'), ('PAID', 'Paid'), ('CANCELED', 'Canceled'), ('VOIDED', 'Voided')];
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          for (final (value, label) in options)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilterChip(
                key: Key('today-filter-$value'),
                label: Text(label),
                selected: _filter == value,
                onSelected: (_) => setState(() => _filter = value),
              ),
            ),
        ]),
      ),
    );
  }

  /// Server rows when reachable; otherwise the local same-day settles, shaped
  /// into the same row keys so the list renders identically. When the server IS
  /// reachable, local settlements not yet accepted (offline/failed) are merged
  /// in so a `PAID - Offline` / `FAILED` sale is never invisible.
  List<Map<String, dynamic>> get _rows {
    if (!_serverOk) return _session.todayBills.map(_fromLocal).toList();
    final serverReceipts = {
      for (final r in _session.todayLedger) r['receiptId']?.toString() ?? '',
    };
    final localOnly = [
      for (final rec in _session.pendingSettlements)
        if (!serverReceipts.contains(rec.bill['receiptId']?.toString() ?? ''))
          _fromLocal(rec.bill),
    ];
    return [..._session.todayLedger, ...localOnly];
  }

  Map<String, dynamic> _fromLocal(Map<String, dynamic> b) {
    final key = b['clientSettlementKey']?.toString();
    final rec = key == null ? null : _session.settlementFor(key);
    final failed = rec?.failed == true;
    final offline = b['offline'] == true && !failed;
    return {
      'orderId': b['orderId'],
      'status': failed ? 'FAILED' : (offline ? 'PAID - Offline' : 'PAID'),
      'receiptId': b['receiptId'],
      'total': b['total'],
      'tableName': null,
      'paidByName': null,
      'at': b['paidAt'] ?? b['transactedAt'],
      'failureCode': rec?.errorCode,
      'clientSettlementKey': key,
      'offline': offline,
    };
  }

  bool _isPaid(Map<String, dynamic> r) {
    final s = r['status']?.toString() ?? 'PAID';
    return s == 'PAID' || s == 'PAID - Offline';
  }

  bool _isFailed(Map<String, dynamic> r) => r['status']?.toString() == 'FAILED';

  /// Dashboard filter: All / Paid / Canceled / Voided. Paid includes the
  /// offline variant; a refunded/failed row stays visible under All only.
  String _filter = 'ALL';

  bool _matchesFilter(Map<String, dynamic> r) {
    final s = r['status']?.toString() ?? 'PAID';
    return switch (_filter) {
      'PAID' => _isPaid(r),
      'CANCELED' => s == 'CANCELED',
      'VOIDED' => s == 'VOIDED',
      _ => true,
    };
  }

  /// Cancelled / voided / refunded rows are tappable: they open the trace popup
  /// (when / who asked / who authorised / why).
  bool _hasAudit(Map<String, dynamic> r) =>
      const {'CANCELED', 'VOIDED', 'REFUNDED'}.contains(r['status']?.toString() ?? '');

  static const _dash = '-';

  String _dashOr(Object? v) {
    final s = v?.toString().trim() ?? '';
    return s.isEmpty ? _dash : s;
  }

  /// The order action trace popup. Null audit fields (legacy rows, offline
  /// fallback) read as '-'; an AUTO decision shows who pressed the button and
  /// that their own role carried the right (no second approver).
  Future<void> _showAudit(BuildContext context, Map<String, dynamic> row) async {
    final status = row['status']?.toString() ?? '';
    final decision = row['statusDecision']?.toString();
    final requestedBy = _dashOr(row['statusRequestedByName']);
    final decidedBy = _dashOr(row['statusDecidedByName']);
    final authorized = decision == 'AUTO'
        ? (requestedBy == _dash ? _dash : 'Auto-approved — $requestedBy (role-nya berhak)')
        : decidedBy;
    final lines = <(String, String)>[
      ('Status', status.isEmpty ? _dash : status),
      ('Action at', _stamp(row['statusChangedAt']?.toString())),
      ('Requested by', requestedBy),
      ('Authorized by', authorized),
      ('Reason', _dashOr(row['statusReason'])),
    ];
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Transaction trace'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final (label, value) in lines)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  SizedBox(
                    width: 110,
                    child: Text(label, style: const TextStyle(color: PosTheme.slate, fontSize: 13)),
                  ),
                  Expanded(child: Text(value, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13))),
                ]),
              ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
        ],
      ),
    );
  }

  /// Full local date+time for the popup; '-' when absent.
  String _stamp(String? iso) {
    if (iso == null || iso.isEmpty) return _dash;
    final t = DateTime.tryParse(iso)?.toLocal();
    if (t == null) return _dash;
    String p(int n) => n.toString().padLeft(2, '0');
    return '${t.year}-${p(t.month)}-${p(t.day)} ${p(t.hour)}:${p(t.minute)}';
  }

  Future<void> _void(BuildContext context, Map<String, dynamic> row) async {
    final orderId = row['orderId'];
    if (orderId == null) {
      _toast(context, 'This bill has no linked order — use web-app.');
      return;
    }
    // The server sends the timestamp in UTC ISO-8601; compare in the device's
    // LOCAL zone or a bill settled at 00:02 WIB reads as 17:02 the day before
    // and same-day void wrongly refuses it.
    final paidAt = DateTime.tryParse((row['at'] ?? '').toString())?.toLocal();
    final isToday = paidAt == null || _sameDay(paidAt);
    if (!isToday) {
      _toast(context, 'This is a past-day bill — request the refund in the Web Past Bill.');
      return;
    }
    final reason = await _askReason(context);
    if (reason == null || !context.mounted) return;
    try {
      final r = await _session.posApi.requestVoid(orderId as String, reason: reason);
      if (!context.mounted) return;
      // The server AUTO-APPLIES the void when the requester's role is entitled:
      // it answers {voided:true, status:'VOIDED'} with NO `approval` block. Only
      // a below-threshold request comes back as {approval:{status:...}}. Read
      // the direct shape first, or the operator is told "pending" for a bill
      // that is already voided.
      final applied = r['voided'] == true || r['canceled'] == true || r['refunded'] == true;
      final approval = r['approval'] as Map?;
      if (applied) {
        final st = r['status']?.toString() ?? 'VOIDED';
        _toast(context, 'Void applied — the bill is now $st.');
      } else if (approval != null) {
        _toast(context, 'Void requested — approval ${approval['status'] ?? 'PENDING'}.');
      } else {
        _toast(context, 'Void requested.');
      }
      await _load(); // reflect the new status without a manual refresh
    } on PosApiException catch (e) {
      if (context.mounted) _toast(context, posErrorText('Void failed', e.code, status: e.status));
    } on PosNetworkException {
      if (context.mounted) _toast(context, 'No network — void not requested.');
    }
  }

  Future<void> _reprint(BuildContext context, Map<String, dynamic> row) async {
    final d = _session.printDispatcher;
    final receiptId = row['receiptId']?.toString();
    if (d == null || receiptId == null) {
      _toast(context, 'Reprint queued for ${row['receiptId']} — print is delivered via the print broker.');
      return;
    }
    final out = await d.reprintBill(receiptId);
    if (context.mounted) {
      _toast(context, out.alerts.isNotEmpty ? out.alerts.first : 'Reprinted $receiptId.');
    }
  }

  Future<void> _reprintCaptain(BuildContext context, Map<String, dynamic> row) async {
    final d = _session.printDispatcher;
    final receiptId = row['receiptId']?.toString();
    if (d == null || receiptId == null) {
      _toast(context, 'Captain reprint needs a same-day print record.');
      return;
    }
    final out = await d.reprintCaptain(receiptId);
    if (context.mounted) {
      _toast(context, out.alerts.isNotEmpty ? out.alerts.first : 'Captain order reprinted — no bev labels.');
    }
  }

  bool _sameDay(DateTime t) {
    final n = DateTime.now();
    return t.year == n.year && t.month == n.month && t.day == n.day;
  }

  Future<String?> _askReason(BuildContext context) {
    final c = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Void this bill?'),
        content: TextField(controller: c, autofocus: true, maxLines: 2, decoration: const InputDecoration(labelText: 'Reason')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim().isEmpty ? 'Void (POS)' : c.text.trim()), child: const Text('Request void')),
        ],
      ),
    );
  }

  void _toast(BuildContext context, String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Today's transactions"),
        actions: [IconButton(tooltip: 'Refresh', onPressed: _loading ? null : _load, icon: const Icon(Icons.refresh))],
      ),
      body: SafeArea(
        child: ListenableBuilder(
          listenable: _session,
          builder: (_, __) {
            if (_loading) return const Center(child: CircularProgressIndicator());
            final all = _rows;
            final rows = all.where(_matchesFilter).toList();
            return Column(children: [
              _summary(all),
              if (_offlineNote != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
                  child: Row(children: [
                    const Icon(Icons.cloud_off, size: 16, color: PosTheme.warn),
                    const SizedBox(width: 6),
                    Expanded(child: Text(_offlineNote!, style: const TextStyle(color: PosTheme.slate, fontSize: 13))),
                  ]),
                ),
              _filterBar(),
              const Divider(height: 1),
              Expanded(
                child: all.isEmpty
                    ? const Center(
                        child: Text('No transactions today yet.', style: TextStyle(color: PosTheme.slate, fontSize: 16)),
                      )
                    : rows.isEmpty
                        ? const Center(
                            child: Text('No transactions match this filter.', style: TextStyle(color: PosTheme.slate, fontSize: 16)),
                          )
                        : ListView.separated(
                            padding: const EdgeInsets.all(20),
                            itemCount: rows.length,
                            separatorBuilder: (_, __) => const SizedBox(height: 12),
                            itemBuilder: (_, i) => _card(context, rows[i]),
                          ),
              ),
            ]);
          },
        ),
      ),
    );
  }

  Widget _summary(List<Map<String, dynamic>> rows) {
    final paid = rows.where(_isPaid).toList();
    final net = paid.fold<num>(0, (s, r) => s + ((r['total'] as num?) ?? 0));
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 10),
      child: Row(children: [
        _metric('Paid', '${paid.length}'),
        _metric('Net collected', _amt(net)),
        _metric('Pending sync', '${_session.pendingPushCount}'),
        _metric('Last synced', _lastSyncedAt == null ? '—' : _clock(_lastSyncedAt!)),
      ]),
    );
  }

  Widget _metric(String label, String value) => Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: const TextStyle(color: PosTheme.slate, fontSize: 12)),
          const SizedBox(height: 2),
          Text(value, style: const TextStyle(color: PosTheme.petrol, fontWeight: FontWeight.w700, fontSize: 15)),
        ]),
      );

  Widget _card(BuildContext context, Map<String, dynamic> row) {
    final status = row['status']?.toString() ?? 'PAID';
    final color = _statusColor(status);
    final paid = _isPaid(row);
    final failed = _isFailed(row);
    final tappable = _hasAudit(row);
    return Card(
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: PosTheme.line)),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: tappable ? () => _showAudit(context, row) : null,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(children: [
            CircleAvatar(backgroundColor: color.withValues(alpha: 0.14), child: Icon(paid ? Icons.check : (failed ? Icons.error_outline : Icons.block), color: color)),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(row['receiptId']?.toString() ?? '—', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14, fontFamily: 'monospace')),
                const SizedBox(height: 4),
                Text(_subtitle(row), style: const TextStyle(color: PosTheme.slate, fontSize: 13)),
                const SizedBox(height: 2),
                Text(_amt(row['total']), style: const TextStyle(color: PosTheme.petrol, fontSize: 14, fontWeight: FontWeight.w600)),
                if (failed && (row['failureCode']?.toString().isNotEmpty ?? false)) ...[
                  const SizedBox(height: 4),
                  Text('Server refused: ${row['failureCode']} — commit again to resend the latest details.',
                      style: const TextStyle(color: PosTheme.danger, fontSize: 12, fontWeight: FontWeight.w600)),
                ],
              ]),
            ),
            if (tappable) ...[
              const Icon(Icons.info_outline, size: 18, color: PosTheme.slate),
              const SizedBox(width: 6),
            ],
            _tag(status, color),
            if (paid)
              PopupMenuButton<String>(
                onSelected: (v) {
                  if (v == 'reprint') _reprint(context, row);
                  if (v == 'captain') _reprintCaptain(context, row);
                  if (v == 'void') _void(context, row);
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'reprint', child: Text('Reprint')),
                  PopupMenuItem(value: 'captain', child: Text('Reprint captain order')),
                  PopupMenuItem(value: 'void', child: Text('Void (same-day)')),
                ],
              ),
            if (failed)
              PopupMenuButton<String>(
                onSelected: (v) {
                  if (v == 'retry') _retrySettlement(context, row);
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'retry', child: Text('Commit again / retry push')),
                ],
              ),
          ]),
        ),
      ),
    );
  }

  /// Re-commit a FAILED settlement: push it again under the SAME
  /// `clientSettlementKey` (idempotent — never a duplicate sale) and report the
  /// honest outcome.
  Future<void> _retrySettlement(BuildContext context, Map<String, dynamic> row) async {
    final key = row['clientSettlementKey']?.toString();
    if (key == null || key.isEmpty) {
      _toast(context, 'Nothing to resend for this row.');
      return;
    }
    final ok = await _session.recommitSettlement(key);
    if (!context.mounted) return;
    _toast(context, ok
        ? 'Settlement pushed — the bill is now PAID on the server.'
        : 'Still refused — ${_session.settlementFor(key)?.errorCode ?? 'no connection'}. Fix it and try again.');
    setState(() {});
  }

  /// "10:44 · B4 · Maya Putri" — only the parts the row actually has.
  String _subtitle(Map<String, dynamic> row) {
    final parts = <String>[
      _clockIso(row['at']?.toString()),
      if (row['tableName'] != null && row['tableName'].toString().isNotEmpty) row['tableName'].toString(),
      if (row['paidByName'] != null && row['paidByName'].toString().isNotEmpty) row['paidByName'].toString(),
      if (!_isPaid(row)) _statusLabel(row['status']?.toString() ?? ''),
    ];
    return parts.where((p) => p.isNotEmpty).join(' · ');
  }

  Widget _tag(String status, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: color),
        ),
        child: Text(status,
            style: TextStyle(color: color, fontWeight: FontWeight.w800, fontSize: 12, letterSpacing: .4)),
      );

  Color _statusColor(String s) => switch (s) {
        'PAID' => PosTheme.ok,
        'PAID - Offline' => PosTheme.warn,
        'FAILED' => PosTheme.danger,
        'CANCELED' => PosTheme.warn,
        'VOIDED' => PosTheme.danger,
        'REFUNDED' => PosTheme.petrol,
        _ => PosTheme.slate,
      };

  String _statusLabel(String s) => switch (s) {
        'CANCELED' => 'cancelled',
        'VOIDED' => 'voided',
        'REFUNDED' => 'refunded',
        'FAILED' => 'failed — not synced',
        _ => s.toLowerCase(),
      };

  String _clock(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';

  String _clockIso(String? iso) {
    if (iso == null || iso.isEmpty) return '';
    final t = DateTime.tryParse(iso)?.toLocal();
    if (t == null) return '';
    return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  }

  String _amt(Object? v) => money.moneyLabel((v as num?) ?? 0, _label);

  String get _label => _session.config?.shift.currencyLabel ?? '';
}
