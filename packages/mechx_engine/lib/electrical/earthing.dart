/// Earthing / protective-conductor + RCD logic — ported from PanelMaker
/// `engine/grounding.ts` + `standards/rcdType.ts`. Sizes the PE/neutral cable
/// make-up, the installation earthing system (RCD policy + main earthing/bonding
/// conductors + electrode target), and the per-circuit RCD (sensitivity + type).
///
/// The driven-rod electrode ARRAY design (count to reach the target Ω, from soil
/// resistivity) is deferred to a later step — `computeEarthing` reports the
/// target; the array sizing is an A8 refinement.
///
/// Zero Flutter imports.
library;

import '../standards/puil.dart';
import '../units.dart';
import 'load_kind.dart';

/// Installation earthing system (IEC 60364 / PUIL).
enum EarthingSystem { tnCs, tnS, tt }

extension EarthingSystemInfo on EarthingSystem {
  String get label => switch (this) {
        EarthingSystem.tnCs => 'TN-C-S (PME)',
        EarthingSystem.tnS => 'TN-S',
        EarthingSystem.tt => 'TT',
      };

  String get note => switch (this) {
        EarthingSystem.tnCs =>
          'Combined PEN from the source, split into separate N and PE at the '
              'origin. Common PLN practice.',
        EarthingSystem.tnS =>
          'Separate neutral and protective conductors throughout the installation.',
        EarthingSystem.tt =>
          'Installation earthed via a local electrode; requires RCD protection. '
              'Common for standalone/rural sites.',
      };
}

/// PLN PME practice default.
const EarthingSystem defaultEarthingSystem = EarthingSystem.tnCs;

/// RCD waveform type (IEC 60364-4-41 / IEC 62423 / IEC 61008/61009), increasing
/// capability AC ⊂ A ⊂ F ⊂ B.
enum RcdType { ac, a, f, b }

/// Capability ordering — a higher rank covers every waveform a lower one does.
int rcdTypeRank(RcdType t) => switch (t) {
      RcdType.ac => 0,
      RcdType.a => 1,
      RcdType.f => 2,
      RcdType.b => 3,
    };

String _rcdTypeCode(RcdType t) => switch (t) {
      RcdType.ac => 'AC',
      RcdType.a => 'A',
      RcdType.f => 'F',
      RcdType.b => 'B',
    };

/// Recommend the minimum-suitable RCD *type* from the load's nature. Never
/// returns [RcdType.ac] (deprecated for general use). The mA sensitivity is set
/// separately by [circuitRcd].
({RcdType type, String reason}) recommendedRcdType(
  LoadKind loadKind, {
  bool hasVfd = false,
  bool isEvCharger = false,
}) {
  if (isEvCharger || loadKind == LoadKind.evCharger) {
    return (
      type: RcdType.b,
      reason:
          'EV charging — Type B RCD for smooth DC fault current (IEC 60364-7-722); '
              'Type A + 6 mA DC RDC-DD acceptable.',
    );
  }
  if (hasVfd) {
    return (
      type: RcdType.b,
      reason:
          'Variable-speed drive / 3-phase rectifier — Type B RCD for smooth DC '
              'residual current (IEC 62423).',
    );
  }
  switch (loadKind) {
    case LoadKind.general:
    case LoadKind.socket:
    case LoadKind.ups:
      return (
        type: RcdType.a,
        reason:
            'Electronic loads present — Type A RCD for pulsating DC residual '
                'current (IEC 60364-4-41 §531.3.3).',
      );
    case LoadKind.lighting:
    case LoadKind.heating:
      return (
        type: RcdType.a,
        reason:
            'Type A RCD — Type AC no longer recommended even for resistive/'
                'lighting circuits (electronic drivers/ballasts).',
      );
    default:
      return (
        type: RcdType.a,
        reason:
            'Type A RCD — modern minimum (Type AC deprecated for general use; '
                'IEC 60364-4-41 §531.3.3).',
      );
  }
}

/// PE/neutral cable make-up for a circuit.
class GroundingResult {
  final double peCsaMm2;

  /// Neutral section (mm²); 0 when the circuit has no neutral.
  final double neutralCsaMm2;

  /// Total conductor count, incl. PE.
  final int cores;

