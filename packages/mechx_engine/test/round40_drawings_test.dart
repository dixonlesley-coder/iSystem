// Round 40 (2026-10-18) — electrical drawing honesty.
//
// Each group pins one confirmed finding with a first-principles derivation;
// where a counterexample generalises, it is a seeded property.
import 'dart:math' as math;

import 'package:mechx_engine/electrical/advanced_study.dart';
import 'package:mechx_engine/electrical/bom.dart' show faultSpecifiedKa;
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/geo_length.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/sources.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/report/electrical_pdf_export.dart'
    show sldSinglePageMinLabelPt;
import 'package:mechx_engine/report/electrical_plan_export.dart';
import 'package:mechx_engine/report/electrical_sld_drawing.dart';
import 'package:mechx_engine/report/riser_pagination.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

const _p = PuilProfile();

ElectricalCircuit _feeder(String id, String to) => ElectricalCircuit(
    id: id,
    name: 'to $to',
    loadKind: LoadKind.feeder,
    feedsPanelId: to,
    phases: 3,
    length: const Length(20));

ElectricalCircuit _light(String id) => ElectricalCircuit(
    id: id,
    name: 'Light $id',
    loadKind: LoadKind.lighting,
    isLighting: true,
    loadW: 1200,
    length: const Length(20));

LayoutPos _at(int floor) =>
    LayoutPos(sheetId: 's$floor', floorIndex: floor, x: 0, y: 0);

/// MDP (normal, ground) feeds SDP-1..3 on floors 1..3; EMDP (essential,
/// ground) feeds EP-3 on floor 3 — two parents whose feeders both climb the
/// shaft to floor 3.
ElectricalProject _twoParentRiser({double? supplyVa}) => ElectricalProject(
      id: 'p',
      name: 'P',
      supplyCapacityVa: supplyVa == null ? null : ApparentPower(supplyVa),
      panels: [
        ElectricalPanel(
            id: 'MDP',
            name: 'MDP',
            layoutPos: _at(0),
            circuits: [
              for (var f = 1; f <= 3; f++) _feeder('m$f', 'SDP$f'),
            ]),
        ElectricalPanel(
            id: 'EMDP',
            name: 'EMDP',
            essential: true,
            layoutPos: _at(0),
            circuits: [_feeder('e3', 'EP3')]),
        for (var f = 1; f <= 3; f++)
          ElectricalPanel(
              id: 'SDP$f',
              name: 'SDP-$f',
              sourceType: PanelSource.feeder,
              fedByCircuitId: 'm$f',
              layoutPos: _at(f),
              circuits: [_light('l$f')]),
        ElectricalPanel(
            id: 'EP3',
            name: 'EP-3',
            essential: true,
            sourceType: PanelSource.feeder,
            fedByCircuitId: 'e3',
            layoutPos: _at(3),
            circuits: [_light('el')]),
      ],
    );

const _fourStoreys = BuildingLevels([
  Floor('G', Length(4)),
  Floor('L1', Length(4)),
  Floor('L2', Length(4)),
  Floor('L3', Length(4)),
]);

