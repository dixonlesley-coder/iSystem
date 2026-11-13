// Round 65 (elec-convergence-17-sectioned-service-drawn-as-paralleled-
// transformers) — a SECTIONED (dual-transformer / transformerUnits >= 2)
// service is DRAWN as separate sections, never as n units paralleled onto
// one LV main.
//
// The fault study rates every device on ONE unit's fault (Round 58/60:
// Isc = S / (sqrt(3) x 400 x 0.04) per section); paralleling two units onto
// one bus would double it. Round 65 r2 — the drawing now carries the
// topology itself, not a caption: one transformer node per section
// ('TX-i <kVA>'), one 'LV SECTION i' board each, a normally-open bus
// coupler between adjacent sections (open blade + 'N.O.' + a legend key),
// and every service-entrance board fed from the section
// [serviceSectionOfRoot] puts it on — the partition [sectionAssignment]
// realises for [minimalMaxSectionLoad], the figure the loading judge used.
// A single section draws none of it (byte-identical).
library;

// Backlog E-1 (2026-11-13): every board here is its own SERVICE ENTRANCE
// (own meter / section main), so each is flagged `serviceEntrance: true` —
// an unflagged un-fed board after the first is `unfed-panel` and outside
// the supply study.
import 'dart:math' as math;

import 'package:mechx_engine/electrical/advanced_study.dart';
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/sources.dart';
import 'package:mechx_engine/electrical/supply_design.dart';
import 'package:mechx_engine/report/electrical_sld_drawing.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

const _p = PuilProfile();

ElectricalProject _proj(
        {bool dual = false, int? units, List<double>? rootKw}) =>
    ElectricalProject(
      id: 'x',
      name: 'x',
      dualTransformer: dual,
      transformerUnits: units,
      sources: const ElectricalSources(generator: GeneratorSource()),
      panels: [
        for (final (i, kw) in (rootKw ?? const [160.0, 160.0]).indexed)
          ElectricalPanel(serviceEntrance: true, 
            id: 'R$i',
            name: 'MDP-$i',
            system: ElectricalSystem.threePhase,
            voltage: const Voltage(400),
            circuits: [
              for (var k = 0; k < 4; k++)
                ElectricalCircuit(
                  id: 'R$i-$k',
                  name: 'Load $k',
                  loadKind: LoadKind.general,
                  loadW: kw * 1000 / 4,
                  cosPhi: 1,
                  phases: 3,
                  length: const Length(10),
                ),
            ],
          ),
      ],
    );

Iterable<SldLabel> _labels(SldSheet s) => s.prims.whereType<SldLabel>();

Iterable<String> _texts(SldSheet s) => _labels(s).map((l) => l.text);

/// The column x of section [i]'s transformer ('TX-i …' labelled at x + 22).
double _txColumn(SldSheet s, int i) =>
    _labels(s).firstWhere((l) => l.text.startsWith('TX-$i')).x - 22;

