/// Hybrid power one-line model — the utility, an optional generator transferred
/// by an ATS, and grid-tied solar PV and/or a battery converging on the main LV
/// bus, with the source interlocks (mains↔genset mutual exclusion, PV
/// anti-islanding, battery transfer). Ported from PanelMaker
/// `engine/powerOneline.ts` + `types/oneline.ts`.
///
/// A GENERATED render of the sources design — it derives the buses + interlock
/// notes from [ElectricalSources] (sized via `sources.dart`) and the demand; it
/// is not a parallel calculation.
///
/// Pure Dart, ZERO Flutter imports.
library;

import '../units.dart';
import 'sources.dart';

/// What kind of node sits on the power one-line.
enum PowerNodeKind {
  utility,
  generator,
  ats,
  pv,
  pvInverter,
  battery,
  batteryInverter,
  hybridInverter,
  bus,
  mainPanel,
}

/// A node on the power one-line.
class PowerNode {
  final String id;
  final PowerNodeKind kind;
  final String label;
  final String? sub;

  const PowerNode({
    required this.id,
    required this.kind,
    required this.label,
    this.sub,
  });
}

/// A directed connection between two power-one-line nodes.
class PowerEdge {
  final String id;
  final String from;
  final String to;
  final String? label;

  const PowerEdge({
    required this.id,
    required this.from,
    required this.to,
    this.label,
  });
}

/// Whether an interlock is enforced mechanically or electrically.
enum PowerInterlockKind { mechanical, electrical }

/// The relationship an interlock enforces between two nodes.
enum PowerInterlockRelation { mutualExclusion, sequence, permissive }

/// A source interlock acting between two nodes.
class PowerInterlock {
  final String id;
  final PowerInterlockKind kind;
  final String aId;
  final String bId;
  final PowerInterlockRelation relation;
  final String note;

  const PowerInterlock({
    required this.id,
    required this.kind,
    required this.aId,
    required this.bId,
    required this.relation,
    required this.note,
  });
}

/// The hybrid power one-line: nodes, edges and source interlocks.
class PowerOneLine {
  final List<PowerNode> nodes;
  final List<PowerEdge> edges;
  final List<PowerInterlock> interlocks;

  const PowerOneLine({
    required this.nodes,
    required this.edges,
    required this.interlocks,
  });

  /// First node of a kind, or null.
  PowerNode? nodeOfKind(PowerNodeKind kind) {
    for (final n in nodes) {
      if (n.kind == kind) return n;
    }
    return null;
  }

  bool get hasEssentialBus =>
      nodes.any((n) => n.kind == PowerNodeKind.bus && n.id == 'ess-bus');

  bool get hasCriticalBus =>
      nodes.any((n) => n.kind == PowerNodeKind.bus && n.id == 'ups-bus');
}

String _fmt(double v) =>
    v == v.roundToDouble() ? v.toInt().toString() : v.toString();

