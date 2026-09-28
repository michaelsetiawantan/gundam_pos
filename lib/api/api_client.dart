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

/// Low-level REST transport with an injected [http.Client] (mockable in tests).
/// Wraps every response into decoded JSON and maps server error bodies into a
/// typed [PosApiException]. Can throw [PosNetworkException] on transport error.
class ApiClient {
  ApiClient({required this.baseUrl, http.Client? httpClient, AuthProvider? authProvider})
      : _client = httpClient ?? http.Client(),
        _authProvider = authProvider;

  /// Mutable so the runtime operator-entered address can be applied without
  /// rebuilding the app. Every request reads it at call time.
  String baseUrl;
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