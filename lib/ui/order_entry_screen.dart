import 'package:flutter/material.dart';

import 'package:gundam_pos/logic/cart.dart';
import 'package:gundam_pos/logic/money.dart' as money;
import 'package:gundam_pos/models/config_models.dart';
import 'package:gundam_pos/state/app_session.dart';
import 'package:gundam_pos/state/order_controller.dart';
import 'package:gundam_pos/state/payment_controller.dart';
import 'package:gundam_pos/ui/payment_screen.dart';
import 'package:gundam_pos/ui/theme.dart';
import 'package:gundam_pos/ui/widgets.dart';

/// P08–P13 — Order entry. The menu is an arbitrary drill-down node tree from
/// config (menus; not hardcoded Food/Beverage). Cart is sent as captain-order
/// batches; already-sent lines are never reprinted (server marks sentToKitchen).
class OrderEntryScreen extends StatefulWidget {
  const OrderEntryScreen({super.key, required this.session, required this.controller});

  final AppSession session;
  final OrderController controller;

  @override
  State<OrderEntryScreen> createState() => _OrderEntryScreenState();
}

class _OrderEntryScreenState extends State<OrderEntryScreen> {
  List<MenuNode> _breadcrumb = []; // empty = menu forest roots

  OrderController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    _breadcrumb = [];
  }

  /// Nodes shown at the current scope: forest roots when not drilled, else the
  /// current node's children.
  List<MenuNode> get _scopeNodes => _breadcrumb.isEmpty ? c.config.orderTree() : _breadcrumb.last.children;

  /// Items shown at the current scope: the current node's direct assignments
  /// (root level shows groups only — drill into a node to reveal its items).
  List<String> get _scopeItemIds => _breadcrumb.isEmpty ? const [] : _breadcrumb.last.itemIds;

  void _drill(MenuNode node) {
    setState(() => _breadcrumb.add(node));
  }

  void _back() {
    if (_breadcrumb.isEmpty) return;
    setState(() => _breadcrumb.removeLast());
  }

  Future<void> _addItem(MenuItem item) async {
    final pick = await showModalBottomSheet<_PickResult>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _ItemOptionsSheet(item: item),
    );
    if (pick == null || !mounted) return;
    final ok = await c.addItem(item, levelIndex: pick.level, qty: pick.qty, mods: pick.mods);
    if (ok == null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(c.error ?? 'Item not added')));
    }
  }

  void _openCart() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => _CartSheet(controller: c),
    );
  }

  void _pay() {
    final pc = PaymentController(
      posApi: c.posApi,
      tenantId: c.tenantId,
      config: c.config,
      orderId: c.orderId!,
      tableName: c.tableName,
      cart: c.cart,
      deviceAssetId: c.deviceAssetId,
      shortcode: widget.session.shortcode,
      onSettled: widget.session.noteSettled,
    );
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => PaymentScreen(controller: pc)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(c.tableName ?? 'Order'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(48),
          child: _breadcrumbs(),
        ),
      ),
      body: ListenableBuilder(
        listenable: c,
        builder: (context, _) => Column(children: [
          if (c.error != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: ErrorBanner(message: c.error),
            ),
          Expanded(child: _menuGrid()),
          _cartBar(),
        ]),
      ),
    );
  }

  Widget _breadcrumbs() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Row(children: [
        if (_breadcrumb.length > 1)
          InkWell(
            onTap: _back,
            child: const Padding(
              padding: EdgeInsets.all(4),
              child: Icon(Icons.arrow_back, color: Colors.white, size: 22),
            ),
          ),
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              const Text('Menu', style: TextStyle(color: PosTheme.tealSoft, fontSize: 15)),
              for (final n in _breadcrumb) ...[
                const Text(' › ', style: TextStyle(color: PosTheme.tealSoft)),
                Text(n.name, style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600)),
              ],
            ]),
          ),
        ),
      ]),
    );
  }

  Widget _menuGrid() {
    final scopeItems = _scopeItemIds.map((id) => c.config.itemById(id)).whereType<MenuItem>().toList();
    final nodes = _scopeNodes;
    final hasLeaves = scopeItems.isNotEmpty;

    if (nodes.isEmpty && !hasLeaves) {
      return const Center(child: Text('No items in this section yet.', style: TextStyle(color: PosTheme.slate)));
    }

    final entries = <Widget>[];
    for (final node in nodes) {
      entries.add(_nodeCard(node));
    }
    for (final item in scopeItems) {
      entries.add(_itemCard(item));
    }

    return GridView.count(
      crossAxisCount: _cols(entries.length),
      padding: const EdgeInsets.all(16),
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
      childAspectRatio: 1.1,
      children: entries,
    );
  }

  int _cols(int n) => n > 12 ? 5 : n > 6 ? 4 : n > 2 ? 3 : 2;

  Widget _nodeCard(MenuNode node) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: () => _drill(node),
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), border: Border.all(color: PosTheme.line)),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            const Icon(Icons.folder_outlined, color: PosTheme.teal, size: 32),
            const SizedBox(height: 10),
            Text(node.name, textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15, color: PosTheme.ink)),
          ]),
        ),
      ),
    );
  }

  Widget _itemCard(MenuItem item) {
    final price = _priceOf(item);
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: () => _addItem(item),
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), border: Border.all(color: PosTheme.line)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Center(
                  child: Icon(item.vatMode == money.VatScMode.none ? Icons.fastfood_outlined : Icons.local_dining, color: PosTheme.petrol, size: 28),
                ),
              ),
              Text(item.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14, color: PosTheme.ink)),
              Text(price == null ? '—' : _money(price), style: const TextStyle(color: PosTheme.teal, fontWeight: FontWeight.w700, fontSize: 14)),
            ],
          ),
        ),
      ),
    );
  }

  double? _priceOf(MenuItem item) => item.priceLevels.isEmpty ? null : item.priceLevels.first.price;

  Widget _cartBar() {
    if (c.cart.isEmpty) return const SizedBox.shrink();
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        color: PosTheme.petrol,
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text('${c.cart.itemCount} item(s)', style: const TextStyle(color: PosTheme.tealSoft, fontSize: 13)),
              Text(_money(c.cart.total), style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w800)),
            ]),
          ),
          TextButton.icon(
            onPressed: c.busy ? null : _openCart,
            icon: const Icon(Icons.receipt_long),
            label: const Text('Cart'),
          ),
          const SizedBox(width: 8),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: PosTheme.teal, foregroundColor: PosTheme.ink),
            onPressed: c.busy ? null : _openCart,
            child: const Text('Review cart'),
          ),
          const SizedBox(width: 8),
          OutlinedButton(
            style: OutlinedButton.styleFrom(
              foregroundColor: PosTheme.tealSoft,
              side: const BorderSide(color: PosTheme.teal, width: 1.5),
              minimumSize: const Size(64, 48),
            ),
            onPressed: c.cart.isEmpty ? null : _pay,
            child: const Text('Payment'),
          ),
        ]),
      ),
    );
  }

  static String _money(double v) => '${v == v.roundToDouble() ? v.toInt() : v.toStringAsFixed(2)}';
}

