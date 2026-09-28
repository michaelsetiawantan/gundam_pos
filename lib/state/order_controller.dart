import 'package:flutter/foundation.dart';

import 'package:gundam_pos/api/api_client.dart';
import 'package:gundam_pos/api/pos_api.dart';
import 'package:gundam_pos/logic/cart.dart';
import 'package:gundam_pos/logic/money.dart' as money;
import 'package:gundam_pos/logic/print_payload.dart';
import 'package:gundam_pos/logic/shift_window.dart';
import 'package:gundam_pos/models/config_models.dart';
import 'package:gundam_pos/services/print_dispatcher.dart';

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
  });

  final PosApi posApi;
  final String tenantId;
  final TenantConfig config;
  final String? deviceAssetId;

  /// The outlet print path (from the app session). Null → printing is a no-op.
  final PrintDispatcher? printer;

  /// Shift window gate (AUTOMATIC meal-shift). Null → derived from [config].
  final ShiftGate? shiftGate;

  ShiftGate get shiftRules => shiftGate ?? ShiftGate(config.shift);

  String? orderId;
  String? tableName;
  String? guestName;
  bool started = false;

  /// When the server opened the order (`order.openedAt`, ISO-8601). Feeds the
  /// recap-window check on a pre-midnight hanging order at payment time.
  /// Null when the server ships no/unparseable `openedAt`.
  DateTime? openedAt;

  final Cart cart = Cart();
  String? lastBatchLabel;
  int captainBatchCount = 0;

  /// Honest print warnings from the last send-cart (never blocks the sale).
  List<String> printAlerts = const [];

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

  Future<bool> startOrder({
    String? tableId,
    String? tableName,
    Map<String, dynamic>? guest,
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
      final r = await posApi.createOrder(
        tenantId: tenantId,
        tableId: tableId,
        tableName: tableName,
        guest: guest,
      );
      final order = r['order'] as Map<String, dynamic>;
      orderId = order['id'] as String?;
      openedAt = DateTime.tryParse((order['openedAt'] as String?) ?? '')?.toLocal();
      tableName = (order['tableName'] ?? tableName) as String?;
      guestName = guest?['name'] as String?;
      started = orderId != null;
      return started;
    } on PosApiException catch (e) {
      error = _message('Could not open the order', e);
      return false;
    } on PosNetworkException {
      error = 'No network — cannot open the order.';
      return false;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// Add an item to the server cart. The server returns the priced line
  /// (already modifier-inclusive); we fold it into one cart row.
  Future<CartLine?> addItem(
    MenuItem item, {
    int levelIndex = 0,
    int qty = 1,
    List<CartModifier> mods = const [],
  }) async {
    busy = true;
    error = null;
    notifyListeners();
    try {
      final r = await posApi.addLine(orderId!, body: {
        'itemId': item.id,
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
      });
      final line = r['line'] as Map<String, dynamic>;
      final cartLine = CartLine(
        itemId: item.id,
        name: line['itemName'] as String? ?? item.name,
        sku: item.sku,
        qty: ((line['qty'] as num?) ?? qty).toInt(),
        priceLevelIndex: ((line['priceLevelIndex'] as num?) ?? levelIndex).toInt(),
        // Server `unitPrice` is modifier-INCLUSIVE, so modifiers are folded here.
        unitPrice: money.round2(((line['unitPrice'] as num?) ?? 0).toDouble()),
        vatMode: _modeFrom(line['vatMode'] as String?),
        scMode: _modeFrom(line['scMode'] as String?),
        modifiers: const [],
        sent: (line['sentToKitchen'] as bool?) ?? false,
      );
      cart.addLine(cartLine);
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

  /// Send the cart: snapshot unsent lines into the next captain batch (already
  /// sent lines are never reprinted — server marks them sentToKitchen).
  Future<bool> sendCart() async {
    if (cart.isEmpty) return false;
    busy = true;
    error = null;
    notifyListeners();
    try {
      final r = await posApi.sendCart(orderId!);
      final batch = r['batch'] as Map<String, dynamic>?;
      lastBatchLabel = batch?['label'] as String?;
      captainBatchCount = ((batch?['sequence'] as num?) ?? captainBatchCount).toInt() + 1;
      final justSent = [for (final l in cart.lines) if (!l.sent) l];
      final batchIndex = _batchSeq++;
      for (final line in cart.lines) {
        if (!line.sent) line.sent = true;
      }
      // Print the just-sent batch: captain sheet(s) + a bev label per item.
      // Never blocks or fails the sale — warnings are surfaced, not thrown.
      final items = [for (final l in justSent) PrintItem.fromCartLine(l, batchIndex: batchIndex)];
      printAlerts = await _printSendCart(items);
      return true;
    } on PosApiException catch (e) {
      error = e.code == 'nothing_to_send' ? 'Nothing new to send.' : _message('Could not send the cart', e);
      return false;
    } on PosNetworkException {
      error = 'No network — cart not sent.';
      return false;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> discard() {
    // The order stays open on the server; leave the local flow.
    notifyListeners();
    return Future.value();
  }

  /// Remove an unsent cart line (server delete is handled separately; for the
  /// live cart this just drops the local row). Re-throws [CartError] for sent.
  void removeFromCart(CartLine line, {int qty = 1}) {
    cart.removeLine(line, qty: qty);
    notifyListeners();
  }

  static Future<List<Map<String, dynamic>>> openOrders(PosApi posApi, String tenantId) async {
    final r = await posApi.listOpenOrders(tenantId);
    final orders = r['orders'] as List? ?? const [];
    return orders.cast<Map<String, dynamic>>();
  }

  Future<List<String>> _printSendCart(List<PrintItem> items) async {
    final d = printer;
    if (d == null || items.isEmpty) return const [];
    try {
      final out = await d.printSendCart(items: items, tableName: tableName);
      return out.alerts;
    } catch (_) {
      return const ['Print path errored — sale unaffected.'];
    }
  }

  String _message(String prefix, PosApiException e) => e.isRateLimited ? 'Too many attempts. Wait and retry.' : '$prefix (${e.code}).';
}

money.VatScMode _modeFrom(String? s) => switch (s) {
      'INCLUDE' => money.VatScMode.include,
      'EXCLUDE' => money.VatScMode.exclude,
      _ => money.VatScMode.none,
    };