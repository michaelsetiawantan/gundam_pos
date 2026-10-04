import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'package:gundam_pos/logic/cart.dart';
import 'package:gundam_pos/logic/money.dart' as money;
import 'package:gundam_pos/models/config_models.dart';
import 'package:gundam_pos/state/app_session.dart';
import 'package:gundam_pos/state/order_controller.dart';
import 'package:gundam_pos/state/payment_controller.dart';
import 'package:gundam_pos/state/pricing_controller.dart';
import 'package:gundam_pos/ui/bill_preview_screen.dart';
import 'package:gundam_pos/ui/captain_preview_screen.dart';
import 'package:gundam_pos/ui/payment_screen.dart';
import 'package:gundam_pos/ui/pricing_panel.dart';
import 'package:gundam_pos/ui/theme.dart';
import 'package:gundam_pos/ui/widgets.dart';

/// P08–P13 — Order entry. The menu is an arbitrary drill-down node tree from
/// config (menus; not hardcoded Food/Beverage). Cart is sent as captain-order
/// batches; already-sent lines are never reprinted (server marks sentToKitchen).
class OrderEntryScreen extends StatefulWidget {
  const OrderEntryScreen({
    super.key,
    required this.session,
    required this.controller,
    this.mediaBytes,
  });

  final AppSession session;
  final OrderController controller;

  /// Seam for the tile images: resolves a media asset key to its cached bytes.
  /// Defaults to the session's media cache; a test injects it so the tile logic
  /// is exercised without touching the filesystem.
  final Future<Uint8List?> Function(String assetKey)? mediaBytes;

  @override
  State<OrderEntryScreen> createState() => _OrderEntryScreenState();
}

class _OrderEntryScreenState extends State<OrderEntryScreen> with WidgetsBindingObserver {
  List<MenuNode> _breadcrumb = []; // empty = menu forest roots
  final TextEditingController _search = TextEditingController();
  String _query = '';

  OrderController get c => widget.controller;

  /// ONE stable listenable for the whole body. `Listenable.merge([c, c.pricing])`
  /// built inside build() minted a NEW object every frame, so the panel
  /// re-subscribed on each rebuild and a notification could land in the swap —
  /// the field bug where a picked product only showed after a manual Refresh.
  /// This object forwards events from the order controller AND its (possibly
  /// late-assigned) pricing controller, re-hooking pricing when it changes.
  late final _OrderPanelListenable _panelListenable;

  @override
  void initState() {
    super.initState();
    _breadcrumb = [];
    _panelListenable = _OrderPanelListenable(c);
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _search.dispose();
    _panelListenable.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Coming back to the app must not need a manual Refresh: try to sync queued
    // items and reconcile from the server (silently when offline).
    if (state == AppLifecycleState.resumed) {
      _syncNow(quiet: true);
    }
  }

