/// Pump / water-level control schemes and pump-group (alternation / lead-lag /
/// parallel / cascade) gear. Ported from PanelMaker
/// `engine/control/{pumpControl,pumpGroup}.ts` + `standards/control/{pump,pumpGroup}.ts`.
///
/// A pump circuit uses an underlying motor starter (see `starter.dart`) and
/// layers level sensing, control logic and interlocks on top. A pump *group*
/// operates several such circuits together under one duty scheme, deriving the
/// shared controller / alternator gear and the cross-pump interlocks.
///
/// The React-Flow ladder schematic that PanelMaker also emits has no analogue in
/// this engine, so it is intentionally omitted; only the engineering content
/// (devices + interlocks + warnings) is ported. Per-rung schematic generation is
/// a known follow-up (TODO).
///
/// PURE Dart — zero Flutter imports.
library;

import 'starter.dart';

/// Single-pump level-control scheme.
enum PumpControlMode { fill, drain, duplex, booster }

/// Level-sensing technology.
enum LevelSensing { float, electrode, pressure, ultrasonic }

/// Declarative description of a single-pump control template.
class PumpTemplate {
  final PumpControlMode mode;
  final String label;
  final String startCondition;
  final String stopCondition;

  /// Sensor roles required for this scheme.
  final List<String> requiredSensors;

  /// Safety interlocks / alarms inherent to the scheme.
  final List<String> protections;

  const PumpTemplate({
    required this.mode,
    required this.label,
    required this.startCondition,
    required this.stopCondition,
    required this.requiredSensors,
    required this.protections,
  });
}

/// Per-mode pump templates.
///
/// // VERIFY (notAnSniClause): general control-engineering practice — not a
/// specific SNI/PUIL clause.
const Map<PumpControlMode, PumpTemplate> pumpTemplates = {
  PumpControlMode.fill: PumpTemplate(
    mode: PumpControlMode.fill,
    label: 'Fill (tank from reservoir)',
    startCondition: 'tank level below LOW (E2)',
    stopCondition: 'tank level reaches HIGH (E3)',
    requiredSensors: ['level-relay', 'electrode-assembly', 'source-low-electrode'],
    protections: [
      'dry-run (source-low NC in series with start)',
      'high-high overflow alarm',
    ],
  ),
  PumpControlMode.drain: PumpTemplate(
    mode: PumpControlMode.drain,
    label: 'Drain / sump / sewage',
    startCondition: 'sump level reaches HIGH (E3)',
    stopCondition: 'sump level falls below LOW (E2)',
    requiredSensors: ['level-relay', 'electrode-assembly'],
    protections: ['high-high fail alarm', 'discharge check-valve (mechanical)'],
  ),
  PumpControlMode.duplex: PumpTemplate(
    mode: PumpControlMode.duplex,
    label: 'Duplex duty / standby (lead-lag)',
    startCondition: 'lead at MED level; lag at HIGH level',
    stopCondition: 'both off below STOP level',
    requiredSensors: [
      'alternator-relay',
      'float-switch-stop',
      'float-switch-lead',
      'float-switch-lag',
    ],
    protections: ['automatic lead/lag alternation', 'duty-assist on high demand'],
  ),
  PumpControlMode.booster: PumpTemplate(
    mode: PumpControlMode.booster,
    label: 'Constant-pressure booster (VFD + PID)',
    startCondition: 'demand / pressure below setpoint',
    stopCondition: 'no-flow / sleep at setpoint',
    requiredSensors: ['pressure-transmitter'],
    protections: [
      'dry-run / low-suction protection',
      'cascade staging for multi-pump',
    ],
  ),
};

/// Default level-sensing technology per pump mode.
const Map<PumpControlMode, LevelSensing> defaultSensing = {
  PumpControlMode.fill: LevelSensing.electrode,
  PumpControlMode.drain: LevelSensing.electrode,
  PumpControlMode.duplex: LevelSensing.float,
  PumpControlMode.booster: LevelSensing.pressure,
};

/// The pump configuration recorded on an assembly.
class PumpConfig {
  final PumpControlMode mode;
  final LevelSensing sensing;
  final List<String> requiredSensors;

  const PumpConfig({
    required this.mode,
    required this.sensing,
    required this.requiredSensors,
  });
}

/// A control assembly augmented with pump-level control: the base assembly plus
/// the sensing devices and the resolved pump configuration.
class PumpControlAssembly {
  final ControlAssembly assembly;
  final PumpConfig pump;

  const PumpControlAssembly({required this.assembly, required this.pump});
}

