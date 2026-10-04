import 'dart:convert';

import 'package:flutter/material.dart';

import 'package:gundam_pos/api/api_client.dart';
import 'package:gundam_pos/logic/discount_voucher.dart' as dv;
import 'package:gundam_pos/logic/money.dart' as money;
import 'package:gundam_pos/state/app_session.dart';
import 'package:gundam_pos/ui/theme.dart';

/// P27 — Approvals. The POS decides the PENDING cancel/void/refund/discount
/// requests raised while the requester's role was below the approval threshold.
/// TIP approval is WEB-ONLY and is filtered out here (the server still lists
/// it for the web queues). The server is the authority: the list is group-scoped
/// (403 for a role without an approval capability) and the decide route re-checks
/// the caller's power on every action. Nothing is applied optimistically — after
/// a decision the list is re-pulled from the server.
///
/// Each row shows what an operator understands: the action, the TABLE, the
/// discount amount (DISCOUNT), who asked, when, and the plain reason (the
/// `::{...}` JSON payload the server tucks onto the reason is stripped here).
///
/// When the CURRENT session may not decide, the Approve (or Reject) action asks
/// for the username + password of a user who may. Wrong credentials keep the
/// dialog open and ask again; a correct pair applies the decision. Passwords are
/// never stored or logged.
class ApprovalsScreen extends StatefulWidget {
  const ApprovalsScreen({super.key, required this.session});

  final AppSession session;

  @override
  State<ApprovalsScreen> createState() => _ApprovalsScreenState();
}

/// Outcome of one decide attempt.
enum _DecideKind { ok, denied, invalidCredential, already, network, failed, cancelled }

class _ApprovalsScreenState extends State<ApprovalsScreen> with WidgetsBindingObserver {
  /// Client-side action-type filter. Tip is deliberately absent.
  static const _filters = <String, String>{
    'ALL': 'All',
    'CANCEL': 'Cancel',
    'CANCEL_ORDER': 'Cancel order',
    'CANCEL_ITEM': 'Cancel item',
    'VOID': 'Void',
    'REFUND': 'Refund',
    'DISCOUNT': 'Discount',
  };

  bool _loading = true;
  String? _error; // friendly message; never a dead-end (Retry stays available)
  DateTime? _lastSyncedAt;
  List<Map<String, dynamic>> _rows = const [];
  String _filter = 'ALL';

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

