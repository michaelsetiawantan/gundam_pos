import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

// Config cache store — the POS local mirror of server-truth config JSON.
// This is the "atomic temp+rename, version-stamped, old-or-new only" contract
// from `web/lib/config/clientContract.ts` and LOCAL-SCHEMA `config_store`.
// Never a partial/mixed version: write to a same-dir temp, verify, then rename.

class ConfigKey {
  ConfigKey(this.name, {this.version = 0, this.sha256, this.jsonPayload});

  final String name;
  int version;
  String? sha256;
  String? jsonPayload; // raw JSON string

  String stamp() => '$name:v$version';
}

/// In-memory directory-backed cache (injectable for tests). File layout:
/// `<dir>/<name>.json` + `<dir>/<name>.version` + `<dir>/<name>.sha256`.
class ConfigCache {
  ConfigCache(this.dir);

  final Directory dir;

  String sha256Of(Object data) => sha256.convert(utf8.encode(jsonEncode(data))).toString();

  Future<File> _ensure(File f) async {
    await f.parent.create(recursive: true);
    return f;
  }

  File _verFile(String name) => File(p.join(dir.path, '$name.version'));
  File _jsonFile(String name) => File(p.join(dir.path, '$name.json'));
  File _shaFile(String name) => File(p.join(dir.path, '$name.sha256'));

  /// Read the cached payload for a key; null when absent or stale (version
  /// mismatch). The caller falls back to last-known-good for the previous key.
  Future<ConfigKey?> read(String name) async {
    final jf = _jsonFile(name);
    final vf = _verFile(name);
    if (!await jf.exists() || !await vf.exists()) return null;
    final version = int.tryParse(vf.readAsStringSync()) ?? 0;
    final sha = await _readSha(name);
    return ConfigKey(name, version: version, sha256: sha, jsonPayload: await jf.readAsString());
  }

  Future<String?> _readSha(String name) async {
    final f = _shaFile(name);
    if (!await f.exists()) return null;
    return (await f.readAsLines()).first.trim();
  }

  /// Atomic write: temp file in the same dir, then rename over the target.
  /// Old-or-new only; a failed write leaves the previous version untouched.
  Future<ConfigKey> write(ConfigKey key, {required String jsonPayload}) async {
    final jf = await _ensure(_jsonFile(key.name));
    final vf = await _ensure(_verFile(key.name));
    final sf = await _ensure(_shaFile(key.name));
    final sha = sha256.convert(utf8.encode(jsonPayload)).toString();

    final tmp = File(p.join(jf.parent.path, '.${key.name}.${DateTime.now().microsecondsSinceEpoch}.tmp'));
    try {
      await tmp.writeAsString(jsonPayload, flush: true);
      await tmp.rename(jf.path); // atomic within the same filesystem
    } catch (_) {
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
      rethrow;
    }
    await vf.writeAsString('${key.version}');
    await sf.writeAsString(sha);
    return ConfigKey(key.name, version: key.version, sha256: sha, jsonPayload: jsonPayload);
  }

  /// JSON convenience wrapper.
  Future<ConfigKey> writeJson(String name, int version, Object data) =>
      write(ConfigKey(name, version: version), jsonPayload: jsonEncode(data));

  /// Remove a stale key (called when the server reports a lower/zero version).
  Future<void> remove(String name) async {
    for (final f in [_jsonFile(name), _verFile(name), _shaFile(name)]) {
      try {
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
  }
}