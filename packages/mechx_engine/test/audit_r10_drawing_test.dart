// Round 10 (2026-10-18) — drawing-property findings (electrical + mechanical
// sheets), each turned into a permanent (seeded where it fits) property test.
import 'dart:convert' show latin1;
import 'dart:math' as math;

import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/geo_length.dart' show LayoutPos;
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/power_oneline.dart';
import 'package:mechx_engine/electrical/sources.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/report/drawing_chrome.dart'
    show helveticaTextWidth, kMinPlotLabelPt;
import 'package:mechx_engine/report/electrical_pdf_export.dart';
import 'package:mechx_engine/report/electrical_sld_drawing.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

typedef _B = ({double l, double t, double r, double b});

bool _overlap(_B a, _B b) =>
    math.min(a.r, b.r) - math.max(a.l, b.l) > 1e-6 &&
    math.min(a.b, b.b) - math.max(a.t, b.t) > 1e-6;

_B _rectBox(SldRect r) => (l: r.x, t: r.y, r: r.x + r.w, b: r.y + r.h);

_B _labelBox(SldLabel l) => (
      l: l.x,
      t: l.y - l.size * 0.72,
      r: l.x + helveticaTextWidth(l.text, l.size),
      b: l.y + l.size * 0.21,
    );

/// True when the segment passes through the rect's INTERIOR (strictly inside,
/// sampled along its length).
bool _lineThroughRect(SldLine ln, SldRect r) {
  const steps = 40;
  for (var i = 0; i <= steps; i++) {
    final t = i / steps;
    final x = ln.x1 + (ln.x2 - ln.x1) * t;
    final y = ln.y1 + (ln.y2 - ln.y1) * t;
    if (x > r.x + 0.5 && x < r.x + r.w - 0.5 && y > r.y + 0.5 &&
        y < r.y + r.h - 0.5) {
      return true;
    }
  }
  return false;
}

const _profile = PuilProfile();

ElectricalProject _mvProject(int boards,
    {bool solar = true, bool battery = true, bool genset = false}) {
  return ElectricalProject(
    id: 'r10',
    name: 'R10',
    dualTransformer: true,
    sources: ElectricalSources(
      solar: solar ? const SolarSource(panels: 10) : null,
      battery: battery ? const BatterySource(autonomyHours: 2) : null,
      generator: genset ? const GeneratorSource() : null,
    ),
    panels: [
      ElectricalPanel(
        id: 'MDP',
        name: 'MDP',
        layoutPos: const LayoutPos(sheetId: 's', floorIndex: 0, x: 0, y: 0),
        circuits: [
          for (var i = 1; i < boards; i++)
            ElectricalCircuit(
                id: 'f$i',
                name: 'Feeder SDP$i',
                loadKind: LoadKind.feeder,
                feedsPanelId: 'SDP$i',
                length: const Length(10)),
        ],
      ),
      for (var i = 1; i < boards; i++)
        ElectricalPanel(
          id: 'SDP$i',
          name: 'SDP$i',
          sourceType: PanelSource.feeder,
          layoutPos:
              LayoutPos(sheetId: 's', floorIndex: 0, x: 100.0 * i, y: 0),
          circuits: [
            ElectricalCircuit(
                id: 'l$i',
                name: 'Lighting',
                loadKind: LoadKind.lighting,
                isLighting: true,
                loadW: 1200,
                length: const Length(12)),
          ],
        ),
    ],
  );
}

/// Every SOURCE-spine primitive that intrudes into a distribution board.
List<String> _sourceInsideBoards(SldSheet sheet) {
  final boards = [
    for (final p in sheet.prims)
      if (p is SldRect && p.role != SldRole.source) p,
  ];
  final out = <String>[];
  for (final p in sheet.prims) {
    for (final b in boards) {
      if (p is SldLine && p.role == SldRole.source && _lineThroughRect(p, b)) {
        out.add('line (${p.x1},${p.y1})-(${p.x2},${p.y2}) in board @${b.x},${b.y}');
      } else if (p is SldLabel &&
          p.role == SldRole.source &&
          _overlap(_labelBox(p), _rectBox(b))) {
        out.add('label "${p.text}" in board @${b.x},${b.y}');
      }
    }
  }
  return out;
}

