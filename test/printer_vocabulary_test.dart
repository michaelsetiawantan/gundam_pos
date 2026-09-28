import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gundam_pos/services/escpos.dart';
import 'package:gundam_pos/services/print_routing.dart';
import 'package:gundam_pos/services/usb_printer_channel.dart';

import '../tool/printer_vocabulary.dart';

/// Drift guard for the printer vocabulary shared with the web app.
///
/// The web config is the TRIGGER, this APK holds the drivers: a dialect or code
/// page spelled one way on the web and another here silently mis-prints. The
/// committed manifest `tool/printer-vocabulary.json` is derived from the real
/// Dart registries; this test fails the moment the two disagree, and the web
/// side reads the same file.
///
/// Refresh it with:
///   UPDATE_PRINTER_VOCABULARY=1 flutter test test/printer_vocabulary_test.dart
void main() {
  test('tool/printer-vocabulary.json is derived from the Dart registries', () {
    if (Platform.environment['UPDATE_PRINTER_VOCABULARY'] == '1') {
      writePrinterVocabulary();
    }
    final file = File(kPrinterVocabularyPath);
    expect(file.existsSync(), isTrue,
        reason: 'missing — run: UPDATE_PRINTER_VOCABULARY=1 flutter test test/printer_vocabulary_test.dart');
    expect(file.readAsStringSync(), encodePrinterVocabulary(),
        reason: 'manifest is stale — regenerate it and commit the result');
  });

  test('the manifest covers every code the web vocabulary ships', () {
    final v = buildPrinterVocabulary();

    // Drifted dialect spellings both resolve to the one canonical code.
    expect(normalizeDialect('ESC/POS-GENERIC'), 'ESC/POS-CLONE');
    expect(normalizeDialect('ESC/POS-CLONE'), 'ESC/POS-CLONE');
    expect(normalizeDialect('STAR-LINE-MODE'), 'STAR');
    expect(normalizeDialect('CITIZEN-ESCPOS'), 'CITIZEN');
    expect(normalizeCodePage('WPC1252'), 'CP1252');

    final dialects = (v['dialects'] as Map).keys.cast<String>().toSet();
    expect(dialects, containsAll(['ESC/POS', 'ESC/POS-CLONE', 'STAR', 'CITIZEN']));

    final codePages = (v['codePages'] as Map).keys.cast<String>().toSet();
    expect(codePages, containsAll(['CP437', 'CP1252', 'CP863', 'CP865', 'UTF-8']));

    final chips = (v['usbChips'] as Map).keys.cast<String>().toSet();
    expect(chips, kUsbChipWebCodes.toSet());
    expect((v['capabilityConfigKeys'] as List).cast<String>(), kPrinterCapabilityKeys);
    // Web capability codes ↔ the config keys the APK parses: same three flags.
    expect((v['capabilities'] as Map).values.cast<String>().toSet(), kPrinterCapabilityKeys.toSet());
    expect((v['capabilities'] as Map).keys.cast<String>().toSet(),
        {'CUTTER', 'NATIVE_QR', 'NATIVE_BARCODE'});
  });
}