  void _syncNow({bool quiet = false}) {
    c.retryUnsyncedLines().then((ok) {
      if (!mounted) return;
      if (!quiet && !ok) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(c.error ?? 'Could not sync yet — will retry automatically.')),
        );
      }
      c.refreshQuietly();
    });
  }

  /// Nodes shown at the current scope: forest roots when not drilled, else the
  /// current node's children.
  List<MenuNode> get _scopeNodes => _breadcrumb.isEmpty ? c.config.orderTree() : _breadcrumb.last.children;

  /// Items shown at the current scope: the current node's direct assignments
  /// (root level shows groups only — drill into a node to reveal its items).
  List<String> get _scopeItemIds => _breadcrumb.isEmpty ? const [] : _breadcrumb.last.itemIds;

  /// Every sellable item assigned to at least one layout node (search scope).
  /// The pruned tree already drops inactive items and empty nodes, so this is
  /// exactly "active AND assigned" per the Menu Layout PRD.
  List<MenuItem> get _assignedItems {
    final out = <MenuItem>[];
    void walk(List<MenuNode> nodes) {
      for (final n in nodes) {
        for (final id in n.itemIds) {
          final it = c.config.itemById(id);
          if (it != null) out.add(it);
        }
        walk(n.children);
      }
    }

    walk(c.config.orderTree());
    return out;
  }

  /// Cross-node search over name + SKU + itemcode, case-insensitive. Empty query
  /// → null so the grid falls back to normal drill-down.
  List<MenuItem>? get _searchResults {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return null;
    return _assignedItems
        .where((i) =>
            i.name.toLowerCase().contains(q) ||
            i.sku.toLowerCase().contains(q) ||
            i.itemcode.toLowerCase().contains(q))
        .toList();
  }

  void _drill(MenuNode node) {
    setState(() => _breadcrumb.add(node));
  }

  /// Up ONE menu level (never straight to Open Tables — that is the AppBar
  /// back only at the root).
  void _back() {
    if (_breadcrumb.isEmpty) return;
    setState(() => _breadcrumb.removeLast());
  }

  void _root() => setState(() => _breadcrumb = []);

  Future<void> _addItem(MenuItem item) async {
    final pick = await showModalBottomSheet<_PickResult>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _ItemOptionsSheet(item: item, currency: c.config.shift.currencyLabel),
    );
    if (pick == null || !mounted) return;
    final ok = await c.addItem(item, levelIndex: pick.level, qty: pick.qty, mods: pick.mods);
    if (!mounted) return;
    // Belt-and-braces: the right-hand panel MUST reflect the new line the instant
    // the server answers, even if a listenable event was ever missed. Cheap and
    // idempotent; addItem's contract is untouched.
    setState(() {});
    if (ok == null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(c.error ?? 'Item not added')));
    }
  }

  /// Send the whole unsent cart from the action bar (same path as the cart
  /// sheet) — the obvious way out of the "unsent lines" state.
  Future<void> _sendCart() async {
    final ok = await c.sendCart();
    if (!mounted) return;
    if (ok) {
      final label = c.lastBatchLabel;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: c.printAlerts.isEmpty ? PosTheme.ok : PosTheme.petrol,
        content: Text(c.printAlerts.isEmpty
            ? 'Sent — batch ${label ?? '—'}. Already-sent lines were not reprinted.'
            : '${label == null ? '' : 'Sent — batch $label. '}${c.printAlerts.first}'),
      ));
      return;
    }
    // A refused send must never be a dead end: show the cause AND offer the
    // way out (back to the tables list, where the order can be reloaded).
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(c.error ?? 'Send failed'),
      action: SnackBarAction(
        label: 'Back to tables',
        onPressed: () => Navigator.of(context).maybePop(),
      ),
    ));
  }

  void _openCart() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => _CartSheet(controller: c),
    );
  }

  /// Discount/voucher is part of the ORDER flow, not just the payment screen:
  /// the cashier can attach it while still taking the order. Server-backed via
  /// [OrderController.pricing], so payment settles exactly this choice.
  void _openPricing() {
    final p = c.pricing;
    if (p == null) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => _PricingSheet(pricing: p, currency: c.config.shift.currencyLabel),
    );
  }

  /// Show the bill EXACTLY as it will print — same engine + BILL format as the
  /// printer, with the order's live discount/voucher. Available once the cart
  /// has items (the PRD allows a bill preview after send-cart; the preview is
  /// read-only and never blocks the sale).
  /// One entry for every printout this order prints: the operator picks which
  /// ticket to see. Bill and captain order are rendered through the SAME payload
  /// builders and format store the printers use, so a preview equals the paper.
  Future<void> _printoutPreview() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text('Which printout?',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
          ),
          ListTile(
            key: const Key('preview-choice-bill'),
            leading: const Icon(Icons.receipt_long_outlined),
            title: const Text('Preview bill'),
            subtitle: const Text('Customer bill — items, discounts, totals'),
            onTap: () => Navigator.pop(ctx, 'bill'),
          ),
          ListTile(
            key: const Key('preview-choice-captain'),
            leading: const Icon(Icons.soup_kitchen_outlined),
            title: const Text('Preview captain order'),
            subtitle: const Text('Kitchen sheet — items grouped by menu'),
            onTap: () => Navigator.pop(ctx, 'captain'),
          ),
          const SizedBox(height: 8),
        ]),
      ),
    );
    if (!mounted || choice == null) return;
    // Same reason as payment: adopt the SERVER's applied pricing first, so the
    // bill preview can never show a discount the server has already applied.
    await c.refreshQuietly();
    if (!mounted) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => choice == 'captain'
          ? CaptainPreviewScreen(session: widget.session, controller: c)
          : BillPreviewScreen(session: widget.session, controller: c),
    ));
  }

  Future<void> _pay() async {
    // Gate: the PRD forbids paying a cart that was never sent to the kitchen.
    if (!c.canPay) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Send the cart to the kitchen before payment.'),
      ));
      return;
    }
    // Payment must reflect the SERVER's truth: a discount authorised elsewhere
    // (approval decided on this POS, another device, the web) lives on the order
    // row, not in this screen's memory. Best-effort and silent when offline.
    await c.refreshQuietly();
    if (!mounted) return;
    final pc = PaymentController(
      posApi: c.posApi,
      tenantId: c.tenantId,
      config: c.config,
      orderId: c.orderId!,
      tableName: c.tableName,
      cart: c.cart,
      deviceAssetId: c.deviceAssetId,
      shortcode: widget.session.shortcode,
      receipts: widget.session.receipts,
      onSettled: widget.session.noteSettled,
      printer: widget.session.printDispatcher,
      // Late print warnings (bill) reach the operator via the shell's shared
      // surface, even after this screen pops to the success page.
      onPrintAlerts: widget.session.notePrintAlerts,
      // Offline-first: a settle that cannot reach the server completes locally
      // and queues an idempotent `order_settle` in this durable outbox.
      pushStore: widget.session.pushStore,
      // The order's discount/voucher, shared — a discount applied during order
      // entry is the one the payment screen previews and settles.
      pricingController: c.pricing,
      // The order's server opened time + the session gate → the recap-window
      // alert (pre-midnight hanging order) can fire on the real UI path.
      openedAt: c.openedAt,
      shiftGate: widget.session.gateFor(c.config),
    );
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => PaymentScreen(controller: pc)));
  }

  /// Ask the server to cancel this order. Nothing was sent to the kitchen →
  /// closed immediately; already sent → PENDING approval (decided in the web
  /// console, nothing reversed on the tablet).
  ///
  /// A cart with NOTHING on it has nothing to justify — asking for a reason
  /// there is pure friction (the server closes it with no approval anyway), so
  /// an empty cart cancels straight away.
  Future<void> _cancelOrder() async {
    Future<String?> askReason() => showDialog<String>(
          context: context,
          builder: (_) => const _ReasonDialog(title: 'Cancel order', hint: 'Reason for cancelling this order'),
        );

    // An empty cart has nothing to justify — the server closes it outright.
    var reason = c.cart.isEmpty ? '' : await askReason();
    if (reason == null || !mounted) return;
    var r = await c.cancelOrder(reason);
    if (!mounted) return;
    if (r == null && c.lastErrorCode == 'reason_required') {
      // The server still holds sent lines the cart no longer shows, so it does
      // want a justification. Ask once and retry instead of dead-ending.
      reason = await askReason();
      if (reason == null || !mounted) return;
      r = await c.cancelOrder(reason);
      if (!mounted) return;
    }
    if (r == 'canceled') {
      // Tell the table list THIS order is gone before we pop: Open Tables must
      // not need a refresh (or a round-trip) to drop it.
      final closedId = c.orderId;
      if (closedId != null && closedId.isNotEmpty) widget.session.noteOrderClosed(closedId);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        backgroundColor: PosTheme.ok,
        content: Text('Order cancelled — the table is free.'),
      ));
      // The order entry sits directly on top of Open Tables: pop exactly one
      // route to land back there. `maybePop` was a dead end once the menu was
      // drilled (PopScope.canPop == false) — plain pop() is unconditional; if
      // there is nothing to pop, unwind to the first route.
      final nav = Navigator.of(context);
      if (nav.canPop()) {
        nav.pop();
      } else {
        nav.popUntil((route) => route.isFirst);
      }
      return;
    } else if (r == 'pending') {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: PosTheme.petrol,
        content: const Text('Cancel requested — awaiting approval. Nothing is reversed yet.'),
        action: SnackBarAction(label: 'Back to tables', onPressed: () => Navigator.of(context).maybePop()),
      ));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(c.error ?? 'Could not cancel the order')));
    }
  }

  /// Re-read the order from the server and rebuild the cart — recovery when the
  /// tablet and server drifted (e.g. a delete that never reached the server).
  Future<void> _reload() async {
    final ok = await c.reloadFromServer();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(ok ? 'Order refreshed from the server.' : (c.error ?? 'Could not refresh the order.')),
    ));
  }

  /// Per-item cancel of an ALREADY-SENT line: pick quantity (1..line.qty) +
  /// mandatory reason, then the server decides (immediate or PENDING approval).
  /// The local line stays — the web console owns a sent line's fate.
  Future<void> _cancelLine(CartLine line) async {
    final pick = await showDialog<(int, String)>(
      context: context,
      builder: (_) => _CancelLineDialog(line: line, currency: c.config.shift.currencyLabel),
    );
    if (pick == null || !mounted) return;
    final r = await c.cancelLine(line, qty: pick.$1, reason: pick.$2);
    if (!mounted) return;
    if (r == 'pending') {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        backgroundColor: PosTheme.petrol,
        content: Text('Cancel requested — awaiting approval'),
      ));
    } else if (r == 'canceled') {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        backgroundColor: PosTheme.ok,
        content: Text('Item cancelled — nothing had reached the kitchen.'),
      ));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(c.error ?? 'Could not cancel the item')));
    }
  }

  @override
  Widget build(BuildContext context) {
    // Phone/portrait keeps the bottom bar + cart sheet; tablet landscape gets
    // the persistent right-hand cart panel the mockup shows alongside the menu.
    // A 10" tablet is often scaled (e.g. 1280×800 physical @1.5 → ~853 logical),
    // so a flat 900px gate dropped the panel entirely. 820 catches the scaled
    // tablet without turning an ordinary 800px-wide surface into two columns.
    final size = MediaQuery.sizeOf(context);
    final wide = size.width >= 820;
    return PopScope(
      // Back (hardware/gesture) goes UP one menu level while drilled; only at the
      // root does it leave to Open Tables. Never a straight pop past the tree.
      canPop: _breadcrumb.isEmpty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(c.tableName ?? 'Order'),
          // Root → the default leading pops the route (Open Tables). Drilled →
          // the leading is OURS and climbs exactly one menu level.
          leading: _breadcrumb.isEmpty
              ? null
              : IconButton(
                  key: const Key('menu-back'),
                  tooltip: 'Back one menu level',
                  onPressed: _back,
                  icon: const Icon(Icons.arrow_back),
                ),
          actions: [
            // Discount/voucher rides the order flow, not only the payment screen.
            if (c.pricing != null)
              IconButton(
                key: const Key('order-pricing'),
                tooltip: 'Discount / Voucher',
                onPressed: _openPricing,
                icon: const Icon(Icons.local_offer_outlined),
              ),
            IconButton(
              key: const Key('order-refresh'),
              tooltip: 'Refresh from server',
              onPressed: c.busy ? null : _reload,
              icon: const Icon(Icons.sync),
            ),
            if (c.canCancel)
              IconButton(
                key: const Key('order-cancel'),
                tooltip: 'Cancel order',
                onPressed: c.busy ? null : _cancelOrder,
                icon: const Icon(Icons.cancel_outlined),
              ),
          ],
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(48),
            child: _breadcrumbs(),
          ),
        ),
        body: ListenableBuilder(
          // The cart bar shows the order's discount too — listening to the order
          // controller alone would leave the applied discount invisible until a
          // navigation (the "must refresh" complaint). [_panelListenable] is a
          // STABLE merge of both sources (built once, not per frame).
          listenable: _panelListenable,
          builder: (context, _) => Column(children: [
            if (c.error != null)
              Padding(
                padding: const EdgeInsets.all(12),
                child: ErrorBanner(message: c.error),
              ),
            if (wide)
              Expanded(
                child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Expanded(child: _menuPanel()),
                  const SizedBox(width: 12),
                  SizedBox(width: 380, child: _cartPanel()),
                  const SizedBox(width: 4),
                ]),
              )
            else ...[
              Expanded(child: _menuPanel()),
              _cartBar(),
            ],
          ]),
        ),
      ),
    );
  }

  /// Menu column: search box + breadcrumb row + the drill grid.
  Widget _menuPanel() {
    return Column(children: [
      _searchBar(),
      Expanded(child: _menuGrid()),
    ]);
  }

  Widget _searchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
      child: TextField(
        key: const Key('menu-search'),
        controller: _search,
        onChanged: (v) => setState(() => _query = v),
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          isDense: true,
          hintText: 'Search items (name / SKU) across all menus',
          prefixIcon: const Icon(Icons.search),
          suffixIcon: _query.isEmpty
              ? null
              : IconButton(
                  key: const Key('menu-search-clear'),
                  tooltip: 'Clear search',
                  onPressed: () {
                    _search.clear();
                    setState(() => _query = '');
                  },
                  icon: const Icon(Icons.clear),
                ),
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }

  Widget _breadcrumbs() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Row(children: [
        if (_breadcrumb.isNotEmpty)
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
              Text(_breadcrumb.isEmpty ? 'All menus' : 'Menu',
                  style: const TextStyle(color: PosTheme.tealSoft, fontSize: 15)),
              for (final n in _breadcrumb) ...[
                const Text(' › ', style: TextStyle(color: PosTheme.tealSoft)),
                Text(n.name, style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600)),
              ],
            ]),
          ),
        ),
        // Explicit way home, always available once drilled.
        if (_breadcrumb.isNotEmpty)
          TextButton(
            key: const Key('menu-root'),
            onPressed: _root,
            style: TextButton.styleFrom(foregroundColor: PosTheme.tealSoft),
            child: const Text('All menus'),
          ),
      ]),
    );
  }

  Widget _menuGrid() {
    final results = _searchResults;
    final searching = results != null;

    final entries = <Widget>[];
    if (searching) {
      // Search spans every assigned/active item, regardless of drill location.
      for (final item in results) {
        entries.add(_itemCard(item));
      }
    } else {
      for (final node in _scopeNodes) {
        entries.add(_nodeCard(node));
      }
      for (final id in _scopeItemIds) {
        final item = c.config.itemById(id);
        if (item != null) entries.add(_itemCard(item));
      }
    }

    if (entries.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            searching ? 'No item matches “${_query.trim()}”.' : 'No items in this section yet.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: PosTheme.slate),
          ),
        ),
      );
    }

    // Tile size follows the AVAILABLE WIDTH, not the entry count. ~255px per
    // tile at ratio 0.98 gives bigger cards with real room for an UPLOADED
    // image (the picture must actually be visible), while still keeping several
    // choices per row on a scaled 10" tablet.
    return LayoutBuilder(
      builder: (context, box) {
        final cols = (box.maxWidth / 255).floor().clamp(2, 9);
        return GridView.count(
          crossAxisCount: cols,
          padding: const EdgeInsets.all(8),
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
          childAspectRatio: 0.98,
          children: entries,
        );
      },
    );
  }

  /// Uploaded tile images, memoized per (asset key, sync generation). A tile
  /// rebuild must not refetch, but a NEW config sync must re-look: the first sync
  /// after an upload is what actually lands the bytes.
  final Map<String, Future<Uint8List?>> _tileImages = {};

  Future<Uint8List?> _tileImage(String key) => _tileImages.putIfAbsent(
        '$key@${widget.session.lastSyncAt?.microsecondsSinceEpoch ?? 0}',
        () async {
          try {
            final inject = widget.mediaBytes;
            if (inject != null) return await inject(key);
            return await widget.session.mediaSync?.bytesFor(key);
          } catch (_) {
            return null; // best-effort: a missing image falls back to the icon
          }
        },
      );

  /// The outlet's UPLOADED image when its bytes are already cached on this
  /// tablet; the built-in [fallback] icon otherwise. Never a blank tile: an
  /// image that has not synced yet shows the icon, exactly as before.
  Widget _tilePicture(String? key, Widget fallback) {
    if (key == null || key.isEmpty) return fallback;
    return FutureBuilder<Uint8List?>(
      future: _tileImage(key),
      builder: (context, snap) {
        final bytes = snap.data;
        if (bytes == null || bytes.isEmpty) return fallback;
        return ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Image.memory(
            bytes,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            filterQuality: FilterQuality.medium,
            width: double.infinity,
          ),
        );
      },
    );
  }

  Widget _nodeCard(MenuNode node) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: () => _drill(node),
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), border: Border.all(color: PosTheme.line)),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Expanded(
              child: _tilePicture(
                node.imageKey,
                const Center(child: Icon(Icons.folder_outlined, color: PosTheme.teal, size: 46)),
              ),
            ),
            const SizedBox(height: 6),
            Text(node.name, textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 17, color: PosTheme.ink)),
          ]),
        ),
      ),
    );
  }

  Widget _itemCard(MenuItem item) {
    final price = _priceOf(item);
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: () => _addItem(item),
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), border: Border.all(color: PosTheme.line)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _tilePicture(
                  item.imageKey,
                  Center(
                    child: Icon(item.vatMode == money.VatScMode.none ? Icons.fastfood_outlined : Icons.local_dining, color: PosTheme.petrol, size: 46),
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Text(item.name, maxLines: 2, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 17, color: PosTheme.ink)),
              Text(price == null ? '—' : _money(price), style: const TextStyle(color: PosTheme.teal, fontWeight: FontWeight.w700, fontSize: 15)),
            ],
          ),
        ),
      ),
    );
  }

  double? _priceOf(MenuItem item) => item.priceLevels.isEmpty ? null : item.priceLevels.first.price;

  /// Remove an UNSENT line from the persistent panel (same path as the sheet).
  Future<void> _removeLine(CartLine line) async {
    try {
      final ok = await c.removeFromCart(line);
      if (!mounted) return;
      if (!ok) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(c.error ?? 'Could not remove the item.')));
      }
    } on CartError {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('This line is already sent — cancel it instead.')),
      );
    }
  }

  /// Persistent right-hand cart preview (tablet landscape) matching the mockup:
  /// header `Cart · <table>` + `N UNSENT`, the line list (qty × name, per-line
  /// subtotal, sent/unsent marker + cancel/remove), Subtotal, and the order
  /// actions. This is NOT the modal `_CartSheet` — it stays visible beside the
  /// menu.
  Widget _cartPanel() {
    final unsent = c.cart.lines.where((l) => !l.sent).length;
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: PosTheme.line),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Row(children: [
            Expanded(
              child: Text('Cart · ${c.tableName ?? '—'}',
                  style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16, color: PosTheme.ink)),
            ),
            if (unsent > 0)
              Container(
                key: const Key('cart-unsent-tag'),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(color: PosTheme.tealSoft, borderRadius: BorderRadius.circular(6)),
                child: Text('$unsent UNSENT',
                    style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: PosTheme.ink)),
              ),
          ]),
        ),
        const Divider(height: 1),
        Expanded(child: _cartLines()),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
          child: Row(children: [
            const Expanded(child: Text('Subtotal', style: TextStyle(fontWeight: FontWeight.w700))),
            Text(_money(c.cart.total),
                style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18, color: PosTheme.petrol)),
          ]),
        ),
        _cartActions(),
        const SizedBox(height: 10),
      ]),
    );
  }

  Widget _cartLines() {
    if (c.cart.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text('No items yet.', style: TextStyle(color: PosTheme.slate)),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: c.cart.lines.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (_, i) {
        final line = c.cart.lines[i];
        return ListTile(
          dense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 12),
          title: Text('${line.qty}× ${line.name}',
              maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
          subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            // The picked modifiers belong WITH their item — an operator must see
            // what was chosen, not just the parent menu.
            if (line.modifiers.isNotEmpty)
              Text(
                line.modifiers.map((m) => m.qty > 1 ? '${m.qty}× ${m.name}' : m.name).join(' · '),
                key: Key('line-mods-${line.lineId ?? line.localKey ?? line.itemId}'),
                style: const TextStyle(fontSize: 11.5, color: PosTheme.petrol, fontWeight: FontWeight.w600),
              ),
            Text(
                '${line.failed ? 'FAILED' : line.pending ? 'UNSYNCED' : line.sent ? 'SENT' : 'UNSENT'} · ${_money(line.lineSubtotal)}',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: line.failed
                      ? PosTheme.danger
                      : line.pending
                          ? PosTheme.warn
                          : line.sent
                              ? PosTheme.ok
                              : PosTheme.slate)),
          ]),
          trailing: line.sent
              ? IconButton(
                  key: Key('line-cancel-${line.lineId ?? line.itemId}'),
                  tooltip: 'Cancel item',
                  onPressed: c.busy ? null : () => _cancelLine(line),
                  icon: const Icon(Icons.cancel_outlined, color: PosTheme.danger),
                )
              : IconButton(
                  key: Key('line-remove-${line.lineId ?? line.itemId}'),
                  tooltip: 'Remove',
                  onPressed: c.busy ? null : () => _removeLine(line),
                  icon: const Icon(Icons.delete_outline, color: PosTheme.danger),
                ),
        );
      },
    );
  }

  Widget _cartActions() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        if (c.hasUnsyncedLines)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(children: [
              const Icon(Icons.cloud_off, size: 14, color: PosTheme.warn),
              const SizedBox(width: 6),
              const Expanded(
                child: Text('Items not synced to the server yet — they send automatically.',
                    key: Key('unsynced-reason'), style: TextStyle(fontSize: 11, color: PosTheme.slate)),
              ),
              TextButton(
                key: const Key('panel-sync-now'),
                onPressed: c.busy ? null : _syncNow,
                child: const Text('Sync now'),
              ),
            ]),
          ),
        if (c.hasUnsentLines)
          const Row(children: [
            Icon(Icons.info_outline, size: 14, color: PosTheme.slate),
            SizedBox(width: 6),
            Expanded(
              child: Text('New lines not sent yet — send before payment.',
                  key: Key('send-gate-reason'), style: TextStyle(fontSize: 11, color: PosTheme.slate)),
            ),
          ]),
        if (c.hasUnsentLines) const SizedBox(height: 6),
        if (c.hasUnsentLines)
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              key: const Key('panel-send-cart'),
              style: FilledButton.styleFrom(
                  backgroundColor: PosTheme.teal, foregroundColor: PosTheme.ink, minimumSize: const Size(0, 44)),
              onPressed: c.busy ? null : _sendCart,
              icon: const Icon(Icons.send),
              label: const Text('Send cart'),
            ),
          ),
        if (!c.cart.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                key: const Key('panel-preview-printout'),
                onPressed: c.busy ? null : _printoutPreview,
                icon: const Icon(Icons.print_outlined, size: 18),
                label: const Text('Printout preview'),
              ),
            ),
          ),
        if (c.pricing != null || c.canCancel)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(children: [
              if (c.pricing != null)
                Expanded(
                  child: OutlinedButton.icon(
                    key: const Key('panel-discount'),
                    onPressed: c.busy ? null : _openPricing,
                    icon: const Icon(Icons.local_offer_outlined, size: 18),
                    label: const Text('Discount'),
                  ),
                ),
              if (c.pricing != null && c.canCancel) const SizedBox(width: 8),
              if (c.canCancel)
                Expanded(
                  child: OutlinedButton.icon(
                    key: const Key('panel-cancel-order'),
                    onPressed: c.busy ? null : _cancelOrder,
                    icon: const Icon(Icons.cancel_outlined, size: 18),
                    label: const Text('Cancel order'),
                  ),
                ),
            ]),
          ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton(
            key: const Key('panel-payment'),
            style: OutlinedButton.styleFrom(minimumSize: const Size(0, 46)),
            // GATE: payment stays disabled until every cart line is sent.
            onPressed: c.canPay ? _pay : null,
            child: const Text('Payment'),
          ),
        ),
      ]),
    );
  }

  Widget _cartBar() {
    if (c.cart.isEmpty) return const SizedBox.shrink();
    final p = c.pricing;
    final master = p?.applied;
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        color: PosTheme.petrol,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (master != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(children: [
                const Icon(Icons.local_offer, size: 16, color: PosTheme.teal),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '${p!.selection.discount != null ? 'Discount' : 'Voucher'}: ${master.name} − ${_money(money.round2(p.amountFor(c.cart.total)))}',
                    key: const Key('cart-pricing'),
                    style: const TextStyle(color: PosTheme.teal, fontSize: 13, fontWeight: FontWeight.w700),
                  ),
                ),
              ]),
            ),
          if (c.hasUnsentLines)
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Row(children: [
                Icon(Icons.info_outline, size: 16, color: PosTheme.tealSoft),
                SizedBox(width: 6),
                Expanded(
                  child: Text('New lines not sent yet — send the cart before payment.',
                      key: Key('send-gate-reason'),
                      style: TextStyle(color: PosTheme.tealSoft, fontSize: 13)),
                ),
              ]),
            ),
          Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text('${c.cart.itemCount} item(s)', style: const TextStyle(color: PosTheme.tealSoft, fontSize: 13)),
              Text(_money(c.cart.total), style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w800)),
            ]),
          ),
          if (c.pricing != null)
            TextButton.icon(
              key: const Key('cart-discount'),
              onPressed: c.busy ? null : _openPricing,
              icon: const Icon(Icons.local_offer_outlined),
              label: const Text('Discount'),
            ),
          TextButton.icon(
            onPressed: c.busy ? null : _openCart,
            icon: const Icon(Icons.receipt_long),
            label: const Text('Cart'),
          ),
          const SizedBox(width: 8),
          if (c.hasUnsentLines) ...[
            FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: PosTheme.teal, foregroundColor: PosTheme.ink),
              onPressed: c.busy ? null : _sendCart,
              icon: const Icon(Icons.send),
              label: const Text('Send cart'),
            ),
            const SizedBox(width: 8),
          ],
          OutlinedButton(
            style: OutlinedButton.styleFrom(
              foregroundColor: PosTheme.tealSoft,
              side: const BorderSide(color: PosTheme.teal, width: 1.5),
              minimumSize: const Size(64, 48),
            ),
            // GATE: payment stays disabled until every cart line is sent.
            onPressed: c.canPay ? _pay : null,
            child: const Text('Payment'),
          ),
          ]),
        ]),
      ),
    );
  }

  String _money(double v) => money.moneyLabel(v, c.config.shift.currencyLabel);
}