/// MDP (6 lighting ways + 3 feeders) + 3 x LP with 12 ways = 4 boards / 45
/// ways — the finding's probe project.
ElectricalProject _fortyFiveWays() => ElectricalProject(
      id: 'w45',
      name: 'W45',
      panels: [
        ElectricalPanel(id: 'MDP', name: 'MDP', circuits: [
          for (var i = 0; i < 6; i++)
            ElectricalCircuit(
                id: 'm$i',
                name: 'Lighting $i',
                loadKind: LoadKind.lighting,
                isLighting: true,
                loadW: 600,
                length: const Length(15)),
          for (var k = 1; k <= 3; k++)
            ElectricalCircuit(
                id: 'f$k',
                name: 'Feeder LP$k',
                loadKind: LoadKind.feeder,
                feedsPanelId: 'LP$k',
                length: const Length(20)),
        ]),
        for (var k = 1; k <= 3; k++)
          ElectricalPanel(
              id: 'LP$k',
              name: 'LP$k',
              sourceType: PanelSource.feeder,
              circuits: [
                for (var i = 0; i < 12; i++)
                  ElectricalCircuit(
                      id: 'lp$k-$i',
                      name: 'Way $i',
                      loadKind: LoadKind.lighting,
                      isLighting: true,
                      loadW: 400,
                      length: const Length(12)),
              ]),
      ],
    );

/// Every `/F1 <size> Tf` the PDF writes, in page points.
List<double> _pdfFontSizes(List<int> bytes) => [
      for (final m in RegExp(r'/F1 ([0-9.]+) Tf').allMatches(latin1.decode(bytes)))
        double.parse(m.group(1)!),
    ];

int _pdfPageCount(List<int> bytes) =>
    RegExp(r'/Type /Page\b(?!s)').allMatches(latin1.decode(bytes)).length;

