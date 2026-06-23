/// Motor-starter templates and the control-assembly assembler (IEC 60947-4-1).
/// Ported from PanelMaker `engine/control/applyStarterTemplate.ts` +
/// `standards/control/{starters,coordination}.ts` and `types/control.ts`.
///
/// `applyStarterTemplate` interprets a data-driven [StarterTemplate] for a motor
/// circuit: it sizes each gear slot (contactor / overload / VFD / control-tx),
/// resolves the declarative interlocks into concrete [Interlock]s referencing the
/// instantiated device ids, attaches the IEC 60947-4-1 Type-2 coordination set,
/// and runs the starting analysis. Pure and fully unit-testable.
///
/// PURE Dart — zero Flutter imports.
library;

import '../../units.dart';
import 'contactor.dart';
import 'control_gear.dart';
import 'motor_flc.dart';
import 'starting.dart';
import 'vfd.dart';

/// The kinds of motor starter / transfer scheme the engine can assemble.
/// Mirrors PanelMaker's `StarterType`.
enum StarterType {
  dol,
  starDelta,
  reversing,
  softStarter,
  vfd,
  ats,
  pump,
}

/// Functional category of a control device (drives default widths / icons).
enum DeviceCategory {
  contactor,
  overloadRelay,
  vfd,
  softStarter,
  breaker,
  controlTransformer,
  timerRelay,
  controlRelay,
  pilotDevice,
  indicatorLamp,
  phaseProtectionRelay,
  levelRelay,
  electrodeAssembly,
  floatSwitch,
  pressureTransmitter,
  alternatorRelay,
  levelSensor,
}

/// Interlock physical realisation.
enum InterlockKind { mechanical, electrical, keyCastell }

/// Interlock logical relation between two devices.
enum InterlockRelation { mutualExclusion, sequence, permissive }

/// How a device slot in a starter template is sized.
enum SizingRule {
  ac3FullFlc, // contactor at 100% motor FLC
  ac3StarWinding, // contactor at 58% FLC (star)
  overloadFlc, // overload set to FLC
  overloadStarFlc, // overload in delta leg, FLC × 0.58
  vfdOutput, // drive sized to FLC
  pilot, // pilot device, fixed
}

/// Declarative description of one piece of gear a template instantiates.
class DeviceSlot {
  final String role;
  final DeviceCategory category;
  final SizingRule sizing;
  final int qty;

  const DeviceSlot({
    required this.role,
    required this.category,
    required this.sizing,
    this.qty = 1,
  });
}

/// Declarative interlock requirement between two device roles in a template.
class InterlockSpec {
  final InterlockKind kind;
  final String roleA;
  final String roleB;
  final InterlockRelation relation;
  final String? note;

  const InterlockSpec({
    required this.kind,
    required this.roleA,
    required this.roleB,
    required this.relation,
    this.note,
  });
}

/// A data-driven starter template definition.
class StarterTemplate {
  final StarterType type;
  final String label;
  final List<DeviceSlot> deviceSlots;
  final List<InterlockSpec> interlocks;
  final bool controlTransformerRequired;

  /// Motor power range (kW) the starter is typically suited to.
  final List<double>? suitedKwRange;

  const StarterTemplate({
    required this.type,
    required this.label,
    required this.deviceSlots,
    required this.interlocks,
    required this.controlTransformerRequired,
    this.suitedKwRange,
  });
}

