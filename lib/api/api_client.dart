import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// Build-time base URL for the Gundam backend. Android emulator reaches the
/// host via 10.0.2.2; a real tablet uses the outlet LAN IP / reverse proxy.
/// Override at build time with `--dart-define=POS_API_BASE=...`.
const _envBase = String.fromEnvironment('POS_API_BASE', defaultValue: '');
const defaultBaseUrl = 'http://10.0.2.2:3000';

/// Server address precedence: operator-entered runtime value > build-time
/// `--dart-define=POS_API_BASE` > [defaultBaseUrl]. [runtime] is the persisted
/// address the operator typed on the activation/login screen.
String resolveBaseUrl({String? runtime}) {
  final r = runtime?.trim() ?? '';
  if (r.isNotEmpty) return r;
  return _envBase.isEmpty ? defaultBaseUrl : _envBase;
}

final _hostLabel = RegExp(r'^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$');
final _ipv6Host = RegExp(r'^\[[0-9a-fA-F:]+\]$');

/// Normalise an operator-entered server address into an absolute base URL, or
/// null when it is empty/garbage. Accepts `host`, `host:port`, and full
/// `http(s)://...` URLs. Never silently accepts a malformed value.
String? normalizeServerAddress(String input) {
  var s = input.trim();
  if (s.isEmpty) return null;
  if (!s.contains('://')) s = 'http://$s';
  final uri = Uri.tryParse(s);
  if (uri == null) return null;
  final scheme = uri.scheme;
  if (scheme != 'http' && scheme != 'https') return null;
  if (uri.hasQuery || uri.hasFragment) return null;
  final host = uri.host;
  if (host.isEmpty || host.contains(' ')) return null;
  if (!host.contains(':') && !_ipv6Host.hasMatch(host)) {
    if (!host.split('.').every(_hostLabel.hasMatch)) return null;
  }
  final authority = uri.hasPort ? '$host:${uri.port}' : host;
  final path = (uri.path == '/' || uri.path.isEmpty) ? '' : uri.path;
  return '$scheme://$authority$path';
}

/// True when [url] is plain `http` on a non-local host. Browsers/clients reject
/// `Secure` session cookies on insecure origins, so a login failure is expected
/// there until the server side allows it (env switch). Informational only.
bool isInsecureServerUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || uri.scheme != 'http') return false;
  final h = uri.host;
  return h != 'localhost' && h != '127.0.0.1' && h != '::1' && h != '10.0.2.2';
}

/// Outcome of probing an operator-entered server address.
enum ServerProbeState { healthy, wrongService, unreachable, tlsFailure, invalid }

class ServerProbeResult {
  const ServerProbeResult(this.state, {this.detail});

  final ServerProbeState state;
  final String? detail;

  bool get ok => state == ServerProbeState.healthy;

  /// Operator-facing copy — honest about which class of failure happened.
  String get message => switch (state) {
        ServerProbeState.healthy => 'Server reachable — correct Gundam service.',
        ServerProbeState.wrongService => 'Reachable, but this is not the Gundam POS service.',
        ServerProbeState.unreachable => 'No response — unreachable, timeout or DNS failure.',
        ServerProbeState.tlsFailure => 'TLS/certificate failure — the certificate was rejected.',
        ServerProbeState.invalid => 'Invalid address — enter a host, host:port or http(s):// URL.',
      };

  @override
  String toString() => 'ServerProbeResult($state${detail != null ? ', $detail' : ''})';
}

/// Probes a server address by HTTP and classifies it as a healthy Gundam
/// service, a wrong service, unreachable, or a TLS/certificate failure.
///
/// It first tries the unauthenticated `GET /api/health`; when that endpoint is
/// absent it falls back to a known POS route (`GET /api/pos/config/state`) and
/// says so in [ServerProbeResult.detail].
class ServerProbe {
  ServerProbe({http.Client? httpClient, this.timeout = const Duration(seconds: 5)})
      : _client = httpClient ?? http.Client();

  final http.Client _client;
  final Duration timeout;

