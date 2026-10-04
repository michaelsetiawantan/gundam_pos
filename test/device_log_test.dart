import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gundam_pos/api/api_client.dart';
import 'package:gundam_pos/api/pos_api.dart';
import 'package:gundam_pos/data/config_cache.dart';
import 'package:gundam_pos/services/diagnostic_report.dart';
import 'package:gundam_pos/state/app_session.dart';
import 'package:gundam_pos/state/session_store.dart';
import 'package:gundam_pos/ui/device_log_screen.dart';
import 'package:gundam_pos/ui/theme.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// (A) non-HTTP failures must be RECORDED; (B) the warn/error trail must
/// SURVIVE a restart; (C) the operator must be able to SEE and SEND the log
/// from the tablet. Each test is falsifiable: without the new logging /
/// persistence / screen it fails.

PosApi _throwingApi() => PosApi(ApiClient(
      baseUrl: 'http://fake.test',
      authProvider: () => null,
      httpClient: MockClient((_) async => throw http.ClientException('offline')),
    ));

PosContext _readyCtx() => const PosContext()
    .withRedeem({'deviceToken': 'd', 'groupId': 'g1', 'tenantId': 't1', 'shortcode': 'NSTAR-POS1'})
    .withSession({'sessionId': 's1', 'user': {'id': 'u1', 'fullName': 'C1'}, 'outlet': {'id': 't1', 'name': 'Northstar'}})
    .copyWith(deviceId: 'device-1');

void main() {
  group('(A) non-HTTP failures are recorded', () {
    test('an offline logout leaves a warn line (previously swallowed)', () async {
      final session = AppSession(posApi: _throwingApi(), sessionStore: InMemorySessionStore());
      session.ctx = _readyCtx();

      await session.logout();

      expect(
        session.diagnostics.snapshot().any((l) => l.tag == 'logout' && l.level == 'warn'),
        isTrue,
        reason: 'an unreachable logout must leave a trail, not vanish into catch(_)',
      );
    });

    test('a corrupt cached config payload is recorded, not silently dropped', () async {
      final dir = Directory.systemTemp.createTempSync('gundam_devlog_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final cache = ConfigCache(dir);
      // A FORMULA payload that is not valid JSON → hydrate throws → warn.
      await cache.write(ConfigKey('FORMAT'), jsonPayload: '{not valid json');

      final session = AppSession(posApi: _throwingApi(), sessionStore: InMemorySessionStore());
      session.attachConfigCache(cache);
      await session.hydrateFromCache();

      expect(
        session.diagnostics.snapshot().any((l) => l.tag == 'cache' && l.level == 'warn'),
        isTrue,
        reason: 'a hydration failure must be visible in the diagnostics log',
      );
    });
  });

  group('(B) the warn/error trail survives a restart', () {
    test('MemoryDiagnosticLogStore keeps order, caps rows and prunes by age', () async {
      final now = DateTime(2026, 10, 4, 12);
      final store = MemoryDiagnosticLogStore(now: () => now);
      for (var i = 0; i < kDiagMaxPersistedRows + 25; i++) {
        await store.append(LogLine(at: now, level: 'error', tag: 't', message: 'line $i'));
      }
      final rows = await store.recent(limit: kDiagMaxPersistedRows + 100);
      expect(rows, hasLength(kDiagMaxPersistedRows));
      expect(rows.last.message, 'line ${kDiagMaxPersistedRows + 24}'); // newest kept

      final old = now.subtract(kDiagMaxPersistedAge + const Duration(days: 1));
      await store.append(LogLine(at: old, level: 'error', tag: 't', message: 'stale'));
      await store.prune(maxRows: kDiagMaxPersistedRows, maxAge: kDiagMaxPersistedAge);
      expect((await store.recent()).any((l) => l.message == 'stale'), isFalse);
    });

    test('a new session restores the previous session lines, marked prior-session', () async {
      // Same durable store, two DIFFERENT in-memory buffers → the restart.
      final store = MemoryDiagnosticLogStore();
      final session1 = AppSession(
        posApi: _throwingApi(),
        sessionStore: InMemorySessionStore(),
        diagLog: DiagnosticLog(),
        diagStore: store,
      );
      session1.diagnostics.error('boom', 'context lost at 03:00');
      await pumpEventQueue(); // let the fire-and-forget append land

      // Restart: a FRESH buffer, the SAME durable store.
      final session2 = AppSession(
        posApi: _throwingApi(),
        sessionStore: InMemorySessionStore(),
        diagLog: DiagnosticLog(),
        diagStore: store,
      );
      expect(session2.diagnostics.snapshot().any((l) => l.tag == 'boom'), isFalse,
          reason: 'a fresh process starts with an empty in-memory buffer');
      await session2.init();

      final recovered = session2.diagnostics.snapshot().firstWhere((l) => l.tag == 'boom');
      expect(recovered.fromPreviousSession, isTrue);
      expect(recovered.toJson()['previousSession'], isTrue,
          reason: 'the bundle must mark a prior-session line as such');
    });
  });

  group('(C) the Device log screen', () {
    testWidgets('shows the lines, filters, copies and can send to the server', (tester) async {
      final hits = <String>[];
      final client = ApiClient(
        baseUrl: 'http://fake.test',
        authProvider: () => null,
        httpClient: MockClient((req) async {
          hits.add(req.url.path);
          return http.Response('{"accepted":true}', 200, headers: {'content-type': 'application/json'});
        }),
      );
      final log = DiagnosticLog()
        ..info('boot', 'app started')
        ..warn('print', 'printer unreachable')
        ..error('api', 'server error 500');
      final session = AppSession(
        posApi: PosApi(client),
        sessionStore: InMemorySessionStore(),
        diagLog: log,
      );
      session.ctx = _readyCtx();

      await tester.pumpWidget(MaterialApp(theme: PosTheme.theme(), home: DeviceLogScreen(session: session)));
      await tester.pumpAndSettle();

      expect(find.text('printer unreachable'), findsOneWidget);
      expect(find.text('server error 500'), findsOneWidget);
      expect(find.textContaining('1 error, 1 warn'), findsOneWidget);

      // Filter to errors only: the warn line disappears.
      await tester.tap(find.widgetWithText(ChoiceChip, 'error'));
      await tester.pumpAndSettle();
      expect(find.text('server error 500'), findsOneWidget);
      expect(find.text('printer unreachable'), findsNothing);

      // Send to server → the durable diagnostics POST goes out.
      await tester.tap(find.widgetWithText(FilledButton, 'Send to server'));
      await tester.pumpAndSettle();
      expect(hits, contains('/api/pos/diagnostics'));
    });
  });
}
