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

/// A cold-water riser that ALSO carries a water meter + a PRV inline on the
/// ground-floor main. The G7 valve detail callouts gate on these components
/// existing, so this fixture exercises the both-boxes-present path.
Network _riserNetWithValves() => Network(
      nodes: [
        _n('rt', 200, 2,
            role: NodeRole.plant,
            component: NodeComponent.roofTank,
            tankLitres: 5000),
        _n('m', 200, 0),
        _n('wm', 160, 0, component: NodeComponent.waterMeter),
        _n('prv', 240, 0, component: NodeComponent.prv),
        _n('wc', 120, 0,
            role: NodeRole.fixture,
            fixture: PlumbingFixture.waterClosetFlushValve),
        _n('lav', 280, 0,
            role: NodeRole.fixture, fixture: PlumbingFixture.lavatory),
      ],
      edges: [
        _e('riser', 'rt', 'm', ServiceType.coldWater, kind: EdgeKind.riser),
        _e('em', 'm', 'wm', ServiceType.coldWater),
        _e('ep', 'm', 'prv', ServiceType.coldWater),
        _e('b1', 'm', 'wc', ServiceType.coldWater),
        _e('b2', 'm', 'lav', ServiceType.coldWater),
      ],
    );

/// The bare cold-water riser plus exactly ONE extra [component] node on the
/// ground main — used to prove each valve detail box gates independently (G7).
Network _riserNetWithComponent(NodeComponent component) => Network(
      nodes: [
        _n('rt', 200, 2,
            role: NodeRole.plant,
            component: NodeComponent.roofTank,
            tankLitres: 5000),
        _n('m', 200, 0),
        _n('c', 160, 0, component: component),
        _n('wc', 120, 0,
            role: NodeRole.fixture,
            fixture: PlumbingFixture.waterClosetFlushValve),
      ],
      edges: [
        _e('riser', 'rt', 'm', ServiceType.coldWater, kind: EdgeKind.riser),
        _e('ec', 'm', 'c', ServiceType.coldWater),
        _e('b1', 'm', 'wc', ServiceType.coldWater),
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

/// A soil + vent stack (B2): a drainage riser dropping to a ground-floor base,
/// a vent riser teeing off the shared mid junction, optionally reaching the
/// top floor (VTR) and optionally a cleanout beside the stack base.
Network _stackNet({bool withCleanout = true, bool ventToTop = true}) => Network(
      nodes: [
        _n('base', 200, 0),
        _n('j1', 200, 1),
        if (ventToTop) _n('top', 200, 2) else _n('v0', 260, 0),
        if (withCleanout)
          _n('co', 140, 0,
              role: NodeRole.fixture, component: NodeComponent.cleanout),
      ],
      edges: [
        _e('soil', 'j1', 'base', ServiceType.drainage, kind: EdgeKind.riser),
        if (ventToTop)
          _e('vent', 'j1', 'top', ServiceType.vent, kind: EdgeKind.riser)
        else
          _e('vent', 'v0', 'j1', ServiceType.vent, kind: EdgeKind.riser),
        if (withCleanout) _e('cob', 'base', 'co', ServiceType.drainage),
      ],
    );

/// An upfeed cold-water riser WITH a booster pump on the ground main — exercises
/// the G3 pump-set valve train (suction/discharge glyph rows around the pump).
Network _riserNetWithPump() => Network(
      nodes: [
        _n('gt', 200, 0,
            role: NodeRole.plant,
            component: NodeComponent.groundTank,
            tankLitres: 8000),
        _n('p', 200, 0, role: NodeRole.plant, component: NodeComponent.pump),
        _n('m0', 200, 0),
        _n('m1', 200, 1),
        _n('wc', 120, 1,
            role: NodeRole.fixture,
            fixture: PlumbingFixture.waterClosetFlushValve),
      ],
      edges: [
        _e('gp', 'gt', 'p', ServiceType.coldWater),
        _e('pm', 'p', 'm0', ServiceType.coldWater),
        _e('r', 'm0', 'm1', ServiceType.coldWater, kind: EdgeKind.riser),
        _e('b', 'm1', 'wc', ServiceType.coldWater),
      ],
    );

/// A hot-water supply riser + a per-floor lavatory branch — exercises the G2
/// recirculation RETURN leg (the return riser + recirc pump are drawn from the
/// hotWaterRecirc signal, not a drawn return edge).
Network _hwRiserNet() => Network(
      nodes: [
        _n('hm0', 250, 0),
        _n('hm1', 250, 1),
        _n('hlav', 320, 1,
            role: NodeRole.fixture, fixture: PlumbingFixture.lavatory),
      ],
      edges: [
        _e('hr', 'hm0', 'hm1', ServiceType.hotWater, kind: EdgeKind.riser),
        _e('hb', 'hm1', 'hlav', ServiceType.hotWater),
      ],
    );

/// A drainage stack that carries a FLOOR DRAIN + a vent-through-roof + a ground
/// exit — exercises the G4 drainage reference details + the sewer terminus.
Network _drainNet() => Network(
      nodes: [
        _n('d-exit', 300, 0), // the drainage exit (a plain main on floor 0)
        _n('d-b0', 300, 0), // the stack base
        _n('d-b1', 300, 1),
        _n('d-fd', 360, 1,
            role: NodeRole.fixture, component: NodeComponent.floorDrain),
        _n('v-1', 340, 1),
        _n('v-top', 340, 2),
      ],
      edges: [
        _e('d-e', 'd-exit', 'd-b0', ServiceType.drainage),
        _e('d-r', 'd-b0', 'd-b1', ServiceType.drainage, kind: EdgeKind.riser),
        _e('d-f', 'd-b1', 'd-fd', ServiceType.drainage),
        _e('v-t', 'd-b1', 'v-1', ServiceType.vent),
        _e('v-r', 'v-1', 'v-top', ServiceType.vent, kind: EdgeKind.riser),
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

    test('N15: a plumbing riser DXF uses M-* layers, NEVER the electrical E-*',
        () {
      // The mechanical wrapper defaults to the M-* namespace, so the riser's
      // text / frame / device graphics land on M-TEXT / M-FRAME / M-DETAIL and
      // never on E-BREAKER / E-TEXT / E-FRAME (a plumbing drawing must not carry
      // electrical layers).
      final sheet = buildMechanicalRiserSld(
        network: _riserNet(),
        sizing: {'riser': _sz('riser', ServiceType.coldWater, 50)},
        building: _levels,
        downfeed: true,
        supplyNote: 'Feed: gravity downfeed - roof tank',
      );
      final dxf =
          sldSheetToDxf(sheet: sheet, diagramTitle: 'DIAGRAM SISTEM AIR BERSIH');
      // No electrical class layer appears anywhere in the output.
      for (final e in const [
        'E-BREAKER',
        'E-TEXT',
        'E-FRAME',
        'E-BUS',
        'E-FEEDER',
        'E-ESSENTIAL',
      ]) {
        expect(dxf, isNot(contains(e)), reason: 'must not emit $e');
      }
      // The mechanical layers ARE declared + used (LAYER records + entities).
      expect(dxf, contains('LAYER\n2\nM-TEXT\n'));
      expect(dxf, contains('LAYER\n2\nM-FRAME\n'));
      expect(dxf, contains('LAYER\n2\nM-DETAIL\n'));
      expect(dxf, contains('8\nM-TEXT\n'));
      expect(dxf, contains('8\nM-FRAME\n'));
      // Pipe runs keep their explicit per-service layer (e.g. cold water 'CW').
      expect(dxf, contains('8\nCW\n'));
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
      // Re-derived for the B1 symbol pass: equipment/fixture GLYPH strokes are
      // thin un-layered lines too now, so a datum is additionally identified by
      // its full-band horizontal span (a glyph stroke is ≤ ~20 units long).
      final datums = lines
          .where((l) =>
              l.weight == SldWeight.thin &&
              l.layer == null &&
              l.y1 == l.y2 &&
              (l.x2 - l.x1).abs() > 800)
          .toList();
      expect(datums.length, greaterThanOrEqualTo(3)); // Ground / L1 / Roof
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

    // ── N3: adjacent short branch tags must never fuse ───────────────────────
    test('N3: a dense cluster of coincident short branch tags stays '
        'collision-free with leaders (no "15-CW-PPR25-CW-PPR" fusing)', () {
      // A header feeding SIX fixtures mapping to the SAME band column (same x)
      // on one floor: their branch tags share a midpoint and exhaust the short
      // divert ladder. Before the escape fallback the least-overlap slot still
      // overprinted, fusing tags into one token ("15-CW-PPR25-CW-PPR").
      const fixtures = [
        PlumbingFixture.waterClosetFlushValve,
        PlumbingFixture.lavatory,
        PlumbingFixture.shower,
        PlumbingFixture.kitchenSink,
        PlumbingFixture.bathtub,
        PlumbingFixture.urinalFlushTank,
      ];
      const sizes = [15.0, 20.0, 25.0, 32.0, 40.0, 50.0];
      final net = Network(
        nodes: [
          _n('h', 100, 0),
          for (var i = 0; i < fixtures.length; i++)
            _n('f$i', 400, 0, role: NodeRole.fixture, fixture: fixtures[i]),
        ],
        edges: [
          for (var i = 0; i < fixtures.length; i++)
            _e('r$i', 'h', 'f$i', ServiceType.coldWater),
        ],
      );
      final s = buildMechanicalRiserSld(
        network: net,
        sizing: {
          for (var i = 0; i < sizes.length; i++)
            'r$i': _sz('r$i', ServiceType.coldWater, sizes[i]),
        },
        building: _levels,
      );
      final labels = s.prims.whereType<SldLabel>().toList();
      for (var i = 0; i < labels.length; i++) {
        for (var j = i + 1; j < labels.length; j++) {
          expect(_labelBoxesIntersect(labels[i], labels[j]), isFalse,
              reason: 'labels "${labels[i].text}" and "${labels[j].text}" '
                  'fused');
        }
      }
      // Every branch size survives, distinct — nothing fused or dropped.
      final text = _labels(s);
      for (final tag in [
        '15-CW-PPR',
        '20-CW-PPR',
        '25-CW-PPR',
        '32-CW-PPR',
        '40-CW-PPR',
        '50-CW-PPR',
      ]) {
        expect(text, contains(tag));
      }
      // The diverted tags carry leaders back to their runs (diagonal thin line).
      expect(
          s.prims.whereType<SldLine>().where((l) =>
              l.weight == SldWeight.thin && l.x1 != l.x2 && l.y1 != l.y2),
          isNotEmpty);
    });

    // ── N6: run + riser lengths on the pipe tags ─────────────────────────────
    test('N6: edgeLengths append " - x.x m" to run + riser tags; an absent '
        'edge stays bare', () {
      final s = buildMechanicalRiserSld(
        network: _riserNet(),
        sizing: {
          'riser': _sz('riser', ServiceType.coldWater, 50),
          'b1': _sz('b1', ServiceType.coldWater, 25),
          'b2': _sz('b2', ServiceType.coldWater, 20),
        },
        building: _levels,
        downfeed: true,
        edgeLengths: {
          'riser': const Length(7.5), // §10 elevation delta
          'b1': const Length(3.2), // branch run length
        },
      );
      final text = _labels(s);
      expect(text, contains('50-CW-PPR-GRAVITASI - 7.5 m')); // riser lift
      expect(text, contains('25-CW-PPR-GRAVITASI - 3.2 m')); // branch stub
      // b2 is sized but carries NO length entry ⇒ bare tag (never fabricated).
      expect(text, contains('20-CW-PPR-GRAVITASI'));
      expect(text, isNot(contains('20-CW-PPR-GRAVITASI - ')));
    });

    // ── N7: grouped per-type fan-out (no "+N more" truncation) ───────────────
    test('N7: the fan-out enumerates every fixture grouped by type with counts',
        () {
      // Floor 1 distributes 3 WCs + 2 lavatories + 1 shower — 6 fixtures, past
      // the legacy cap of 4 (which showed "4 + +2 more").
      final net = Network(
        nodes: [
          _n('m', 200, 0),
          for (var i = 0; i < 3; i++)
            _n('wc$i', 100.0 + i, 1,
                role: NodeRole.fixture,
                fixture: PlumbingFixture.waterClosetFlushValve),
          for (var i = 0; i < 2; i++)
            _n('lav$i', 200.0 + i, 1,
                role: NodeRole.fixture, fixture: PlumbingFixture.lavatory),
          _n('sh', 300, 1,
              role: NodeRole.fixture, fixture: PlumbingFixture.shower),
        ],
        edges: [_e('r', 'm', 'wc0', ServiceType.coldWater)],
      );
      final text = _labels(buildMechanicalRiserSld(network: net, building: _levels));
      expect(text, contains('WC x3'));
      expect(text, contains('Lavatory x2'));
      expect(text, contains('Shower')); // count 1 stays bare (no " x1")
      expect(text, isNot(contains('Shower x1')));
      expect(text, isNot(contains('more'))); // no truncation row
    });

    // ── N2: the exported title block carries the real project name ───────────
    test('N2: sldSheetToPdf/Dxf stamp the passed project name (no '
        '"Untitled project")', () {
      final sheet = buildMechanicalRiserSld(
          network: _riserNet(), building: _levels, downfeed: true);
      final pdf =
          latin1.decode(sldSheetToPdf(sheet: sheet, projectName: 'Menara Contoh'));
      expect(pdf, contains('(Menara Contoh)'));
      expect(pdf, isNot(contains('Untitled project')));
      final dxf = sldSheetToDxf(sheet: sheet, projectName: 'Menara Contoh');
      expect(dxf, contains('Menara Contoh'));
      expect(dxf, isNot(contains('Untitled project')));
      // Omitted ⇒ the placeholder (byte-identical default preserved).
      expect(latin1.decode(sldSheetToPdf(sheet: sheet)),
          contains('Untitled project'));
    });

    // ── B1: export parity with the live Auto canvas ──────────────────────────
    test('B1: nodes carry real schematic symbols, not anonymous boxes', () {
      // A pump component renders the plan-symbol glyph (its casing CIRCLE) in
      // the plant SOURCE role; the old node treatment had no such circle.
      final net = Network(
        nodes: [
          _n('p', 100, 0, role: NodeRole.plant, component: NodeComponent.pump),
          _n('m', 300, 0),
        ],
        edges: [_e('e', 'p', 'm', ServiceType.coldWater)],
      );
      final s = buildMechanicalRiserSld(network: net, building: _levels);
      expect(
          s.prims
              .whereType<SldCircle>()
              .where((c) => c.role == SldRole.source),
          isNotEmpty);
      // Fixtures switched from the open circle to the drop-triangle marker and
      // the roof-tank glyph is pure line-work, so the riser net has NO circles.
      final riser = buildMechanicalRiserSld(
          network: _riserNet(), building: _levels, downfeed: true);
      expect(riser.prims.whereType<SldCircle>(), isEmpty);
    });

    test('B1: an equipment detail suffix is appended to the node label', () {
      final s = buildMechanicalRiserSld(
        network: _riserNet(),
        building: _levels,
        downfeed: true,
        equipmentDetailByNodeId: const {'rt': '5 m3'},
      );
      expect(_labels(s), contains('Roof tank · 5 m3'));
      // No supplied detail => the plain name (nothing fabricated).
      final plain = buildMechanicalRiserSld(
          network: _riserNet(), building: _levels, downfeed: true);
      expect(_labels(plain), contains('Roof tank'));
      expect(_labels(plain), isNot(contains('· 5 m3')));
    });

    test('B1: a flow chevron (3 lines) draws ONLY when the solve knows the '
        'direction', () {
      final noDir = buildMechanicalRiserSld(
        network: _riserNet(),
        sizing: {'b1': _sz('b1', ServiceType.coldWater, 40)},
        building: _levels,
        downfeed: true,
      );
      final withDir = buildMechanicalRiserSld(
        network: _riserNet(),
        sizing: {
          'b1': _sz('b1', ServiceType.coldWater, 40).withFlowFrom('m'),
        },
        building: _levels,
        downfeed: true,
      );
      final n0 = noDir.prims.whereType<SldLine>().length;
      final n1 = withDir.prims.whereType<SldLine>().length;
      // A chevron is exactly 3 SldLines (a short shaft + two arrowhead legs).
      expect(n1, n0 + 3);
    });

    test('B1: the new detail params default EMPTY => byte-identical output',
        () {
      final base = buildMechanicalRiserSld(
        network: _riserNet(),
        sizing: {'riser': _sz('riser', ServiceType.coldWater, 50)},
        building: _levels,
        downfeed: true,
      );
      final explicit = buildMechanicalRiserSld(
        network: _riserNet(),
        sizing: {'riser': _sz('riser', ServiceType.coldWater, 50)},
        building: _levels,
        downfeed: true,
        equipmentDetailByNodeId: const {},
        notes: const [],
        detailCallouts: false,
      );
      // Pin byte-identity through a full render (geometry AND ordering).
      expect(sldSheetToDxf(sheet: explicit), sldSheetToDxf(sheet: base));
      // And none of the gated content leaks into the default sheet.
      final text = _labels(base);
      expect(text, isNot(contains('KETERANGAN')));
      expect(text, isNot(contains('DETAIL WATER METER')));
      expect(text, isNot(contains('PUMP-SET DETAIL')));
    });

    test('B1: notes render as a bordered KETERANGAN block that grows the sheet',
        () {
      final s = buildMechanicalRiserSld(
        network: _riserNet(),
        building: _levels,
        downfeed: true,
        notes: const [
          'Feed: gravity downfeed (roof tank)',
          'Roof tank: 5 m3',
        ],
      );
      final text = _labels(s);
      expect(text, contains('KETERANGAN'));
      expect(text, contains('Feed: gravity downfeed (roof tank)'));
      expect(text, contains('Roof tank: 5 m3'));
      // The block border rect (width 240 — the notes block) was emitted and the
      // bounds grew downward to carry it.
      expect(s.prims.whereType<SldRect>().any((r) => r.w == 240), isTrue);
      final plain = buildMechanicalRiserSld(
          network: _riserNet(), building: _levels, downfeed: true);
      expect(s.maxY, greaterThan(plain.maxY));
    });

    test('B1: detailCallouts draws the valve references + the data-gated '
        'plant detail on the water focus only', () {
      // A cold-water riser that ALSO carries a water meter + PRV inline — the
      // detail callouts key off those components existing (G7).
      final s = buildMechanicalRiserSld(
        network: _riserNetWithValves(),
        building: _levels,
        downfeed: true,
        detailCallouts: true,
        equipmentDetailByNodeId: const {'rt': '5 m3'},
      );
      final text = _labels(s);
      expect(text, contains('DETAIL WATER METER'));
      expect(text, contains('DETAIL PRV SET'));
      expect(text, contains('PRV'));
      // The plant detail carries the ROOF TANK row with its REAL capacity and
      // the downfeed GRAVITASI leg label.
      expect(text, contains('PUMP-SET DETAIL'));
      expect(text, contains('ROOF TANK 5 m3'));
      expect(text, contains('GRAVITASI'));
      // Honesty: no supplied capacity => the row stays plain.
      final noCap = buildMechanicalRiserSld(
          network: _riserNetWithValves(),
          building: _levels,
          downfeed: true,
          detailCallouts: true);
      expect(_labels(noCap), contains('ROOF TANK'));
      expect(_labels(noCap), isNot(contains('ROOF TANK 5 m3')));
      // No plant nodes at all => the plant detail is omitted entirely (the
      // valve references are also omitted — the stack net carries no meter/PRV).
      final noPlant = buildMechanicalRiserSld(
          network: _stackNet(), building: _levels, detailCallouts: true);
      expect(_labels(noPlant), isNot(contains('PUMP-SET DETAIL')));
      // A non-water focus omits the clean-water details entirely.
      final drain = buildMechanicalRiserSld(
          network: _riserNetWithValves(),
          building: _levels,
          focus: ServiceType.drainage,
          detailCallouts: true);
      expect(_labels(drain), isNot(contains('DETAIL WATER METER')));
    });

    test('G7: the valve detail callouts are DATA-GATED on the drawn '
        'components — each box draws only when its device exists', () {
      // A plain cold-water riser with NO meter and NO PRV: neither box draws,
      // even with Details on (was drawn unconditionally — the finding).
      final none = _labels(buildMechanicalRiserSld(
          network: _riserNet(),
          building: _levels,
          downfeed: true,
          detailCallouts: true));
      expect(none, isNot(contains('DETAIL WATER METER')));
      expect(none, isNot(contains('DETAIL PRV SET')));
      // Water meter only => only the meter box (independent gating).
      final meterOnly = _labels(buildMechanicalRiserSld(
          network: _riserNetWithComponent(NodeComponent.waterMeter),
          building: _levels,
          detailCallouts: true));
      expect(meterOnly, contains('DETAIL WATER METER'));
      expect(meterOnly, isNot(contains('DETAIL PRV SET')));
      // PRV only => only the PRV box.
      final prvOnly = _labels(buildMechanicalRiserSld(
          network: _riserNetWithComponent(NodeComponent.prv),
          building: _levels,
          detailCallouts: true));
      expect(prvOnly, contains('DETAIL PRV SET'));
      expect(prvOnly, isNot(contains('DETAIL WATER METER')));
    });

    // ── B2: drainage / vent stack detail ─────────────────────────────────────
    test('B2: VTR + CO + the vent tee draw only from the DRAWN network', () {
      final s = buildMechanicalRiserSld(network: _stackNet(), building: _levels);
      final text = _labels(s);
      // The vent riser reaches the top floor => a VTR termination.
      expect(text, contains('VTR'));
      // A drawn cleanout serves the stack base => the CO tag.
      expect(text, contains('CO'));
      // The vent-to-soil tee: a short (18-unit) D-layer bar at the shared
      // junction — p.dx ± 9 by construction.
      expect(
          s.prims.whereType<SldLine>().any((l) =>
              l.layer == 'D' && l.y1 == l.y2 && (l.x2 - l.x1).abs() == 18),
          isTrue);
      // No cleanout drawn => no CO tag (that case is a Review ADVISORY, never a
      // fabricated symbol).
      final bare = buildMechanicalRiserSld(
          network: _stackNet(withCleanout: false), building: _levels);
      expect(_labels(bare), isNot(contains('CO')));
      // A vent stopping below the roof is NOT a VTR.
      final short = buildMechanicalRiserSld(
          network: _stackNet(ventToTop: false), building: _levels);
      expect(_labels(short), isNot(contains('VTR')));
    });

    test('B2: the legend speaks the Indonesian sheet language for '
        'drainage/vent/rainwater', () {
      final s = buildMechanicalRiserSld(network: _stackNet(), building: _levels);
      final meanings = {for (final e in s.legend) e.code: e.meaning};
      expect(meanings['D'], 'Air kotor & bekas (drainage)');
      expect(meanings['V'], 'Ven (vent)');
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

    // ── G3: the pump-set detail draws the suction/discharge valve train ───────
    test('G3: the PUMP-SET DETAIL draws the suction/discharge valve train', () {
      final s = buildMechanicalRiserSld(
        network: _riserNetWithPump(),
        building: _levels,
        detailCallouts: true,
        equipmentDetailByNodeId: const {'p': '2.2 kW'},
      );
      final text = _labels(s);
      expect(text, contains('PUMP-SET DETAIL'));
      // Suction leg (GV - STR - FJ) + discharge leg (CV - GV - FJ) glyph rows.
      expect(text, contains('STR')); // suction strainer
      expect(text, contains('CV')); // discharge check valve
      expect(text, contains('FJ')); // flexible joints
      expect(text, contains('GV')); // isolation gate valves
      expect(text, contains('BOOSTER PUMP 2.2 kW'));
      // A tank-only plant (no pump) draws NO valve train — nothing fabricated.
      final noPump = _labels(buildMechanicalRiserSld(
          network: _riserNet(),
          building: _levels,
          downfeed: true,
          detailCallouts: true));
      expect(noPump, contains('PUMP-SET DETAIL')); // the roof-tank still shows
      expect(noPump, isNot(contains('STR')));
      expect(noPump, isNot(contains('CV')));
      expect(noPump, isNot(contains('FJ')));
    });

    // ── G4: drainage reference details + the sewer/STP terminus ───────────────
    test('G4: drainage reference details + the disposal terminus draw on the '
        'drainage view', () {
      final s = buildMechanicalRiserSld(
        network: _drainNet(),
        building: _levels,
        detailCallouts: true,
      );
      final text = _labels(s);
      expect(text, contains('DETAIL FLOOR DRAIN'));
      expect(text, contains('DETAIL VTR'));
      // The terminus at the drainage exit — a GENERIC disposal label, never a
      // fabricated STP / city-sewer destination the model can't confirm.
      expect(text, contains('KE SALURAN PEMBUANGAN'));
      expect(text, isNot(contains('KE STP')));
      expect(text, isNot(contains('KE RIOL')));
      // Focusing the clean-water view hides the drainage reference boxes + the
      // terminus (they belong to the drainage view).
      final cw = _labels(buildMechanicalRiserSld(
          network: _drainNet(),
          building: _levels,
          focus: ServiceType.coldWater,
          detailCallouts: true));
      expect(cw, isNot(contains('DETAIL FLOOR DRAIN')));
      expect(cw, isNot(contains('KE SALURAN PEMBUANGAN')));
      // Honesty: a drainage net WITHOUT a floor drain shows no FLOOR DRAIN box.
      final noFd = _labels(buildMechanicalRiserSld(
          network: _stackNet(), building: _levels, detailCallouts: true));
      expect(noFd, isNot(contains('DETAIL FLOOR DRAIN')));
    });

    test('G4: the terminus is data-gated — no drainage ⇒ no disposal label', () {
      // A pure cold-water riser carries no drainage exit, so no terminus.
      final s = buildMechanicalRiserSld(
          network: _riserNet(),
          building: _levels,
          downfeed: true,
          detailCallouts: true);
      expect(_labels(s), isNot(contains('KE SALURAN PEMBUANGAN')));
    });

    // ── G2: the hot-water recirculation return leg ───────────────────────────
    test('G2: hotWaterRecirc draws the HWR return leg + recirc pump; off ⇒ '
        'byte-identical', () {
      final withR = buildMechanicalRiserSld(
        network: _hwRiserNet(),
        building: _levels,
        hotWaterRecirc: true,
      );
      final text = _labels(withR);
      expect(text, contains('HWR')); // the return-leg tag
      expect(text, contains('HWR PUMP')); // the recirc pump at the loop base
      // A THINNER + DASHED hot-water (HW-layer) return riser exists.
      expect(
          withR.prims.whereType<SldLine>().any((l) =>
              l.dashed &&
              l.layer == 'HW' &&
              l.weight == SldWeight.thin &&
              l.x1 == l.x2),
          isTrue);
      // Off (or default) draws NOTHING — byte-identical through a full render.
      final off = buildMechanicalRiserSld(
          network: _hwRiserNet(), building: _levels, hotWaterRecirc: false);
      final def =
          buildMechanicalRiserSld(network: _hwRiserNet(), building: _levels);
      expect(sldSheetToDxf(sheet: off), sldSheetToDxf(sheet: def));
      expect(_labels(off), isNot(contains('HWR')));
      // No hot-water riser ⇒ nothing drawn even with the flag on.
      final noHw = _labels(buildMechanicalRiserSld(
          network: _riserNet(),
          building: _levels,
          downfeed: true,
          hotWaterRecirc: true));
      expect(noHw, isNot(contains('HWR')));
    });
  });
}