DeviceCategory _sensorCategory(String role) {
  if (role.contains('level-relay')) return DeviceCategory.levelRelay;
  if (role.contains('electrode')) return DeviceCategory.electrodeAssembly;
  if (role.contains('float')) return DeviceCategory.floatSwitch;
  if (role.contains('pressure')) return DeviceCategory.pressureTransmitter;
  if (role.contains('alternator')) return DeviceCategory.alternatorRelay;
  return DeviceCategory.levelSensor;
}

/// Layer a pump/level control scheme onto an existing motor-starter assembly:
/// add the required sensing devices, record the pump configuration, and flag
/// missing protections (e.g. dry-run on a fill pump).
PumpControlAssembly applyPumpControl(
  ControlAssembly assembly,
  PumpControlMode mode, {
  LevelSensing? sensing,
}) {
  final tmpl = pumpTemplates[mode]!;
  final resolvedSensing = sensing ?? defaultSensing[mode]!;

  final sensorDevices = tmpl.requiredSensors
      .map((role) => ControlDevice(
            id: '${assembly.circuitId}:$role',
            role: role,
            category: _sensorCategory(role),
            qty: 1,
            rating: '-',
            heatLossW: 0,
            widthMm: 36,
          ))
      .toList();

  final warnings = [...assembly.warnings];
  final hasDryRun =
      tmpl.protections.any((p) => p.toLowerCase().contains('dry-run'));
  if (mode == PumpControlMode.fill && !hasDryRun) {
    warnings.add('Fill pump should include dry-run / source-low protection.');
  }

  final augmented = ControlAssembly(
    circuitId: assembly.circuitId,
    starterType: assembly.starterType,
    motor: assembly.motor,
    devices: [...assembly.devices, ...sensorDevices],
    interlocks: assembly.interlocks,
    starting: assembly.starting,
    coordination: assembly.coordination,
    warnings: warnings,
    verifyItems: [
      ...assembly.verifyItems,
      'Pump-level control scheme: general control-engineering practice '
          '(notAnSniClause).',
    ],
  );

  return PumpControlAssembly(
    assembly: augmented,
    pump: PumpConfig(
      mode: mode,
      sensing: resolvedSensing,
      requiredSensors: tmpl.requiredSensors,
    ),
  );
}

// ---------------------------------------------------------------------------
// Pump groups.
// ---------------------------------------------------------------------------

/// How a set of pumps in a group share the duty.
enum PumpGroupMode {
  singleAlternate, // duty/standby — one runs, role alternates each cycle
  parallelAlternate, // duty/assist — lead runs, more stage in, lead alternates
  leadLag, // fixed lead then lag, assist on demand, no alternation
  parallel, // all pumps run together (no staging)
  cascade, // sequential staging by demand (booster set)
}

/// What initiates and modulates a pump group's run demand.
enum PumpGroupTrigger { level, timer, pressure, manual }

/// Cross-pump interlock pattern the engine enforces between member contactors.
enum GroupInterlockPattern { mutualExclusion, sequence, none }

/// Definition of a pump-group duty scheme.
class PumpGroupModeDef {
  final PumpGroupMode mode;
  final String label;

  /// Members may run simultaneously (assist/parallel) vs strictly one at a time.
  final bool allowsParallel;

  /// The lead role rotates automatically between cycles (even run hours).
  final bool alternates;

  /// Cross-pump interlock pattern the engine enforces.
  final GroupInterlockPattern interlock;

  /// Fewest member pumps for the scheme to be meaningful.
  final int minPumps;

  final String description;

  const PumpGroupModeDef({
    required this.mode,
    required this.label,
    required this.allowsParallel,
    required this.alternates,
    required this.interlock,
    required this.minPumps,
    required this.description,
  });
}

/// Per-mode pump-group definitions.
///
/// // VERIFY (notAnSniClause): general pump-control practice — not an SNI clause.
const Map<PumpGroupMode, PumpGroupModeDef> pumpGroupModes = {
  PumpGroupMode.singleAlternate: PumpGroupModeDef(
    mode: PumpGroupMode.singleAlternate,
    label: 'Single duty / standby (alternating)',
    allowsParallel: false,
    alternates: true,
    interlock: GroupInterlockPattern.mutualExclusion,
    minPumps: 2,
    description:
        'One pump runs at a time; the duty role alternates each cycle to even '
        'out run hours. The standby starts only if the duty fails.',
  ),
  PumpGroupMode.parallelAlternate: PumpGroupModeDef(
    mode: PumpGroupMode.parallelAlternate,
    label: 'Duty / assist (alternating)',
    allowsParallel: true,
    alternates: true,
    interlock: GroupInterlockPattern.sequence,
    minPumps: 2,
    description:
        'The lead pump runs; further pumps stage in on rising demand and drop '
        'out as it falls. The lead role alternates each cycle.',
  ),
  PumpGroupMode.leadLag: PumpGroupModeDef(
    mode: PumpGroupMode.leadLag,
    label: 'Fixed lead / lag (assist)',
    allowsParallel: true,
    alternates: false,
    interlock: GroupInterlockPattern.sequence,
    minPumps: 2,
    description:
        'A fixed lead pump starts first; the lag pump(s) assist on rising '
        'demand. No automatic alternation.',
  ),
  PumpGroupMode.parallel: PumpGroupModeDef(
    mode: PumpGroupMode.parallel,
    label: 'Parallel (all together)',
    allowsParallel: true,
    alternates: false,
    interlock: GroupInterlockPattern.none,
    minPumps: 2,
    description:
        'All pumps start and stop together on demand — no staging or alternation.',
  ),
  PumpGroupMode.cascade: PumpGroupModeDef(
    mode: PumpGroupMode.cascade,
    label: 'Cascade staging (booster set)',
    allowsParallel: true,
    alternates: true,
    interlock: GroupInterlockPattern.sequence,
    minPumps: 2,
    description:
        'Pumps stage on/off sequentially to hold the setpoint (typically a VFD '
        'lead with fixed-speed assists); lead rotates for even wear.',
  ),
};

