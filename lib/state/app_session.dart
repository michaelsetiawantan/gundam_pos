import 'dart:math';

import 'package:flutter/foundation.dart';

import 'package:gundam_pos/api/api_client.dart';
import 'package:gundam_pos/api/pos_api.dart';
import 'package:gundam_pos/data/config_cache.dart';
import 'package:gundam_pos/data/local_db.dart';
import 'package:gundam_pos/data/pos_store.dart';
import 'package:gundam_pos/data/print_format_store.dart';
import 'package:gundam_pos/data/print_log_store.dart';
import 'package:gundam_pos/logic/print_payload.dart';
import 'package:gundam_pos/logic/shift_window.dart';
import 'package:gundam_pos/logic/sync_planner.dart';
import 'package:gundam_pos/models/config_models.dart';
import 'package:gundam_pos/models/license_info.dart';
import 'package:gundam_pos/services/bluetooth_print_transport.dart';
import 'package:gundam_pos/services/print_broker.dart';
import 'package:gundam_pos/services/print_dispatcher.dart';
import 'package:gundam_pos/services/print_log.dart';
import 'package:gundam_pos/services/print_routing.dart';
import 'package:gundam_pos/services/printer_health.dart';
import 'package:gundam_pos/services/printer_health_report.dart';
import 'package:gundam_pos/services/usb_print_transport.dart';
import 'package:gundam_pos/state/payment_controller.dart';
import 'package:gundam_pos/state/session_store.dart';
import 'package:gundam_pos/state/shift_controller.dart';
import 'package:path_provider/path_provider.dart';

/// App-level session controller: owns device activation, POS login/
/// single-active handling, the outlet config sync and the logout release.
/// A thin orchestrator — the server enforces the business rules.
enum PosStage { checking, needActivation, login, ready }

class AppSession extends ChangeNotifier {
  AppSession({
    required PosApi posApi,
    required SessionStore sessionStore,
    ServerAddressStore? serverAddressStore,
    ReceiptSequenceStore? receiptSequence,
    PushStore? pushStore,
    DateTime Function()? now,
    PrintTransport? printTransport,
    PrinterHealthReporter? printerHealthReporter,
    PrintLogStore? printLogStore,
  })  : _posApi = posApi,
        _store = sessionStore,
        _addrStore = serverAddressStore ?? InMemoryServerAddressStore(),
        _receipts = ReceiptSequencer(store: receiptSequence ?? MemoryReceiptSequenceStore()),
        _push = pushStore ?? MemoryPushStore(),
        _now = now ?? DateTime.now,
        _printTransport = printTransport ?? _defaultPrintTransport(),
        _healthReporter = printerHealthReporter,
        printLogs = printLogStore ?? MemoryPrintLogStore(now: now);

  final PosApi _posApi;
  final SessionStore _store;
  final ServerAddressStore _addrStore;
  final ReceiptSequencer _receipts;
  final PushStore _push;
  final DateTime Function() _now;
  final PrintTransport _printTransport;

  /// Default real transports: network :9100, Classic Bluetooth SPP, and USB Host
  /// (CDC-ACM/CH340/PL2303/FTDI built into the APK).
  static PrintTransport _defaultPrintTransport() => PrintTransportRouter({
        'NETWORK': const NetworkPrintTransport(),
        'BLUETOOTH': BluetoothPrintTransport(),
        'USB': UsbPrintTransport(),
      });

  final PrinterHealthReporter? _healthReporter;

  /// Probe every active printer and report the honest per-printer status to the
  /// server (`POST /api/pos/printers/health`). Best-effort: never throws, never
  /// blocks a sale; a missing reporter / routing skips the upload.
  Future<bool> reportPrinterHealth() async {
    final reporter = _healthReporter;
    final dispatcher = _printDispatcher;
    final tenantId = ctx.tenantId;
    final assetId = ctx.deviceId;
    if (reporter == null || dispatcher == null || tenantId == null || assetId == null) return false;
    final links = await dispatcher.checkHealth();
    if (links.isEmpty) return false;
    return reporter.report(
      tenantId: tenantId,
      assetId: assetId,
      statusesByPrinterId: {
        for (final e in links.entries) e.key: printerHealthStatusName(e.value.state),
      },
    );
  }

