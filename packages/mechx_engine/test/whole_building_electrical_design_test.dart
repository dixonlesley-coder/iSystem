/// EXPLORATORY HARNESS (temporary) — dump the whole-building design.
library;

import 'package:mechx_engine/electrical/advanced_study.dart';
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/control/starter.dart';
import 'package:mechx_engine/electrical/earthing.dart';
import 'package:mechx_engine/electrical/fault.dart';
import 'package:mechx_engine/electrical/headroom.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/panel_results.dart';
import 'package:mechx_engine/electrical/sources.dart';
import 'package:mechx_engine/report/electrical_sld_drawing.dart';
import 'package:mechx_engine/report/sld_sheet.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

ElectricalCircuit _lighting(String id, String name, double w, double m) =>
    ElectricalCircuit(
      id: id,
      name: name,
      loadW: w,
      cosPhi: 0.9,
      length: Length(m),
      loadKind: LoadKind.lighting,
      isLighting: true,
      cableType: 'NYM',
    );

ElectricalCircuit _socket(String id, String name, double w, double m,
        {int points = 6}) =>
    ElectricalCircuit(
      id: id,
      name: name,
      loadW: w,
      points: points,
      cosPhi: 0.9,
      length: Length(m),
      loadKind: LoadKind.socket,
      demandFactor: 0.7,
      cableType: 'NYM',
    );

ElectricalCircuit _feeder(String id, String name, String child, double m) =>
    ElectricalCircuit(
      id: id,
      name: name,
      length: Length(m),
      loadKind: LoadKind.feeder,
      cableType: 'NYY',
      feedsPanelId: child,
    );