class _PickResult {
  _PickResult(this.level, this.qty, this.mods);
  final int level;
  final int qty;
  final List<CartModifier> mods;
}

/// A single, STABLE listenable for the order-entry body. Replaces the
/// `Listenable.merge([c, c.pricing])` that build() rebuilt every frame — that
/// minted a fresh object per rebuild, so the panel re-subscribed on every frame
/// and a notification could be dropped in the swap (the "pick a product, nothing
/// shows until Refresh" bug). This forwards from the order controller and its
/// (possibly still-null, later-assigned) pricing controller, re-hooking pricing
/// whenever the order replaces it.
class _OrderPanelListenable extends ChangeNotifier {
  _OrderPanelListenable(this._order) {
    _order.addListener(_onOrderChanged);
    _hookPricing();
  }

  final OrderController _order;
  PricingController? _pricing;

  void _onOrderChanged() {
    _hookPricing();
    notifyListeners();
  }

  /// Follow `order.pricing` as it appears/replaces (startOrder/resume build it
  /// after this object exists). Only re-subscribes when the instance changes.
  void _hookPricing() {
    final p = _order.pricing;
    if (identical(p, _pricing)) return;
    _pricing?.removeListener(notifyListeners);
    _pricing = p;
    _pricing?.addListener(notifyListeners);
  }

