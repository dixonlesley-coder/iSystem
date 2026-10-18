// Sample-export generator: builds a representative mid-rise MEP fixture
// ("Menara Contoh", 3 floors: CW tank->booster->riser + fixtures, drainage +
// vent stacks, floor-1 AHU + diffusers, MDP->LP-1/PP-1/EMG electrical) and
// drives the real pure-engine export APIs to emit the full artifact set an
// Indonesian MEP consultant would issue (plan PDF/DXF, mech riser SLD,
// electrical detail/overview/riser, calc reports, equipment schedule, BOM).
// Used by the WORKFLOW-GOLDENS-REVIEW export-readiness audit to LOOK at the
// real deliverables. Run from the package dir:
//   dart run tool/generate_export_samples.dart [outDir]
// Dev tool only — not part of the app or the test gate.
// ignore_for_file: avoid_print, prefer_const_declarations
import 'dart:convert' show latin1;
import 'dart:io';
import 'dart:typed_data';

import 'package:mechx_engine/electrical/advanced_study.dart'
    show computeAdvancedStudy;
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/containment.dart' show ConduitSpec;
import 'package:mechx_engine/electrical/control/starter.dart' show StarterType;
import 'package:mechx_engine/electrical/earthing.dart' show EarthingSystem;
import 'package:mechx_engine/electrical/geo_length.dart'
    show LayoutPos, electricalCableLength;
import 'package:mechx_engine/electrical/headroom.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/load_list.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/panel_results.dart'
    show ElectricalSystemResult;
import 'package:mechx_engine/electrical/sources.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/duct_static.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/network/pressure_solve.dart';
import 'package:mechx_engine/report/calc_report.dart';
import 'package:mechx_engine/report/cover_sheet.dart';
import 'package:mechx_engine/report/drawing_chrome.dart';
import 'package:mechx_engine/report/dxf_export.dart';
import 'package:mechx_engine/report/electrical_calc_report.dart';
import 'package:mechx_engine/report/electrical_dxf_export.dart';
import 'package:mechx_engine/report/electrical_pdf_export.dart';
import 'package:mechx_engine/report/electrical_plan_export.dart';
import 'package:mechx_engine/report/electrical_sld_drawing.dart';
import 'package:mechx_engine/report/equipment_schedule.dart';
import 'package:mechx_engine/report/mechanical_sld_drawing.dart';
import 'package:mechx_engine/report/plan_pdf_export.dart';
import 'package:mechx_engine/report/plan_symbols.dart';
import 'package:mechx_engine/report/riser_tags.dart' show elementTags;
import 'package:mechx_engine/report/sld_export.dart';
import 'package:mechx_engine/sizing/bom.dart';
import 'package:mechx_engine/sizing/drainage_sizing.dart';
import 'package:mechx_engine/sizing/fan.dart';
import 'package:mechx_engine/sizing/fire_pump_rating.dart';
import 'package:mechx_engine/sizing/fire_standpipe.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/sizing/pump.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/standards/sni.dart';
import 'package:mechx_engine/units.dart';

// Output directory: first CLI arg, else build/export-samples under the
// package. Set in main() before anything writes.
String outDir = 'build/export-samples';
const projectName = 'Menara Contoh';
const dateString = '2026-07-06';

// ── Building + calibration ───────────────────────────────────────────────────
const building = BuildingLevels([
  Floor('Ground', Length(4.0)),
  Floor('Lantai 1', Length(4.0)),
  Floor('Lantai 2', Length(4.0)),
]);
final calibrations = <String, ScaleCalibration>{
  's0': const ScaleCalibration(0.02),
  's1': const ScaleCalibration(0.02),
  's2': const ScaleCalibration(0.02),
};

// N4: a representative structural setting-out grid (column axes A–D, row axes
// 1–3) in sheet pixels, threaded into the plan exports so a riser ties back to
// the nearest grid intersection (as a real drawing would carry from the
// architect's model).
const referenceGrid = ReferenceGrid(
  columns: [
    GridAxis('A', 170),
    GridAxis('B', 480),
    GridAxis('C', 760),
    GridAxis('D', 1040),
  ],
  rows: [
    GridAxis('1', 220),
    GridAxis('2', 320),
    GridAxis('3', 420),
  ],
);

// N5: the per-run centreline-elevation labels — the SAME engine function the
// app calls (`runCentrelineLabels`), so the harness can't drift from the app.
Map<String, String> elevationLabels(Network net) =>
    runCentrelineLabels(net, building);

