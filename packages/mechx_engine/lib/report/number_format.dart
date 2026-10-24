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

/// What both formatters print for a NON-FINITE input (NaN / ±Infinity) — the
/// same `-` "no value" mark the schedules already use, instead of throwing
/// mid-export.
const String kNonFiniteNumber = '-';

/// Group the INTEGER part of [v] into thousands with [separator] (default the
/// Indonesian dot). [v] is ROUNDED to the nearest whole number first — this is
/// the exact core of the DAYA-in-WATT formatter, so delegating keeps that
/// output byte-identical (`groupThousands(4400)` -> `4.400`,
/// `groupThousands(190)` -> `190`, `groupThousands(52871)` -> `52.871`).
///
/// A non-finite [v] prints [kNonFiniteNumber].
String groupThousands(num v, {String separator = '.'}) {
  if (v is double && !v.isFinite) return kNonFiniteNumber;
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
/// half-away-from-zero) so the integer part and fraction stay consistent. A
/// value that ROUNDS to zero prints unsigned (`money(-0.004, dp: 2)` ->
/// `0,00`, never `-0,00`), consistent with [groupThousands]; a non-finite [v]
/// prints [kNonFiniteNumber].
String money(
  num v, {
  int dp = 0,
  String groupSeparator = '.',
  String decimalSeparator = ',',
}) {
  if (v is double && !v.isFinite) return kNonFiniteNumber;
  final fixed = v.toStringAsFixed(dp); // e.g. "3703.68", "1181250", "-12.00"
  final signed = fixed.startsWith('-');
  final abs = signed ? fixed.substring(1) : fixed;
  // Drop the sign of a value that rounded to zero ("-0", "-0.00").
  final neg = signed && abs.contains(RegExp(r'[1-9]'));
  final dot = abs.indexOf('.');
  final intDigits = dot < 0 ? abs : abs.substring(0, dot);
  final frac = dot < 0 ? '' : abs.substring(dot + 1);
  final grouped = groupThousands(int.parse(intDigits), separator: groupSeparator);
  final body = frac.isEmpty ? grouped : '$grouped$decimalSeparator$frac';
  return '${neg ? '-' : ''}$body';
}

/// Round 9 (report-parity-quotation-separators) — a client-facing QUANTITY
/// (metres, pieces, labour hours) in the SAME convention as [money], so one
/// proposal row never mixes `1234.57` (dot = decimal) beside `45.000,00`
/// (dot = thousands). Whole → grouped integer (`1234` → `1.234`); else 2 dp
/// with trailing fraction zeros trimmed (`1234.567` → `1.234,57`, `246.9` →
/// `246,9`). A non-finite [v] prints [kNonFiniteNumber].
String quantity(
  num v, {
  String groupSeparator = '.',
  String decimalSeparator = ',',
}) {
  if (v is double && !v.isFinite) return kNonFiniteNumber;
  if (v == v.roundToDouble()) {
    return groupThousands(v, separator: groupSeparator);
  }
  var s = money(v,
      dp: 2, groupSeparator: groupSeparator, decimalSeparator: decimalSeparator);
  while (s.contains(decimalSeparator) && s.endsWith('0')) {
    s = s.substring(0, s.length - 1);
  }
  if (s.endsWith(decimalSeparator)) s = s.substring(0, s.length - 1);
  return s;
}

/// A signed elevation figure with two decimals — `+4.00`, `-3.20`, and `+0.00`
/// for anything that rounds to zero (never `-0.00` / `+-3.20`). ONE formatter
/// for every FFL notation (mechanical + electrical risers, the plan hover chip)
/// so the issued drawings of one building agree on below-ground levels.
String signedElevationText(double meters) {
  final s = meters.abs().toStringAsFixed(2);
  return (meters < 0 && s != '0.00') ? '-$s' : '+$s';
}