/// Definition of a pump-group trigger (the run-demand source).
class PumpGroupTriggerDef {
  final PumpGroupTrigger trigger;
  final String label;

  /// Category of the controller device the trigger provisions, if any.
  final DeviceCategory? controllerCategory;

  /// Default device role for the controller.
  final String controllerRole;

  final String description;

  const PumpGroupTriggerDef({
    required this.trigger,
    required this.label,
    required this.controllerCategory,
    required this.controllerRole,
    required this.description,
  });
}

/// Per-trigger pump-group definitions.
const Map<PumpGroupTrigger, PumpGroupTriggerDef> pumpGroupTriggers = {
  PumpGroupTrigger.level: PumpGroupTriggerDef(
    trigger: PumpGroupTrigger.level,
    label: 'Water-level controller',
    controllerCategory: DeviceCategory.levelRelay,
    controllerRole: 'group-level-controller',
    description:
        'Tank/sump level (float, electrode, pressure or ultrasonic) starts and '
        'stops the set.',
  ),
  PumpGroupTrigger.timer: PumpGroupTriggerDef(
    trigger: PumpGroupTrigger.timer,
    label: 'Cyclic timer',
    controllerCategory: DeviceCategory.timerRelay,
    controllerRole: 'group-timer',
    description:
        'A repeat-cycle timer runs the set on an ON/OFF schedule (e.g. '
        'circulation duty).',
  ),
  PumpGroupTrigger.pressure: PumpGroupTriggerDef(
    trigger: PumpGroupTrigger.pressure,
    label: 'Pressure transmitter',
    controllerCategory: DeviceCategory.pressureTransmitter,
    controllerRole: 'group-pressure-controller',
    description:
        'A pressure transmitter / switch holds system pressure by staging the '
        'pumps.',
  ),
  PumpGroupTrigger.manual: PumpGroupTriggerDef(
    trigger: PumpGroupTrigger.manual,
    label: 'Manual / BMS',
    controllerCategory: null,
    controllerRole: 'group-run-command',
    description:
        'Run command comes from a selector or the BMS; the group only handles '
        'staging/alternation.',
  ),
};

/// A resolved member of a pump group: an existing pump/motor circuit.
class PumpGroupMember {
  final String circuitId;
  final String name;

  /// The member's own sized starter assembly, when it has one.
  final ControlAssembly? control;

  const PumpGroupMember({
    required this.circuitId,
    required this.name,
    this.control,
  });
}

/// Configuration for one pump group.
class PumpGroupConfig {
  final String id;
  final String name;
  final PumpGroupMode mode;
  final PumpGroupTrigger trigger;

  /// Level-sensing technology when the trigger is a water-level controller.
  final LevelSensing? sensing;

  /// Timer ON / OFF durations (minutes) when the trigger is a cyclic timer.
  final int? timerOnMin;
  final int? timerOffMin;

  const PumpGroupConfig({
    required this.id,
    required this.name,
    required this.mode,
    required this.trigger,
    this.sensing,
    this.timerOnMin,
    this.timerOffMin,
  });
}

/// The derived control package for one pump group: the shared controller /
/// alternator gear, the cross-pump interlocks, and validation warnings.
class PumpGroupResult {
  final String id;
  final String name;
  final PumpGroupMode mode;
  final PumpGroupTrigger trigger;
  final List<String> memberCircuitIds;
  final List<String> memberNames;

  /// Shared control gear (controller, alternator relay…).
  final List<ControlDevice> devices;

  /// Cross-circuit interlocks between the member pumps' run coils.
  final List<Interlock> interlocks;

  final List<String> warnings;
  final String note;
  final List<String> verifyItems;

