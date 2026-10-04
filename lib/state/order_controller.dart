import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:gundam_pos/api/api_client.dart';
import 'package:gundam_pos/api/pos_api.dart';
import 'package:gundam_pos/data/pos_store.dart';
import 'package:gundam_pos/logic/cart.dart';
import 'package:gundam_pos/logic/money.dart' as money;
import 'package:gundam_pos/logic/order_number.dart';
import 'package:gundam_pos/logic/print_payload.dart';
import 'package:gundam_pos/logic/shift_window.dart';
import 'package:gundam_pos/models/config_models.dart';
import 'package:gundam_pos/services/print_dispatcher.dart';
import 'package:gundam_pos/state/pricing_controller.dart';

/// Orchestrates a single live order: create/add-line/send-cart against the
/// server (which is authoritative for pricing + hanging checks) and keeps the
/// local cart in step. The cart is the thin execution surface (order entry).
class OrderController extends ChangeNotifier {
  OrderController({
    required this.posApi,
    required this.tenantId,
    required this.config,
    this.deviceAssetId,
    this.printer,
    this.shiftGate,
    this.pushStore,
    this.orderNumbers,
    this.shortcode,
    this.onPrintAlerts,
  });

  final PosApi posApi;
  final String tenantId;
  final TenantConfig config;
  final String? deviceAssetId;

  /// Client-side order-number generator (offline order creation). When null an
  /// offline start falls back to the legacy "no network" error.
  final OrderNumberGenerator? orderNumbers;

  /// This device's POS shortcode — embedded in every client-minted order number
  /// so two POS devices can never mint the same id.
  final String? shortcode;

  /// Durable outbox for optimistic offline line adds. When present, [addItem]
  /// is optimistic (line shows instantly, queued in the outbox, flushed when
  /// online). When null the legacy synchronous server-only path runs unchanged.
  final PushStore? pushStore;

  /// The outlet print path (from the app session). Null → printing is a no-op.
  final PrintDispatcher? printer;

  /// Shift window gate (AUTOMATIC meal-shift). Null → derived from [config].
  final ShiftGate? shiftGate;

  ShiftGate get shiftRules => shiftGate ?? ShiftGate(config.shift);

  String? orderId;
  String? tableName;
  String? guestName;
  bool started = false;

  /// True while this order exists ONLY locally: it was opened offline with a
  /// client-minted [orderId] and its `order_create` is still queued, so the
  /// server has not confirmed the order yet. Lines must not be sent until it
  /// clears (the create is flushed first, idempotently, by the order id).
  bool pendingCreate = false;

  /// The order's discount/voucher, available from the moment the order is
  /// linked to the server. Shared with the payment screen so a discount applied
  /// while taking the order is exactly the one settled. Null before [orderId].
  PricingController? pricing;

  /// Cashier who OPENED the order (`order.openedByName`). The payer can differ
  /// on a shared table, so the print payload must not assume they are the same.
  String openedByName = '';

  /// Numeric table NUMBER: the table label when it is purely digits, else ''.
  /// A free-text table ("Terrace") has no number — never invent one.
  String get tableNumber {
    final t = (tableName ?? '').trim();
    return RegExp(r'^\d+$').hasMatch(t) ? t : '';
  }

  /// When the server opened the order (`order.openedAt`, ISO-8601). Feeds the
  /// recap-window check on a pre-midnight hanging order at payment time.
  /// Null when the server ships no/unparseable `openedAt`.
  DateTime? openedAt;

  final Cart cart = Cart();
  String? lastBatchLabel;
  int captainBatchCount = 0;

  /// Honest print warnings from the last send-cart (never blocks the sale).
  /// Filled LATE — the captain/bev print runs OFF the send path, so this is set
  /// when the printer finally answers, not when [sendCart] returns.
  List<String> printAlerts = const [];

  /// Delivered the moment a fire-and-forget print finishes with warnings, so the
  /// operator still sees them after the order screen has moved on. Wired to the
  /// app session's shared alert surface; never called with an empty list.
  final void Function(List<String> alerts)? onPrintAlerts;

  /// True while any cart line has NOT been sent to the kitchen yet.
  bool get hasUnsentLines => cart.lines.any((l) => !l.sent);

  /// Payment is allowed only once the whole cart has been sent (PRD 'Order
  /// Flow' step 9: bill print only after send-cart then payment — paying a cart
  /// that was never sent is not allowed). Already-sent lines are never re-sent,
  /// so a re-send only carries the new lines.
  bool get canPay => !cart.isEmpty && !hasUnsentLines;

  int _batchSeq = 0;

  String? error;
  bool busy = false;

