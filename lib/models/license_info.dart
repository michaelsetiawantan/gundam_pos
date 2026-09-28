import 'package:flutter/foundation.dart';

/// The licence coverage the server ships with the POS login / config sync
/// payloads (`license` block). ADDITIVE over the original `{state, grace}`.
///
/// States: ACTIVE / GRACE / LOCKED / NO_LICENSE. A LOCKED or NO_LICENSE login is
/// refused with 403 on the server, so a live session only ever sees ACTIVE or
/// GRACE — the reminder here is informational and never blocks the cashier.
@immutable
class LicenseInfo {
  const LicenseInfo({
    required this.state,
    this.validFrom,
    this.validTo,
    this.graceStart,
    this.graceDays,
    this.graceEndsAt,
  });

  /// ACTIVE | GRACE | LOCKED | NO_LICENSE.
  final String state;

  /// Official coverage start.
  final DateTime? validFrom;

  /// Official coverage end — the grace window opens right after this.
  final DateTime? validTo;

  /// Grace window start.
  final DateTime? graceStart;

  /// Configured grace length in days.
  final int? graceDays;

  /// End of the grace window — the hard cutoff that blocks POS sales.
  final DateTime? graceEndsAt;

  bool get isGrace => state == 'GRACE';
  bool get isLocked => state == 'LOCKED' || state == 'NO_LICENSE';

  /// A licence is "approaching expiry" when it is still ACTIVE but the official
  /// coverage end is within [window] (default 14 days). ACTIVE implies validTo
  /// is in the future, so no lower bound is needed.
  bool approachingExpiry([Duration window = const Duration(days: 14)]) {
    if (state != 'ACTIVE' || validTo == null) return false;
    return validTo!.difference(DateTime.now()) <= window;
  }

  /// Whether the reminder should show at all (GRACE always; ACTIVE only when
  /// the shipped dates say it is nearing expiry).
  bool needsReminder() => isGrace || approachingExpiry();

  static DateTime? _date(Object? v) =>
      v is String ? DateTime.tryParse(v)?.toLocal() : null;

  /// Parse the server `license` block. Returns null when absent/unusable, so the
  /// caller never blocks on a malformed reminder payload.
  static LicenseInfo? fromJson(Object? json) {
    if (json is! Map) return null;
    final state = json['state'];
    if (state is! String || state.isEmpty) return null;
    return LicenseInfo(
      state: state,
      validFrom: _date(json['validFrom']),
      validTo: _date(json['validTo']),
      graceStart: _date(json['graceStart']),
      graceDays: (json['graceDays'] as num?)?.toInt(),
      graceEndsAt: _date(json['graceEndsAt']),
    );
  }
}