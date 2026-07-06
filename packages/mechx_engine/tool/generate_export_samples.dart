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
import 'dart:io';
import 'dart:typed_data';

import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/control/starter.dart' show StarterType;
import 'package:mechx_engine/electrical/earthing.dart' show EarthingSystem;
import 'package:mechx_engine/electrical/geo_length.dart' show LayoutPos;
import 'package:mechx_engine/electrical/headroom.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/sources.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/calc_report.dart';
import 'package:mechx_engine/report/drawing_chrome.dart';
import 'package:mechx_engine/report/dxf_export.dart';
import 'package:mechx_engine/report/electrical_calc_report.dart';
import 'package:mechx_engine/report/electrical_dxf_export.dart';
import 'package:mechx_engine/report/electrical_pdf_export.dart';
import 'package:mechx_engine/report/electrical_sld_drawing.dart';
import 'package:mechx_engine/report/equipment_schedule.dart';
import 'package:mechx_engine/report/mechanical_sld_drawing.dart';
import 'package:mechx_engine/report/plan_pdf_export.dart';
import 'package:mechx_engine/report/sld_export.dart';
import 'package:mechx_engine/sizing/bom.dart';
import 'package:mechx_engine/sizing/drainage_sizing.dart';
import 'package:mechx_engine/sizing/fan.dart';
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
      tankCapacityLitres: 5000));
  node(const NetNode(
      id: 'cw-pump', sheetId: 's0', x: 170, y: 540, floorIndex: 0,
      role: NodeRole.plant, component: NodeComponent.pump,
      electricalLoadW: 2200));
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
      role: NodeRole.plant, component: NodeComponent.ahu));
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

