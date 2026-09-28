import 'dart:convert';

import 'package:gundam_pos/api/api_client.dart';
import 'package:gundam_pos/api/pos_api.dart';
import 'package:gundam_pos/state/app_session.dart';
import 'package:gundam_pos/state/session_store.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Scriptable fake Gundam backend for app/screen tests. Routes by path and
/// returns canned or overridable responses, so the AppSession + UI can be
/// exercised without a server. Mirrors the real server JSON shapes.
class FakeBackend {
  FakeBackend({this.loginError, this.loginBody});

  /// If set, the pos-login route returns this error code at the given status.
  (String, int)? loginError; // e.g. ('session_active_other_device', 409)
  Map<String, dynamic>? loginBody;

  /// Overridable `license` block sent by both pos-login and config/sync — lets a
  /// test drive the GRACE / nearing-expiry reminder. Default = ACTIVE, far out.
  Map<String, dynamic>? licenseBody;

  /// Pricing route controls (POST /api/pos/orders/[id]/pricing):
  /// [pricingPending] → below-threshold `{approval:{...}}`; [pricingError] →
  /// `{error:code}`; otherwise the applied `{order:{discountId,voucherId}}`.
  bool pricingPending = false;
  String? pricingError;
  Map<String, dynamic>? lastPricingBody;
  /// Last settle request body, so tests can assert what the tablet sent.
  Map<String, dynamic>? lastSettleBody;

  /// `openedAt` the fake order-create route returns. Defaults to now; set it to
  /// simulate a pre-midnight hanging order.
  DateTime? openOrderOpenedAt;

  final _serverVersions = <String, int>{};

  /// Increments per send-cart so tests can tell a fresh batch from a reprint.
  int _sendBatchSeq = 0;

  void setVersions(Map<String, int> v) => _serverVersions
    ..clear()
    ..addAll(v);

  /// Northstar demo config payloads (MASTER + OUTLET), tolerated by the client.
  static Map<String, dynamic> northstarMaster() => {
        'categories': [
          {'id': 'cat-bev', 'parentId': null, 'name': 'Beverages', 'children': []},
          {'id': 'cat-food', 'parentId': null, 'name': 'Food', 'children': []},
        ],
        'items': [
          {
            'id': 'item-espresso',
            'categoryId': 'cat-bev',
            'name': 'Espresso',
            'itemcode': 'ESP',
            'sku': 'NSTAR-NS-ESP',
            'active': true,
            'vatMode': 'EXCLUDE',
            'vatRate': '11',
            'scMode': 'NONE',
            'priceLevels': [
              {'levelIndex': 0, 'label': '', 'price': '25000'},
              {'levelIndex': 1, 'label': 'Double', 'price': '32000'},
            ],
          },
          {
            'id': 'item-nasi',
            'categoryId': 'cat-food',
            'name': 'Nasi Goreng Special',
            'itemcode': 'NGS',
            'sku': 'NSTAR-NS-NGS',
            'active': true,
            'vatMode': 'INCLUDE',
            'vatRate': '11',
            'scMode': 'NONE',
            'priceLevels': [
              {'levelIndex': 0, 'label': '', 'price': '45000'},
              {'levelIndex': 1, 'label': 'Large', 'price': '55000'},
            ],
            'itemModifiers': [
              {'modifierId': 'mod-egg', 'modifier': {'id': 'mod-egg', 'name': 'Add egg', 'price': '5000', 'isOpenMod': false}},
              {'modifierId': 'mod-crackers', 'modifier': {'id': 'mod-crackers', 'name': 'Crackers', 'price': '2000', 'isOpenMod': false}},
            ],
          },
        ],
        'menuLayouts': [
          {
            'id': 'layout-main',
            'name': 'Main Menu',
            'active': true,
            'nodes': [
              {'id': 'node-bev', 'parentId': null, 'name': 'Beverages', 'sortOrder': 0, 'assignments': [{'itemId': 'item-espresso'}]},
              {'id': 'node-food', 'parentId': null, 'name': 'Main Dishes', 'sortOrder': 1, 'assignments': [{'itemId': 'item-nasi'}]},
            ],
          },
        ],
        'paymentMasters': [
          {'id': 'm-cash', 'code': 'CASH', 'name': 'Cash', 'type': 'CASH'},
          {'id': 'm-card', 'code': 'CARD', 'name': 'Card', 'type': 'NON_CASH'},
        ],
      };