  static const healthPath = '/api/health';
  static const fallbackPath = '/api/pos/config/state';

  Future<ServerProbeResult> probe(String baseUrl) async {
    final base = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
    final health = await _attempt('$base$healthPath');
    if (health.ok) {
      return const ServerProbeResult(ServerProbeState.healthy, detail: 'GET $healthPath → 200 JSON');
    }
    final pos = await _attempt('$base$fallbackPath');
    if (pos.json) {
      return ServerProbeResult(
        ServerProbeState.healthy,
        detail: 'Verified via GET $fallbackPath → ${pos.status} JSON (no $healthPath endpoint yet)',
      );
    }
    // A transport failure is more informative than a wrong-service hint.
    final failure = [health, pos].firstWhere((a) => !a.isResponse, orElse: () => health);
    if (!failure.isResponse) {
      return ServerProbeResult(
        failure.failure!,
        detail: failure.failure == ServerProbeState.tlsFailure ? 'TLS/certificate rejected' : 'timeout / connection refused / DNS',
      );
    }
    return ServerProbeResult(
      ServerProbeState.wrongService,
      detail: 'HTTP ${health.isResponse ? health.status : pos.status} without a JSON API body',
    );
  }

  Future<_ProbeAttempt> _attempt(String url) async {
    try {
      final res = await _client
          .get(Uri.parse(url), headers: const {'accept': 'application/json'})
          .timeout(timeout);
      final ct = (res.headers['content-type'] ?? '').toLowerCase();
      return _ProbeAttempt.http(res.statusCode, ct.contains('json') || _parsesJson(res.body));
    } on TimeoutException {
      return const _ProbeAttempt.error(ServerProbeState.unreachable);
    } catch (e) {
      return _ProbeAttempt.error(_transportState(e));
    }
  }

  static bool _parsesJson(String body) {
    if (body.isEmpty) return false;
    try {
      final d = jsonDecode(body);
      return d is Map || d is List;
    } catch (_) {
      return false;
    }
  }

  static ServerProbeState _transportState(Object e) {
    final s = e.toString();
    if (e is HandshakeException ||
        e is TlsException ||
        s.contains('HandshakeException') ||
        s.contains('TlsException') ||
        s.toLowerCase().contains('certificate')) {
      return ServerProbeState.tlsFailure;
    }
    return ServerProbeState.unreachable;
  }
}

class _ProbeAttempt {
  const _ProbeAttempt.http(this.status, this.json) : isResponse = true, failure = null;
  const _ProbeAttempt.error(this.failure) : isResponse = false, json = false, status = 0;

  final bool isResponse;
  final int status;
  final bool json;
  final ServerProbeState? failure;

  bool get ok => isResponse && status == 200 && json;
}

/// Thrown when the server returns a well-formed JSON `{ error: code }`.
class PosApiException implements Exception {
  PosApiException(this.status, this.code, {this.message, this.retryAfterSeconds});

  final int status;
  final String code;
  final String? message;
  final int? retryAfterSeconds;

  bool get isSessionActiveOtherDevice => status == 409 && code == 'session_active_other_device';
  bool get isDeviceNotActivated =>
      status == 409 && code == 'device_not_activated' || status == 403 && code == 'device_not_activated';
  bool get isLicenseLocked => status == 403 && code == 'license_locked';
  bool get isInvalidCredential => status == 401 && code == 'invalid_credential';
  bool get isRateLimited => status == 429;

  @override
  String toString() => 'PosApiException($status, $code${message != null ? ', $message' : ''})';
}

/// Network-level failure (offline / timeout / DNS). Distinct from API errors so
/// the UI can show a clear "no network" state.
class PosNetworkException implements Exception {
  PosNetworkException([this.cause]);
  final Object? cause;

  @override
  String toString() => 'PosNetworkException(${cause ?? "no network"})';
}

/// Auth injection for guarded routes. The server's session guard reads the
/// `gundam_auth` cookie; the client supplies whatever credential material the
/// deployment issues (the opaque device token / JWT session cookie).
class AuthHeaders {
  const AuthHeaders({this.cookie, this.extra = const {}});

