/// App version identity + the server's release manifest.
///
/// [AppVersion] is what THIS build is; [ReleaseInfo] is what the server
/// advertises at `GET /api/pos/version.json` (PRD 4.33a UPGRADE CLIENT SOP).
library;

/// What this build is: version name + versionCode (from the parent's build
/// defines), the commit/time it was built from, and the local DB schema version.
///
/// The parent passes `--dart-define=BUILD_VERSION/BUILD_NUMBER/BUILD_SHA/
/// BUILD_TIME`; anything it does not pass falls back to the checked-in pubspec
/// version, so the screen is never blank.
///
/// ponytail: no package_info_plus (dependency budget) — the defines are the
/// identity source. Add it when the value must be read back from the installed
/// APK rather than from the build.
class AppVersion {
  const AppVersion({
    required this.versionName,
    required this.versionCode,
    required this.schemaVersion,
    this.buildSha = '',
    this.buildTime = '',
  });

  final String versionName;
  final int versionCode;

  /// Local SQLite schema version of this build (`local_db.schemaVersion`).
  final int schemaVersion;

  /// Git commit the APK was built from, when the parent passed it.
  final String buildSha;

  /// Build timestamp, when the parent passed it.
  final String buildTime;

  // Fallbacks mirror pubspec `version: 0.2.0+2`.
  static const _defVersion = String.fromEnvironment('BUILD_VERSION', defaultValue: '0.2.0');
  static const _defNumber = String.fromEnvironment('BUILD_NUMBER', defaultValue: '2');
  static const _defSha = String.fromEnvironment('BUILD_SHA', defaultValue: '');
  static const _defTime = String.fromEnvironment('BUILD_TIME', defaultValue: '');

  /// The running build's identity.
  factory AppVersion.running({required int schemaVersion}) => AppVersion(
        versionName: _defVersion.trim().isEmpty ? '0.0.0' : _defVersion.trim(),
        versionCode: int.tryParse(_defNumber.trim()) ?? 0,
        schemaVersion: schemaVersion,
        buildSha: _defSha.trim(),
        buildTime: _defTime.trim(),
      );

  String get display => 'v$versionName ($versionCode)';

  @override
  String toString() => 'AppVersion($display, schema=$schemaVersion)';
}

/// A published release as advertised by `GET /api/pos/version.json`:
/// `{version, versionCode, apk_url, sha256, min_supported_config, mandatory,
/// changelog, released_at}`.
///
/// [parse] is deliberately tolerant (snake_case and camelCase keys, numeric
/// versionCode, string booleans, a changelog list) and returns null for the
/// server's honest empty shape — "nothing published" is NOT an update.
class ReleaseInfo {
  const ReleaseInfo({
    required this.version,
    required this.versionCode,
    this.apkUrl,
    this.sha256,
    this.minSupportedConfig,
    this.mandatory = false,
    this.changelog = '',
    this.releasedAt,
  });

  final String version;
  final int versionCode;
  final String? apkUrl;
  final String? sha256;

  /// Config version this release requires (informational).
  final int? minSupportedConfig;
  final bool mandatory;
  final String changelog;
  final DateTime? releasedAt;

  /// A release can only be fetched+verified when it carries both an APK URL and
  /// its advertised SHA-256. Without the hash the install is refused.
  bool get installable => (apkUrl?.trim().isNotEmpty ?? false) && (sha256?.trim().isNotEmpty ?? false);

  bool isNewerThan(int installedVersionCode) => versionCode > installedVersionCode;

  /// Case-insensitive hex comparison against the advertised digest.
  bool sha256Matches(String actual) =>
      expectedSha256 != null && expectedSha256 == actual.trim().toLowerCase();

  String? get expectedSha256 => sha256?.trim().toLowerCase();

  /// Parse one manifest body. Null = no release published / unusable payload
  /// (never throws, never guesses an update).
  static ReleaseInfo? parse(Object? raw) {
    if (raw is! Map) return null;
    final map = <String, Object?>{for (final e in raw.entries) '${e.key}': e.value};
    final version = _str(map['version'] ?? map['version_name'] ?? map['name']);
    final code = _int(map['versionCode'] ?? map['version_code'] ?? map['buildNumber'] ?? map['build_number']);
    if (version.isEmpty || code == null || code <= 0) return null;
    return ReleaseInfo(
      version: version,
      versionCode: code,
      apkUrl: _nullableStr(map['apk_url'] ?? map['apkUrl'] ?? map['url']),
      sha256: _nullableStr(map['sha256'] ?? map['sha_256'] ?? map['hash']),
      minSupportedConfig: _int(map['min_supported_config'] ?? map['minSupportedConfig']),
      mandatory: _bool(map['mandatory']),
      changelog: _text(map['changelog'] ?? map['whats_new'] ?? map['notes']),
      releasedAt: _date(map['released_at'] ?? map['releasedAt']),
    );
  }

  Map<String, dynamic> toJson() => {
        'version': version,
        'versionCode': versionCode,
        if (apkUrl != null) 'apk_url': apkUrl,
        if (sha256 != null) 'sha256': sha256,
        if (minSupportedConfig != null) 'min_supported_config': minSupportedConfig,
        'mandatory': mandatory,
        'changelog': changelog,
        if (releasedAt != null) 'released_at': releasedAt!.toIso8601String(),
      };

  static String _str(Object? v) => v == null ? '' : '$v'.trim();

  static String? _nullableStr(Object? v) {
    final s = _str(v);
    return s.isEmpty ? null : s;
  }

  static int? _int(Object? v) {
    if (v is num) return v.toInt();
    return int.tryParse('$v'.trim());
  }

  static bool _bool(Object? v) {
    if (v is bool) return v;
    final s = '$v'.trim().toLowerCase();
    return s == 'true' || s == '1' || s == 'yes' || s == 'mandatory';
  }

  static String _text(Object? v) {
    if (v == null) return '';
    if (v is List) return v.map(_str).where((s) => s.isNotEmpty).join('\n');
    return '$v'.trim();
  }

  static DateTime? _date(Object? v) {
    if (v is num) return DateTime.fromMillisecondsSinceEpoch(v.toInt());
    if (v is String) return DateTime.tryParse(v.trim());
    return null;
  }
}