  /// Auto-refresh on resume so a decision made elsewhere (or a request raised
  /// while the screen was backgrounded) shows without the manual Refresh.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_loading) _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final tenantId = _session.tenantId;
    if (tenantId == null) {
      setState(() {
        _loading = false;
        _error = 'This device is not bound to an outlet yet.';
      });
      return;
    }
    try {
      final r = await _session.posApi
          .listApprovals(tenantId: tenantId, status: 'PENDING', perPage: 100);
      final raw = (r['approvals'] ?? r['rows']) as List? ?? const [];
      final rows = raw
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .where((a) => !_isTip(a))
          .toList();
      if (!mounted) return;
      setState(() {
        _loading = false;
        _rows = rows;
        _lastSyncedAt = DateTime.now();
      });
    } on PosApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.status == 403
            ? 'Your role is not allowed to decide approvals.'
            : posErrorText('Could not load approvals', e.code, status: e.status);
      });
    } on PosNetworkException {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'No network — could not load approvals.';
      });
    }
  }

  /// Confirm, then decide with the current session; on a 403 open the delegation
  /// dialog so an authorised user can approve/reject with their own credentials.
  Future<void> _decide(Map<String, dynamic> row, String state) async {
    final id = row['id']?.toString();
    if (id == null) return;
    final approved = state == 'APPROVED';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(approved ? 'Approve this request?' : 'Reject this request?'),
        content: Text('${_actionType(row)} · ${_requester(row)}'
            '${_reason(row).isEmpty ? '' : '\n${_reason(row)}'}'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: approved
                ? null
                : FilledButton.styleFrom(backgroundColor: PosTheme.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(approved ? 'Confirm approve' : 'Confirm reject'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    var res = await _tryDecide(id, state: state);
    if (res.kind == _DecideKind.denied) {
      // The current session may not decide: ask for an authorised user.
      res = await _authoriseAndDecide(id, state: state);
    }
    if (!mounted) return;
    if (res.kind == _DecideKind.ok) {
      _toast(approved ? 'Approved.' : 'Rejected.');
      await _load();
    } else if (res.kind == _DecideKind.already) {
      _toast('Already decided — refreshing.');
      await _load();
    } else if (res.kind == _DecideKind.network) {
      _toast('No network — nothing was decided.');
    } else if (res.kind == _DecideKind.failed) {
      _toast(res.message ?? 'Action failed.');
    } else if (res.kind == _DecideKind.denied) {
      _toast('Your role is not allowed to decide approvals.');
    }
    // invalidCredential / cancelled: the dialog already explained or the user
    // cancelled — nothing more to say here.
  }

  /// Endless-until-success credential flow: ask for a username + password, try
  /// the decide, and ask again on a 401/403 (never a dead-end). Only a cancel
  /// stops the loop.
  Future<_DecideOutcome> _authoriseAndDecide(String id, {required String state}) async {
    String? errorMsg;
    while (mounted) {
      final creds = await _askCredentials(message: errorMsg);
      if (creds == null) return const _DecideOutcome(_DecideKind.cancelled);
      final res = await _tryDecide(id, state: state, email: creds.$1, password: creds.$2);
      if (res.kind == _DecideKind.ok) return res;
      if (res.kind == _DecideKind.invalidCredential || res.kind == _DecideKind.denied) {
        errorMsg = 'Invalid username or password, or that user is not allowed to decide. Try again.';
        continue; // reopen the dialog with the message
      }
      return res; // already/network/failed → stop and report
    }
    return const _DecideOutcome(_DecideKind.cancelled);
  }

  Future<(String, String)?> _askCredentials({String? message}) =>
      showDialog<(String, String)>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _CredentialDialog(message: message),
      );

  Future<_DecideOutcome> _tryDecide(
    String id, {
    required String state,
    String? email,
    String? password,
  }) async {
    try {
      await _session.posApi.decideApproval(
        id,
        state: state,
        approverEmail: email,
        approverPassword: password,
      );
      return const _DecideOutcome(_DecideKind.ok);
    } on PosApiException catch (e) {
      if (e.status == 401 && e.code == 'invalid_credentials') {
        return const _DecideOutcome(_DecideKind.invalidCredential);
      }
      if (e.status == 403) return const _DecideOutcome(_DecideKind.denied);
      if (e.code == 'already_decided') return const _DecideOutcome(_DecideKind.already);
      return _DecideOutcome(
        _DecideKind.failed,
        posErrorText(state == 'APPROVED' ? 'Approve failed' : 'Reject failed', e.code, status: e.status),
      );
    } on PosNetworkException {
      return const _DecideOutcome(_DecideKind.network);
    }
  }

  // ------------------------------------------------------------- helpers --
  bool _isTip(Map<String, dynamic> a) =>
      (a['actionType']?.toString().toUpperCase() ?? '').startsWith('TIP');

  String _actionType(Map<String, dynamic> a) => a['actionType']?.toString() ?? '—';

  String _requester(Map<String, dynamic> a) {
    final r = a['requester'];
    if (r is Map) return (r['fullName'] ?? r['name'] ?? '—').toString();
    return '—';
  }

  /// Reason text with the server's `::{...}` payload suffix stripped, so only
  /// the human reason is shown. Plain reasons (no suffix) pass through unchanged.
  String _reason(Map<String, dynamic> a) {
    final raw = a['reason']?.toString() ?? '';
    final i = raw.lastIndexOf('::');
    if (i < 0) return raw.trim();
    final suffix = raw.substring(i + 2).trim();
    if (suffix.startsWith('{') && suffix.endsWith('}')) return raw.substring(0, i).trim();
    return raw.trim();
  }

  /// Decode the `::{json}` payload the server tucks onto a reason (or null).
  Map<String, dynamic>? _reasonPayload(Map<String, dynamic> a) {
    final raw = a['reason']?.toString() ?? '';
    final i = raw.lastIndexOf('::');
    if (i < 0) return null;
    try {
      final d = jsonDecode(raw.substring(i + 2).trim());
      return d is Map ? Map<String, dynamic>.from(d) : null;
    } catch (_) {
      return null;
    }
  }

  /// Which table the request is about: the order's table name, else its tableId,
  /// else the transaction receipt id, else a dash.
  String _table(Map<String, dynamic> a) {
    final o = a['order'];
    if (o is Map) {
      final tn = o['tableName']?.toString().trim() ?? '';
      if (tn.isNotEmpty) return tn;
      final tid = o['tableId']?.toString().trim() ?? '';
      if (tid.isNotEmpty) return tid;
    }
    final t = a['transaction'];
    if (t is Map) {
      final rid = t['receiptId']?.toString() ?? '';
      if (rid.isNotEmpty) return rid;
    }
    return '—';
  }

  /// Amount label for a DISCOUNT request resolved against LOCAL masters, e.g.
  /// `Happy Hour · 10%` or `Rp 5.000`. A missing master id (or no config) → '-'.
  String _amountLabel(Map<String, dynamic> a) {
    if (_actionType(a) != 'DISCOUNT') return '';
    final p = _reasonPayload(a);
    final cfg = _session.config;
    if (p == null || cfg == null) return '-';
    final did = p['discountId']?.toString();
    if (did != null && did.isNotEmpty && did != 'null') {
      final d = _firstWhereOrNull(cfg.discounts, (x) => x.id == did);
      if (d != null) return _masterLabel(d.name, d.kind, d.value);
    }
    final vid = p['voucherId']?.toString();
    if (vid != null && vid.isNotEmpty && vid != 'null') {
      final v = _firstWhereOrNull(cfg.vouchers, (x) => x.id == vid);
      if (v != null) return 'Voucher · ${_masterLabel(v.name, v.kind, v.value)}';
    }
    return '-';
  }

  String _masterLabel(String name, dv.PricingKind kind, double value) {
    final amt = kind == dv.PricingKind.percentage
        ? '${_trim(value)}%'
        : money.moneyLabel(value, _currencyLabel());
    return name.trim().isEmpty ? amt : '$name · $amt';
  }

  String _currencyLabel() {
    final c = _session.config?.shift.currencyLabel ?? '';
    return c.trim().isEmpty ? 'Rp' : c;
  }

  String _trim(double v) => v.truncateToDouble() == v ? v.toInt().toString() : v.toString();


  String _when(Map<String, dynamic> a) {
    final t = DateTime.tryParse(a['createdAt']?.toString() ?? '');
    if (t == null) return '—';
    final l = t.toLocal();
    String two(int v) => v < 10 ? '0$v' : '$v';
    return '${two(l.hour)}:${two(l.minute)} · ${l.year}-${two(l.month)}-${two(l.day)}';
  }

  List<Map<String, dynamic>> get _filtered => _filter == 'ALL'
      ? _rows
      : _rows.where((a) => _actionType(a) == _filter).toList();

  void _toast(String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Approvals'),
        actions: [
          IconButton(tooltip: 'Refresh', onPressed: _loading ? null : _load, icon: const Icon(Icons.refresh)),
        ],
      ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? _errorView(_error!)
                : _listView(),
      ),
    );
  }

  Widget _errorView(String message) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.lock_outline, size: 40, color: PosTheme.warn),
              const SizedBox(height: 14),
              Text(message, textAlign: TextAlign.center, style: const TextStyle(color: PosTheme.ink, fontSize: 16)),
              const SizedBox(height: 18),
              OutlinedButton.icon(onPressed: _load, icon: const Icon(Icons.refresh), label: const Text('Retry')),
            ],
          ),
        ),
      );

  Widget _listView() {
    final rows = _filtered;
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Wrap(
          spacing: 8,
          children: _filters.entries
              .map((e) => ChoiceChip(
                    label: Text(e.value),
                    selected: _filter == e.key,
                    onSelected: (_) => setState(() => _filter = e.key),
                  ))
              .toList(),
        ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: Row(children: [
          const Icon(Icons.schedule, size: 14, color: PosTheme.slate),
          const SizedBox(width: 6),
          Text('Last synced: ${_clock(_lastSyncedAt)}',
              style: const TextStyle(color: PosTheme.slate, fontSize: 12)),
        ]),
      ),
      const Divider(height: 1),
      Expanded(
        child: rows.isEmpty
            ? const Center(
                child: Text('No pending approvals.',
                    style: TextStyle(color: PosTheme.slate, fontSize: 16)),
              )
            : ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: rows.length,
                separatorBuilder: (_, __) => const SizedBox(height: 12),
                itemBuilder: (_, i) => _card(rows[i]),
              ),
      ),
    ]);
  }

  Widget _card(Map<String, dynamic> a) {
    final action = _actionType(a);
    final color = switch (action) {
      'VOID' => PosTheme.danger,
      'CANCEL_ORDER' => PosTheme.danger,
      'CANCEL_ITEM' => PosTheme.warn,
      'REFUND' => PosTheme.petrol,
      'DISCOUNT' => PosTheme.warn,
      _ => PosTheme.ok,
    };
    final amount = _amountLabel(a);
    return Card(
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: PosTheme.line)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: color),
              ),
              child: Text(action,
                  style: TextStyle(color: color, fontWeight: FontWeight.w800, fontSize: 12, letterSpacing: .4)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text('Table ${_table(a)}',
                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
            ),
            Text(_when(a), style: const TextStyle(color: PosTheme.slate, fontSize: 12)),
          ]),
          if (amount.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(amount, style: const TextStyle(color: PosTheme.ink, fontWeight: FontWeight.w800, fontSize: 15)),
          ],
          const SizedBox(height: 10),
          Row(children: [
            const Icon(Icons.person_outline, size: 15, color: PosTheme.slate),
            const SizedBox(width: 6),
            Expanded(
              child: Text('Requested by ${_requester(a)}',
                  style: const TextStyle(color: PosTheme.ink, fontWeight: FontWeight.w600, fontSize: 14)),
            ),
          ]),
          if (_reason(a).isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(_reason(a), style: const TextStyle(color: PosTheme.slate, fontSize: 13)),
          ],
          const SizedBox(height: 12),
          Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            OutlinedButton(
              style: OutlinedButton.styleFrom(foregroundColor: PosTheme.danger),
              onPressed: () => _decide(a, 'REJECTED'),
              child: const Text('Reject'),
            ),
            const SizedBox(width: 10),
            FilledButton(
              onPressed: () => _decide(a, 'APPROVED'),
              child: const Text('Approve'),
            ),
          ]),
        ]),
      ),
    );
  }

  String _clock(DateTime? t) {
    if (t == null) return '—';
    String two(int v) => v < 10 ? '0$v' : '$v';
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }
}

