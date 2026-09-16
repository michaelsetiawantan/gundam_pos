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

  final _serverVersions = <String, int>{};

  void setVersions(Map<String, int> v) => _serverVersions
    ..clear()
    ..addAll(v);

  http.Response _json(int status, Object body) =>
      http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

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
              'license': {'state': 'ACTIVE', 'grace': false},
            });
      case '/api/auth/logout':
        return _json(200, {'ok': true});
      case '/api/pos/config/state':
        return _json(200, {
          'tenantId': 't1',
          'versions': {
            for (final e in _serverVersions.entries) e.key: {'version': e.value, 'updatedAt': DateTime.now().toIso8601String()},
          },
          'ttl': {'nonCredentialDays': 3},
        });
      case '/api/pos/config/sync':
        return _json(200, {
          'tenantId': 't1',
          'needsFull': <String>[],
          'upToDate': ['MASTER', 'OUTLET', 'FORMAT', 'MEDIA'],
          'full': {},
        });
      default:
        return _json(404, {'error': 'not_found'});
    }
  }
}