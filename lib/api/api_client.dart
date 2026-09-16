import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// Build-time base URL for the Gundam backend. Android emulator reaches the
/// host via 10.0.2.2; a real tablet uses the outlet LAN IP / reverse proxy.
/// Override at build time with `--dart-define=POS_API_BASE=...`.
const _envBase = String.fromEnvironment('POS_API_BASE', defaultValue: '');
const defaultBaseUrl = 'http://10.0.2.2:3000';

String resolveBaseUrl() => _envBase.isEmpty ? defaultBaseUrl : _envBase;

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

/// Low-level REST transport with an injected [http.Client] (mockable in tests).
/// Wraps every response into decoded JSON and maps server error bodies into a
/// typed [PosApiException]. Can throw [PosNetworkException] on transport error.
class ApiClient {
  ApiClient({required this.baseUrl, http.Client? httpClient, AuthProvider? authProvider})
      : _client = httpClient ?? http.Client(),
        _authProvider = authProvider;

  final String baseUrl;
  final http.Client _client;
  final AuthProvider? _authProvider;

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
      throw PosNetworkException(e);
    }

    final decoded = _tryDecode(res.body);
    if (res.statusCode >= 200 && res.statusCode < 300) {
      return decoded;
    }
    throw _mapError(res.statusCode, decoded);
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
    final retryAfter = (body['retryAfter'] ?? body['retryAfterSeconds']) as num?;
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