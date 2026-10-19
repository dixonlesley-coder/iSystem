// Round 20 (2026-10-18) — the engine half of the round-20 audit:
//
//   demand-phase        a demand factor never moves a final way across the
//                       Auto 3φ threshold (one machine does not diversify
//                       against itself); a zero-demand pump is not 'cap'
//   riser-leader        a riser tag's leader never runs along a pipe
//   lighting-limit      the lighting flag picks the 3 % Vd limit (sizing)
//   ads-rounding        the printed Zs / limit pair always backs the verdict
//   report-text         no `_WARN_:` markdown and no dev history in reports
//   schedule-legend     the board legend keys only what the sheet prints;
//                       schedule currents carry one fixed 0.1 A precision
import 'dart:convert';
import 'dart:math' as math;

import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/fault.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/panel_results.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/electrical_sld_drawing.dart';
import 'package:mechx_engine/report/mechanical_sld_drawing.dart';
import 'package:mechx_engine/report/plan_symbols.dart' show equipmentNodeTags;
import 'package:mechx_engine/report/report_blocks.dart';
import 'package:mechx_engine/report/report_pdf.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/standards/sni.dart';
import 'package:mechx_engine/standards/ventilation.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

import '../tool/generate_export_samples.dart'
    show buildNetwork, sizeNetwork, calibrations, building;

const _p = PuilProfile();

ElectricalPanel _board(List<ElectricalCircuit> circuits) => ElectricalPanel(
      id: 'B',
      name: 'Board',
      system: ElectricalSystem.threePhase,
      voltage: const Voltage(400),
      circuits: circuits,
    );

ElectricalCircuitResult _solve(ElectricalCircuit c) =>
    computePanel(_p, _board([c])).circuits.single;

