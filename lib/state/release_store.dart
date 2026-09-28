/// Persists the last release manifest the server advertised at
/// `GET /api/pos/version.json`, so the About screen can still show "what's new"
/// after the APK has been replaced in place and the app restarted.
library;

import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'package:gundam_pos/models/app_release.dart';

abstract class ReleaseInfoStore {
  Future<ReleaseInfo?> load();
  Future<void> save(ReleaseInfo release);
}

const _kLastRelease = 'gundam_last_release';

/// Production store — same device secure storage as the session/address state.
class SecureReleaseInfoStore implements ReleaseInfoStore {
  SecureReleaseInfoStore([FlutterSecureStorage? storage]) : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<ReleaseInfo?> load() async {
    final raw = await _storage.read(key: _kLastRelease);
    if (raw == null || raw.isEmpty) return null;
    try {
      return ReleaseInfo.parse(jsonDecode(raw));
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> save(ReleaseInfo release) =>
      _storage.write(key: _kLastRelease, value: jsonEncode(release.toJson()));
}

/// In-memory fake for unit tests.
class InMemoryReleaseInfoStore implements ReleaseInfoStore {
  ReleaseInfo? _value;

  @override
  Future<ReleaseInfo?> load() async => _value;

  @override
  Future<void> save(ReleaseInfo release) async => _value = release;
}
