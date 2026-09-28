/// Drift guard: the POS printer vocabulary, derived from the REAL Dart registries.
///
/// The web app (the TRIGGER) and the APK (the drivers) must speak the same codes:
/// a dialect spelled one way on the web and another in the APK silently mis-prints.
/// This file renders the APK's vocabulary as JSON; `tool/printer-vocabulary.json`
/// is committed from it and `test/printer_vocabulary_test.dart` fails if the two
/// drift apart. The web side reads the same file and asserts equality.
///
/// Regenerate after any change to escpos.dart / usb_printer_channel.dart /
/// print_routing.dart:
///
///     cd pos && UPDATE_PRINTER_VOCABULARY=1 flutter test test/printer_vocabulary_test.dart
///
/// Nothing here is hand-written: every value comes from the registries.
library;

import 'dart:convert';
import 'dart:io';

import 'package:gundam_pos/services/escpos.dart';
import 'package:gundam_pos/services/print_routing.dart';
import 'package:gundam_pos/services/usb_printer_channel.dart';

Map<String, Object?> _sorted(Map<String, Object?> m) {
  final keys = m.keys.toList()..sort();
  return {for (final k in keys) k: m[k]};
}

/// The web's capability vocabulary code → the config key that carries it in the
/// printer/model payload (the key [ClientPrinter.fromJson] parses). A test in
/// `test/printer_vocabulary_test.dart` asserts the keys here are exactly
/// [kPrinterCapabilityKeys], so the two cannot diverge.
const Map<String, String> kCapabilityWebCodes = {
  'CUTTER': 'supportsCutter',
  'NATIVE_QR': 'supportsNativeQr',
  'NATIVE_BARCODE': 'supportsNativeBarcode',
};

/// The full vocabulary map — dialects, aliases, code pages, usb chips,
/// capabilities. Deterministic ordering so the committed JSON is stable.
Map<String, Object?> buildPrinterVocabulary() {
  final dialects = <String, Object?>{
    for (final e in kEscPosDialects.entries) e.key: {'implemented': e.value.implemented},
  };
  final codePages = <String, Object?>{
    for (final e in kEscPosCodePages.entries)
      e.key: {'selector': e.value.selector, 'implemented': e.value.implemented},
  };
  final usbChips = <String, Object?>{
    for (final c in kUsbChipWebCodes) c: canonicalUsbChip(c),
  };
  return {
    'dialects': _sorted(dialects),
    'dialectAliases': _sorted({for (final e in kDialectAliases.entries) e.key: e.value}),
    'codePages': _sorted(codePages),
    'codePageAliases': _sorted({for (final e in kCodePageAliases.entries) e.key: e.value}),
    'usbChips': _sorted(usbChips),
    'capabilities': _sorted({for (final e in kCapabilityWebCodes.entries) e.key: e.value}),
    'capabilityConfigKeys': List<String>.from(kPrinterCapabilityKeys),
    'capabilityAliases': List<String>.from(kPrinterCapabilityAliases),
  };
}

/// The exact committed file contents (2-space indent, trailing newline).
String encodePrinterVocabulary() =>
    '${const JsonEncoder.withIndent('  ').convert(buildPrinterVocabulary())}\n';

/// The committed manifest path, relative to the package root.
const String kPrinterVocabularyPath = 'tool/printer-vocabulary.json';

/// Write (or refresh) the committed manifest from the registries above.
void writePrinterVocabulary([String path = kPrinterVocabularyPath]) =>
    File(path).writeAsStringSync(encodePrinterVocabulary());
