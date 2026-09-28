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

  /// The shift RULES the running shift started with. A config change only
  /// applies to clients on the NEXT day — a running shift never switches
  /// mid-shift (PRD 'Config meal-shift berubah → apply HARI BERIKUTNYA').
  ShiftConfig? startedConfig;

  bool get isOpen => shift != null;
  bool get isClosed => closing != null;

  double get openingHousebank => ((shift?['openHousebank'] ?? 0) as num).toDouble();

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
      if (shift != null) startedConfig = config;
      return shift != null;
    } on PosApiException catch (e) {
      error = _msg('Could not start the shift', e);
      return false;
    } on PosNetworkException {
      error = 'No network — cannot start the shift.';
      return false;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<bool> close({required double countedTotal}) async {
    if (shift == null) return false;
    busy = true;
    error = null;
    notifyListeners();
    try {
      final r = await posApi.closeShift(shiftId: (shift!['id'] as String), countedTotal: countedTotal, deviceAssetId: deviceAssetId);
      closing = r['closing'] as Map<String, dynamic>?;
      return closing != null;
    } on PosApiException catch (e) {
      error = _msg('Could not close the shift', e);
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
    error = null;
    notifyListeners();
  }

  String _msg(String prefix, PosApiException e) => '$prefix (${e.code}).';
}