  @override
  void dispose() {
    _order.removeListener(_onOrderChanged);
    _pricing?.removeListener(notifyListeners);
    super.dispose();
  }
}

class _ItemOptionsSheet extends StatefulWidget {
  const _ItemOptionsSheet({required this.item, required this.currency});
  final MenuItem item;

  /// The outlet currency label, so every price reads the same everywhere.
  final String currency;

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

  String _money(double v) => money.moneyLabel(v, widget.currency);
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
      final alerts = c.printAlerts;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: alerts.isEmpty ? PosTheme.ok : PosTheme.petrol,
        content: Row(children: [
          Icon(alerts.isEmpty ? Icons.check_circle : Icons.print_disabled, color: Colors.white),
          const SizedBox(width: 10),
          Expanded(
            child: Text(alerts.isEmpty
                ? 'Sent — batch ${c.lastBatchLabel}. Lines already sent are not reprinted.'
                : 'Sent — batch ${c.lastBatchLabel}. ${alerts.first}'),
          ),
        ]),
      ));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(c.error ?? 'Send failed')));
    }
  }

  @override
  Widget build(BuildContext context) {
    // The cart sheet is its own route — it MUST listen to the controller, else
    // a remove/send leaves the list and total stale until it is reopened.
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
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
                  subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    if (line.modifiers.isNotEmpty)
                      Text(
                        line.modifiers.map((m) => m.qty > 1 ? '${m.qty}× ${m.name}' : m.name).join(' · '),
                        style: const TextStyle(fontSize: 11.5, color: PosTheme.petrol, fontWeight: FontWeight.w600),
                      ),
                    Text(line.sent ? 'sent to kitchen' : _money(line.lineSubtotal)),
                  ]),
                  trailing: line.sent
                      ? const Text('sent', style: TextStyle(color: PosTheme.ok, fontWeight: FontWeight.w600))
                      : IconButton(
                          tooltip: 'Remove',
                          onPressed: c.busy
                              ? null
                              : () async {
                                  try {
                                    final ok = await c.removeFromCart(line);
                                    if (!context.mounted) return;
                                    if (!ok) {
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        SnackBar(content: Text(c.error ?? 'Could not remove the item.')),
                                      );
                                    }
                                  } on CartError {
                                    if (!context.mounted) return;
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(content: Text('This line is already sent — cancel it instead.')),
                                    );
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
      },
    );
  }

  String _money(double v) => money.moneyLabel(v, widget.controller.config.shift.currencyLabel);
}

