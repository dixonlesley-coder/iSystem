import 'package:flutter/widgets.dart' show Brightness, Offset, Size;
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/data/project_document.dart';
import 'package:mechx/store/models/sheet.dart';
import 'package:mechx/ui/canvas/viewport.dart';
import 'package:mechx_engine/electrical/earthing.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/fire_sprinkler.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/standards/puil.dart'
    show CableInstallMethod, ConductorInsulation, ConductorMaterial;
import 'package:mechx_engine/standards/sni.dart';
import 'package:mechx_engine/units.dart';

void main() {
  test('encodes and decodes a full project losslessly', () {
    const doc = ProjectDocument(
      projectName: 'Tower A',
      floors: [Floor('Ground', Length(4.0)), Floor('L1', Length(3.5))],
      calibrations: {'s1': ScaleCalibration(0.02)},
      sheets: [
        Sheet(id: 's1', name: 'Ground Floor', sizePx: Size(1684, 1190)),
        Sheet(
          id: 'p#0',
          name: 'plan p1',
          pdfPath: '/x/plan.pdf',
          sizePx: Size(800, 600),
        ),
      ],
      viewports: {
        's1': ViewportTransform(scale: 0.5, offset: Offset(12, 34)),
      },
      sheetFloors: {'p#0': 1},
      network: Network(
        nodes: [
          NetNode(
            id: 'n0',
            sheetId: 's1',
            x: 10,
            y: 20,
            floorIndex: 0,
            role: NodeRole.plant,
            elevation: Length(30),
          ),
          NetNode(
            id: 'n1',
            sheetId: 's1',
            x: 110,
            y: 20,
            floorIndex: 0,
            role: NodeRole.fixture,
            airflow: FlowRate(0.045), // 45 L/s
          ),
          NetNode(
            id: 'n2',
            sheetId: 's1',
            x: 110,
            y: 20,
            floorIndex: 1,
            role: NodeRole.fixture,
            fixture: PlumbingFixture.lavatory,
          ),
        ],
        edges: [
          NetEdge(id: 'e0', fromId: 'n0', toId: 'n1', service: ServiceType.coldWater),
          NetEdge(
            id: 'e1',
            fromId: 'n1',
            toId: 'n2',
            service: ServiceType.coldWater,
            kind: EdgeKind.riser,
          ),
        ],
      ),
    );

    final decoded = ProjectDocument.decode(doc.encode());

    expect(decoded.version, ProjectDocument.currentVersion);
    expect(decoded.projectName, 'Tower A');
    expect(decoded.floors.length, 2);
    expect(decoded.floors.first.height.meters, 4.0);
    expect(decoded.calibrations['s1']?.metersPerPixel, 0.02);
    expect(decoded.sheets.length, 2);
    expect(decoded.sheets[1].pdfPath, '/x/plan.pdf');
    expect(decoded.sheets[1].sizePx, const Size(800, 600));
    expect(decoded.sheets.first.pdfPath, isNull);
    expect(decoded.network.nodes.length, 3);
    expect(decoded.network.nodes[1].x, 110);
    // node role / explicit elevation / fixture type round-trip
    expect(decoded.network.nodes[0].role, NodeRole.plant);
    expect(decoded.network.nodes[0].elevation?.meters, 30);
    expect(decoded.network.nodes[2].role, NodeRole.fixture);
    expect(decoded.network.nodes[2].fixture, PlumbingFixture.lavatory);
    expect(decoded.network.nodes[1].role, NodeRole.fixture);
    expect(decoded.network.nodes[1].airflow?.inLitersPerSecond, closeTo(45, 1e-9));
    expect(decoded.network.nodes[1].fixture, isNull);
    expect(decoded.network.edges.length, 2);
    expect(decoded.network.edges[0].service, ServiceType.coldWater);
    expect(decoded.network.edges[1].kind, EdgeKind.riser);
    // viewport + sheet→floor mapping round-trip
    expect(decoded.viewports['s1']?.scale, 0.5);
    expect(decoded.viewports['s1']?.offset, const Offset(12, 34));
    expect(decoded.sheetFloors['p#0'], 1);
  });

  test('design settings round-trip (occupancy, feed, ducts, rainfall, fire, theme)',
      () {
    const doc = ProjectDocument(
      projectName: 'X',
      floors: [Floor('G', Length(3))],
      calibrations: {},
      sheets: [],
      network: Network(),
      settings: DesignSettings(
        occupancy: Occupancy.assembly,
        upfeed: true,
        ductShape: DuctShape.rectangular,
        ductMethod: DuctSizingMethod.equalFriction,
        rainfallMmPerHr: 275,
        fireHazard: FireHazardClass.ordinaryHazard2,
        brightness: Brightness.light,
      ),
    );
    final decoded = ProjectDocument.decode(doc.encode());
    final s = decoded.settings;
    expect(s.occupancy, Occupancy.assembly);
    expect(s.upfeed, isTrue);
    expect(s.ductShape, DuctShape.rectangular);
    expect(s.ductMethod, DuctSizingMethod.equalFriction);
    expect(s.rainfallMmPerHr, 275);
    expect(s.fireHazard, FireHazardClass.ordinaryHazard2);
    expect(s.brightness, Brightness.light);
  });

  test('a file with no settings block loads provider defaults', () {
    const doc = ProjectDocument(
      projectName: 'X',
      floors: [Floor('G', Length(3))],
      calibrations: {},
      sheets: [],
      network: Network(),
    );
    final json = doc.toJson()..remove('settings');
    final s = ProjectDocument.fromJson(json).settings;
    expect(s.occupancy, Occupancy.private);
    expect(s.upfeed, isFalse);
    expect(s.ductShape, DuctShape.round);
    expect(s.ductMethod, DuctSizingMethod.velocity);
    expect(s.rainfallMmPerHr, 200);
    expect(s.fireHazard, FireHazardClass.ordinaryHazard1);
    expect(s.brightness, Brightness.dark);
  });

  test('tolerates a missing version (defaults to current)', () {
    const doc = ProjectDocument(
      projectName: 'X',
      floors: [Floor('G', Length(3))],
      calibrations: {},
      sheets: [],
      network: Network(),
    );
    final json = doc.toJson()..remove('version');
    expect(ProjectDocument.fromJson(json).version, ProjectDocument.currentVersion);
  });

  test('unknown enum values fall back instead of throwing (forward compat)', () {
    const doc = ProjectDocument(
      projectName: 'X',
      floors: [Floor('G', Length(3))],
      calibrations: {},
      sheets: [Sheet(id: 's1', name: 'P', sizePx: Size(100, 100))],
      network: Network(
        nodes: [
          NetNode(id: 'a', sheetId: 's1', x: 0, y: 0, floorIndex: 0),
          NetNode(id: 'b', sheetId: 's1', x: 9, y: 0, floorIndex: 0),
        ],
        edges: [
          NetEdge(id: 'e', fromId: 'a', toId: 'b', service: ServiceType.duct),
        ],
      ),
    );
    final json = doc.toJson();
    // Simulate a newer build's unknown enum names.
    (json['network']['edges'][0] as Map)['service'] = 'plasmaConduit';
    (json['network']['nodes'][0] as Map)['role'] = 'antigravity';
    final decoded = ProjectDocument.fromJson(json);
    expect(decoded.network.edges[0].service, ServiceType.coldWater); // fallback
    expect(decoded.network.nodes[0].role, NodeRole.main); // fallback
  });

  test('a newer file version is rejected with a clear message', () {
    const doc = ProjectDocument(
      projectName: 'X',
      floors: [Floor('G', Length(3))],
      calibrations: {},
      sheets: [],
      network: Network(),
    );
    final json = doc.toJson()..['version'] = ProjectDocument.currentVersion + 1;
    expect(
      () => ProjectDocument.fromJson(json),
      throwsA(isA<ProjectDocumentException>()),
    );
  });

  test('malformed JSON / wrong shape throws ProjectDocumentException', () {
    expect(() => ProjectDocument.decode('}{ not json'),
        throwsA(isA<ProjectDocumentException>()));
    expect(() => ProjectDocument.decode('[1,2,3]'),
        throwsA(isA<ProjectDocumentException>()));
    expect(() => ProjectDocument.decode('{"hello":"world"}'),
        throwsA(isA<ProjectDocumentException>()));
  });

  test('v2 electrical sub-model round-trips through encode/decode', () {
    const doc = ProjectDocument(
      projectName: 'Tower E',
      floors: [Floor('G', Length(3))],
      calibrations: {},
      sheets: [],
      network: Network(),
      electrical: ElectricalProject(
        id: 'ep1',
        name: 'Building electrical',
        earthingSystem: EarthingSystem.tt,
        panels: [
          ElectricalPanel(
            id: 'mdp',
            name: 'Main Distribution',
            tag: 'MDP',
            system: ElectricalSystem.threePhase,
            voltage: Voltage(400),
            ambientTempC: 35,
            installMethod: CableInstallMethod.tray,
            insulation: ConductorInsulation.xlpe,
            material: ConductorMaterial.copper,
            groupingCount: 3,
            diversityFactor: 0.8,
            occupancy: 'office',
            sourceType: PanelSource.utility,
            circuits: [
              ElectricalCircuit(
                id: 'c1',
                name: 'Lighting',
                role: CircuitRole.branch,
                loadW: 3600,
                cosPhi: 0.9,
                length: Length(25),
                loadKind: LoadKind.lighting,
                isLighting: true,
                phases: 1,
                phaseOverride: PhaseLine.l2,
                breakerOverrideA: Current(16),
              ),
              ElectricalCircuit(
                id: 'c2',
                name: 'Feeder to SP-1',
                role: CircuitRole.branch,
                loadKind: LoadKind.feeder,
                length: Length(40),
                feedsPanelId: 'sp1',
                sourceEquipmentId: 'pump-101',
                flaOverrideA: Current(22.5),
                busbarBreakBefore: true,
              ),
            ],
          ),
          ElectricalPanel(
            id: 'sp1',
            name: 'Sub Panel 1',
            tag: 'SP-1',
            system: ElectricalSystem.singlePhase,
            voltage: Voltage(220),
            sourceType: PanelSource.feeder,
            fedByCircuitId: 'c2',
          ),
        ],
      ),
    );

    final decoded = ProjectDocument.decode(doc.encode());
    expect(decoded.version, ProjectDocument.currentVersion);
    expect(decoded.version, 2);

    final e = decoded.electrical;
    expect(e, isNotNull);
    expect(e!.id, 'ep1');
    expect(e.name, 'Building electrical');
    expect(e.earthingSystem, EarthingSystem.tt);
    expect(e.panels.length, 2);

    final mdp = e.panels[0];
    expect(mdp.id, 'mdp');
    expect(mdp.tag, 'MDP');
    expect(mdp.system, ElectricalSystem.threePhase);
    expect(mdp.voltage.volts, 400);
    expect(mdp.ambientTempC, 35);
    expect(mdp.installMethod, CableInstallMethod.tray);
    expect(mdp.insulation, ConductorInsulation.xlpe);
    expect(mdp.material, ConductorMaterial.copper);
    expect(mdp.groupingCount, 3);
    expect(mdp.diversityFactor, 0.8);
    expect(mdp.occupancy, 'office');
    expect(mdp.sourceType, PanelSource.utility);
    expect(mdp.circuits.length, 2);

    final c1 = mdp.circuits[0];
    expect(c1.id, 'c1');
    expect(c1.loadW, 3600);
    expect(c1.cosPhi, 0.9);
    expect(c1.length.meters, 25);
    expect(c1.loadKind, LoadKind.lighting);
    expect(c1.isLighting, isTrue);
    expect(c1.phases, 1);
    expect(c1.phaseOverride, PhaseLine.l2);
    expect(c1.breakerOverrideA?.amperes, 16);

    final c2 = mdp.circuits[1];
    expect(c2.loadKind, LoadKind.feeder);
    expect(c2.isFeeder, isTrue);
    expect(c2.length.meters, 40);
    expect(c2.feedsPanelId, 'sp1');
    expect(c2.sourceEquipmentId, 'pump-101');
    expect(c2.flaOverrideA?.amperes, 22.5);
    expect(c2.busbarBreakBefore, isTrue);
    // Optional fields not set stay null.
    expect(c2.motorKw, isNull);
    expect(c2.phaseOverride, isNull);

    final sp1 = e.panels[1];
    expect(sp1.system, ElectricalSystem.singlePhase);
    expect(sp1.voltage.volts, 220);
    expect(sp1.sourceType, PanelSource.feeder);
    expect(sp1.fedByCircuitId, 'c2');
    expect(sp1.circuits, isEmpty);
  });

  test('a v1 file (no electrical key) loads with electrical == null', () {
    final v1Json = <String, dynamic>{
      'version': 1,
      'project': {
        'name': 'Legacy',
        'floors': [
          {'name': 'G', 'height_m': 3.0},
        ],
        'calibrations': <String, dynamic>{},
      },
      'sheets': <dynamic>[],
      'network': {'nodes': <dynamic>[], 'edges': <dynamic>[]},
    };
    final decoded = ProjectDocument.fromJson(v1Json);
    expect(decoded.version, 1);
    expect(decoded.projectName, 'Legacy');
    expect(decoded.electrical, isNull);
  });

  test('a v3 (newer) file is rejected with ProjectDocumentException', () {
    const doc = ProjectDocument(
      projectName: 'X',
      floors: [Floor('G', Length(3))],
      calibrations: {},
      sheets: [],
      network: Network(),
    );
    final json = doc.toJson()..['version'] = 3;
    expect(
      () => ProjectDocument.fromJson(json),
      throwsA(isA<ProjectDocumentException>()),
    );
  });
}
