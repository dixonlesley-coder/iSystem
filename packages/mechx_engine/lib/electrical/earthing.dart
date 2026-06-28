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

  const RcdSpec({
    required this.required,
    required this.ratingMa,
    required this.reason,
    this.type,
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
  final groups = <({double size, int n})>[];
  for (final size in conductors) {
    if (groups.isNotEmpty && groups.last.size == size) {
      final last = groups.removeLast();
      groups.add((size: last.size, n: last.n + 1));
    } else {
      groups.add((size: size, n: 1));
    }
  }
  final makeup = groups
      .map((g) => g.n > 1 ? '${g.n}×${_num(g.size)}' : _num(g.size))
      .join(' + ');

  final prefix = runsPerPhase > 1 ? '$runsPerPhase× ' : '';
  return GroundingResult(
    peCsaMm2: pe,
    neutralCsaMm2: neutral,
    cores: cores,
    cableSpec: '$prefix$type $makeup mm²',
    cableType: type,
  );
}

/// Design the installation earthing system: RCD policy, main earthing + bonding
/// conductors and the electrode-resistance target. (Electrode rod-array design
/// to reach the target is an A8 refinement.)
EarthingResult computeEarthing(
  ElectricalStandardsProfile profile, {
  required EarthingSystem system,
  required double supplyPeMm2,
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
    mainEarthingConductorMm2: profile.mainEarthingConductorMm2(supplyPeMm2),
    mainBondingConductorMm2: profile.mainBondingConductorMm2(supplyPeMm2),
    electrodeResistanceTarget: profile.maxEarthResistance.value,
    note: system.note + tail,
  );
}

/// Decide whether a circuit needs an RCD, at what sensitivity, and which type.
RcdSpec circuitRcd({
  required EarthingSystem earthingSystem,
  required LoadKind loadKind,
  required bool isFinalCircuit,
  required Current designCurrent,
  bool lifeSafety = false,
  bool hasVfd = false,
}) {
  RcdType rcdType() =>
      recommendedRcdType(loadKind, hasVfd: hasVfd, isEvCharger: loadKind == LoadKind.evCharger)
          .type;

  // A spare way has no load and no cable run — nothing to protect.
  if (loadKind == LoadKind.spare) {
    return const RcdSpec(required: false, ratingMa: 0, reason: '');
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
    return RcdSpec(
      required: true,
      ratingMa: 300,
      reason:
          'TT feeder — time-delayed (S-type) RCD for earth-fault protection, '
          'selective above the downstream final RCDs (no ADS on the TT loop). '
          '// VERIFY',
      type: rcdType(),
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
