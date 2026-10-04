import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gundam_pos/services/media_sync.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

// The IMAGE block must print offline: the manifest carries key/url/sha256/size
// and this sync brings the bytes into the local cache. A wrong hash or a short
// body is a FAILURE — never a half-written file the printer would raster.

String _sha(List<int> bytes) => sha256.convert(bytes).toString();

MockClient _backend(Map<String, List<int>> files, {List<Map<String, Object?>>? manifest, String? failKey}) {
  return MockClient((req) async {
    if (req.url.path.contains('/media/manifest')) {
      final entries = manifest ??
          files.entries
              .map((e) => <String, Object?>{
                    'key': e.key,
                    'url': 'https://cdn.test/${e.key}',
                    'sha256': _sha(e.value),
                    'size': e.value.length,
                    'version': 1,
                    'kind': 'OTHER',
                  })
              .toList();
      return http.Response(jsonEncode({'assets': entries}), 200,
          headers: {'content-type': 'application/json'});
    }
    final name = req.url.pathSegments.last;
    if (failKey != null && name == failKey) return http.Response('boom', 500);
    final bytes = files[name];
    if (bytes == null) return http.Response('missing', 404);
    return http.Response.bytes(bytes, 200);
  });
}

void main() {
  late Directory dir;
  late MemoryMediaCacheStore store;
  final manifestUri = Uri.parse('https://srv.test/api/pos/media/manifest?tenantId=t1');

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('gundam-media-');
    store = MemoryMediaCacheStore();
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  MediaSync sync(MockClient client) =>
      MediaSync(dir: dir, store: store, httpClient: client);

  test('downloads, verifies and caches every manifest entry', () async {
    final logo = utf8.encode('PNG-LOGO-BYTES');
    final s = sync(_backend({'logo': logo}));

    final report = await s.sync(manifestUri: manifestUri);

    expect(report.ok, isTrue);
    expect(report.downloaded, ['logo']);
    expect(report.failed, isEmpty);

    final file = File('${dir.path}/logo');
    expect(await file.exists(), isTrue);
    expect(await file.readAsBytes(), logo);

    final row = await store.find('logo');
    expect(row, isNotNull);
    expect(row!.sha256, _sha(logo));
    expect(row.size, logo.length);
    expect(row.localPath, file.path);

    expect(await s.bytesFor('logo'), logo);
  });

  test('re-uses a cached asset with the same hash (no re-download)', () async {
    final bytes = utf8.encode('LOGO');
    await sync(_backend({'logo': bytes})).sync(manifestUri: manifestUri);

    var downloads = 0;
    final counting = MockClient((req) async {
      if (req.url.path.contains('/media/manifest')) {
        return http.Response(
          jsonEncode({
            'assets': [
              {'key': 'logo', 'url': 'https://cdn.test/logo', 'sha256': _sha(bytes), 'size': bytes.length, 'version': 1},
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      downloads++;
      return http.Response.bytes(bytes, 200);
    });

    final second = sync(counting);
    final report = await second.sync(manifestUri: manifestUri);
    expect(report.skipped, ['logo']);
    expect(report.downloaded, isEmpty);
    expect(downloads, 0);
  });

  test('a hash mismatch fails and never leaves a file behind', () async {
    final manifest = [
      {
        'key': 'logo',
        'url': 'https://cdn.test/logo',
        'sha256': _sha(utf8.encode('EXPECTED')),
        'size': 0,
        'version': 1,
      },
    ];
    final s = sync(_backend({'logo': utf8.encode('ACTUAL')}, manifest: manifest));

    final report = await s.sync(manifestUri: manifestUri);

    expect(report.ok, isFalse);
    expect(report.failed.single, startsWith('logo:sha256'));
    expect(report.downloaded, isEmpty);
    expect(await File('${dir.path}/logo').exists(), isFalse);
    expect(await File('${dir.path}/logo.part').exists(), isFalse);
    expect(await store.find('logo'), isNull);
  });

  test('a size mismatch fails and records nothing', () async {
    final bytes = utf8.encode('LOGO');
    final manifest = [
      {'key': 'logo', 'url': 'https://cdn.test/logo', 'sha256': _sha(bytes), 'size': 999, 'version': 1},
    ];
    final s = sync(_backend({'logo': bytes}, manifest: manifest));

    final report = await s.sync(manifestUri: manifestUri);

    expect(report.ok, isFalse);
    expect(report.failed.single, startsWith('logo:size'));
    expect(await store.find('logo'), isNull);
  });

  test('an HTTP failure is reported, not cached', () async {
    final s = sync(_backend({'logo': utf8.encode('X')}, failKey: 'logo'));
    final report = await s.sync(manifestUri: manifestUri);
    expect(report.ok, isFalse);
    expect(report.failed.single, 'logo:http500');
    expect(await store.find('logo'), isNull);
  });

  test('an asset dropped from the manifest is pruned (row + file)', () async {
    final bytes = utf8.encode('LOGO');
    await sync(_backend({'logo': bytes})).sync(manifestUri: manifestUri);
    expect(await store.find('logo'), isNotNull);

    final empty = sync(_backend({}, manifest: []));
    final report = await empty.sync(manifestUri: manifestUri);

    expect(report.pruned, ['logo']);
    expect(await store.find('logo'), isNull);
    expect(await File('${dir.path}/logo').exists(), isFalse);
  });
}
