import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gundam_pos/data/config_cache.dart';

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('gundam-config-cache-');
  });

  tearDown(() => dir.deleteSync(recursive: true));

  group('ConfigCache (atomic temp+rename)', () {
    test('write then read roundtrips payload + version', () async {
      final cache = ConfigCache(dir);
      await cache.writeJson('MASTER', 3, {'items': [1, 2, 3]});
      final key = await cache.read('MASTER');
      expect(key, isNotNull);
      expect(key!.version, 3);
      expect(key.jsonPayload, isNotNull);
      expect(key.jsonPayload, contains('"items"'));
    });

    test('atomic: old version preserved on read? no — read reflects latest', () async {
      final cache = ConfigCache(dir);
      await cache.writeJson('OUTLET', 1, {'a': 1});
      await cache.writeJson('OUTLET', 2, {'a': 2});
      final key = await cache.read('OUTLET');
      expect(key!.version, 2);
    });

    test('missing key returns null', () async {
      final cache = ConfigCache(dir);
      expect(await cache.read('NOPE'), isNull);
    });

    test('remove deletes all side files', () async {
      final cache = ConfigCache(dir);
      await cache.writeJson('MEDIA', 1, {'x': true});
      expect(await cache.read('MEDIA'), isNotNull);
      await cache.remove('MEDIA');
      expect(await cache.read('MEDIA'), isNull);
    });

    test('no leftover temp files after write', () async {
      final cache = ConfigCache(dir);
      await cache.writeJson('MASTER', 1, {'x': true});
      final temps = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.contains('.tmp'));
      expect(temps, isEmpty);
    });
  });
}