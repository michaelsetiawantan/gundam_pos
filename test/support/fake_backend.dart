import 'dart:convert';

import 'package:gundam_pos/api/api_client.dart';
import 'package:gundam_pos/api/pos_api.dart';
import 'package:gundam_pos/data/pos_store.dart';
import 'package:gundam_pos/state/app_session.dart';
import 'package:gundam_pos/state/release_store.dart';
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

  /// Offline-first deferred settlement (`POST .../settle-deferred`).
  /// [settleDeferredCalls] counts attempts; [lastSettleDeferredBody] is the last
  /// snapshot; [settleDeferredError] forces a 4xx refusal (e.g. totals_mismatch);
  /// [settleDeferredOffline] forces a transport failure. Idempotent on
  /// `clientSettlementKey` via [seenSettlementKeys] (a repeat → `already:true`).
  int settleDeferredCalls = 0;
  Map<String, dynamic>? lastSettleDeferredBody;
  String? settleDeferredError;
  bool settleDeferredOffline = false;
  final Set<String> seenSettlementKeys = <String>{};

  /// Last print-logs upload body (`POST /api/pos/print-logs`).
  Map<String, dynamic>? lastPrintLogsBody;

  /// `openedAt` the fake order-create route returns. Defaults to now; set it to
  /// simulate a pre-midnight hanging order.
  DateTime? openOrderOpenedAt;

  /// Hanging orders served by `GET /api/pos/orders` (Open Tables source). Set a
  /// non-empty list to exercise the resume/continue path.
  List<Map<String, dynamic>> openOrders = const [];

  /// When true, `GET /api/pos/orders` throws a transport error (offline list) —
  /// drives the local-order-only Open Tables path.
  bool ordersOffline = false;

  /// When true, `POST /api/pos/orders` throws a transport error (offline create).
  bool createOrderOffline = false;

  /// Every order-create body the tablet sent (FIFO).
  final List<Map<String, dynamic>> createdOrderBodies = [];

  /// Order lifecycle calls in the order they arrived: `create:<id>` / `line:<orderId>`.
  final List<String> orderEvents = [];

  /// Shift served by `GET /api/pos/shifts/active` (the restore path). Null =
  /// no OPEN shift on the server (`{shift: null}`).
  Map<String, dynamic>? activeShiftBody;

  /// Last body the tablet sent to `POST /api/pos/shifts` — lets a test assert the
  /// typed opening cash actually reaches the server.
  Map<String, dynamic>? lastShiftOpenBody;

  /// Last body sent to `POST /api/pos/tables/ops` (merge/split/move/lock/…).
  Map<String, dynamic>? lastTableOpsBody;

  /// When set, the tables-ops route answers `{error: code}` at [tableOpsStatus]
  /// instead of a result — drives server refusals (table_locked, order_closed).
  String? tableOpsError;
  int tableOpsStatus = 409;

  /// Result payload served by the tables-ops route on success.
  Map<String, dynamic> tableOpsResult = const {'ok': true};

  /// Body served for `GET /api/pos/version.json`. Default = the server's honest
  /// empty shape ("no release published"), which must NOT read as an update.
  Map<String, dynamic> versionJson = const {};

  /// When set, the version.json route answers this status instead (fetch-failure
  /// tests: an offline/misconfigured server must stay silent).
  int? versionStatus;

  /// A published-release manifest in the server's shape
  /// `{version, versionCode, apk_url, sha256, min_supported_config, mandatory,
  /// changelog, released_at}`.
  static Map<String, dynamic> release({
    String version = '0.3.0',
    int versionCode = 3,
    String apkUrl = 'https://pos.example/gundam-pos-0.3.0.apk',
    String sha256 = '',
    int? minSupportedConfig,
    bool mandatory = false,
    String changelog = 'Faster order entry; fixed the shift recap window.',
    String? releasedAt,
  }) =>
      {
        'version': version,
        'versionCode': versionCode,
        'apk_url': apkUrl,
        'sha256': sha256,
        if (minSupportedConfig != null) 'min_supported_config': minSupportedConfig,
        'mandatory': mandatory,
        'changelog': changelog,
        if (releasedAt != null) 'released_at': releasedAt,
      };

  final _serverVersions = <String, int>{};

  /// Increments per send-cart so tests can tell a fresh batch from a reprint.
  int _sendBatchSeq = 0;

  /// When set, `POST .../send-cart` answers this `{error:code}` (400) instead of
  /// a batch — drives server rejections (nothing_to_send / shift_required / …).
  String? sendCartError;

  /// When true, `POST .../send-cart` throws a transport error (offline network).
  bool sendCartOffline = false;

  /// Order-line ids the tablet DELETEd (`DELETE /orders/[id]/lines/[lineId]`).
  final List<String> removedLineIds = [];

  /// When true, `POST .../lines` throws a transport error (offline add).
  bool addLineOffline = false;

  /// When set, `POST .../lines` answers this `{error:code}` (400) instead of a
  /// line — drives the server-rejection path (item disabled, shift required…).
  String? addLineError;

  /// Every add-line body the tablet sent (FIFO) — lets a test assert the outbox
  /// flushed exactly once per queued line.
  final List<Map<String, dynamic>> addedLineBodies = [];

  /// When true, the cancel route answers `{approval:{...}}` (already-sent order
  /// → approval path) instead of an immediate `{canceled:true}` (nothing sent).
  bool cancelPending = false;

  /// When true the next cancel is refused with `reason_required` (the server
  /// still holds sent lines the cart no longer shows), then the flag clears.
  bool cancelNeedsReason = false;
  Map<String, dynamic>? lastCancelBody;

  /// When true, the settle route returns the bill's money fields as STRINGS
  /// (Prisma Decimal serialises as a string) — the client must still show the
  /// success page instead of throwing on a cast.
  bool settleStringNumbers = false;

  /// When true, `POST .../settle` throws a transport error (server unreachable)
  /// — drives the offline-first LOCAL settle + deferred push.
  bool settleOffline = false;

  // ------------------------------------------------------------ approvals --
  /// PENDING approval rows served by `GET /api/approvals` (server shape:
  /// id/actionType/status/reason/createdAt/requester/order/transaction). The
  /// list route is group-scoped; a non-approver gets 403 via [approvalsError].
  List<Map<String, dynamic>> approvals = [];

  /// When set, `GET /api/approvals` answers this error code at 403 (drives the
  /// "role may not decide" path).
  String? approvalsError;

  /// Count of `GET /api/approvals` calls — lets a test prove the list is
  /// re-pulled after a decision.
  int approvalsListCalls = 0;

  /// When set, `POST /api/approvals/[id]/decide` answers this error code at
  /// [decideStatus] (403 approval_denied / 409 already_decided).
  String? decideError;
  int decideStatus = 403;

  /// When true, the decide route demands delegated credentials: a call with NO
  /// `approverEmail`/`approverPassword` answers 403 `approval_denied` (the
  /// current session may not decide); a call WITH them is checked against
  /// [validApproverEmail]/[validApproverPassword] — mismatch → 401
  /// `invalid_credentials`, match → success.
  bool decideRequiresCredentials = false;
  String? validApproverEmail;
  String? validApproverPassword;

  /// Last approval id + decide body the tablet sent.
  String? lastDecideId;
  Map<String, dynamic>? lastDecideBody;

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
        // Outlet + group identity shipped in the OUTLET domain (mirrors the real
        // server contract so the print tokens have something to resolve).
        'outlet': {
          'id': 't1', 'name': 'Northstar Central', 'shortcode': 'NSC',
          'address': 'Jl. Sudirman 18, Jakarta', 'phone': '021-5578899',
          'socialMedia': '@northstar', 'instagram': '@northstar.id', 'tiktok': '@northstar',
          'email': 'hello@northstar.id', 'timezone': 'Asia/Jakarta', 'currencyLabel': 'IDR',
        },
        'group': {'id': 'g1', 'name': 'Nusantara Hospitality Group', 'shortcode': 'NHG'},
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

  /// Overrides for a PARTIAL config sync: the server only sends the domains that
  /// changed. Defaults to a full first sync (both MASTER + OUTLET).
  List<String> configSyncNeedsFull = const ['MASTER', 'OUTLET'];
  Map<String, dynamic>? configSyncFull;

  Map<String, dynamic> get _license => licenseBody ?? activeLicense();

  /// Every request URL the fake saw, in order — lets tests assert which host
  /// the client actually talked to (runtime-address proof).
  final List<Uri> requested = [];

  AppSession createSession({
    SessionStore? store,
    ServerAddressStore? addressStore,
    ReleaseInfoStore? releaseStore,
    PushStore? pushStore,
  }) {
    final client = ApiClient(
      baseUrl: 'http://fake.test',
      httpClient: MockClient(_handle),
      authProvider: () => null,
    );
    final api = PosApi(client);
    return AppSession(
      posApi: api,
      sessionStore: store ?? InMemorySessionStore(),
      serverAddressStore: addressStore,
      releaseStore: releaseStore,
      pushStore: pushStore,
    );
  }

  Future<http.Response> _handle(http.Request req) async {
    requested.add(req.url);
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
              'user': {'id': 'u1', 'email': 'c@x.demo', 'fullName': 'Cashier One', 'role': 'Cashier'},
              'license': _license,
            });
      case '/api/auth/logout':
        return _json(200, {'ok': true});
      case '/api/pos/version.json':
        if (versionStatus != null) return _json(versionStatus!, {'error': 'unavailable'});
        return _json(200, versionJson);
      case '/api/pos/print-logs':
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        lastPrintLogsBody = body;
        final logs = body['logs'] as List? ?? const [];
        return _json(200, {'accepted': logs.length, 'alreadySeen': 0, 'rejected': 0});
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
          'needsFull': configSyncNeedsFull,
          'upToDate': const ['FORMAT', 'MEDIA'],
          'full': configSyncFull ?? {'MASTER': northstarMaster(), 'OUTLET': northstarOutlet()},
          'license': _license,
        });
      case '/api/pos/shifts/active':
        return _json(200, {'shift': activeShiftBody});
      case '/api/pos/shifts':
        if (req.method == 'POST') {
          final body = jsonDecode(req.body) as Map<String, dynamic>;
          lastShiftOpenBody = body;
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
          createdOrderBodies.add(body);
          if (createOrderOffline) throw http.ClientException('offline');
          final id = (body['clientOrderId'] as String?) ?? 'order-1';
          orderEvents.add('create:$id');
          return _json(201, {
            'order': {
              'id': id,
              'status': 'OPEN',
              'tableName': body['tableName'],
              'openedById': 'u1',
              'openedAt': (openOrderOpenedAt ?? DateTime.now()).toIso8601String(),
              'lines': <Map<String, dynamic>>[],
            },
          });
        }
        if (ordersOffline) throw http.ClientException('offline');
        return _json(200, {'orders': openOrders});
      case '/api/pos/tables/ops':
        lastTableOpsBody = jsonDecode(req.body) as Map<String, dynamic>;
        if (tableOpsError != null) return _json(tableOpsStatus, {'error': tableOpsError});
        return _json(200, {'result': tableOpsResult});
      case '/api/approvals':
        approvalsListCalls++;
        if (approvalsError != null) return _json(403, {'error': approvalsError});
        return _json(200, {
          'approvals': approvals,
          'total': approvals.length,
          'counts': {'PENDING': approvals.length, 'APPROVED': 0, 'REJECTED': 0},
          'page': 1,
          'perPage': 50,
        });
      default:
        final addLineOrder = _addLineOrderId(path, req.method);
        if (addLineOrder != null) {
          final body = jsonDecode(req.body) as Map<String, dynamic>;
          if (addLineOffline) throw http.ClientException('offline');
          if (addLineError != null) return _json(400, {'error': addLineError});
          orderEvents.add('line:$addLineOrder');
          addedLineBodies.add(body);
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
              'mods': [
                // The real server echoes the resolved modifier NAMES (with the
                // price folded into unitPrice); the fake must do the same or a
                // modifier-display test would pass vacuously.
                for (final m in (body['mods'] as List? ?? const []))
                  {
                    ...(m as Map),
                    'name': ({'mod-egg': 'Add egg', 'mod-crackers': 'Crackers'}[(m)['modifierId'] as String?] ??
                        ((m)['openText'] as String?) ??
                        'Option'),
                  },
              ],
            },
          });
        }
        if (req.method == 'POST' && path.endsWith('/send-cart')) {
          if (sendCartOffline) throw http.ClientException('offline');
          if (sendCartError != null) return _json(400, {'error': sendCartError});
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
        if (req.method == 'POST' && path.endsWith('/settle-deferred')) {
          final body = jsonDecode(req.body) as Map<String, dynamic>;
          lastSettleDeferredBody = body;
          settleDeferredCalls++;
          if (settleDeferredOffline) throw http.ClientException('offline');
          if (settleDeferredError != null) return _json(400, {'error': settleDeferredError});
          final key = body['clientSettlementKey']?.toString() ?? '';
          if (seenSettlementKeys.contains(key)) {
            return _json(200, {'settled': true, 'already': true, 'receiptId': body['receiptId']});
          }
          seenSettlementKeys.add(key);
          return _json(201, {
            'settled': true,
            'receiptId': body['receiptId'],
            'transactionId': 'txn-deferred-${seenSettlementKeys.length}',
          });
        }
        if (req.method == 'POST' && path.endsWith('/settle')) {
          final body = jsonDecode(req.body) as Map<String, dynamic>;
          if (settleOffline) throw http.ClientException('offline');
          lastSettleBody = body;
          return _json(200, {
            'bill': {
              'transactionId': 'txn-1',
              'receiptId': body['receiptId'],
              'orderId': _orderIdFrom(path),
              'status': 'PAID',
              // Prisma Decimals serialise as strings in the real server; the
              // flag lets a test drive exactly that shape.
              'total': settleStringNumbers ? '45000' : 45000,
              'change': settleStringNumbers ? '0' : 0,
              'tipsPending': settleStringNumbers ? '0' : 0,
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
        if (req.method == 'DELETE' && _lineDeleteRe.hasMatch(path)) {
          removedLineIds.add(path.split('/').last);
          return _json(200, {'removed': true});
        }
        if (req.method == 'POST' && path.endsWith('/cancel')) {
          lastCancelBody = jsonDecode(req.body) as Map<String, dynamic>;
          // An empty reason on an order the server still considers non-empty is
          // refused, exactly like the real route.
          if (cancelNeedsReason) {
            cancelNeedsReason = false; // one refusal, then it behaves
            return _json(400, {'error': 'reason_required'});
          }
          if (cancelPending) return _json(200, {'approval': {'id': 'app-1', 'status': 'PENDING'}});
          // An accepted cancel REALLY changes the server state: the cancelled
          // line is gone (that is what the tablet must pick up on its own).
          final lineId = lastCancelBody!['lineId'];
          if (lineId is String) {
            openOrders = [
              for (final o in openOrders)
                {...o, 'lines': [for (final l in (o['lines'] as List? ?? const [])) if ((l as Map)['id'] != lineId) l]},
            ];
          }
          return _json(200, {'canceled': true, 'status': 'CANCELED'});
        }
        if (req.method == 'POST' && _decideRe.hasMatch(path)) {
          lastDecideId = _decideRe.firstMatch(path)!.group(1);
          lastDecideBody = jsonDecode(req.body) as Map<String, dynamic>;
          if (decideRequiresCredentials) {
            final email = lastDecideBody!['approverEmail'];
            final pass = lastDecideBody!['approverPassword'];
            if (email == null && pass == null) {
              return _json(403, {'error': 'approval_denied'});
            }
            if (email != validApproverEmail || pass != validApproverPassword) {
              return _json(401, {'error': 'invalid_credentials'});
            }
          }
          if (decideError != null) return _json(decideStatus, {'error': decideError});
          final state = lastDecideBody!['state'];
          approvals.removeWhere((a) => a['id'] == lastDecideId);
          return _json(200, {'approval': {'id': lastDecideId, 'status': state}});
        }
        return _json(404, {'error': 'not_found'});
    }
  }

  // Route matchers (keep the switch small).
  static final _ordersAddLineRe = RegExp(r'^/api/pos/orders/([^/]+)/lines/?$');
  static final _lineDeleteRe = RegExp(r'^/api/pos/orders/[^/]+/lines/[^/]+$');
  static final _decideRe = RegExp(r'^/api/approvals/([^/]+)/decide$');
  static final _orderPathRe = RegExp(r'^/api/pos/orders/([^/]+)');
  String? _addLineOrderId(String path, String method) {
    if (method != 'POST') return null;
    final m = _ordersAddLineRe.firstMatch(path);
    return m?.group(1);
  }
  String? _orderIdFrom(String path) => _orderPathRe.firstMatch(path)?.group(1);
}