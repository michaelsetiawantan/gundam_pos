import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gundam_pos/api/api_client.dart';
import 'package:gundam_pos/api/pos_api.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('ApiClient request mapping', () {
    test('GET sends the gundam_auth cookie when auth provider is set', () async {
      late http.Request captured;
      final mock = MockClient((req) async {
        captured = req;
        return http.Response('{"ok":true}', 200);
      });
      final client = ApiClient(
        baseUrl: 'http://api.test',
        httpClient: mock,
        authProvider: () => const AuthHeaders(cookie: 'abc.def.ghi'),
      );
      final r = await client.get('/api/pos/orders', query: {'tenantId': 't1'});
      expect(r['ok'], isTrue);
      expect(captured.url.path, '/api/pos/orders');
      expect(captured.url.queryParameters['tenantId'], 't1');
      expect(captured.headers['cookie'], 'gundam_auth=abc.def.ghi');
    });

    test('POST encodes JSON body and decodes response', () async {
      Map<String, dynamic>? sent;
      late http.Request captured;
      final mock = MockClient((req) async {
        captured = req;
        sent = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response('{"order":{"id":"o1"}}', 201);
      });
      final client = ApiClient(baseUrl: 'http://api.test', httpClient: mock);
      final r = await client.post('/api/pos/orders', body: {'tenantId': 't1', 'tableName': 'A1'});
      expect(r['order']!['id'], 'o1');
      expect(sent!['tableName'], 'A1');
      expect(captured.headers['content-type'], contains('application/json'));
    });

    test('429 rate_limited surfaces retryAfterSeconds', () async {
      final mock = MockClient((_) async => http.Response('{"error":"rate_limited","retryAfter":30}', 429));
      final client = ApiClient(baseUrl: 'http://api.test', httpClient: mock);
      expect(
        () => client.post('/api/auth/pos-login', body: {}, auth: false),
        throwsA(isA<PosApiException>()
            .having((e) => e.isRateLimited, 'isRateLimited', isTrue)
            .having((e) => e.retryAfterSeconds, 'retryAfterSeconds', 30)),
      );
    });

    test('429 rate_limited tolerates a STRING retryAfter (no throw)', () async {
      final mock = MockClient((_) async => http.Response('{"error":"rate_limited","retryAfter":"30"}', 429));
      final client = ApiClient(baseUrl: 'http://api.test', httpClient: mock);
      final err = await _catch(client.post('/api/auth/pos-login', body: {}, auth: false));
      expect(err, isA<PosApiException>());
      expect((err as PosApiException).isRateLimited, isTrue);
      expect(err.retryAfterSeconds, 30);
    });

    test('single-active other device maps to a distinct error', () async {
      final mock = MockClient((_) async => http.Response(
            '{"error":"session_active_other_device","message":"Session active on another device"}',
            409,
          ));
      final client = ApiClient(baseUrl: 'http://api.test', httpClient: mock);
      final api = PosApi(client);
      final err = await _catch(api.login(deviceId: 'd1', deviceToken: 't', email: 'e', password: 'p'));
      expect(err, isA<PosApiException>());
      expect((err as PosApiException).isSessionActiveOtherDevice, isTrue);
      expect(err.status, 409);
    });

    test('401 invalid_credential', () async {
      final mock = MockClient((_) async => http.Response('{"error":"invalid_credential"}', 401));
      final client = ApiClient(baseUrl: 'http://api.test', httpClient: mock);
      final err = await _catch(client.post('/api/auth/pos-login', body: {}, auth: false));
      expect((err as PosApiException).isInvalidCredential, isTrue);
    });

    test('network failure becomes PosNetworkException', () async {
      final mock = MockClient((_) async => throw http.ClientException('connection refused'));
      final client = ApiClient(baseUrl: 'http://api.test', httpClient: mock);
      final err = await _catch(client.get('/x'));
      expect(err, isA<PosNetworkException>());
    });

    test('non-2xx without known code yields the raw error code', () async {
      final mock = MockClient((_) async => http.Response('{"error":"table_hanging"}', 409));
      final client = ApiClient(baseUrl: 'http://api.test', httpClient: mock);
      final err = await _catch(client.post('/api/pos/orders', body: {}));
      expect((err as PosApiException).code, 'table_hanging');
    });
  });
}

Future<Object?> _catch(Future<Map<String, dynamic>> f) async {
  try {
    await f;
    return null;
  } catch (e) {
    return e;
  }
}