// ── The drawn network ────────────────────────────────────────────────────────
Network buildNetwork() {
  final nodes = <NetNode>[];
  final edges = <NetEdge>[];
  void node(NetNode n) => nodes.add(n);
  void run(String id, String a, String b, ServiceType s,
          {EdgeKind kind = EdgeKind.run}) =>
      edges.add(NetEdge(id: id, fromId: a, toId: b, service: s, kind: kind));

  // ── COLD WATER: ground tank -> booster pump -> riser -> per-floor branches ──
  node(const NetNode(
      id: 'cw-gtank', sheetId: 's0', x: 90, y: 540, floorIndex: 0,
      role: NodeRole.plant, component: NodeComponent.groundTank,
      // Ground tank + booster stand on the ground slab (FFL 0.00), not the
      // roof the bare plant role would assume.
      elevation: Length(0), tankCapacityLitres: 5000));
  node(const NetNode(
      id: 'cw-pump', sheetId: 's0', x: 170, y: 540, floorIndex: 0,
      role: NodeRole.plant, component: NodeComponent.pump,
      // No hand-typed electrical load: the pump duty (and its electrical
      // circuit) is DERIVED from the pressure solve — one source of truth.
      elevation: Length(0)));
  node(const NetNode(
      id: 'cw-b0', sheetId: 's0', x: 170, y: 320, floorIndex: 0));
  node(const NetNode(
      id: 'cw-b1', sheetId: 's1', x: 170, y: 320, floorIndex: 1));
  node(const NetNode(
      id: 'cw-b2', sheetId: 's2', x: 170, y: 320, floorIndex: 2));
  run('cw-e-gt', 'cw-gtank', 'cw-pump', ServiceType.coldWater);
  run('cw-e-pb', 'cw-pump', 'cw-b0', ServiceType.coldWater);
  run('cw-r01', 'cw-b0', 'cw-b1', ServiceType.coldWater, kind: EdgeKind.riser);
  run('cw-r12', 'cw-b1', 'cw-b2', ServiceType.coldWater, kind: EdgeKind.riser);
  // Floor 1 branch + fixtures.
  node(const NetNode(id: 'cw-h1', sheetId: 's1', x: 380, y: 320, floorIndex: 1));
  node(const NetNode(
      id: 'cw-wc1', sheetId: 's1', x: 480, y: 220, floorIndex: 1,
      role: NodeRole.fixture, fixture: PlumbingFixture.waterClosetFlushValve));
  node(const NetNode(
      id: 'cw-lav1', sheetId: 's1', x: 480, y: 320, floorIndex: 1,
      role: NodeRole.fixture, fixture: PlumbingFixture.lavatory));
  node(const NetNode(
      id: 'cw-sh1', sheetId: 's1', x: 480, y: 420, floorIndex: 1,
      role: NodeRole.fixture, fixture: PlumbingFixture.shower));
  run('cw-h1', 'cw-b1', 'cw-h1', ServiceType.coldWater);
  run('cw-w1', 'cw-h1', 'cw-wc1', ServiceType.coldWater);
  run('cw-l1', 'cw-h1', 'cw-lav1', ServiceType.coldWater);
  run('cw-s1', 'cw-h1', 'cw-sh1', ServiceType.coldWater);
  // Floor 2 branch + fixtures.
  node(const NetNode(id: 'cw-h2', sheetId: 's2', x: 380, y: 320, floorIndex: 2));
  node(const NetNode(
      id: 'cw-wc2', sheetId: 's2', x: 480, y: 220, floorIndex: 2,
      role: NodeRole.fixture, fixture: PlumbingFixture.waterClosetFlushValve));
  node(const NetNode(
      id: 'cw-lav2', sheetId: 's2', x: 480, y: 320, floorIndex: 2,
      role: NodeRole.fixture, fixture: PlumbingFixture.lavatory));
  node(const NetNode(
      id: 'cw-sh2', sheetId: 's2', x: 480, y: 420, floorIndex: 2,
      role: NodeRole.fixture, fixture: PlumbingFixture.shower));
  run('cw-h2', 'cw-b2', 'cw-h2', ServiceType.coldWater);
  run('cw-w2', 'cw-h2', 'cw-wc2', ServiceType.coldWater);
  run('cw-l2', 'cw-h2', 'cw-lav2', ServiceType.coldWater);
  run('cw-s2', 'cw-h2', 'cw-sh2', ServiceType.coldWater);

  // ── HOT WATER: heater base -> riser -> per-floor lavatories (recirc loop) ───
  // A hot-water supply riser + branches; the recirc RETURN leg (G2) is drawn by
  // the riser SLD from the hotWaterRecirc signal, not a drawn return edge.
  node(const NetNode(id: 'hw-b0', sheetId: 's0', x: 250, y: 380, floorIndex: 0));
  node(const NetNode(id: 'hw-b1', sheetId: 's1', x: 250, y: 380, floorIndex: 1));
  node(const NetNode(id: 'hw-b2', sheetId: 's2', x: 250, y: 380, floorIndex: 2));
  run('hw-r01', 'hw-b0', 'hw-b1', ServiceType.hotWater, kind: EdgeKind.riser);
  run('hw-r12', 'hw-b1', 'hw-b2', ServiceType.hotWater, kind: EdgeKind.riser);
  node(const NetNode(
      id: 'hw-lav1', sheetId: 's1', x: 320, y: 380, floorIndex: 1,
      role: NodeRole.fixture, fixture: PlumbingFixture.lavatory));
  node(const NetNode(
      id: 'hw-lav2', sheetId: 's2', x: 320, y: 380, floorIndex: 2,
      role: NodeRole.fixture, fixture: PlumbingFixture.lavatory));
  run('hw-l1', 'hw-b1', 'hw-lav1', ServiceType.hotWater);
  run('hw-l2', 'hw-b2', 'hw-lav2', ServiceType.hotWater);

  // ── DRAINAGE stack + per-floor fixture branches -> ground exit ──────────────
  node(const NetNode(
      id: 'dr-exit', sheetId: 's0', x: 640, y: 560, floorIndex: 0));
  node(const NetNode(
      id: 'dr-co0', sheetId: 's0', x: 640, y: 340, floorIndex: 0,
      component: NodeComponent.cleanout));
  node(const NetNode(id: 'dr-b1', sheetId: 's1', x: 640, y: 320, floorIndex: 1));
  node(const NetNode(id: 'dr-b2', sheetId: 's2', x: 640, y: 320, floorIndex: 2));
  run('dr-exit', 'dr-exit', 'dr-co0', ServiceType.drainage);
  run('dr-r01', 'dr-co0', 'dr-b1', ServiceType.drainage, kind: EdgeKind.riser);
  run('dr-r12', 'dr-b1', 'dr-b2', ServiceType.drainage, kind: EdgeKind.riser);
  node(const NetNode(
      id: 'dr-wc1', sheetId: 's1', x: 760, y: 220, floorIndex: 1,
      role: NodeRole.fixture, fixture: PlumbingFixture.waterClosetFlushValve));
  node(const NetNode(
      id: 'dr-lav1', sheetId: 's1', x: 760, y: 320, floorIndex: 1,
      role: NodeRole.fixture, fixture: PlumbingFixture.lavatory));
  node(const NetNode(
      id: 'dr-fd1', sheetId: 's1', x: 760, y: 420, floorIndex: 1,
      role: NodeRole.fixture, component: NodeComponent.floorDrain));
  run('dr-w1', 'dr-b1', 'dr-wc1', ServiceType.drainage);
  run('dr-l1', 'dr-b1', 'dr-lav1', ServiceType.drainage);
  run('dr-f1', 'dr-b1', 'dr-fd1', ServiceType.drainage);
  node(const NetNode(
      id: 'dr-wc2', sheetId: 's2', x: 760, y: 220, floorIndex: 2,
      role: NodeRole.fixture, fixture: PlumbingFixture.waterClosetFlushValve));
  node(const NetNode(
      id: 'dr-lav2', sheetId: 's2', x: 760, y: 320, floorIndex: 2,
      role: NodeRole.fixture, fixture: PlumbingFixture.lavatory));
  node(const NetNode(
      id: 'dr-fd2', sheetId: 's2', x: 760, y: 420, floorIndex: 2,
      role: NodeRole.fixture, component: NodeComponent.floorDrain));
  run('dr-w2', 'dr-b2', 'dr-wc2', ServiceType.drainage);
  run('dr-l2', 'dr-b2', 'dr-lav2', ServiceType.drainage);
  run('dr-f2', 'dr-b2', 'dr-fd2', ServiceType.drainage);

  // ── VENT stack alongside the drainage stack (tee off the stack, VTR at top) ─
  node(const NetNode(id: 'vt-1', sheetId: 's1', x: 700, y: 260, floorIndex: 1));
  node(const NetNode(id: 'vt-2', sheetId: 's2', x: 700, y: 260, floorIndex: 2));
  node(const NetNode(id: 'vt-top', sheetId: 's2', x: 700, y: 170, floorIndex: 2));
  run('vt-t1', 'dr-b1', 'vt-1', ServiceType.vent);
  run('vt-r12', 'vt-1', 'vt-2', ServiceType.vent, kind: EdgeKind.riser);
  run('vt-vtr', 'vt-2', 'vt-top', ServiceType.vent);

  // ── HVAC (floor 1): AHU -> supply trunk -> 3 supply diffusers ───────────────
  node(const NetNode(
      id: 'ahu1', sheetId: 's1', x: 940, y: 520, floorIndex: 1,
      role: NodeRole.plant, component: NodeComponent.ahu,
      elevation: Length(4.0))); // floor-standing on Lantai 1 (FFL +4.00)
  node(const NetNode(id: 'sa-h1', sheetId: 's1', x: 940, y: 320, floorIndex: 1));
  node(const NetNode(
      id: 'sd1', sheetId: 's1', x: 1040, y: 220, floorIndex: 1,
      role: NodeRole.fixture, component: NodeComponent.supplyDiffuser,
      airflow: FlowRate(0.12), faceWidthMm: 300, faceHeightMm: 300));
  node(const NetNode(
      id: 'sd2', sheetId: 's1', x: 1040, y: 320, floorIndex: 1,
      role: NodeRole.fixture, component: NodeComponent.supplyDiffuser,
      airflow: FlowRate(0.12), faceWidthMm: 300, faceHeightMm: 300));
  node(const NetNode(
      id: 'sd3', sheetId: 's1', x: 1040, y: 420, floorIndex: 1,
      role: NodeRole.fixture, component: NodeComponent.supplyDiffuser,
      airflow: FlowRate(0.12), faceWidthMm: 300, faceHeightMm: 300));
  run('sa-t', 'ahu1', 'sa-h1', ServiceType.duct);
  run('sa-d1', 'sa-h1', 'sd1', ServiceType.duct);
  run('sa-d2', 'sa-h1', 'sd2', ServiceType.duct);
  run('sa-d3', 'sa-h1', 'sd3', ServiceType.duct);

  return Network(nodes: nodes, edges: edges);
}