  PosContext ctx = const PosContext();
  PosStage stage = PosStage.checking;

  /// The server address in use RIGHT NOW. Precedence: persisted runtime value
  /// (operator-entered) > build-time `--dart-define=POS_API_BASE` > default.
  /// Every network call resolves against [_posApi.baseUrl], which is kept in
  /// sync with this value.
  String serverAddress = resolveBaseUrl();

  /// Informational: plain `http` on a non-local host means some clients reject
  /// `Secure` session cookies, so a login failure there is expected until the
  /// server side allows it. Never a hard block.
  bool get insecureHttpWarning => isInsecureServerUrl(serverAddress);

  TenantConfig? config;
  Map<String, int> deviceVersions = const {};
  DateTime? lastSyncAt;
  bool syncing = false;

  /// Licence coverage last seen from the server (login + config sync payloads).
  /// Null until the first login response. Never blocks a session — the hard lock
  /// is enforced server-side; this only drives the informational reminder.
  LicenseInfo? license;

  /// Memoised dismissal for the licence reminder. Cleared on login, so a new
  /// licence state / coverage end / day re-arms it.
  String? _dismissedLicenseKey;

  /// Reminder identity: a new state, coverage end or calendar day re-arms it.
  String? get _licenseKey {
    final l = license;
    if (l == null) return null;
    final now = _now();
    return '${l.state}|${l.validTo?.toIso8601String()}|${now.year}-${now.month}-${now.day}';
  }

  /// True when the home screen should show the licence reminder (GRACE always;
  /// ACTIVE only when the shipped dates say it is nearing expiry). Informational
  /// only — dismissing or ignoring it never affects the session.
  bool get showLicenseReminder =>
      license != null &&
      !license!.isLocked &&
      license!.needsReminder() &&
      _dismissedLicenseKey != _licenseKey;

  /// Dismiss the current reminder (memoised for this state/coverage/day).
  void dismissLicenseReminder() {
    _dismissedLicenseKey = _licenseKey;
    notifyListeners();
  }

  /// Outbox for deferred pushes (e.g. offline transactions). The MVP settles
  /// directly against the server; this stays empty but enqueues and drains are
  /// exercised by the sync UI. Backed by [PushStore] (sqflite `pending_sync` on
  /// device) so an offline queue survives restart.
  int get pendingPushCount => _push.count;

  ConfigCache? _configCache;

  /// Published print formats for this outlet (last-known-good). Fed from the
  /// FORMAT config domain on each sync; read by the print path.
  final PrintFormatStore printFormats = PrintFormatStore();

  PrintBroker? _printBroker;
  PrintBroker? get printBroker => _printBroker;

  /// Outlet printer model + routing, parsed from the synced OUTLET payload.
  PrinterRouting? _printRouting;
  PrinterRouting? get printRouting => _printRouting;

  /// The live print path: routing + payload builder + the broker queue. Built
  /// from REAL synced config here, not by a caller.
  PrintDispatcher? _printDispatcher;
  PrintDispatcher? get printDispatcher => _printDispatcher;

  /// Local print-attempt audit (SQLite `print_log` on device). Every attempt —
  /// failure, fallback and success — is recorded here and shipped to the server
  /// as development material.
  final PrintLogStore printLogs;

  late final PrintLogAudit _printAudit = PrintLogAudit(store: printLogs, now: _now);
  late final PrintLogUploader _logUploader = PrintLogUploader(api: _posApi, store: printLogs);

  /// Cached pending-upload count; refreshed by [refreshPrintLogPending] and
  /// after each upload pass. The diagnostics screen shows it honestly.
  int printLogPending = 0;

  Future<int> refreshPrintLogPending() async {
    try {
      printLogPending = await printLogs.pendingUploadCount();
    } catch (_) {
      printLogPending = 0;
    }
    notifyListeners();
    return printLogPending;
  }