  /// Human-readable make-up, e.g. "NYY 4×50 + 25 mm²".
  final String cableSpec;

  /// Effective cable construction/type label.
  final String cableType;

  const GroundingResult({
    required this.peCsaMm2,
    required this.neutralCsaMm2,
    required this.cores,
    required this.cableSpec,
    required this.cableType,
  });
}

/// Per-circuit RCD decision.
class RcdSpec {
  final bool required;
  final int ratingMa;
  final String reason;
  final RcdType? type;

  /// True when the device must be TIME-DELAYED (S-type, selective) — the TT
  /// feeder's 300 mA RCD (Round 19: the BOM must not order an instantaneous
  /// device for it).
  final bool timeDelayed;

  const RcdSpec({
    required this.required,
    required this.ratingMa,
    required this.reason,
    this.type,
    this.timeDelayed = false,
  });
}

/// Installation-level earthing design.
class EarthingResult {
  final EarthingSystem system;
  final String label;
  final bool requiresRcd;
  final double mainEarthingConductorMm2;
  final double mainBondingConductorMm2;
  final Resistance electrodeResistanceTarget;
  final String note;

  const EarthingResult({
    required this.system,
    required this.label,
    required this.requiresRcd,
    required this.mainEarthingConductorMm2,
    required this.mainBondingConductorMm2,
    required this.electrodeResistanceTarget,
    required this.note,
  });
}

String _num(double v) =>
    v == v.roundToDouble() ? v.toInt().toString() : v.toString();

/// The ONE conductor-grouping rule behind every printed cable make-up (Round
/// 19 review follow-up): consecutive equal sections collapse to `N×size`
/// (`[35, 35, 35, 35, 16]` → `4×35 + 16`). The BOM description
/// ([GroundingResult.cableSpec], unicode `×` / ` + `) and the drawing labels
/// (`cableLabel`, ASCII `x` / `+`) both call it with their own glyphs, so the
/// two can differ only in typography, never in the grouping.
String groupedConductorMakeup(
  List<double> conductors,
  String Function(double) format, {
  required String times,
  required String separator,
}) {
  final groups = <({double size, int n})>[];
  for (final size in conductors) {
    if (groups.isNotEmpty && groups.last.size == size) {
      final last = groups.removeLast();
      groups.add((size: last.size, n: last.n + 1));
    } else {
      groups.add((size: size, n: 1));
    }
  }
  return groups
      .map((g) => g.n > 1 ? '${g.n}$times${format(g.size)}' : format(g.size))
      .join(separator);
}

/// Size the PE + neutral conductors and describe the cable make-up.
/// 1φ = L+N+PE; 3φ = 3L+N+PE (or 3L+PE without a neutral, e.g. motors). With
/// parallel runs the make-up is per run, prefixed with the run count.
GroundingResult sizeGrounding(
  ElectricalStandardsProfile profile, {
  required double phaseCsaMm2,
  required bool threePhase,
  bool hasNeutral = true,
  String? cableType,
  bool reducedNeutral = false,
  int runsPerPhase = 1,
}) {
  final pe = profile.peConductorSizeMm2(phaseCsaMm2);
  final neutral = hasNeutral
      ? profile.neutralConductorSizeMm2(phaseCsaMm2, reduced: reducedNeutral)
      : 0.0;

  final liveCores = threePhase ? 3 : 1;
  final cores = liveCores + (hasNeutral ? 1 : 0) + 1;
  final type = cableType ?? (threePhase ? 'NYY' : 'NYM');

  final conductors = <double>[
    for (var i = 0; i < liveCores; i++) phaseCsaMm2,
    if (hasNeutral) neutral,
    pe,
  ];
  final makeup =
      groupedConductorMakeup(conductors, _num, times: '×', separator: ' + ');

  final prefix = runsPerPhase > 1 ? '$runsPerPhase× ' : '';
  return GroundingResult(
    peCsaMm2: pe,
    neutralCsaMm2: neutral,
    cores: cores,
    cableSpec: '$prefix$type $makeup mm²',
    cableType: type,
  );
}

