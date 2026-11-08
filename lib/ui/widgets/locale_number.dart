/// Locale-aware parsing of a typed ENGINEERING number (Round 17 follow-up,
/// i18n-residuals-numeric-input-not-locale-aware).
///
/// The money fields already read numbers by locale ([parseMoneyInput]: in the
/// Indonesian UI `.` groups thousands and `,` marks decimals). Every other
/// number field used a plain `double.tryParse`, so in one ID session the same
/// keystrokes `33.000` meant 33 000 in a price cell and 33 in the PLN daya
/// (VA) cell — a 33 VA service, a 6 kA device rung instead of 10 kA, and the
/// service-capacity floor switched off — while `0,85` (a cos φ typed with the
/// decimal comma) was silently dropped.
///
/// This is the ONE structural parser for those fields: an optional sign, then
/// [parseMoneyInput]'s separator rules (both marks ⇒ the last is decimal; one
/// mark repeated ⇒ grouping; a single mark before exactly three digits groups
/// thousands only when it is the locale's grouping mark) — except that a
/// single mark after a lone `0` integer part (`0.125`, `0,125`) is always the
/// decimal mark (no thousands group starts with 0). Plain-dart forms the money
/// parser does not cover (`1e-3`, `NaN`, `Infinity`) fall back to
/// `double.tryParse`, so the callers' non-finite rejection still sees them.
/// Returns null when the text is not a number.
library;

import '../commercial/money_input.dart' show parseMoneyInput;

double? parseLocaleNumber(String input, {required bool indonesian}) {
  var t = input.trim();
  if (t.isEmpty) return null;
  var sign = 1.0;
  if (t.startsWith('-') || t.startsWith('+')) {
    if (t.startsWith('-')) sign = -1.0;
    t = t.substring(1).trim();
  }
  if (t.isEmpty) return null;
  final leadingZero = RegExp(r'^0[.,]([0-9]+)$').firstMatch(t);
  if (leadingZero != null) {
    final v = double.tryParse('0.${leadingZero.group(1)}');
    return v == null ? null : sign * v;
  }
  final structural = parseMoneyInput(t, indonesian: indonesian);
  if (structural != null) return sign * structural;
  // Exponent / NaN / Infinity forms — the caller rejects non-finite values.
  if (t.contains(',')) return null;
  final plain = double.tryParse(t);
  return plain == null ? null : sign * plain;
}

/// The DISPLAY half of [parseLocaleNumber] (Round 18 review follow-up): a
/// plain-dart number text (`1.125`, `33000`, `0.85` — never grouped) shown in
/// the Indonesian UI with the decimal COMMA (`1,125`), so editing the shown
/// value and committing it reads back the same number. A dot-decimal display
/// with three decimals used to be re-read by the ID rules as a thousands group
/// (`1.126` → 1126). Exponent / non-numeric text is returned unchanged; the
/// English UI is byte-identical.
String localizeNumberText(String plain, {required bool indonesian}) {
  if (!indonesian) return plain;
  if (!RegExp(r'^[+-]?[0-9]+\.[0-9]+$').hasMatch(plain.trim())) return plain;
  return plain.replaceFirst('.', ',');
}
