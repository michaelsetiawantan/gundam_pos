/// Typed endpoint client for the Gundam POS backend. Thin mapping over the
/// server truth — this client deliberately has no business rules; the server
/// enforces them (single-active, hanging tables, split, rounding, receipt id).
library;

import 'package:gundam_pos/api/api_client.dart';

class PosApi {
  PosApi(this._client);

  final ApiClient _client;

  /// The base URL every call resolves against (read at request time).
  String get baseUrl => _client.baseUrl;

  /// Switch the whole API surface to a new runtime server address.
  set baseUrl(String value) => _client.baseUrl = value;

  /// Forward every failed request (HTTP error or transport failure) to a
  /// listener. AppSession wires this to the diagnostic log so client-side
  /// failures are recorded and can be shipped to the server.
  set onApiError(void Function(ApiErrorEvent e)? handler) => _client.onError = handler;

  // ------------------------------------------------------------------ auth --
  // Activation (public — no session).
  Future<Map<String, dynamic>> redeem({
    required String code,
    required String deviceId,
    String? assetLabel,
  }) =>
      _client.post('/api/auth/pos-redeem',
          body: {'code': code, 'deviceId': deviceId, if (assetLabel != null) 'assetLabel': assetLabel}, auth: false);

  /// POS login (public). Throws [PosApiException] with distinct states:
  /// invalid_credential / device_not_activated / license_locked /
  /// session_active_other_device. Returns session + outlet context.
  Future<Map<String, dynamic>> login({
    required String email,
    required String password,
    required String deviceToken,
    required String deviceId,
  }) =>
      _client.post('/api/auth/pos-login',
          body: {'email': email, 'password': password, 'deviceToken': deviceToken, 'deviceId': deviceId}, auth: false);

  /// Sign out the active POS session (requires online; single-active release).
  Future<Map<String, dynamic>> logout({String? body}) =>
      _client.post('/api/auth/logout', body: body == null ? null : {});

  // ----------------------------------------------------------------- shifts -
  Future<Map<String, dynamic>> openShift({
    required String tenantId,
    String? deviceAssetId,
    double? openHousebank,
  }) =>
      _client.post('/api/pos/shifts',
          body: {
            'tenantId': tenantId,
            if (deviceAssetId != null) 'deviceAssetId': deviceAssetId,
            if (openHousebank != null) 'openHousebank': openHousebank,
          });

  /// The caller's currently OPEN shift for this outlet (or `{shift: null}`).
  /// Lets the tablet recover a running shift after the app is closed/reopened;
  /// the server returns only OPEN shifts (CLOSED/AUTO_CLOSED are never active).
  Future<Map<String, dynamic>> activeShift({required String tenantId}) =>
      _client.get('/api/pos/shifts/active', query: {'tenantId': tenantId});

  /// Close a shift. [body] is the mode-specific counted payload built by
  /// ShiftController.buildClosePayload (ONLY_CASH / CASH_CASHLESS /
  /// CROSSCHECK_PER_METHOD).
  Future<Map<String, dynamic>> closeShift({
    required String shiftId,
    required Map<String, dynamic> body,
    String? deviceAssetId,
  }) =>
      _client.post('/api/pos/shifts/$shiftId/close',
          body: {...body, if (deviceAssetId != null) 'deviceAssetId': deviceAssetId});

  // ----------------------------------------------------------------- orders -
  Future<Map<String, dynamic>> listOpenOrders(String tenantId) =>
      _client.get('/api/pos/orders', query: {'tenantId': tenantId});

  /// Today's transactions WITH full status (PAID / CANCELED / VOIDED /
  /// REFUNDED) — the Today's transactions feed. Distinct from [listOpenOrders]
  /// (Open Tables, OPEN only); a cancelled order shows up here as CANCELED.
  Future<Map<String, dynamic>> listTodayOrders(String tenantId) =>
      _client.get('/api/pos/orders/today', query: {'tenantId': tenantId});

