import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:gundam_pos/api/api_client.dart';
import 'package:gundam_pos/api/pos_api.dart';
import 'package:gundam_pos/state/app_session.dart';
import 'package:gundam_pos/state/session_store.dart';

/// Client-side error observability: a server 5xx must not read as a bare
/// "unknown error", EVERY failed request must be recorded, and a server error
/// must be shippable to the server (durable outbox) even if the operator never
/// opens Print diagnostics.

void main() {
  group('posErrorText names the HTTP class', () {
    test('a 5xx with no server code is a SERVER error, not a mystery', () {
      final t = posErrorText('Could not settle', 'unknown_error', status: 500);
      expect(t, contains('server error'));
      expect(t, contains('500'));
      expect(t, isNot(contains('unknown_error')));
    });

    test('an unmapped 4xx keeps the code and shows the status', () {
      final t = posErrorText('Could not add item', 'weird_code', status: 418);
      expect(t, contains('weird_code'));
      expect(t, contains('418'));
    });

    test('known codes keep their actionable wording', () {
      expect(posErrorText('x', 'shift_required', status: 409), contains('Start a shift'));
      expect(posErrorText('x', 'order_closed', status: 409), contains('already closed'));
    });
  });

  group('ApiClient reports every failed request', () {
    test('HTTP error → one event with method/path/status/code', () async {
      final events = <ApiErrorEvent>[];
      final client = ApiClient(
        baseUrl: 'http://fake.test',
        httpClient: MockClient((_) async => http.Response('{}', 500)),
      )..onError = events.add;

      await expectLater(
        client.post('/api/pos/orders/o1/settle', body: {'a': 1}),
        throwsA(isA<PosApiException>()),
      );
      expect(events, hasLength(1));
      expect(events.single.method, 'POST');
      expect(events.single.path, '/api/pos/orders/o1/settle');
      expect(events.single.status, 500);
      expect(events.single.code, 'unknown_error');
      expect(events.single.network, isFalse);
      expect(events.single.label, contains('500'));
    });

    test('transport failure → a network event, never an HTTP one', () async {
      final events = <ApiErrorEvent>[];
      final client = ApiClient(
        baseUrl: 'http://fake.test',
        httpClient: MockClient((_) async => throw http.ClientException('offline')),
      )..onError = events.add;

      await expectLater(client.get('/api/pos/orders'), throwsA(isA<PosNetworkException>()));
      expect(events, hasLength(1));
      expect(events.single.network, isTrue);
      expect(events.single.status, isNull);
    });
  });

  group('AppSession records + ships server errors', () {
    Future<(AppSession, List<Uri>)> sessionWith(Future<http.Response> Function(http.Request) reply) async {
      final hits = <Uri>[];
      final client = ApiClient(
        baseUrl: 'http://fake.test',
        authProvider: () => null,
        httpClient: MockClient((req) async {
          hits.add(req.url);
          return reply(req);
        }),
      );
      final session = AppSession(posApi: PosApi(client), sessionStore: InMemorySessionStore());
      session.ctx = const PosContext()
          .withRedeem({'deviceToken': 'dev', 'groupId': 'g1', 'tenantId': 't1', 'shortcode': 'NSTAR-POS1'})
          .copyWith(deviceId: 'device-1');
      return (session, hits);
    }

    test('a 5xx is logged AND queued for the server (durable outbox)', () async {
      final (session, _) = await sessionWith((_) async => http.Response('{}', 500));

      await session.posApi.configState('t1').catchError((Object _) => <String, dynamic>{});
      await pumpEventQueue();

      final lines = session.diagnostics.snapshot();
      expect(lines.any((l) => l.level == 'error' && l.tag == 'api' && l.message.contains('500')), isTrue,
          reason: 'the failed call must be in the shipped log');

      expect(await session.refreshDiagnosticPending(), greaterThan(0),
          reason: 'a server error must be shippable without the operator asking');
      expect(session.diagnostics.snapshot().any((l) => l.message.contains('config/state')), isTrue);
    });

    test('auto-queue is throttled (no bundle flood while the server is down)', () async {
      final (session, _) = await sessionWith((_) async => http.Response('{}', 500));

      await session.posApi.configState('t1').catchError((Object _) => <String, dynamic>{});
      await pumpEventQueue();
      final first = await session.refreshDiagnosticPending();
      expect(first, greaterThan(0));

      await session.posApi.configState('t1').catchError((Object _) => <String, dynamic>{});
      await pumpEventQueue();
      expect(await session.refreshDiagnosticPending(), first,
          reason: 'a second 5xx within the window must not queue another bundle');
      // …but it is still RECORDED in the log.
      expect(session.diagnostics.snapshot().where((l) => l.tag == 'api').length, greaterThanOrEqualTo(2));
    });

    test('a 4xx is recorded but never auto-queues a bundle', () async {
      final (session, _) = await sessionWith((_) async => http.Response('{"error":"shift_required"}', 409));

      await session.posApi.configState('t1').catchError((Object _) => <String, dynamic>{});
      await pumpEventQueue();

      expect(session.diagnostics.snapshot().any((l) => l.tag == 'api' && l.message.contains('shift_required')), isTrue);
      expect(await session.refreshDiagnosticPending(), 0);
    });
  });
}
