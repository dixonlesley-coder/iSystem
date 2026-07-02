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

/// A dense two-riser cold-water network: two roof-tank riser stacks plus two
/// COINCIDENT fixtures on a floor (same world x) and two close branch runs whose
/// centred sized tags overlap — exercises the spread + ladder + leader paths.
Network _denseTwoRiserNet() => Network(
      nodes: [
        // Riser A stack at x=200.
        _n('rtA', 200, 2,
            role: NodeRole.plant,
            component: NodeComponent.roofTank,
            tankLitres: 5000),
        _n('mA1', 200, 1),
        _n('mA0', 200, 0),
        // Riser B stack at x=400.
        _n('rtB', 400, 2,
            role: NodeRole.plant,
            component: NodeComponent.roofTank,
            tankLitres: 5000),
        _n('mB1', 400, 1),
        _n('mB0', 400, 0),
        // Coincident fixtures on floor 1 (same world x) — must be spread apart.
        _n('wc1', 150, 1,
            role: NodeRole.fixture,
            fixture: PlumbingFixture.waterClosetFlushValve),
        _n('lav1', 150, 1,
            role: NodeRole.fixture, fixture: PlumbingFixture.lavatory),
        // Two close branch runs on floor 0 whose long sized tags collide.
        _n('wc0', 100, 0,
            role: NodeRole.fixture,
            fixture: PlumbingFixture.waterClosetFlushValve),
        _n('sink0', 130, 0,
            role: NodeRole.fixture, fixture: PlumbingFixture.kitchenSink),
      ],
      edges: [
        _e('rA1', 'rtA', 'mA1', ServiceType.coldWater, kind: EdgeKind.riser),
        _e('rA0', 'mA1', 'mA0', ServiceType.coldWater, kind: EdgeKind.riser),
        _e('rB1', 'rtB', 'mB1', ServiceType.coldWater, kind: EdgeKind.riser),
        _e('rB0', 'mB1', 'mB0', ServiceType.coldWater, kind: EdgeKind.riser),
        _e('bWc1', 'mA1', 'wc1', ServiceType.coldWater),
        _e('bLav1', 'mA1', 'lav1', ServiceType.coldWater),
        _e('bWc0', 'mA0', 'wc0', ServiceType.coldWater),
        _e('bSink0', 'mA0', 'sink0', ServiceType.coldWater),
      ],
    );

Map<String, EdgeSizing> _denseSizing() => {
      'rA1': _sz('rA1', ServiceType.coldWater, 50),
      'rA0': _sz('rA0', ServiceType.coldWater, 50),
      'rB1': _sz('rB1', ServiceType.coldWater, 50),
      'rB0': _sz('rB0', ServiceType.coldWater, 50),
      'bWc0': _sz('bWc0', ServiceType.coldWater, 40),
      'bSink0': _sz('bSink0', ServiceType.coldWater, 25),
    };