// ── Sizing (mirrors lib/store/sizing_store.dart) ─────────────────────────────
Map<String, EdgeSizing> sizeNetwork(Network net) {
  const profile = SniProfile();
  const occupancy = Occupancy.public;
  final nodeFixtureUnits = <String, double>{
    for (final n in net.nodes)
      if (n.fixture != null)
        n.id: profile.fixtureUnitLoad(n.fixture!, occupancy: occupancy),
  };
  final nodeDrainageUnits = <String, double>{
    for (final n in net.nodes)
      if (n.fixture != null) n.id: drainageFixtureUnit(n.fixture!),
  };
  final nodeFlowDemand = <String, FlowRate>{
    for (final n in net.nodes)
      if (n.airflow != null) n.id: n.airflow!,
  };
  final anyFlushValve = net.nodes
      .any((n) => n.fixture == PlumbingFixture.waterClosetFlushValve);
  const leafDemand = <ServiceType, FlowRate>{
    ServiceType.duct: FlowRate(0.05),
    ServiceType.returnAir: FlowRate(0.05),
    ServiceType.exhaust: FlowRate(0.03),
    ServiceType.coldWater: FlowRate(0.0002),
    ServiceType.hotWater: FlowRate(0.0002),
    ServiceType.drainage: FlowRate(0.0008),
    ServiceType.vent: FlowRate(0.0004),
    ServiceType.rainwater: FlowRate(0.001),
    ServiceType.fireSprinkler: FlowRate(0.0005),
    ServiceType.fireHydrant: FlowRate(0.005),
  };
  const leafFixtureUnits = <ServiceType, double>{
    ServiceType.coldWater: 2.0,
    ServiceType.hotWater: 2.0,
  };
  return autoSizeNetwork(
    net,
    const SizingContext(),
    leafDemand: leafDemand,
    leafFixtureUnits: leafFixtureUnits,
    nodeFixtureUnits: nodeFixtureUnits,
    nodeDrainageUnits: nodeDrainageUnits,
    nodeFlowDemand: nodeFlowDemand,
    flushSystem: anyFlushValve ? FlushSystem.flushValve : FlushSystem.flushTank,
    building: building,
    calibrationBySheet: calibrations,
  );
}

// N16: per-edge accumulated fixture units for the calc-report run/riser
// schedule — cold-water UBAP (rooted at the ground tank) + drainage DFU (rooted
// at the ground exit), the same node loads the sizing uses.
Map<String, double> buildEdgeFixtureUnits(Network net) {
  const profile = SniProfile();
  const occupancy = Occupancy.public;
  final cwUnits = <String, double>{
    for (final n in net.nodes)
      if (n.fixture != null)
        n.id: profile.fixtureUnitLoad(n.fixture!, occupancy: occupancy),
  };
  final drUnits = <String, double>{
    for (final n in net.nodes)
      if (n.fixture != null) n.id: drainageFixtureUnit(n.fixture!),
  };
  return <String, double>{
    ...accumulateFixtureUnits(
        net: net,
        service: ServiceType.coldWater,
        rootId: 'cw-gtank',
        terminalUnits: cwUnits),
    ...accumulateFixtureUnits(
        net: net,
        service: ServiceType.drainage,
        rootId: 'dr-exit',
        terminalUnits: drUnits),
  };
}

// ── Mechanical duties: DERIVED from the one solve (mirrors solve_store) ──────
// R3 reports-7: the harness used to hand-type the pump / fan / fire-pump
// duties (a 20 L/s booster against a ~1.6 L/s network), so its artifacts
// contradicted each other and could not catch a real cross-artifact seam
// regression. Every duty now comes from the solve exactly as the app derives
// it (`pumpDutyProvider` / `ductFanProvider` / `standpipeDesignProvider`).
class MechDuties {
  final PumpDuty supplyPump;
  final FanDuty ahuFan;
  final FireStandpipeDesign standpipe;
  final PumpDuty firePump;
  final FirePumpRatingResult firePumpRating;
  const MechDuties({
    required this.supplyPump,
    required this.ahuFan,
    required this.standpipe,
    required this.firePump,
    required this.firePumpRating,
  });
}

const targetResidual = Pressure(100000); // 100 kPa

MechDuties deriveDuties(Network net, Map<String, EdgeSizing> sizing) {
  Map<String, FlowRate> flowsOf(ServiceType svc) => {
        for (final e in net.edges)
          if (e.service == svc && sizing[e.id] != null) e.id: sizing[e.id]!.flow,
      };
  FlowRate peak(Map<String, FlowRate> flows) => flows.values.fold(
      const FlowRate(0),
      (a, f) => f.cubicMetersPerSecond > a.cubicMetersPerSecond ? f : a);

  // Upfeed booster: peak supply flow at the solve's required pump head.
  final cwFlows = flowsOf(ServiceType.coldWater);
  final solution = solvePressurized(
    net: net,
    service: ServiceType.coldWater,
    sourceId: 'cw-gtank',
    edgeFlows: cwFlows,
    sizing: sizing,
    calibrationBySheet: calibrations,
    building: building,
    targetResidual: targetResidual,
  );
  final supplyPump =
      sizePump(flow: peak(cwFlows), head: solution.requiredPumpHead);

  // AHU supply fan: trunk airflow at the index-run total static.
  final saFlows = flowsOf(ServiceType.duct);
  final duct = solveDuctStatic(
    net: net,
    service: ServiceType.duct,
    fanNodeId: 'ahu1',
    edgeFlows: saFlows,
    sizing: sizing,
    calibrationBySheet: calibrations,
    building: building,
  );
  final ahuFan = sizeFan(
      airflow: peak(saFlows), totalStaticPressure: duct.totalStaticPressure);

  // Standpipe fire pump, as the app designs it from the building height.
  final standpipe =
      designStandpipe(risers: 1, buildingHeight: building.totalHeight);
  return MechDuties(
    supplyPump: supplyPump,
    ahuFan: ahuFan,
    standpipe: standpipe,
    firePump: sizePump(flow: standpipe.requiredFlow, head: standpipe.pumpHead),
    firePumpRating: checkFirePumpRating(
        ratedFlow: standpipe.requiredFlow, ratedHead: standpipe.pumpHead),
  );
}