void main() {
  // ── demand-phase ──────────────────────────────────────────────────────────
  group('demand factor never flips a final way to single phase', () {
    test('5 kW pump: 3φ at df 1.0 AND at df 0.5', () {
      const base = ElectricalCircuit(
          id: 'p',
          name: 'Pump',
          loadKind: LoadKind.pump,
          loadW: 5000,
          cosPhi: 0.85,
          length: Length(20));
      final full = _solve(base);
      final half = _solve(base.copyWith(demandFactor: 0.5));
      expect(full.threePhase, isTrue);
      expect(half.threePhase, isTrue);
      // Undiversified 3φ run current = 5000 / (√3·400·0.85) = 8.49 A — the
      // device sizes on it at either factor; the diversified DESIGN current
      // halves (4.25 A), it never RISES to the 1φ 12.7 A.
      final ib = 5000 / (math.sqrt(3) * 400 * 0.85);
      expect(half.runCurrentA.amperes, closeTo(ib, 0.05));
      expect(half.designCurrent.amperes, closeTo(ib * 0.5, 0.05));
      expect(half.breaker.ratingA, full.breaker.ratingA);
      expect(half.cable.csaMm2, full.cable.csaMm2);
    });

    test('seeded property: the phase decision is df-independent', () {
      final rnd = math.Random(20);
      const kinds = [
        LoadKind.general,
        LoadKind.pump,
        LoadKind.motor,
        LoadKind.socket,
        LoadKind.hvac,
      ];
      for (var i = 0; i < 300; i++) {
        final c = ElectricalCircuit(
          id: 'c',
          name: 'C',
          loadKind: kinds[rnd.nextInt(kinds.length)],
          loadW: 500 + rnd.nextDouble() * 15000,
          cosPhi: 0.8 + rnd.nextDouble() * 0.2,
          length: const Length(15),
        );
        final df = rnd.nextDouble();
        expect(_solve(c.copyWith(demandFactor: df)).threePhase,
            _solve(c).threePhase,
            reason: '${c.loadKind} ${c.loadW} W at df $df');
      }
    });

    test('a standby pump at df 0 is not printed as a capacitor', () {
      const pr = ElectricalProject(id: 'p', name: 'P', panels: [
        ElectricalPanel(
          id: 'B',
          name: 'Board',
          voltage: Voltage(400),
          circuits: [
            ElectricalCircuit(
                id: 'sp',
                name: 'Standby pump',
                loadKind: LoadKind.pump,
                loadW: 5000,
                cosPhi: 0.85,
                demandFactor: 0,
                length: Length(20)),
          ],
        ),
      ]);
      final sys = computeSystem(_p, pr);
      final labels = [
        for (final l in buildElectricalPanelDetail(
                project: pr, result: sys, panelId: 'B')
            .prims
            .whereType<SldLabel>())
          l.text,
      ];
      expect(labels.where((t) => t.endsWith(' cap')), isEmpty,
          reason: labels.join(' | '));
    });
  });

  // ── riser-leader ──────────────────────────────────────────────────────────
  test('riser: no tag leader runs collinear along a pipe (harness M-201)', () {
    // The export harness network exactly as the dev tool issues it: the
    // floor-1 AHU -> header -> 3 supply diffusers used to carry a leader
    // from the third diffuser BACK along the duct (942 -> 812 at y -209.8),
    // through two diffuser glyphs and the AHU, to a tag parked left of the
    // plant.
    final net = buildNetwork();
    final sizing = sizeNetwork(net);
    final sheet = buildMechanicalRiserSld(
      network: net,
      sizing: sizing,
      building: building,
      edgeLengths: {
        for (final e in net.edges)
          e.id: edgeLength(e, net,
              calibrationBySheet: calibrations, building: building),
      },
      nodeTags: equipmentNodeTags(net),
      supplyNote: 'Air bersih: tangki bawah -> pompa booster -> riser upfeed',
      notes: const ['Sistem upfeed booster'],
      detailCallouts: true,
      hotWaterRecirc: net.edges.any((e) => e.service == ServiceType.hotWater),
    );
    final lines = sheet.prims.whereType<SldLine>().toList();
    final pipes = lines.where((l) => l.weight != SldWeight.thin).toList();
    // A LEADER ends on its label's box (the nearest point of it).
    final labels = sheet.prims.whereType<SldLabel>().toList();
    bool endsOnLabel(SldLine l) => labels.any((t) {
          final w = mechRiserLabelWidth(t.text, t.size);
          return l.x2 >= t.x - 0.01 &&
              l.x2 <= t.x + w + 0.01 &&
              l.y2 >= t.y - t.size - 0.01 &&
              l.y2 <= t.y + 0.35 * t.size + 0.01;
        });
    final thin =
        lines.where((l) => l.weight == SldWeight.thin && endsOnLabel(l));
    expect(thin, isNotEmpty);
    // Collinear overlap of an axis-aligned thin line with a pipe line.
    double overlap(SldLine a, SldLine b) {
      if ((a.y1 - a.y2).abs() < 1e-6 &&
          (b.y1 - b.y2).abs() < 1e-6 &&
          (a.y1 - b.y1).abs() < 0.5) {
        final lo = math.max(math.min(a.x1, a.x2), math.min(b.x1, b.x2));
        final hi = math.min(math.max(a.x1, a.x2), math.max(b.x1, b.x2));
        return math.max(0.0, hi - lo);
      }
      if ((a.x1 - a.x2).abs() < 1e-6 &&
          (b.x1 - b.x2).abs() < 1e-6 &&
          (a.x1 - b.x1).abs() < 0.5) {
        final lo = math.max(math.min(a.y1, a.y2), math.min(b.y1, b.y2));
        final hi = math.min(math.max(a.y1, a.y2), math.max(b.y1, b.y2));
        return math.max(0.0, hi - lo);
      }
      return 0;
    }

    for (final l in thin) {
      for (final p in pipes) {
        // A text height (8) of shared ink is the most a leader may skim
        // while leaving its own glyph; a run along the pipe is a stub.
        expect(overlap(l, p), lessThanOrEqualTo(8),
            reason: 'leader (${l.x1},${l.y1})-(${l.x2},${l.y2}) along pipe '
                '(${p.x1},${p.y1})-(${p.x2},${p.y2})');
      }
    }
  });

  // ── lighting-limit ────────────────────────────────────────────────────────
  test('lighting flag: 2000 W / 70 m on 1φ 230 V sizes to the 3 % limit', () {
    // Ib = 2000 / (230 × 0.9) = 9.66 A. Vd% = 2·L·Ib·R / 230:
    //   2.5 mm² (R ≈ 8.0 Ω/km): 2·70·9.66·0.0080 / 230 ≈ 4.7 %  (≤ 5 %, > 3 %)
    //   4.0 mm² (R ≈ 5.0 Ω/km): ≈ 2.9 %                          (≤ 3 %)
    // so the lighting way steps one size up; the same way flagged non-lighting
    // stays at 2.5 mm² against the general 5 %.
    ElectricalCircuitResult way(bool lighting) => computePanel(
          _p,
          ElectricalPanel(
            id: 'L',
            name: 'LP',
            system: ElectricalSystem.singlePhase,
            voltage: const Voltage(230),
            circuits: [
              ElectricalCircuit(
                  id: 'w',
                  name: 'Lighting',
                  loadKind: LoadKind.lighting,
                  isLighting: lighting,
                  loadW: 2000,
                  cosPhi: 0.9,
                  length: const Length(70)),
            ],
          ),
        ).circuits.single;
    final general = way(false), lighting = way(true);
    expect(general.cable.csaMm2, 2.5);
    expect(general.voltageDrop.dropPercent, inInclusiveRange(3.0, 5.0));
    expect(lighting.cable.csaMm2, 4.0);
    expect(lighting.voltageDrop.dropPercent, lessThanOrEqualTo(3.0));
  });

  // ── ads-rounding ──────────────────────────────────────────────────────────
  test('seeded property: printed Zs vs limit always agrees with adsOk', () {
    final rnd = math.Random(37);
    var fails = 0;
    for (var i = 0; i < 600; i++) {
      final circuits = [
        for (var k = 0; k < 1 + rnd.nextInt(4); k++)
          ElectricalCircuit(
            id: 'c$k',
            name: 'C$k',
            loadKind: [
              LoadKind.general,
              LoadKind.socket,
              LoadKind.motor,
              LoadKind.lighting,
            ][rnd.nextInt(4)],
            loadW: 300 + rnd.nextDouble() * 12000,
            cosPhi: 0.8 + rnd.nextDouble() * 0.2,
            length: Length(5 + rnd.nextDouble() * 150),
          ),
      ];
      final pr = ElectricalProject(id: 'p', name: 'P', panels: [
        ElectricalPanel(
            id: 'P1',
            name: 'P1',
            voltage: const Voltage(400),
            circuits: circuits),
      ]);
      final f = faultStudy(computeSystem(_p, pr), pr, _p);
      for (final r in f.circuits.values) {
        final zs = r.zsOhm, max = r.zsMaxOhm;
        if (zs == null || max == null || !max.isFinite) continue;
        if (r.adsOk == false) {
          fails++;
          expect(zs, greaterThan(max), reason: 'FAIL printed $zs vs $max');
        } else if (r.adsOk == true) {
          expect(zs, lessThanOrEqualTo(max), reason: 'PASS printed $zs vs $max');
        }
      }
    }
    expect(fails, greaterThan(0), reason: 'the sweep must exercise failures');
  });

  // ── report-text ───────────────────────────────────────────────────────────
  test('a leading _WARN_: / _INFO_: emphasis never reaches the PDF', () {
    final pdf = latin1.decode(reportBlocksToPdf(const [
      RptKeyValue([
        ('', '_WARN_: [vd] Lighting - Level 1: drop 5.2 %'),
        ('', '_INFO_: [fire-pump-protection] note'),
      ]),
    ], docTitle: 'T', projectName: 'P'));
    expect(pdf, isNot(contains('_WARN_')));
    expect(pdf, isNot(contains('_INFO_')));
    expect(pdf, contains('WARN: [vd]'));
    expect(pdf, contains('INFO: [fire-pump-protection]'));
  });

  test('no development history in any issued unverified-value note', () {
    final notes = [
      for (final v in [
        ...const SniProfile().verifyChecklist,
        ...const PuilProfile().verifyChecklist,
        ...const SniVentilationProfile().verifyChecklist,
      ])
        '${v.citation} ${v.note ?? ''}',
    ];
    for (final t in notes) {
      expect(t, isNot(matches(RegExp(r'\bRound \d+'))), reason: t);
      expect(t, isNot(contains('egress')), reason: t);
      expect(t, isNot(contains('session')), reason: t);
    }
  });

  // ── schedule-legend ───────────────────────────────────────────────────────
  group('board schedule: printed tokens + fixed precision', () {
    const pr = ElectricalProject(id: 'p', name: 'P', panels: [
      ElectricalPanel(
        id: 'B',
        name: 'Board',
        voltage: Voltage(400),
        circuits: [
          // 3000 W 1φ on a 400 V board: Ib = 3000 / 230.9 = 12.99 A — the
          // cell must print '13.0', never a bare '13' beside '14.8'.
          ElectricalCircuit(
              id: 'a',
              name: 'A',
              loadKind: LoadKind.general,
              loadW: 3000,
              cosPhi: 1,
              length: Length(10)),
          ElectricalCircuit(
              id: 'b',
              name: 'B',
              loadKind: LoadKind.general,
              loadW: 1700,
              cosPhi: 1,
              length: Length(10)),
        ],
      ),
    ]);
    final sys = computeSystem(_p, pr);
    final sheet =
        buildElectricalPanelDetail(project: pr, result: sys, panelId: 'B');
    final labels = [
      for (final l in sheet.prims.whereType<SldLabel>()) l.text,
    ];
    final codes = [for (final e in sheet.legend) e.code];

    test('every schedule current carries one decimal', () {
      final ids = {for (final c in sys.panels['B']!.circuits) c.circuitId};
      expect(ids, hasLength(2));
      for (final c in sys.panels['B']!.circuits) {
        final ib = c.designCurrent.amperes.toStringAsFixed(1);
        expect(labels, contains(ib));
      }
      // No bare integer in an R/S/T cell (a label that is all digits).
      expect(labels.where((t) => RegExp(r'^\d+$').hasMatch(t)), isEmpty,
          reason: labels.join(' | '));
    });

    test('legend: no Ib, no way curves, no CT on a kWh-direct board', () {
      expect(codes, isNot(contains('Ib')));
      expect(codes, isNot(contains('VD!')));
      expect(labels.any((t) => t.contains('VD!')), isFalse);
      expect(labels.any((t) => t.startsWith('CT ')), isFalse);
      expect(codes, isNot(contains('CT')));
      // Every keyed curve is the incomer's (the only printed curve letter).
      for (final c in codes.where((c) => c.startsWith('Curve '))) {
        final letter = c.substring(6);
        expect(labels.any((t) => t.contains('Incomer') && t.contains(letter)),
            isTrue,
            reason: '$c keyed but not printed');
      }
    });

    test('column heads sit 7 units above their rule like every body row', () {
      final grup = sheet.prims
          .whereType<SldLabel>()
          .firstWhere((l) => l.text == 'GRUP');
      final w1 = sheet.prims
          .whereType<SldLabel>()
          .firstWhere((l) => l.text == 'W1');
      // Head baseline busTop + 13 = 7 above its rule (busTop + 20); the W1
      // row baseline busTop + 39 = 7 above ITS rule (busTop + 46) — the same
      // clearance, so the two baselines sit 46 − 20 = 26 apart. (The old head
      // at busTop + 19 stood 1 above its rule: 20 apart.)
      expect(w1.y - grup.y, closeTo(20 + 6, 1e-9));
    });
  });
}
