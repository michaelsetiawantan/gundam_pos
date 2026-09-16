import 'package:flutter/material.dart';

import 'package:gundam_pos/api/api_client.dart';
import 'package:gundam_pos/models/config_models.dart';
import 'package:gundam_pos/state/app_session.dart';
import 'package:gundam_pos/state/order_controller.dart';
import 'package:gundam_pos/ui/new_order_screen.dart';
import 'package:gundam_pos/ui/theme.dart';

/// P06 — Open tables: server-synced hanging orders (server is the source of
/// truth for the hanging check and table lock). The "last synced" timestamp is
/// shown per the ops concern (never look like realtime before a sync).
class OpenTablesScreen extends StatefulWidget {
  const OpenTablesScreen({super.key, required this.session, required this.config});

  final AppSession session;
  final TenantConfig config;

  @override
  State<OpenTablesScreen> createState() => _OpenTablesScreenState();
}

class _OpenTablesScreenState extends State<OpenTablesScreen> {
  List<Map<String, dynamic>> _orders = [];
  bool _loading = true;
  String? _error;
  DateTime? _lastSynced;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final orders = await OrderController.openOrders(widget.session.posApi, widget.session.tenantId!);
      if (!mounted) return;
      setState(() {
        _orders = orders;
        _lastSynced = DateTime.now();
      });
    } on PosApiException catch (e) {
      if (mounted) setState(() => _error = 'Could not load tables (${e.code})');
    } on PosNetworkException {
      if (mounted) setState(() => _error = 'No network — showing cached list');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _newOrder() {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => NewOrderScreen(session: widget.session, config: widget.config))).then((_) => _load());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Open Tables'), actions: [
        IconButton(tooltip: 'Refresh', onPressed: _load, icon: const Icon(Icons.refresh)),
      ]),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: PosTheme.teal,
        foregroundColor: PosTheme.ink,
        onPressed: _newOrder,
        heroTag: 'new-order',
        icon: const Icon(Icons.add),
        label: const Text('New order'),
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
      final t = DateTime.tryParse(at);
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