/// Bottom sheet for choosing a discount/voucher while taking the order.
class _PricingSheet extends StatelessWidget {
  const _PricingSheet({required this.pricing, required this.currency});
  final PricingController pricing;

  /// Outlet currency label from the server config (display only).
  final String currency;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
        child: ListenableBuilder(
          listenable: pricing,
          builder: (_, __) {
            final empty = pricing.applied == null &&
                !pricing.pending &&
                pricing.availableDiscounts.isEmpty &&
                pricing.availableVouchers.isEmpty;
            return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Discount / Voucher', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
              const SizedBox(height: 12),
              if (empty)
                const Text('No discount or voucher is available for this bill.',
                    style: TextStyle(color: PosTheme.slate))
              else
                PricingPanel(controller: pricing, currency: currency),
            ]);
          },
        ),
      ),
    );
  }
}

/// Small modal that collects a non-empty reason (cancel/void approval needs one).
class _ReasonDialog extends StatefulWidget {
  const _ReasonDialog({required this.title, required this.hint});
  final String title;
  final String hint;

  @override
  State<_ReasonDialog> createState() => _ReasonDialogState();
}

class _ReasonDialogState extends State<_ReasonDialog> {
  final _reason = TextEditingController();

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final valid = _reason.text.trim().isNotEmpty;
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        key: const Key('reason-field'),
        controller: _reason,
        autofocus: true,
        maxLines: 2,
        onChanged: (_) => setState(() {}),
        decoration: InputDecoration(hintText: widget.hint),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: valid ? () => Navigator.pop(context, _reason.text.trim()) : null,
          child: const Text('Confirm'),
        ),
      ],
    );
  }
}