class _PickResult {
  _PickResult(this.level, this.qty, this.mods);
  final int level;
  final int qty;
  final List<CartModifier> mods;
}

class _ItemOptionsSheet extends StatefulWidget {
  const _ItemOptionsSheet({required this.item});
  final MenuItem item;

  @override
  State<_ItemOptionsSheet> createState() => _ItemOptionsSheetState();
}

class _ItemOptionsSheetState extends State<_ItemOptionsSheet> {
  int _level = 0;
  int _qty = 1;
  final Set<String> _picked = {};

  double get _unitPrice {
    final levels = widget.item.priceLevels;
    final base = levels.isEmpty ? 0.0 : levels.firstWhere((l) => l.levelIndex == _level, orElse: () => levels.first).price;
    final modTotal = widget.item.modifiers.where((m) => _picked.contains(m.id)).fold<double>(0, (s, m) => s + m.price);
    return money.round2(base + modTotal);
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final hasLevels = item.priceLevels.length > 1;
    final hasMods = item.modifiers.isNotEmpty;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        top: false,
        child: DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.9,
          builder: (_, scroll) => ListView(
            controller: scroll,
            padding: const EdgeInsets.all(20),
            children: [
              Row(children: [
                const Icon(Icons.local_dining, color: PosTheme.petrol),
                const SizedBox(width: 10),
                Expanded(child: Text(item.name, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800))),
              ]),
              const SizedBox(height: 18),
              if (hasLevels) ...[
                const Text('Portion', style: TextStyle(fontWeight: FontWeight.w700, color: PosTheme.petrol)),
                const SizedBox(height: 8),
                Wrap(spacing: 8, children: [
                  for (final l in item.priceLevels)
                    ChoiceChip(
                      label: Text(l.label.isEmpty ? 'L${l.levelIndex}'.toUpperCase() : l.label),
                      selected: _level == l.levelIndex,
                      onSelected: (_) => setState(() => _level = l.levelIndex),
                    ),
                ]),
                const SizedBox(height: 16),
              ],
              if (hasMods) ...[
                const Text('Options', style: TextStyle(fontWeight: FontWeight.w700, color: PosTheme.petrol)),
                const SizedBox(height: 8),
                for (final m in item.modifiers)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _picked.contains(m.id),
                    title: Text(m.name),
                    subtitle: m.price > 0 ? Text('+${_money(m.price)}') : null,
                    onChanged: (v) => setState(() => v == true ? _picked.add(m.id) : _picked.remove(m.id)),
                  ),
                const SizedBox(height: 8),
              ],
              Row(children: [
                const Text('Qty', style: TextStyle(fontWeight: FontWeight.w700, color: PosTheme.petrol)),
                const Spacer(),
                _QtyStepper(value: _qty, onChanged: (v) => setState(() => _qty = v)),
              ]),
              const SizedBox(height: 20),
              SizedBox(height: PosTheme.minTouch + 8, child: FilledButton.icon(
                onPressed: () => Navigator.pop(context, _PickResult(_level, _qty, [
                  for (final m in widget.item.modifiers.where((m) => _picked.contains(m.id)))
                    CartModifier(modifierId: m.id, name: m.name, price: m.price),
                ])),
                icon: const Icon(Icons.add_shopping_cart),
                label: Text('Add · ${_money(_unitPrice * _qty)}'),
              )),
            ],
          ),
        ),
      ),
    );
  }

  static String _money(double v) => '${v == v.roundToDouble() ? v.toInt() : v.toStringAsFixed(2)}';
}