/// The data-driven starter templates. Adding a starter = adding a definition
/// here — no new control-flow code.
const Map<StarterType, StarterTemplate> starterTemplates = {
  StarterType.dol: StarterTemplate(
    type: StarterType.dol,
    label: 'Direct-On-Line',
    suitedKwRange: [0.37, 5.5],
    controlTransformerRequired: false,
    deviceSlots: [
      DeviceSlot(
          role: 'main-contactor',
          category: DeviceCategory.contactor,
          sizing: SizingRule.ac3FullFlc),
      DeviceSlot(
          role: 'overload',
          category: DeviceCategory.overloadRelay,
          sizing: SizingRule.overloadFlc),
      DeviceSlot(
          role: 'start-pb',
          category: DeviceCategory.pilotDevice,
          sizing: SizingRule.pilot),
      DeviceSlot(
          role: 'stop-pb',
          category: DeviceCategory.pilotDevice,
          sizing: SizingRule.pilot),
      DeviceSlot(
          role: 'run-lamp',
          category: DeviceCategory.indicatorLamp,
          sizing: SizingRule.pilot),
    ],
    interlocks: [],
  ),
  StarterType.starDelta: StarterTemplate(
    type: StarterType.starDelta,
    label: 'Star-Delta (Y-D)',
    suitedKwRange: [7.5, 55],
    controlTransformerRequired: true,
    deviceSlots: [
      DeviceSlot(
          role: 'main-contactor',
          category: DeviceCategory.contactor,
          sizing: SizingRule.ac3FullFlc),
      DeviceSlot(
          role: 'delta-contactor',
          category: DeviceCategory.contactor,
          sizing: SizingRule.ac3FullFlc),
      DeviceSlot(
          role: 'star-contactor',
          category: DeviceCategory.contactor,
          sizing: SizingRule.ac3StarWinding),
      DeviceSlot(
          role: 'overload',
          category: DeviceCategory.overloadRelay,
          sizing: SizingRule.overloadStarFlc),
      DeviceSlot(
          role: 'star-delta-timer',
          category: DeviceCategory.timerRelay,
          sizing: SizingRule.pilot),
      DeviceSlot(
          role: 'start-pb',
          category: DeviceCategory.pilotDevice,
          sizing: SizingRule.pilot),
      DeviceSlot(
          role: 'stop-pb',
          category: DeviceCategory.pilotDevice,
          sizing: SizingRule.pilot),
      DeviceSlot(
          role: 'run-lamp',
          category: DeviceCategory.indicatorLamp,
          sizing: SizingRule.pilot),
    ],
    interlocks: [
      InterlockSpec(
        kind: InterlockKind.mechanical,
        roleA: 'star-contactor',
        roleB: 'delta-contactor',
        relation: InterlockRelation.mutualExclusion,
        note: 'Star and delta must never close together (phase-to-phase short).',
      ),
      InterlockSpec(
        kind: InterlockKind.electrical,
        roleA: 'star-contactor',
        roleB: 'delta-contactor',
        relation: InterlockRelation.mutualExclusion,
        note: 'Cross-wired NC auxiliaries as redundant interlock.',
      ),
    ],
  ),
  StarterType.reversing: StarterTemplate(
    type: StarterType.reversing,
    label: 'Reversing (Fwd/Rev)',
    suitedKwRange: [0.37, 30],
    controlTransformerRequired: false,
    deviceSlots: [
      DeviceSlot(
          role: 'forward-contactor',
          category: DeviceCategory.contactor,
          sizing: SizingRule.ac3FullFlc),
      DeviceSlot(
          role: 'reverse-contactor',
          category: DeviceCategory.contactor,
          sizing: SizingRule.ac3FullFlc),
      DeviceSlot(
          role: 'overload',
          category: DeviceCategory.overloadRelay,
          sizing: SizingRule.overloadFlc),
      DeviceSlot(
          role: 'fwd-pb',
          category: DeviceCategory.pilotDevice,
          sizing: SizingRule.pilot),
      DeviceSlot(
          role: 'rev-pb',
          category: DeviceCategory.pilotDevice,
          sizing: SizingRule.pilot),
      DeviceSlot(
          role: 'stop-pb',
          category: DeviceCategory.pilotDevice,
          sizing: SizingRule.pilot),
    ],
    interlocks: [
      InterlockSpec(
        kind: InterlockKind.mechanical,
        roleA: 'forward-contactor',
        roleB: 'reverse-contactor',
        relation: InterlockRelation.mutualExclusion,
        note: 'Forward and reverse must never close together.',
      ),
      InterlockSpec(
        kind: InterlockKind.electrical,
        roleA: 'forward-contactor',
        roleB: 'reverse-contactor',
        relation: InterlockRelation.mutualExclusion,
      ),
    ],
  ),
  StarterType.softStarter: StarterTemplate(
    type: StarterType.softStarter,
    label: 'Soft Starter',
    suitedKwRange: [5.5, 250],
    controlTransformerRequired: false,
    deviceSlots: [
      DeviceSlot(
          role: 'soft-starter',
          category: DeviceCategory.softStarter,
          sizing: SizingRule.vfdOutput),
      DeviceSlot(
          role: 'bypass-contactor',
          category: DeviceCategory.contactor,
          sizing: SizingRule.ac3FullFlc),
      DeviceSlot(
          role: 'overload',
          category: DeviceCategory.overloadRelay,
          sizing: SizingRule.overloadFlc),
      DeviceSlot(
          role: 'start-pb',
          category: DeviceCategory.pilotDevice,
          sizing: SizingRule.pilot),
      DeviceSlot(
          role: 'stop-pb',
          category: DeviceCategory.pilotDevice,
          sizing: SizingRule.pilot),
    ],
    interlocks: [],
  ),
  StarterType.vfd: StarterTemplate(
    type: StarterType.vfd,
    label: 'Variable Frequency Drive',
    suitedKwRange: [0.37, 250],
    controlTransformerRequired: false,
    deviceSlots: [
      DeviceSlot(
          role: 'drive',
          category: DeviceCategory.vfd,
          sizing: SizingRule.vfdOutput),
      DeviceSlot(
          role: 'input-mccb',
          category: DeviceCategory.breaker,
          sizing: SizingRule.ac3FullFlc),
      DeviceSlot(
          role: 'speed-pot',
          category: DeviceCategory.pilotDevice,
          sizing: SizingRule.pilot),
      DeviceSlot(
          role: 'start-pb',
          category: DeviceCategory.pilotDevice,
          sizing: SizingRule.pilot),
      DeviceSlot(
          role: 'stop-pb',
          category: DeviceCategory.pilotDevice,
          sizing: SizingRule.pilot),
    ],
    interlocks: [],
  ),
  StarterType.ats: StarterTemplate(
    type: StarterType.ats,
    label: 'Automatic Transfer Switch',
    controlTransformerRequired: true,
    deviceSlots: [
      DeviceSlot(
          role: 'mains-contactor',
          category: DeviceCategory.contactor,
          sizing: SizingRule.ac3FullFlc),
      DeviceSlot(
          role: 'genset-contactor',
          category: DeviceCategory.contactor,
          sizing: SizingRule.ac3FullFlc),
      DeviceSlot(
          role: 'mains-failure-relay',
          category: DeviceCategory.phaseProtectionRelay,
          sizing: SizingRule.pilot),
    ],
    interlocks: [
      InterlockSpec(
        kind: InterlockKind.mechanical,
        roleA: 'mains-contactor',
        roleB: 'genset-contactor',
        relation: InterlockRelation.mutualExclusion,
        note: 'Mains and genset sources must never be paralleled.',
      ),
      InterlockSpec(
        kind: InterlockKind.electrical,
        roleA: 'mains-contactor',
        roleB: 'genset-contactor',
        relation: InterlockRelation.mutualExclusion,
      ),
    ],
  ),
  // A pump starter is a DOL starter; level/group control layers on top
  // (pump_control.dart). It shares the DOL slot set.
  StarterType.pump: StarterTemplate(
    type: StarterType.pump,
    label: 'Pump (DOL basis)',
    suitedKwRange: [0.37, 30],
    controlTransformerRequired: false,
    deviceSlots: [
      DeviceSlot(
          role: 'main-contactor',
          category: DeviceCategory.contactor,
          sizing: SizingRule.ac3FullFlc),
      DeviceSlot(
          role: 'overload',
          category: DeviceCategory.overloadRelay,
          sizing: SizingRule.overloadFlc),
      DeviceSlot(
          role: 'start-pb',
          category: DeviceCategory.pilotDevice,
          sizing: SizingRule.pilot),
      DeviceSlot(
          role: 'stop-pb',
          category: DeviceCategory.pilotDevice,
          sizing: SizingRule.pilot),
      DeviceSlot(
          role: 'run-lamp',
          category: DeviceCategory.indicatorLamp,
          sizing: SizingRule.pilot),
    ],
    interlocks: [],
  ),
};