  /// Client-shaped printer model the OUTLET payload ships (transport +
  /// addressing + routing + strict item-level itemRoutes).
  static Map<String, dynamic> northstarPrintModel() => {
        'printers': [
          {'id': 'pr-front', 'name': 'Front Receipt', 'type': 'RECEIPT', 'transport': 'NETWORK', 'ip': '10.0.0.9', 'port': 9100, 'widthMm': 80, 'supportsRasterImage': false, 'shared': true, 'active': true, 'retryCount': 3, 'retryTimeoutSec': 20},
          {'id': 'pr-captain', 'name': 'Captain Station', 'type': 'KITCHEN', 'transport': 'NETWORK', 'ip': '10.0.0.10', 'port': 9100, 'widthMm': 80, 'shared': true, 'active': true},
          {'id': 'pr-bev', 'name': 'Bar Label', 'type': 'LABEL', 'transport': 'NETWORK', 'ip': '10.0.0.11', 'port': 9100, 'widthMm': 58, 'active': true},
          {'id': 'pr-bt', 'name': 'BT Label', 'type': 'LABEL', 'transport': 'BLUETOOTH', 'bluetoothMac': 'AA:BB:CC', 'widthMm': 58, 'active': true},
        ],
        'routing': {
          'BILL': [
            {'printerId': 'pr-front', 'batchStep': null},
          ],
          'CAPTAIN_ORDER': [
            {'printerId': 'pr-captain', 'batchStep': 0},
            {'printerId': 'pr-captain', 'batchStep': 1},
          ],
          'BEV_LABEL': [
            {'printerId': 'pr-bev', 'batchStep': null},
          ],
        },
        'itemRoutes': [
          {'itemId': 'item-espresso', 'captainPrinterId': 'pr-captain', 'bevPrinterId': 'pr-bev'},
          {'itemId': 'item-nasi', 'captainPrinterId': 'pr-captain', 'bevPrinterId': null},
        ],
      };

  static Map<String, dynamic> northstarOutlet() => {
        'paymentMethods': [
          {'id': 'pm-cash', 'masterId': 'm-cash', 'displayName': 'Cash', 'enabled': true, 'sortOrder': 0, 'master': {'id': 'm-cash', 'code': 'CASH', 'type': 'CASH'}},
          {'id': 'pm-card', 'masterId': 'm-card', 'displayName': 'Visa', 'enabled': true, 'sortOrder': 1, 'master': {'id': 'm-card', 'code': 'CARD', 'type': 'NON_CASH'}},
        ],
        'shift': {'shiftType': 'MANUAL', 'defaultHouseBank': '500000', 'roundingMode': 'UP', 'timezone': 'Asia/Jakarta', 'currencyLabel': 'Rp'},
        'tables': [
          {'id': 'tbl-a1', 'name': 'A1', 'enabled': true, 'capacity': 4},
          {'id': 'tbl-a2', 'name': 'A2', 'enabled': true, 'capacity': 6},
        ],
        'printRoutings': [],
        ...northstarPrintModel(),
      };

  http.Response _json(int status, Object body) =>
      http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

  /// Faithful ACTIVE licence coverage (server adds from/to + grace window).
  static Map<String, dynamic> activeLicense({int daysLeft = 365}) {
    final now = DateTime.now();
    final to = now.add(Duration(days: daysLeft));
    return {
      'state': 'ACTIVE',
      'grace': false,
      'validFrom': now.subtract(const Duration(days: 30)).toUtc().toIso8601String(),
      'validTo': to.toUtc().toIso8601String(),
      'graceStart': to.add(const Duration(days: 1)).toUtc().toIso8601String(),
      'graceDays': 0,
      'graceEndsAt': to.toUtc().toIso8601String(),
    };
  }

  Map<String, dynamic> get _license => licenseBody ?? activeLicense();

  AppSession createSession({SessionStore? store}) {
    final client = ApiClient(
      baseUrl: 'http://fake.test',
      httpClient: MockClient(_handle),
      authProvider: () => null,
    );
    final api = PosApi(client);
    return AppSession(posApi: api, sessionStore: store ?? InMemorySessionStore());
  }