// ── Electrical model: MDP -> LP-1 / PP-1 / EMG ───────────────────────────────
ElectricalProject buildElectrical() {
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
  const pp1 = ElectricalPanel(
    id: 'PP1',
    name: 'PP-1',
    tag: 'PP-1',
    sourceType: PanelSource.feeder,
    fedByCircuitId: 'mdp-f-pp1',
    layoutPos: LayoutPos(sheetId: 's2', floorIndex: 2, x: 380, y: 540),
    circuits: [
      ElectricalCircuit(
          id: 'pp1-dp', name: 'Domestic pump', loadKind: LoadKind.motor,
          motorKw: 3.0, starterType: StarterType.dol, cableType: 'NYY',
          length: Length(12)),
      ElectricalCircuit(
          id: 'pp1-bp', name: 'Booster pump', loadKind: LoadKind.motor,
          motorKw: 2.2, starterType: StarterType.dol, cableType: 'NYY',
          length: Length(14)),
      ElectricalCircuit(
          id: 'pp1-ac1', name: 'AC unit L.1', loadKind: LoadKind.general,
          loadW: 2600, length: Length(20)),
      ElectricalCircuit(
          id: 'pp1-ac2', name: 'AC unit L.2', loadKind: LoadKind.general,
          loadW: 2600, length: Length(24)),
      ElectricalCircuit(
          id: 'pp1-ac3', name: 'AC unit L.3', loadKind: LoadKind.general,
          loadW: 2600, length: Length(28)),
      ElectricalCircuit(
          id: 'pp1-wh', name: 'Central water heater',
          loadKind: LoadKind.general, loadW: 4400, length: Length(16)),
    ],
  );
  const emg = ElectricalPanel(
    id: 'EMG',
    name: 'PP EMERGENCY',
    tag: 'EMG',
    essential: true,
    sourceType: PanelSource.feeder,
    fedByCircuitId: 'mdp-f-emg',
    layoutPos: LayoutPos(sheetId: 's0', floorIndex: 0, x: 640, y: 540),
    circuits: [
      ElectricalCircuit(
          id: 'emg-fp', name: 'Fire pump', loadKind: LoadKind.motor,
          motorKw: 5.5, starterType: StarterType.starDelta, lifeSafety: true,
          cableType: 'FRC', length: Length(30)),
      ElectricalCircuit(
          id: 'emg-el', name: 'Emergency lighting', loadKind: LoadKind.lighting,
          isLighting: true, lifeSafety: true, loadW: 1000, cableType: 'FRC',
          length: Length(35)),
    ],
  );
  return const ElectricalProject(
    id: 'menara-contoh',
    name: projectName,
    earthingSystem: EarthingSystem.tnCs,
    transformerKva: ApparentPower(630000),
    capacitorBankKvar: 50,
    sources: ElectricalSources(
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

void main(List<String> args) {
  if (args.isNotEmpty) outDir = args.first;
  Directory(outDir).createSync(recursive: true);
  final net = buildNetwork();
  final sizing = sizeNetwork(net);
  final edgeLengths = <String, Length>{
    for (final e in net.edges)
      e.id: edgeLength(e, net,
          calibrationBySheet: calibrations, building: building),
  };
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

  // 1 & 2 — annotated plan PDFs (A3, calibrated, issuable chrome).
  attempt('plan-ground.pdf', () {
    writeBytes(
        'plan-ground.pdf',
        planToPdf(
          net: net,
          sizing: sizing,
          edgeLengths: edgeLengths,
          sheetId: 's0',
          floorIndex: 0,
          projectName: projectName,
          sheetName: 'Ground Floor - Plumbing & Risers',
          dateString: dateString,
          metersPerPixel: 0.02,
          chrome: DrawingChrome(
            drawingNumber: 'M-101',
            revisionNumber: 'Rev. 0',
            sheetIndex: 1,
            sheetTotal: 3,
            clientName: 'PT Contoh Developer',
            drawingTitle: 'GROUND FLOOR - PLUMBING & RISERS',
            drawnBy: 'CAD',
            checkedBy: 'MEP',
            dateString: dateString,
            legendServices: servicesOnFloor(net, 's0', 0),
          ),
        ));
  });
  attempt('plan-lantai1.pdf', () {
    writeBytes(
        'plan-lantai1.pdf',
        planToPdf(
          net: net,
          sizing: sizing,
          edgeLengths: edgeLengths,
          sheetId: 's1',
          floorIndex: 1,
          projectName: projectName,
          sheetName: 'Lantai 1 - Plumbing & HVAC',
          dateString: dateString,
          metersPerPixel: 0.02,
          chrome: DrawingChrome(
            drawingNumber: 'M-102',
            revisionNumber: 'Rev. 0',
            sheetIndex: 2,
            sheetTotal: 3,
            clientName: 'PT Contoh Developer',
            drawingTitle: 'LANTAI 1 - PLUMBING & HVAC',
            drawnBy: 'CAD',
            checkedBy: 'MEP',
            dateString: dateString,
            legendServices: servicesOnFloor(net, 's1', 1),
          ),
        ));
  });

  // 3 — plan DXF for the ground floor.
  attempt('plan-ground.dxf', () {
    writeText(
        'plan-ground.dxf',
        networkToDxf(
          net: net,
          sizing: sizing,
          sheetId: 's0',
          floorIndex: 0,
          metersPerPixel: 0.02,
          chrome: DrawingChrome(
            drawingNumber: 'M-101',
            revisionNumber: 'Rev. 0',
            sheetIndex: 1,
            sheetTotal: 3,
            clientName: 'PT Contoh Developer',
            drawingTitle: 'GROUND FLOOR - PLUMBING & RISERS',
            dateString: dateString,
            legendServices: servicesOnFloor(net, 's0', 0),
          ),
        ));
  });

  // 4 — mechanical riser single-line (combined services) → PDF + DXF.
  attempt('riser-mech', () {
    final riserChrome = const DrawingChrome(
      drawingNumber: 'M-201',
      revisionNumber: 'Rev. 0',
      clientName: 'PT Contoh Developer',
      dateString: dateString,
    );
    final riserSheet = buildMechanicalRiserSld(
      network: net,
      sizing: sizing,
      building: building,
      supplyNote: 'Air bersih: tangki bawah -> pompa booster -> riser upfeed',
      equipmentDetailByNodeId: const {
        'cw-gtank': '5.0 m3',
        'cw-pump': '2.2 kW',
      },
      notes: const [
        'Sistem upfeed booster',
        'Tangki bawah 5.0 m3',
        'Pompa booster 2.2 kW',
      ],
      detailCallouts: true,
    );
    writeBytes(
        'riser-mech.pdf',
        sldSheetToPdf(
          sheet: riserSheet,
          title: projectName,
          diagramTitle: 'DIAGRAM SISTEM AIR BERSIH & AIR KOTOR',
          chrome: riserChrome,
        ));
    writeText(
        'riser-mech.dxf',
        sldSheetToDxf(
          sheet: riserSheet,
          diagramTitle: 'DIAGRAM SISTEM AIR BERSIH & AIR KOTOR',
          chrome: riserChrome,
        ));
  });

  // ── Electrical ────────────────────────────────────────────────────────────
  final project = buildElectrical();
  const puil = PuilProfile();
  final result = computeSystem(
    puil,
    project,
    originFaultLevel: const Current(16000),
    busbarClearingTimeS: 0.1,
  );
  final elecChrome = const DrawingChrome(
    drawingNumber: 'E-201',
    revisionNumber: 'Rev. 0',
    clientName: 'PT Contoh Developer',
    dateString: dateString,
  );

  // 5 — per-panel detail single-line (one page per panel).
  attempt('elec-detail.pdf', () {
    writeBytes(
        'elec-detail.pdf',
        electricalSldToPdfPaginated(
          project: project,
          result: result,
          title: projectName,
          diagramTitle: 'DIAGRAM PANEL',
          chrome: elecChrome,
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
          chrome: elecChrome,
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
          chrome: elecChrome,
        ));
  });

  // 8 — electrical single-line DXF (per-panel detail).
  attempt('elec-single-line.dxf', () {
    writeText(
        'elec-single-line.dxf',
        electricalSldToDxf(
          project: project,
          result: result,
          diagramTitle: 'DIAGRAM PANEL',
          chrome: elecChrome,
        ));
  });

  // ── Reports ───────────────────────────────────────────────────────────────
  const profile = SniProfile();
  final pumpDuty = sizePump(flow: const FlowRate(0.020), head: const Head(45));
  final firePumpDuty =
      sizePump(flow: const FlowRate(0.030), head: const Head(70));
  final exhaustFan = sizeFan(
      airflow: const FlowRate(0.36), totalStaticPressure: const Pressure(250));
  final ahuFan = sizeFan(
      airflow: const FlowRate(0.50), totalStaticPressure: const Pressure(400));

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
      targetResidual: const Pressure(100000), // 100 kPa
      pump: pumpDuty,
      fan: ahuFan,
      supplyAirflowLps: 360,
      returnAirflowLps: 320,
      rainfallMmPerHr: 200,
      runoffCoefficient: 0.9,
      occupancy: Occupancy.public,
      bom: bom,
      fittings: fittings,
      revisions: const [
        Revision('2026-07-06', 'Issued for construction (Rev. 0)'),
      ],
    );
    writeText('calc-report.md', buildCalcReportMarkdown(data));
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
      pumps: [
        PumpScheduleItem(duty: pumpDuty, service: 'Domestic water supply'),
        PumpScheduleItem(duty: firePumpDuty, service: 'Fire pump'),
      ],
      fans: [
        FanScheduleItem(duty: exhaustFan, service: 'Toilet exhaust'),
        FanScheduleItem(
            duty: ahuFan, service: 'Office AHU', airHandling: true),
      ],
      electrical: result,
    );
    writeText('equipment-schedule.md', buildEquipmentScheduleMarkdown(data));
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

  print('\n=== DONE ===');
  if (failures.isEmpty) {
    print('all artifacts generated');
  } else {
    print('FAILURES (${failures.length}):');
    for (final f in failures) {
      print('  - $f');
    }
  }
}
