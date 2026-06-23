/// Revenue / sub-metering selection (A8 advanced pass).
///
/// Ported from PanelMaker `engine/metering.ts` + `standards/metering.ts`.
/// From a board's demand current, picks whole-current (direct) kWh metering up
/// to the standard 100 A limit, or CT-operated metering above it — choosing the
/// CT primary from the standard ladder (secondary 5 A) and the revenue accuracy
/// class.
///
/// References: PLN service-connection practice (direct vs CT metering). The
/// 100 A direct limit, the CT primary ladder and the 0.5S accuracy class are
/// Indonesian utility practice, not a verbatim SNI/PUIL clause — tagged
/// `// VERIFY` and surfaced in [MeteringSpec.verifyItems].
///
/// Zero Flutter imports.
library;

import '../units.dart' show Current;

/// Direct (whole-current) kWh-meter limit (A); above it metering is CT-operated.
/// // VERIFY notAnSniClause (PLN practice).
const double directMeterMaxA = 100;

/// Standard metering CT primary ratings (A), secondary 5 A, ascending.
/// // VERIFY notAnSniClause (standard CT ladder).
const List<double> ctPrimaryA = [
  50, 75, 100, 150, 200, 250, 300, 400, 500, 600, 800, 1000, 1250, 1600, 2000, 2500,
];

/// Revenue-metering CT accuracy class. // VERIFY notAnSniClause.
const String meteringCtClass = '0.5S';

/// Metering type.
enum MeteringKind { direct, ct }

extension MeteringKindLabel on MeteringKind {
  String get label =>
      this == MeteringKind.direct ? 'direct' : 'ct';
}

/// A board's metering specification.
class MeteringSpec {
  /// Whole-current (direct) meter, or CT-operated above the direct limit.
  final MeteringKind metering;

  /// Demand current the selection was made for (A).
  final Current demandCurrent;

  /// CT primary rating (A) when CT-operated, else null.
  final double? ctPrimaryA;

  /// CT ratio string, e.g. "150/5", when CT-operated.
  final String? ctRatio;

  /// CT accuracy class for revenue metering, when CT-operated.
  final String? ctClass;

  final String note;

  /// Honesty surface — the practice tier behind this selection.
  final List<String> verifyItems;

  const MeteringSpec({
    required this.metering,
    required this.demandCurrent,
    this.ctPrimaryA,
    this.ctRatio,
    this.ctClass,
    required this.note,
    required this.verifyItems,
  });
}

const List<String> _verifyItems = [
  'Metering selection (100 A direct limit, CT primary ladder, 0.5S revenue '
      'class) is Indonesian utility (PLN) practice - NOT a verbatim SNI/PUIL '
      'clause. Confirm the metering scheme with the supply authority.',
];

/// Select metering for a board from its demand current: a direct (whole-current)
/// kWh meter up to [directMeterMaxA], CT-operated above it.
MeteringSpec meterFor(Current demand) {
  final a = demand.amperes;
  if (a <= directMeterMaxA) {
    return MeteringSpec(
      metering: MeteringKind.direct,
      demandCurrent: demand,
      note: 'Direct (whole-current) kWh metering at '
          '${_num(_round(a, 1))} A (<= ${_num(directMeterMaxA)} A).',
      verifyItems: _verifyItems,
    );
  }
  final primary = ctPrimaryA.cast<double?>().firstWhere(
        (p) => p! >= a,
        orElse: () => ctPrimaryA.last,
      )!;
  final ratio = '${_num(primary)}/5';
  return MeteringSpec(
    metering: MeteringKind.ct,
    demandCurrent: demand,
    ctPrimaryA: primary,
    ctRatio: ratio,
    ctClass: meteringCtClass,
    note: 'CT-operated kWh metering, $ratio class $meteringCtClass '
        '(demand current ${_num(_round(a, 1))} A).',
    verifyItems: _verifyItems,
  );
}

double _round(double v, int dp) {
  var f = 1.0;
  for (var i = 0; i < dp; i++) {
    f *= 10;
  }
  return (v * f).round() / f;
}

String _num(double v) =>
    v == v.roundToDouble() ? v.toInt().toString() : v.toString();
