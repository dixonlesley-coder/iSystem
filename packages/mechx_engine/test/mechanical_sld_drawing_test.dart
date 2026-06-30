import 'dart:convert';

import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/mechanical_sld_drawing.dart';
import 'package:mechx_engine/report/sld_export.dart';
import 'package:mechx_engine/report/sld_sheet.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/standards/sni.dart' show PlumbingFixture;
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

NetNode _n(
  String id,
  double x,
  int floor, {
  NodeRole role = NodeRole.main,
  NodeComponent? component,
  PlumbingFixture? fixture,
  double? tankLitres,
}) =>
    NetNode(
      id: id,
      sheetId: 's1',
      x: x,
      y: 0,
      floorIndex: floor,
      role: role,
      component: component,
      fixture: fixture,
      tankCapacityLitres: tankLitres,
    );

NetEdge _e(String id, String from, String to, ServiceType service,
        {EdgeKind kind = EdgeKind.run}) =>
    NetEdge(id: id, fromId: from, toId: to, service: service, kind: kind);

EdgeSizing _sz(String edgeId, ServiceType service, double mm) => EdgeSizing(
      edgeId: edgeId,
      service: service,
      flow: const FlowRate(1),
      diameter: Diameter.mm(mm),
      velocity: const Velocity(1.5),
    );

/// A small downfeed cold-water riser: a roof tank on the top floor feeds a riser
/// down to a ground-floor main that branches to two fixtures.
Network _riserNet() => Network(
      nodes: [
        _n('rt', 200, 2,
            role: NodeRole.plant,
            component: NodeComponent.roofTank,
            tankLitres: 5000),
        _n('m', 200, 0),
        _n('wc', 120, 0,
            role: NodeRole.fixture,
            fixture: PlumbingFixture.waterClosetFlushValve),
        _n('lav', 280, 0,
            role: NodeRole.fixture, fixture: PlumbingFixture.lavatory),
      ],
      edges: [
        _e('riser', 'rt', 'm', ServiceType.coldWater, kind: EdgeKind.riser),
        _e('b1', 'm', 'wc', ServiceType.coldWater),
        _e('b2', 'm', 'lav', ServiceType.coldWater),
      ],
    );

const _levels = BuildingLevels([
  Floor('Ground', Length(4)),
  Floor('Level 1', Length(4)),
  Floor('Roof', Length(3.5)),
]);

String _labels(SldSheet s) =>
    s.prims.whereType<SldLabel>().map((l) => l.text).join('\n');

void main() {
  group('buildMechanicalRiserSld', () {
    test('emits a non-empty sheet with bounds and the fitting legend', () {
      final s = buildMechanicalRiserSld(
        network: _riserNet(),
        building: _levels,
        downfeed: true,
      );
      expect(s.isEmpty, isFalse);
      expect(s.maxX, greaterThan(s.minX));
      expect(s.maxY, greaterThan(s.minY));
      // KETERANGAN device legend carries the reference fitting glossary.
      final codes = s.legend.map((e) => e.code).toSet();
      expect(codes, containsAll(<String>{'GV', 'CV', 'STR', 'PRV', 'WM'}));
      // The cold-water service present is keyed too.
      expect(codes, contains('CW'));
    });

    test('a sized cold-water riser carries the SIZE-CW-PPR tag + a riser id', () {
      final s = buildMechanicalRiserSld(
        network: _riserNet(),
        sizing: {'riser': _sz('riser', ServiceType.coldWater, 50)},
        building: _levels,
        downfeed: true,
      );
      final text = _labels(s);
      // 50 mm cold-water PPR riser; downfeed from the roof tank => GRAVITASI.
      expect(text, contains('50-CW-PPR'));
      expect(text, contains('GRAVITASI'));
      // Per-service riser tag.
      expect(text, contains('CW-R1'));
    });

    test('FFL gutter + fixture fan-out + tank label render', () {
      final s = buildMechanicalRiserSld(
        network: _riserNet(),
        building: _levels,
        downfeed: true,
      );
      final text = _labels(s);
      expect(text, contains('FFL +0.00')); // ground-floor elevation
      expect(text, contains('Roof')); // a building floor name in the gutter
      // The ground floor distributes a WC + a lavatory — fan-out stubs.
      expect(text, contains('BRANCHES'));
      expect(text, contains('WC'));
      expect(text, contains('Lavatory'));
    });

    test('an empty network yields an empty (legend-only) sheet, never throws',
        () {
      final s = buildMechanicalRiserSld(
        network: const Network(nodes: [], edges: []),
      );
      expect(s.isEmpty, isTrue);
      expect(s.prims, isEmpty);
    });

    test('the riser sheet exports to a PDF carrying the legend + mech title',
        () {
      final sheet = buildMechanicalRiserSld(
        network: _riserNet(),
        sizing: {'riser': _sz('riser', ServiceType.coldWater, 50)},
        building: _levels,
        downfeed: true,
        supplyNote: 'Feed: gravity downfeed - roof tank',
      );
      final pdf = latin1.decode(
          sldSheetToPdf(sheet: sheet, diagramTitle: 'DIAGRAM SISTEM AIR BERSIH'));
      expect(pdf.startsWith('%PDF-1.4'), isTrue);
      // The mechanical diagram title + the KETERANGAN legend ride the export.
      expect(pdf, contains('DIAGRAM SISTEM AIR BERSIH'));
      expect(pdf, contains('LEGEND'));
      expect(pdf, contains('Gate valve')); // a fitting-legend meaning
    });

    test('the riser sheet exports to a DXF carrying the legend + mech title',
        () {
      final sheet = buildMechanicalRiserSld(
        network: _riserNet(),
        building: _levels,
        downfeed: true,
      );
      final dxf =
          sldSheetToDxf(sheet: sheet, diagramTitle: 'DIAGRAM SISTEM AIR BERSIH');
      expect(dxf, contains('SECTION'));
      expect(dxf.trimRight(), endsWith('EOF'));
      expect(dxf, contains('DIAGRAM SISTEM AIR BERSIH'));
      expect(dxf, contains('LEGEND'));
    });

    test('focus filter keeps only that service (drainage absent => fewer prims)',
        () {
      final net = Network(
        nodes: [
          ..._riserNet().nodes,
          _n('d', 300, 0, role: NodeRole.fixture),
        ],
        edges: [
          ..._riserNet().edges,
          _e('dr', 'm', 'd', ServiceType.drainage),
        ],
      );
      final all = buildMechanicalRiserSld(network: net, building: _levels);
      final cwOnly = buildMechanicalRiserSld(
          network: net, building: _levels, focus: ServiceType.coldWater);
      // The combined view draws the drainage edge too; focusing CW drops it.
      expect(cwOnly.prims.length, lessThan(all.prims.length));
      expect(cwOnly.legend.map((e) => e.code), isNot(contains('D')));
    });
  });
}
