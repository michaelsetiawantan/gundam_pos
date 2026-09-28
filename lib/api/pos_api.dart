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
          body: {'tenantId': tenantId, if (deviceAssetId != null) 'deviceAssetId': deviceAssetId});

  Future<Map<String, dynamic>> closeShift({
    required String shiftId,
    required double countedTotal,
    String? deviceAssetId,
  }) =>
      _client.post('/api/pos/shifts/$shiftId/close',
          body: {'countedTotal': countedTotal, if (deviceAssetId != null) 'deviceAssetId': deviceAssetId});

  // ----------------------------------------------------------------- orders -
  Future<Map<String, dynamic>> listOpenOrders(String tenantId) =>
      _client.get('/api/pos/orders', query: {'tenantId': tenantId});

  Future<Map<String, dynamic>> createOrder({
    required String tenantId,
    String? tableId,
    String? tableName,
    Map<String, dynamic>? guest,
  }) =>
      _client.post('/api/pos/orders',
          body: {
            'tenantId': tenantId,
            if (tableId != null) 'tableId': tableId,
            if (tableName != null) 'tableName': tableName,
            if (guest != null) 'guest': guest,
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

  Future<Map<String, dynamic>> requestVoid(String orderId, {required String reason}) =>
      _client.post('/api/pos/orders/$orderId/void', body: {'reason': reason});

  Future<Map<String, dynamic>> requestCancel(String orderId, {String? reason, String? lineId, int? qty}) =>
      _client.post('/api/pos/orders/$orderId/cancel', body: {
        if (reason != null) 'reason': reason,
        if (lineId != null) 'lineId': lineId,
        if (qty != null) 'qty': qty,
      });

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
}