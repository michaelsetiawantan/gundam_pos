import 'package:flutter/material.dart';

import 'package:gundam_pos/api/api_client.dart';
import 'package:gundam_pos/models/config_models.dart';
import 'package:gundam_pos/state/app_session.dart';
import 'package:gundam_pos/ui/theme.dart';
import 'package:gundam_pos/ui/widgets.dart';

/// Merge / Split / Move for open tables. Modal-first: the operator picks the
/// operation, picks the order(s), confirms, and the single POST
/// `/api/pos/tables/ops` runs server-side. The server owns all the rules
/// (merge naming, split qty accounting, empty-table move, guard locks); this
/// screen never fakes a result — a refusal is shown as-is.
///
/// Returns `true` (via pop) when the server accepted, so the caller reloads.
enum TableOpKind { merge, split, move }

Future<bool> showTableOpsSheet(
  BuildContext context, {
  required AppSession session,
  required TenantConfig config,
  required List<Map<String, dynamic>> orders,
  TableOpKind initialKind = TableOpKind.merge,
}) async {
  final changed = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => TableOpsSheet(
      session: session,
      config: config,
      orders: orders,
      initialKind: initialKind,
    ),
  );
  return changed ?? false;
}

class TableOpsSheet extends StatefulWidget {
  const TableOpsSheet({
    super.key,
    required this.session,
    required this.config,
    required this.orders,
    this.initialKind = TableOpKind.merge,
  });

  final AppSession session;
  final TenantConfig config;
  final List<Map<String, dynamic>> orders;
  final TableOpKind initialKind;

  @override
  State<TableOpsSheet> createState() => _TableOpsSheetState();
}

