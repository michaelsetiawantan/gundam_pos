/// Tablet-side enforcement of the PRD shift rules: which function is offered
/// (MANUAL vs AUTOMATIC labels) and the AUTOMATIC meal-shift / recap windows.
///
/// The server ships ONLY `shiftType, defaultHouseBank, roundingMode, timezone,
/// currencyLabel` in `OUTLET.shift` (web/lib/config/resync.ts buildFull). It
/// does NOT ship the meal-shift windows or the recap window, so on a real
/// device the AUTOMATIC range is "not configured": we surface that and gate
/// NOTHING (we never guess a range). Tests (and a future payload) supply the
/// window rows and then the gate is live.
library;

import 'package:gundam_pos/models/config_models.dart';

class ShiftGate {
  ShiftGate(this.config, {DateTime Function()? now}) : _now = now ?? DateTime.now;

  final ShiftConfig config;
  final DateTime Function() _now;

  bool get isAutomatic => config.isAutomatic;

  /// The eligible function's exact label (PRD: MANUAL = 'Start Shift' /
  /// 'End Shift'; AUTOMATIC = 'Start Shift Cash Count' /
  /// 'End Shift Cash Count'). The OTHER label is never shown — the POS offers
  /// only the function the configured type allows.
  String get startLabel => isAutomatic ? 'Start Shift Cash Count' : 'Start Shift';
  String get endLabel => isAutomatic ? 'End Shift Cash Count' : 'End Shift';

  bool get windowConfigured => config.mealShiftWindows.isNotEmpty;
  bool get recapConfigured => config.recapWindow != null;

  /// AUTOMATIC but the server shipped no range → visibly "not configured".
  bool get windowNotConfigured => isAutomatic && !windowConfigured;

  String get windowSummary =>
      windowConfigured ? config.mealShiftWindows.map((w) => w.label).join(', ') : 'not configured';

  bool inMealShift(DateTime t) => config.mealShiftWindows.any((w) => w.contains(t));

  bool inRecap(DateTime t) => config.recapWindow?.contains(t) ?? false;

  /// The PRD alert for a pre-midnight hanging order caught in the recap window.
  String get hangingOrderAlert {
    final r = config.recapWindow;
    final ends = r == null ? '' : ' (recap window ${r.label})';
    return 'This order was opened before midnight and is still hanging. It will '
        'NOT be counted as yesterday\'s revenue. Finish it after the recap '
        'window$ends to settle it.';
  }

  /// Message when a NEW transaction may not start, else null. Only AUTOMATIC is
  /// gated, and only when the range is actually configured.
  String? blockNewTransactionAt(DateTime t) {
    if (!isAutomatic || !windowConfigured) return null;
    if (inMealShift(t)) return null;
    return 'Outside meal-shift hours ($windowSummary). No transaction can start now.';
  }

  String? blockNewTransaction() => blockNewTransactionAt(_now());

  /// The recap-window block for a pre-midnight hanging order (else null).
  String? hangingBlockAt(DateTime t, DateTime? openedAt) {
    if (!isAutomatic || openedAt == null) return null;
    if (_crossedMidnight(openedAt, t) && inRecap(t)) return hangingOrderAlert;
    return null;
  }

  /// Message when an existing order may not be PAID now, else null.
  ///
  /// A pre-midnight hanging order is exempt from the meal-shift window: the
  /// PRD lets it be settled AFTER the recap window, and it is no longer a "new"
  /// transaction today. Everything else follows [blockNewTransactionAt].
  String? blockPaymentAt(DateTime t, DateTime? openedAt) {
    final hang = hangingBlockAt(t, openedAt);
    if (hang != null) return hang;
    if (openedAt != null && _crossedMidnight(openedAt, t)) return null;
    return blockNewTransactionAt(t);
  }

  String? blockPayment(DateTime? openedAt) => blockPaymentAt(_now(), openedAt);

  static bool _crossedMidnight(DateTime opened, DateTime t) =>
      opened.year != t.year || opened.month != t.month || opened.day != t.day;
}
