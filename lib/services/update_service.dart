/// In-place APK upgrade (PRD 4.33a Upgrade Client SOP).
///
/// The whole decision sequence — download, SHA-256 verify, refuse on mismatch,
/// then hand the file to Android's installer — lives here in pure Dart so it is
/// unit-tested. Only the platform half ([ApkInstallBridge.install]: presenting
/// the installer for a FileProvider content URI) is device-verified.
library;

import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:gundam_pos/models/app_release.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Platform seam for the two device-only steps: fetching the APK bytes and
/// asking Android to install a staged file. The production implementation is
/// [PlatformApkBridge]; tests inject a fake.
abstract class ApkInstallBridge {
  /// Fetch the APK bytes from the advertised URL (HTTPS).
  Future<List<int>> download(String url);

  /// App storage directory the APK is staged in.
  Future<String> apkDirectory();

  /// Hand the APK at [path] to the Android package installer. Returns an
  /// operator-readable detail; throws when the installer could not be opened.
  Future<String> install(String path);
}

enum UpdateOutcome { installed, shaMismatch, unavailable, failed }

/// Result of one install attempt. [message] is operator-facing copy.
class UpdateAttempt {
  const UpdateAttempt(this.outcome, {this.detail});

  final UpdateOutcome outcome;
  final String? detail;

  bool get ok => outcome == UpdateOutcome.installed;

  String get message => switch (outcome) {
        UpdateOutcome.installed =>
          'Installer opened — confirm the in-place update. Local data is kept.',
        UpdateOutcome.shaMismatch =>
          'SHA-256 mismatch — install REFUSED (release integrity check failed). $detail',
        UpdateOutcome.unavailable => 'Cannot install this release: $detail',
        UpdateOutcome.failed => 'Update failed — $detail',
      };

  @override
  String toString() => 'UpdateAttempt($outcome${detail == null ? '' : ', $detail'})';
}

/// Download → verify SHA-256 → install. The APK is verified BEFORE it is
/// written to app storage and NEVER installed on a digest mismatch.
class UpdateService {
  UpdateService(this.bridge);

  final ApkInstallBridge bridge;

  Future<UpdateAttempt> apply(ReleaseInfo release) async {
    if (!release.installable) {
      return const UpdateAttempt(UpdateOutcome.unavailable,
          detail: 'the release has no apk_url or sha256 to verify against');
    }
    final expected = release.expectedSha256!;

    final List<int> bytes;
    try {
      bytes = await bridge.download(release.apkUrl!);
    } catch (e) {
      return UpdateAttempt(UpdateOutcome.failed, detail: 'download failed: $e');
    }

    final actual = sha256.convert(bytes).toString();
    if (actual != expected) {
      return UpdateAttempt(UpdateOutcome.shaMismatch, detail: 'expected $expected, got $actual');
    }

    // Verified only from here on: stage it, then ask Android to install.
    try {
      final dir = await bridge.apkDirectory();
      Directory(dir).createSync(recursive: true);
      final target = p.join(dir, 'gundam-pos-v${release.version}.apk');
      await File(target).writeAsBytes(bytes, flush: true);
      final detail = await bridge.install(target);
      return UpdateAttempt(UpdateOutcome.installed, detail: detail);
    } catch (e) {
      return UpdateAttempt(UpdateOutcome.failed, detail: '$e');
    }
  }
}

/// Production bridge: dart:io over `http` for the download, app storage for the
/// staged file, and the `gundam/update` MethodChannel (FileProvider content URI)
/// for the install intent.
class PlatformApkBridge implements ApkInstallBridge {
  PlatformApkBridge({http.Client? httpClient, MethodChannel? channel, Future<String> Function()? directory})
      : _http = httpClient ?? http.Client(),
        _channel = channel ?? const MethodChannel(kUpdateChannel),
        _directory = directory;

  static const kUpdateChannel = 'gundam/update';

  final http.Client _http;
  final MethodChannel _channel;
  final Future<String> Function()? _directory;

  @override
  Future<List<int>> download(String url) async {
    final res = await _http.get(Uri.parse(url));
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw HttpException('HTTP ${res.statusCode} for $url');
    }
    return res.bodyBytes;
  }

  @override
  Future<String> apkDirectory() async {
    if (_directory != null) return _directory();
    final dir = await getApplicationSupportDirectory();
    return p.join(dir.path, 'apk');
  }

  @override
  Future<String> install(String path) async {
    final res = await _channel.invokeMapMethod<String, dynamic>('installApk', {'path': path});
    final state = '${res?['state'] ?? 'unsupported'}';
    final detail = '${res?['detail'] ?? path}';
    if (state != 'ready') throw StateError(detail);
    return detail;
  }
}
