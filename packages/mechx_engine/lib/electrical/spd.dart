/// Surge Protective Device (SPD) selection (A8 advanced pass).
///
/// Ported from PanelMaker `engine/spd.ts` + `standards/spd.ts`. Given whether
/// the device sits at the service origin, the feeder distance from the origin
/// SPD, the earthing system and the lightning / overhead-line exposure, returns
/// the recommended SPD class (Type 1 / 1+2 / 2), the Uc / Up / Uw values and the
/// connection arrangement.
///
/// Decision summary:
///  - At the origin (main board / service entrance): external LPS or overhead /
///    direct-strike exposure → Type 1 (encoded as combined Type 1+2 so one unit
///    also gives the board its Type 2 protection); otherwise Type 2.
///  - Sub-distribution (`atOrigin = false`): Type 2; beyond
///    [secondarySpdDistanceM] (10 m) of feeder a secondary Type 2 is needed
///    because the origin device no longer covers the sub-board (oscillation
///    doubling, IEC 61643-12).
///  - Uc / connection by earthing system: TT → "3+1" with a higher N-PE Uc;
///    TN-S / TN-C-S → common-mode 275 V modules.
///
/// References: IEC 61643-11, IEC 60364-5-534 / -4-44 §443, PUIL 2011 §3.20.
/// The IEC family is `secondarySource`; the ratings are representative
/// catalogue defaults. See [SpdRecommendation.verifyItems].
///
/// Zero Flutter imports.
library;

/// Beyond this feeder distance from the origin SPD, the origin protection no
/// longer covers the sub-board (oscillation doubling, IEC 61643-12) — a
/// secondary Type 2 SPD is recommended there. // VERIFY secondarySource (IEC).
const double secondarySpdDistanceM = 10;

/// Maximum continuous operating voltage Uc (L-N), volts, for a 230/400 V TN
/// system (≥ 1.1·U0 = 253 V). // VERIFY secondarySource (IEC 61643-11).
const double ucTnV = 275;

/// Uc for the N-PE path in a TT "3+1" arrangement — the N-PE module must
/// withstand √3·U0 ≈ 398 V under fault, so 335 V (common N-PE spark-gap rating)
/// is used. // VERIFY secondarySource (IEC 60364-5-534).
const double ucTtNpeV = 335;

/// Comfortable protection-level target Up at the equipment (V) — ≈ 0.6·Uw for
/// cat II. // VERIFY secondarySource (IEC 60364-4-44 §443).
const double upTargetGoodV = 1500;

/// Upper acceptable bound on Up at the equipment (V) = cat II Uw (2.5 kV).
/// // VERIFY secondarySource.
const double upTargetAcceptableV = 2500;

/// SPD test class / type per IEC 61643-11.
enum SpdType { type1, type2, type3, type1plus2 }

extension SpdTypeLabel on SpdType {
  String get label => switch (this) {
        SpdType.type1 => 'Type 1',
        SpdType.type2 => 'Type 2',
        SpdType.type3 => 'Type 3',
        SpdType.type1plus2 => 'Type 1+2',
      };
}

/// SPD connection arrangement (IEC 60364-5-534 §534.2).
enum SpdConnection { commonMode, threePlusOne }

extension SpdConnectionInfo on SpdConnection {
  String get note => switch (this) {
        SpdConnection.commonMode =>
          'Connect each line (and N where present) to PE via an SPD '
              '(common-mode / "4+0" arrangement).',
        SpdConnection.threePlusOne =>
          '"3+1" connection: each line to N via a class-II varistor, and N to PE '
              'via a class-I spark-gap. Holds the higher N-PE temporary '
              'overvoltage off the line modules and stays RCD-compatible.',
      };
}

/// How a device Up rates against the cat II coordination target.
enum SpdProtectionRating { good, acceptable, inadequate }