ElectricalProject _project() {
  final lp1 = ElectricalPanel(
    id: 'lp1',
    name: 'Lighting Panel L1',
    tag: 'LP-1',
    system: ElectricalSystem.threePhase,
    voltage: const Voltage(400),
    ambientTempC: 35,
    groupingCount: 3,
    diversityFactor: 0.9,
    sourceType: PanelSource.feeder,
    headroom: const HeadroomSpec(sparePercentage: 20, spareWays: 3),
    circuits: [
      _lighting('lp1-l1', 'Lighting zone A', 1800, 35),
      _lighting('lp1-l2', 'Lighting zone B', 1600, 40),
      _lighting('lp1-l3', 'Lighting corridor', 1200, 28),
      _socket('lp1-s1', 'Sockets zone A', 3000, 30),
      _socket('lp1-s2', 'Sockets zone B', 3000, 34),
      _socket('lp1-s3', 'Pantry sockets', 2200, 22, points: 4),
    ],
  );
  final lp2 = ElectricalPanel(
    id: 'lp2',
    name: 'Lighting Panel L2',
    tag: 'LP-2',
    ambientTempC: 35,
    groupingCount: 3,
    diversityFactor: 0.9,
    sourceType: PanelSource.feeder,
    headroom: const HeadroomSpec(sparePercentage: 20, spareWays: 3),
    circuits: [
      _lighting('lp2-l1', 'Lighting zone A', 1900, 38),
      _lighting('lp2-l2', 'Lighting zone B', 1500, 42),
      _lighting('lp2-l3', 'Lighting corridor', 1200, 30),
      _socket('lp2-s1', 'Sockets zone A', 3200, 32),
      _socket('lp2-s2', 'Sockets zone B', 2800, 36),
      _socket('lp2-s3', 'Meeting rooms sockets', 2400, 26, points: 5),
    ],
  );
  // Top floor: a small single-phase board (220 V) — mixed by design.
  final lp3 = ElectricalPanel(
    id: 'lp3',
    name: 'Lighting Panel L3',
    tag: 'LP-3',
    system: ElectricalSystem.singlePhase,
    voltage: const Voltage(220),
    ambientTempC: 35,
    groupingCount: 3,
    diversityFactor: 0.9,
    sourceType: PanelSource.feeder,
    headroom: const HeadroomSpec(sparePercentage: 20, spareWays: 2),
    circuits: [
      _lighting('lp3-l1', 'Lighting open plan', 1400, 30),
      _lighting('lp3-l2', 'Lighting corridor', 1000, 24),
      _socket('lp3-s1', 'Sockets open plan', 2600, 28),
      _socket('lp3-s2', 'Pantry sockets', 2000, 20, points: 4),
    ],
  );
  final pp1 = ElectricalPanel(
    id: 'pp1',
    name: 'Power Panel',
    tag: 'PP-1',
    ambientTempC: 35,
    groupingCount: 4,
    diversityFactor: 0.85,
    sourceType: PanelSource.feeder,
    headroom: const HeadroomSpec(sparePercentage: 25, spareWays: 4),
    circuits: [
      const ElectricalCircuit(
        id: 'pp1-wk',
        name: 'Workshop sockets 3ph',
        loadW: 6000,
        points: 3,
        cosPhi: 0.9,
        length: Length(28),
        loadKind: LoadKind.socket,
        demandFactor: 0.7,
        phases: 3,
        cableType: 'NYY',
      ),
      const ElectricalCircuit(
        id: 'pp1-wh1',
        name: 'Water heater P1',
        loadW: 4500,
        cosPhi: 1.0,
        length: Length(30),
        loadKind: LoadKind.heating,
        cableType: 'NYM',
      ),
      const ElectricalCircuit(
        id: 'pp1-wh2',
        name: 'Water heater P2',
        loadW: 4500,
        cosPhi: 1.0,
        length: Length(34),
        loadKind: LoadKind.heating,
        cableType: 'NYM',
      ),
      const ElectricalCircuit(
        id: 'pp1-cmp',
        name: 'Air compressor',
        motorKw: 11,
        cosPhi: 0.85,
        length: Length(24),
        loadKind: LoadKind.motor,
        cableType: 'NYY',
        starterType: StarterType.starDelta,
      ),
      const ElectricalCircuit(
        id: 'pp1-tp',
        name: 'Transfer pump',
        motorKw: 5.5,
        cosPhi: 0.85,
        length: Length(40),
        loadKind: LoadKind.pump,
        cableType: 'NYY',
        starterType: StarterType.dol,
      ),
    ],
  );
  final ac1 = ElectricalPanel(
    id: 'ac1',
    name: 'AC Panel',
    tag: 'AC-1',
    ambientTempC: 35,
    groupingCount: 4,
    diversityFactor: 0.9,
    sourceType: PanelSource.feeder,
    headroom: const HeadroomSpec(sparePercentage: 20, spareWays: 3),
    circuits: [
      const ElectricalCircuit(
        id: 'ac1-ahu1',
        name: 'AHU-1 ducted',
        loadW: 7500,
        cosPhi: 0.85,
        length: Length(30),
        loadKind: LoadKind.hvac,
        demandFactor: 0.9,
        cableType: 'NYY',
        starterType: StarterType.vfd,
      ),
      const ElectricalCircuit(
        id: 'ac1-ahu2',
        name: 'AHU-2 ducted',
        loadW: 7500,
        cosPhi: 0.85,
        length: Length(36),
        loadKind: LoadKind.hvac,
        demandFactor: 0.9,
        cableType: 'NYY',
        starterType: StarterType.vfd,
      ),
      const ElectricalCircuit(
        id: 'ac1-cu1',
        name: 'Condensing unit CU-1',
        loadW: 5200,
        cosPhi: 0.85,
        length: Length(42),
        loadKind: LoadKind.hvac,
        demandFactor: 0.9,
        cableType: 'NYY',
      ),
      const ElectricalCircuit(
        id: 'ac1-sp1',
        name: 'Split AC office A',
        loadW: 2500,
        cosPhi: 0.85,
        length: Length(26),
        loadKind: LoadKind.hvac,
        demandFactor: 0.9,
        cableType: 'NYM',
      ),
      const ElectricalCircuit(
        id: 'ac1-sp2',
        name: 'Split AC office B',
        loadW: 2500,
        cosPhi: 0.85,
        length: Length(32),
        loadKind: LoadKind.hvac,
        demandFactor: 0.9,
        cableType: 'NYM',
      ),
      const ElectricalCircuit(
        id: 'ac1-ef',
        name: 'Toilet exhaust fans',
        loadW: 1500,
        cosPhi: 0.85,
        length: Length(45),
        loadKind: LoadKind.hvac,
        demandFactor: 0.9,
        cableType: 'NYM',
      ),
    ],
  );
  final ep1 = ElectricalPanel(
    id: 'ep1',
    name: 'Essential Panel',
    tag: 'EP-1',
    ambientTempC: 35,
    groupingCount: 3,
    diversityFactor: 1.0,
    sourceType: PanelSource.feeder,
    essential: true,
    headroom: const HeadroomSpec(sparePercentage: 25, spareWays: 3),
    circuits: [
      const ElectricalCircuit(
        id: 'ep1-fp',
        name: 'Fire pump',
        motorKw: 15,
        cosPhi: 0.85,
        length: Length(35),
        loadKind: LoadKind.pump,
        lifeSafety: true,
        cableType: 'FRC',
        starterType: StarterType.starDelta,
      ),
      const ElectricalCircuit(
        id: 'ep1-jp',
        name: 'Jockey pump',
        motorKw: 3.7,
        cosPhi: 0.85,
        length: Length(35),
        loadKind: LoadKind.pump,
        lifeSafety: true,
        cableType: 'FRC',
        starterType: StarterType.dol,
      ),
      const ElectricalCircuit(
        id: 'ep1-lift',
        name: 'Lift motor',
        motorKw: 11,
        cosPhi: 0.85,
        length: Length(28),
        loadKind: LoadKind.motor,
        cableType: 'NYY',
        starterType: StarterType.vfd,
      ),
      const ElectricalCircuit(
        id: 'ep1-el',
        name: 'Emergency lighting',
        loadW: 1500,
        cosPhi: 0.9,
        length: Length(48),
        loadKind: LoadKind.lighting,
        isLighting: true,
        lifeSafety: true,
        cableType: 'FRC',
      ),
      const ElectricalCircuit(
        id: 'ep1-sf',
        name: 'Staircase pressurisation fan',
        loadW: 4000,
        cosPhi: 0.85,
        length: Length(40),
        loadKind: LoadKind.hvac,
        demandFactor: 1,
        lifeSafety: true,
        cableType: 'FRC',
      ),
    ],
  );
  final mdp = ElectricalPanel(
    id: 'mdp',
    name: 'Main Distribution Panel',
    tag: 'MDP',
    ambientTempC: 35,
    groupingCount: 6,
    diversityFactor: 0.9,
    headroom: const HeadroomSpec(sparePercentage: 20, spareWays: 2),
    circuits: [
      _feeder('mdp-f-lp1', 'Feeder LP-1', 'lp1', 24),
      _feeder('mdp-f-lp2', 'Feeder LP-2', 'lp2', 30),
      _feeder('mdp-f-lp3', 'Feeder LP-3', 'lp3', 36),
      _feeder('mdp-f-pp1', 'Feeder PP-1', 'pp1', 22),
      _feeder('mdp-f-ac1', 'Feeder AC-1', 'ac1', 26),
      _feeder('mdp-f-ep1', 'Feeder EP-1', 'ep1', 20),
    ],
  );

  return ElectricalProject(
    id: 'office3',
    name: 'Gedung Kantor 3 Lantai',
    earthingSystem: EarthingSystem.tnCs,
    supplyKind: SupplyKind.pln,
    supplyCapacityVa: ApparentPower(197000),
    capacitorBankKvar: 30,
    occupancy: 'office',
    sources: const ElectricalSources(
      generator: GeneratorSource(
        backupFraction: 0.45,
        mode: GeneratorMode.standby,
        transfer: GeneratorTransfer.ats,
      ),
    ),
    panels: [mdp, lp1, lp2, lp3, pp1, ac1, ep1],
  );
}

