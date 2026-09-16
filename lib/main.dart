import 'package:flutter/material.dart';

/// Gundam POS Client — F0 foundation placeholder.
/// Cashier UI + local SQLite + print broker (:9100 / Bluetooth / USB).
/// Real routes/logic start in F1+; this only proves the app shell builds.
void main() => runApp();

void runApp() {
  runAppWithArgs();
}

@pragma('vm:entry-point')
void runAppWithArgs() {
  print('Gundam POS Client shell (F0)');
}