/// Classify a Up value (kV) against the cat II coordination targets.
SpdProtectionRating ratePup(double upKv) {
  final upV = upKv * 1000;
  if (upV <= upTargetGoodV) return SpdProtectionRating.good;
  if (upV <= upTargetAcceptableV) return SpdProtectionRating.acceptable;
  return SpdProtectionRating.inadequate;
}

/// Representative ratings for an SPD type (currents kA, voltages kV / V).
class _SpdRating {
  final double? iimpKa; // Type 1 Class I impulse (10/350 µs), kA/pole
  final double? inKa; // Class II nominal discharge (8/20 µs), kA
  final double? imaxKa; // Class II maximum discharge (8/20 µs), kA
  final double? uocKv; // Type 3 open-circuit voltage (combination wave), kV
  final double upKv; // voltage protection level Up at the device, kV
  const _SpdRating({this.iimpKa, this.inKa, this.imaxKa, this.uocKv, required this.upKv});
}

const Map<SpdType, _SpdRating> _ratings = {
  SpdType.type1: _SpdRating(iimpKa: 12.5, upKv: 1.5),
  SpdType.type2: _SpdRating(inKa: 20, imaxKa: 40, upKv: 1.2),
  SpdType.type3: _SpdRating(uocKv: 6, upKv: 1.0),
  SpdType.type1plus2:
      _SpdRating(iimpKa: 12.5, inKa: 20, imaxKa: 40, upKv: 1.5),
};

/// SPD recommendation for a location.
class SpdRecommendation {
  /// Whether an SPD is recommended for this location.
  final bool recommended;

  /// Selected SPD class.
  final SpdType type;

  /// Where the SPD is installed (origin / sub-distribution).
  final String location;

  /// Maximum continuous operating voltage Uc, L-N (V).
  final double ucV;

  /// N-PE Uc for a "3+1" arrangement (V), when applicable.
  final double? npeUcV;

  /// Class I impulse current Iimp (10/350 µs), kA/pole — Type 1 only.
  final double? iimpKa;

  /// Class II nominal discharge current In (8/20 µs), kA.
  final double? inKa;

  /// Class II maximum discharge current Imax (8/20 µs), kA.
  final double? imaxKa;

  /// Class III open-circuit voltage Uoc (combination wave), kV — Type 3.
  final double? uocKv;

  /// Voltage protection level Up of the device (kV).
  final double upKv;

  /// Coordinated protection-level ceiling at the equipment terminals (kV).
  final double upKvMax;

  /// Connection arrangement.
  final SpdConnection connection;

  /// How the device Up rates against the cat II coordination target.
  final SpdProtectionRating protectionRating;

  /// Human-readable rationale.
  final String note;

  /// Honesty surface — the standards tier behind this recommendation.
  final List<String> verifyItems;

  const SpdRecommendation({
    required this.recommended,
    required this.type,
    required this.location,
    required this.ucV,
    this.npeUcV,
    this.iimpKa,
    this.inKa,
    this.imaxKa,
    this.uocKv,
    required this.upKv,
    required this.upKvMax,
    required this.connection,
    required this.protectionRating,
    required this.note,
    required this.verifyItems,
  });
}

/// Normalise an earthing-system string ("TT" / "TN-S" / "TN-C-S", any case) to
/// the Uc + connection. TT (and TN where the N-PE path can see √3·U0 under
/// fault) use "3+1" with a higher N-PE Uc; TN-S / TN-C-S use common-mode.
({double ucV, double? npeUcV, SpdConnection connection}) _ucForEarthing(
    String earthingSystem) {
  final s = earthingSystem.toUpperCase().replaceAll(RegExp(r'[^A-Z]'), '');
  if (s == 'TT') {
    return (ucV: ucTnV, npeUcV: ucTtNpeV, connection: SpdConnection.threePlusOne);
  }
  return (ucV: ucTnV, npeUcV: null, connection: SpdConnection.commonMode);
}