/// Per-item cancel of a SENT line: pick the quantity (1..line.qty) and a
/// mandatory reason (mockup 21). Returns `(qty, reason)` or null when dismissed.
/// Compact ± stepper for the cancel dialog: small, aligned, and it shows the
/// ceiling ("/ N") on the same line instead of dropping it underneath.
class _CancelQtyStepper extends StatelessWidget {
  const _CancelQtyStepper({required this.value, required this.max, required this.onChanged});

  final int value;
  final int max;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      IconButton(
        visualDensity: VisualDensity.compact,
        tooltip: 'Less',
        onPressed: value > 1 ? () => onChanged(value - 1) : null,
        icon: const Icon(Icons.remove_circle_outline),
      ),
      SizedBox(
        width: 36,
        child: Text('$value',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
      ),
      IconButton(
        visualDensity: VisualDensity.compact,
        tooltip: 'More',
        onPressed: value < max ? () => onChanged(value + 1) : null,
        icon: const Icon(Icons.add_circle_outline),
      ),
      Text('/ $max', style: const TextStyle(color: PosTheme.slate, fontSize: 13)),
    ]);
  }
}

class _CancelLineDialog extends StatefulWidget {
  const _CancelLineDialog({required this.line, required this.currency});
  final CartLine line;

  /// Outlet currency label (display only) for the line price.
  final String currency;