void main() {
  // ── elec-drawing-props-1 ─────────────────────────────────────────────────
  group('elec-drawing-props-1 — the MV side-source stack counts toward the '
      'spine height', () {
    const oneFloor = BuildingLevels([Floor('Ground', Length(4))]);

    test('MV + solar + battery + 3 top-band boards: no source prim in a board '
        '(riser + overview)', () {
      final project = _mvProject(3);
      final result = computeSystem(_profile, project);
      final riser = buildElectricalRiser(
          project: project,
          result: result,
          building: oneFloor,
          sourceChain: true);
      expect(_sourceInsideBoards(riser), isEmpty);
      final overview = buildElectricalOverview(
          project: project, result: result, sourceChain: true);
      expect(_sourceInsideBoards(overview), isEmpty);
    });

    test('property: no MV source mask x board count overprints a board '
        '(seeded)', () {
      final rnd = math.Random(1001);
      for (var i = 0; i < 40; i++) {
        final project = _mvProject(1 + rnd.nextInt(6),
            solar: rnd.nextBool(),
            battery: rnd.nextBool(),
            genset: rnd.nextBool());
        final result = computeSystem(_profile, project);
        for (final sheet in [
          buildElectricalRiser(
              project: project,
              result: result,
              building: oneFloor,
              sourceChain: true),
          buildElectricalOverview(
              project: project, result: result, sourceChain: true),
        ]) {
          expect(_sourceInsideBoards(sheet), isEmpty, reason: 'seed $i');
        }
      }
    });
  });

  // ── elec-drawing-props-2 ─────────────────────────────────────────────────
  group('elec-drawing-props-2 — the power one-line never routes through a box '
      'and never stacks two edge labels', () {
    List<String> defects(SldSheet sheet) {
      final rects = [for (final p in sheet.prims) if (p is SldRect) p];
      final out = <String>[];
      for (final p in sheet.prims) {
        if (p is! SldLine) continue;
        for (final r in rects) {
          if (_lineThroughRect(p, r)) {
            out.add('edge (${p.x1},${p.y1})-(${p.x2},${p.y2}) through box '
                '@${r.x},${r.y}');
          }
        }
      }
      // Edge labels are the 6.5 pt ones; no two may share any area, and none
      // may sit inside a node box.
      final labels = [
        for (final p in sheet.prims)
          if (p is SldLabel && p.size == 6.5) p,
      ];
      for (var i = 0; i < labels.length; i++) {
        for (var j = i + 1; j < labels.length; j++) {
          if (_overlap(_labelBox(labels[i]), _labelBox(labels[j]))) {
            out.add('labels "${labels[i].text}" / "${labels[j].text}" overlap');
          }
        }
        for (final r in rects) {
          if (_overlap(_labelBox(labels[i]), _rectBox(r))) {
            out.add('label "${labels[i].text}" inside box @${r.x},${r.y}');
          }
        }
      }
      return out;
    }

    test('solar-only (non-hybrid): the mains edge detours, never through the '
        'PV inverter', () {
      final ol = buildPowerOneLine(
          const ElectricalSources(solar: SolarSource(panels: 40)),
          demand: const ApparentPower(120000));
      expect(defects(buildPowerOneLineSheet(ol)), isEmpty);
    });

    test('default genset: the mains and genset labels no longer coincide', () {
      final ol = buildPowerOneLine(
          const ElectricalSources(generator: GeneratorSource()),
          demand: const ApparentPower(120000));
      expect(defects(buildPowerOneLineSheet(ol)), isEmpty);
    });

    test('property: every source mask is defect-free (exhaustive)', () {
      for (var mask = 0; mask < 32; mask++) {
        final gen = mask & 1 != 0;
        final sources = ElectricalSources(
          generator: gen
              ? GeneratorSource(backupFraction: mask & 16 != 0 ? 0.5 : 1.0)
              : null,
          solar: mask & 2 != 0 ? const SolarSource(panels: 24) : null,
          battery:
              mask & 4 != 0 ? const BatterySource(autonomyHours: 2) : null,
          hybridInverter: mask & 8 != 0 ? false : null,
        );
        final ol =
            buildPowerOneLine(sources, demand: const ApparentPower(120000));
        expect(defects(buildPowerOneLineSheet(ol)), isEmpty,
            reason: 'mask $mask');
      }
    });
  });

  // ── elec-drawing-props-3 ─────────────────────────────────────────────────
  group('elec-drawing-props-3 — the issued detail SLD never prints below the '
      'minimum plotted label size', () {
    final project = _fortyFiveWays();
    final result = computeSystem(_profile, project);

    test('4 boards / 45 ways: one A3 page would print < 7 pt, so the export '
        'paginates one board per page, each >= 7 pt', () {
      final whole = buildElectricalSld(project: project, result: result);
      // Precondition (the defect): stacked onto one A3 the boxed schedule
      // cells fall well under kMinPlotLabelPt.
      expect(sldSinglePageMinLabelPt(whole), lessThan(kMinPlotLabelPt));
      final bytes =
          electricalSldDetailToPdf(project: project, result: result);
      expect(_pdfPageCount(bytes), result.order.length);
      for (final id in result.order) {
        final one = buildElectricalSld(
            project: project, result: result, onlyPanelId: id);
        expect(sldSinglePageMinLabelPt(one),
            greaterThanOrEqualTo(kMinPlotLabelPt - 1e-9),
            reason: id);
      }
    });

    test('a small project stays ONE legible sheet', () {
      const small = ElectricalProject(id: 's', name: 'S', panels: [
        ElectricalPanel(id: 'DB', name: 'DB', circuits: [
          ElectricalCircuit(
              id: 'a',
              name: 'Lighting',
              loadKind: LoadKind.lighting,
              isLighting: true,
              loadW: 600,
              length: Length(10)),
        ]),
      ]);
      final r = computeSystem(_profile, small);
      expect(_pdfPageCount(electricalSldDetailToPdf(project: small, result: r)),
          1);
    });
  });

  // ── elec-drawing-props-4 ─────────────────────────────────────────────────
  group('elec-drawing-props-4 — the PDF prints the FITTED label sizes (no '
      'renderer floor), so PDF == DXF', () {
    test('the smallest PDF text size IS the plot fit\'s smallest label', () {
      final project = _fortyFiveWays();
      final result = computeSystem(_profile, project);
      final whole = buildElectricalSld(project: project, result: result);
      final fitted = sldSinglePageMinLabelPt(whole);
      // The fit leaves boxed-in labels below 5 pt on this sheet …
      expect(fitted, lessThan(5.0));
      final sizes =
          _pdfFontSizes(electricalSldToPdf(project: project, sheet: whole));
      // … and the PDF writes exactly that size (2-dp formatting), never a
      // re-enlarged 5 pt that would overprint its neighbours.
      expect(sizes.reduce(math.min), closeTo(fitted, 0.006));
    });
  });
}
