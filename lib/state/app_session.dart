import 'dart:math';

import 'package:flutter/foundation.dart';

import 'package:gundam_pos/api/api_client.dart';
import 'package:gundam_pos/api/pos_api.dart';
import 'package:gundam_pos/logic/sync_planner.dart';
import 'package:gundam_pos/models/config_models.dart';
import 'package:gundam_pos/state/session_store.dart';

/// App-level session controller: owns device activation, POS login/
/// single-active handling, the outlet config sync and the logout release.
/// A thin orchestrator — the server enforces the business rules.
enum PosStage { checking, needActivation, login, ready }

class AppSession extends ChangeNotifier {
  AppSession({
    required PosApi posApi,
    required SessionStore sessionStore,
    DateTime Function()? now,
  })  : _posApi = posApi,
        _store = sessionStore,
        _now = now ?? DateTime.now;

  final PosApi _posApi;
  final SessionStore _store;
  final DateTime Function() _now;

  PosContext ctx = const PosContext();
  PosStage stage = PosStage.checking;
  TenantConfig? config;
  Map<String, int> deviceVersions = const {};
  DateTime? lastSyncAt;
  bool syncing = false;

  /// Error surfaced to the current screen (mapped to user copy).
  String? lastError;
  bool busy = false;

  PosContext get context => ctx;
  bool get isReady => stage == PosStage.ready;

  /// Backend + session helpers consumed by the flow screens.
  PosApi get posApi => _posApi;
  String? get tenantId => ctx.tenantId;
  String? get shortcode => ctx.shortcode;

  /// Auth provider for guarded routes — forwards the session cookie the
  /// deployment issues (server guard reads `gundam_auth`), plus the device id.
  AuthHeaders? authHeaders() {
    final cookie = ctx.sessionCookie;
    final extra = <String, String>{if (ctx.deviceId != null) 'x-pos-device': ctx.deviceId!};
    if (cookie == null && extra.isEmpty) return null;
    return AuthHeaders(cookie: cookie, extra: extra);
  }

  Future<void> init() async {
    ctx = await _store.load();
    final dId = ctx.deviceId ?? _generateDeviceId();
    if (ctx.deviceId != dId) {
      ctx = ctx.copyWith(deviceId: dId);
      await _store.save(ctx);
    }
    _stageFromContext();
    notifyListeners();
  }

  void _stageFromContext() {
    if (!ctx.activated) {
      stage = PosStage.needActivation;
    } else if (!ctx.loggedIn) {
      stage = PosStage.login;
    } else {
      stage = PosStage.ready;
    }
  }