  @override
  State<_CancelLineDialog> createState() => _CancelLineDialogState();
}

class _CancelLineDialogState extends State<_CancelLineDialog> {
  int _qty = 1;
  final _reason = TextEditingController();

  @override
  void initState() {
    super.initState();
    _qty = widget.line.qty;
  }

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final maxQty = widget.line.qty;
    final valid = _reason.text.trim().isNotEmpty && _qty >= 1 && _qty <= maxQty;
    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
      titlePadding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
      contentPadding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
      title: const Row(children: [
        Icon(Icons.remove_shopping_cart_outlined, color: PosTheme.danger),
        SizedBox(width: 10),
        Expanded(
          child: Text('Cancel sent item', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
        ),
      ]),
      content: SizedBox(
        width: 440,
        // Keyboard-safe: the reason field must never be shoved off the dialog.
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: PosTheme.mist,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: PosTheme.line),
                ),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(widget.line.name,
                      style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15, color: PosTheme.ink)),
                  const SizedBox(height: 2),
                  Text(
                    '${widget.line.qty} × ${money.moneyLabel(widget.line.unitPrice, widget.currency)}'
                    '   ·   line ${money.moneyLabel(widget.line.lineSubtotal, widget.currency)}',
                    style: const TextStyle(color: PosTheme.slate, fontSize: 12.5),
                  ),
                ]),
              ),
              const SizedBox(height: 18),
              Row(children: [
                const Expanded(
                  child: Text('Quantity to cancel',
                      style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                ),
                _CancelQtyStepper(
                  value: _qty,
                  max: maxQty,
                  onChanged: (v) => setState(() => _qty = v),
                ),
              ]),
              const SizedBox(height: 16),
              TextField(
                key: const Key('cancel-line-reason'),
                controller: _reason,
                autofocus: true,
                minLines: 2,
                maxLines: 3,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  labelText: 'Reason (required)',
                  hintText: 'e.g. wrong item, guest changed their mind',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Keep item')),
        FilledButton(
          key: const Key('cancel-line-confirm'),
          onPressed: valid ? () => Navigator.pop(context, (_qty, _reason.text.trim())) : null,
          child: const Text('Request cancellation'),
        ),
      ],
    );
  }
}