/// The sample electrical project built on the duties DERIVED from the sample
/// network's own solve — the entry point tests share with the harness.
ElectricalProject buildSampleElectrical() {
  final net = buildNetwork();
  return buildElectrical(deriveDuties(net, sizeNetwork(net)));
}

// ── Electrical model: MDP -> LP-1 / PP-1 / EMG ───────────────────────────────
// The motor ways for the booster pump, the AHU fan and the fire pump are the
// SAME `buildEquipmentCircuits` projection of the solved duties the app's
// MEP->E feed (`electrical_feed.dart`) uses — never hand-typed kW.
ElectricalProject buildElectrical(MechDuties duties) {
  final mepWays = buildEquipmentCircuits(
    [
      MepEquipmentLoad.fromPumpDuty(duties.supplyPump,
          id: 'supply-pump', name: 'Booster pump'),
      MepEquipmentLoad.fromFanDuty(duties.ahuFan,
          id: 'supply-fan', name: 'AHU fan L.1'),
    ],
    panelVoltage: const Voltage(400),
    lengthM: 14,
  ).map((c) => c.copyWith(starterType: StarterType.dol, cableType: 'NYY'));
  final firePumpWay = equipmentToCircuit(
    MepEquipmentLoad(
      id: 'fire-pump',
      name: 'Fire pump',
      source: MepLoadSource.firePump,
      mechanicalPower: duties.standpipe.pumpShaftPower,
    ),
    panelVoltage: const Voltage(400),
    lengthM: 30,
  ).copyWith(starterType: StarterType.starDelta, cableType: 'FRC');

  const mdp = ElectricalPanel(
    id: 'MDP',
    name: 'MDP',
    tag: 'MDP',
    layoutPos: LayoutPos(sheetId: 's0', floorIndex: 0, x: 170, y: 540),
    headroom: HeadroomSpec(sparePercentage: 20, spareWays: 3),
    circuits: [
      ElectricalCircuit(
          id: 'mdp-f-lp1', name: 'Feeder to LP-1', loadKind: LoadKind.feeder,
          feedsPanelId: 'LP1', length: Length(18)),
      ElectricalCircuit(
          id: 'mdp-f-pp1', name: 'Feeder to PP-1', loadKind: LoadKind.feeder,
          feedsPanelId: 'PP1', length: Length(24)),
      ElectricalCircuit(
          id: 'mdp-f-emg', name: 'Feeder to EMG', loadKind: LoadKind.feeder,
          feedsPanelId: 'EMG', length: Length(28)),
      ElectricalCircuit(
          id: 'mdp-lift', name: 'Lift motor', loadKind: LoadKind.motor,
          motorKw: 11, starterType: StarterType.vfd, cableType: 'NYY',
          length: Length(35)),
      ElectricalCircuit(
          id: 'mdp-gen', name: 'General power', loadKind: LoadKind.general,
          loadW: 8000, length: Length(20)),
    ],
  );
  const lp1 = ElectricalPanel(
    id: 'LP1',
    name: 'LP-1',
    tag: 'LP-1',
    system: ElectricalSystem.singlePhase,
    voltage: Voltage(220),
    sourceType: PanelSource.feeder,
    fedByCircuitId: 'mdp-f-lp1',
    layoutPos: LayoutPos(sheetId: 's1', floorIndex: 1, x: 380, y: 540),
    circuits: [
      ElectricalCircuit(
          id: 'lp1-lt1', name: 'Lighting L.1', loadKind: LoadKind.lighting,
          isLighting: true, loadW: 1200, cableType: 'NYM', length: Length(22)),
      ElectricalCircuit(
          id: 'lp1-lt2', name: 'Lighting L.2', loadKind: LoadKind.lighting,
          isLighting: true, loadW: 1350, cableType: 'NYM', length: Length(26)),
      ElectricalCircuit(
          id: 'lp1-lt3', name: 'Corridor lighting', loadKind: LoadKind.lighting,
          isLighting: true, loadW: 900, cableType: 'NYM', length: Length(30)),
      ElectricalCircuit(
          id: 'lp1-sk1', name: 'Sockets L.1', loadKind: LoadKind.socket,
          loadW: 2000, points: 6, cableType: 'NYM', length: Length(24)),
      ElectricalCircuit(
          id: 'lp1-sk2', name: 'Sockets L.2', loadKind: LoadKind.socket,
          loadW: 2000, points: 6, cableType: 'NYM', length: Length(28)),
      ElectricalCircuit(
          id: 'lp1-wh', name: 'Water heater', loadKind: LoadKind.general,
          loadW: 3000, cableType: 'NYM', length: Length(18)),
      ElectricalCircuit(
          id: 'lp1-ext', name: 'Exterior lighting', loadKind: LoadKind.lighting,
          isLighting: true, loadW: 600, cableType: 'NYM', length: Length(40)),
    ],
  );
  final pp1 = ElectricalPanel(
    id: 'PP1',
    name: 'PP-1',
    tag: 'PP-1',
    sourceType: PanelSource.feeder,
    fedByCircuitId: 'mdp-f-pp1',
    layoutPos: const LayoutPos(sheetId: 's2', floorIndex: 2, x: 380, y: 540),
    circuits: [
      ...mepWays,
      const ElectricalCircuit(
          id: 'pp1-ac1', name: 'AC unit L.1', loadKind: LoadKind.general,
          loadW: 2600, length: Length(20)),
      const ElectricalCircuit(
          id: 'pp1-ac2', name: 'AC unit L.2', loadKind: LoadKind.general,
          loadW: 2600, length: Length(24)),
      const ElectricalCircuit(
          id: 'pp1-ac3', name: 'AC unit L.3', loadKind: LoadKind.general,
          loadW: 2600, length: Length(28)),
      const ElectricalCircuit(
          id: 'pp1-wh', name: 'Central water heater',
          loadKind: LoadKind.general, loadW: 4400, length: Length(16)),
    ],
  );
  final emg = ElectricalPanel(
    id: 'EMG',
    name: 'PP EMERGENCY',
    tag: 'EMG',
    essential: true,
    sourceType: PanelSource.feeder,
    fedByCircuitId: 'mdp-f-emg',
    layoutPos: const LayoutPos(sheetId: 's0', floorIndex: 0, x: 640, y: 540),
    circuits: [
      firePumpWay,
      const ElectricalCircuit(
          id: 'emg-el', name: 'Emergency lighting', loadKind: LoadKind.lighting,
          isLighting: true, lifeSafety: true, loadW: 1000, cableType: 'FRC',
          length: Length(35)),
    ],
  );
  return ElectricalProject(
    id: 'menara-contoh',
    name: projectName,
    earthingSystem: EarthingSystem.tnCs,
    transformerKva: const ApparentPower(630000),
    capacitorBankKvar: 50,
    sources: const ElectricalSources(
      generator: GeneratorSource(backupFraction: 0.6),
    ),
    panels: [mdp, lp1, pp1, emg],
  );
}