  /// Open an order. When [clientOrderId] is supplied (offline-created order) the
  /// SERVER accepts it verbatim and is idempotent — a retry returns the SAME
  /// order instead of a duplicate. Omitted → the server mints a cuid.
  Future<Map<String, dynamic>> createOrder({
    required String tenantId,
    String? tableId,
    String? tableName,
    Map<String, dynamic>? guest,
    String? clientOrderId,
  }) =>
      _client.post('/api/pos/orders',
          body: {
            'tenantId': tenantId,
            if (tableId != null) 'tableId': tableId,
            if (tableName != null) 'tableName': tableName,
            if (guest != null) 'guest': guest,
            if (clientOrderId != null) 'clientOrderId': clientOrderId,
          });

  Future<Map<String, dynamic>> addLine(String orderId, {required Map<String, dynamic> body}) =>
      _client.post('/api/pos/orders/$orderId/lines', body: body);

  Future<Map<String, dynamic>> removeLine(String orderId, String lineId) =>
      _client.delete('/api/pos/orders/$orderId/lines/$lineId');

  Future<Map<String, dynamic>> sendCart(String orderId) =>
      _client.post('/api/pos/orders/$orderId/send-cart', body: {});

  /// Set or clear the bill's discount OR voucher (one-per-bill). The tablet only
  /// PROPOSES ids; the SERVER re-validates active/expiry/quota/category-eligibility
  /// and decides. Returns `{order:{discountId,voucherId}}` when applied directly,
  /// or `{approval:{approvalId,status}}` when the caller is below the approval
  /// threshold (queued PENDING, nothing applied yet). `{discountId:null,
  /// voucherId:null}` clears the choice. Never carries an amount.
  Future<Map<String, dynamic>> setPricing(
    String orderId, {
    String? discountId,
    String? voucherId,
    String? reason,
  }) =>
      _client.post('/api/pos/orders/$orderId/pricing', body: {
        'discountId': discountId,
        'voucherId': voucherId,
        if (reason != null) 'reason': reason,
      });

  Future<Map<String, dynamic>> settle(
    String orderId, {
    required List<Map<String, dynamic>> payments,
    required String receiptId,
    String? transactedAt,
    String? deviceAssetId,
    Map<String, dynamic>? shipment,
  }) =>
      _client.post('/api/pos/orders/$orderId/settle',
          body: {
            'payments': payments,
            'receiptId': receiptId,
            if (transactedAt != null) 'transactedAt': transactedAt,
            if (deviceAssetId != null) 'deviceAssetId': deviceAssetId,
            if (shipment != null) 'shipment': shipment,
          });

  /// Offline-first deferred settlement: the tablet already completed the sale
  /// LOCALLY (money flow + receipt id are device-side) and replays the full
  /// snapshot here. Idempotent on `clientSettlementKey` — a retry never doubles
  /// the sale. 201 = newly applied, 200 `{already:true}` = already applied,
  /// 4xx `{error:code}` = refused (tablet marks FAILED and tells the cashier).
  Future<Map<String, dynamic>> settleDeferred(String orderId, {required Map<String, dynamic> body}) =>
      _client.post('/api/pos/orders/$orderId/settle-deferred', body: body);

  Future<Map<String, dynamic>> requestVoid(String orderId, {required String reason}) =>
      _client.post('/api/pos/orders/$orderId/void', body: {'reason': reason});

  Future<Map<String, dynamic>> requestCancel(String orderId, {String? reason, String? lineId, int? qty}) =>
      _client.post('/api/pos/orders/$orderId/cancel', body: {
        if (reason != null) 'reason': reason,
        if (lineId != null) 'lineId': lineId,
        if (qty != null) 'qty': qty,
      });