/// Build the hybrid power one-line from the sources design.
///
/// [demand] is the diversified building demand (apparent power) reaching the
/// main bus. The sources are pre-sized here from [sources] so the model is
/// self-contained. When both PV and battery are present (or `hybridInverter`
/// is forced on) the DC sources + grid share ONE hybrid inverter; otherwise
/// each DC source gets its own inverter. With a generator and a < 1.0
/// `backupFraction`, an ESSENTIAL bus is split behind the ATS; a battery then
/// backs a CRITICAL (UPS) bus charged from the backed bus.
PowerOneLine buildPowerOneLine(
  ElectricalSources sources, {
  required ApparentPower demand,
  Voltage voltage = const Voltage(400),
  List<GensetMotor> motors = const <GensetMotor>[],
}) {
  final nodes = <PowerNode>[];
  final edges = <PowerEdge>[];
  final interlocks = <PowerInterlock>[];

  var e = 0;
  void edge(String from, String to, [String? label]) =>
      edges.add(PowerEdge(id: 'pe${e++}', from: from, to: to, label: label));

  // Main LV bus + main panel.
  nodes.add(PowerNode(
    id: 'bus',
    kind: PowerNodeKind.bus,
    label: 'Main LV bus',
    sub: '${_fmt(voltage.volts)} V',
  ));
  nodes.add(const PowerNode(
    id: 'main',
    kind: PowerNodeKind.mainPanel,
    label: 'Main panel',
  ));
  edge('bus', 'main');

  // Utility (PLN). This domain feeds the bus at LV; MV/transformer topology is
  // an A8 supply concern, deliberately out of scope here.
  nodes.add(PowerNode(
    id: 'utility',
    kind: PowerNodeKind.utility,
    label: 'PLN utility',
    sub: '${_fmt(voltage.volts)} V LV',
  ));
  const utilityOut = 'utility';

  // Pre-size the configured sources.
  final gen = sources.generator;
  final genResult =
      gen == null ? null : _sizeGen(gen, demand);
  // Motor-start voltage-dip screen for the sized genset — annotated onto the
  // generator node so the one-line carries the load-acceptance verdict.
  final gensetStart = genResult == null
      ? null
      : assessGensetStart(genResult.ratingKva, motors: motors);

  final solar = sources.solar;
  final solarResult = solar == null
      ? null
      : sizeSolar(panelWp: solar.panelWp, panels: solar.panels, dcAcRatio: solar.dcAcRatio);

  final batt = sources.battery;
  // The battery backs the building demand × (1 − genset fraction is not applied
  // here); its critical load is the demand at the assumed PF for sizing.
  final batteryResult = batt == null
      ? null
      : sizeBattery(_demandToPower(demand), autonomyHours: batt.autonomyHours, chemistry: batt.chemistry);

  final solarOn = solarResult != null;
  final battOn = batteryResult != null;
  final hybrid = (sources.hybridInverter ?? (solarOn && battOn)) && (solarOn || battOn);

  // Essential split: a genset that backs only a fraction transfers a dedicated
  // ESSENTIAL bus (non-hybrid topology); the battery then backs a CRITICAL bus.
  final essentialSplit =
      gen != null && !hybrid && gen.backupFraction < 1.0;
  var backedBus = 'bus';

  // Generator via ATS / COS, with the mains↔genset interlock.
  var gridOut = utilityOut;
  if (genResult != null && gen != null) {
    final manualTransfer = gen.transfer.isManual;
    final dipTag = (gensetStart != null && !gensetStart.acceptable)
        ? ' · start dip ${gensetStart.estimatedDipPct}% over'
        : '';
    nodes.add(PowerNode(
      id: 'gen',
      kind: PowerNodeKind.generator,
      label: 'Generator',
      sub: '${_fmt(genResult.ratingKva.inKilovoltAmperes)} kVA '
          '${gen.mode.label}$dipTag',
    ));
    nodes.add(PowerNode(
      id: 'ats',
      kind: PowerNodeKind.ats,
      label: manualTransfer ? 'COS' : 'ATS',
      sub: manualTransfer ? 'manual changeover' : 'transfer switch',
    ));
    gridOut = 'ats';
    if (essentialSplit) {
      nodes.add(PowerNode(
        id: 'ess-bus',
        kind: PowerNodeKind.bus,
        label: 'Essential bus',
        sub: '${_fmt(genResult.backupKva.inKilovoltAmperes)} kVA',
      ));
      edge(utilityOut, 'bus', 'mains');
      edge('bus', 'ats', 'normal');
      edge('gen', 'ats', 'genset');
      edge('ats', 'ess-bus');
      backedBus = 'ess-bus';
    } else {
      edge(utilityOut, 'ats', 'mains');
      edge('gen', 'ats', 'genset');
      if (!hybrid) edge('ats', 'bus');
    }
    interlocks.add(PowerInterlock(
      id: 'il-ats-mech',
      kind: PowerInterlockKind.mechanical,
      aId: 'utility',
      bId: 'gen',
      relation: PowerInterlockRelation.mutualExclusion,
      note: manualTransfer
          ? 'Mains and generator must never be paralleled — the changeover (COS) is break-before-make by construction.'
          : 'Mains and generator must never be paralleled — mechanical interlock at the ATS.',
    ));
    interlocks.add(PowerInterlock(
      id: 'il-ats-elec',
      kind: PowerInterlockKind.electrical,
      aId: 'utility',
      bId: 'gen',
      relation: PowerInterlockRelation.mutualExclusion,
      note: manualTransfer
          ? 'Manual transfer: an operator must start the genset and switch — the backed loads see an outage until then.'
          : 'Cross-wired electrical interlock + break-before-make transfer (mains-failure sensing).',
    ));
  } else if (!hybrid) {
    edge(utilityOut, 'bus', 'mains');
  }

  if (hybrid) {
    // ONE hybrid (multi-mode) inverter combines PV + battery + grid.
    nodes.add(PowerNode(
      id: 'hinv',
      kind: PowerNodeKind.hybridInverter,
      label: 'Hybrid inverter',
      sub: _hybridInverterSub(solarResult, batteryResult),
    ));
    if (solarResult != null) {
      nodes.add(PowerNode(
        id: 'pv',
        kind: PowerNodeKind.pv,
        label: 'Solar array',
        sub: '${_fmt(solarResult.arrayKwp.inKiloWatts)} kWp',
      ));
      edge('pv', 'hinv', 'DC');
    }
    if (batteryResult != null) {
      nodes.add(PowerNode(
        id: 'batt',
        kind: PowerNodeKind.battery,
        label: 'Battery',
        sub: '${_fmt(batteryResult.installedKwh.inKilowattHours)} kWh',
      ));
      edge('batt', 'hinv', 'DC');
    }
    edge(gridOut, 'hinv', 'AC grid');
    edge('hinv', 'bus', 'AC');
    interlocks.add(const PowerInterlock(
      id: 'il-hybrid',
      kind: PowerInterlockKind.electrical,
      aId: 'hinv',
      bId: 'bus',
      relation: PowerInterlockRelation.permissive,
      note: 'Anti-islanding + transfer: the hybrid inverter disconnects export on grid loss and re-feeds the essential bus from PV/battery (island/UPS mode).',
    ));
    if (genResult != null) {
      interlocks.add(const PowerInterlock(
        id: 'il-hybrid-gen',
        kind: PowerInterlockKind.electrical,
        aId: 'hinv',
        bId: 'gen',
        relation: PowerInterlockRelation.permissive,
        note: 'On generator supply the hybrid inverter must stop exporting (charge-only / derate) — a standby genset cannot absorb reverse feed.',
      ));
    }
  } else {
    // Separate per-source inverters; the grid already feeds the bus above.
    if (solarResult != null) {
      nodes.add(PowerNode(
        id: 'pv',
        kind: PowerNodeKind.pv,
        label: 'Solar array',
        sub: '${_fmt(solarResult.arrayKwp.inKiloWatts)} kWp',
      ));
      nodes.add(PowerNode(
        id: 'pvinv',
        kind: PowerNodeKind.pvInverter,
        label: 'PV inverter',
        sub: '${_fmt(solarResult.inverterKw.inKiloWatts)} kW',
      ));
      edge('pv', 'pvinv');
      edge('pvinv', 'bus', 'AC');
      interlocks.add(PowerInterlock(
        id: 'il-pv',
        kind: PowerInterlockKind.electrical,
        aId: 'pvinv',
        bId: 'bus',
        relation: PowerInterlockRelation.permissive,
        note: batteryResult != null
            ? 'Hybrid: PV + battery island the essential bus on grid loss.'
            : 'Anti-islanding: the grid-tied PV inverter disconnects within ~2 s on grid loss.',
      ));
      if (genResult != null) {
        interlocks.add(const PowerInterlock(
          id: 'il-pv-gen',
          kind: PowerInterlockKind.electrical,
          aId: 'pvinv',
          bId: 'gen',
          relation: PowerInterlockRelation.permissive,
          note: 'On generator supply the PV inverter must disconnect or derate — a standby genset cannot absorb reverse PV feed.',
        ));
      }
    }

    if (batteryResult != null) {
      nodes.add(PowerNode(
        id: 'batt',
        kind: PowerNodeKind.battery,
        label: 'Battery',
        sub: '${_fmt(batteryResult.installedKwh.inKilowattHours)} kWh',
      ));
      nodes.add(PowerNode(
        id: 'battinv',
        kind: PowerNodeKind.batteryInverter,
        label: 'Battery inverter',
        sub: '${_fmt(batteryResult.inverterKw.inKiloWatts)} kW',
      ));
      edge('batt', 'battinv');
      if (essentialSplit) {
        // A critical (UPS) bus rides the battery through any transfer gap.
        nodes.add(PowerNode(
          id: 'ups-bus',
          kind: PowerNodeKind.bus,
          label: 'UPS / critical bus',
          sub: '${_fmt(batteryResult.criticalLoad.inKiloWatts)} kW',
        ));
        edge(backedBus, 'battinv', 'charge');
        edge('battinv', 'ups-bus', 'UPS');
        interlocks.add(const PowerInterlock(
          id: 'il-batt',
          kind: PowerInterlockKind.electrical,
          aId: 'battinv',
          bId: 'ups-bus',
          relation: PowerInterlockRelation.sequence,
          note: 'Double-conversion UPS: the critical bus rides the battery through any transfer gap (genset start, ATS changeover).',
        ));
      } else {
        edge('battinv', backedBus, 'AC');
        interlocks.add(PowerInterlock(
          id: 'il-batt',
          kind: PowerInterlockKind.electrical,
          aId: 'battinv',
          bId: backedBus,
          relation: PowerInterlockRelation.sequence,
          note: 'Battery inverter transfers the essential load on outage (UPS / island mode).',
        ));
      }
    }
  }

  return PowerOneLine(nodes: nodes, edges: edges, interlocks: interlocks);
}

/// Size the generator for the one-line: a forced kVA wins, else the demand ×
/// backupFraction is the backup demand.
GeneratorResult _sizeGen(GeneratorSource gen, ApparentPower demand) {
  final backup = gen.kva ??
      ApparentPower(demand.voltAmperes * gen.backupFraction);
  return sizeGenerator(
    backup,
    mode: gen.mode,
    transfer: gen.transfer,
    forcedKva: gen.kva,
  );
}

/// Convert an apparent-power demand to a real-power critical load for battery
/// sizing, at the genset power factor (a representative building PF).
Power _demandToPower(ApparentPower demand) =>
    Power(demand.voltAmperes * kGeneratorPf);

String? _hybridInverterSub(SolarResult? solar, BatteryResult? batt) {
  final kw = [
    solar?.inverterKw.inKiloWatts ?? 0,
    batt?.inverterKw.inKiloWatts ?? 0,
  ].reduce((a, b) => a > b ? a : b);
  if (kw <= 0) return null;
  return '${_fmt(kw)} kW';
}