// ── Helpers ──────────────────────────────────────────────────────────────────
void writeBytes(String name, Uint8List bytes) {
  File('$outDir/$name').writeAsBytesSync(bytes);
  print('WROTE $name (${bytes.length} bytes)');
}

void writeText(String name, String text) {
  File('$outDir/$name').writeAsStringSync(text);
  print('WROTE $name (${text.length} chars)');
}

List<ServiceType> servicesOnFloor(Network net, String sheetId, int floor) {
  final onFloor = net.nodes
      .where((n) => n.sheetId == sheetId && n.floorIndex == floor)
      .map((n) => n.id)
      .toSet();
  final svc = <ServiceType>{};
  for (final e in net.edges) {
    if (e.kind == EdgeKind.run &&
        onFloor.contains(e.fromId) &&
        onFloor.contains(e.toId)) {
      svc.add(e.service);
    }
  }
  return svc.toList()..sort((a, b) => a.index.compareTo(b.index));
}

/// The issued title block of plan sheet [index] — ONE value for its PDF and
/// its DXF, so both size to the same plotted scale (R6).
DrawingChrome planSheetChrome(
        Network net, String sheetId, int floor, int index, String title) =>
    DrawingChrome(
      // N19: derived per sheet (mechanical plan band, rail position).
      drawingNumber:
          sheetDrawingNumber(series: DrawingSeries.mechanicalPlan, index: index),
      revisionNumber: 'Rev. 0',
      sheetIndex: index,
      sheetTotal: 3,
      clientName: 'PT Contoh Developer',
      drawingTitle: title,
      drawnBy: 'CAD',
      checkedBy: 'MEP',
      dateString: dateString,
      legendServices: servicesOnFloor(net, sheetId, floor),
    );

