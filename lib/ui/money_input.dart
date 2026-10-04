import 'package:flutter/services.dart';

/// Indonesian thousand separators for MONEY text fields.
///
/// The display is grouped ("1.000.000") while the VALUE stays a plain number —
/// formatting never touches the maths. Every money field parses through
/// [parseMoneyInput] so a grouped string can never be misread as decimals.
const String kThousandsSeparator = '.';

String _group(String digits) {
  final buf = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buf.write(kThousandsSeparator);
    buf.write(digits[i]);
  }
  return buf.toString();
}

/// Digits in, grouped digits out. Non-digits are dropped (paste included), so
/// "1000" shows as "1.000" and the caret lands at the end.
class ThousandsInputFormatter extends TextInputFormatter {
  const ThousandsInputFormatter();

  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    final digits = newValue.text.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.isEmpty) return const TextEditingValue();
    final grouped = _group(digits);
    return TextEditingValue(
      text: grouped,
      selection: TextSelection.collapsed(offset: grouped.length),
    );
  }
}

/// The number behind a grouped display value. Empty / "." → 0.
double parseMoneyInput(String raw) =>
    double.tryParse(raw.replaceAll(kThousandsSeparator, '').trim()) ?? 0;

/// Whole-rupiah variant for integer amounts.
int parseIntInput(String raw) =>
    int.tryParse(raw.replaceAll(kThousandsSeparator, '').trim()) ?? 0;

/// Format a number for display in a money field (no decimals — rupiah is whole).
String formatMoneyInput(num value) => _group(value.round().abs().toString());