/// Round 24 — a TN service's main earthing conductor (mm²): the service PE
/// summed over its parallel runs (`supplyPeMm2 × runsPerPhase`), floored at
/// 16 mm² and snapped up the standard section ladder (an equivalent section
/// above the ladder's top is returned as-is). See [computeEarthing].
double tnMainEarthingConductorMm2(
  ElectricalStandardsProfile profile,
  double supplyPeMm2, {
  int runsPerPhase = 1,
}) {
  final total = supplyPeMm2 * (runsPerPhase < 1 ? 1 : runsPerPhase);
  final target = total > 16 ? total : 16.0;
  for (final s in profile.standardSectionsMm2) {
    if (s >= target - 1e-9) return s;
  }
  return target;
}

/// Design the installation earthing system: RCD policy, main earthing + bonding
/// conductors and the electrode-resistance target. (Electrode rod-array design
/// to reach the target is an A8 refinement.)
///
/// Round 24 — the main EARTHING conductor on a TN service follows the
/// service's protective conductor (IEC 60364-5-54 §542.3.1 → §543.1, Table
/// 54.7: the whole PE of the service cable — [supplyPeMm2] per run ×
/// [runsPerPhase] parallel runs), floored at 16 mm², snapped up the standard
/// section ladder, NEVER capped at 50 mm² (the earth-fault current of a
/// TN-C-S service returns through it). The 16..50 clamp
/// ([ElectricalStandardsProfile.mainEarthingConductorMm2]) is kept for the
/// TT electrode conductor only. // VERIFY (secondarySource)
EarthingResult computeEarthing(
  ElectricalStandardsProfile profile, {
  required EarthingSystem system,
  required double supplyPeMm2,
  int runsPerPhase = 1,
}) {
  final requiresRcd = system == EarthingSystem.tt;
  final tail = requiresRcd
      ? ' Earth-fault loop impedance is high, so an RCD provides fault '
          'protection on every final circuit.'
      : ' Overcurrent devices clear earth faults; RCDs are still required for '
          'socket-outlets and special locations.';
  return EarthingResult(
    system: system,
    label: system.label,
    requiresRcd: requiresRcd,
    mainEarthingConductorMm2: system == EarthingSystem.tt
        ? profile.mainEarthingConductorMm2(supplyPeMm2)
        : tnMainEarthingConductorMm2(profile, supplyPeMm2,
            runsPerPhase: runsPerPhase),
    mainBondingConductorMm2: profile.mainBondingConductorMm2(supplyPeMm2),
    electrodeResistanceTarget: profile.maxEarthResistance.value,
    note: system.note + tail,
  );
}

/// Round 24 — the TT feeder RCD sensitivity ladder (mA): a feeder with NO
/// RCD-bearing feeder below it sits at 300 mA (≥ 3 × the 30 / 100 mA finals);
/// each further RCD feeder level below steps it up the standard IΔn series
/// (300 → 1000 → 3000 → 10000 mA) so the upstream device keeps the ≥ 3 × IΔn
/// ratio of IEC 60364-5-53 §535.3 discrimination. // VERIFY
int ttFeederRcdMa(int rcdFeederLevelsBelow) {
  const ladder = [300, 1000, 3000, 10000];
  return ladder[rcdFeederLevelsBelow.clamp(0, ladder.length - 1)];
}

/// Round 24 — the TOPOLOGY a TT feeder's RCD must respect, derived bottom-up
/// over the board it feeds by `computeSystem`:
///   * [downstreamType] — the highest RCD type anywhere in the fed sub-tree
///     (B > F > A > AC): a Type A device upstream of a Type B load is blinded
///     by smooth DC residual current (IEC 60364-5-53 §531.3.3), so the feeder
///     takes at least that type;
///   * [rcdFeederLevelsBelow] — how many RCD-bearing feeder levels sit below
///     it (the sensitivity ladder [ttFeederRcdMa]);
///   * [lifeSafetyOnly] — every load way in the sub-tree is life-safety: a
///     tripping RCD on the feeder would defeat their deliberate RCD omission
///     (a fire pump must not stop on an earth fault).
typedef TtFeederRcdBasis = ({
  RcdType? downstreamType,
  int rcdFeederLevelsBelow,
  bool lifeSafetyOnly,
});

