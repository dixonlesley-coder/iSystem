import 'package:flutter/widgets.dart' show Size;
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/data/project_document.dart';
import 'package:mechx/store/models/sheet.dart';
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
          NetNode(id: 'n1', sheetId: 's1', x: 110, y: 20, floorIndex: 0),
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
    expect(decoded.network.nodes[1].role, NodeRole.main);
    expect(decoded.network.nodes[1].fixture, isNull);
    expect(decoded.network.edges.length, 2);
    expect(decoded.network.edges[0].service, ServiceType.coldWater);
    expect(decoded.network.edges[1].kind, EdgeKind.riser);
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
}