class _TableOpsSheetState extends State<TableOpsSheet> {
  late TableOpKind _kind = widget.initialKind;
  final Set<String> _selected = {};
  final Map<String, int> _moved = {}; // split: lineId -> qty moved to the new part
  String? _targetTableId;
  bool _useCustomTarget = false; // move: destination is a free-text table name
  final TextEditingController _customTarget = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _customTarget.dispose();
    super.dispose();
  }

  List<Map<String, dynamic>> get _orders =>
      widget.orders.where((o) => (o['id'] as String?)?.isNotEmpty ?? false).toList();

  List<Map<String, dynamic>> _lines(Map<String, dynamic> o) =>
      (o['lines'] as List? ?? const []).cast<Map<String, dynamic>>();

  Map<String, dynamic>? get _single =>
      _selected.length == 1 ? _orders.firstWhere((o) => o['id'] == _selected.first) : null;

  void _setKind(TableOpKind k) => setState(() {
        _kind = k;
        _selected.clear();
        _moved.clear();
        _targetTableId = null;
        _useCustomTarget = false;
        _customTarget.clear();
        _error = null;
      });

  void _toggle(String id) => setState(() {
        _error = null;
        if (_kind == TableOpKind.merge) {
          _selected.contains(id) ? _selected.remove(id) : _selected.add(id);
        } else {
          _selected
            ..clear()
            ..add(id);
          _moved.clear();
        }
      });

  String get _prefix => switch (_kind) {
        TableOpKind.merge => 'Could not merge the tables',
        TableOpKind.split => 'Could not split the table',
        TableOpKind.move => 'Could not move the table',
      };

  // ---------------------------------------------------------------- submit --

  Map<String, dynamic>? _buildBody() {
    final assetId = widget.session.context.deviceId;
    switch (_kind) {
      case TableOpKind.merge:
        if (_selected.length < 2) return _fail('Pick at least 2 open tables to merge.');
        return {'action': 'merge', 'orderIds': _selected.toList(), 'assetId': assetId};
      case TableOpKind.split:
        final order = _single;
        if (order == null) return _fail('Pick one open table to split.');
        final lines = _lines(order);
        if (_moved.values.every((q) => q <= 0)) {
          return _fail('Move at least one item to the new part.');
        }
        final remainder = <Map<String, dynamic>>[];
        final moved = <Map<String, dynamic>>[];
        for (final l in lines) {
          final id = l['id'] as String?;
          if (id == null) continue;
          final qty = ((l['qty'] as num?) ?? 0).toInt();
          final m = (_moved[id] ?? 0).clamp(0, qty);
          if (qty - m > 0) remainder.add({'lineId': id, 'qty': qty - m});
          if (m > 0) moved.add({'lineId': id, 'qty': m});
        }
        return {
          'action': 'split',
          'orderId': order['id'],
          'parts': [
            {'items': remainder},
            {'items': moved},
          ],
          'assetId': assetId,
        };
      case TableOpKind.move:
        final order = _single;
        if (order == null) return _fail('Pick one open table to move.');
        if (_useCustomTarget) {
          final name = _customTarget.text.trim();
          if (name.isEmpty || name.length > 16) {
            return _fail('Custom table name must be 1–16 characters.');
          }
          return {'action': 'move', 'orderId': order['id'], 'toTableName': name, 'assetId': assetId};
        }
        if (_targetTableId == null) {
          return _fail('Pick an empty table or type a custom table name.');
        }
        return {
          'action': 'move',
          'orderId': order['id'],
          'toTableId': _targetTableId,
          'assetId': assetId,
        };
    }
  }

  Map<String, dynamic>? _fail(String msg) {
    setState(() => _error = msg);
    return null;
  }

  Future<void> _submit() async {
    final body = _buildBody();
    if (body == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.session.posApi.tableOps(widget.session.tenantId!, body);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on PosApiException catch (e) {
      if (mounted) setState(() => _error = posErrorText(_prefix, e.code, status: e.status));
    } on PosNetworkException {
      if (mounted) setState(() => _error = 'No network — the operation was not applied.');
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not reach the server. Try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ------------------------------------------------------------------ build --

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.9),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          _header(),
          const Divider(height: 1),
          Flexible(child: ListView(padding: const EdgeInsets.all(20), children: _content())),
          const Divider(height: 1),
          Padding(padding: const EdgeInsets.all(16), child: _footer()),
        ]),
      ),
    );
  }

  Widget _header() => Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Table operations',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: PosTheme.petrol)),
          const SizedBox(height: 10),
          Wrap(spacing: 10, children: [
            for (final k in TableOpKind.values)
              ChoiceChip(
                selected: _kind == k,
                label: Text(switch (k) {
                  TableOpKind.merge => 'Merge',
                  TableOpKind.split => 'Split',
                  TableOpKind.move => 'Move',
                }),
                onSelected: (_) => _setKind(k),
              ),
          ]),
        ]),
      );

  List<Widget> _content() {
    if (_orders.isEmpty) {
      return const [
        Text('No open tables to operate on.', style: TextStyle(color: PosTheme.slate)),
      ];
    }
    final widgets = <Widget>[
      Text(
        switch (_kind) {
          TableOpKind.merge => 'Pick 2 or more open tables to combine into one bill.',
          TableOpKind.split => 'Pick one open table to break into parts.',
          TableOpKind.move => 'Pick one open table to move to an empty table.',
        },
        style: const TextStyle(color: PosTheme.slate, fontSize: 13),
      ),
      const SizedBox(height: 12),
      for (final o in _orders) _orderTile(o),
      if (_error != null) ...[
        const SizedBox(height: 12),
        _errorBanner(),
      ],
    ];
    if (_kind == TableOpKind.merge && _selected.length >= 2) {
      widgets
        ..add(const SizedBox(height: 16))
        ..add(_mergeSummary());
    }
    if (_kind == TableOpKind.split && _single != null) {
      widgets
        ..add(const SizedBox(height: 20))
        ..add(const Text('Allocate items', style: TextStyle(fontWeight: FontWeight.w700, color: PosTheme.petrol)))
        ..add(const SizedBox(height: 8))
        ..addAll(_splitEditor(_single!));
    }
    if (_kind == TableOpKind.move && _single != null) {
      widgets
        ..add(const SizedBox(height: 20))
        ..add(const Text('Destination (empty tables)', style: TextStyle(fontWeight: FontWeight.w700, color: PosTheme.petrol)))
        ..add(const SizedBox(height: 8))
        ..addAll(_moveTargets(_single!));
    }
    return widgets;
  }

  Widget _orderTile(Map<String, dynamic> o) {
    final id = o['id'] as String;
    final lines = _lines(o);
    final itemCount = lines.fold<int>(0, (s, l) => s + (((l['qty'] as num?) ?? 0).toInt()));
    final locked = o['lockedAt'] != null;
    final selected = _selected.contains(id);
    return Card(
      elevation: 0,
      color: selected ? PosTheme.tealSoft : Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: selected ? PosTheme.petrol : PosTheme.line),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        leading: Icon(
          _kind == TableOpKind.merge
              ? (selected ? Icons.check_box : Icons.check_box_outline_blank)
              : (selected ? Icons.radio_button_checked : Icons.radio_button_unchecked),
          color: PosTheme.petrol,
        ),
        title: Text(o['tableName']?.toString() ?? 'Takeaway',
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
        subtitle: Text(
          '$itemCount item(s)${locked ? ' · locked' : ''}',
          style: TextStyle(color: locked ? PosTheme.danger : PosTheme.slate),
        ),
        onTap: _busy ? null : () => _toggle(id),
      ),
    );
  }

  Widget _errorBanner() => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: PosTheme.danger.withValues(alpha: 0.1),
          border: const Border(left: BorderSide(color: PosTheme.danger, width: 4)),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(_error!, style: const TextStyle(color: PosTheme.danger, fontWeight: FontWeight.w600)),
      );

  /// Mirrors the server's canonical merged label: unique table names, natural
  /// sort, joined with `-`, suffixed `-MGR`, capped at 40 chars.
  String _mergedName() {
    final names = <String>{};
    for (final o in _orders.where((o) => _selected.contains(o['id']))) {
      final n = o['tableName']?.toString() ?? '';
      if (n.isNotEmpty) names.add(n);
    }
    final sorted = names.toList()..sort(_naturalCompare);
    return '${sorted.join('-')}-MGR';
  }

  Widget _mergeSummary() {
    final pax = _orders
        .where((o) => _selected.contains(o['id']))
        .map((o) => (o['pax'] as num?)?.toInt())
        .whereType<int>()
        .fold<int>(0, (s, v) => s + v);
    final hasPax = _orders.where((o) => _selected.contains(o['id'])).any((o) => o['pax'] != null);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: PosTheme.tealSoft, borderRadius: BorderRadius.circular(12)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Merged bill', style: TextStyle(fontWeight: FontWeight.w700, color: PosTheme.petrol)),
        const SizedBox(height: 6),
        Text(_mergedName(), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: PosTheme.ink)),
        const SizedBox(height: 4),
        Text('${_selected.length} tables combined${hasPax ? ' · pax $pax' : ''}',
            style: const TextStyle(color: PosTheme.slate, fontSize: 13)),
      ]),
    );
  }

  List<Widget> _splitEditor(Map<String, dynamic> order) {
    final lines = _lines(order);
    final out = <Widget>[];
    if (lines.isEmpty) {
      out.add(const Text('This table has no items to allocate.', style: TextStyle(color: PosTheme.slate)));
      return out;
    }
    for (final l in lines) {
      final id = l['id'] as String?;
      if (id == null) continue;
      final qty = ((l['qty'] as num?) ?? 0).toInt();
      final moved = (_moved[id] ?? 0).clamp(0, qty);
      out.add(Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(l['itemName']?.toString() ?? 'Item', style: const TextStyle(fontWeight: FontWeight.w600)),
              Text('$qty total · ${qty - moved} stay / $moved move',
                  style: const TextStyle(color: PosTheme.slate, fontSize: 12)),
            ]),
          ),
          IconButton(
            tooltip: 'Less to new part',
            onPressed: moved <= 0 ? null : () => setState(() => _moved[id] = moved - 1),
            icon: const Icon(Icons.remove_circle_outline),
          ),
          Text('$moved', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
          IconButton(
            tooltip: 'More to new part',
            onPressed: moved >= qty ? null : () => setState(() => _moved[id] = moved + 1),
            icon: const Icon(Icons.add_circle_outline),
          ),
        ]),
      ));
    }
    out.add(const SizedBox(height: 4));
    out.add(const Text(
      'New part name is assigned by the server (e.g. B4-1, B4-2); the original becomes the first part.',
      style: TextStyle(color: PosTheme.slate, fontSize: 12),
    ));
    return out;
  }

  List<Widget> _moveTargets(Map<String, dynamic> order) {
    final orders = _orders;
    final occupiedIds = orders.map((o) => o['tableId']).whereType<String>().toSet();
    final occupiedNames = orders.map((o) => o['tableName']).whereType<String>().toSet();
    final empty = widget.config.tables
        .where((t) => t.enabled && !occupiedIds.contains(t.id) && !(t.name != null && occupiedNames.contains(t.name)))
        .toList();
    return [
      if (empty.isEmpty)
        const Text('No empty tables available — use a custom name below.',
            style: TextStyle(color: PosTheme.slate))
      else
        Wrap(spacing: 10, runSpacing: 10, children: [
          for (final t in empty)
            ChoiceChip(
              selected: !_useCustomTarget && _targetTableId == t.id,
              label: Text(t.name ?? t.id),
              onSelected: (_) => setState(() {
                _targetTableId = t.id;
                _useCustomTarget = false;
                _customTarget.clear();
                _error = null;
              }),
            ),
        ]),
      const SizedBox(height: 16),
      ChoiceChip(
        selected: _useCustomTarget,
        avatar: const Icon(Icons.edit_outlined, size: 18),
        label: const Text('Custom table name'),
        onSelected: (_) => setState(() {
          _useCustomTarget = !_useCustomTarget;
          _targetTableId = null;
          _error = null;
        }),
      ),
      if (_useCustomTarget) ...[
        const SizedBox(height: 10),
        TextField(
          key: const Key('move-custom-name'),
          controller: _customTarget,
          maxLength: 16,
          enabled: !_busy,
          onChanged: (_) => setState(() => _error = null),
          decoration: const InputDecoration(
            labelText: 'Destination table name',
            hintText: 'e.g. Terrace 3',
            counterText: '',
          ),
        ),
      ],
    ];
  }

  Widget _footer() => PrimaryButton(
        label: switch (_kind) {
          TableOpKind.merge => 'Merge ${_selected.length >= 2 ? '${_selected.length} tables' : 'tables'}',
          TableOpKind.split => 'Split table',
          TableOpKind.move => 'Move table',
        },
        busy: _busy,
        onPressed: _submit,
      );
}

/// Natural (numeric-aware) compare, so T2 sorts before T10 — matches the
/// server's merged-label ordering.
int _naturalCompare(String a, String b) {
  final re = RegExp(r'(\d+|\D+)');
  final as = re.allMatches(a).map((m) => m.group(0)!).toList();
  final bs = re.allMatches(b).map((m) => m.group(0)!).toList();
  for (var i = 0; i < as.length && i < bs.length; i++) {
    final x = as[i], y = bs[i];
    final nx = int.tryParse(x), ny = int.tryParse(y);
    final c = (nx != null && ny != null)
        ? nx.compareTo(ny)
        : x.toLowerCase().compareTo(y.toLowerCase());
    if (c != 0) return c;
  }
  return as.length.compareTo(bs.length);
}