  final String? cookie;
  final Map<String, String> extra;

  Map<String, String> toHeaders() => {
        if (cookie != null) 'cookie': 'gundam_auth=$cookie',
        ...extra,
      };
}

typedef AuthProvider = AuthHeaders? Function();

/// One failed request, in the shape the diagnostic log wants. Deliberately
/// carries NO request body and no credentials — only method/path/status/code.
class ApiErrorEvent {
  const ApiErrorEvent({
    required this.method,
    required this.path,
    required this.network,
    this.status,
    this.code,
    this.detail,
  });

  final String method;
  final String path;
  final bool network; // transport failure (offline/timeout/DNS), not an HTTP error
  final int? status;
  final String? code; // server `error` code, else 'unknown_error'/'malformed_response'
  final String? detail;

  /// `POST /api/pos/orders/x/settle → 500 unknown_error`
  String get label => '$method $path → ${network ? 'network' : status}'
      '${code != null ? ' $code' : ''}';
}

/// Low-level REST transport with an injected [http.Client] (mockable in tests).
/// Wraps every response into decoded JSON and maps server error bodies into a
/// typed [PosApiException]. Can throw [PosNetworkException] on transport error.
class ApiClient {
  ApiClient({required this.baseUrl, http.Client? httpClient, AuthProvider? authProvider, this.onError})
      : _client = httpClient ?? http.Client(),
        _authProvider = authProvider;

  /// Mutable so the runtime operator-entered address can be applied without
  /// rebuilding the app. Every request reads it at call time.
  String baseUrl;
  final http.Client _client;
  final AuthProvider? _authProvider;

  /// Called for EVERY failed request (HTTP error or transport failure) so the
  /// app can record it. Wired by AppSession to the diagnostic log; null in tests.
  void Function(ApiErrorEvent e)? onError;

  static const _jsonHeaders = {'content-type': 'application/json', 'accept': 'application/json'};

  Map<String, String> _headers({Map<String, String>? extra, bool auth = true}) {
    final headers = <String, String>{..._jsonHeaders, ...?extra};
    if (auth) {
      final a = _authProvider?.call();
      if (a != null) headers.addAll(a.toHeaders());
    }
    return headers;
  }

  Uri _uri(String path, [Map<String, String>? query]) {
    final full = path.startsWith('http') ? path : '$baseUrl$path';
    final u = Uri.parse(full);
    if (query == null || query.isEmpty) return u;
    return u.replace(queryParameters: {...u.queryParameters, ...query});
  }

  Future<Map<String, dynamic>> get(String path, {Map<String, String>? query, bool auth = true}) =>
      _send('GET', path, query: query, auth: auth);

  Future<Map<String, dynamic>> post(String path, {Object? body, Map<String, String>? query, bool auth = true}) =>
      _send('POST', path, body: body, query: query, auth: auth);

  Future<Map<String, dynamic>> delete(String path, {Object? body, bool auth = true}) =>
      _send('DELETE', path, body: body, auth: auth);

  Future<Map<String, dynamic>> _send(String method, String path, {Object? body, Map<String, String>? query, bool auth = true}) async {
    http.Response res;
    final uri = _uri(path, query);
    try {
      switch (method) {
        case 'GET':
          res = await _client.get(uri, headers: _headers(auth: auth));
          break;
        case 'POST':
          res = await _client.post(
            uri,
            headers: _headers(auth: auth),
            body: body == null ? null : jsonEncode(body),
          );
          break;
        case 'DELETE':
          res = await _client.delete(uri, headers: _headers(auth: auth), body: body == null ? null : jsonEncode(body));
          break;
        default:
          throw StateError('unsupported method $method');
      }
    } on PosApiException {
      rethrow;
    } catch (e) {
      _reportError(ApiErrorEvent(method: method, path: path, network: true, detail: '$e'));
      throw PosNetworkException(e);
    }

    final decoded = _tryDecode(res.body);
    if (res.statusCode >= 200 && res.statusCode < 300) {
      return decoded;
    }
    final err = _mapError(res.statusCode, decoded);
    _reportError(ApiErrorEvent(
      method: method,
      path: path,
      network: false,
      status: res.statusCode,
      code: err.code,
      detail: err.message,
    ));
    throw err;
  }

