import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gundam_pos/api/api_client.dart';
import 'package:gundam_pos/state/session_store.dart';
import 'package:gundam_pos/ui/activation_screen.dart';
import 'package:gundam_pos/ui/theme.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/fake_backend.dart';

ServerProbe _okProbe() => ServerProbe(
      httpClient: MockClient((_) async => http.Response('{"ok":true}', 200, headers: {'content-type': 'application/json'})),
    );

ServerProbe _probeReturning(http.Response Function(http.Request) handler) =>
    ServerProbe(httpClient: MockClient((req) async => handler(req)));

ServerProbe _probeThrowing(Object error) => ServerProbe(httpClient: MockClient((_) async => throw error));

void main() {
  group('resolveBaseUrl precedence', () {
    test('runtime address beats build-time define and default', () {
      const runtime = 'https://vpn.example:8443';
      expect(resolveBaseUrl(runtime: runtime), runtime);
      // No --dart-define in tests → falls back to the compiled default.
      expect(resolveBaseUrl(), defaultBaseUrl);
      expect(resolveBaseUrl(runtime: '  $runtime  '), runtime, reason: 'trimmed before use');
    });

    test('empty/blank runtime falls through to the build-time value', () {
      expect(resolveBaseUrl(runtime: ''), defaultBaseUrl);
      expect(resolveBaseUrl(runtime: '   '), defaultBaseUrl);
      expect(resolveBaseUrl(runtime: null), defaultBaseUrl);
    });
  });

  group('normalizeServerAddress', () {
    test('accepts host / host:port / http url / https url', () {
      expect(normalizeServerAddress('example.com'), 'http://example.com');
      expect(normalizeServerAddress('example.com:3000'), 'http://example.com:3000');
      expect(normalizeServerAddress('http://10.0.0.5:3100'), 'http://10.0.0.5:3100');
      expect(normalizeServerAddress('https://vpn.example/path'), 'https://vpn.example/path');
      expect(normalizeServerAddress('  gundam.local:3000  '), 'http://gundam.local:3000');
    });

    test('rejects empty / garbage — never silently accepted', () {
      for (final bad in ['', '   ', 'http://', 'ftp://x.com', '!!!', 'http://exa..mple.com', 'https://host!']) {
        expect(normalizeServerAddress(bad), isNull, reason: 'must reject "$bad"');
      }
    });
  });

  group('isInsecureServerUrl', () {
    test('http on a non-local host warns; https and localhost do not', () {
      expect(isInsecureServerUrl('http://10.0.0.5:3000'), isTrue);
      expect(isInsecureServerUrl('https://10.0.0.5:3000'), isFalse);
      expect(isInsecureServerUrl('http://localhost:3000'), isFalse);
      expect(isInsecureServerUrl('http://127.0.0.1:3000'), isFalse);
      expect(isInsecureServerUrl('http://10.0.2.2:3000'), isFalse);
    });
  });

  group('ServerProbe classification', () {
    test('GET /api/health 200 JSON → healthy', () async {
      final probe = _probeReturning((req) => req.url.path == '/api/health'
          ? http.Response('{"status":"ok"}', 200, headers: {'content-type': 'application/json'})
          : http.Response('nope', 404));
      final r = await probe.probe('http://srv.test');
      expect(r.state, ServerProbeState.healthy);
    });

    test('health absent → falls back to a known POS endpoint (JSON → healthy)', () async {
      final probe = _probeReturning((req) => req.url.path == ServerProbe.fallbackPath
          ? http.Response('{"error":"unauthorized"}', 401, headers: {'content-type': 'application/json'})
          : http.Response('Not Found', 404, headers: {'content-type': 'text/html'}));
      final r = await probe.probe('http://srv.test');
      expect(r.state, ServerProbeState.healthy);
      expect(r.detail, contains('config/state'));
    });

    test('reachable but non-JSON service → wrongService', () async {
      final probe = _probeReturning((_) => http.Response('<html>nginx</html>', 200, headers: {'content-type': 'text/html'}));
      final r = await probe.probe('http://srv.test');
      expect(r.state, ServerProbeState.wrongService);
    });

    test('connection refused / timeout → unreachable', () async {
      final r = await _probeThrowing(http.ClientException('connection refused')).probe('http://srv.test');
      expect(r.state, ServerProbeState.unreachable);
    });

    test('handshake failure → tlsFailure', () async {
      final r = await _probeThrowing(const HandshakeException('CERTIFICATE_VERIFY_FAILED')).probe('https://srv.test');
      expect(r.state, ServerProbeState.tlsFailure);
    });
  });

  group('AppSession runtime server address', () {
    test('persists across a rebuild of the session', () async {
      final backend = FakeBackend();
      final addr = InMemoryServerAddressStore();
      final s1 = backend.createSession(store: InMemorySessionStore(), addressStore: addr);
      await s1.init();
      final r = await s1.setServerAddress('https://vpn.example:8443', probe: _okProbe());
      expect(r.ok, isTrue);
      expect(s1.serverAddress, 'https://vpn.example:8443');

      // Rebuild the session against the SAME store (simulates an app restart).
      final s2 = backend.createSession(store: InMemorySessionStore(), addressStore: addr);
      await s2.init();
      expect(s2.serverAddress, 'https://vpn.example:8443');
      expect(s2.posApi.baseUrl, 'https://vpn.example:8443');
    });

    test('every network call site uses the runtime address (activation, login, config sync)', () async {
      final backend = FakeBackend();
      final session = backend.createSession(store: InMemorySessionStore(), addressStore: InMemoryServerAddressStore());
      await session.init();
      await session.setServerAddress('https://vpn.example:8443', probe: _okProbe());

      expect(session.posApi.baseUrl, 'https://vpn.example:8443');
      backend.requested.clear();

      await session.redeem('x' * 64); // activation
      await session.login(email: 'c@x.demo', password: 'Pass1234'); // login + config sync

      expect(backend.requested, isNotEmpty);
      expect(
        backend.requested.every((u) => u.host == 'vpn.example' && u.port == 8443),
        isTrue,
        reason: 'no call may still target the compiled-in address: ${backend.requested}',
      );
      expect(backend.requested.any((u) => u.path == '/api/auth/pos-redeem'), isTrue);
      expect(backend.requested.any((u) => u.path == '/api/auth/pos-login'), isTrue);
      expect(backend.requested.any((u) => u.path == '/api/pos/config/state'), isTrue);
    });

    test('a failed probe keeps the previous working address', () async {
      final backend = FakeBackend();
      final addr = InMemoryServerAddressStore();
      final session = backend.createSession(store: InMemorySessionStore(), addressStore: addr);
      await session.init();
      await session.setServerAddress('https://good.example:1', probe: _okProbe());

      final failed = await session.setServerAddress('https://bad.example:2', probe: _probeThrowing(http.ClientException('refused')));
      expect(failed.ok, isFalse);
      expect(failed.state, ServerProbeState.unreachable);
      expect(session.serverAddress, 'https://good.example:1');
      expect(session.posApi.baseUrl, 'https://good.example:1');
      expect(await addr.load(), 'https://good.example:1');

      final invalid = await session.setServerAddress('!!!', probe: _okProbe());
      expect(invalid.state, ServerProbeState.invalid);
      expect(session.serverAddress, 'https://good.example:1');
    });
  });

  group('ServerAddressField on the activation screen', () {
    testWidgets('http warning shows for http:// non-localhost, hides for https and localhost', (tester) async {
      final session = FakeBackend().createSession(store: InMemorySessionStore());
      await session.init();
      await tester.pumpWidget(MaterialApp(theme: PosTheme.theme(), home: ActivationScreen(session: session)));

      final field = find.widgetWithText(TextField, 'Server address');
      expect(field, findsOneWidget);

      await tester.enterText(field, 'http://10.0.0.5:3000');
      await tester.pump();
      expect(find.textContaining('plain http'), findsOneWidget);

      await tester.enterText(field, 'https://10.0.0.5:3000');
      await tester.pump();
      expect(find.textContaining('plain http'), findsNothing);

      await tester.enterText(field, 'http://localhost:3000');
      await tester.pump();
      expect(find.textContaining('plain http'), findsNothing);
    });
  });
}