String _connectionText(SpdConnection connection, double? npeUcV) {
  final base = connection.note;
  if (connection == SpdConnection.threePlusOne && npeUcV != null) {
    return '$base N-PE module Uc >= ${_num(npeUcV)} V.';
  }
  return base;
}

/// Recommend an SPD class, rating and connection for a location.
///
/// Deterministic and pure. [feederDistanceM] is the feeder length from the
/// origin SPD (only consulted for sub-distribution boards). [hasExternalLps] /
/// [overheadSupply] force a Type 1 device at the origin.
SpdRecommendation recommendSpd({
  required bool atOrigin,
  required double feederDistanceM,
  required String earthingSystem,
  bool hasExternalLps = false,
  bool overheadSupply = false,
}) {
  final directStrikeRisk = hasExternalLps || overheadSupply;
  final uc = _ucForEarthing(earthingSystem);

  final SpdType type;
  final String location;
  final bool recommended;
  if (atOrigin) {
    type = directStrikeRisk ? SpdType.type1plus2 : SpdType.type2;
    location = 'Origin (main distribution board / service entrance)';
    recommended = true;
  } else {
    type = SpdType.type2;
    location =
        'Sub-distribution board (coordinated downstream of the origin SPD)';
    // The origin SPD covers a short feeder; beyond ~10 m a secondary SPD is
    // genuinely needed. Within the distance one is optional (still returned,
    // marked not strictly required).
    recommended = feederDistanceM > secondarySpdDistanceM;
  }

  final rating = _ratings[type]!;
  final protectionRating = ratePup(rating.upKv);
  final upKvMax =
      (protectionRating == SpdProtectionRating.good ? upTargetGoodV : upTargetAcceptableV) /
          1000;

  final String note;
  if (atOrigin) {
    if (directStrikeRisk) {
      final cause = hasExternalLps
          ? 'the building has an external Lightning Protection System'
          : 'the supply is via an overhead line (direct-strike exposure)';
      note = 'Type 1 (combined Type 1+2) at the origin because $cause; it '
          'conducts the partial-lightning impulse current (Iimp, 10/350 us) and '
          'also provides the main-board Type 2 protection. '
          '${_connectionText(uc.connection, uc.npeUcV)}';
    } else {
      note = 'Type 2 at the main distribution board (no external LPS or '
          'overhead-line exposure). Standard origin overvoltage protection '
          'against switching and indirect lightning surges. '
          '${_connectionText(uc.connection, uc.npeUcV)}';
    }
  } else if (recommended) {
    note = 'Sub-board is ${_num(feederDistanceM)} m (> $secondarySpdDistanceM m) '
        'from the origin SPD - fit a coordinated Type 2 here; add a Type 3 '
        'stage before sensitive equipment on long final circuits. '
        '${_connectionText(uc.connection, uc.npeUcV)}';
  } else {
    note = 'Sub-board within $secondarySpdDistanceM m of the origin SPD - the '
        'origin device still covers it; a local Type 2 is optional. '
        '${_connectionText(uc.connection, uc.npeUcV)}';
  }

  return SpdRecommendation(
    recommended: recommended,
    type: type,
    location: location,
    ucV: uc.ucV,
    npeUcV: uc.npeUcV,
    iimpKa: rating.iimpKa,
    inKa: rating.inKa,
    imaxKa: rating.imaxKa,
    uocKv: rating.uocKv,
    upKv: rating.upKv,
    upKvMax: upKvMax,
    connection: uc.connection,
    protectionRating: protectionRating,
    note: note,
    verifyItems: const [
      'SPD selection follows the IEC family (IEC 61643-11, IEC 60364-5-534 / '
          '-4-44 §443) referenced by PUIL 2011 §3.20 - secondarySource, pending '
          'the official clause. Ratings (Iimp/In/Imax/Uc/Up) are representative '
          'catalogue defaults; confirm against the chosen device datasheet.',
    ],
  );
}

String _num(double v) =>
    v == v.roundToDouble() ? v.toInt().toString() : v.toString();
