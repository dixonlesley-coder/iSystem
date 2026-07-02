/// Client-facing number formatting — the ONE place the Indonesian dot-grouping
/// lives, shared by the DAYA-in-WATT drawing label (`_wattsId` in
/// `electrical_sld_drawing.dart`) and the commercial quotation proposal. Pure,
/// zero Flutter imports.
///
/// The convention is Indonesian: thousands are separated by a DOT and the
/// decimal is a COMMA (so `3703.68` reads `3.703,68`, `1181250` reads
/// `1.181.250`). Both separators are overridable for callers that need a
/// different locale.
library;

/// Group the INTEGER part of [v] into thousands with [separator] (default the
/// Indonesian dot). [v] is ROUNDED to the nearest whole number first — this is
/// the exact core of the DAYA-in-WATT formatter, so delegating keeps that
/// output byte-identical (`groupThousands(4400)` -> `4.400`,
/// `groupThousands(190)` -> `190`, `groupThousands(52871)` -> `52.871`).
String groupThousands(num v, {String separator = '.'}) {
  final n = v.round();
  final neg = n < 0;
  final digits = n.abs().toString();
  final buf = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buf.write(separator);
    buf.write(digits[i]);
  }
  return '${neg ? '-' : ''}$buf';
}

/// A client-facing money figure: the integer part grouped into thousands (via
/// [groupThousands]) with a fixed [dp] decimal places joined by
/// [decimalSeparator]. `money(1181250)` -> `1.181.250`,
/// `money(3703.68, dp: 2)` -> `3.703,68`, `money(1000, dp: 2)` -> `1.000,00`.
///
/// The value is first rounded to [dp] decimals (banker-free, `toStringAsFixed`
/// half-away-from-zero) so the integer part and fraction stay consistent.
String money(
  num v, {
  int dp = 0,
  String groupSeparator = '.',
  String decimalSeparator = ',',
}) {
  final fixed = v.toStringAsFixed(dp); // e.g. "3703.68", "1181250", "-12.00"
  final neg = fixed.startsWith('-');
  final abs = neg ? fixed.substring(1) : fixed;
  final dot = abs.indexOf('.');
  final intDigits = dot < 0 ? abs : abs.substring(0, dot);
  final frac = dot < 0 ? '' : abs.substring(dot + 1);
  final grouped = groupThousands(int.parse(intDigits), separator: groupSeparator);
  final body = frac.isEmpty ? grouped : '$grouped$decimalSeparator$frac';
  return '${neg ? '-' : ''}$body';
}