  // ------------------------------------------------------------------ redeem --
  Future<bool> redeem(String code, {String? assetLabel}) async {
    _setBusy(clearError: true);
    try {
      final r = await _posApi.redeem(code: code, deviceId: ctx.deviceId!, assetLabel: assetLabel);
      ctx = ctx.withRedeem(r);
      await _store.save(ctx);
      stage = PosStage.login;
      return true;
    } on PosApiException catch (e) {
      lastError = _activationError(e);
      return false;
    } on PosNetworkException {
      lastError = 'Cannot reach the server. Check your connection and try again.';
      return false;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  // ------------------------------------------------------------------ login --
  Future<bool> login({required String email, required String password}) async {
    _setBusy(clearError: true);
    try {
      final r = await _posApi.login(
        email: email,
        password: password,
        deviceToken: ctx.deviceToken!,
        deviceId: ctx.deviceId!,
      );
      ctx = ctx.withSession(r);
      await _store.save(ctx);
      stage = PosStage.ready;
      notifyListeners();
      // Config sync is best-effort; failure must not block the cashier.
      try {
        await refreshConfig();
      } catch (_) {}
      return true;
    } on PosApiException catch (e) {
      lastError = _loginError(e);
      return false;
    } on PosNetworkException {
      lastError = 'Login requires a server connection. Check your network.';
      return false;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  // ----------------------------------------------------------------- logout --
  Future<void> logout() async {
    // Sign-out warns only on unsafe unsynced queue / active payment; open
    // tables are NOT a blocker (server/outlet state, not a cashier block).
    final prior = ctx.sessionId;
    busy = true;
    notifyListeners();
    if (prior != null) {
      try {
        await _posApi.logout();
      } catch (_) {
        // Offline logout needs online to release; best-effort here.
      }
    }
    ctx = ctx.toSessionless(
      userId: null,
      userEmail: null,
      userName: null,
      outletName: null,
    );
    await _store.save(ctx);
    stage = PosStage.login;
    busy = false;
    lastError = null;
    notifyListeners();
  }

  // ---------------------------------------------------------------- config --
  Future<bool> refreshConfig() async {
    if (syncing) return false;
    syncing = true;
    notifyListeners();
    try {
      final tenantId = ctx.tenantId!;
      final state = await _posApi.configState(tenantId);
      final vs = state['versions'] as Map<String, dynamic>? ?? const {};
      final serverVersions = <String, int>{
        for (final e in vs.entries)
          e.key: ((e.value is Map) ? ((e.value as Map)['version'] as num?)?.toInt() ?? 0 : (e.value as num).toInt()),
      };
      final plan = planSync(serverVersions, deviceVersions);
      if (plan.needsFull.isNotEmpty) {
        final sync = await _posApi.configSync(tenantId, deviceVersions);
        final full = sync['full'] as Map<String, dynamic>? ?? const {};
        final master = full['MASTER'] as Map<String, dynamic>? ?? const {};
        final outlet = full['OUTLET'] as Map<String, dynamic>? ?? const {};
        config = TenantConfig.fromSyncPayloads(master, outlet);
        final applied = <String, int>{...deviceVersions};
        for (final d in plan.needsFull) {
          final v = serverVersions[d] ?? 0;
          applied[d] = v;
        }
        deviceVersions = applied;
      }
      lastSyncAt = _now();
      return true;
    } on PosApiException catch (e) {
      lastError = _configError(e);
      return false;
    } on PosNetworkException {
      lastError = 'Config refresh failed — no network.';
      return false;
    } finally {
      syncing = false;
      notifyListeners();
    }
  }

  void _setBusy({bool clearError = false}) {
    busy = true;
    if (clearError) lastError = null;
  }

  static final _rng = Random();
  String _generateDeviceId() {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    return List.generate(16, (_) => chars[_rng.nextInt(chars.length)]).join();
  }

  String _activationError(PosApiException e) {
    switch (e.code) {
      case 'invalid_code':
        return 'Invalid activation code. Please re-check the code.';
      case 'code_expired':
        return 'This activation code has expired. Ask for a new one.';
      case 'code_already_used':
      case 'device_bound_other_group':
        return 'This code was already used or the device is bound to another group.';
      case 'pos_quota_exhausted':
        return 'Your POS asset quota is full. Free a device license first.';
      case 'rate_limited':
        return 'Too many attempts. Wait and try again.';
      default:
        return 'Activation failed (${e.code}).';
    }
  }

  String _loginError(PosApiException e) {
    if (e.isSessionActiveOtherDevice) return 'Session is already active on another device. Ask an admin to release it.';
    if (e.isLicenseLocked) return 'License locked. Renew before continuing to sell.';
    if (e.isDeviceNotActivated) return 'This device is not activated for this outlet.';
    switch (e.code) {
      case 'invalid_credential':
        return 'Incorrect email or password.';
      case 'permission_denied':
        return 'This user cannot access the POS.';
      case 'credential_group_mismatch':
        return 'Device and user belong to different groups.';
      case 'device_revoked':
        return 'This device has been deactivated. Reactivate it.';
      case 'license_locked':
        return 'License locked.';
      case 'rate_limited':
        return 'Too many attempts. Wait and try again.';
      default:
        return 'Login failed (${e.code}).';
    }
  }

  String _configError(PosApiException e) {
    return e.isLicenseLocked ? 'Config refresh blocked by license lock.' : 'Config refresh failed (${e.code})';
  }
}

extension _Sessionless on PosContext {
  PosContext toSessionless({String? userId, String? userEmail, String? userName, String? outletName}) => PosContext(
        deviceId: deviceId,
        deviceToken: deviceToken,
        groupId: groupId,
        tenantId: tenantId,
        shortcode: shortcode,
        sessionId: null,
        userId: userId,
        userEmail: userEmail,
        userName: userName,
        outletId: outletId,
        outletName: outletName,
        sessionCookie: null,
      );
}

/// Convenience: build the real ApiClient + PosApi + secure store wiring used
/// by the app entrypoint. The auth provider reads the live session context so
/// guarded routes are authenticated once login succeeds.
class AppDependencies {
  AppDependencies._();

  static AppSession create({SessionStore? store}) {
    final st = store ?? SecureSessionStore();
    final ref = <AppSession?>[null];
    final client = ApiClient(
      baseUrl: resolveBaseUrl(),
      authProvider: () => ref[0]?.authHeaders(),
    );
    final session = AppSession(posApi: PosApi(client), sessionStore: st);
    ref[0] = session;
    return session;
  }
}