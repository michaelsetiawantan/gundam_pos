import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'package:gundam_pos/api/api_client.dart';
import 'package:gundam_pos/api/pos_api.dart';
import 'package:gundam_pos/data/config_cache.dart';
import 'package:gundam_pos/data/local_db.dart';
import 'package:gundam_pos/data/media_cache_store.dart';
import 'package:gundam_pos/data/pos_store.dart';
import 'package:gundam_pos/data/print_format_store.dart';
import 'package:gundam_pos/data/print_log_store.dart';
import 'package:gundam_pos/logic/order_number.dart';
import 'package:gundam_pos/logic/print_payload.dart';
import 'package:gundam_pos/logic/shift_window.dart';
import 'package:gundam_pos/logic/sync_planner.dart';
import 'package:gundam_pos/models/app_release.dart';
import 'package:gundam_pos/models/config_models.dart';
import 'package:gundam_pos/models/license_info.dart';
import 'package:gundam_pos/services/bluetooth_print_transport.dart';
import 'package:gundam_pos/services/diagnostic_report.dart';
import 'package:gundam_pos/services/media_sync.dart';
import 'package:gundam_pos/services/print_broker.dart';
import 'package:gundam_pos/services/print_dispatcher.dart';
import 'package:gundam_pos/services/print_image.dart';
import 'package:gundam_pos/services/print_log.dart';
import 'package:gundam_pos/services/print_routing.dart';
import 'package:gundam_pos/services/printer_health.dart';
import 'package:gundam_pos/services/printer_health_report.dart';
import 'package:gundam_pos/services/update_service.dart';
import 'package:gundam_pos/services/usb_print_transport.dart';
import 'package:gundam_pos/state/order_controller.dart';
import 'package:gundam_pos/state/payment_controller.dart';
import 'package:gundam_pos/state/release_store.dart';
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
    ReleaseInfoStore? releaseStore,
    ReceiptSequenceStore? receiptSequence,
    PushStore? pushStore,
    DateTime Function()? now,
    PrintTransport? printTransport,
    PrinterHealthReporter? printerHealthReporter,
    PrintLogStore? printLogStore,
    DiagnosticLog? diagLog,
  })  : _posApi = posApi,
        _store = sessionStore,
        _addrStore = serverAddressStore ?? InMemoryServerAddressStore(),
        _releaseStore = releaseStore ?? InMemoryReleaseInfoStore(),
        _receiptStore = receiptSequence ?? MemoryReceiptSequenceStore(),
        _push = pushStore ?? MemoryPushStore(),
        _now = now ?? DateTime.now,
        _printTransport = printTransport ?? _defaultPrintTransport(),
        _healthReporter = printerHealthReporter,
        diagnostics = diagLog ?? diagnosticLog,
        printLogs = printLogStore ?? MemoryPrintLogStore(now: now) {
    // Record EVERY failed request into the diagnostic log — the operator sees a
    // message once, but the bundle carries the trail to the server.
    _posApi.onApiError = _recordApiError;
  }

  final PosApi _posApi;
  final SessionStore _store;
  final ServerAddressStore _addrStore;
  final ReleaseInfoStore _releaseStore;

  /// Device-persisted receipt/order sequence store — shared by [receipts] and
  /// [orderNumbers] so the daily counter is one monotonic series per device.
  final ReceiptSequenceStore _receiptStore;
  late final ReceiptSequencer _receipts = ReceiptSequencer(store: _receiptStore, now: _now);

  /// Client-born order numbers for offline order creation
  /// (`[shortcode]-[YYYYMMDD]-[HHMM]-[NNNNNN]`) — unique per POS, monotonic.
  late final OrderNumberGenerator orderNumbers = OrderNumberGenerator(store: _receiptStore, now: _now);

  final PushStore _push;
  final DateTime Function() _now;
  final PrintTransport _printTransport;

  /// Default real transports: network :9100, Classic Bluetooth SPP, and USB Host
  /// (CDC-ACM/CH340/PL2303/FTDI built into the APK). [imageSourceProvider] is
  /// read at SEND time so the media cache can be attached after construction.
  static PrintTransport _defaultPrintTransport({
    PrintImageSource? Function()? imageSourceProvider,
  }) =>
      PrintTransportRouter({
        'NETWORK': NetworkPrintTransport(imageSourceProvider: imageSourceProvider),
        'BLUETOOTH': BluetoothPrintTransport(imageSourceProvider: imageSourceProvider),
        'USB': UsbPrintTransport(imageSourceProvider: imageSourceProvider),
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

  // ---------------------------------------------------- client version/update -
  /// This build's identity (version name + versionCode + local DB schema).
  final AppVersion appVersion = AppVersion.running(schemaVersion: schemaVersion);

  /// Last release manifest the server advertised (persisted across restarts) —
  /// drives "what's new" on the About screen. Null = never seen.
  ReleaseInfo? lastRelease;

  /// Set only by the most recent SUCCESSFUL check: a newer releaseCode than this
  /// build. An unpublished release or a failed fetch never arms it (no nagging).
  bool updateOffered = false;

  DateTime? lastUpdateCheckedAt;

  /// Honest record of the last fetch failure (offline, 404, malformed). Never
  /// surfaced as a blocking error — the cashier must not notice a dead network.
  String? lastUpdateCheckError;

  bool get updateAvailable => updateOffered && lastRelease != null && lastRelease!.versionCode > appVersion.versionCode;

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

  /// The durable outbox itself — handed to [OrderController] so offline line
  /// adds survive a restart and flush when the network returns.
  PushStore get pushStore => _push;

  /// Cross-controller batch metadata per order id. A merge/split hands an order
  /// to a NEW [OrderController]; sharing this tracker keeps the captain batch
  /// sequence (label + count) continuous instead of restarting at A.
  final BatchTracker batchTracker = BatchTracker();

  /// Cached count of order items (`order_create` + `order_line`) waiting in the
  /// outbox. Refreshed by [flushOrderQueue]; shown honestly.
  int orderQueuePending = 0;

  /// Flush the order outbox against the server, in the ONLY correct order:
  /// every `order_create` FIRST (FIFO), then the `order_line` adds of orders
  /// whose create already succeeded. A line whose order has not been created yet
  /// (its `order_create` is still queued) is SKIPPED and left in the queue — it
  /// is never sent against a nonexistent order. Network failure → stop and leave
  /// the queue. Server rejection → drop that item and record it in [diagnostics]
  /// so a poison payload can never wedge the queue forever.
  /// Returns the number of items accepted (creates + lines).
  Future<int> flushOrderQueue() async {
    var sent = 0;
    try {
      final items = await _push.pending();
      final creates = [for (final it in items) if (it['type'] == 'order_create') it];
      final lines = [for (final it in items) if (it['type'] == 'order_line') it];
      final sendCount = [for (final it in items) if (it['type'] == 'order_send') it].length;
      orderQueuePending = creates.length + lines.length + sendCount;

      // Orders whose create is still pending — their lines must wait.
      final needCreate = <String>{
        for (final it in creates)
          if (it['payload_json'] is Map && (it['payload_json'] as Map)['orderId'] != null)
            '${(it['payload_json'] as Map)['orderId']}'
          else
            '${it['id']}',
      };

      // 1. Create the orders (FIFO).
      for (final it in creates) {
        final id = '${it['id']}';
        final payload = it['payload_json'];
        if (payload is! Map) {
          await _push.remove('order_create', id);
          needCreate.remove(id);
          orderQueuePending--;
          continue;
        }
        final p = payload.cast<String, dynamic>();
        final orderId = (p['orderId'] as String?) ?? id;
        try {
          await _posApi.createOrder(
            tenantId: (p['tenantId'] as String?) ?? ctx.tenantId!,
            clientOrderId: orderId,
            tableId: p['tableId'] as String?,
            tableName: p['tableName'] as String?,
            guest: (p['guest'] as Map?)?.cast<String, dynamic>(),
          );
          await _push.remove('order_create', id);
          needCreate.remove(orderId);
          needCreate.remove(id);
          orderQueuePending--;
          sent++;
        } on PosNetworkException {
          break; // offline — stop; lines of uncreated orders stay queued
        } on PosApiException catch (e) {
          await _push.remove('order_create', id);
          needCreate.remove(orderId);
          needCreate.remove(id);
          orderQueuePending--;
          diagnostics.error('order-queue', 'rejected create for order $orderId: ${e.code}');
        }
      }

      // 2. Add the lines of orders that now exist on the server.
      for (final it in lines) {
        final id = '${it['id']}';
        final payload = it['payload_json'];
        if (payload is! Map) {
          await _push.remove('order_line', id);
          orderQueuePending--;
          continue;
        }
        final p = payload.cast<String, dynamic>();
        final orderId = p['orderId'] as String?;
        if (orderId == null || orderId.isEmpty) {
          await _push.remove('order_line', id);
          orderQueuePending--;
          continue;
        }
        if (needCreate.contains(orderId)) continue; // order not created yet — leave queued
        try {
          await _posApi.addLine(orderId, body: {
            'itemId': p['itemId'],
            'priceLevelIndex': p['priceLevelIndex'] ?? 0,
            'qty': p['qty'] ?? 1,
            'mods': p['mods'] ?? const [],
          });
          await _push.remove('order_line', id);
          orderQueuePending--;
          sent++;
        } on PosNetworkException {
          break; // offline — keep the rest queued
        } on PosApiException catch (e) {
          await _push.remove('order_line', id);
          orderQueuePending--;
          diagnostics.error('order-queue', 'rejected line for order $orderId: ${e.code}');
        }
      }

      // 3. Reconcile the send-cart for orders that are fully on the server
      // (create + every line accepted). Anything still queued for that order
      // (create / line) means the server does not have the full bill yet, so its
      // send is left queued — never sent against a half-created order.
      final sends = [for (final it in items) if (it['type'] == 'order_send') it];
      if (sends.isNotEmpty) {
        final stillQueued = await _push.pending();
        for (final it in stillQueued) {
          final t = it['type'];
          if (t != 'order_line' && t != 'order_create') continue;
          final p = it['payload_json'];
          if (p is Map) {
            final oid = (p['orderId'] ?? it['id'])?.toString();
            if (oid != null) needCreate.add(oid);
          }
        }
        for (final it in sends) {
          final payload = it['payload_json'];
          final orderId = payload is Map ? (payload['orderId'] ?? '').toString() : '';
          if (orderId.isEmpty) {
            await _push.remove('order_send', '${it['id']}');
            orderQueuePending--;
            continue;
          }
          if (needCreate.contains(orderId)) continue; // order not fully on server yet
          try {
            await _posApi.sendCart(orderId);
            await _push.remove('order_send', '${it['id']}');
            orderQueuePending--;
            sent++;
          } on PosNetworkException {
            break; // offline — keep the send queued
          } on PosApiException catch (e) {
            // `nothing_to_send` = the server already had every line sent; that is
            // success. Anything else keeps the send queued so it is retried.
            if (e.code == 'nothing_to_send') {
              await _push.remove('order_send', '${it['id']}');
              orderQueuePending--;
              sent++;
            } else {
              diagnostics.error('order-queue', 'rejected send for order $orderId: ${e.code}');
            }
          }
        }
      }
    } catch (_) {
      // Best-effort: a flush failure never breaks a sync.
    }
    notifyListeners();
    return sent;
  }

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

  /// Result of the most recent [uploadPrintLogs] pass — lets the UI say WHY a
  /// retry did not drain the queue (server rejected N rows with code X vs. the
  /// server was unreachable) instead of blaming the printer.
  PrintLogUploadResult? lastPrintLogUpload;

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
  /// the number of rows accepted this pass; the full outcome (including any
  /// server-side rejections) is left in [lastPrintLogUpload].
  Future<int> uploadPrintLogs() async {
    final tenantId = ctx.tenantId;
    final assetId = ctx.deviceId;
    if (tenantId == null || assetId == null) {
      lastPrintLogUpload = null;
      return 0;
    }
    var uploaded = 0;
    try {
      final res = await _logUploader.uploadPending(tenantId: tenantId, assetId: assetId);
      lastPrintLogUpload = res;
      uploaded = res.uploaded;
      await printLogs.pruneUploaded(maxRows: kPrintLogMaxRows, maxAge: kPrintLogMaxAge);
    } catch (_) {
      // keep rows pending for the next pass
    }
    await refreshPrintLogPending();
    return uploaded;
  }

  // -------------------------------------------------------- diagnostics ------
  /// In-app log buffer (bounded, in-memory) that the diagnostics bundle ships.
  final DiagnosticLog diagnostics;

  /// Last time a 5xx auto-queued a diagnostic bundle (throttle, not a spam valve).
  DateTime? _lastAutoDiagnosticAt;

  /// Every failed API call lands here: one line in the ring buffer, and — for a
  /// server-side 5xx — a queued diagnostic bundle so the server has the evidence
  /// even if the operator never opens Print diagnostics. Throttled to one auto
  /// bundle per 5 minutes; the manual "Report issue" path is untouched.
  void _recordApiError(ApiErrorEvent e) {
    diagnostics.error('api', e.detail == null || e.detail!.isEmpty ? e.label : '${e.label} — ${e.detail}');
    final status = e.status;
    if (status == null || status < 500) return;
    final now = _now();
    final last = _lastAutoDiagnosticAt;
    if (last != null && now.difference(last) < const Duration(minutes: 5)) return;
    _lastAutoDiagnosticAt = now;
    unawaited(_autoDiagnostic(e));
  }

  /// Fire-and-forget companion of [sendDiagnostics]. The bundle is enqueued in
  /// the durable outbox BEFORE it is flushed, so a dead network loses nothing.
  Future<void> _autoDiagnostic(ApiErrorEvent e) async {
    if (ctx.tenantId == null || ctx.deviceId == null) return;
    try {
      await sendDiagnostics(description: 'auto · ${e.label}${e.detail != null ? ' — ${e.detail}' : ''}');
    } catch (_) {
      // Diagnostics must never break the app.
    }
  }

  late final DiagnosticReporter _diagReporter =
      DiagnosticReporter(api: _posApi, push: _push, now: _now);

  /// Cached number of diagnostic reports waiting in the outbox; refreshed by
  /// [refreshDiagnosticPending] and after each send/flush.
  int diagnosticPending = 0;

  /// Why the last diagnostic upload could not reach the server (null when it
  /// did). The screen shows this verbatim so "no network" never hides a server
  /// refusal like `404 asset_not_found`.
  String? get lastDiagnosticFailure => _diagReporter.lastFailure;

  List<Map<String, dynamic>> _printerSummaries() {
    final r = _printRouting;
    if (r == null) return const [];
    return [
      for (final p in r.printers)
        {
          'id': p.id,
          'name': p.name,
          'transport': p.transport,
          'active': p.active,
          'widthMm': p.widthMm,
          if (p.ip != null) 'ip': p.ip,
          if (p.model != null) 'model': p.model,
        },
    ];
  }

  /// Collect the device context + local print summary + recent log lines, and
  /// submit the bundle. Durable offline: the bundle is enqueued into the outbox
  /// FIRST, then flushed — a dead network leaves it queued for the next sync.
  Future<DiagnosticSendResult> sendDiagnostics({required String description}) async {
    final tenantId = ctx.tenantId;
    final assetId = ctx.deviceId;
    final id = _diagReporter.newId();

    List<PrintLogRow> recent = const [];
    var counts = const <String, int>{};
    var total = 0;
    var pending = printLogPending;
    try {
      recent = await printLogs.list(limit: kDiagMaxRecentPrintRows);
      counts = await printLogs.outcomeCounts();
      total = await printLogs.totalCount();
      pending = await printLogs.pendingUploadCount();
    } catch (_) {
      diagnostics.warn('diagnostics', 'print-log summary unavailable');
    }

    final bundle = buildDiagnosticBundle(
      clientReportId: id,
      generatedAt: _now(),
      description: description,
      appVersionName: appVersion.versionName,
      appVersionCode: appVersion.versionCode,
      schemaVersion: appVersion.schemaVersion,
      buildSha: appVersion.buildSha,
      deviceId: ctx.deviceId,
      shortcode: ctx.shortcode,
      groupId: ctx.groupId,
      tenantId: tenantId,
      outletName: ctx.outletName,
      userName: ctx.userName,
      serverAddress: serverAddress,
      lastSyncAt: lastSyncAt,
      configVersions: deviceVersions,
      lastError: lastError,
      recentPrintRows: recent,
      printOutcomeCounts: counts,
      printTotal: total,
      printPendingUpload: pending,
      logLines: diagnostics.snapshot(),
      printers: _printerSummaries(),
    );

    if (tenantId == null || assetId == null) {
      diagnostics.warn('diagnostics', 'cannot send — device not fully activated');
      return DiagnosticSendResult(sent: 0, pending: await refreshDiagnosticPending(), queued: false);
    }

    final res = await _diagReporter.submit(bundle: bundle, tenantId: tenantId, assetId: assetId);
    diagnostics.info('diagnostics', 'report $id ${res.sent > 0 ? 'sent' : 'queued (offline)'}');
    await refreshDiagnosticPending();
    return res;
  }

  /// Ship any queued diagnostic reports (best-effort; offline leaves them queued).
  Future<int> flushDiagnostics() async {
    final tenantId = ctx.tenantId;
    final assetId = ctx.deviceId;
    if (tenantId == null || assetId == null) return 0;
    final sent = await _diagReporter.flush(tenantId: tenantId, assetId: assetId);
    await refreshDiagnosticPending();
    return sent;
  }

  Future<int> refreshDiagnosticPending() async {
    diagnosticPending = await _diagReporter.pendingCount();
    notifyListeners();
    return diagnosticPending;
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
      // Outlet/group identity comes from the synced config (the server ships it
      // in the OUTLET domain). Without this the print path could only ever print
      // store_address/group_name EMPTY even though the web builder showed them.
      storeName: (config?.outlet.name.isNotEmpty ?? false) ? config!.outlet.name : (ctx.outletName ?? ''),
      storeShortcode: config?.outlet.shortcode ?? '',
      storeAddress: config?.outlet.address ?? '',
      storePhone: config?.outlet.phone ?? '',
      storeSocial: config?.outlet.socialMedia ?? '',
      storeInstagram: config?.outlet.instagram ?? '',
      storeTiktok: config?.outlet.tiktok ?? '',
      storeEmail: config?.outlet.email ?? '',
      groupName: config?.group.name ?? '',
      groupShortcode: config?.group.shortcode ?? '',
      cashier: ctx.userName ?? '',
      deviceShortcode: ctx.shortcode ?? '',
      deviceLabel: ctx.shortcode ?? '',
      posClientId: ctx.deviceId ?? '',
      currencyLabel: config?.shift.currencyLabel ?? '',
      timezone: config?.shift.timezone ?? '',
      // Effective outlet rates: resolved per item at config-build time from the
      // outlet master, so the first tagged rate IS the outlet's rate.
      vatPercent: _firstRate(config?.items, (i) => i.vatRate),
      scPercent: _firstRate(config?.items, (i) => i.scRate),
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

  void attachConfigCache(ConfigCache cache) {
    _configCache = cache;
    // Hydrate the last-known-good payloads from disk. Without this a tablet
    // whose persisted domain VERSIONS say "up to date" but whose in-memory
    // stores are empty renders the BUILT-IN ticket and silently ignores the
    // outlet's published format — "format client beda dengan server".
    unawaited(hydrateFromCache());
  }

  /// Apply the persisted config domains (menu, outlet identity, published print
  /// formats) so the device has its last-known-good state before — and
  /// independently of — a sync. Never throws: a corrupt cache must not block the
  /// till.
  Future<void> hydrateFromCache() async {
    final cache = _configCache;
    if (cache == null) return;
    try {
      final master = await _cachedDomain(cache, 'MASTER');
      final outlet = await _cachedDomain(cache, 'OUTLET');
      if (master.isNotEmpty || outlet.isNotEmpty) {
        config = TenantConfig.fromSyncPayloads(master, outlet);
        _printRouting = PrinterRouting.parse(outlet)
          ..itemCategories = {
            for (final i in config?.items ?? const <MenuItem>[]) i.id: i.categoryId,
          };
        _ensurePrintPath();
      }
      // THE fix for the format drift: the published formats live on disk.
      final fmt = await cache.read('FORMAT');
      final fmtRaw = fmt?.jsonPayload;
      if (fmtRaw != null) {
        final decoded = jsonDecode(fmtRaw);
        if (decoded is Map<String, dynamic>) {
          printFormats.apply(decoded, version: fmt!.version);
        }
      }
      // A version claim is only honest when the payload it refers to is actually
      // HELD. Anything recorded without a payload is dropped so the next sync
      // re-pulls it — this un-sticks a tablet that once claimed a domain version
      // (e.g. FORMAT) it never actually stored.
      final held = <String, int>{};
      for (final d in const ['MASTER', 'OUTLET', 'FORMAT', 'MEDIA']) {
        final k = await cache.read(d);
        if (k != null && (k.jsonPayload ?? '').trim().isNotEmpty) held[d] = k.version;
      }
      deviceVersions = held;
      notifyListeners();
    } catch (_) {/* keep whatever last-known-good state we already have */}
  }

  Future<Map<String, dynamic>> _cachedDomain(ConfigCache cache, String d) async {
    final raw = (await cache.read(d))?.jsonPayload;
    if (raw == null) return const {};
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic> ? decoded : const {};
    } catch (_) {
      return const {};
    }
  }

  /// Media file cache (tenant logos/rasters). Wired by the app factory; when
  /// absent the MEDIA domain simply has no files to pull.
  MediaSync? mediaSync;
  void attachMediaSync(MediaSync sync) => mediaSync = sync;

  /// Non-fatal lines from the last media pull (a failed download is reported,
  /// never thrown — the cashier keeps selling and the IMAGE block prints its
  /// labelled placeholder until the file lands).
  final List<String> mediaWarnings = [];

  /// Pull the tenant's media files into the local cache so IMAGE blocks print
  /// offline. Best-effort: any failure is recorded and swallowed.
  Future<void> syncMedia(String tenantId) async {
    final sync = mediaSync;
    if (sync == null) return;
    sync.baseHeaders = authHeaders()?.toHeaders() ?? const {};
    final uri = Uri.parse(
      '${_posApi.baseUrl}/api/pos/media/manifest?tenantId=$tenantId',
    );
    try {
      final report = await sync.sync(manifestUri: uri);
      mediaWarnings
        ..clear()
        ..addAll(report.failed);
    } catch (e) {
      mediaWarnings
        ..clear()
        ..add('$e');
    }
  }

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
    // A settle that only happened LOCALLY (offline) is tracked so the list can
    // say `PAID - Offline` / `FAILED` and the push can flip it to `PAID`.
    final key = bill['clientSettlementKey']?.toString();
    if (bill['offline'] == true && key != null && key.isNotEmpty) {
      settlements[key] = SettlementRecord(
        clientSettlementKey: key,
        orderId: bill['orderId']?.toString() ?? '',
        bill: bill,
      );
    }
    notifyListeners();
  }

  // ------------------------------------------------------ offline settlements --
  /// Local settlements keyed by `clientSettlementKey`, with their push state.
  final Map<String, SettlementRecord> settlements = {};

  SettlementRecord? settlementFor(String key) => settlements[key];

  /// Rebuild the in-memory settlement records from the DURABLE outbox rows the
  /// server has not accepted yet. Called at session start so a settlement the
  /// server REFUSED still shows FAILED (with the same error code) after a
  /// restart — the record itself is memory-only; the refusal is on the row.
  Future<void> hydrateSettlements() async {
    try {
      final items = await _push.pending();
      for (final it in items) {
        if (it['type'] != 'order_settle') continue;
        final key = '${it['id']}';
        final p = it['payload_json'];
        if (p is! Map) continue;
        final bill = <String, dynamic>{
          'orderId': p['orderId'],
          'receiptId': p['receiptId'],
          'status': 'PAID',
          'total': p['totals'] is Map ? (p['totals'] as Map)['total'] : null,
          'paidAt': p['paidAt'],
          'offline': true,
          'clientSettlementKey': key,
        };
        settlements[key] = SettlementRecord(
          clientSettlementKey: key,
          orderId: '${p['orderId'] ?? ''}',
          bill: bill,
        )
          ..status = (it['status'] as String?) ?? 'pending'
          ..errorCode = it['error_code'] as String?;
        if (!todayBills.any((b) => b['clientSettlementKey'] == key)) {
          todayBills.insert(0, bill);
        }
      }
      notifyListeners();
    } catch (_) {/* hydration is best-effort — never block startup */}
  }

  /// Local settlements not yet accepted by the server (pending or FAILED) — the
  /// rows the Today's list must show alongside the server feed.
  List<SettlementRecord> get pendingSettlements =>
      [for (final r in settlements.values) if (!r.synced) r];

  int get failedSettlementCount =>
      settlements.values.where((r) => r.failed).length;

  /// Cashier-facing notices for settlements the server REFUSED (never silent).
  /// The shell/More screen drains this once, like [pendingPrintAlerts].
  final List<String> settlementNotices = [];

  void clearSettlementNotices() {
    if (settlementNotices.isEmpty) return;
    settlementNotices.clear();
    notifyListeners();
  }

  /// Push every queued `order_settle` in FIFO order, but ONLY after that
  /// order's create/line/send have landed (the server refuses a settle on an
  /// order it has never seen). 2xx → accepted, the local bill flips to PAID and
  /// the queue entry is dropped. 4xx → the record is marked FAILED with the
  /// server code and the cashier is told; it is NOT auto-retried until it is
  /// re-committed. Network failure → stop, keep the queue. Returns accepted.
  Future<int> flushSettlements() async {
    var sent = 0;
    try {
      // Make sure the order exists on the server with its lines + send first.
      await flushOrderQueue();
      final items = await _push.pending();
      // Order ids still blocked by a queued create/line/send.
      final blocked = <String>{};
      for (final it in items) {
        final t = it['type'];
        if (t != 'order_create' && t != 'order_line' && t != 'order_send') continue;
        final p = it['payload_json'];
        if (p is Map) {
          final oid = (p['orderId'] ?? it['id'])?.toString();
          if (oid != null && oid.isNotEmpty) blocked.add(oid);
        }
      }
      for (final it in items) {
        if (it['type'] != 'order_settle') continue;
        final key = '${it['id']}';
        final rec = settlements[key];
        if (rec != null && rec.failed) continue; // awaiting a re-commit
        final payload = it['payload_json'];
        if (payload is! Map) {
          await _push.remove('order_settle', key);
          continue;
        }
        final p = payload.cast<String, dynamic>();
        final orderId = (p['orderId'] ?? '').toString();
        if (orderId.isEmpty) {
          await _push.remove('order_settle', key);
          continue;
        }
        if (blocked.contains(orderId)) continue; // order not fully on server yet
        try {
          final r = await _posApi.settleDeferred(orderId, body: p);
          await _push.remove('order_settle', key);
          _settlementAccepted(key, '${p['receiptId'] ?? r['receiptId'] ?? ''}');
          sent++;
        } on PosNetworkException {
          break; // offline — keep the queue, try again later
        } on PosApiException catch (e) {
          await _settlementRejected(key, e.code);
        }
      }
    } catch (_) {
      // Best-effort: a flush failure never breaks a sync.
    }
    notifyListeners();
    return sent;
  }

  void _settlementAccepted(String key, String receiptId) {
    final rec = settlements[key];
    if (rec != null) {
      rec.status = 'synced';
      rec.errorCode = null;
      rec.bill['offline'] = false;
    }
  }

  Future<void> _settlementRejected(String key, String code) async {
    final rec = settlements[key];
    if (rec != null) {
      rec.status = 'failed';
      rec.errorCode = code;
    }
    // Persist the refusal on the queued row so FAILED + its code survive a
    // restart (the record itself is memory-only).
    await _push.markFailed('order_settle', key, code);
    settlementNotices.add(
      'Settlement ${rec?.bill['receiptId'] ?? key} was REFUSED by the server ($code). '
      'Fix it and commit again from Today transactions — the sale is held locally.',
    );
    diagnostics.error('settle', 'settle-deferred rejected $key: $code');
    notifyListeners();
  }

  /// Re-commit a FAILED settlement and push it again under the SAME
  /// `clientSettlementKey` (idempotent — never a duplicate sale). When
  /// [payload] is given it REPLACES the queued snapshot with the cashier's
  /// corrected, latest details; otherwise the queued snapshot is retried.
  Future<bool> recommitSettlement(String key, {Map<String, dynamic>? payload}) async {
    final rec = settlements[key];
    if (rec == null) return false;
    if (payload != null) {
      try {
        await _push.enqueue('order_settle', key, payload);
      } catch (_) {}
    }
    // A re-commit is a fresh attempt — clear any stored FAILED so a restart
    // does not re-flag a settlement the cashier has already re-committed.
    try {
      await _push.clearFailure('order_settle', key);
    } catch (_) {}
    rec.status = 'pending';
    rec.errorCode = null;
    rec.bill['offline'] = true;
    notifyListeners();
    await flushSettlements();
    return settlements[key]?.synced ?? false;
  }

  /// Manual "Push now": flush the order queue (create → line → send) AND the
  /// deferred settlements. Returns a small summary for the More screen.
  Future<PushSummary> pushNow() async {
    final orders = await flushOrderQueue();
    final settles = await flushSettlements();
    return PushSummary(
      orderItems: orders,
      settlements: settles,
      failed: failedSettlementCount,
      queued: await _push.pending().then((p) => p.length),
    );
  }

  /// Auto-push when the app returns to the foreground (resume). Deliberately
  /// guarded so a resume costs nothing when there is nothing to do: no request
  /// unless the session is READY (logged in), no flow is busy, and the outbox
  /// actually holds something.
  Future<void> pushQueuedOnResume() async {
    if (stage != PosStage.ready || busy || _push.count == 0) return;
    await pushNow();
  }

  /// Print warnings from a fire-and-forget print (bill at settle, captain/bev at
  /// send-cart) that finished AFTER its screen had already moved on. The shell
  /// drains this once and shows ONE snackbar — so a slow or flaky printer never
  /// holds the sale but the operator still learns the paper did not come out.
  final List<String> pendingPrintAlerts = [];

  /// Merge a finished print's honest warnings into the shared surface. Empty
  /// lists are ignored so this can never arm a pointless (spam) snackbar.
  void notePrintAlerts(List<String> alerts) {
    if (alerts.isEmpty) return;
    pendingPrintAlerts.addAll(alerts);
    notifyListeners();
  }

  /// The shell has shown the pending print alerts — clear them (no spam).
  void clearPrintAlerts() {
    if (pendingPrintAlerts.isEmpty) return;
    pendingPrintAlerts.clear();
    notifyListeners();
  }

  /// Server truth for Today's transactions: the outlet's current trading-day
  /// PAID / CANCELED / VOIDED / REFUNDED rows, full status included. Distinct
  /// from [todayBills] (settles this device just made). Kept so a cancelled
  /// order — which never reaches [noteSettled] — still shows on the list.
  final List<Map<String, dynamic>> todayLedger = [];

  /// Fetch today's transactions from the server into [todayLedger]. Best-effort:
  /// returns the rows on success (possibly empty), or null when the network /
  /// server fails — the caller then falls back to [todayBills] and says so.
  Future<List<Map<String, dynamic>>?> loadTodayOrders() async {
    final tenantId = ctx.tenantId;
    if (tenantId == null) return null;
    try {
      final r = await _posApi.listTodayOrders(tenantId);
      final rows = (r['orders'] as List? ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      todayLedger
        ..clear()
        ..addAll(rows);
      notifyListeners();
      return rows;
    } on PosApiException {
      return null;
    } on PosNetworkException {
      return null;
    }
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
    // Last release the server advertised (drives "what's new" after a restart).
    try {
      lastRelease = await _releaseStore.load();
    } catch (_) {
      lastRelease = null;
    }
    // Storage hygiene: builds before the prune-before-download fix left full-size
    // APKs stacked in app storage. Clear them on every start. Best-effort: the
    // platform path is absent in tests and the caller must never fail startup.
    unawaited(UpdateService(PlatformApkBridge()).pruneStaleDownloads());
    _stageFromContext();
    // Rebuild any un-accepted settlements from the durable outbox so a FAILED
    // sale still reads FAILED (with its server code) after a restart.
    await hydrateSettlements();
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
      diagnostics.error('activation', 'redeem failed: ${e.code}');
      return false;
    } on PosNetworkException {
      lastError = 'Cannot reach the server. Check your connection and try again.';
      diagnostics.error('activation', 'redeem offline: server unreachable');
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
      diagnostics.error('login', 'login failed: ${e.code}');
      return false;
    } on PosNetworkException {
      lastError = 'Login requires a server connection. Check your network.';
      diagnostics.error('login', 'login offline: server unreachable');
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
    // Drop the session-held shift controller too — the next login builds a fresh
    // one scoped to that session's tenant, so a previous tenant's shift is never
    // restored into the new session.
    _shiftController = null;
    stage = PosStage.login;
    busy = false;
    lastError = null;
    notifyListeners();
  }

  // ---------------------------------------------------------------- update --
  /// PRD 4.33a: check the server's `version.json` on login and on every config
  /// sync, and compare the advertised versionCode with this build's.
  ///
  /// Never throws and never blocks: an unpublished release, a malformed payload
  /// and a failed fetch all leave [updateAvailable] false. A failure is recorded
  /// honestly in [lastUpdateCheckError] (shown on the About screen) — the
  /// tablet is never nagged about a release it cannot see.
  Future<void> checkForUpdate() async {
    try {
      final res = await _posApi.versionInfo();
      // The manifest may be returned flat or nested under `release`.
      final raw = res['release'] is Map ? res['release'] : (res['version'] == null && res['data'] is Map ? res['data'] : res);
      final release = ReleaseInfo.parse(raw);
      lastUpdateCheckedAt = _now();
      lastUpdateCheckError = null;
      if (release == null) {
        // Honest empty shape ("no release published") — say nothing, never an update.
        updateOffered = false;
      } else {
        lastRelease = release;
        updateOffered = release.isNewerThan(appVersion.versionCode);
        try {
          await _releaseStore.save(release);
        } catch (_) {/* keep the in-memory copy */}
      }
    } catch (e) {
      lastUpdateCheckedAt = _now();
      lastUpdateCheckError = e is PosApiException ? 'server error ${e.status} (${e.code})' : 'unreachable ($e)';
      updateOffered = false;
    }
    notifyListeners();
  }

  // ---------------------------------------------------------------- config --
  /// Orders this tablet CLOSED (cancel/void). Open Tables filters them out
  /// immediately — no server round-trip, no refresh needed (the field report).
  final Set<String> _closedOrderIds = <String>{};
  Set<String> get closedOrderIds => _closedOrderIds;
  void noteOrderClosed(String id) {
    if (id.isEmpty) return;
    _closedOrderIds.add(id);
    notifyListeners();
  }

  /// Forget closed ids the server no longer lists (the order is gone for good, or
  /// was re-opened) so the set cannot grow without bound.
  void pruneClosedOrders(Set<String> stillListed) {
    final gone = [for (final id in _closedOrderIds) if (!stillListed.contains(id)) id];
    if (gone.isEmpty) return;
    _closedOrderIds.removeAll(gone);
  }

  /// Last-known Open Tables list, cached on disk so the screen can render
  /// IMMEDIATELY (offline-first) instead of waiting for the server. The server
  /// is still the truth — it refreshes the list in the background.
  static const String _openOrdersKey = 'OPEN_ORDERS';

  Future<List<Map<String, dynamic>>?> cachedOpenOrders() async {
    final raw = (await _configCache?.read(_openOrdersKey))?.jsonPayload;
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) return [for (final o in decoded) if (o is Map<String, dynamic>) o];
    } catch (_) {/* a corrupt cache is just "no cache" */}
    return null;
  }

  Future<void> cacheOpenOrders(List<Map<String, dynamic>> orders) async {
    try {
      await _configCache?.writeJson(_openOrdersKey, 1, orders);
    } catch (_) {/* best-effort: never block the till on a cache write */}
  }

  /// Repair path for a stuck tablet: forget which domains we believe we hold so
  /// the next sync pulls EVERY domain in full. An operator escape hatch when a
  /// device claims a domain it never actually stored.
  Future<bool> forceFullConfigResync() async {
    deviceVersions = const {};
    return refreshConfig();
  }

  Future<bool> refreshConfig() async {
    if (syncing) return false;
    syncing = true;
    notifyListeners();
    try {
      // PRD 4.33a: the version.json check rides every config sync, which is also
      // what a login triggers (login → refreshConfig). Best-effort, silent on
      // failure, and never blocks the cashier.
      await checkForUpdate();
      // Deterministic order: hydrate the last-known-good payloads (and the
      // HONEST domain versions — a claim without a stored payload is dropped)
      // BEFORE planning, so a late hydration can never clobber a fresh sync.
      await hydrateFromCache();
      final tenantId = ctx.tenantId!;
      final state = await _posApi.configState(tenantId);
      final vs = state['versions'] as Map<String, dynamic>? ?? const {};
      final serverVersions = <String, int>{
        for (final e in vs.entries)
          e.key: ((e.value is Map) ? _asInt((e.value as Map)['version']) : _asInt(e.value)) ?? 0,
      };
      final plan = planSync(serverVersions, deviceVersions);
      if (plan.needsFull.isNotEmpty) {
        final sync = await _posApi.configSync(tenantId, deviceVersions);
        // Refresh the licence block so the reminder can re-arm on renewal or a
        // state change without a re-login (additive; absent → keep last known).
        license = LicenseInfo.fromJson(sync['license']) ?? license;
        final full = sync['full'] as Map<String, dynamic>? ?? const {};
        final cache = _configCache;
        // A partial sync carries ONLY the domains that changed. Rebuilding the
        // config from `full` alone wiped everything else — after an OUTLET-only
        // sync the item catalog/layout and the discount masters vanished (no menu
        // to tap, no discount to add). Every domain therefore falls back to its
        // LAST-KNOWN-GOOD cached payload.
        Future<Map<String, dynamic>> domainPayload(String d) async {
          final sent = full[d];
          if (sent is Map<String, dynamic>) return sent;
          final raw = (await cache?.read(d))?.jsonPayload;
          if (raw == null) return const {};
          try {
            final decoded = jsonDecode(raw);
            return decoded is Map<String, dynamic> ? decoded : const {};
          } catch (_) {
            return const {};
          }
        }

        final master = await domainPayload('MASTER');
        final outlet = await domainPayload('OUTLET');
        config = TenantConfig.fromSyncPayloads(master, outlet);
        // Outlet printer model + routing (tolerant; never throws). The print
        // path is rebuilt from this real synced config.
        _printRouting = PrinterRouting.parse(outlet)
          // itemId → categoryId, so a menu-level station assignment resolves on
          // the device (the printer payload carries printers, not the catalog).
          ..itemCategories = {
            for (final i in config?.items ?? const <MenuItem>[]) i.id: i.categoryId,
          };
        _ensurePrintPath();
        // Published print formats ride the FORMAT domain; applied defensively
        // (a bad payload keeps last-known-good and the built-in fallback holds).
        final formatDomain = full['FORMAT'];
        if (formatDomain != null) {
          printFormats.apply(formatDomain, version: serverVersions['FORMAT'] ?? 0);
        }
        // Tenant media FILES (logos/rasters) ride the MEDIA domain — but the pull
        // runs on EVERY sync, not only when the version moved: the sync is
        // idempotent (identical hash = skip) and this is what retries a download
        // that failed earlier (offline, wrong host). Best-effort: a failure never
        // blocks the cashier.
        await syncMedia(tenantId);
        // Bookkeeping: a domain is "applied" ONLY when we actually HOLD its
        // payload. Recording a version we never stored pins the device to
        // "up to date" forever and it never re-pulls — that is exactly why the
        // published print format never reached the tablet again.
        final applied = <String, int>{...deviceVersions};
        for (final d in plan.needsFull) {
        applied[d] = (full[d] != null) ? (serverVersions[d] ?? 0) : 0;
        }
        // Domains the server considers current: keep the claim only if the payload
        // is genuinely held (cache), else clear it so the next sync re-pulls.
        if (cache != null) {
        for (final d in plan.upToDate) {
          final held = (await cache.read(d))?.jsonPayload != null;
          if (!held) applied[d] = 0;
        }
        }
        deviceVersions = applied;
        // Persist EVERY domain the server sent — not just the ones this device
        // happened to ask for.
        if (cache != null) {
        for (final e in full.entries) {
          final payload = e.value;
          if (payload is Map<String, dynamic>) {
            try {
              await cache.writeJson(e.key, serverVersions[e.key] ?? 0, payload);
            } catch (_) {/* keep last-known-good */}
          }
        }
        }
    }
      lastSyncAt = _now();
      // Best-effort: ship any locally-recorded print attempts (additive).
      await uploadPrintLogs();
      // Best-effort: ship any operator diagnostics queued while offline.
      await flushDiagnostics();
      // Best-effort: flush optimistic offline line adds recovered from the outbox.
      await flushOrderQueue();
      // Best-effort: push any local (offline) settlements once the server is
      // reachable again — the sale is already done, this just reconciles it.
      await flushSettlements();
      // Recover a running shift so a reopened app / fresh config sync knows the
      // shift is already open (server returns only OPEN shifts). Never blocks.
      try {
        await shiftController.restore();
      } catch (_) {}
      return true;
    } on PosApiException catch (e) {
      lastError = _configError(e);
      diagnostics.error('config', 'config refresh failed: ${e.code}');
      return false;
    } on PosNetworkException {
      lastError = 'Config refresh failed — no network.';
      diagnostics.error('config', 'config refresh offline: server unreachable');
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

/// One device-local settlement and its push state. The SALE is done locally the
/// moment it is created; [status] tracks whether the server has accepted it.
class SettlementRecord {
  SettlementRecord({
    required this.clientSettlementKey,
    required this.orderId,
    required this.bill,
  });

  final String clientSettlementKey;
  final String orderId;

  /// Display row (receiptId/total/paidAt…). `offline` flips to false on accept.
  final Map<String, dynamic> bill;

  /// `pending` (queued, not yet accepted) | `synced` (server accepted → PAID) |
  /// `failed` (server refused a push → cashier must fix & commit again).
  String status = 'pending';
  String? errorCode;

  bool get synced => status == 'synced';
  bool get failed => status == 'failed';
}

/// Outcome of a manual "Push now": counts accepted this pass plus what is left.
class PushSummary {
  const PushSummary({
    required this.orderItems,
    required this.settlements,
    required this.failed,
    required this.queued,
  });

  final int orderItems;
  final int settlements;
  final int failed;
  final int queued;

  bool get ok => orderItems + settlements > 0;
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
    // Tenant media FILES: the manifest index lives in the same device DB, the
    // bytes under <support>/gundam_pos/media (the tablet prints offline).
    final mediaStore = SqliteMediaCacheStore(
      localDb: LocalDb(),
      pathProvider: () async {
        final dir = await getApplicationSupportDirectory();
        return '${dir.path}/gundam_pos/gundam.db';
      },
    );
    // The IMAGE source is read per print job, so it can be resolved lazily here
    // (the media cache only exists after the platform dir is known).
    final imageRef = <PrintImageSource?>[null];
    final session = AppSession(
      posApi: PosApi(client),
      sessionStore: st,
      serverAddressStore: addressStore ?? SecureServerAddressStore(),
      releaseStore: SecureReleaseInfoStore(),
      receiptSequence: posStore,
      pushStore: posStore,
      printLogStore: printLogStore,
      printTransport: AppSession._defaultPrintTransport(
        imageSourceProvider: () => imageRef[0],
      ),
      printerHealthReporter: PrinterHealthReporter(client: client),
    );
    ref[0] = session;
    // Best-effort: the platform support dir is unavailable on a test host, so
    // this never blocks construction.
    unawaited(() async {
      try {
        final dir = await getApplicationSupportDirectory();
        final sync = MediaSync(
          dir: Directory('${dir.path}/gundam_pos/media'),
          store: mediaStore,
          baseHeaders: session.authHeaders()?.toHeaders() ?? const {},
        );
        session.attachMediaSync(sync);
        imageRef[0] = MediaSyncPrintImageSource(sync);
      } catch (_) {
        // No platform dir (CI/test host) → the IMAGE block prints its placeholder.
      }
    }());
    return session;
  }
}
/// First non-null rate among the outlet's items — the config build resolves the
/// outlet master's VAT/SC rate onto every tagged item, so the first one IS the
/// outlet's effective rate ({vat_percent} / {sc_percent}). '' when unset.
String _firstRate(List<MenuItem>? items, double? Function(MenuItem) pick) {
  for (final i in items ?? const <MenuItem>[]) {
    final v = pick(i);
    if (v != null) return v.toString();
  }
  return '';
}

/// Tolerant numeric read for SERVER JSON: Prisma Decimals/some counters arrive
/// as strings, and a hard `as num` cast on one throws (the class of bug that
/// crashed `addItem`). Never used for local SQLite values, which are numeric.
int? _asInt(Object? v) {
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v);
  return null;
}
