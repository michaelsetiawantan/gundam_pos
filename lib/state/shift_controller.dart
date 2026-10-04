import 'package:flutter/foundation.dart';

import 'package:gundam_pos/api/api_client.dart';
import 'package:gundam_pos/api/pos_api.dart';
import 'package:gundam_pos/models/config_models.dart';

/// Drives the cashier shift: open (TOTAL-ONLY cash count / housebank) and
/// close (+ variance / closing summary). Fully synced to the server; the
/// closing report aggregates from the server ledger (never live-POS).
class ShiftController extends ChangeNotifier {
  ShiftController({required this.posApi, required this.tenantId, this.deviceAssetId});

  final PosApi posApi;
  final String tenantId;
  final String? deviceAssetId;

  Map<String, dynamic>? shift; // the opened shift
  Map<String, dynamic>? closing; // the closing report once closed
  bool busy = false;
  String? error;

  /// The opening cash count the operator TYPED for the running shift. Kept on
  /// the controller (not the screen's disposable TextEditingController) so the
  /// typed value survives a shift-screen rebuild and is the value the shift was
  /// opened with. Seeded from the server shift on [restore].
  double? startHousebank;

  /// The shift RULES the running shift started with. A config change only
  /// applies to clients on the NEXT day — a running shift never switches
  /// mid-shift (PRD 'Config meal-shift berubah → apply HARI BERIKUTNYA').
  ShiftConfig? startedConfig;

  bool get isOpen => shift != null;
  bool get isClosed => closing != null;

  double get openingHousebank => _asNum(shift?['openHousebank']) ?? 0;

  /// The config the running shift runs on: pinned to what it started with,
  /// otherwise the live synced config.
  ShiftConfig effectiveConfig(ShiftConfig live) =>
      isOpen && startedConfig != null ? startedConfig! : live;

  /// True when the freshly synced config differs from the running shift's —
  /// the new rules apply only on the next day/shift.
  bool configChangedSinceStart(ShiftConfig live) {
    final started = startedConfig;
    return isOpen && started != null && !started.sameRules(live);
  }

  Future<bool> open({double? housebank, ShiftConfig? config}) async {
    busy = true;
    error = null;
    notifyListeners();
    try {
      final r = await posApi.openShift(tenantId: tenantId, deviceAssetId: deviceAssetId, openHousebank: housebank);
      shift = r['shift'] as Map<String, dynamic>?;
      if (shift != null) {
        startedConfig = config;
        // Remember the cash the operator actually counted (the value the shift
        // was opened with), independent of the screen's text controller.
        if (housebank != null) startHousebank = housebank;
      }
      return shift != null;
    } on PosApiException catch (e) {
      error = posErrorText('Could not start the shift', e.code, status: e.status);
      return false;
    } on PosNetworkException {
      error = 'No network — cannot start the shift.';
      return false;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// Recover a shift that is already OPEN on the server (called after login /
  /// config sync and when the shift screen opens) so a reopened app knows the
  /// shift is running. The server returns only OPEN shifts, so a CLOSED /
  /// AUTO_CLOSED shift can never reappear as active. Offline or an unexpected
  /// error keeps the last known state — never a false "shift not started".
  Future<void> restore() async {
    try {
      final r = await posApi.activeShift(tenantId: tenantId);
      final s = r['shift'];
      shift = s is Map<String, dynamic> ? s : null;
      error = null;
      if (shift != null) startHousebank = _asNum(shift!['openHousebank']) ?? startHousebank;
    } on PosApiException {
      // A resolved-but-not-returned shift (404/409): no active shift for us.
      shift = null;
    } on PosNetworkException {
      // Offline — keep the in-memory state (do not clear a known-open shift).
    }
    notifyListeners();
  }

  /// Build the close request body for a mode. Pure → unit-testable:
  /// - ONLY_CASH stays the LEGACY shape `{countedTotal}` (server defaults to it).
  /// - CASH_CASHLESS → `{mode, cash, cashless}`.
  /// - CROSSCHECK_PER_METHOD → `{mode, perMethod:[{outletMethodId, counted}]}`.
  static Map<String, dynamic> buildClosePayload(
    EndCountMode mode, {
    double? countedTotal,
    double? cash,
    double? cashless,
    List<Map<String, dynamic>>? perMethod,
  }) {
    switch (mode) {
      case EndCountMode.cashCashless:
        return {'mode': 'CASH_CASHLESS', 'cash': cash ?? 0, 'cashless': cashless ?? 0};
      case EndCountMode.crosscheckPerMethod:
        return {'mode': 'CROSSCHECK_PER_METHOD', 'perMethod': perMethod ?? const []};
      case EndCountMode.onlyCash:
        return {'countedTotal': countedTotal ?? 0};
    }
  }

  /// Close the shift with the END SHIFT mode's counted figures. Only the fields
  /// the mode needs are sent; unknown mode falls back to ONLY_CASH.
  Future<bool> close({
    EndCountMode mode = EndCountMode.onlyCash,
    double? countedTotal,
    double? cash,
    double? cashless,
    List<Map<String, dynamic>>? perMethod,
  }) async {
    if (shift == null) return false;
    busy = true;
    error = null;
    notifyListeners();
    try {
      final body = buildClosePayload(mode, countedTotal: countedTotal, cash: cash, cashless: cashless, perMethod: perMethod);
      final r = await posApi.closeShift(shiftId: (shift!['id'] as String), body: body, deviceAssetId: deviceAssetId);
      closing = r['closing'] as Map<String, dynamic>?;
      return closing != null;
    } on PosApiException catch (e) {
      error = posErrorText('Could not close the shift', e.code, status: e.status);
      return false;
    } on PosNetworkException {
      error = 'No network — shift not closed.';
      return false;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  void reset() {
    shift = null;
    closing = null;
    startedConfig = null;
    startHousebank = null;
    error = null;
    notifyListeners();
  }

}
/// Prisma Decimals serialise as JSON STRINGS ("500000") — never hard-cast one.
/// The same class of bug crashed `addItem` (a `as num?` on a string Decimal) and
/// left the cart panel empty until a manual refresh.
double? _asNum(Object? v) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v);
  return null;
}
