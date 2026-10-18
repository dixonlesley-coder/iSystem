/// Locale-aware parsing of a typed money / rate figure (audit r8 costing-3).
///
/// The product's issued notation (`report/number_format.dart` `money()`) is
/// Indonesian — `.` groups thousands, `,` marks decimals — so an engineer types
/// `12.500` for twelve thousand five hundred rupiah. The old English-only
/// parse (`double.tryParse(s.replaceAll(',', ''))`) read that as 12.5 and
/// silently DELETED a price typed as `1.250.000` (unparseable → cleared).
///
/// Rules (deterministic, structure first, locale only breaks a tie):
///  * both `.` and `,` present → the LAST one is the decimal separator, the
///    other groups thousands (`1.250.000,50` and `1,250,000.50` both work);
///  * one separator kind appearing MORE than once → it groups thousands;
///  * a single separator followed by exactly three digits is ambiguous
///    (`12.500` / `12,500`) → it groups thousands when it is the locale's
///    grouping mark (ID `.`, EN `,`), else it is the decimal mark;
///  * any other single separator is the decimal mark.
/// Returns null for anything that is not a well-formed non-negative number.
library;

double? parseMoneyInput(String input, {required bool indonesian}) {
  var s = input.trim().replaceAll(' ', '').replaceAll(' ', '');
  if (s.isEmpty) return null;
  if (!RegExp(r'^[0-9.,]+$').hasMatch(s)) return null;
  final dots = '.'.allMatches(s).length;
  final commas = ','.allMatches(s).length;

  String? decimal; // the decimal separator, if any
  if (dots > 0 && commas > 0) {
    decimal = s.lastIndexOf('.') > s.lastIndexOf(',') ? '.' : ',';
    final group = decimal == '.' ? ',' : '.';
    if (decimal.allMatches(s).length > 1) return null;
    // The grouping mark must not appear after the decimal mark.
    if (s.lastIndexOf(group) > s.indexOf(decimal)) return null;
    s = s.replaceAll(group, '');
  } else if (dots + commas > 0) {
    final sep = dots > 0 ? '.' : ',';
    final count = dots > 0 ? dots : commas;
    if (count > 1) {
      // Several marks of one kind ⇒ thousands grouping; every group after the
      // first must be exactly three digits.
      final parts = s.split(sep);
      if (parts.first.isEmpty ||
          parts.skip(1).any((p) => p.length != 3)) {
        return null;
      }
      s = s.replaceAll(sep, '');
    } else {
      final tail = s.substring(s.indexOf(sep) + 1);
      final localeGroup = indonesian ? '.' : ',';
      if (tail.length == 3 && sep == localeGroup && s.indexOf(sep) > 0) {
        s = s.replaceAll(sep, '');
      } else {
        decimal = sep;
      }
    }
  }
  if (decimal != null) s = s.replaceAll(decimal, '.');
  if (s.startsWith('.') || s.endsWith('.')) return null;
  return double.tryParse(s);
}