void main(List<String> args) {
  if (args.isNotEmpty) outDir = args.first;
  Directory(outDir).createSync(recursive: true);
  final net = buildNetwork();
  final sizing = sizeNetwork(net);
  // R3 reports-7: ONE solve feeds every duty (calc report, equipment schedule,
  // riser notes, electrical motor ways).
  final duties = deriveDuties(net, sizing);
  final pumpKwToken =
      '${duties.supplyPump.selectedMotor.inKiloWatts.toStringAsFixed(2)} kW';
  final tankM3 = (net.nodeById('cw-gtank')!.tankCapacityLitres! / 1000)
      .toStringAsFixed(1);
  // Artifact texts the final cross-check compares (filled as they're built).
  final checkTexts = <String, String>{};
  final edgeLengths = <String, Length>{
    for (final e in net.edges)
      e.id: edgeLength(e, net,
          calibrationBySheet: calibrations, building: building),
  };
  final elevLabels = elevationLabels(net);
  // N13: one stable element tag per edge (riser stack tag / run floor tag),
  // threaded into BOTH plan formats so they trace to the riser + BOM + report.
  final edgeTagsMap = elementTags(net);
  // G1: one stable equipment tag per plant/air-unit node (P-01 / TK-01 / AHU-01),
  // threaded into the plan PDF + DXF beside each equipment glyph.
  final nodeTagsMap = equipmentNodeTags(net);
  // G5: the laid drainage fall the sizer actually uses (ctx gradient, not a
  // hardcoded default) — shown as `1:100` on gravity runs.
  final gravitySlope = const SizingContext().drainageSlope;
  print('network: ${net.nodes.length} nodes, ${net.edges.length} edges; '
      'sized ${sizing.length} edges');

  final failures = <String>[];
  void attempt(String label, void Function() body) {
    try {
      body();
    } catch (e, st) {
      failures.add('$label: $e');
      print('FAILED $label: $e\n$st');
    }
  }

  // 0 — front matter: cover + Daftar Gambar (drawing list) + general-notes &
  // MASTER legend (N21 / N24), rendered through the shared SLD multi-page path.
  attempt('cover-sheets.pdf', () {
    final elec = buildElectrical(duties);
    final drawings = <DrawingListEntry>[
      DrawingListEntry(
          number:
              sheetDrawingNumber(series: DrawingSeries.mechanicalPlan, index: 1),
          title: 'GROUND FLOOR - PLUMBING & RISERS',
          revision: 'Rev. 0',
          date: dateString),
      DrawingListEntry(
          number:
              sheetDrawingNumber(series: DrawingSeries.mechanicalPlan, index: 2),
          title: 'LANTAI 1 - PLUMBING & HVAC',
          revision: 'Rev. 0',
          date: dateString),
      DrawingListEntry(
          number: sheetDrawingNumber(series: DrawingSeries.mechanicalRiser),
          title: 'DIAGRAM RISER MEKANIKAL / MECHANICAL RISER SLD',
          revision: 'Rev. 0',
          date: dateString),
      DrawingListEntry(
          number: sheetDrawingNumber(series: DrawingSeries.electricalDetail),
          title: 'DIAGRAM PANEL / ELECTRICAL SLD',
          revision: 'Rev. 0',
          date: dateString),
    ];
    final cables = <String>{
      for (final p in elec.panels)
        for (final c in p.circuits)
          if (c.cableType != null && c.cableType!.isNotEmpty) c.cableType!,
    };
    final frontMatter = buildSubmittalFrontMatter(
      projectName: projectName,
      drawings: drawings,
      clientName: 'PT Contoh Developer',
      coverDrawingNumber: 'MEP-000',
      revision: 'Rev. 0',
      date: dateString,
      preparedBy: 'CAD',
      services: {for (final e in net.edges) e.service},
      components: {
        for (final n in net.nodes)
          if (n.component != null) n.component!,
      },
      cableFamilies: cables,
    );
    writeBytes(
        'cover-sheets.pdf',
        sldSheetsToPdf(
          frontMatter,
          title: 'iSystem MEP submittal',
          diagramTitles: kFrontMatterDiagramTitles,
          chrome: const DrawingChrome(
            // N20: the front matter carries the same full title block as every
            // issued sheet — DWG NO + the DRAWN/CHECKED/APPROVED sign-off block
            // (APPROVED stays a blank ruled cell for hand sign-off).
            drawingNumber: 'MEP-000',
            revisionNumber: 'Rev. 0',
            clientName: 'PT Contoh Developer',
            drawnBy: 'CAD',
            checkedBy: 'MEP',
            dateString: dateString,
          ),
          projectName: projectName,
        ));
  });

  // 1 & 2 — annotated plan PDFs (A3, calibrated, issuable chrome).
  attempt('plan-ground.pdf', () {
    final bytes = planToPdf(
          net: net,
          sizing: sizing,
          edgeLengths: edgeLengths,
          // N5: centreline heights; N4: setting-out grid + riser ties.
          edgeElevationLabels: elevLabels,
          grid: referenceGrid,
          // N13: the stable element tag on each run/riser label.
          edgeTags: edgeTagsMap,
          // G1 equipment tags + G5 gravity fall.
          nodeTags: nodeTagsMap,
          gravitySlope: gravitySlope,
          sheetId: 's0',
          floorIndex: 0,
          projectName: projectName,
          sheetName: 'Ground Floor - Plumbing & Risers',
          dateString: dateString,
          metersPerPixel: 0.02,
          chrome: planSheetChrome(net, 's0', 0, 1, 'GROUND FLOOR - PLUMBING & RISERS'),
        );
    checkTexts['plan-ground'] = latin1.decode(bytes);
    writeBytes('plan-ground.pdf', bytes);
  });
  attempt('plan-lantai1.pdf', () {
    final bytes = planToPdf(
          net: net,
          sizing: sizing,
          edgeLengths: edgeLengths,
          // N5: centreline heights; N4: setting-out grid + riser ties.
          edgeElevationLabels: elevLabels,
          grid: referenceGrid,
          // N13: the stable element tag on each run/riser label.
          edgeTags: edgeTagsMap,
          // G1 equipment tags + G5 gravity fall.
          nodeTags: nodeTagsMap,
          gravitySlope: gravitySlope,
          sheetId: 's1',
          floorIndex: 1,
          projectName: projectName,
          sheetName: 'Lantai 1 - Plumbing & HVAC',
          dateString: dateString,
          metersPerPixel: 0.02,
          chrome: planSheetChrome(net, 's1', 1, 2, 'LANTAI 1 - PLUMBING & HVAC'),
        );
    checkTexts['plan-lantai1'] = latin1.decode(bytes);
    writeBytes('plan-lantai1.pdf', bytes);
  });

  // 3 — plan DXF for the ground floor, at the plan PDF's own plotted scale
  // (R6) so the shared annotation layout makes the PDF's exact label choices.
  attempt('plan-ground.dxf', () {
    final chrome = planSheetChrome(net, 's0', 0, 1,
        'GROUND FLOOR - PLUMBING & RISERS');
    writeText(
        'plan-ground.dxf',
        networkToDxf(
          net: net,
          sizing: sizing,
          sheetId: 's0',
          floorIndex: 0,
          metersPerPixel: 0.02,
          // The same §10 lengths as the plan PDF, so PDF == DXF labels.
          edgeLengths: edgeLengths,
          // N5: centreline heights; N4: setting-out grid + riser ties.
          edgeElevationLabels: elevLabels,
          grid: referenceGrid,
          // N13: the stable element tag on each run label + riser marker.
          edgeTags: edgeTagsMap,
          // G1 equipment tags + G5 gravity fall.
          nodeTags: nodeTagsMap,
          gravitySlope: gravitySlope,
          chrome: chrome,
          sheetPlot: planSheetPlot(
            net: net,
            sheetId: 's0',
            floorIndex: 0,
            projectName: projectName,
            sheetName: 'Ground Floor - Plumbing & Risers',
            dateString: dateString,
            metersPerPixel: 0.02,
            grid: referenceGrid,
            chrome: chrome,
          ),
        ));
  });

  // 4 — mechanical riser single-line (combined services) → PDF + DXF.
  attempt('riser-mech', () {
    // N19: the mechanical riser band M-201 (derived, not hand-typed).
    // N20: the riser sheet carries the same full title block as every issued
    // sheet — SHEET (1 of 1) + the DRAWN/CHECKED/APPROVED sign-off block.
    final riserChrome = DrawingChrome(
      drawingNumber:
          sheetDrawingNumber(series: DrawingSeries.mechanicalRiser, index: 1),
      revisionNumber: 'Rev. 0',
      sheetIndex: 1,
      sheetTotal: 1,
      clientName: 'PT Contoh Developer',
      drawnBy: 'CAD',
      checkedBy: 'MEP',
      dateString: dateString,
    );
    final riserSheet = buildMechanicalRiserSld(
      network: net,
      sizing: sizing,
      building: building,
      // N6: the §10 length-per-edge map — every run/riser tag carries metres.
      edgeLengths: edgeLengths,
      // drafting-7: the SAME stable equipment tags the plan + schedule print.
      nodeTags: nodeTagsMap,
      supplyNote: 'Air bersih: tangki bawah -> pompa booster -> riser upfeed',
      // Derived from the model + the solved duty, never hand-typed.
      equipmentDetailByNodeId: {
        'cw-gtank': '$tankM3 m3',
        'cw-pump': pumpKwToken,
      },
      notes: [
        'Sistem upfeed booster',
        'Tangki bawah $tankM3 m3',
        'Pompa booster $pumpKwToken',
      ],
      detailCallouts: true,
      // G2: the fixture carries a hot-water loop, so the riser draws the HWR
      // return leg + recirc pump (the app supplies this from the recirc solve).
      hotWaterRecirc: net.edges.any((e) => e.service == ServiceType.hotWater),
    );
    checkTexts['riser-mech'] =
        riserSheet.prims.whereType<SldLabel>().map((l) => l.text).join(' | ');
    writeBytes(
        'riser-mech.pdf',
        sldSheetToPdf(
          sheet: riserSheet,
          title: projectName,
          diagramTitle: 'DIAGRAM SISTEM AIR BERSIH & AIR KOTOR',
          chrome: riserChrome,
          // N2: the live project name in the title-block PROJECT row.
          projectName: projectName,
        ));
    writeText(
        'riser-mech.dxf',
        sldSheetToDxf(
          sheet: riserSheet,
          diagramTitle: 'DIAGRAM SISTEM AIR BERSIH & AIR KOTOR',
          chrome: riserChrome,
          projectName: projectName,
          // N15: a plumbing riser DXF uses the M-* layer namespace, never E-*.
          layers: SldDxfLayers.mechanical,
        ));
  });

  // ── Electrical ────────────────────────────────────────────────────────────
  final project = buildElectrical(duties);
  const puil = PuilProfile();
  // Geo-aware, exactly as the app's electricalResultProvider: placed feeders
  // size on their calibrated layout length, so the schedule / overview print
  // the SAME length the electrical layout plan does.
  final result = computeSystem(
    puil,
    project,
    calibrationBySheet: calibrations,
    building: building,
    originFaultLevel: const Current(16000),
    busbarClearingTimeS: 0.1,
  );
  // N19: each electrical DRAWING TYPE gets its own number band — the per-panel
  // detail E-201, the building overview E-301, the floor-by-floor riser E-401 —
  // so three different electrical drawings never all read 'E-201'.
  // N20: every electrical sheet carries the same full title block — the
  // DRAWN/CHECKED/APPROVED sign-off block (APPROVED a blank ruled cell); the
  // paginated detail export re-stamps its own per-page SHEET counter.
  // X3: every electrical drawing is a STANDALONE one-sheet issue in this set,
  // so it states so — `SHEET 1 of 1` — instead of leaving the row blank. (The
  // paginated per-panel detail supersedes this with its real per-page counter.)
  DrawingChrome elecChromeFor(DrawingSeries series) => DrawingChrome(
        drawingNumber: sheetDrawingNumber(series: series),
        revisionNumber: 'Rev. 0',
        sheetIndex: 1,
        sheetTotal: 1,
        clientName: 'PT Contoh Developer',
        drawnBy: 'CAD',
        checkedBy: 'MEP',
        dateString: dateString,
      );
  // E1 / E2: the ONE study that already knows each way's own device breaking
  // capacity and its conduit fill — fed to the board schedule so the sheet
  // prints per-DEVICE kA (not the board incomer's frame ladder) and the SAME
  // containment size the take-off issues (not a second, un-fill-checked CSA
  // ladder).
  final advanced = computeAdvancedStudy(puil, project, result,
      originFaultLevel: const Current(16000));
  final breakerKaByCircuitId = <String, double>{
    for (final e in advanced.fault.circuits.entries) e.key: e.value.breakerKa,
  };
  final breakerIcuKaByPanelId = <String, double>{
    for (final e in advanced.fault.panels.entries) e.key: e.value.incomerKa,
  };
  final containmentByCircuitId = <String, ConduitSpec>{
    for (final c in advanced.containment.values)
      for (final cc in c.conduits) cc.circuitId: cc.conduit,
  };
  final elecDetailChrome = elecChromeFor(DrawingSeries.electricalDetail);
  final elecOverviewChrome = elecChromeFor(DrawingSeries.electricalOverview);
  final elecRiserChrome = elecChromeFor(DrawingSeries.electricalRiser);

  // 5 — per-panel detail single-line (one page per panel), each board schedule
  // carrying its per-WAY device kA + the containment study's own conduit size.
  // (The sheets are built HERE — one per board, root-first, exactly as
  // `electricalSldToPdfPaginated` does — so the per-circuit maps can be fed;
  // `electricalSldSheetsToPdf` then stamps the same real `Sheet i of N`.)
  attempt('elec-detail.pdf', () {
    final panelSheets = [
      for (final id in result.order)
        buildElectricalPanelDetail(
          project: project,
          result: result,
          panelId: id,
          breakerIcuKaByPanelId: breakerIcuKaByPanelId,
          breakerKaByCircuitId: breakerKaByCircuitId,
          containmentByCircuitId: containmentByCircuitId,
        ),
    ];
    writeBytes(
        'elec-detail.pdf',
        electricalSldSheetsToPdf(
          sheets: panelSheets,
          title: projectName,
          diagramTitle: 'DIAGRAM PANEL',
          chrome: elecDetailChrome,
          projectName: projectName,
        ));
  });

  // 6 — zoomed-out building overview (source chain on).
  attempt('elec-overview.pdf', () {
    writeBytes(
        'elec-overview.pdf',
        electricalSldToPdf(
          project: project,
          result: result,
          title: projectName,
          diagramTitle: 'BUILDING SINGLE-LINE (OVERVIEW)',
          overview: true,
          sourceChain: true,
          chrome: elecOverviewChrome,
        ));
  });

  // 7 — floor-by-floor electrical riser.
  attempt('elec-riser.pdf', () {
    final riserSheet = buildElectricalRiser(
      project: project,
      result: result,
      building: building,
      sourceChain: true,
    );
    writeBytes(
        'elec-riser.pdf',
        electricalSldToPdf(
          project: project,
          result: result,
          sheet: riserSheet,
          title: projectName,
          diagramTitle: 'DIAGRAM RISER LISTRIK',
          chrome: elecRiserChrome,
        ));
  });

  // 8 — electrical single-line DXF (per-panel detail).
  attempt('elec-single-line.dxf', () {
    writeText(
        'elec-single-line.dxf',
        electricalSldToDxf(
          // The SAME enriched geometry the PDF draws (per-way kA + the
          // containment study's conduit) — PDF and DXF must never disagree.
          sheet: buildElectricalSld(
            project: project,
            result: result,
            breakerIcuKaByPanelId: breakerIcuKaByPanelId,
            breakerKaByCircuitId: breakerKaByCircuitId,
            containmentByCircuitId: containmentByCircuitId,
          ),
          diagramTitle: 'DIAGRAM PANEL',
          chrome: elecDetailChrome,
          projectName: projectName,
        ));
  });

  // 14 — plan-accurate electrical LAYOUT (denah instalasi listrik) for the
  // ground floor: panels + loads at their real placed sheet positions, feeders
  // with §10 cable lengths, and an honest "Unplaced" corner note for the panels
  // / loads not placed on this sheet+floor (H1). PDF + DXF share one geometry.
  attempt('elec-layout.pdf', () {
    final planData = buildElectricalPlanData(
      project: project,
      result: result,
      sheetId: 's0',
      floorIndex: 0,
      calibrations: calibrations,
      building: building,
    );
    writeBytes(
        'elec-layout.pdf',
        electricalPlanToPdf(
          data: planData,
          projectName: projectName,
          sheetName: 'Denah Lantai Dasar',
          dateString: dateString,
          chrome: elecChromeFor(DrawingSeries.electricalLayout),
          metersPerPixel: calibrations['s0']?.metersPerPixel,
        ));
    writeText(
        'elec-layout.dxf',
        electricalPlanToDxf(
          data: planData,
          projectName: projectName,
          sheetName: 'Denah Lantai Dasar',
          chrome: elecChromeFor(DrawingSeries.electricalLayout),
        ));
  });

  // ── Reports ───────────────────────────────────────────────────────────────
  const profile = SniProfile();
  final pumpDuty = duties.supplyPump;
  final ahuFan = duties.ahuFan;

  // 9 — mechanical calc report.
  attempt('calc-report.md', () {
    final bom = buildBom(
      net: net,
      sizing: sizing,
      calibrationBySheet: calibrations,
      building: building,
      groupByFloor: true,
    );
    final fittings = buildFittings(net: net, sizing: sizing);
    final data = CalcReportData(
      projectName: projectName,
      date: dateString,
      standardsName: profile.name,
      standardsRevision: profile.revision,
      verifyItems: profile.verifyChecklist,
      building: building,
      feedStrategy: 'Upfeed booster (ground tank -> booster pump)',
      targetResidual: targetResidual,
      pump: pumpDuty,
      // The standpipe the app always designs reaches the report (fire section).
      standpipe: duties.standpipe,
      firePumpRating: duties.firePumpRating,
      fan: ahuFan,
      supplyAirflowLps: ahuFan.airflow.inLitersPerSecond,
      rainfallMmPerHr: 200,
      runoffCoefficient: 0.9,
      occupancy: Occupancy.public,
      bom: bom,
      fittings: fittings,
      // N16: the per-run/riser sizing schedule (tag/size/FU/flow/vel/length).
      runSchedule: buildRunSchedule(
        net: net,
        sizing: sizing,
        edgeLengths: edgeLengths,
        edgeFixtureUnits: buildEdgeFixtureUnits(net),
      ),
      revisions: const [
        Revision('2026-07-06', 'Issued for construction (Rev. 0)'),
      ],
    );
    final md = buildCalcReportMarkdown(data);
    checkTexts['calc-report'] = md;
    writeText('calc-report.md', md);
  });

  // 10 — electrical calc report.
  attempt('elec-calc-report.md', () {
    final data = ElectricalCalcReportData(
      projectName: projectName,
      date: dateString,
      standardsName: puil.name,
      standardsRevision: puil.revision,
      project: project,
      result: result,
      originFaultLevelA: 16000,
      busbarClearingTimeS: 0.1,
      revisions: const [
        Revision('2026-07-06', 'Issued for construction (Rev. 0)'),
      ],
    );
    writeText('elec-calc-report.md', buildElectricalCalcReport(data));
  });

  // 11 — equipment schedule (MD) + BOM CSV.
  attempt('equipment-schedule.md', () {
    final data = EquipmentScheduleData(
      projectName: projectName,
      date: dateString,
      // Tags + services as the app's exportEquipmentSchedule assigns them.
      pumps: [
        PumpScheduleItem(
            duty: pumpDuty,
            service: 'Domestic water supply',
            // Keyed on the drawn unit's plan tag (as the app's tagOfFirst does).
            tag: nodeTagsMap['cw-pump']!),
        PumpScheduleItem(
            duty: duties.firePump,
            service: 'Fire standpipe pump',
            // Not drawn on any plan ⇒ the fixed fallback tag (app parity).
            tag: 'FP-01'),
      ],
      fans: [
        FanScheduleItem(
            duty: ahuFan,
            service: 'Office AHU',
            tag: nodeTagsMap['ahu1']!,
            airHandling: true),
      ],
      electrical: result,
      // N22: the transformer / standby genset / capacitor bank the model
      // already carries reach the procurement schedule.
      electricalProject: project,
    );
    final md = buildEquipmentScheduleMarkdown(data);
    checkTexts['equipment-schedule'] = md;
    writeText('equipment-schedule.md', md);
  });
  attempt('bom.csv', () {
    final bom = buildBom(
      net: net,
      sizing: sizing,
      calibrationBySheet: calibrations,
      building: building,
      groupByFloor: true,
    );
    writeText('bom.csv', bomToCsv(bom));
  });

  // ── Cross-artifact consistency (R3 reports-7) ─────────────────────────────
  // The acceptance harness FAILS when two issued artifacts disagree on the
  // same equipment or run — the seam regressions it used to be blind to.
  attempt('cross-check', () {
    final mismatches = crossCheckArtifacts(
      duties: duties,
      pumpKwToken: pumpKwToken,
      texts: checkTexts,
      project: project,
      result: result,
      drawnUnitTags: [nodeTagsMap['cw-pump']!, nodeTagsMap['ahu1']!],
    );
    if (mismatches.isNotEmpty) {
      throw StateError('cross-artifact mismatches:\n  - '
          '${mismatches.join('\n  - ')}');
    }
    print('cross-check: all artifacts agree');
  });

  print('\n=== DONE ===');
  if (failures.isEmpty) {
    print('all artifacts generated');
  } else {
    print('FAILURES (${failures.length}):');
    for (final f in failures) {
      print('  - $f');
    }
    exitCode = 1;
  }
}

