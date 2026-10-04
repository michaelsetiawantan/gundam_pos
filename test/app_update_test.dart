import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gundam_pos/models/app_release.dart';
import 'package:gundam_pos/services/update_service.dart';
import 'package:gundam_pos/state/app_session.dart';
import 'package:gundam_pos/state/release_store.dart';
import 'package:gundam_pos/state/session_store.dart';
import 'package:gundam_pos/ui/about_screen.dart';
import 'package:gundam_pos/ui/more_screen.dart';
import 'package:gundam_pos/ui/theme.dart';
import 'package:path/path.dart' as p;

import 'support/fake_backend.dart';

/// Records what the platform half was asked to do. The real installer intent is
/// Android-only (device verified); the decision logic above it is what we test.
class _FakeBridge implements ApkInstallBridge {
  _FakeBridge(this.bytes, {required this.dir});

  final List<int> bytes;
  final String dir;
  final List<String> downloaded = [];
  final List<String> installed = [];
  bool failInstall = false;

  @override
  Future<List<int>> download(String url) async {
    downloaded.add(url);
    return bytes;
  }

  @override
  Future<String> apkDirectory() async => dir;

  @override
  Future<String> install(String path) async {
    if (failInstall) throw StateError('installer unavailable');
    installed.add(path);
    return 'Installer opened for ${path.split('/').last}';
  }
}

Future<AppSession> readySession(FakeBackend backend, {ReleaseInfoStore? releaseStore}) async {
  final store = InMemorySessionStore();
  await store.save(const PosContext()
      .withRedeem({'deviceToken': 'd', 'groupId': 'g1', 'tenantId': 't1', 'shortcode': 'NSTAR-POS1'})
      .withSession({'sessionId': 's1', 'user': {'id': 'u1', 'fullName': 'C1'}, 'outlet': {'id': 't1', 'name': 'Northstar'}})
      .copyWith(deviceId: 'device-1'));
  final session = backend.createSession(store: store, releaseStore: releaseStore);
  await session.init();
  return session;
}