// ---------------------------------------------------------------------------
// IEC 60947-4-1 Type-2 coordinated DOL starter sets, 400 V.
// ---------------------------------------------------------------------------

/// A verified Type-2 coordinated DOL combination (breaker + contactor + OL).
/// After a short circuit a Type-2 combination must remain serviceable (no
/// welding / recalibration); only a TESTED set guarantees this — independently
/// sized devices are merely a starting point.
class Type2Set {
  /// Rated motor power (kW, 400 V).
  final double kw;

  /// Motor circuit-breaker / MCCB rating of the verified set (A).
  final double breakerA;

  /// Contactor AC-3 rating of the verified set (A).
  final double contactorAc3A;

  /// Overload adjustment range of the verified set (A) — [lo, hi].
  final List<double> olRangeA;

  const Type2Set({
    required this.kw,
    required this.breakerA,
    required this.contactorAc3A,
    required this.olRangeA,
  });
}

/// Type-2 verified DOL sets at 400 V, ascending by motor kW.
///
/// // VERIFY (secondarySource): composite of typical published manufacturer
/// tables (Schneider TeSys/GV-NSX, ABB MS/AF, Siemens 3RV/3RT). Always confirm
/// against the chosen manufacturer's coordination table.
const List<Type2Set> type2DolSets400v = [
  Type2Set(kw: 0.37, breakerA: 1.6, contactorAc3A: 9, olRangeA: [0.63, 1]),
  Type2Set(kw: 0.55, breakerA: 2.5, contactorAc3A: 9, olRangeA: [1, 1.6]),
  Type2Set(kw: 0.75, breakerA: 2.5, contactorAc3A: 9, olRangeA: [1.6, 2.5]),
  Type2Set(kw: 1.1, breakerA: 4, contactorAc3A: 9, olRangeA: [2.5, 4]),
  Type2Set(kw: 1.5, breakerA: 4, contactorAc3A: 9, olRangeA: [2.5, 4]),
  Type2Set(kw: 2.2, breakerA: 6.3, contactorAc3A: 9, olRangeA: [4, 6.3]),
  Type2Set(kw: 3, breakerA: 10, contactorAc3A: 9, olRangeA: [6, 10]),
  Type2Set(kw: 4, breakerA: 10, contactorAc3A: 9, olRangeA: [6, 10]),
  Type2Set(kw: 5.5, breakerA: 14, contactorAc3A: 12, olRangeA: [9, 14]),
  Type2Set(kw: 7.5, breakerA: 18, contactorAc3A: 18, olRangeA: [13, 18]),
  Type2Set(kw: 11, breakerA: 25, contactorAc3A: 25, olRangeA: [17, 25]),
  Type2Set(kw: 15, breakerA: 32, contactorAc3A: 32, olRangeA: [23, 32]),
  Type2Set(kw: 18.5, breakerA: 40, contactorAc3A: 40, olRangeA: [30, 40]),
  Type2Set(kw: 22, breakerA: 50, contactorAc3A: 50, olRangeA: [37, 50]),
  Type2Set(kw: 30, breakerA: 63, contactorAc3A: 65, olRangeA: [48, 65]),
  Type2Set(kw: 37, breakerA: 80, contactorAc3A: 80, olRangeA: [60, 80]),
  Type2Set(kw: 45, breakerA: 100, contactorAc3A: 95, olRangeA: [70, 95]),
  Type2Set(kw: 55, breakerA: 125, contactorAc3A: 115, olRangeA: [90, 120]),
  Type2Set(kw: 75, breakerA: 160, contactorAc3A: 150, olRangeA: [110, 160]),
  Type2Set(kw: 90, breakerA: 200, contactorAc3A: 185, olRangeA: [140, 200]),
];

