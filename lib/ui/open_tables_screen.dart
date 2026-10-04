import 'package:flutter/material.dart';

import 'package:gundam_pos/api/api_client.dart';
import 'package:gundam_pos/models/config_models.dart';
import 'package:gundam_pos/state/app_session.dart';
import 'package:gundam_pos/state/order_controller.dart';
import 'package:gundam_pos/ui/new_order_screen.dart';
import 'package:gundam_pos/ui/order_entry_screen.dart';
import 'package:gundam_pos/ui/table_ops_sheet.dart';
import 'package:gundam_pos/ui/theme.dart';

/// P06 — Open tables: server-synced hanging orders (server is the source of
/// truth for the hanging check and table lock). The "last synced" timestamp is
/// shown per the ops concern (never look like realtime before a sync).
class OpenTablesScreen extends StatefulWidget {
  const OpenTablesScreen({
    super.key,
    required this.session,
    required this.config,
    this.initialOrders,
  });

  final AppSession session;
  final TenantConfig config;

  /// Seam: the last-known list to paint immediately (offline-first). Production
  /// reads it from the on-disk cache in `_load`; a test injects it so the
  /// screen's behavior is exercised without touching the filesystem.
  final List<Map<String, dynamic>>? initialOrders;

  @override
  State<OpenTablesScreen> createState() => _OpenTablesScreenState();
}

class _OpenTablesScreenState extends State<OpenTablesScreen> with WidgetsBindingObserver {
  List<Map<String, dynamic>> _orders = [];
  bool _loading = true;
  String? _error;
  DateTime? _lastSynced;

  @override
  void initState() {
    super.initState();
    // Paint the last-known list first (offline-first); `_load` refreshes it.
    final seed = widget.initialOrders;
    if (seed != null && seed.isNotEmpty) {
      _orders = seed;
      _loading = false;
    }
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Auto-refresh on resume: another device may have opened/paid a table while
  /// this screen was backgrounded — no manual Refresh required.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_loading) _load();
  }

  Future<void> _load() async {
    // OFFLINE-FIRST: paint the last-known list straight away (no spinner wall,
    // no waiting on the network). The server refresh below replaces it.
    if (_orders.isEmpty) {
      final cached = await widget.session.cachedOpenOrders();
      if (cached != null && cached.isNotEmpty && mounted) {
        setState(() {
          _orders = cached;
          _loading = false;
          _error = null;
        });
      }
    }
    if (!mounted) return;
    setState(() {
      // Keep whatever we already show: a background refresh must not blank it.
      _loading = _orders.isEmpty;
      _error = null;
    });
    List<Map<String, dynamic>> server = const [];
    String? netError;
    try {
      server = await OrderController.openOrders(widget.session.posApi, widget.session.tenantId!);
    } on PosApiException catch (e) {
      netError = 'Could not load tables (${e.code})';
    } on PosNetworkException {
      netError = 'No network — showing locally opened orders';
    }
    // Offline-first: orders opened on this tablet whose `order_create` is still
    // queued are not on the server yet — surface them so the operator sees the
    // table. Once synced the server row exists and the id dedupe drops the copy.
    final local = await _localOrders();
    final serverIds = {for (final o in server) o['id']};
    final all = [...server, ...local.where((o) => !serverIds.contains(o['id']))];
    // An order this tablet just closed never shows again — without waiting for
    // the server (an offline-created order has no server row to disappear from).
    final closed = widget.session.closedOrderIds;
    final merged = [for (final o in all) if (!closed.contains(o['id'])) o];
    widget.session.pruneClosedOrders({for (final o in all) o['id']});
    // Remember it for the next visit (and for the offline case).
    if (server.isNotEmpty || netError == null) {
      await widget.session.cacheOpenOrders(merged);
    }
    if (!mounted) return;
    setState(() {
      // A FAILED refresh must never blank the list we are showing: offline, the
      // screen keeps the last-known tables (that is the whole point).
      final keepExisting = server.isEmpty && netError != null && _orders.isNotEmpty;
      _orders = keepExisting ? _orders : merged;
      _lastSynced = DateTime.now();
      // Only shout when there is truly nothing to show.
      _error = _orders.isEmpty ? netError : null;
      _loading = false;
    });
  }

  /// Local (un-synced) orders from the durable outbox: one map per queued
  /// `order_create`, in the server's Open Tables shape so the list renders it.
  Future<List<Map<String, dynamic>>> _localOrders() async {
    try {
      final pending = await widget.session.pushStore.pending();
      return [
        for (final it in pending)
          if (it['type'] == 'order_create' && it['payload_json'] is Map)
            _localOrder(it['payload_json'] as Map),
      ];
    } catch (_) {
      return const [];
    }
  }

  Map<String, dynamic> _localOrder(Map payload) => {
        'id': payload['orderId'],
        'status': 'OPEN',
        if (payload['tableId'] != null) 'tableId': payload['tableId'],
        'tableName': payload['tableName'],
        'openedAt': payload['openedAt'],
        'lines': const [],
        'localOnly': true,
      };