  // ------------------------------------------------------------- approvals --
  /// Group-scoped approval queue (`GET /api/approvals`). The server decides
  /// visibility: a role without an approval capability gets a 403. Powers the
  /// POS Approvals screen — PENDING cancel/void/refund/discount requests only
  /// (tip approval is web-only and never requested from the tablet).
  Future<Map<String, dynamic>> listApprovals({
    String? tenantId,
    String? status,
    String? actionType,
    int? page,
    int? perPage,
  }) =>
      _client.get('/api/approvals', query: {
        if (tenantId != null) 'tenantId': tenantId,
        if (status != null) 'status': status,
        if (actionType != null) 'actionType': actionType,
        if (page != null) 'page': '$page',
        if (perPage != null) 'perPage': '$perPage',
      });

  /// Approve or reject ONE pending approval
  /// (`POST /api/approvals/[id]/decide`, body `{state}`). 403 `approval_denied`
  /// when the caller's role may not decide; 409 `already_decided` when another
  /// approver got there first.
  ///
  /// When the current session lacks the decide right, a second authorised user
  /// may authorise by presenting their own [approverEmail] + [approverPassword]
  /// (both required together). A wrong credential OR an under-privileged user
  /// both answer 401 `invalid_credentials`. The password is sent once and never
  /// stored.
  Future<Map<String, dynamic>> decideApproval(
    String id, {
    required String state,
    String? approverEmail,
    String? approverPassword,
  }) =>
      _client.post('/api/approvals/$id/decide', body: {
        'state': state,
        if (approverEmail != null) 'approverEmail': approverEmail,
        if (approverPassword != null) 'approverPassword': approverPassword,
      });

  // -------------------------------------------------------------- version --
  /// Public release manifest (`GET /api/pos/version.json`, no auth). Used by the
  /// tablet's update check; an honest empty body means "no release published",
  /// never an update.
  Future<Map<String, dynamic>> versionInfo() =>
      _client.get('/api/pos/version.json', auth: false);

  // ---------------------------------------------------------------- config --
  Future<Map<String, dynamic>> configState(String tenantId) =>
      _client.get('/api/pos/config/state', query: {'tenantId': tenantId});

  Future<Map<String, dynamic>> configSync(String tenantId, Map<String, int> deviceVersions) =>
      _client.post('/api/pos/config/sync', body: {'tenantId': tenantId, 'deviceVersions': deviceVersions});

  // ------------------------------------------------------------------ media --
  Future<Map<String, dynamic>> mediaManifest(String tenantId) =>
      _client.get('/api/pos/media/manifest', query: {'tenantId': tenantId});

  Future<Map<String, dynamic>> mediaResolve(String tenantId, String key, {String? variant}) =>
      _client.post('/api/pos/media/resolve', body: {
        'tenantId': tenantId,
        'key': key,
        if (variant != null) 'variant': variant,
      });

  // -------------------------------------------------------------- tables ops -
  Future<Map<String, dynamic>> tableOps(String tenantId, Map<String, dynamic> body) =>
      _client.post('/api/pos/tables/ops', body: {'tenantId': tenantId, ...body});

  // ------------------------------------------------------------------ print --
  Future<Map<String, dynamic>> printEnqueue(String outletId, List<Map<String, dynamic>> jobs) =>
      _client.post('/api/pos/print', body: {'outletId': outletId, 'jobs': jobs});

  /// Upload a batch of device-observed print attempts as development material
  /// (`POST /api/pos/print-logs`). Idempotent on each log's `clientLogId`; the
  /// response is a summary of accepted / alreadySeen / rejected.
  Future<Map<String, dynamic>> postPrintLogs({
    required String tenantId,
    required String assetId,
    required List<Map<String, dynamic>> logs,
  }) =>
      _client.post('/api/pos/print-logs', body: {'tenantId': tenantId, 'assetId': assetId, 'logs': logs});

  /// Upload ONE operator-triggered diagnostic bundle (device context + local
  /// print summary + recent app log lines) as development material
  /// (`POST /api/pos/diagnostics`). Idempotent on the bundle's `clientReportId`.
  Future<Map<String, dynamic>> postDiagnostics({
    required String tenantId,
    required String assetId,
    required Map<String, dynamic> report,
  }) =>
      _client.post('/api/pos/diagnostics', body: {'tenantId': tenantId, 'assetId': assetId, 'report': report});
}