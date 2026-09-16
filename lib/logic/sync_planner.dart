/// Client mirror of `web/lib/config/version.ts` planSync — decides which config
/// domains need a FULL re-sync when the applied version mismatches the server.
library;

const List<String> configDomains = ['MASTER', 'OUTLET', 'FORMAT', 'MEDIA'];

class SyncPlan {
  SyncPlan({required this.needsFull, required this.upToDate});

  final List<String> needsFull;
  final List<String> upToDate;
}

/// Version match → no pull; missing or stale → full resync of that domain.
SyncPlan planSync(
  Map<String, int> serverVersions,
  Map<String, num>? clientVersions,
) {
  clientVersions ??= const {};
  final needsFull = <String>[];
  final upToDate = <String>[];
  for (final domain in configDomains) {
    final serverV = serverVersions[domain] ?? 0;
    final clientV = (clientVersions[domain] ?? 0).toInt();
    if (clientV == serverV) {
      upToDate.add(domain);
    } else {
      needsFull.add(domain);
    }
  }
  return SyncPlan(needsFull: needsFull, upToDate: upToDate);
}