void main() {
  for (final (name, pr) in [
    ('dualTransformer', _proj(dual: true)),
    ('transformerUnits 2', _proj(units: 2)),
  ]) {
    group(name, () {
      final sys = computeSystem(_p, pr);

      test('vertical spine: a transformer + LV section per section, N.O.',
          () {
        final spine = buildElectricalSourceSpine(project: pr, result: sys);
        final t = _texts(spine).toList();
        expect(t.where((x) => x.startsWith('TX-1 ')), hasLength(1));
        expect(t.where((x) => x.startsWith('TX-2 ')), hasLength(1));
        expect(t, containsAll(['LV SECTION 1', 'LV SECTION 2', 'N.O.']));
        // Never one paralleled-bank glyph on one LV main.
        expect(t.any((x) => x.startsWith('TRANSFORMER')), isFalse);
        expect(t, isNot(contains('PANEL UTAMA TEGANGAN RENDAH')));
        expect(spine.legend.map((e) => e.code), contains('N.O.'));
        // Two separate transformer columns.
        expect(_txColumn(spine, 1), lessThan(_txColumn(spine, 2)));
      });

      test('horizontal canvas spine: section rows + N.O. + fed boards', () {
        final spine = buildElectricalSourceSpine(
            project: pr, result: sys, horizontal: true);
        final t = _texts(spine).toList();
        expect(t, containsAll(['LVMDP-1', 'LVMDP-2', 'N.O.']));
        expect(t.where((x) => x.startsWith('TRAFO-')), hasLength(2));
        expect(t, isNot(contains('LVMDP')));
        expect(t.where((x) => x.startsWith('feeds ')), hasLength(2));
      });

      test('each root board hangs under its own section', () {
        final sections = serviceSectionOfRoot(pr, sys);
        expect(sections.values.toSet(), {0, 1});
        final overview = buildElectricalOverview(
            project: pr, result: sys, sourceChain: true);
        final cols = [_txColumn(overview, 1), _txColumn(overview, 2)];
        final lvTop = _labels(overview)
            .firstWhere((l) => l.text.startsWith('TX-1'))
            .y;
        // A vertical supply drop leaves the bottom of EACH section column.
        for (final x in cols) {
          final drops = overview.prims.whereType<SldLine>().where((l) =>
              l.role == SldRole.source &&
              (l.x1 - x).abs() < 1e-6 &&
              (l.x2 - x).abs() < 1e-6 &&
              math.min(l.y1, l.y2) > lvTop + 40);
          expect(drops, isNotEmpty, reason: 'column $x');
        }
        expect(overview.legend.map((e) => e.code), contains('N.O.'));
        final riser =
            buildElectricalRiser(project: pr, result: sys, sourceChain: true);
        expect(_texts(riser), containsAll(['LV SECTION 1', 'LV SECTION 2']));
      });

      test('power one-line: one bus per section, coupler N.O. edge', () {
        final ol = computeAdvancedStudy(_p, pr, sys).powerOneLine!;
        final ids = ol.nodes.map((n) => n.id).toSet();
        expect(ids, containsAll(['bus', 'bus-s2']));
        expect(ol.nodes.firstWhere((n) => n.id == 'bus').label,
            'LV section 1');
        expect(
            ol.edges.where((e) =>
                e.from == 'bus' &&
                e.to == 'bus-s2' &&
                e.label == 'coupler N.O.'),
            hasLength(1));
        expect(ol.edges.where((e) => e.to == 'bus-s2' && e.label == 'TX-2'),
            hasLength(1));
        expect(ol.interlocks.map((i) => i.id), contains('il-coupler-2'));
        final sheet = buildPowerOneLineSheet(ol);
        // Drawn as an OPEN tie between the two section boards on one row
        // (never as a feeder), keyed in the legend.
        expect(_texts(sheet), containsAll(['N.O.', 'TX-2']));
        expect(sheet.legend.map((e) => e.code), contains('N.O.'));
        final rects = sheet.prims.whereType<SldRect>().toList();
        final s1 = _labels(sheet).firstWhere((l) => l.text == 'LV section 1');
        final s2 = _labels(sheet).firstWhere((l) => l.text == 'LV section 2');
        expect(s1.y, closeTo(s2.y, 1e-6), reason: 'sections share one row');
        expect(rects, isNotEmpty);
      });
    });
  }

  test('3 sections, 4 boards: drawn on the optimum partition', () {
    final pr = _proj(units: 3, rootKw: [300, 200, 160, 120]);
    final sys = computeSystem(_p, pr);
    final sec = serviceSectionOfRoot(pr, sys);
    expect(sec.keys.toSet(), {'R0', 'R1', 'R2', 'R3'});
    final load = <int, double>{};
    final loads = <double>[];
    for (final id in ['R0', 'R1', 'R2', 'R3']) {
      final va = sys.panels[id]!.demandVaOrEstimate();
      loads.add(va);
      load[sec[id]!] = (load[sec[id]!] ?? 0) + va;
    }
    expect(load.values.reduce(math.max),
        closeTo(minimalMaxSectionLoad(loads, 3), 1e-6));
    final spine = buildElectricalSourceSpine(project: pr, result: sys);
    expect(_texts(spine).where((t) => t == 'N.O.'), hasLength(2));
    expect(_texts(spine), contains('LV SECTION 3'));
  });

  test('sectionAssignment realises minimalMaxSectionLoad (seeded)', () {
    final rnd = math.Random(65);
    for (var trial = 0; trial < 400; trial++) {
      final n = 1 + rnd.nextInt(16);
      final k = 1 + rnd.nextInt(4);
      final loads = [
        for (var i = 0; i < n; i++)
          rnd.nextInt(5) == 0 ? 0.0 : 1 + rnd.nextInt(500).toDouble(),
      ];
      final bins = sectionAssignment(loads, k);
      expect(bins, hasLength(n));
      final sum = List<double>.filled(k, 0);
      for (var i = 0; i < n; i++) {
        expect(bins[i], inInclusiveRange(0, k - 1));
        sum[bins[i]] += loads[i];
      }
      expect(sum.reduce(math.max),
          closeTo(minimalMaxSectionLoad(loads, k), 1e-9),
          reason: 'trial $trial loads $loads k $k');
    }
  });

  test('one section: no section geometry anywhere', () {
    final pr = _proj();
    final sys = computeSystem(_p, pr);
    expect(serviceSectionOfRoot(pr, sys), isEmpty);
    for (final horizontal in [false, true]) {
      final spine = buildElectricalSourceSpine(
          project: pr, result: sys, horizontal: horizontal);
      expect(_texts(spine), isNot(contains('N.O.')));
      expect(spine.legend.map((e) => e.code), isNot(contains('N.O.')));
    }
    final ol = computeAdvancedStudy(_p, pr, sys).powerOneLine!;
    final bus = ol.nodes.firstWhere((n) => n.id == 'bus');
    expect(bus.label, 'Main LV bus');
    expect(bus.sub, '400 V');
    expect(ol.nodes.any((n) => n.id.startsWith('bus-s')), isFalse);
  });
}