void main() {
  // The tablet's own identity, from the build defines with a pubspec fallback.
  group('version identity', () {
    final v = AppVersion.running(schemaVersion: 3);

    test('exposes version name + versionCode + schema version', () {
      expect(v.versionName, isNotEmpty);
      expect(v.versionCode, greaterThan(0));
      expect(v.schemaVersion, 3);
      expect(v.display, contains('v${v.versionName}'));
    });

    test('nothing in the defines leaves no blank field', () {
      // The fallbacks must always produce something displayable.
      expect(AppVersion.running(schemaVersion: 0).versionName, isNotEmpty);
    });
  });

  group('ReleaseInfo parsing (tolerant)', () {
    test('reads the server manifest keys', () {
      final r = ReleaseInfo.parse(FakeBackend.release(
        version: '0.4.1',
        versionCode: 41,
        sha256: 'AB' * 32,
        minSupportedConfig: 7,
        mandatory: true,
        changelog: 'Line one\nLine two',
        releasedAt: '2026-09-01T10:00:00Z',
      ))!;
      expect(r.version, '0.4.1');
      expect(r.versionCode, 41);
      expect(r.minSupportedConfig, 7);
      expect(r.mandatory, isTrue);
      expect(r.changelog, contains('Line one'));
      expect(r.releasedAt, isNotNull);
      expect(r.installable, isTrue);
      expect(r.sha256Matches('ab' * 32), isTrue); // case-insensitive hex compare
    });

    test('honest empty shape is not a release', () {
      expect(ReleaseInfo.parse(const {}), isNull);
      expect(ReleaseInfo.parse(null), isNull);
      expect(ReleaseInfo.parse(const {'version': '0.4.1'}), isNull); // no versionCode
      expect(ReleaseInfo.parse(const {'versionCode': 4}), isNull); // no version
      expect(ReleaseInfo.parse(const {'version': null, 'versionCode': null}), isNull);
    });

    test('tolerates string numbers, string booleans and a changelog list', () {
      final r = ReleaseInfo.parse(const {
        'version': 0.5, // JSON number for a version string
        'version_code': '5',
        'apkUrl': 'https://x/y.apk',
        'sha_256': 'abc',
        'mandatory': 'true',
        'changelog': ['First fix', '', 'Second fix'],
      })!;
      expect(r.version, '0.5');
      expect(r.versionCode, 5);
      expect(r.mandatory, isTrue);
      expect(r.changelog, 'First fix\nSecond fix');
      expect(r.apkUrl, 'https://x/y.apk');
    });

    test('garbage is dropped, never guessed into an update', () {
      expect(ReleaseInfo.parse('not json'), isNull);
      expect(ReleaseInfo.parse(<dynamic>[]), isNull);
      expect(ReleaseInfo.parse(const {'version': 'x', 'versionCode': 'abc'}), isNull);
    });
  });

  group('update check', () {
    test('a newer versionCode raises the notice with changelog + mandatory flag', () async {
      final backend = FakeBackend()
        ..versionJson = FakeBackend.release(
          version: '0.3.0',
          versionCode: 3,
          mandatory: true,
          changelog: 'Faster order entry.',
        );
      final session = await readySession(backend);
      await session.checkForUpdate();

      expect(session.updateAvailable, isTrue);
      expect(session.lastRelease!.version, '0.3.0');
      expect(session.lastRelease!.changelog, 'Faster order entry.');
      expect(session.lastRelease!.mandatory, isTrue);
      expect(session.lastUpdateCheckError, isNull);
      expect(session.lastUpdateCheckedAt, isNotNull);
    });

    test('an equal or older versionCode is not an update', () async {
      for (final code in [sessionVersionCode, sessionVersionCode - 1]) {
        final backend = FakeBackend()..versionJson = FakeBackend.release(versionCode: code);
        final session = await readySession(backend);
        await session.checkForUpdate();
        expect(session.updateAvailable, isFalse, reason: 'versionCode $code');
      }
    });

    test('an unpublished (empty) response is never an update and never an error', () async {
      final backend = FakeBackend()..versionJson = const {};
      final session = await readySession(backend);
      await session.checkForUpdate();

      expect(session.updateAvailable, isFalse);
      expect(session.lastRelease, isNull);
      expect(session.lastUpdateCheckError, isNull);
    });

    test('a malformed payload is tolerated (no notice, no throw)', () async {
      final backend = FakeBackend()..versionJson = const {'version': 'oops', 'versionCode': '???'};
      final session = await readySession(backend);
      await session.checkForUpdate();

      expect(session.updateAvailable, isFalse);
      expect(session.lastUpdateCheckError, isNull);
    });

    test('a failed fetch stays silent but is recorded honestly', () async {
      final backend = FakeBackend()
        ..versionJson = FakeBackend.release(versionCode: 9)
        ..versionStatus = 503;
      final session = await readySession(backend);
      await session.checkForUpdate();

      expect(session.updateAvailable, isFalse);
      expect(session.lastUpdateCheckError, contains('503'));
      expect(session.lastError, isNull, reason: 'the cashier must not see a dead network');
      expect(session.isReady, isTrue);
    });

    test('login triggers the check (login → config sync)', () async {
      final backend = FakeBackend()..versionJson = FakeBackend.release(versionCode: 3);
      final session = await readySession(backend);
      backend.requested.clear();

      await session.login(email: 'c@x.demo', password: 'pw');
      expect(backend.requested.any((u) => u.path == '/api/pos/version.json'), isTrue);
      expect(session.updateAvailable, isTrue);
    });

    test('config sync triggers the check', () async {
      final backend = FakeBackend()..versionJson = FakeBackend.release(versionCode: 3);
      final session = await readySession(backend);
      backend.requested.clear();

      await session.refreshConfig();
      expect(backend.requested.any((u) => u.path == '/api/pos/version.json'), isTrue);
    });

    test('the last release survives a restart (persisted for "what\'s new")', () async {
      final backend = FakeBackend()
        ..versionJson = FakeBackend.release(version: '0.3.0', versionCode: 3, changelog: 'Notes for 0.3.0.');
      final store = InMemoryReleaseInfoStore();
      final first = await readySession(backend, releaseStore: store);
      await first.checkForUpdate();
      expect(first.lastRelease!.version, '0.3.0');

      // A fresh session (post-install restart) reads it back; no notice until a
      // fresh check confirms the offer.
      final second = await readySession(FakeBackend(), releaseStore: store);
      expect(second.lastRelease!.version, '0.3.0');
      expect(second.lastRelease!.changelog, 'Notes for 0.3.0.');
      expect(second.updateAvailable, isFalse, reason: 'nothing offered until checked');
    });
  });

  group('install flow (download → SHA-256 → installer)', () {
    late Directory dir;

    setUp(() => dir = Directory.systemTemp.createTempSync('gundam-apk-test'));
    tearDown(() { if (dir.existsSync()) dir.deleteSync(recursive: true); });

    test('a matching SHA-256 stages the APK and opens the installer', () async {
      final bytes = List<int>.generate(64, (i) => i);
      final bridge = _FakeBridge(bytes, dir: dir.path);
      final release = ReleaseInfo.parse(FakeBackend.release(
        version: '0.3.0',
        versionCode: 3,
        apkUrl: 'https://pos.example/a.apk',
        sha256: sha256.convert(bytes).toString(),
      ))!;

      final attempt = await UpdateService(bridge).apply(release);

      expect(attempt.outcome, UpdateOutcome.installed);
      expect(bridge.downloaded, ['https://pos.example/a.apk']);
      expect(bridge.installed.single, endsWith('gundam-pos-v0.3.0.apk'));
      expect(File(bridge.installed.single).existsSync(), isTrue,
          reason: 'the APK handed to the installer is kept until it finishes; '
              'the app-start prune clears it on the next launch');
    });

    test('a SHA-256 mismatch REFUSES the install and reports it', () async {
      final bridge = _FakeBridge(List<int>.filled(32, 7), dir: dir.path);
      final release = ReleaseInfo.parse(FakeBackend.release(
        versionCode: 3,
        sha256: 'a' * 64, // advertised value the bytes do not match
      ))!;

      final attempt = await UpdateService(bridge).apply(release);

      expect(attempt.outcome, UpdateOutcome.shaMismatch);
      expect(bridge.installed, isEmpty, reason: 'never installed on a mismatch');
      expect(attempt.message, contains('SHA-256 mismatch'));
      // Nothing was staged either: the file is only written after verification.
      expect(dir.listSync(), isEmpty);
    });

    test('a release without apk_url/sha256 cannot be installed', () async {
      final bridge = _FakeBridge(const [], dir: dir.path);
      final release = ReleaseInfo.parse(FakeBackend.release(versionCode: 3, apkUrl: '', sha256: ''))!;

      final attempt = await UpdateService(bridge).apply(release);

      expect(attempt.outcome, UpdateOutcome.unavailable);
      expect(bridge.installed, isEmpty);
    });

    test('an installer failure is reported, not thrown', () async {
      final bytes = List<int>.filled(8, 1);
      final bridge = _FakeBridge(bytes, dir: dir.path)..failInstall = true;
      final release = ReleaseInfo.parse(FakeBackend.release(
        versionCode: 3,
        sha256: sha256.convert(bytes).toString(),
      ))!;

      final attempt = await UpdateService(bridge).apply(release);
      expect(attempt.outcome, UpdateOutcome.failed);
      expect(attempt.message, contains('installer unavailable'));
    });

    test('staging a new version deletes earlier APKs — only the new one remains', () async {
      // Two full-size APKs left behind by previous updates, plus a temp download.
      _oldFile(p.join(dir.path, 'gundam-pos-v0.1.0.apk'), 'old-1');
      _oldFile(p.join(dir.path, 'gundam-pos-v0.2.0.apk'), 'old-2');
      _oldFile(p.join(dir.path, 'staging.part'), 'partial');

      final bytes = List<int>.filled(16, 5);
      // failInstall keeps the freshly staged file so we can inspect the directory.
      final bridge = _FakeBridge(bytes, dir: dir.path)..failInstall = true;
      final release = ReleaseInfo.parse(FakeBackend.release(
        version: '0.3.0',
        versionCode: 3,
        sha256: sha256.convert(bytes).toString(),
      ))!;

      await UpdateService(bridge).apply(release);

      final names = dir.listSync().whereType<File>().map((f) => p.basename(f.path)).toList();
      expect(names, ['gundam-pos-v0.3.0.apk'],
          reason: 'previous APKs and the .part are removed; only the new APK stays');
    });

    test('non-APK files (logs) survive the staging cleanup', () async {
      final log = File(p.join(dir.path, 'update.log'))..writeAsStringSync('keep me');
      final bytes = List<int>.filled(8, 6);
      final bridge = _FakeBridge(bytes, dir: dir.path)..failInstall = true;
      final release = ReleaseInfo.parse(FakeBackend.release(
        versionCode: 3,
        sha256: sha256.convert(bytes).toString(),
      ))!;

      await UpdateService(bridge).apply(release);

      expect(log.existsSync(), isTrue);
      expect(log.readAsStringSync(), 'keep me');
    });

    test('a cleanup failure is swallowed — apply never throws', () async {
      // apkDirectory points under a regular file: createSync/listSync cannot
      // work, so the whole staging step fails — but apply returns, not throws.
      final blocker = File(p.join(dir.path, 'not-a-dir'))..writeAsStringSync('x');
      final bytes = List<int>.filled(8, 1);
      final bridge = _FakeBridge(bytes, dir: p.join(blocker.path, 'apk'));
      final release = ReleaseInfo.parse(FakeBackend.release(
        versionCode: 3,
        sha256: sha256.convert(bytes).toString(),
      ))!;

      final attempt = await UpdateService(bridge).apply(release); // must not throw
      expect(attempt.outcome, UpdateOutcome.failed);
      expect(bridge.installed, isEmpty);
    });

    test('a SHA-256 mismatch keeps the previous valid APK untouched', () async {
      final previous = File(p.join(dir.path, 'gundam-pos-v0.2.0.apk'))..writeAsStringSync('previous-good');
      final bridge = _FakeBridge(List<int>.filled(32, 7), dir: dir.path);
      final release = ReleaseInfo.parse(FakeBackend.release(
        versionCode: 3,
        sha256: 'a' * 64, // advertised digest the bytes do not match
      ))!;

      final attempt = await UpdateService(bridge).apply(release);

      expect(attempt.outcome, UpdateOutcome.shaMismatch);
      expect(bridge.installed, isEmpty);
      expect(previous.existsSync(), isTrue,
          reason: 'verification runs before cleanup, so the old APK is not deleted');
    });

    test('app-start prune clears APKs left by older builds; in-use file and non-APKs survive', () async {
      _oldFile(p.join(dir.path, 'gundam-pos-v0.1.0.apk'), 'old-1');
      _oldFile(p.join(dir.path, 'gundam-pos-v0.2.0.apk'), 'old-2');
      _oldFile(p.join(dir.path, 'staging.part'), 'partial');
      File(p.join(dir.path, 'update.log')).writeAsStringSync('keep me');
      final inUse = p.join(dir.path, 'gundam-pos-v0.3.0.apk');
      _oldFile(inUse, 'installing');

      UpdateService.pruneDirectory(dir.path, keep: inUse);

      final names = dir.listSync().whereType<File>().map((f) => p.basename(f.path)).toList()..sort();
      expect(names, ['gundam-pos-v0.3.0.apk', 'update.log'],
          reason: 'old APKs + .part are cleared; the in-use APK and non-APK files stay');
    });

    test('a FRESH download survives the app-start prune (pending install)', () async {
      // Field bug: the user downloaded the update, switched back to the app (which
      // re-ran the start prune without a `keep`), and Android could no longer read
      // the APK → "can't install / problem parsing the package".
      final fresh = File(p.join(dir.path, 'gundam-pos-v0.4.9.apk'))..writeAsStringSync('just downloaded');
      _oldFile(p.join(dir.path, 'gundam-pos-v0.1.0.apk'), 'ancient');

      UpdateService.pruneDirectory(dir.path); // exactly what app start does

      expect(fresh.existsSync(), isTrue, reason: 'a just-downloaded APK must not be yanked mid-install');
      expect(File(p.join(dir.path, 'gundam-pos-v0.1.0.apk')).existsSync(), isFalse,
          reason: 'older leftovers are still cleaned');
    });

    test('pruneStaleDownloads on a missing directory never throws', () async {
      final bridge = _FakeBridge(const [], dir: p.join(dir.path, 'does-not-exist'));
      await UpdateService(bridge).pruneStaleDownloads(); // must not throw
    });
  });

  group('About / Version screen', () {
    testWidgets('shows version, versionCode, schema version and server address', (tester) async {
      final backend = FakeBackend();
      final session = await readySession(backend);
      final v = session.appVersion;

      await tester.pumpWidget(MaterialApp(theme: PosTheme.theme(), home: AboutScreen(session: session)));
      await tester.pumpAndSettle();

      expect(find.text('About / Version'), findsOneWidget);
      expect(find.text('Version'), findsOneWidget);
      expect(find.text(v.versionName), findsOneWidget);
      expect(find.text('Version code'), findsOneWidget);
      expect(find.text('${v.versionCode}'), findsOneWidget);
      expect(find.text('Schema version'), findsOneWidget);
      expect(find.text('${v.schemaVersion}'), findsOneWidget);
      expect(find.text('Server address'), findsOneWidget);
      expect(find.text(session.serverAddress), findsOneWidget);

      // The release surface is below the fold in the scrolling body.
      await tester.scrollUntilVisible(find.text("What's new"), 300, scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      expect(find.text('No release has been seen from the server yet.'), findsOneWidget);
      expect(find.text('Check for update'), findsOneWidget);
    });

    testWidgets('offers the release with its changelog and installs on confirmation', (tester) async {
      final bytes = List<int>.filled(24, 3);
      final backend = FakeBackend()
        ..versionJson = FakeBackend.release(
          version: '0.3.0',
          versionCode: 3,
          mandatory: true,
          changelog: 'Faster order entry.',
          sha256: sha256.convert(bytes).toString(),
        );
      final session = await readySession(backend);
      await session.checkForUpdate();
      final apkDir = Directory.systemTemp.createTempSync('gundam-apk-ui');
      final bridge = _FakeBridge(bytes, dir: apkDir.path);

      await tester.pumpWidget(MaterialApp(
        theme: PosTheme.theme(),
        home: AboutScreen(session: session, installer: bridge),
      ));
      await tester.pumpAndSettle();

      // The notice, the changelog and the mandatory flag are all visible.
      expect(find.text('New version v0.3.0 available'), findsOneWidget);
      expect(find.textContaining('MANDATORY'), findsOneWidget);
      expect(find.text('Faster order entry.'), findsOneWidget); // the notice
      expect(find.textContaining('In-place install keeps local data'), findsOneWidget);

      // "What's new" keeps the changelog reachable for the offered version.
      await tester.scrollUntilVisible(find.text("What's new"), 300, scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      expect(find.textContaining('offered to this tablet'), findsOneWidget);
      expect(find.text('Faster order entry.'), findsWidgets);

      // Manual, user-confirmed: nothing is downloaded or installed until the
      // operator accepts (the post-confirmation download/verify/install path is
      // covered by the unit tests above; the staging write is real file IO).
      await tester.scrollUntilVisible(find.text('Download & install'), -300, scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Download & install'));
      await tester.pumpAndSettle();
      expect(find.text('Install v0.3.0?'), findsOneWidget);
      expect(bridge.downloaded, isEmpty);
      expect(bridge.installed, isEmpty);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(bridge.downloaded, isEmpty);
      expect(bridge.installed, isEmpty);
      apkDir.deleteSync(recursive: true);
    });

    testWidgets('a SHA-256 mismatch is reported on the screen and never installed', (tester) async {
      final backend = FakeBackend()
        ..versionJson = FakeBackend.release(versionCode: 3, sha256: 'b' * 64);
      final session = await readySession(backend);
      await session.checkForUpdate();
      final apkDir = Directory.systemTemp.createTempSync('gundam-apk-bad');
      final bridge = _FakeBridge(List<int>.filled(16, 9), dir: apkDir.path);

      await tester.pumpWidget(MaterialApp(
        theme: PosTheme.theme(),
        home: AboutScreen(session: session, installer: bridge),
      ));
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(find.text('Download & install'), 300, scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Download & install'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Install now'));
      await tester.pumpAndSettle();

      expect(bridge.installed, isEmpty);
      expect(find.textContaining('SHA-256 mismatch'), findsWidgets);
      apkDir.deleteSync(recursive: true);
    });
  });

  testWidgets('More exposes a direct "Send diagnostics to server" entry', (tester) async {
    final session = await readySession(FakeBackend());

    await tester.pumpWidget(MaterialApp(theme: PosTheme.theme(), home: MoreScreen(session: session)));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(find.text('Send diagnostics to server'), 300,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('Send diagnostics to server'), findsOneWidget);
    expect(find.textContaining('bundles the device context'), findsOneWidget); // subtitle names its job
    expect(find.text('Open print diagnostics'), findsOneWidget); // existing entry is NOT removed
  });

  testWidgets('More screen shows the identity + the update notice', (tester) async {
    final backend = FakeBackend()
      ..versionJson = FakeBackend.release(version: '0.3.0', versionCode: 3, changelog: 'Faster order entry.');
    final session = await readySession(backend);
    await session.checkForUpdate();

    await tester.pumpWidget(MaterialApp(theme: PosTheme.theme(), home: MoreScreen(session: session)));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(find.text('Client update'), 300, scrollable: find.byType(Scrollable).first);
    expect(find.text('Installed'), findsOneWidget);
    expect(find.text(session.appVersion.display), findsOneWidget);
    expect(find.text('New version v0.3.0 available'), findsOneWidget);
    expect(find.text('Faster order entry.'), findsOneWidget);
    expect(find.text('Version & updates'), findsOneWidget);
  });
}

/// This build's versionCode, used to drive "equal / older" cases without
/// hardcoding the pubspec fallback.
final int sessionVersionCode = AppVersion.running(schemaVersion: 0).versionCode;

/// A staged file old enough for the age window to prune (a pending install is
/// deliberately spared for 30 minutes, so "old" test fixtures must be back-dated).
File _oldFile(String path, String content) {
  final f = File(path)..writeAsStringSync(content);
  f.setLastModifiedSync(DateTime.now().subtract(const Duration(hours: 2)));
  return f;
}