void main() {
  // ── 9. normal and essential risers never share one channel line ─────────
  group('elec-drawings-5-riser-shared-channel-essential-overprints-normal',
      () {
    final project = _twoParentRiser();
    final sys = computeSystem(_p, project);
    final sheet = buildElectricalRiser(
        project: project, result: sys, building: _fourStoreys);

    test('no vertical normal line coincides with a vertical essential line',
        () {
      final verticals = sheet.prims
          .whereType<SldLine>()
          .where((l) => (l.x1 - l.x2).abs() < 1e-9 && l.y1 != l.y2)
          .toList();
      final hits = <String>[];
      for (final a in verticals) {
        for (final b in verticals) {
          if (a.role == b.role) continue;
          if ((a.x1 - b.x1).abs() > 1e-6) continue;
          final lo = math.max(math.min(a.y1, a.y2), math.min(b.y1, b.y2));
          final hi = math.min(math.max(a.y1, a.y2), math.max(b.y1, b.y2));
          if (hi - lo > 1e-6) hits.add('x ${a.x1} ${a.role} / ${b.role}');
        }
      }
      expect(hits, isEmpty);
      // Both roles are drawn (the essential trunk is its own lane).
      expect(verticals.any((l) => l.role == SldRole.essential), isTrue);
      expect(verticals.any((l) => l.role == SldRole.normal), isTrue);
    });

    test('a one-role riser keeps one channel (no lane offset)', () {
      final normalOnly = ElectricalProject(
          id: 'p',
          name: 'P',
          panels: [
            for (final p in project.panels)
              if (p.id != 'EMDP' && p.id != 'EP3') p,
          ]);
      final s = computeSystem(_p, normalOnly);
      final r = buildElectricalRiser(
          project: normalOnly, result: s, building: _fourStoreys);
      final xs = {
        for (final l in r.prims.whereType<SldLine>())
          if ((l.x1 - l.x2).abs() < 1e-9 && (l.y1 - l.y2).abs() > 100)
            l.x1.toStringAsFixed(2),
      };
      expect(xs, hasLength(1), reason: 'one shared channel vertical');
    });
  });

  // ── 13. a page without the spine keys no Source / Earth ─────────────────
  group('elec-drawings-5-riser-page-legend-keys-unprinted-source', () {
    final project = _twoParentRiser(supplyVa: 66000);
    final sys = computeSystem(_p, project);
    SldSheet page(int lo, int hi) => buildElectricalRiser(
        project: project,
        result: sys,
        building: _fourStoreys,
        sourceChain: true,
        floorRange: (lo: lo, hi: hi));
    List<String> codes(SldSheet s) => [for (final e in s.legend) e.code];

    test('the upper page carries no source prims and no Source / Earth key',
        () {
      final upper = page(2, 3);
      expect(upper.prims.any((p) => switch (p) {
            SldLine(:final role) => role == SldRole.source,
            SldLabel(:final role) => role == SldRole.source,
            _ => false,
          }), isFalse);
      expect(codes(upper), isNot(contains('Source')));
      expect(codes(upper), isNot(contains('Earth')));
    });

    test('the page holding the root band keys both', () {
      final ground = page(0, 1);
      expect(codes(ground), containsAll(['Source', 'Earth']));
    });
  });

  // ── 14. the supply lead never strikes the genset coverage label ─────────
  group('elec-drawings-5-supply-lead-strikes-genset-label', () {
    // Ruko: PLN 23 kVA LV service, a FORCED 20 kVA genset (backs 100 %).
    final project = ElectricalProject(
      id: 'p',
      name: 'Ruko',
      supplyCapacityVa: const ApparentPower(23000),
      sources: const ElectricalSources(
          generator: GeneratorSource(kva: ApparentPower(20000))),
      panels: [
        ElectricalPanel(id: 'MDP', name: 'MDP', layoutPos: _at(0), circuits: [
          for (var i = 0; i < 3; i++)
            ElectricalCircuit(
                id: 'h$i',
                name: 'Heater $i',
                loadKind: LoadKind.heating,
                loadW: 3000,
                length: const Length(10)),
          _feeder('f1', 'LP1'),
        ]),
        // An upper-floor board puts the spine BESIDE the ground root (its
        // lead runs below the side-source stack into the root's supply row).
        ElectricalPanel(
            id: 'LP1',
            name: 'LP-1',
            sourceType: PanelSource.feeder,
            fedByCircuitId: 'f1',
            layoutPos: _at(1),
            circuits: [_light('l1')]),
      ],
    );
    final sys = computeSystem(_p, project);

    for (final (name, sheet) in [
      (
        'riser',
        buildElectricalRiser(
            project: project,
            result: sys,
            building: const BuildingLevels(
                [Floor('G', Length(4)), Floor('L1', Length(4))]),
            sourceChain: true)
      ),
      (
        'overview',
        buildElectricalOverview(
            project: project, result: sys, sourceChain: true)
      ),
    ]) {
      test('$name: no source line crosses the "backs" label glyph band', () {
        final backs = sheet.prims
            .whereType<SldLabel>()
            .where((l) => l.text.startsWith('backs '))
            .toList();
        expect(backs, hasLength(1));
        final l = backs.single;
        // Glyph band: cap height 0.718 em above the baseline, descent 0.3 em
        // below; width ~0.55 em per char (Helvetica average).
        final top = l.y - 0.718 * l.size, bottom = l.y + 0.3 * l.size;
        final left = l.x, right = l.x + l.text.length * 0.55 * l.size;
        final strikes = sheet.prims.whereType<SldLine>().where((s) {
          if ((s.y1 - s.y2).abs() > 1e-9) return false;
          final lo = math.min(s.x1, s.x2), hi = math.max(s.x1, s.x2);
          return s.y1 > top && s.y1 < bottom && lo < right && hi > left;
        }).toList();
        expect(strikes, isEmpty);
      });
    }
  });

  // ── 10. an under-rated device is marked on the schedule ─────────────────
  group('elec-drawings-5-schedule-underrated-device-ka-unmarked', () {
    // A 60 kA origin: SDP 4 m of 10 mm2 from the MDP keeps ~26 kA at its bus,
    // above the 25 kA MCB class maximum -> the study raises
    // breaking-capacity-inadequate and the schedule must print 'kA!'.
    final project = ElectricalProject(
      id: 'p',
      name: 'P',
      originFaultLevelA: const Current(60000),
      panels: [
        const ElectricalPanel(id: 'MDP', name: 'MDP', circuits: [
          ElectricalCircuit(
              id: 'f',
              name: 'to SDP',
              loadKind: LoadKind.feeder,
              feedsPanelId: 'SDP',
              phases: 3,
              length: Length(4),
              cableOverrideMm2: 10),
        ]),
        ElectricalPanel(
            id: 'SDP',
            name: 'SDP',
            sourceType: PanelSource.feeder,
            fedByCircuitId: 'f',
            circuits: [for (var i = 0; i < 3; i++) _light('w$i')]),
      ],
    );
    final sys = computeSystem(_p, project,
        originFaultLevel: const Current(60000), busbarClearingTimeS: 0.1);
    final adv = computeAdvancedStudy(_p, project, sys);
    final ka = faultSpecifiedKa(adv.fault);
    final sheet = buildElectricalPanelDetail(
        project: project,
        result: sys,
        panelId: 'SDP',
        breakerIcuKaByPanelId: ka.incomers,
        breakerKaByCircuitId: ka.breakers);
    final labels = [
      for (final p in sheet.prims)
        if (p is SldLabel) p.text,
    ];

    test('every way the study finds inadequate prints kA!, and only those',
        () {
      for (final id in ['w0', 'w1', 'w2']) {
        final c = adv.fault.circuits[id]!;
        final name = 'Light $id';
        final row = labels.indexWhere((t) => t.contains(name));
        expect(row, greaterThanOrEqualTo(0));
        final marked = labels.any((t) =>
            t.contains('${c.breakerKa.toStringAsFixed(0)}kA!') &&
            t.startsWith('MCB'));
        expect(c.breakerAdequate, isFalse,
            reason: 'fixture: the MCB class cannot break the SDP bus fault');
        expect(marked, isTrue);
      }
    });

    test('the legend keys kA! and no longer claims Icu >= the bus fault', () {
      final codes = {for (final e in sheet.legend) e.code: e.meaning};
      expect(codes.keys, contains('kA!'));
      expect(codes['kA'], 'Breaking capacity Icu');
    });

    test('without a bus fault (Fold 1 off) nothing is marked', () {
      final s0 = computeSystem(_p, project);
      final d = buildElectricalPanelDetail(
          project: project, result: s0, panelId: 'SDP');
      expect(
          d.prims.whereType<SldLabel>().any((l) => l.text.contains('kA!')),
          isFalse);
    });
  });

  // ── 11. every off-sheet riser gets its own marker ───────────────────────
  group('elec-drawings-5-layout-riser-markers-coincide', () {
    test('21 risers at one board -> 21 distinct marker positions', () {
      final data = ElectricalPlanData(nodes: const [
        ElectricalPlanNode(
            x: 0, y: 0, tag: 'MDP', kind: ElectricalPlanNodeKind.panel),
      ], risers: [
        for (var i = 0; i < 21; i++)
          ElectricalPlanRiser(
              x: 0, y: 0, text: 'ke SDP-L${i + 1} - ${4.0 * (i + 1)} m',
              sense: 'UP'),
      ]);
      final ann = layoutElectricalPlanAnnotations(data,
          map: (x, y) => (x: x, y: -y), sizes: kElectricalPlanPdfSizes);
      final marks = {
        for (final r in ann.risers)
          '${r.x2.toStringAsFixed(3)},${r.y2.toStringAsFixed(3)}',
      };
      expect(marks, hasLength(21));
      // Markers stay at least one marker diameter apart.
      final pts = [for (final r in ann.risers) (r.x2, r.y2)];
      final d = 2 * kElectricalPlanPdfSizes.riserR;
      for (var i = 0; i < pts.length; i++) {
        for (var j = i + 1; j < pts.length; j++) {
          final dx = pts[i].$1 - pts[j].$1, dy = pts[i].$2 - pts[j].$2;
          expect(math.sqrt(dx * dx + dy * dy), greaterThanOrEqualTo(d),
              reason: 'markers $i / $j');
        }
      }
    });

    test('up to 8 risers keep the legacy bearings (byte-identical)', () {
      final data = ElectricalPlanData(nodes: const [
        ElectricalPlanNode(
            x: 0, y: 0, tag: 'MDP', kind: ElectricalPlanNodeKind.panel),
      ], risers: [
        for (var i = 0; i < 8; i++)
          ElectricalPlanRiser(x: 0, y: 0, text: 'r$i', sense: 'UP'),
      ]);
      final ann = layoutElectricalPlanAnnotations(data,
          map: (x, y) => (x: x, y: -y), sizes: kElectricalPlanPdfSizes);
      const z = kElectricalPlanPdfSizes;
      final reach = z.panelH / 2 + z.riserStub; // 22
      for (final r in ann.risers) {
        expect(math.sqrt(r.x2 * r.x2 + r.y2 * r.y2), closeTo(reach, 1e-9));
      }
    });
  });

  // ── 12. a width-limited band shrinks only its own page ──────────────────
  group('elec-drawings-5-riser-pagination-global-cap-shrinks-all-pages', () {
    // A tower: the GROUND band holds the source spine, MDP and six more
    // boards (width-limited), every upper floor one SDP fed from the MDP.
    const floors = 13;
    final building = BuildingLevels([
      for (var f = 0; f < floors; f++) Floor(f == 0 ? 'G' : 'L$f', const Length(4)),
    ]);
    final project = ElectricalProject(
      id: 'p',
      name: 'Tower',
      supplyCapacityVa: const ApparentPower(147000),
      panels: [
        ElectricalPanel(id: 'MDP', name: 'MDP', layoutPos: _at(0), circuits: [
          for (var f = 1; f < floors; f++) _feeder('m$f', 'SDP$f'),
          for (var g = 0; g < 6; g++) _feeder('g$g', 'GB$g'),
        ]),
        for (var g = 0; g < 6; g++)
          ElectricalPanel(
              id: 'GB$g',
              name: 'GROUND BOARD $g',
              sourceType: PanelSource.feeder,
              fedByCircuitId: 'g$g',
              layoutPos: _at(0),
              circuits: [_light('gl$g')]),
        for (var f = 1; f < floors; f++)
          ElectricalPanel(
              id: 'SDP$f',
              name: 'SDP-L$f',
              sourceType: PanelSource.feeder,
              fedByCircuitId: 'm$f',
              layoutPos: _at(f),
              circuits: [_light('l$f')]),
      ],
    );
    final sys = computeSystem(_p, project);
    SldSheet build(({int lo, int hi})? r) => buildElectricalRiser(
        project: project,
        result: sys,
        building: building,
        sourceChain: true,
        floorRange: r);
    double pt(SldSheet s) => sldSinglePageMinLabelPt(s);

    test('every page prints at the best its own floors allow', () {
      final pages = paginatedRiserSheets(
          build: build,
          levelCount: floors,
          diagramTitle: 'ELECTRICAL SINGLE-LINE DIAGRAM');
      final single = [
        for (var f = 0; f < floors; f++) pt(build((lo: f, hi: f))),
      ];
      expect(pages.length, greaterThan(1));
      var covered = 0;
      for (final page in pages) {
        final onPage = [
          for (var f = 0; f < floors; f++)
            if (page.prims.whereType<SldLabel>().any((l) =>
                l.size == 10 && l.text == (f == 0 ? 'G' : 'L$f')))
              f,
        ];
        covered += onPage.length;
        final target = onPage
            .map((f) => math.min(7.0, 0.95 * single[f]))
            .reduce(math.max);
        expect(pt(page), greaterThanOrEqualTo(target - 1e-6),
            reason: 'page $onPage');
        // A page of upper floors whose single pages reach 7 pt prints at 7.
        if (!onPage.contains(0) &&
            onPage.every((f) => single[f] * 0.95 >= 7 - 1e-9)) {
          expect(pt(page), greaterThanOrEqualTo(7 - 1e-6),
              reason: 'page $onPage');
        }
      }
      expect(covered, floors);
    });
  });
}