/// Decide whether a circuit needs an RCD, at what sensitivity, and which type.
/// [ttFeeder] (a TT feeder only) carries the fed sub-tree's topology — see
/// [TtFeederRcdBasis]; null ⇒ the single-level 300 mA rule (byte-identical).
RcdSpec circuitRcd({
  required EarthingSystem earthingSystem,
  required LoadKind loadKind,
  required bool isFinalCircuit,
  required Current designCurrent,
  bool lifeSafety = false,
  bool hasVfd = false,
  TtFeederRcdBasis? ttFeeder,
}) {
  RcdType rcdType() =>
      recommendedRcdType(loadKind, hasVfd: hasVfd, isEvCharger: loadKind == LoadKind.evCharger)
          .type;

  // A spare way has no load and no cable run — nothing to protect.
  if (loadKind == LoadKind.spare) {
    return const RcdSpec(required: false, ratingMa: 0, reason: '');
  }
  // Round 24 — a TT feeder whose whole sub-tree is life-safety takes no
  // tripping RCD either: it would stop the fire pump the downstream omission
  // protects. An RCM (residual-current MONITOR, alarm only) keeps the earth
  // fault visible without a trip.
  if (!lifeSafety &&
      !isFinalCircuit &&
      earthingSystem == EarthingSystem.tt &&
      (ttFeeder?.lifeSafetyOnly ?? false)) {
    return const RcdSpec(
      required: false,
      ratingMa: 0,
      reason: 'Feeder to a life-safety-only board — no tripping RCD (it would '
          'stop the fire pump on an earth fault); fit an RCM (residual-current '
          'monitor, alarm only). // VERIFY',
    );
  }
  // Life-safety: an earth-fault trip must not stop a fire pump mid-fire.
  if (lifeSafety) {
    return const RcdSpec(
      required: false,
      ratingMa: 0,
      reason:
          'Life-safety circuit — RCD deliberately omitted (availability prevails).',
    );
  }
  if (earthingSystem == EarthingSystem.tt && isFinalCircuit) {
    return RcdSpec(
      required: true,
      ratingMa: designCurrent.amperes <= 63 ? 30 : 100,
      reason: 'TT system — RCD required for earth-fault protection.',
      type: rcdType(),
    );
  }
  // A TT FEEDER (distribution circuit, not a final) still needs earth-fault
  // protection: the high TT earth-loop impedance means an overcurrent device
  // cannot guarantee disconnection (no ADS on a TT loop). A time-delayed
  // (S-type) 300 mA RCD provides it while discriminating above the 30/100 mA
  // RCDs on the downstream finals.
  if (earthingSystem == EarthingSystem.tt) {
    // Round 24 — at least the highest type downstream (a Type A device above
    // a Type B load is blinded by smooth DC), and a sensitivity that keeps
    // the ≥ 3 × IΔn ratio above every RCD feeder below it.
    final own = rcdType();
    final down = ttFeeder?.downstreamType;
    final raised = down != null && rcdTypeRank(down) > rcdTypeRank(own);
    final type = raised ? down : own;
    final levels = ttFeeder?.rcdFeederLevelsBelow ?? 0;
    final ma = ttFeederRcdMa(levels);
    final typeNote = raised
        ? ' Type ${_rcdTypeCode(type)}: a Type ${_rcdTypeCode(type)} device '
            'downstream (EV / VFD) — a lower type here would be blinded by its '
            'smooth DC residual current.'
        : '';
    final reason = levels == 0
        ? 'TT feeder — time-delayed (S-type) RCD for earth-fault protection, '
            'selective above the downstream final RCDs (no ADS on the TT loop). '
            '// VERIFY'
        : 'TT feeder — time-delayed RCD at $ma mA, ≥ 3 × the '
            '${ttFeederRcdMa(levels - 1)} mA time-delayed feeder RCD below it '
            'and set to a LONGER delay than it (IEC 60364-5-53 §535.3 '
            'discrimination; no ADS on the TT loop). // VERIFY';
    return RcdSpec(
      required: true,
      ratingMa: ma,
      reason: reason + typeNote,
      type: type,
      timeDelayed: true,
    );
  }
  if (loadKind == LoadKind.socket || loadKind == LoadKind.evCharger) {
    return RcdSpec(
      required: true,
      ratingMa: 30,
      reason: 'Socket / EV circuit — 30 mA RCD (additional protection).',
      type: rcdType(),
    );
  }
  return const RcdSpec(required: false, ratingMa: 0, reason: '');
}