/// The verified Type-2 DOL set covering [motorKw], or null beyond the table.
Type2Set? type2SetFor(double motorKw) {
  for (final s in type2DolSets400v) {
    if (s.kw >= motorKw) return s;
  }
  return null;
}

// ---------------------------------------------------------------------------
// Assembly result types.
// ---------------------------------------------------------------------------

/// A sized piece of gear instantiated from a [DeviceSlot].
class ControlDevice {
  final String id;
  final String role;
  final DeviceCategory category;

  /// Target electrical rating the device must meet (A), if applicable.
  final Current? targetRatingA;

  /// Human-readable chosen rating / setting (e.g. "40 A AC-3", "set 37 A").
  final String? rating;

  /// Heat dissipation contribution (W).
  final double heatLossW;

  /// DIN modules / width contribution (mm).
  final double widthMm;

  final int qty;

  const ControlDevice({
    required this.id,
    required this.role,
    required this.category,
    this.targetRatingA,
    this.rating,
    this.heatLossW = 0,
    this.widthMm = 0,
    this.qty = 1,
  });
}

/// A concrete interlock between two instantiated devices.
class Interlock {
  final String id;
  final InterlockKind kind;
  final String deviceAId;
  final String deviceBId;
  final InterlockRelation relation;
  final String? note;