  const PumpGroupResult({
    required this.id,
    required this.name,
    required this.mode,
    required this.trigger,
    required this.memberCircuitIds,
    required this.memberNames,
    required this.devices,
    required this.interlocks,
    required this.warnings,
    required this.note,
    required this.verifyItems,
  });
}

/// Resolve a member's run-coil device id (main contactor / bypass / drive).
String _runCoilId(PumpGroupMember member) {
  String? byRole(String role) {
    for (final d in member.control?.devices ?? const <ControlDevice>[]) {
      if (d.role == role) return d.id;
    }
    return null;
  }

  return byRole('main-contactor') ??
      byRole('bypass-contactor') ??
      byRole('drive') ??
      '${member.circuitId}:run';
}

/// Derive the full control package for one pump group from its config and the
/// resolved member pump circuits.
PumpGroupResult computePumpGroup(
  PumpGroupConfig config,
  List<PumpGroupMember> members,
) {
  final modeDef = pumpGroupModes[config.mode]!;
  final triggerDef = pumpGroupTriggers[config.trigger]!;
  final warnings = <String>[];
  final devices = <ControlDevice>[];

  // Shared trigger controller (water-level / timer / pressure).
  if (triggerDef.controllerCategory != null) {
    final controllerId = 'group:${config.id}:controller';
    final rating = switch (config.trigger) {
      PumpGroupTrigger.level =>
        '${(config.sensing ?? defaultSensing[PumpControlMode.duplex]!).name} sensing',
      PumpGroupTrigger.timer =>
        '${config.timerOnMin ?? 5} min ON / ${config.timerOffMin ?? 10} min OFF',
      PumpGroupTrigger.pressure => 'PID setpoint',
      PumpGroupTrigger.manual => 'manual',
    };
    devices.add(ControlDevice(
      id: controllerId,
      role: triggerDef.controllerRole,
      category: triggerDef.controllerCategory!,
      qty: 1,
      rating: rating,
      heatLossW: 1,
      widthMm: 36,
    ));
  }

  // Alternator relay for schemes that rotate the lead.
  if (modeDef.alternates) {
    devices.add(ControlDevice(
      id: 'group:${config.id}:alternator',
      role: 'group-alternator',
      category: DeviceCategory.alternatorRelay,
      qty: 1,
      rating: '${members.length}-way duty rotation',
      heatLossW: 1,
      widthMm: 36,
    ));
  }

  // Cross-pump interlocks between the member run coils.
  final interlocks = <Interlock>[];
  if (modeDef.interlock == GroupInterlockPattern.mutualExclusion) {
    for (var i = 0; i < members.length; i++) {
      for (var j = i + 1; j < members.length; j++) {
        interlocks.add(Interlock(
          id: 'group:${config.id}:il-$i-$j',
          kind: InterlockKind.electrical,
          deviceAId: _runCoilId(members[i]),
          deviceBId: _runCoilId(members[j]),
          relation: InterlockRelation.mutualExclusion,
          note: 'Only one pump of "${config.name}" runs at a time '
              '(duty/standby) — cross-wired NC interlock; the alternator '
              'rotates which is duty.',
        ));
      }
    }
  } else if (modeDef.interlock == GroupInterlockPattern.sequence) {
    for (var i = 1; i < members.length; i++) {
      interlocks.add(Interlock(
        id: 'group:${config.id}:il-seq-$i',
        kind: InterlockKind.electrical,
        deviceAId: _runCoilId(members[i - 1]),
        deviceBId: _runCoilId(members[i]),
        relation: InterlockRelation.sequence,
        note: '"${members[i].name}" stages in only after '
            '"${members[i - 1].name}" is running (assist on rising demand).',
      ));
    }
  }

  // Validation.
  if (members.length < modeDef.minPumps) {
    warnings.add('"${config.name}" (${modeDef.label}) needs at least '
        '${modeDef.minPumps} pumps — assign more member pumps.');
  }
  for (final m in members.where((m) => m.control == null)) {
    warnings.add('Pump "${m.name}" has no motor starter, so it cannot be '
        'controlled in group "${config.name}" — set a starter on it.');
  }

  final note = '${members.length} pump(s) as ${modeDef.label}, started by a '
      '${triggerDef.label.toLowerCase()}. ${modeDef.description}';

  return PumpGroupResult(
    id: config.id,
    name: config.name,
    mode: config.mode,
    trigger: config.trigger,
    memberCircuitIds: members.map((m) => m.circuitId).toList(),
    memberNames: members.map((m) => m.name).toList(),
    devices: devices,
    interlocks: interlocks,
    warnings: warnings,
    note: note,
    verifyItems: const [
      'Pump-group duty schemes (alternation / lead-lag / cascade): general '
          'pump-control practice (notAnSniClause).',
    ],
  );
}