class _DecideOutcome {
  const _DecideOutcome(this.kind, [this.message]);
  final _DecideKind kind;
  final String? message;
}

/// Modal that collects the credentials of a user authorised to decide. Owns its
/// controllers (disposed with the widget) so nothing is used after dispose.
/// Returns `(email, password)` on Authorise, or null on Cancel.
class _CredentialDialog extends StatefulWidget {
  const _CredentialDialog({this.message});

  final String? message;

  @override
  State<_CredentialDialog> createState() => _CredentialDialogState();
}

class _CredentialDialogState extends State<_CredentialDialog> {
  final _email = TextEditingController();
  final _pass = TextEditingController();

  @override
  void dispose() {
    _email.dispose();
    _pass.dispose();
    super.dispose();
  }

  void _submit() {
    final e = _email.text.trim();
    final p = _pass.text;
    if (e.isEmpty || p.isEmpty) return; // keep the dialog open
    Navigator.pop(context, (e, p));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Approval required'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('This session may not approve. Enter the username and password of a user who can.'),
            if (widget.message != null) ...[
              const SizedBox(height: 10),
              Text(widget.message!, style: const TextStyle(color: PosTheme.danger, fontSize: 13)),
            ],
            const SizedBox(height: 12),
            TextField(
              controller: _email,
              autofocus: true,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(labelText: 'Username or email'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _pass,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Password'),
              onSubmitted: (_) => _submit(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _submit, child: const Text('Authorise')),
      ],
    );
  }
}

T? _firstWhereOrNull<T>(Iterable<T> items, bool Function(T) test) {
  for (final i in items) {
    if (test(i)) return i;
  }
  return null;
}