  const Interlock({
    required this.id,
    required this.kind,
    required this.deviceAId,
    required this.deviceBId,
    required this.relation,
    this.note,
  });
}

/// The Type-2 verified combination attached to a contactor-based assembly.
class CoordinationSet {
  final Current breakerA;
  final Current contactorAc3A;
  final List<double> olRangeA;

  /// Whether the engine's own contactor pick is at/above the verified set's.
  final bool contactorMatches;
  final String note;

  const CoordinationSet({
    required this.breakerA,
    required this.contactorAc3A,
    required this.olRangeA,
    required this.contactorMatches,
    required this.note,
  });
}

/// Motor summary attached to a control assembly.
class AssemblyMotor {
  final double kw;
  final Current flcA;
  final int poles;

  const AssemblyMotor({
    required this.kw,
    required this.flcA,
    required this.poles,
  });
}

/// The complete control-gear bill produced for one motor / control circuit.
class ControlAssembly {
  final String circuitId;
  final StarterType starterType;
  final AssemblyMotor? motor;
  final List<ControlDevice> devices;
  final List<Interlock> interlocks;

  /// Starting current/torque analysis for the chosen method.
  final StartingAnalysisResult? starting;

  /// IEC 60947-4-1 Type-2 verified combination (DOL basis), when applicable.
  final CoordinationSet? coordination;

  /// Free-text warnings (e.g. no frame covers the current).
  final List<String> warnings;

  /// `// VERIFY` provenance items surfaced to the user (standards-honesty).
  final List<String> verifyItems;

  const ControlAssembly({
    required this.circuitId,
    required this.starterType,
    this.motor,
    required this.devices,
    required this.interlocks,
    this.starting,
    this.coordination,
    required this.warnings,
    required this.verifyItems,
  });
}

double _round(double x, [int dp = 2]) {
  var f = 1.0;
  for (var i = 0; i < dp; i++) {
    f *= 10;
  }
  return (x * f).round() / f;
}

/// Format a number for display, dropping a trailing `.0` (so `18.0` reads `18`,
/// `15.5` stays `15.5`) — matches the JavaScript original's number rendering.
String _num(double x) {
  if (x == x.roundToDouble()) return x.toInt().toString();
  return x.toString();
}

double _contactorWidth(double ac3A) {
  if (ac3A <= 40) return 45;
  if (ac3A <= 115) return 55;
  if (ac3A <= 300) return 105;
  return 160;
}

double _pilotWidth(DeviceCategory category) {
  if (category == DeviceCategory.timerRelay ||
      category == DeviceCategory.controlRelay) {
    return 36;
  }
  if (category == DeviceCategory.vfd ||
      category == DeviceCategory.softStarter) {
    return 90;
  }
  if (category == DeviceCategory.breaker) return 54;
  return 22;
}

/// The standards-provenance items every assembly carries (the honesty surface).
const List<String> _baseVerifyItems = [
  'Motor FLC: IEC 60034-1 typical 400 V table — verify against the motor '
      'nameplate (secondarySource).',
  'Contactor / overload / VFD ladders: IEC 60947-4-1 typical frames — verify '
      'against the chosen manufacturer catalogue (secondarySource).',
];

