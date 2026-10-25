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
import 'model.dart' show SupplyKind;
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
  ApparentPower? backupDemand,
  Power? backupPower,
  Power? demandPower,
  String? utilitySub,
  SupplyKind supplyKind = SupplyKind.pln,
  ApparentPower? supplyCapacity,
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
  // an A8 supply concern, deliberately out of scope here. Round 23
  // (elec-drafting-2-2) — [utilitySub] names a DECLARED MV service ('MV via
  // TX 2 x 1600 kVA'), so the one-line never calls a tower's MV supply
  // '400 V LV' while the riser of the same set draws its transformer.
  //
  // Round 58 (elec-convergence-10-power-oneline-pln-on-genset-supply) — the
  // head follows [supplyKind], the SAME primary supply the overview / riser
  // spine prints: an on-site GENERATOR plant is 'GENSET SUPPLY <kVA>' (and
  // `sources.generator` IS that plant — no second set, no ATS, no mains
  // interlocks: there is no grid to transfer from), a SOLAR plant 'PV
  // SUPPLY'. PLN ⇒ byte-identical.
  final genPrimary = supplyKind == SupplyKind.generator;
  final cap = supplyCapacity?.inKilovoltAmperes;
  final capText = (cap != null && cap > 0) ? '${_fmt(cap)} kVA' : null;
  final headId = supplyKind == SupplyKind.pln ? 'utility' : 'supply';
  final utilityOut = headId;

  // Pre-size the configured sources.
  final gen = sources.generator;
  final genResult =
      gen == null ? null : _sizeGen(gen, demand, backupDemand, backupPower);
  // Motor-start voltage-dip screen for the sized genset — annotated onto the
  // generator node so the one-line carries the load-acceptance verdict.
  final gensetStart = genResult == null
      ? null
      // Paralleled sets share the start transient — screen the dip on the
      // TOTAL running kVA, not one set (audit r8-5).
      : assessGensetStart(
          ApparentPower.kilovoltAmperes(
              genResult.ratingKva.inKilovoltAmperes * genResult.units),
          motors: motors);

  // The primary genset plant: the declared capacity when stated, else the
  // sized set (units x rating) — the start-dip screen runs on that plant.
  final plantKva = genPrimary
      ? (cap != null && cap > 0
          ? cap
          : genResult == null
              ? null
              : genResult.ratingKva.inKilovoltAmperes * genResult.units)
      : null;
  final plantStart = plantKva == null || plantKva <= 0
      ? null
      : assessGensetStart(ApparentPower.kilovoltAmperes(plantKva),
          motors: motors);
  switch (supplyKind) {
    case SupplyKind.pln:
      nodes.add(PowerNode(
        id: 'utility',
        kind: PowerNodeKind.utility,
        label: 'PLN utility',
        sub: utilitySub ?? '${_fmt(voltage.volts)} V LV',
      ));
    case SupplyKind.generator:
      final dip = (plantStart != null && !plantStart.acceptable)
          ? ' · start dip ${plantStart.estimatedDipPct}% over'
          : '';
      final fig = capText ??
          (genResult == null
              ? null
              : '${genResult.units > 1 ? '${genResult.units} x ' : ''}'
                  '${_fmt(genResult.ratingKva.inKilovoltAmperes)} kVA');
      final parts = [
        if (fig != null) fig,
        if (gen != null) gen.mode.label,
      ];
      nodes.add(PowerNode(
        id: 'supply',
        kind: PowerNodeKind.generator,
        label: 'GENSET SUPPLY',
        sub: parts.isEmpty && dip.isEmpty ? null : '${parts.join(' ')}$dip',
      ));
    case SupplyKind.solar:
      nodes.add(PowerNode(
        id: 'supply',
        kind: PowerNodeKind.pv,
        label: 'PV SUPPLY',
        sub: capText,
      ));
  }

  // Round 44 — ONE sizing of the distributed sources, shared with the BOM
  // and the equipment schedule ([sizeDistributedSources]).
  final ds = sizeDistributedSources(sources,
      demand: demand, demandPower: demandPower);
  final solarResult = ds.solar;
  final batteryResult = ds.battery;
  final hybrid = ds.hybrid;

  // Essential split: a genset that backs only a fraction transfers a dedicated
  // ESSENTIAL bus (non-hybrid topology); the battery then backs a CRITICAL bus.
  final essentialSplit =
      gen != null && !genPrimary && !hybrid && gen.backupFraction < 1.0;
  var backedBus = 'bus';

  // Generator via ATS / COS, with the mains↔genset interlock.
  var gridOut = utilityOut;
  // On a genset primary supply the generator IS the head node above.
  final genNodeId = genPrimary ? headId : 'gen';
  if (genPrimary) {
    if (!hybrid) edge(utilityOut, 'bus', 'genset');
  } else if (genResult != null && gen != null) {
    final manualTransfer = gen.transfer.isManual;
    final dipTag = (gensetStart != null && !gensetStart.acceptable)
        ? ' · start dip ${gensetStart.estimatedDipPct}% over'
        : '';
    nodes.add(PowerNode(
      id: 'gen',
      kind: PowerNodeKind.generator,
      label: 'Generator',
      sub: '${genResult.units > 1 ? '${genResult.units} x ' : ''}'
          '${_fmt(genResult.ratingKva.inKilovoltAmperes)} kVA '
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
      aId: headId,
      bId: 'gen',
      relation: PowerInterlockRelation.mutualExclusion,
      note: manualTransfer
          ? 'Mains and generator must never be paralleled — the changeover (COS) is break-before-make by construction.'
          : 'Mains and generator must never be paralleled — mechanical interlock at the ATS.',
    ));
    interlocks.add(PowerInterlock(
      id: 'il-ats-elec',
      kind: PowerInterlockKind.electrical,
      aId: headId,
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
    if (genResult != null || genPrimary) {
      interlocks.add(PowerInterlock(
        id: 'il-hybrid-gen',
        kind: PowerInterlockKind.electrical,
        aId: 'hinv',
        bId: genNodeId,
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
        sub: inverterRatingLabel(
            solarResult.inverterKw, solarResult.inverterUnits),
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
      if (genResult != null || genPrimary) {
        interlocks.add(PowerInterlock(
          id: 'il-pv-gen',
          kind: PowerInterlockKind.electrical,
          aId: 'pvinv',
          bId: genNodeId,
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
        sub: inverterRatingLabel(
            batteryResult.inverterKw, batteryResult.inverterUnits),
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

/// Size the generator for the one-line: a forced kVA wins, else the resolved
/// [backupDemand] (Round 13 — `max(fraction × demand, essential demand)` from
/// `gensetBackupDemandVa`), else the demand × backupFraction.
///
/// Round 47 (cross-surface-oneline-essential-bus-prints-forced-nameplate) —
/// the forced nameplate picks the RATING only (via `forcedKva` / `forcedUnits`);
/// the backup DEMAND stays the solved basis, so the 'Essential bus' figure and
/// the 'backing N kVA' note never echo whatever nameplate was typed.
GeneratorResult _sizeGen(GeneratorSource gen, ApparentPower demand,
    ApparentPower? backupDemand, Power? backupPower) {
  final backup =
      backupDemand ?? ApparentPower(demand.voltAmperes * gen.backupFraction);
  return sizeGenerator(
    backup,
    mode: gen.mode,
    transfer: gen.transfer,
    forcedKva: gen.kva,
    forcedUnits: gen.units,
    backupPower: backupPower,
  );
}

/// Round 44 (elec-report-bom-3-battery-inverter-pv-never-taken-off) — the
/// distributed sources (PV array, battery bank) sized ONCE: the power
/// one-line draws them, the BOM buys them and the equipment schedule lists
/// them from this one call, so the three can never disagree.
///
/// The battery backs the building demand. Round 16 (supply-sources-battery-
/// critical-load-pf) — its critical load is the REAL demand W
/// ([demandPower]) when known; the assumed-PF conversion of [demand] stays
/// only as the fallback. [hybrid] = PV + battery (or a forced hybrid) share
/// ONE hybrid inverter.
({SolarResult? solar, BatteryResult? battery, bool hybrid})
    sizeDistributedSources(
  ElectricalSources sources, {
  required ApparentPower demand,
  Power? demandPower,
}) {
  final solar = sources.solar;
  final solarResult = solar == null
      ? null
      : sizeSolar(
          panelWp: solar.panelWp,
          panels: solar.panels,
          dcAcRatio: solar.dcAcRatio);
  final batt = sources.battery;
  final batteryResult = batt == null
      ? null
      : sizeBattery(demandPower ?? _demandToPower(demand),
          autonomyHours: batt.autonomyHours, chemistry: batt.chemistry);
  final solarOn = solarResult != null;
  final battOn = batteryResult != null;
  final hybrid =
      (sources.hybridInverter ?? (solarOn && battOn)) && (solarOn || battOn);
  return (solar: solarResult, battery: batteryResult, hybrid: hybrid);
}

/// The inverter the distributed sources need: one HYBRID inverter (the
/// larger of the PV / battery inverters, as the one-line labels it), else
/// each DC source's own. Unit kW × units. Pure.
List<({String kind, Power unitKw, int units})> distributedSourceInverters(
    ({SolarResult? solar, BatteryResult? battery, bool hybrid}) ds) {
  final s = ds.solar;
  final b = ds.battery;
  if (ds.hybrid) {
    final sKw = s == null ? 0.0 : s.inverterKw.inKiloWatts * s.inverterUnits;
    final bKw = b == null ? 0.0 : b.inverterKw.inKiloWatts * b.inverterUnits;
    if (sKw <= 0 && bKw <= 0) return const [];
    return sKw >= bKw && s != null
        ? [(kind: 'hybrid', unitKw: s.inverterKw, units: s.inverterUnits)]
        : [(kind: 'hybrid', unitKw: b!.inverterKw, units: b.inverterUnits)];
  }
  return [
    if (s != null && s.inverterKw.inKiloWatts > 0)
      (kind: 'pv', unitKw: s.inverterKw, units: s.inverterUnits),
    if (b != null && b.inverterKw.inKiloWatts > 0)
      (kind: 'battery', unitKw: b.inverterKw, units: b.inverterUnits),
  ];
}

/// Convert an apparent-power demand to a real-power critical load for battery
/// sizing, at the genset power factor (a representative building PF).
Power _demandToPower(ApparentPower demand) =>
    Power(demand.voltAmperes * kGeneratorPf);

String? _hybridInverterSub(SolarResult? solar, BatteryResult? batt) {
  final s = solar == null
      ? 0.0
      : solar.inverterKw.inKiloWatts * solar.inverterUnits;
  final b = batt == null
      ? 0.0
      : batt.inverterKw.inKiloWatts * batt.inverterUnits;
  final kw = s > b ? s : b;
  if (kw <= 0) return null;
  final pick = s >= b ? solar! : null;
  return pick != null
      ? inverterRatingLabel(pick.inverterKw, pick.inverterUnits)
      : inverterRatingLabel(batt!.inverterKw, batt.inverterUnits);
}
