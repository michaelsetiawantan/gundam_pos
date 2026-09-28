import 'package:flutter/material.dart';

import 'package:gundam_pos/models/app_release.dart';
import 'package:gundam_pos/services/update_service.dart';
import 'package:gundam_pos/state/app_session.dart';
import 'package:gundam_pos/ui/theme.dart';

/// About / Version — what THIS build is, and the release surface.
///
/// Shows the version name + versionCode (build defines), the running local DB
/// schema version and the server address in use; then the update check against
/// the server's `version.json`, the offered release's CHANGELOG and mandatory
/// flag, and the manual in-place install (download → SHA-256 verify → Android
/// installer via FileProvider). Local data is preserved by the in-place install.
class AboutScreen extends StatefulWidget {
  const AboutScreen({super.key, required this.session, this.installer});

  final AppSession session;

  /// Injectable platform bridge (tests). Defaults to the real Android channel.
  final ApkInstallBridge? installer;

  @override
  State<AboutScreen> createState() => _AboutScreenState();
}

class _AboutScreenState extends State<AboutScreen> {
  bool _installing = false;
  UpdateAttempt? _attempt;

  UpdateService get _update => UpdateService(widget.installer ?? PlatformApkBridge());

  Future<void> _check() async {
    await widget.session.checkForUpdate();
    if (!mounted) return;
    final s = widget.session;
    final msg = s.updateAvailable
        ? 'New version v${s.lastRelease!.version} available.'
        : s.lastUpdateCheckError != null
            ? 'Update check failed silently: ${s.lastUpdateCheckError}'
            : 'No newer release published by the server.';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// Always operator-confirmed: the PRD makes the APK upgrade a manual action
  /// (the server only notifies). Android asks for the final install tap too.
  Future<void> _confirmInstall(ReleaseInfo release) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Install v${release.version}?'),
        content: const Text(
          'The APK downloads to app storage, is verified against the advertised '
          'SHA-256, and is then handed to the Android installer.\n\n'
          'This is an IN-PLACE install: Android keeps the app data directory '
          '(local DB + synced config), so the upgrade is seamless — as long as '
          'every release is signed with the same key. A mismatched SHA-256 is '
          'refused, never installed.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Install now')),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() {
      _installing = true;
      _attempt = null;
    });
    final attempt = await _update.apply(release);
    if (!mounted) return;
    setState(() {
      _installing = false;
      _attempt = attempt;
    });
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(attempt.message)));
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.session;
    final v = s.appVersion;
    final offered = s.lastRelease;
    return Scaffold(
      appBar: AppBar(title: const Text('About / Version')),
      body: SafeArea(
        child: ListenableBuilder(
          listenable: s,
          builder: (_, __) => ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _card(
                title: 'This build',
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('Gundam POS',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: PosTheme.petrol)),
                  const SizedBox(height: 8),
                  _infoRow('Version', v.versionName),
                  _infoRow('Version code', '${v.versionCode}'),
                  if (v.buildSha.isNotEmpty) _infoRow('Build SHA', v.buildSha),
                  if (v.buildTime.isNotEmpty) _infoRow('Build time', v.buildTime),
                  _infoRow('Schema version', '${v.schemaVersion}'),
                  _infoRow('Server address', s.serverAddress),
                  const SizedBox(height: 8),
                  const Text(
                    'Version identity comes from the build (BUILD_VERSION / BUILD_NUMBER / BUILD_SHA / '
                    'BUILD_TIME defines, pubspec fallback). The schema version is the local SQLite '
                    'PRAGMA user_version this APK migrates to idempotently on launch.',
                    style: TextStyle(color: PosTheme.slate, fontSize: 12),
                  ),
                ]),
              ),
              _card(
                title: 'Client update',
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  if (s.updateAvailable && offered != null)
                    UpdateNoticeCard(
                      release: offered,
                      installing: _installing,
                      onInstall: () => _confirmInstall(offered),
                    )
                  else
                    Text(
                      s.lastUpdateCheckError != null
                          ? 'Update check failed (recorded, not shown to the cashier): ${s.lastUpdateCheckError}'
                          : offered == null
                              ? 'The server has no release published (nothing to update).'
                              : 'Up to date with v${offered.version} (server).',
                      style: const TextStyle(color: PosTheme.slate),
                    ),
                  const SizedBox(height: 12),
                  _infoRow('Last checked',
                      s.lastUpdateCheckedAt == null ? 'never' : s.lastUpdateCheckedAt!.toIso8601String().substring(0, 19)),
                  const SizedBox(height: 12),
                  OutlinedButton(
                    onPressed: _installing ? null : _check,
                    child: const Text('Check for update'),
                  ),
                  if (_attempt != null && !_attempt!.ok) ...[
                    const SizedBox(height: 12),
                    _messageBox(_attempt!.message, danger: true),
                  ],
                  const SizedBox(height: 8),
                  const Text(
                    'Checked against GET /api/pos/version.json on login and on config sync. An '
                    'offline tablet stays silent: a failed check is never a blocking error.',
                    style: TextStyle(color: PosTheme.slate, fontSize: 12),
                  ),
                ]),
              ),
              _card(
                title: "What's new",
                child: offered == null
                    ? const Text('No release has been seen from the server yet.',
                        style: TextStyle(color: PosTheme.slate))
                    : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('v${offered.version} (${offered.versionCode})',
                            style: const TextStyle(fontWeight: FontWeight.w800, color: PosTheme.ink)),
                        if (offered.releasedAt != null)
                          _infoRow('Released', offered.releasedAt!.toIso8601String().substring(0, 10)),
                        const SizedBox(height: 8),
                        Text(
                          offered.changelog.isEmpty ? '(The release carries no changelog text.)' : offered.changelog,
                          style: const TextStyle(color: PosTheme.ink, height: 1.35),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          offered.versionCode > v.versionCode
                              ? 'This is the version offered to this tablet.'
                              : 'This is the latest release known to this tablet '
                                  '(shown after an update too, so the changelog stays reachable).',
                          style: const TextStyle(color: PosTheme.slate, fontSize: 12),
                        ),
                      ]),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _infoRow(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: Text(label, style: const TextStyle(color: PosTheme.slate))),
          Flexible(
            child: Text(value, textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.w700)),
          ),
        ]),
      );

  Widget _messageBox(String text, {bool danger = false}) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: (danger ? PosTheme.danger : PosTheme.ok).withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: danger ? PosTheme.danger : PosTheme.ok),
        ),
        child: Text(text, style: TextStyle(color: danger ? PosTheme.danger : PosTheme.petrol, fontWeight: FontWeight.w600)),
      );

  Widget _card({required String title, required Widget child}) => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: PosTheme.line),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w800, color: PosTheme.petrol)),
          const SizedBox(height: 10),
          child,
        ]),
      );
}