  /// Never let the observer break a request.
  void _reportError(ApiErrorEvent e) {
    try {
      onError?.call(e);
    } catch (_) {
      // logging must never throw
    }
  }

  Map<String, dynamic> _tryDecode(String body) {
    if (body.isEmpty) return const {};
    try {
      final d = jsonDecode(body);
      return d is Map<String, dynamic> ? d : {'error': body};
    } catch (_) {
      return {'error': 'malformed_response'};
    }
  }

  PosApiException _mapError(int status, Map<String, dynamic> body) {
    final code = (body['error'] ?? 'unknown_error').toString();
    // Server may serialise retryAfter as a number OR a numeric string
    // ("30") — a hard `as num?` cast would throw inside error handling.
    final raw = body['retryAfter'] ?? body['retryAfterSeconds'];
    final retryAfter = raw is num ? raw : num.tryParse('$raw');
    return PosApiException(
      status,
      code,
      message: body['message'] as String?,
      retryAfterSeconds: retryAfter?.toInt(),
    );
  }

  /// Perform a health probe against the given host/port (printer-network check)
  /// returning whether the TCP endpoint is reachable. Non-HTTP transport.
  Future<bool> tcpReachable(String host, int port, {Duration timeout = const Duration(seconds: 3)}) async {
    try {
      final socket = await Socket.connect(host, port, timeout: timeout);
      await socket.close();
      return true;
    } catch (_) {
      return false;
    }
  }
}
/// Human text for a POS API error code.
///
/// Why this exists: the screens used to print the raw code (`$prefix (unknown_error)`),
/// which told the operator nothing — a failure with no server-side `error` field
/// looked like a mystery. Every code the POS can hit must say what to DO.
/// [status] (the HTTP status) sharpens the message: a server-side 5xx is a
/// different beast from a 4xx the operator can act on, and it must never read as
/// a bare "unknown error".
///
/// Three layers, in order: an EXACT message for codes the operator drives
/// (approvals, void/cancel, discount/voucher, shift, payment, tables, device),
/// then FAMILY rules (every `*_not_found` / `*_required` / `invalid_*` …), then
/// the raw-code fallback. The code is always kept in the text so support can
/// still grep it.
String posErrorText(String prefix, String code, {int? status}) {
  final unexplained = code == 'unknown_error' || code == 'malformed_response';
  if (unexplained && status != null && status >= 500) {
    return '$prefix — server error (HTTP $status). The tablet recorded it; the server log '
        'has the details. Retry; if it keeps happening, send diagnostics (More → Print diagnostics).';
  }
  // Every message keeps the raw code (support greps it) — the operator gets the
  // explanation, the log keeps the code.
  String say(String what) => prefix.isEmpty ? '$what ($code)' : '$prefix — $what ($code)';
  final tail = '($code${status != null ? ' · HTTP $status' : ''})';
  final withCode = prefix.isEmpty ? tail : '$prefix $tail';

  switch (code) {
    // ---- session / device / entitlement -------------------------------
    case 'shift_required':
      return 'Start a shift first — transactions are blocked until the shift is open. ($code)';
    case 'device_not_registered':
    case 'device_not_activated':
      return say('this tablet is not activated for this outlet any more — re-activate it (More → Activate).');
    case 'device_required':
      return say('the tablet identity is missing — re-activate the device (More → Activate).');
    case 'device_revoked':
    case 'revoked':
      return say('this device was revoked by an admin — ask for a new activation code.');
    case 'device_bound_other_group':
      return say('this device is bound to another group — it must be released before it can be used here.');
    case 'credential_group_mismatch':
      return 'This account belongs to another group than this device. ($code)';
    case 'unauthenticated':
      return say('the session expired — sign in again.');
    case 'permission_denied':
    case 'forbidden':
    case 'web_access_denied':
      return '$prefix — your role is not allowed to do that. ($code)';
    case 'license_locked':
    case 'no_active_license':
      return say('the outlet licence has ended — the owner must renew before selling (Web POS → Billing).');
    case 'pos_quota_exhausted':
      return say('no POS device slots left in this group — ask the owner to add capacity.');

    // ---- approvals (void / cancel / cancel item / discount / tips) -----
    case 'invalid_credential':
    case 'invalid_credentials':
      return '$prefix — wrong username or password for the authoriser. Try again (the request '
          'stays pending until it is authorised or rejected). ($code)';
    case 'approval_denied':
      return '$prefix — that user is not allowed to approve this request. Use an account with '
          'the matching approval right. ($code)';
    case 'already_decided':
      return '$prefix — this request was already decided (approved or rejected) by someone else. '
          'Pull the list again. ($code)';
    case 'invalid_action_type':
      return '$prefix — this request type cannot be decided here. ($code)';
    case 'not_paid':
      return '$prefix — that bill is not PAID, so it cannot be voided. Only a settled (paid) bill '
          'of today can be voided. ($code)';
    case 'void_outside_trading_day':
      return '$prefix — that bill belongs to a different trading day. Only bills from this outlet\'s '
          'current day can be voided here. ($code)';
    case 'no_transaction':
      return '$prefix — this bill has no recorded transaction, so there is nothing to void. ($code)';
    case 'nothing_to_cancel':
      return say('nothing to cancel in this order.');
    case 'reason_required':
      return '$prefix — a reason is required. Type one and try again. ($code)';
    case 'line_not_sent':
      return '$prefix — that item was never sent to the kitchen, so it does not need approval. '
          'Remove it from the cart instead. ($code)';
    case 'line_already_sent':
      return '$prefix — that item already went to the kitchen — cancel it per item, not by editing. ($code)';
    case 'line_not_found':
      return '$prefix — that item is no longer on this order. Refresh and try again. ($code)';
    case 'invalid_qty':
      return '$prefix — that quantity is not valid for this item. ($code)';
    case 'order_closed':
      return 'That order is already closed on the server — reload the Open Tables list. ($code)';
    case 'order_not_found':
    case 'not_found':
      return '$prefix — that order no longer exists on the server. Reload and try again. ($code)';
    case 'order_id_conflict':
      return '$prefix — this order number collided with an existing one. Try creating the order again. ($code)';
    case 'require_send_cart':
      return '$prefix — send the cart to the kitchen first; a bill cannot be settled before that. ($code)';

    // ---- discount / voucher -------------------------------------------
    case 'discount_expired':
    case 'voucher_expired':
      return '$prefix — that discount/voucher has expired. Pick another one. ($code)';
    case 'discount_inactive':
    case 'voucher_inactive':
      return '$prefix — that discount/voucher was turned off by the admin. ($code)';
    case 'discount_not_eligible':
    case 'voucher_not_eligible':
      return '$prefix — this item/order does not qualify for that discount/voucher. ($code)';
    case 'voucher_exhausted':
      return '$prefix — that voucher has been fully used. Pick another one. ($code)';
    case 'discount_not_found':
    case 'voucher_not_found':
      return '$prefix — that discount/voucher no longer exists. Pull the config again. ($code)';

    // ---- payment / settle ---------------------------------------------
    case 'insufficient_payment':
      return '$prefix — the payments do not cover the total yet. Add another payment. ($code)';
    case 'invalid_amount':
      return '$prefix — that amount is not valid. ($code)';
    case 'shipment_negative':
      return '$prefix — the shipment amount cannot be negative. ($code)';
    case 'shipment_not_found':
      return '$prefix — that shipment option no longer exists. Pull the config again. ($code)';
    case 'split_missing_item':
      return '$prefix — a split is missing an item. Re-check the split and try again. ($code)';
    case 'split_qty_mismatch':
      return '$prefix — the split quantities do not add up to the sold quantity. ($code)';
    case 'split_requires_two_or_more':
      return '$prefix — a split needs at least two parts. ($code)';
    case 'merge_requires_two_or_more':
      return '$prefix — merging needs at least two tables. ($code)';
    case 'invalid_client_order_id':
      return '$prefix — the order identifier was rejected. Create the order again. ($code)';
    case 'receipt_id_exists':
    case 'invalid_receipt_id':
      return '$prefix — the receipt number is not acceptable for this outlet. ($code)';

    // ---- shift ---------------------------------------------------------
    case 'counted_total_required':
      return '$prefix — enter the counted amount(s) before closing the shift. ($code)';
    case 'shift_close_failed':
      return '$prefix — the server could not close the shift. Send diagnostics and retry. ($code)';
    case 'shift_open_failed':
      return '$prefix — the server could not open the shift. Send diagnostics and retry. ($code)';
    case 'shift_closed':
      return '$prefix — that shift is already closed. Reload the shift screen. ($code)';
    case 'no_pending_tip':
      return '$prefix — there is no pending tip on this bill. ($code)';

    // ---- tables / layout ----------------------------------------------
    case 'table_locked':
      return '$prefix — that table is locked by another operation. Reload Open Tables. ($code)';
    case 'table_hanging':
      return '$prefix — that table still has a hanging (unpaid) bill. Settle or cancel it first. ($code)';
    case 'table_not_empty':
      return '$prefix — that table is not empty yet. ($code)';
    case 'table_not_found':
      return '$prefix — that table no longer exists. Reload Open Tables. ($code)';
    case 'need_table_or_table_name':
      return '$prefix — pick a table or type a custom table name. ($code)';
    case 'invalid_table_name':
      return '$prefix — that table name is not valid. ($code)';
    case 'already_in_target':
      return '$prefix — it is already on that table. ($code)';
    case 'nothing_to_send':
      return 'Nothing new to send — every line was already sent. ($code)';

    // ---- printing / media ---------------------------------------------
    case 'printer_not_found':
    case 'invalid_printer':
      return '$prefix — the printer for this station is missing. Fix it in Web POS → printers. ($code)';
    case 'batch_too_large':
      return '$prefix — too many items for one kitchen sheet. Send in smaller batches. ($code)';
    case 'media_unavailable':
      return '$prefix — the image/media service is unavailable right now. The image will sync later. ($code)';
    case 'missing_asset':
      return '$prefix — that uploaded image is missing on the server. Upload it again. ($code)';

    // ---- misc values ---------------------------------------------------
    case 'invalid_json':
    case 'not_an_object':
      return '$prefix — the tablet sent a malformed request. Send diagnostics and retry. ($code)';
    case 'rate_limited':
      return '$prefix — too many attempts in a row. Wait a moment and try again. ($code)';
    case 'no_network':
      return '$prefix — no connection to the server. Check the network and retry. ($code)';

    case 'unknown_error':
    case 'malformed_response':
      return '$prefix — the server did not explain the failure'
          '${status != null ? ' (HTTP $status)' : ''}. '
          'Send diagnostics (More → Print diagnostics) so it can be fixed. ($code)';
  }

  // ---- family fallbacks: still actionable, never a bare code -----------
  if (code.endsWith('_required') || code.startsWith('missing_')) {
    return say('a required field is missing ($code). Fill it in and try again.');
  }
  if (code.endsWith('_not_found')) {
    return say('that record no longer exists on the server ($code). Reload the list and try again.');
  }
  if (code.startsWith('invalid_')) {
    return say('a value was rejected as invalid ($code). Check the entry and try again.');
  }
  if (code.startsWith('already_') || code == 'duplicate_code') {
    return say('that was already done ($code). Reload to see the current state.');
  }
  if (code == 'too_large' || code == 'invalid_size' || code == 'empty_file') {
    return say('the file is empty or too large ($code). Use a smaller file.');
  }
  if (code.startsWith('unsupported_')) {
    return say('that format/type is not supported ($code).');
  }
  if (code == 'csrf_failed') {
    return say('the security token expired. Reload and try again.');
  }
  return withCode;
}