/// Compare what the issued artifacts state about the SAME equipment / runs.
/// Returns one message per disagreement (empty ⇒ consistent).
List<String> crossCheckArtifacts({
  required MechDuties duties,
  required String pumpKwToken,
  required Map<String, String> texts,
  required ElectricalProject project,
  required ElectricalSystemResult result,
  List<String> drawnUnitTags = const [],
}) {
  final out = <String>[];
  String text(String key) {
    final t = texts[key];
    if (t == null) out.add('$key was not generated');
    return t ?? '';
  }

  // 1. Booster pump motor: calc report = equipment schedule = riser notes.
  for (final key in ['calc-report', 'equipment-schedule', 'riser-mech']) {
    if (!text(key).contains(pumpKwToken)) {
      out.add('$key does not state the solved booster motor $pumpKwToken');
    }
  }
  // …and the electrical way carries the same rated motor.
  final pumpWay = project.panels
      .expand((p) => p.circuits)
      .where((c) => c.sourceEquipmentId == 'supply-pump')
      .firstOrNull;
  final kw = duties.supplyPump.selectedMotor.inKiloWatts;
  if (pumpWay == null || ((pumpWay.motorKw ?? -1) - kw).abs() > 1e-9) {
    out.add('electrical booster way motorKw ${pumpWay?.motorKw} != $kw');
  }

  // 1b. drafting-7 tag parity: every scheduled tag of a DRAWN unit appears on
  //     a plan sheet AND on the riser, so the three cross-reference one unit.
  final planText = '${text('plan-ground')}\n${text('plan-lantai1')}';
  for (final tag in drawnUnitTags) {
    if (!text('equipment-schedule').contains(tag)) {
      out.add('equipment-schedule does not list the drawn unit $tag');
    }
    if (!planText.contains(tag)) {
      out.add('no plan sheet prints the scheduled tag $tag');
    }
    if (!text('riser-mech').contains(tag)) {
      out.add('riser-mech does not print the scheduled tag $tag');
    }
  }

  // 2. Fire pump presence: equipment schedule <=> calc-report fire section
  //    <=> an electrical fire-pump way.
  final schedFire = text('equipment-schedule').contains('FP-01');
  final reportFire = !text('calc-report').contains('none modelled');
  final elecFire = project.panels
      .expand((p) => p.circuits)
      .any((c) => c.sourceEquipmentId == 'fire-pump');
  if (!(schedFire == reportFire && reportFire == elecFire)) {
    out.add('fire pump presence disagrees: schedule=$schedFire '
        'calc-report=$reportFire electrical=$elecFire');
  }

  // 3. Feeder lengths: a feeder whose two boards are both placed must size on
  //    the geo route the electrical LAYOUT plan prints, so the board schedule /
  //    overview and the layout can never state two lengths for one cable.
  final byId = {for (final p in project.panels) p.id: p};
  for (final p in project.panels) {
    for (final c in p.circuits) {
      final fed = c.feedsPanelId == null ? null : byId[c.feedsPanelId];
      final a = p.layoutPos;
      final b = fed?.layoutPos;
      if (a == null || b == null) continue;
      final geo = electricalCableLength(a, b,
              calibrationBySheet: calibrations, building: building)
          .meters;
      final sized = result.panels[p.id]?.circuits
          .where((r) => r.circuitId == c.id)
          .firstOrNull
          ?.lengthM;
      if (geo <= 0 || sized == null || (sized - geo).abs() > 0.05) {
        out.add('${c.name}: schedule length $sized m vs layout ${_m(geo)} m');
      }
    }
  }
  return out;
}

String _m(double v) => v.toStringAsFixed(1);
