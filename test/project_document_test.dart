import 'package:flutter/widgets.dart' show Offset, Size;
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/data/project_document.dart';
import 'package:mechx/store/models/sheet.dart';
import 'package:mechx/ui/canvas/viewport.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
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
    // viewport round-trips
    expect(decoded.viewports['s1']?.scale, 0.5);
    expect(decoded.viewports['s1']?.offset, const Offset(12, 34));
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
}
