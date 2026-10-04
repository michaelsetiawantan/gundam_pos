import 'dart:ui';

import 'package:flutter/material.dart';

import 'package:gundam_pos/app.dart';
import 'package:gundam_pos/services/diagnostic_report.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // Every uncaught error lands in the SAME bounded buffer the diagnostic bundle
  // ships, so a crash/exception on a tablet is readable from the server side too
  // (More → Print diagnostics → "Report issue to server") — not just a blank
  // screen nobody can explain afterwards.
  final previous = FlutterError.onError;
  FlutterError.onError = (details) {
    diagnosticLog.error(
      'flutter',
      '${details.exceptionAsString()} :: ${details.library ?? '-'} :: ${details.context ?? '-'}',
    );
    (previous ?? FlutterError.presentError)(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    diagnosticLog.error('async', '$error');
    return true; // recorded — never crash the shell
  };

  runApp(const PosApp());
}