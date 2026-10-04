import 'dart:async';

import 'package:flutter/material.dart';

import 'package:gundam_pos/state/app_session.dart';
import 'package:gundam_pos/ui/activation_screen.dart';
import 'package:gundam_pos/ui/home_screen.dart';
import 'package:gundam_pos/ui/login_screen.dart';
import 'package:gundam_pos/ui/theme.dart';
import 'package:gundam_pos/ui/widgets.dart';

/// Gundam POS app shell. Owns the [AppSession] and routes the auth stages.
class PosApp extends StatefulWidget {
  const PosApp({super.key, this.sessionProvider});

  /// Injectable session factory for tests; defaults to the real wiring.
  final AppSession Function()? sessionProvider;

  @override
  State<PosApp> createState() => _PosAppState();
}

class _PosAppState extends State<PosApp> with WidgetsBindingObserver {
  late final AppSession _session;
  final _messengerKey = GlobalKey<ScaffoldMessengerState>();
  bool _booted = false;

  @override
  void initState() {
    super.initState();
    _session = (widget.sessionProvider ?? AppDependencies.create)();
    _session.addListener(_onSessionChanged);
    WidgetsBinding.instance.addObserver(this);
    _boot();
  }

  /// Push the queue when the app returns to the foreground: a sale taken /
  /// settled while the tablet was backgrounded (or offline) reaches the server
  /// on resume without the operator tapping "Push now". Guarded inside
  /// [AppSession.pushQueuedOnResume] — no request when logged out/busy/empty.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_session.pushQueuedOnResume());
    }
  }

  /// Shared print-alert surface: a fire-and-forget print (bill at settle,
  /// captain/bev at send-cart) may finish AFTER its screen moved on, so the
  /// shell drains the session's pending alerts and shows ONE snackbar. Cleared
  /// immediately, so an empty surface never arms a snackbar (no spam).
  void _onSessionChanged() {
    if (_session.pendingPrintAlerts.isEmpty) return;
    final alerts = List<String>.of(_session.pendingPrintAlerts);
    _session.clearPrintAlerts();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _messengerKey.currentState?.showSnackBar(SnackBar(content: Text(alerts.join(' · '))));
    });
  }

  Future<void> _boot() async {
    await _session.init();
    if (mounted) setState(() => _booted = true);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _session.removeListener(_onSessionChanged);
    _session.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Gundam POS',
      debugShowCheckedModeBanner: false,
      scaffoldMessengerKey: _messengerKey,
      theme: PosTheme.theme(),
      home: _booted
          ? ListenableBuilder(
              listenable: _session,
              builder: (_, __) => switch (_session.stage) {
                PosStage.needActivation => ActivationScreen(session: _session),
                PosStage.login => LoginScreen(session: _session),
                PosStage.ready => HomeScreen(session: _session),
                PosStage.checking => const _Splash(),
              },
            )
          : const _Splash(),
    );
  }
}

class _Splash extends StatelessWidget {
  const _Splash();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: scheme.primary,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const PosLogo(dark: false, size: 72),
            const SizedBox(height: 20),
            Text('Gundam POS', style: Theme.of(context).textTheme.headlineMedium?.copyWith(color: Colors.white, fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            const SizedBox(height: 12),
            const SizedBox(
              width: 26,
              height: 26,
              child: CircularProgressIndicator(strokeWidth: 3, color: PosTheme.tealSoft),
            ),
          ],
        ),
      ),
    );
  }
}