void main() {
  const profile = PuilProfile();

  test('DUMP', () {
    final project = _project();
    final originFault = estimatedServiceFaultLevelA(project);
    print('estimatedServiceFaultLevelA = $originFault A');
    final sys = computeSystem(
      profile,
      project,
      originFaultLevel: originFault,
      busbarClearingTimeS: 0.1,
    );
    final adv = computeAdvancedStudy(profile, project, sys);

    print('order = ${sys.order}');
    print('totalDemandW = ${sys.totalDemandW}');
    print('supply connected=${sys.supply.connectedW} demandW=${sys.supply.demandW} '
        'VA=${sys.supply.demandVa.voltAmperes} sys=${sys.supply.system} V=${sys.supply.voltage.volts}');
    print('earthing = ${sys.earthing.system}');
    print('fault origin kA = ${adv.fault.originFaultkA}');
    print('recommendedDayaVa = ${adv.recommendedDayaVa}');
    print('pf = ${adv.powerFactor.existingPf} -> target');

    for (final id in sys.order) {
      final p = sys.panels[id]!;
      print('');
      print('=== ${p.tag} ${p.name} sys=${p.system} connected=${p.connectedW} '
          'demand=${p.demandW} demandI=${p.demandCurrent.amperes} '
          'future=${p.futureLoadW} incomer=${p.incomer.breaker.ratingA.amperes}A '
          '${p.incomer.breaker.deviceClass.name}/${p.incomer.breaker.curve.name} poles=${p.incomer.poles} '
          'bus=${p.busbar.csaMm2}mm2 icw=${p.busbar.withstand?.icwKa} ok=${p.busbar.withstand?.adequate} '
          'N=${p.neutralPeBars.neutralCsaMm2} PE=${p.neutralPeBars.peCsaMm2} '
          'imb=${p.imbalancePercent}% red=${p.phaseBalance.imbalanceReducible} '
          'L=${p.phaseBalance.l1}/${p.phaseBalance.l2}/${p.phaseBalance.l3} '
          'sections=${p.busbarSections.length} spare=${p.spareWaysReserved}');
      for (final c in p.circuits) {
        final cf = adv.fault.circuits[c.circuitId];
        print('   ${c.name.padRight(30)} Ib=${c.designCurrent.amperes}A '
            '${c.phase.label} ${c.breaker.deviceClass.name.toUpperCase()} '
            '${c.breaker.ratingA.amperes}A/${c.breaker.curve.name} '
            'cable=${c.cable.csaMm2}mm2 Iz=${c.cable.deratedIz.amperes} '
            'df=${c.cable.deratingFactor} amp=${c.cable.ampacityReached} '
            'vd=${c.voltageDrop.dropPercent}/${c.voltageDrop.limitPercent} cum=${c.cumulativeDropPercent} '
            'PE=${c.grounding.peCsaMm2} rcd=${c.rcd.required}/${c.rcd.ratingMa} '
            'L=${c.lengthM}m kA=${cf?.breakerKa} adq=${cf?.breakerAdequate} '
            'zs=${cf?.zsOhm} zsmax=${cf?.zsMaxOhm} ads=${cf?.adsOk}');
      }
      for (final w in p.warnings) {
        print('   !! ${w.severity.name} ${w.code}: ${w.message}');
      }
    }

    print('');
    print('--- system warnings ---');
    for (final w in sys.warnings) {
      print('${w.severity.name} ${w.code}: ${w.message}');
    }
    print('--- fault warnings ---');
    for (final w in adv.fault.warnings) {
      print('${w.severity.name} ${w.code}: ${w.message}');
    }
    print('--- selectivity ---');
    for (final s in adv.fault.selectivity) {
      print('${s.upstreamCircuitId} ${s.upstreamRatingA} -> ${s.downstreamPanelId} '
          '${s.downstreamRatingA} zone=${s.zone} ns=${s.nonSelective} '
          'icu=${s.icuAdequate} ics=${s.icsAdequate} icw=${s.icwAdequate}');
    }

    print('');
    print('--- MDP board schedule ---');
    final detail = buildElectricalPanelDetail(
      project: project,
      result: sys,
      panelId: 'mdp',
      breakerIcuKaByPanelId: {
        for (final e in adv.fault.panels.entries) e.key: e.value.incomerKa,
      },
    );
    for (final pr in detail.prims) {
      if (pr is SldLabel) print('  [${pr.x.toStringAsFixed(0)},${pr.y.toStringAsFixed(0)}] ${pr.text}');
    }

    final overview =
        buildElectricalOverview(project: project, result: sys, sourceChain: true);
    final riser =
        buildElectricalRiser(project: project, result: sys, sourceChain: true);
    final full = buildElectricalSld(project: project, result: sys);
    print('overview prims=${overview.prims.length} riser=${riser.prims.length} '
        'full=${full.prims.length}');
  });
}