  Future<http.Response> _handle(http.Request req) async {
    final path = req.url.path;
    switch (path) {
      case '/api/auth/pos-redeem':
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        return _json(201, {
          'deviceToken': 'dev-token-abc',
          'groupId': 'g1',
          'tenantId': 't1',
          'shortcode': 'NSTAR-POS1',
          'deviceId': body['deviceId'],
        });
      case '/api/auth/pos-login':
        if (loginError != null) return _json(loginError!.$2, {'error': loginError!.$1});
        return _json(200, loginBody ??
            {
              'sessionId': 'sess-123',
              'groupId': 'g1',
              'tenantId': 't1',
              'outlet': {'id': 't1', 'name': 'Northstar'},
              'user': {'id': 'u1', 'email': 'c@x.demo', 'fullName': 'Cashier One'},
              'license': _license,
            });
      case '/api/auth/logout':
        return _json(200, {'ok': true});
      case '/api/pos/config/state':
        return _json(200, {
          'tenantId': 't1',
          'versions': {
            for (final e in (_serverVersions.isEmpty ? const {'MASTER': 1, 'OUTLET': 1, 'FORMAT': 0, 'MEDIA': 0} : _serverVersions).entries) e.key: {'version': e.value, 'updatedAt': DateTime.now().toIso8601String()},
          },
          'ttl': {'nonCredentialDays': 3},
        });
      case '/api/pos/config/sync':
        return _json(200, {
          'tenantId': 't1',
          'needsFull': ['MASTER', 'OUTLET'],
          'upToDate': ['FORMAT', 'MEDIA'],
          'full': {'MASTER': northstarMaster(), 'OUTLET': northstarOutlet()},
          'license': _license,
        });
      case '/api/pos/shifts':
        if (req.method == 'POST') {
          final body = jsonDecode(req.body) as Map<String, dynamic>;
          return _json(201, {
            'shift': {
              'id': 'shift-1',
              'tenantId': 't1',
              'userId': 'u1',
              'shiftType': 'MANUAL',
              'startAt': DateTime.now().toIso8601String(),
              'openHousebank': body['openHousebank'] ?? 500000,
              'status': 'OPEN',
            },
          });
        }
        return _json(200, {});
      case '/api/pos/orders':
        if (req.method == 'POST') {
          final body = jsonDecode(req.body) as Map<String, dynamic>;
          return _json(201, {
            'order': {
              'id': 'order-1',
              'status': 'OPEN',
              'tableName': body['tableName'],
              'openedById': 'u1',
              'openedAt': (openOrderOpenedAt ?? DateTime.now()).toIso8601String(),
              'lines': <Map<String, dynamic>>[],
            },
          });
        }
        return _json(200, {'orders': <Map<String, dynamic>>[]});
      default:
        final addLineOrder = _addLineOrderId(path, req.method);
        if (addLineOrder != null) {
          final body = jsonDecode(req.body) as Map<String, dynamic>;
          final itemId = body['itemId'] as String?;
          final level = ((body['priceLevelIndex'] as num?) ?? 0).toInt();
          final base = itemId == 'item-espresso' ? (level == 1 ? 32000 : 25000) : (level == 1 ? 55000 : 45000);
          final modExtra = (body['mods'] as List? ?? const []).fold<double>(0, (s, m) {
            final id = (m as Map)['modifierId'] as String?;
            return s + ({'mod-egg': 5000, 'mod-crackers': 2000}[id] ?? 0);
          });
          return _json(201, {
            'line': {
              'id': 'line-$itemId',
              'orderId': addLineOrder,
              'itemId': itemId,
              'priceLevelIndex': level,
              'itemName': itemId == 'item-espresso' ? 'Espresso' : 'Nasi Goreng Special',
              'qty': body['qty'] ?? 1,
              'unitPrice': base + modExtra,
              'vatMode': itemId == 'item-espresso' ? 'EXCLUDE' : 'INCLUDE',
              'scMode': 'NONE',
              'sentToKitchen': false,
              'mods': body['mods'] ?? const [],
            },
          });
        }
        if (req.method == 'POST' && path.endsWith('/send-cart')) {
          final seq = _sendBatchSeq++;
          return _json(200, {
            'batch': {'id': 'b${seq + 1}', 'label': String.fromCharCode(65 + seq), 'sequence': seq},
            'sent': <Map<String, dynamic>>[],
            'printJobs': <Map<String, dynamic>>[],
          });
        }
        if (req.method == 'POST' && path.endsWith('/pricing')) {
          final body = jsonDecode(req.body) as Map<String, dynamic>;
          lastPricingBody = body;
          if (pricingError != null) return _json(400, {'error': pricingError});
          if (pricingPending) {
            return _json(200, {'approval': {'approvalId': 'app-1', 'status': 'PENDING'}});
          }
          return _json(200, {
            'order': {'discountId': body['discountId'], 'voucherId': body['voucherId']},
          });
        }
        if (req.method == 'POST' && path.endsWith('/settle')) {
          final body = jsonDecode(req.body) as Map<String, dynamic>;
          lastSettleBody = body;
          return _json(200, {
            'bill': {
              'transactionId': 'txn-1',
              'receiptId': body['receiptId'],
              'orderId': _orderIdFrom(path),
              'status': 'PAID',
              'total': 45000,
              'change': 0,
              'tipsPending': 0,
            },
            'sync': {'status': 'synced', 'transactionId': 'txn-1'},
          });
        }
        if (req.method == 'POST' && RegExp(r'^/api/pos/shifts/[^/]+/close$').hasMatch(path)) {
          return _json(200, {
            'closing': {
              'id': 'shift-1',
              'status': 'CLOSED',
              'endAt': DateTime.now().toIso8601String(),
              'openHousebank': 500000,
              'closeHousebank': 600000,
              'cashSales': 120000,
              'payout': 0,
              'expectedCash': 620000,
              'variance': -20000,
              'guestUpsert': {'upserted': 2, 'guests': 5},
            },
          });
        }
        if (req.method == 'POST' && path.endsWith('/void')) {
          return _json(200, {'approval': {'id': 'app-1', 'status': 'PENDING'}});
        }
        return _json(404, {'error': 'not_found'});
    }
  }

  // Route matchers (keep the switch small).
  static final _ordersAddLineRe = RegExp(r'^/api/pos/orders/([^/]+)/lines/?$');
  static final _orderPathRe = RegExp(r'^/api/pos/orders/([^/]+)');
  String? _addLineOrderId(String path, String method) {
    if (method != 'POST') return null;
    final m = _ordersAddLineRe.firstMatch(path);
    return m?.group(1);
  }
  String? _orderIdFrom(String path) => _orderPathRe.firstMatch(path)?.group(1);
}