/// "New version vX.Y available" — the PRD's notification surface, with the
/// release CHANGELOG and whether the release is mandatory. Shared by More and
/// About so both say exactly the same thing.
class UpdateNoticeCard extends StatelessWidget {
  const UpdateNoticeCard({super.key, required this.release, this.onInstall, this.installing = false});

  final ReleaseInfo release;

  /// Null on a read-only surface (More) that routes the install to About.
  final VoidCallback? onInstall;
  final bool installing;

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: PosTheme.tealSoft,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: PosTheme.petrol),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.system_update_alt, color: PosTheme.petrol, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text('New version v${release.version} available',
                  style: const TextStyle(fontWeight: FontWeight.w800, color: PosTheme.petrol)),
            ),
          ]),
          const SizedBox(height: 6),
          Text(
            release.mandatory
                ? 'MANDATORY release — the server requires this build.'
                : 'Optional release — install at a convenient time.',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: release.mandatory ? PosTheme.danger : PosTheme.slate,
            ),
          ),
          const SizedBox(height: 8),
          Text(release.changelog.isEmpty ? '(No changelog text published.)' : release.changelog,
              style: const TextStyle(color: PosTheme.ink, height: 1.3)),
          const SizedBox(height: 8),
          if (release.installable)
            Text('SHA-256: ${_short(release.sha256!)}', style: const TextStyle(color: PosTheme.slate, fontSize: 12))
          else
            const Text('No apk_url / sha256 published — this release cannot be installed by the tablet yet.',
                style: TextStyle(color: PosTheme.danger, fontSize: 12)),
          if (release.minSupportedConfig != null)
            Text('Requires config v${release.minSupportedConfig}',
                style: const TextStyle(color: PosTheme.slate, fontSize: 12)),
        ]),
      ),
      if (onInstall != null) ...[
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: installing ? null : onInstall,
          icon: installing
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.download),
          label: const Text('Download & install'),
        ),
        const SizedBox(height: 6),
        const Text(
          'In-place install keeps local data (the app data directory survives), so the upgrade is '
          'seamless — the same signing key is required on every release. The SHA-256 is verified '
          'first and a mismatch is refused.',
          style: TextStyle(color: PosTheme.slate, fontSize: 12),
        ),
      ],
    ]);
  }

  static String _short(String sha) => sha.length <= 16 ? sha : '${sha.substring(0, 12)}…';
}