/// Whether two labels' collision boxes intersect, sized with the builder's OWN
/// per-char advance ([kMechRiserLabelCharW]) and the same baseline-up box model.
bool _labelBoxesIntersect(SldLabel a, SldLabel b) {
  double w(SldLabel l) => l.text.length * l.size * kMechRiserLabelCharW;
  final aMaxX = a.x + w(a), bMaxX = b.x + w(b);
  final aMinY = a.y - a.size, bMinY = b.y - b.size;
  return a.x < bMaxX && b.x < aMaxX && aMinY < b.y && bMinY < a.y;
}

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

    test('sldSheetsToPdf issues a numbered SET — page count matches the input',
        () {
      // Three sheets (a per-service pair + a combined view of the same riser)
      // → one 3-page PDF with real per-page `Sheet i of 3` counters and
      // per-page diagram titles.
      final sheet = buildMechanicalRiserSld(
        network: _riserNet(),
        building: _levels,
        downfeed: true,
      );
      final pdf = latin1.decode(sldSheetsToPdf(
        [sheet, sheet, sheet],
        diagramTitles: [
          'DIAGRAM SISTEM AIR BERSIH',
          'DIAGRAM SISTEM AIR KOTOR',
          'DIAGRAM SISTEM MEKANIKAL',
        ],
      ));
      expect(pdf.startsWith('%PDF-1.4'), isTrue);
      expect(pdf.trimRight().endsWith('%%EOF'), isTrue);
      expect(pdf, contains('/Count 3'));
      // Each page stamps its own counter + its own heading.
      expect(pdf, contains('(Sheet 1 of 3)'));
      expect(pdf, contains('(Sheet 2 of 3)'));
      expect(pdf, contains('(Sheet 3 of 3)'));
      expect(pdf, contains('(DIAGRAM SISTEM AIR BERSIH)'));
      expect(pdf, contains('(DIAGRAM SISTEM AIR KOTOR)'));
      expect(pdf, contains('(DIAGRAM SISTEM MEKANIKAL)'));
      // The xref stays byte-accurate on the multi-page document.
      final sx = pdf.lastIndexOf('startxref');
      final xrefOffset = int.parse(pdf
          .substring(sx + 'startxref'.length, pdf.indexOf('%%EOF', sx))
          .trim());
      expect(pdf.substring(xrefOffset, xrefOffset + 4), 'xref');
    });

    test('sldSheetsToPdf with an empty list yields one valid blank page', () {
      final pdf = latin1.decode(sldSheetsToPdf(const []));
      expect(pdf.startsWith('%PDF-1.4'), isTrue);
      expect(pdf, contains('/Count 1'));
      expect(pdf, contains('(Sheet 1 of 1)'));
    });

    // ── B4: line discipline in the exported riser ────────────────────────────
    test('B4: pipe runs/risers are medium+layered, datum lines stay thin', () {
      final s = buildMechanicalRiserSld(
        network: _riserNet(),
        sizing: {'riser': _sz('riser', ServiceType.coldWater, 50)},
        building: _levels,
        downfeed: true,
      );
      final lines = s.prims.whereType<SldLine>().toList();
      // Datum baselines: one per building floor, all THIN and un-layered.
      final datums = lines
          .where((l) => l.weight == SldWeight.thin && l.layer == null)
          .toList();
      expect(datums.length, greaterThanOrEqualTo(3)); // Ground / L1 / Roof
      for (final d in datums) {
        expect(d.y1, d.y2); // datum is a pure horizontal baseline
      }
      // Every cold-water pipe run/riser is MEDIUM and carries the CW layer —
      // re-derived per CAD-OUTPUT-UX-REVIEW B4 (runs were formerly thin).
      final cwPipes = lines.where((l) => l.layer == 'CW').toList();
      expect(cwPipes, isNotEmpty);
      for (final p in cwPipes) {
        expect(p.weight, SldWeight.medium);
      }
    });

    test('B4: the vent service draws DASHED, cold water solid', () {
      final net = Network(
        nodes: [
          _n('m', 200, 0),
          _n('v', 200, 1),
          _n('wc', 120, 0,
              role: NodeRole.fixture,
              fixture: PlumbingFixture.waterClosetFlushValve),
        ],
        edges: [
          _e('vent', 'm', 'v', ServiceType.vent, kind: EdgeKind.riser),
          _e('cw', 'm', 'wc', ServiceType.coldWater),
        ],
      );
      final s = buildMechanicalRiserSld(network: net, building: _levels);
      final lines = s.prims.whereType<SldLine>();
      // Vent pipe lines are dashed + on the 'V' layer; CW lines are solid.
      final ventLines = lines.where((l) => l.layer == 'V');
      expect(ventLines, isNotEmpty);
      expect(ventLines.every((l) => l.dashed), isTrue);
      final cwLines = lines.where((l) => l.layer == 'CW');
      expect(cwLines, isNotEmpty);
      expect(cwLines.every((l) => !l.dashed), isTrue);
    });

    // ── B5: label collision avoidance ────────────────────────────────────────
    test('B5: no two label boxes intersect on a dense two-riser sheet', () {
      final s = buildMechanicalRiserSld(
        network: _denseTwoRiserNet(),
        sizing: _denseSizing(),
        building: _levels,
        downfeed: true,
      );
      final labels = s.prims.whereType<SldLabel>().toList();
      // Reuse the builder's OWN per-char advance to size each box.
      for (var i = 0; i < labels.length; i++) {
        for (var j = i + 1; j < labels.length; j++) {
          expect(_labelBoxesIntersect(labels[i], labels[j]), isFalse,
              reason: 'labels "${labels[i].text}" and "${labels[j].text}" '
                  'overlap');
        }
      }
    });

    test('B5: every expected tag survives the collision pass', () {
      final s = buildMechanicalRiserSld(
        network: _denseTwoRiserNet(),
        sizing: _denseSizing(),
        building: _levels,
        downfeed: true,
      );
      final text = _labels(s);
      // Both riser stacks keep their per-service ids + a sized pipe tag; both
      // dense fixtures keep their node labels — nothing is silently dropped.
      expect(text, contains('CW-R1'));
      expect(text, contains('CW-R2'));
      expect(text, contains('50-CW-PPR'));
      expect(text, contains('WC'));
      expect(text, contains('Lavatory'));
      expect(text, contains('Sink'));
    });

    test('B5: a displaced tag gets a thin diagonal leader line', () {
      final s = buildMechanicalRiserSld(
        network: _denseTwoRiserNet(),
        sizing: _denseSizing(),
        building: _levels,
        downfeed: true,
      );
      // A leader is the only THIN line that is neither a horizontal datum nor an
      // axis-aligned pipe L-route: it runs diagonally from an anchor to a
      // bumped label.
      final leaders = s.prims.whereType<SldLine>().where((l) =>
          l.weight == SldWeight.thin && l.x1 != l.x2 && l.y1 != l.y2);
      expect(leaders, isNotEmpty);
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