  /// The server's machine-readable code behind [error] (e.g. `reason_required`),
  /// so a screen can react to a specific refusal instead of guessing by text.
  String? lastErrorCode;

  Future<bool> startOrder({
    String? tableId,
    String? tableName,
    Map<String, dynamic>? guest,
    bool offline = false,
  }) async {
    busy = true;
    error = null;
    notifyListeners();
    try {
      // PRD: outside the meal-shift range no transaction may start.
      final block = shiftRules.blockNewTransaction();
      if (block != null) {
        error = block;
        return false;
      }
      // The table label for the offline path: a table picked by id has no
      // `tableName` argument, so resolve it from the synced config.
      final resolvedName = (tableName == null || tableName.trim().isEmpty)
          ? _tableNameById(tableId)
          : tableName;
      if (offline) {
        return await _startOrderLocal(tableId: tableId, tableName: resolvedName, guest: guest);
      }
      try {
        final r = await posApi.createOrder(
          tenantId: tenantId,
          tableId: tableId,
          tableName: tableName,
          guest: guest,
        );
        final order = r['order'] as Map<String, dynamic>;
        orderId = order['id'] as String?;
        openedAt = DateTime.tryParse((order['openedAt'] as String?) ?? '')?.toLocal();
        openedByName = (order['openedByName'] as String?) ?? '';
        // Assign the FIELD, not the shadowing parameter — otherwise the table
        // label never reaches the cart/panel/print (bare `tableName` here is the
        // method argument, which shadows `this.tableName`).
        this.tableName = (order['tableName'] ?? tableName) as String?;
        guestName = guest?['name'] as String?;
        started = orderId != null;
        pendingCreate = false;
        pricing = _newPricing();
        return started;
      } on PosNetworkException {
        // Offline-first: the tablet mints the id (unique — it carries the POS
        // shortcode), opens a LOCAL order and queues an `order_create` so the
        // server accepts it idempotently when the network returns.
        return await _startOrderLocal(tableId: tableId, tableName: resolvedName, guest: guest);
      }
    } on PosApiException catch (e) {
      error = _message('Could not open the order', e);
      return false;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// Open a LOCAL order without the server. [orderId] is the client-minted
  /// number; an `order_create` item is queued in the durable outbox so a restart
  /// keeps it and the next sync creates it on the server (idempotent).
  Future<bool> _startOrderLocal({
    String? tableId,
    String? tableName,
    Map<String, dynamic>? guest,
  }) async {
    final gen = orderNumbers;
    final sc = shortcode;
    final store = pushStore;
    if (gen == null || sc == null || sc.isEmpty || store == null) {
      error = 'No network — cannot open the order.';
      return false;
    }
    final id = await gen.next(sc);
    final now = DateTime.now();
    orderId = id;
    this.tableName = tableName;
    guestName = guest?['name'] as String?;
    openedAt = now;
    openedByName = '';
    started = true;
    pendingCreate = true;
    // No server order yet → no pricing controller until the create lands.
    pricing = null;
    await store.enqueue('order_create', id, {
      'orderId': id,
      'tenantId': tenantId,
      if (tableId != null) 'tableId': tableId,
      if (tableName != null && tableName.isNotEmpty) 'tableName': tableName,
      if (guest != null) 'guest': guest,
      'openedAt': now.toIso8601String(),
    });
    return true;
  }

  /// Resolve a table's display name from the synced config (offline path).
  String? _tableNameById(String? tableId) {
    if (tableId == null) return null;
    for (final t in config.tables) {
      if (t.id == tableId) return t.name;
    }
    return null;
  }

  /// Add an item to the cart. With a [pushStore] this is OPTIMISTIC: a locally
  /// priced line appears instantly (pending), is enqueued in the durable outbox
  /// and flushed best-effort. Without one the legacy synchronous path runs.
  Future<CartLine?> addItem(
    MenuItem item, {
    int levelIndex = 0,
    int qty = 1,
    List<CartModifier> mods = const [],
  }) async {
    final id = orderId;
    if (id == null || id.isEmpty) {
      error = 'This order is not linked to the server yet — go back to Open Tables and reopen it.';
      notifyListeners();
      return null;
    }
    final store = pushStore;
    if (store == null) return _addItemServer(item, levelIndex: levelIndex, qty: qty, mods: mods);

    // Optimistic: insert a locally-priced pending line FIRST so the panel shows
    // it the instant it is picked, even with no network.
    final key = _newLocalKey();
    final line = CartLine(
      itemId: item.id,
      name: item.name,
      sku: item.sku,
      qty: qty,
      priceLevelIndex: levelIndex,
      unitPrice: money.round2(_previewPrice(item, levelIndex)),
      modifiers: List<CartModifier>.of(mods),
      vatMode: item.vatMode,
      scMode: item.scMode,
      pending: true,
      localKey: key,
    );
    // MERGE identical picks into ONE line (same item + same modifiers + same
    // price level, still in the same batch and not yet sent): the cart shows a
    // single row whose qty grows, exactly like the printed bill will.
    CartLine? twin;
    for (final l in cart.lines) {
      // The server merges by client line key, so a line the server already
      // knows can still absorb the new qty (it never merges into a SENT line).
      if (l.signature() == line.signature() && !l.sent && l.localKey != null) {
        twin = l;
        break;
      }
    }
    if (twin != null && twin.localKey != null) {
      twin.qty += qty;
      twin.pending = true;
      error = null;
      notifyListeners();
      // ONE queued row per line: re-enqueue under the SAME key with the new
      // TOTAL qty, so the server gets a single line instead of two.
      await store.enqueue('order_line', twin.localKey!,
          _linePayload(id, item.id, levelIndex, twin.qty, mods, clientLineKey: twin.localKey));
      await flushPendingLines();
      return twin;
    }

    // A fresh line: 1:1 with its queued server line.
    cart.addLine(line, merge: false);
    error = null;
    notifyListeners();

    await store.enqueue('order_line', key,
        _linePayload(id, item.id, levelIndex, qty, mods, clientLineKey: key));
    await flushPendingLines();
    return line;
  }

  /// Legacy synchronous add: POST the line and fold the server's priced line.
  /// The server returns the priced line (already modifier-inclusive); we fold
  /// it into one cart row.
  Future<CartLine?> _addItemServer(
    MenuItem item, {
    required int levelIndex,
    required int qty,
    required List<CartModifier> mods,
  }) async {
    busy = true;
    error = null;
    notifyListeners();
    try {
      final r = await posApi.addLine(orderId!, body: _lineBody(item.id, levelIndex, qty, mods));
      final line = r['line'] as Map<String, dynamic>;
      final cartLine = CartLine(
        lineId: line['id'] as String?,
        itemId: item.id,
        name: line['itemName'] as String? ?? item.name,
        sku: item.sku,
        // Server Decimals serialise as JSON strings ("45000"); a hard
        // `as num?` cast threw a TypeError and dropped the whole line — the
        // field bug where a picked item never appeared until manual Refresh.
        qty: _intOf(line['qty'], qty),
        priceLevelIndex: _intOf(line['priceLevelIndex'], levelIndex),
        // Server `unitPrice` is modifier-INCLUSIVE, so modifiers are folded here.
        unitPrice: money.round2(_num(line['unitPrice'])),
        vatMode: _modeFrom(line['vatMode'] as String?),
        scMode: _modeFrom(line['scMode'] as String?),
        // Names only (price 0): the server's unitPrice is modifier-inclusive, so
        // keeping the prices would double-count in unitPriceWithMods. The
        // operator still sees WHICH modifiers were picked.
        modifiers: _displayMods(line['mods']),
        sent: (line['sentToKitchen'] as bool?) ?? false,
      );
      // 1:1 with the server line — NEVER merge, or a later delete targets the
      // wrong OrderLine (the field bug: a deleted item came back on reload).
      cart.addLine(cartLine, merge: false);
      return cartLine;
    } on PosApiException catch (e) {
      error = _message('Could not add item', e);
      return null;
    } on PosNetworkException {
      error = 'No network — item not added.';
      return null;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// True when a line has not been confirmed by the server yet (queued or
  /// rejected). Blocks send-cart so a half-synced bill never reaches the kitchen.
  bool get hasUnsyncedLines => cart.lines.any((l) => l.pending || l.failed);

  bool _flushing = false;
  int _localSeq = 0;

  String _newLocalKey() => '${DateTime.now().microsecondsSinceEpoch}-${_localSeq++}';

  /// Local preview price from the item's price level (0 when the server ships
  /// no price levels — the value is replaced by the server's on adoption).
  double _previewPrice(MenuItem item, int levelIndex) {
    for (final p in item.priceLevels) {
      if (p.levelIndex == levelIndex) return p.price;
    }
    return item.priceLevels.isNotEmpty ? item.priceLevels.first.price : 0;
  }

  /// The wire body for one add (mods folded in exactly as the server expects).
  Map<String, dynamic> _lineBody(String itemId, int levelIndex, int qty, List<CartModifier> mods,
          {String? clientLineKey}) =>
      {
        'itemId': itemId,
        // The tablet's key for this line: the server MERGES the qty when the same
        // key is added again (identical picks), and an offline replay can never
        // create a duplicate line.
        if (clientLineKey != null && clientLineKey.isNotEmpty) 'clientLineKey': clientLineKey,
        'priceLevelIndex': levelIndex,
        'qty': qty,
        'mods': [
          for (final m in mods)
            {
              if (m.modifierId != null) 'modifierId': m.modifierId,
              if (m.openText != null) 'openText': m.openText,
              'qty': m.qty,
            },
        ],
      };

  /// The durable outbox payload for one line (carries `orderId` so a session-wide
  /// flush can POST it without the order controller).
  Map<String, dynamic> _linePayload(String orderId, String itemId, int levelIndex, int qty,
          List<CartModifier> mods, {String? clientLineKey}) =>
      {
        'orderId': orderId,
        ..._lineBody(itemId, levelIndex, qty, mods, clientLineKey: clientLineKey),
      };

  CartLine? _lineByLocalKey(String key) {
    for (final l in cart.lines) {
      if (l.localKey == key) return l;
    }
    return null;
  }

  /// Adopt a server line onto the local pending row: id + server (modifier-
  /// inclusive) price + sent flag. Modifier PRICES are dropped (the server price
  /// already includes them, else the total double-counts) but their NAMES are
  /// kept so the cart can show what was ordered.
  void _adoptServerLine(Map<String, dynamic> server, CartLine local) {
    local.lineId = server['id'] as String?;
    local.unitPrice = money.round2(_num(server['unitPrice']));
    local.modifiers = _displayMods(server['mods']);
    local.sent = (server['sentToKitchen'] as bool?) ?? local.sent;
    local.pending = false;
    local.failed = false;
  }

  /// Modifier names for DISPLAY: price forced to 0 because [CartLine.unitPrice]
  /// is already modifier-inclusive on any server-adopted line.
  static List<CartModifier> _displayMods(Object? raw) {
    if (raw is! List) return const [];
    final out = <CartModifier>[];
    for (final m in raw) {
      if (m is! Map) continue;
      final name = (m['name'] ?? m['openText'] ?? '').toString();
      if (name.isEmpty) continue;
      out.add(CartModifier(
        modifierId: m['modifierId'] as String?,
        name: name,
        price: 0,
        qty: ((m['qty'] as num?) ?? 1).toInt(),
        openText: m['openText'] as String?,
      ));
    }
    return out;
  }

  /// Flush every queued `order_line` for THIS order, FIFO. Success → adopt the
  /// server line + drop the queue entry. Network failure → stop and leave the
  /// queue. Server rejection → mark the line failed, drop the entry, set [error].
  /// Idempotent: a line that already has a server id is never POSTed twice.
  Future<int> flushPendingLines() async {
    final store = pushStore;
    final id = orderId;
    if (store == null || id == null || id.isEmpty || _flushing) return 0;
    _flushing = true;
    var adopted = 0;
    try {
      // Offline-created order: it must exist on the server BEFORE any of its
      // lines can be added (the lines carry this client id). Idempotent — a
      // create that already landed returns the SAME order.
      if (pendingCreate && !await _flushOrderCreate(store, id)) return 0;
      final items = await store.pending();
      for (final it in items) {
        if (it['type'] != 'order_line') continue;
        final key = '${it['id']}';
        final payload = it['payload_json'];
        final local = _lineByLocalKey(key);
        if (local == null) {
          // The line was removed locally — drop the stale queue entry.
          await store.remove('order_line', key);
          continue;
        }
        if (local.lineId != null) {
          // Already adopted — never POST twice.
          await store.remove('order_line', key);
          continue;
        }
        if (payload is! Map) {
          await store.remove('order_line', key);
          continue;
        }
        final p = payload.cast<String, dynamic>();
        final orderId = (p['orderId'] as String?) ?? id;
        try {
          final r = await posApi.addLine(orderId, body: {
            'itemId': p['itemId'],
            'priceLevelIndex': p['priceLevelIndex'] ?? local.priceLevelIndex,
            'qty': p['qty'] ?? local.qty,
            'mods': p['mods'] ?? const [],
          });
          _adoptServerLine(r['line'] as Map<String, dynamic>, local);
          await store.remove('order_line', key);
          adopted++;
        } on PosNetworkException {
          break; // offline — keep the queue, try again later
        } on PosApiException catch (e) {
          local.pending = false;
          local.failed = true;
          await store.remove('order_line', key);
          error = _message('Could not add item', e);
        }
      }
    } catch (_) {
      // Never let a flush error break the flow.
    } finally {
      _flushing = false;
      notifyListeners();
    }
    return adopted;
  }

  /// Create THIS order on the server from its queued `order_create` entry, using
  /// the client-minted id. Returns true once the order exists server-side.
  /// Network failure → false (keep it queued, lines keep waiting). A server
  /// rejection → drop the poison entry (never wedge the queue) and surface it.
  Future<bool> _flushOrderCreate(PushStore store, String id) async {
    Map<String, dynamic> p = const {};
    for (final it in await store.pending()) {
      if (it['type'] == 'order_create' && '${it['id']}' == id) {
        final raw = it['payload_json'];
        if (raw is Map) p = raw.cast<String, dynamic>();
        break;
      }
    }
    try {
      final r = await posApi.createOrder(
        tenantId: tenantId,
        clientOrderId: id,
        tableId: p['tableId'] as String?,
        tableName: p['tableName'] as String?,
        guest: (p['guest'] as Map?)?.cast<String, dynamic>(),
      );
      final order = r['order'] as Map<String, dynamic>?;
      if (order != null) {
        openedAt = DateTime.tryParse((order['openedAt'] as String?) ?? '')?.toLocal() ?? openedAt;
        openedByName = (order['openedByName'] as String?) ?? openedByName;
        tableName = (order['tableName'] ?? tableName) as String?;
      }
      await store.remove('order_create', id);
      pendingCreate = false;
      pricing ??= _newPricing();
      return true;
    } on PosNetworkException {
      return false; // still offline — lines must keep waiting
    } on PosApiException catch (e) {
      await store.remove('order_create', id);
      pendingCreate = false;
      error = _message('Could not open the order', e);
      return false;
    }
  }

  /// Re-queue failed/unconfirmed local lines and flush them again. Returns true
  /// once every cart line is server-backed.
  Future<bool> retryUnsyncedLines() async {
    final store = pushStore;
    if (store == null) return !cart.lines.any((l) => l.lineId == null);
    final id = orderId;
    if (id == null || id.isEmpty) return false;
    for (final l in cart.lines) {
      if (l.lineId == null && l.localKey != null && l.failed) {
        l.failed = false;
        l.pending = true;
        await store.enqueue('order_line', l.localKey!, _linePayload(id, l.itemId, l.priceLevelIndex, l.qty, l.modifiers));
      }
    }
    await flushPendingLines();
    return !cart.lines.any((l) => l.lineId == null);
  }

  /// Send the cart: snapshot unsent lines into the next captain batch (already
  /// sent lines are never reprinted — server marks them sentToKitchen).
  Future<bool> sendCart() async {
    if (cart.isEmpty) return false;
    final id = orderId;
    if (id == null || id.isEmpty) {
      // No server order to send to: fail LOUDLY instead of a swallowed
      // null-check throw (the tap that "does nothing").
      error = 'This order is not linked to the server yet — go back to Open Tables and reopen it.';
      notifyListeners();
      return false;
    }
    busy = true;
    error = null;
    notifyListeners();
    try {
      // Offline-first: when there is a durable outbox, do NOT require the server
      // to allow the send. Flush what we can, and if any line is still
      // unconfirmed (offline or rejected) send the cart LOCALLY — mark the lines
      // sent, print captain/bev now, and queue an `order_send` for the push.
      if (pushStore != null) {
        await flushPendingLines();
        final unsynced = cart.lines.where((l) => l.lineId == null).length;
        if (unsynced > 0) return await _sendCartLocal(id);
      }
      final r = await posApi.sendCart(id);
      final batch = r['batch'] as Map<String, dynamic>?;
      lastBatchLabel = batch?['label'] as String?;
      captainBatchCount = _intOf(batch?['sequence'], captainBatchCount) + 1;
      final justSent = [for (final l in cart.lines) if (!l.sent) l];
      final batchIndex = _batchSeq++;
      for (final line in cart.lines) {
        if (!line.sent) line.sent = true;
      }
      // Print the just-sent batch OFF the send path: captain sheet(s) + a bev
      // label per item. Never blocks or fails the sale — the operator gets back
      // to the cart instantly; warnings arrive later via [printAlerts] and
      // [onPrintAlerts] (3 attempts × 20s must not stall order entry).
      // RAW rows: the dispatcher decides per ticket type — captain sheets merge
      // identical rows, BEV labels print one sticker PER UNIT.
      final items = [for (final l in justSent) PrintItem.fromCartLine(l, batchIndex: batchIndex)];
      unawaited(_printSendCartAndNotify(items));
      return true;
    } on PosApiException catch (e) {
      // `nothing_to_send` = the SERVER already has every line sent (our earlier
      // send committed but its response was lost — flaky outlet Wi-Fi). The
      // server is authoritative: reconcile the local cart. Leaving the lines
      // "unsent" would keep Payment disabled FOREVER — the exact dead end the
      // operator reported ("tidak ada lanjutannya").
      if (e.code == 'nothing_to_send') {
        for (final line in cart.lines) {
          if (!line.sent) line.sent = true;
        }
        printAlerts = const ['Nothing was re-sent — the server already had every line.'];
        return true;
      }
      error = _message('Could not send the cart', e);
      return false;
    } on PosNetworkException {
      // Offline with no outbox → nowhere to keep the send; keep the honest error.
      if (pushStore == null) {
        error = 'No network — cart not sent. Retry the send; do not re-enter the items.';
        return false;
      }
      return _sendCartLocal(id);
    } catch (_) {
      // Any unexpected failure must still reach the operator, never a silent tap.
      error = 'Could not send the cart — unexpected error. Go back to Open Tables and reopen the order.';
      return false;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// Send the cart to the kitchen WITHOUT the server: mark the unsent lines SENT
  /// locally (the payment gate reads LOCAL sent state), print captain/bev on this
  /// device's printer path NOW, and queue an `order_send` so the server is
  /// reconciled on the next push (FIFO after this order's create + lines).
  Future<bool> _sendCartLocal(String id) async {
    final justSent = [for (final l in cart.lines) if (!l.sent) l];
    if (justSent.isEmpty) return true; // nothing new — already sent locally
    final batchIndex = _batchSeq++;
    for (final line in cart.lines) {
      if (!line.sent) line.sent = true;
    }
    captainBatchCount += 1;
    lastBatchLabel = String.fromCharCode(65 + (captainBatchCount - 1) % 26);
    final store = pushStore;
    if (store != null) {
      try {
        await store.enqueue('order_send', id, {'orderId': id});
      } catch (_) {/* the local send already happened; push retries later */}
    }
    final items = [for (final l in justSent) PrintItem.fromCartLine(l, batchIndex: batchIndex)];
    unawaited(_printSendCartAndNotify(items));
    return true;
  }

  Future<void> discard() {
    // The order stays open on the server; leave the local flow.
    notifyListeners();
    return Future.value();
  }

  /// Adopt an EXISTING hanging server order (from the Open Tables list) so the
  /// operator can continue it: same bill id + table, existing lines folded into
  /// the local cart (sent lines stay sent → never reprinted). Counterpart of
  /// [discard]. Returns false when the payload carries no order id.
  bool resumeFrom(Map<String, dynamic> order) {
    final id = order['id'] as String?;
    if (id == null || id.isEmpty) return false;
    orderId = id;
    // A locally-opened order (client id, `order_create` still queued) re-enters
    // the same pending state so adding items keeps the create-first ordering.
    final local = order['localOnly'] == true;
    pendingCreate = local;
    pricing = local ? null : _newPricing();
    final table = order['table'];
    tableName = (order['tableName'] ?? (table is Map ? table['name'] : null)) as String?;
    openedAt = DateTime.tryParse((order['openedAt'] as String?) ?? '')?.toLocal();
    openedByName = (order['openedByName'] as String?) ?? '';
    started = true;
    cart.clear(keepSent: false);
    _adoptLines(order);
    notifyListeners();
    return true;
  }

  /// Fold the server's authoritative lines into the local cart (each server
  /// OrderLine → one cart row, carrying its [CartLine.lineId]).
  void _adoptLines(Map<String, dynamic> order) {
    // The order row also carries the applied pricing — adopt it so a discount
    // authorised elsewhere (an approval decided on this POS by an approver's
    // credentials, or another device) shows up here.
    pricing?.adoptFromOrder(order);
    for (final raw in (order['lines'] as List? ?? const [])) {
      final l = raw as Map<String, dynamic>;
      cart.addLine(
        CartLine(
          lineId: l['id'] as String?,
          itemId: (l['itemId'] as String?) ?? '',
          name: (l['itemName'] as String?) ?? '',
          sku: (l['sku'] as String?) ?? '',
          qty: _intOf(l['qty'], 1),
          priceLevelIndex: _intOf(l['priceLevelIndex'], 0),
          unitPrice: money.round2(_num(l['unitPrice'])),
          vatMode: _modeFrom(l['vatMode'] as String?),
          scMode: _modeFrom(l['scMode'] as String?),
          modifiers: _displayMods(l['mods']),
          sent: (l['sentToKitchen'] as bool?) ?? false,
        ),
        merge: false,
      );
    }
  }

  /// Whether this order can be cancelled from the POS (OPEN, linked to server).
  bool get canCancel => started && (orderId?.isNotEmpty ?? false);

  /// Request cancellation of this OPEN order. The server decides: an order with
  /// nothing sent to the kitchen is closed immediately; an order already sent
  /// goes to a PENDING approval (web decides). Returns 'canceled', 'pending', or
  /// null on failure (see [error]).
  Future<String?> cancelOrder(String reason) async {
    final id = orderId;
    if (id == null || id.isEmpty) {
      error = 'This order is not linked to the server yet.';
      notifyListeners();
      return null;
    }
    busy = true;
    error = null;
    lastErrorCode = null;
    notifyListeners();
    try {
      final r = await posApi.requestCancel(id, reason: reason);
      if (r['approval'] != null) return 'pending';
      await _dropQueuedFor(id);
      return 'canceled';
    } on PosApiException catch (e) {
      lastErrorCode = e.code;
      final queued = await _hasQueuedCreate(id);
      if (e.code == 'not_found' && queued) {
        // Created offline and never reached the server: cancelling it means
        // withdrawing the queued create, not calling the server.
        await _dropQueuedFor(id);
        cart.clear();
        orderId = null;
        notifyListeners();
        return 'canceled';
      }
      error = _message('Could not cancel the order', e);
      return null;
    } on PosNetworkException {
      error = 'No network — the order was not cancelled.';
      return null;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// Cancel a quantity of an ALREADY-SENT line (per-item cancel, PRD 'Void /
  /// Cancel / Refund'). Sends `{reason, lineId, qty}` to the server, which
  /// decides: nothing sent → immediate CANCELED, else a PENDING approval the web
  /// console resolves. Returns 'pending', 'canceled', or null on failure (see
  /// [error]). The local line is NEVER removed here — the server/web owns the
  /// truth for a sent line (a rejected request must not silently drop it).
  Future<String?> cancelLine(CartLine line, {required int qty, required String reason}) async {
    final id = orderId;
    final lineId = line.lineId;
    if (id == null || id.isEmpty || lineId == null) {
      error = 'This line is not linked to the server yet.';
      notifyListeners();
      return null;
    }
    busy = true;
    error = null;
    lastErrorCode = null;
    notifyListeners();
    try {
      final r = await posApi.requestCancel(id, reason: reason, lineId: lineId, qty: qty);
      if (r['approval'] != null) return 'pending';
      // The server dropped/cancelled the line: pull the authoritative cart so it
      // disappears from the screen NOW, without the operator refreshing.
      await reloadFromServer(quiet: true);
      return 'canceled';
    } on PosApiException catch (e) {
      lastErrorCode = e.code;
      error = _message('Could not cancel the item', e);
      return null;
    } on PosNetworkException {
      error = 'No network — the item was not cancelled.';
      return null;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<bool> _hasQueuedCreate(String orderId) async {
    try {
      final pending = await pushStore?.pending() ?? const [];
      return pending.any((i) => i['type'] == 'order_create' && i['id'] == orderId);
    } catch (_) {
      return false;
    }
  }

  /// The order is CLOSED (cancelled/voided): drop anything still queued for it,
  /// or Open Tables keeps showing the table from the local outbox until a sync
  /// (the field report) and a stale create would be pushed afterwards.
  Future<void> _dropQueuedFor(String orderId) async {
    final store = pushStore;
    if (store == null) return;
    for (final t in const ['order_create', 'order_line']) {
      try {
        await store.remove(t, orderId);
      } catch (_) {/* best-effort */}
    }
  }

  /// Re-read THIS order from the server and rebuild the local cart from its
  /// authoritative lines. Recovery path when tablet and server drifted (a
  /// delete that never reached the server, or a lost send-cart response): after
  /// this the send/payment gate reflects the server, never a stale local guess.
  Future<bool> reloadFromServer({bool quiet = false}) async {
    final id = orderId;
    if (id == null || id.isEmpty) return false;
    busy = true;
    error = null;
    notifyListeners();
    try {
      final r = await posApi.listOpenOrders(tenantId);
      final orders = (r['orders'] as List? ?? const []).cast<Map<String, dynamic>>();
      Map<String, dynamic>? mine;
      for (final o in orders) {
        if (o['id'] == id) {
          mine = o;
          break;
        }
      }
      if (mine == null) {
        error = 'This order is no longer open on the server.';
        return false;
      }
      // Local lines the server has NOT confirmed yet must SURVIVE a reconcile —
      // wiping them would throw away work the operator already did offline
      // (offline-first). They are re-appended after the server truth.
      final unsynced = [for (final l in cart.lines) if (l.lineId == null) l];
      cart.clear(keepSent: false);
      _adoptLines(mine);
      for (final l in unsynced) {
        cart.addLine(l, merge: false);
      }
      tableName = (mine['tableName'] ?? tableName) as String?;
      return true;
    } on PosApiException catch (e) {
      // `quiet` = a lifecycle refresh must not shout on a tablet that is simply
      // offline (it would pop an error banner for a background action).
      if (!quiet) error = _message('Could not refresh the order', e);
      return false;
    } on PosNetworkException {
      if (!quiet) error = 'No network — could not refresh the order.';
      return false;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// Best-effort reconcile when the screen becomes visible again (resume /
  /// return from another screen). Silent when offline.
  Future<void> refreshQuietly() => reloadFromServer(quiet: true);

  /// Remove an unsent line: server FIRST (authoritative), then local. A line the
  /// server never acknowledged (no [CartLine.lineId]) is dropped locally only.
  /// Throws [CartError] for a sent line (the cancel path handles those).
  /// Returns false (with [error] set) when the server refused — the line stays.
  Future<bool> removeFromCart(CartLine line) async {
    if (line.sent) throw CartError('line_already_sent');
    final id = orderId;
    final lineId = line.lineId;
    error = null;
    // A line the server never acknowledged (pending/failed, or adopted before
    // the order was linked): drop it locally and dequeue its outbox entry.
    if (lineId == null) {
      cart.lines.remove(line);
      final store = pushStore;
      if (store != null && line.localKey != null) {
        await store.remove('order_line', line.localKey!);
      }
      notifyListeners();
      return true;
    }
    if (id != null) {
      try {
        await posApi.removeLine(id, lineId);
      } on PosApiException catch (e) {
        if (e.code == 'line_already_sent') {
          // The server already sent it: adopt the truth instead of lying.
          line.sent = true;
          error = 'That line was already sent to the kitchen — use Cancel instead.';
          notifyListeners();
          return false;
        }
        if (e.code == 'line_not_found') {
          // Already gone server-side: safe to drop locally.
          cart.lines.remove(line);
          notifyListeners();
          return true;
        }
        error = _message('Could not remove the item', e);
        notifyListeners();
        return false;
      } on PosNetworkException {
        error = 'No network — item not removed; it is still on the bill.';
        notifyListeners();
        return false;
      }
    }
    cart.lines.remove(line);
    notifyListeners();
    return true;
  }

  static Future<List<Map<String, dynamic>>> openOrders(PosApi posApi, String tenantId) async {
    final r = await posApi.listOpenOrders(tenantId);
    final orders = r['orders'] as List? ?? const [];
    return orders.cast<Map<String, dynamic>>();
  }

  /// A pricing controller for the current server order, or null before it is
  /// linked (no order id → no bill to discount).
  PricingController? _newPricing() {
    final id = orderId;
    if (id == null || id.isEmpty) return null;
    return PricingController(posApi: posApi, orderId: id, config: config, cart: cart);
  }

  @override
  void dispose() {
    pricing?.dispose();
    super.dispose();
  }

  /// Run [printSendCart] without holding the send caller: fill [printAlerts] and
  /// publish any honest warnings when it finally finishes. Never throws.
  Future<void> _printSendCartAndNotify(List<PrintItem> items) async {
    final alerts = await _printSendCart(items);
    printAlerts = alerts;
    if (alerts.isNotEmpty) onPrintAlerts?.call(alerts);
  }

  Future<List<String>> _printSendCart(List<PrintItem> items) async {
    final d = printer;
    if (d == null || items.isEmpty) return const [];
    try {
      final out = await d.printSendCart(items: items, tableName: tableName, tableNumber: tableNumber, openedBy: openedByName);
      return out.alerts;
    } catch (_) {
      return const ['Print path errored — sale unaffected.'];
    }
  }

  String _message(String prefix, PosApiException e) => e.isRateLimited
      ? 'Too many attempts. Wait and retry.'
      : posErrorText(prefix, e.code, status: e.status);
}

money.VatScMode _modeFrom(String? s) => switch (s) {
      'INCLUDE' => money.VatScMode.include,
      'EXCLUDE' => money.VatScMode.exclude,
      _ => money.VatScMode.none,
    };

/// Server Decimals serialise as JSON strings ("45000") or numbers; accept both.
double _num(Object? v) => v is num ? v.toDouble() : double.tryParse('$v') ?? 0;

/// Same tolerance for integer server fields (qty/priceLevelIndex/sequence): a
/// JSON string ("2") must not throw. Falls back when the field is absent.
int _intOf(Object? v, int fallback) =>
    v is num ? v.toInt() : (num.tryParse('$v')?.toInt() ?? fallback);