  /// Ship pending print logs to the server, then prune uploaded history.
  /// Best-effort and idempotent: offline simply leaves rows pending. Returns
  /// the number of rows accepted this pass.
  Future<int> uploadPrintLogs() async {
    final tenantId = ctx.tenantId;
    final assetId = ctx.deviceId;
    if (tenantId == null || assetId == null) return 0;
    var uploaded = 0;
    try {
      final res = await _logUploader.uploadPending(tenantId: tenantId, assetId: assetId);
      uploaded = res.uploaded;
      await printLogs.pruneUploaded(maxRows: kPrintLogMaxRows, maxAge: kPrintLogMaxAge);
    } catch (_) {
      // keep rows pending for the next pass
    }
    await refreshPrintLogPending();
    return uploaded;
  }

  /// Wire the print path (queue + transport) once the device printer is known.
  void attachPrintBroker(PrintBroker broker) {
    _printBroker = broker;
    _ensurePrintPath();
  }

  /// (Re)build the broker + dispatcher from the current routing + config.
  void _ensurePrintPath() {
    final routing = _printRouting;
    if (routing == null) return;
    final broker = _printBroker ?? PrintBroker(store: printFormats, queue: PrintQueue(transport: _printTransport));
    _printBroker = broker;
    final base = TicketContext(
      storeName: ctx.outletName ?? '',
      cashier: ctx.userName ?? '',
      deviceShortcode: ctx.shortcode ?? '',
      currencyLabel: config?.shift.currencyLabel ?? '',
      timezone: config?.shift.timezone ?? '',
    );
    final d = _printDispatcher;
    if (d == null || d.broker != broker) {
      _printDispatcher = PrintDispatcher(broker: broker, routing: routing, context: base, logs: _printAudit);
    } else {
      d.routing = routing;
      d.context = base;
      d.logs = _printAudit;
    }
  }

  /// Shared, persisted (device-side) receipt sequencer for the settle flow.
  ReceiptSequencer get receipts => _receipts;

  ShiftController? _shiftController;

  /// The app-wide [ShiftController] — ONE instance for the whole app, so the
  /// running shift's PINNED config ('config change applies next day') covers
  /// every screen, not just the shift screen. Created lazily on first use.
  ShiftController get shiftController =>
      _shiftController ??= ShiftController(
        posApi: _posApi,
        tenantId: ctx.tenantId!,
        deviceAssetId: ctx.deviceId,
      );

  /// The effective shift gate for [live] config: the running shift's pinned
  /// rules when a shift is open, else the live synced config. [now] is a test
  /// seam (defaults to the wall clock).
  ShiftGate gateFor(TenantConfig live, {DateTime Function()? now}) =>
      ShiftGate(shiftController.effectiveConfig(live.shift), now: now);

  void attachConfigCache(ConfigCache cache) => _configCache = cache;

  Future<void> enqueuePush(String entityType, String entityId, Object payload) async {
    await _push.enqueue(entityType, entityId, payload);
    notifyListeners();
  }

  /// Drain the outbox (mark acked). Idempotent; the queue is cleared on ack.
  Future<void> drainPush() async {
    await _push.drain();
    notifyListeners();
  }

  /// Same-day settled bills recorded on this device (POS shows today only).
  final List<Map<String, dynamic>> todayBills = [];

