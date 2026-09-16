import 'package:flutter/foundation.dart';

import 'package:gundam_pos/api/api_client.dart';
import 'package:gundam_pos/api/pos_api.dart';

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

  bool get isOpen => shift != null;
  bool get isClosed => closing != null;

  double get openingHousebank => ((shift?['openHousebank'] ?? 0) as num).toDouble();

  Future<bool> open({double? housebank}) async {
    busy = true;
    error = null;
    notifyListeners();
    try {
      final r = await posApi.openShift(tenantId: tenantId, deviceAssetId: deviceAssetId, openHousebank: housebank);
      shift = r['shift'] as Map<String, dynamic>?;
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
    error = null;
    notifyListeners();
  }

  String _msg(String prefix, PosApiException e) => '$prefix (${e.code}).';
}