/// Interpret a starter template for a motor circuit and produce its full control
/// assembly. Pure and fully unit-testable.
///
/// - [circuitId] namespaces every instantiated device / interlock id.
/// - [motorKw] sizes contactors / overload / VFD via the FLC table.
/// - [voltage] scales the FLC (FLC ∝ 1/V).
/// - [duty] (`jogging` = AC-4) enlarges the contactor frame and the trip class.
/// - [variableTorque] (pump/fan) refines the VFD starting note.
ControlAssembly applyStarterTemplate({
  required String circuitId,
  required StarterType starterType,
  required double motorKw,
  int motorPoles = 4,
  Voltage voltage = const Voltage(400),
  StartingDuty duty = StartingDuty.normal,
  bool variableTorque = false,
}) {
  final flc = Current(_round(motorFlc(motorKw, voltage).amperes, 1));
  final template = starterTemplates[starterType];
  final warnings = <String>[];
  final verifyItems = <String>[..._baseVerifyItems];
  final starting = startingAnalysis(
    flc,
    starterType,
    variableTorque: variableTorque,
    duty: duty,
  );

  if (template == null) {
    return ControlAssembly(
      circuitId: circuitId,
      starterType: starterType,
      motor: AssemblyMotor(kw: motorKw, flcA: flc, poles: motorPoles),
      devices: const [],
      interlocks: const [],
      starting: starting,
      warnings: ['Unknown starter type: $starterType'],
      verifyItems: verifyItems,
    );
  }

  final roleToId = <String, String>{};
  final devices = <ControlDevice>[];

  for (final slot in template.deviceSlots) {
    final id = '$circuitId:${slot.role}';
    roleToId[slot.role] = id;

    switch (slot.sizing) {
      case SizingRule.ac3FullFlc:
        final sel = selectContactor(flc, duty: duty);
        if (!sel.ok) {
          warnings.add(
              'No contactor frame covers ${sel.targetA} A for ${slot.role}');
        }
        devices.add(ControlDevice(
          id: id,
          role: slot.role,
          category: slot.category,
          qty: slot.qty,
          targetRatingA: Current(sel.targetA),
          rating: '${_num(sel.ac3A)} A AC-3 (${_num(sel.kw400)} kW)',
          heatLossW: sel.heatLossW,
          widthMm: _contactorWidth(sel.ac3A),
        ));
      case SizingRule.ac3StarWinding:
        final sel = selectContactor(flc, starDelta: true, duty: duty);
        devices.add(ControlDevice(
          id: id,
          role: slot.role,
          category: slot.category,
          qty: slot.qty,
          targetRatingA: Current(sel.targetA),
          rating: '${_num(sel.ac3A)} A AC-3 (star, 58% FLC)',
          heatLossW: sel.heatLossW,
          widthMm: _contactorWidth(sel.ac3A),
        ));
      case SizingRule.overloadFlc:
        final ol = selectOverload(flc, duty: duty);
        devices.add(ControlDevice(
          id: id,
          role: slot.role,
          category: slot.category,
          qty: slot.qty,
          targetRatingA: ol.settingA,
          rating:
              'set ${_num(ol.settingA.amperes)} A, class ${ol.tripClass.label}',
          heatLossW: 0.5,
          widthMm: 45,
        ));
      case SizingRule.overloadStarFlc:
        final ol = selectOverload(flc, inStarLeg: true, duty: duty);
        devices.add(ControlDevice(
          id: id,
          role: slot.role,
          category: slot.category,
          qty: slot.qty,
          targetRatingA: ol.settingA,
          rating: 'set ${_num(ol.settingA.amperes)} A (delta leg), '
              'class ${ol.tripClass.label}',
          heatLossW: 0.5,
          widthMm: 45,
        ));
      case SizingRule.vfdOutput:
        final v = selectVfd(flc);
        if (!v.ok) {
          warnings
              .add('No drive covers ${v.requiredA.amperes} A for ${slot.role}');
        }
        devices.add(ControlDevice(
          id: id,
          role: slot.role,
          category: slot.category,
          qty: slot.qty,
          targetRatingA: v.requiredA,
          rating: '${_num(v.ratedKw)} kW / ${_num(v.outputA.amperes)} A',
          heatLossW: v.heatLossW,
          widthMm: 90,
        ));
      case SizingRule.pilot:
        devices.add(ControlDevice(
          id: id,
          role: slot.role,
          category: slot.category,
          qty: slot.qty,
          rating: '-',
          heatLossW: 0,
          widthMm: _pilotWidth(slot.category),
        ));
    }
  }

  // Control transformer when the template requires it: size from the contactor
  // coil burdens + a pilot allowance.
  if (template.controlTransformerRequired) {
    final burdens = devices
        .where((d) =>
            d.category == DeviceCategory.contactor && d.targetRatingA != null)
        .map((d) => coilBurdenForFrame(d.targetRatingA!.amperes))
        .toList();
    final tx = sizeControlTransformer(burdens, pilotSealedVa: 10);
    final id = '$circuitId:control-transformer';
    roleToId['control-transformer'] = id;
    devices.add(ControlDevice(
      id: id,
      role: 'control-transformer',
      category: DeviceCategory.controlTransformer,
      qty: 1,
      rating: '${_num(tx.chosenVa.voltAmperes)} VA',
      heatLossW: _round(tx.chosenVa.voltAmperes * 0.03, 1),
      widthMm: 70,
    ));
    if (!tx.ok) {
      warnings.add('Control transformer VA exceeds largest standard size');
    }
  }

  // Resolve the declarative interlocks into concrete device-referencing ones.
  final interlocks = <Interlock>[];
  for (var i = 0; i < template.interlocks.length; i++) {
    final spec = template.interlocks[i];
    interlocks.add(Interlock(
      id: '$circuitId:il$i',
      kind: spec.kind,
      deviceAId: roleToId[spec.roleA] ?? spec.roleA,
      deviceBId: roleToId[spec.roleB] ?? spec.roleB,
      relation: spec.relation,
      note: spec.note,
    ));
  }

  // Type-2 coordination (IEC 60947-4-1) for contactor-based starters.
  CoordinationSet? coordination;
  final contactorBased = starterType == StarterType.dol ||
      starterType == StarterType.starDelta ||
      starterType == StarterType.reversing ||
      starterType == StarterType.pump;
  if (contactorBased) {
    final set = type2SetFor(motorKw);
    if (set != null) {
      ControlDevice? mainContactor;
      for (final d in devices) {
        if (d.category == DeviceCategory.contactor && d.targetRatingA != null) {
          mainContactor = d;
          break;
        }
      }
      final pick = mainContactor?.targetRatingA?.amperes;
      final contactorMatches = pick == null ||
          pick + 1e-9 >=
              (set.contactorAc3A < flc.amperes ? set.contactorAc3A : flc.amperes);
      coordination = CoordinationSet(
        breakerA: Current(set.breakerA),
        contactorAc3A: Current(set.contactorAc3A),
        olRangeA: set.olRangeA,
        contactorMatches: contactorMatches,
        note: 'Type-2 verified set (${_num(set.kw)} kW DOL basis): breaker '
            '${_num(set.breakerA)} A + contactor ${_num(set.contactorAc3A)} A '
            'AC-3 + OL ${_num(set.olRangeA[0])}-${_num(set.olRangeA[1])} A — '
            "confirm against the chosen manufacturer's coordination table.",
      );
      verifyItems.add(
          'Type-2 coordination set: composite of typical manufacturer tables — '
          'confirm against the chosen catalogue (secondarySource).');
      if (!contactorMatches) {
        warnings.add(
            'Contactor below the type-2 verified set (${_num(set.contactorAc3A)} A '
            'AC-3) for ${_num(motorKw)} kW — the combination may weld under '
            'short-circuit (IEC 60947-4-1 type 2).');
      }
    }
  }

  return ControlAssembly(
    circuitId: circuitId,
    starterType: starterType,
    motor: AssemblyMotor(kw: motorKw, flcA: flc, poles: motorPoles),
    devices: devices,
    interlocks: interlocks,
    starting: starting,
    coordination: coordination,
    warnings: warnings,
    verifyItems: verifyItems,
  );
}