class _QtyStepper extends StatelessWidget {
  const _QtyStepper({required this.value, required this.onChanged});
  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      IconButton.filledTonal(
        onPressed: () => onChanged(value > 1 ? value - 1 : 1),
        icon: const Icon(Icons.remove),
        tooltip: 'Decrease',
      ),
      SizedBox(width: 48, child: Text('$value', textAlign: TextAlign.center, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700))),
      IconButton.filledTonal(onPressed: () => onChanged(value + 1), icon: const Icon(Icons.add), tooltip: 'Increase'),
    ]);
  }
}

class _CartSheet extends StatefulWidget {
  const _CartSheet({required this.controller});
  final OrderController controller;

  @override
  State<_CartSheet> createState() => _CartSheetState();
}

class _CartSheetState extends State<_CartSheet> {
  bool get _busy => widget.controller.busy;

  Future<void> _send() async {
    final ok = await widget.controller.sendCart();
    if (!mounted) return;
    final c = widget.controller;
    if (ok) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: PosTheme.ok,
        content: Row(children: [
          const Icon(Icons.check_circle, color: Colors.white),
          const SizedBox(width: 10),
          Expanded(child: Text('Sent — batch ${c.lastBatchLabel}. Lines already sent are not reprinted.')),
        ]),
      ));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(c.error ?? 'Send failed')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Text('Cart', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
          const Spacer(),
          if (c.lastBatchLabel != null)
            Chip(label: Text('batch ${c.lastBatchLabel}', style: const TextStyle(color: PosTheme.petrol, fontWeight: FontWeight.w700))),
        ]),
        const Divider(height: 24),
        Flexible(
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final line in c.cart.lines)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(line.sent ? Icons.verified : Icons.shopping_cart_outlined,
                      color: line.sent ? PosTheme.ok : PosTheme.petrol),
                  title: Text('${line.qty}× ${line.name}', style: const TextStyle(fontWeight: FontWeight.w700)),
                  subtitle: Text(line.sent ? 'sent to kitchen' : _money(line.lineSubtotal)),
                  trailing: line.sent
                      ? const Text('sent', style: TextStyle(color: PosTheme.ok, fontWeight: FontWeight.w600))
                      : IconButton(
                          tooltip: 'Remove',
                          onPressed: () {
                            try {
                              c.removeFromCart(line);
                            } on CartError {
                              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('This line is already sent.')));
                            }
                          },
                          icon: const Icon(Icons.delete_outline, color: PosTheme.danger),
                        ),
                ),
            ],
          ),
        ),
        const Divider(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Row(children: [
            const Expanded(child: Text('Total', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700))),
            Text(_money(c.cart.total), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: PosTheme.petrol)),
          ]),
        ),
        SafeArea(
          top: false,
          child: PrimaryButton(label: 'Send cart to kitchen', busy: _busy, icon: Icons.send, onPressed: c.cart.isEmpty ? null : _send),
        ),
        const SizedBox(height: 12),
      ]),
    );
  }

  static String _money(double v) => '${v == v.roundToDouble() ? v.toInt() : v.toStringAsFixed(2)}';
}