  void noteSettled(Map<String, dynamic>? bill) {
    if (bill == null) return;
    todayBills.insert(0, bill);
    notifyListeners();
  }

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
    // Apply the persisted runtime server address (if any) before any call.
    serverAddress = resolveBaseUrl(runtime: await _addrStore.load());
    _posApi.baseUrl = serverAddress;
    _stageFromContext();
    notifyListeners();
  }

  /// Normalise, probe, then persist + apply an operator-entered server address.
  /// The address is only stored/used when the probe confirms a reachable
  /// Gundam service — a failed probe NEVER wipes an already-working address.
  /// Returns the honest probe result for the UI to display.
  Future<ServerProbeResult> setServerAddress(String input, {ServerProbe? probe}) async {
    final normalized = normalizeServerAddress(input);
    if (normalized == null) {
      return const ServerProbeResult(ServerProbeState.invalid);
    }
    final result = await (probe ?? ServerProbe()).probe(normalized);
    if (!result.ok) return result;
    serverAddress = normalized;
    _posApi.baseUrl = normalized;
    await _addrStore.save(normalized);
    notifyListeners();
    return result;
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
      // Licence coverage for the post-login reminder. A fresh login re-arms it.
      license = LicenseInfo.fromJson(r['license']) ?? license;
      _dismissedLicenseKey = null;
      await _store.save(ctx);
      stage = PosStage.ready;
      notifyListeners();
      // Config sync is best-effort; failure must not block the cashier.
      try {
        await refreshConfig();
      } catch (_) {}
      // Report printer health after config lands (PRD: check at login). Best-effort.
      try {
        await reportPrinterHealth();
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
        // Refresh the licence block so the reminder can re-arm on renewal or a
        // state change without a re-login (additive; absent → keep last known).
        license = LicenseInfo.fromJson(sync['license']) ?? license;
        final full = sync['full'] as Map<String, dynamic>? ?? const {};
        final master = full['MASTER'] as Map<String, dynamic>? ?? const {};
        final outlet = full['OUTLET'] as Map<String, dynamic>? ?? const {};
        config = TenantConfig.fromSyncPayloads(master, outlet);
        // Outlet printer model + routing (tolerant; never throws). The print
        // path is rebuilt from this real synced config.
        _printRouting = PrinterRouting.parse(outlet);
        _ensurePrintPath();
        // Published print formats ride the FORMAT domain; applied defensively
        // (a bad payload keeps last-known-good and the built-in fallback holds).
        final formatDomain = full['FORMAT'];
        if (formatDomain != null) {
          printFormats.apply(formatDomain, version: serverVersions['FORMAT'] ?? 0);
        }
        final applied = <String, int>{...deviceVersions};
        for (final d in plan.needsFull) {
          final v = serverVersions[d] ?? 0;
          applied[d] = v;
        }
        deviceVersions = applied;
        // Persist per-domain atomically (temp+rename); a failed write keeps the
        // previous (last-known-good) file and never leaves a mixed version.
        final cache = _configCache;
        if (cache != null) {
          for (final d in plan.needsFull) {
            final payload = full[d];
            if (payload != null) {
              try {
                await cache.writeJson(d, serverVersions[d] ?? 0, payload);
              } catch (_) {/* keep last-known-good */}}
          }
        }
      }
      lastSyncAt = _now();
      // Best-effort: ship any locally-recorded print attempts (additive).
      await uploadPrintLogs();
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

  static AppSession create({SessionStore? store, ServerAddressStore? addressStore}) {
    final st = store ?? SecureSessionStore();
    final ref = <AppSession?>[null];
    final client = ApiClient(
      baseUrl: resolveBaseUrl(),
      authProvider: () => ref[0]?.authHeaders(),
    );
    // Persist receipt sequencing + the push outbox to SQLite so they survive
    // restart. The device path comes from the platform support dir; when that
    // is unavailable (CI/test host) it degrades to an in-memory DB.
    final posStore = SqlitePosStore(
      localDb: LocalDb(),
      pathProvider: () async {
        final dir = await getApplicationSupportDirectory();
        return '${dir.path}/gundam_pos/gundam.db';
      },
    );
    // Local print-attempt audit persists to the same device DB file.
    final printLogStore = SqlitePrintLogStore(
      localDb: LocalDb(),
      pathProvider: () async {
        final dir = await getApplicationSupportDirectory();
        return '${dir.path}/gundam_pos/gundam.db';
      },
    );
    final session = AppSession(
      posApi: PosApi(client),
      sessionStore: st,
      serverAddressStore: addressStore ?? SecureServerAddressStore(),
      receiptSequence: posStore,
      pushStore: posStore,
      printLogStore: printLogStore,
      printerHealthReporter: PrinterHealthReporter(client: client),
    );
    ref[0] = session;
    return session;
  }
}