  void _newOrder() {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => NewOrderScreen(session: widget.session, config: widget.config))).then((_) => _load());
  }

  /// Open the merge/split/move sheet for the current open-table list. On a
  /// server-accepted op, reload so the list reflects the new shape.
  Future<void> _tableOps(TableOpKind kind) async {
    final changed = await showTableOpsSheet(
      context,
      session: widget.session,
      config: widget.config,
      orders: _orders,
      initialKind: kind,
    );
    if (changed && mounted) _load();
  }

  /// Open a hanging order for continuation: adopt it into a fresh controller
  /// (same bill id + existing lines) and enter order entry. Back → reload.
  Future<void> _resume(Map<String, dynamic> o) async {
    final c = OrderController(
      posApi: widget.session.posApi,
      tenantId: widget.session.tenantId!,
      config: widget.config,
      deviceAssetId: widget.session.context.deviceId,
      printer: widget.session.printDispatcher,
      shiftGate: widget.session.gateFor(widget.config),
      pushStore: widget.session.pushStore,
      orderNumbers: widget.session.orderNumbers,
      shortcode: widget.session.shortcode,
      // Late print warnings (captain/bev) reach the operator via the shell.
      onPrintAlerts: widget.session.notePrintAlerts,
    );
    if (!c.resumeFrom(o)) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => OrderEntryScreen(session: widget.session, controller: c),
    ));
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Open Tables'), actions: [
        PopupMenuButton<TableOpKind>(
          tooltip: 'Table operations',
          enabled: !_loading && _orders.isNotEmpty,
          icon: const Icon(Icons.table_rows_outlined),
          onSelected: _tableOps,
          itemBuilder: (_) => const [
            PopupMenuItem(value: TableOpKind.merge, child: Text('Merge tables')),
            PopupMenuItem(value: TableOpKind.split, child: Text('Split table')),
            PopupMenuItem(value: TableOpKind.move, child: Text('Move table')),
          ],
        ),
        IconButton(tooltip: 'Refresh', onPressed: _load, icon: const Icon(Icons.refresh)),
      ]),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: PosTheme.teal,
        foregroundColor: PosTheme.ink,
        onPressed: _newOrder,
        heroTag: 'new-order',
        // Comfortably tappable: the default FAB was too small for a busy till
        // (a mis-tap here costs a whole order).
        extendedPadding: const EdgeInsets.symmetric(horizontal: 26, vertical: 8),
        icon: const Icon(Icons.add, size: 30),
        label: const Text('New order', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          child: Row(children: [
            const Icon(Icons.cloud_sync, color: PosTheme.slate, size: 16),
            const SizedBox(width: 6),
            Text('Last synced: ${_lastSynced == null ? '—' : _timeAgo(_lastSynced!)}',
                style: const TextStyle(color: PosTheme.slate, fontSize: 13)),
            const Spacer(),
            Text('${_orders.length} open', style: const TextStyle(color: PosTheme.petrol, fontWeight: FontWeight.w700)),
          ]),
        ),
        const Divider(height: 1),
        Expanded(child: _body()),
      ]),
    );
  }

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.cloud_off, color: PosTheme.danger, size: 48),
            const SizedBox(height: 12),
            Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: PosTheme.slate)),
            const SizedBox(height: 16),
            OutlinedButton(onPressed: _load, child: const Text('Retry')),
          ]),
        ),
      );
    }
    if (_orders.isEmpty) {
      return const Center(
        child: Text('No open tables.\nStart a new order to take a sale.',
            textAlign: TextAlign.center, style: TextStyle(color: PosTheme.slate, fontSize: 16)),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.all(20),
      itemCount: _orders.length,
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (_, i) {
        final o = _orders[i];
        final lines = (o['lines'] as List? ?? const []);
        return Card(
          elevation: 0,
          color: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: PosTheme.line)),
          child: ListTile(
            contentPadding: const EdgeInsets.all(14),
            leading: const CircleAvatar(backgroundColor: PosTheme.tealSoft, child: Icon(Icons.table_restaurant, color: PosTheme.petrol)),
            trailing: const Icon(Icons.chevron_right, color: PosTheme.slate),
            onTap: () => _resume(o),
            title: Text(o['tableName']?.toString() ?? 'Takeaway', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 17)),
            subtitle: Text('${lines.length} item(s) · opened ${_openBy(o)}', style: const TextStyle(color: PosTheme.slate)),
          ),
        );
      },
    );
  }

  String _openBy(Map<String, dynamic> o) {
    final at = o['openedAt'];
    if (at is String && at.isNotEmpty) {
      // Server timestamps are UTC: convert to local before diffing, or "opened
      // Xm ago" is off by the zone offset.
      final t = DateTime.tryParse(at)?.toLocal();
      if (t != null) {
        final d = DateTime.now().difference(t);
        return d.inMinutes < 60 ? '${d.inMinutes}m ago' : '${d.inHours}h ago';
      }
    }
    return 'recently';
  }

  String _timeAgo(DateTime t) {
    final d = DateTime.now().difference(t);
    return d.inSeconds < 60 ? 'just now' : '${d.inMinutes}m ago';
  }
}