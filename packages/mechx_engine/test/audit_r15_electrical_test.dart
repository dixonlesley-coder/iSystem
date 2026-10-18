/// ROUND 15 (2026-10-18) — electrical sizing + drawing findings, each pinned
/// by a hand-derived case and (where the rule is a property) a seeded one:
///
///   1. The genset's ESSENTIAL demand is each backed board's OWN VA, not the
///      building-average VA/W (a low-pf essential bus was under-backed).
///   2. A capacitor bank's current carries no cos φ divisor (I = Q/(√3·U)).
///   3. A busbar SECTION carries a bank's switching current (and a feeder to
///      a capacitor board at least that board's switching current).
///   4. Unpinned single-phase banks spread one per line.
///   5. The BOM orders each breaker at the kA the schedule prints.
///   6. A sub-board's unusable future-load headroom is flagged (judge-only).
///   7. The overview node kVA equals the supply note (one per-board VA).
///   8. An unplaced service-entrance root sits on the GROUND floor band.
///   9. A long source-spine board name never runs into its box border.
library;

import 'dart:math' as math;

import 'package:mechx_engine/electrical/advanced_study.dart';
import 'package:mechx_engine/electrical/bom.dart';
import 'package:mechx_engine/electrical/catalog.dart';
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/earthing.dart';
import 'package:mechx_engine/electrical/genset_backup.dart';
import 'package:mechx_engine/electrical/headroom.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/panel_results.dart'
    show ElectricalPanelResult, WarningSeverity;
import 'package:mechx_engine/electrical/sources.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/report/drawing_chrome.dart';
import 'package:mechx_engine/report/electrical_sld_drawing.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

const p = PuilProfile();

ElectricalPanel _p3(String id, List<ElectricalCircuit> circuits,
        {String? fedBy, bool essential = false, HeadroomSpec? headroom}) =>
    ElectricalPanel(
      id: id,
      name: id,
      system: ElectricalSystem.threePhase,
      voltage: const Voltage(400),
      sourceType: fedBy == null ? PanelSource.utility : PanelSource.feeder,
      fedByCircuitId: fedBy,
      essential: essential,
      headroom: headroom,
      circuits: circuits,
    );

ElectricalCircuit _load(String id, double w, double pf,
        {LoadKind kind = LoadKind.general, int? phases = 3}) =>
    ElectricalCircuit(
      id: id,
      name: id,
      loadKind: kind,
      loadW: w,
      cosPhi: pf,
      phases: phases,
      length: const Length(10),
    );

ElectricalCircuit _feeder(String id, String to, {bool breakBefore = false}) =>
    ElectricalCircuit(
      id: id,
      name: 'Feeder $to',
      loadKind: LoadKind.feeder,
      length: const Length(10),
      feedsPanelId: to,
      busbarBreakBefore: breakBefore,
    );

ElectricalCircuit _bank(String id, double kvar,
        {int? phases, double cosPhi = 1.0, bool breakBefore = false}) =>
    ElectricalCircuit(
      id: id,
      name: 'Bank $id',
      loadKind: LoadKind.capacitor,
      loadW: kvar,
      cosPhi: cosPhi,
      phases: phases,
      length: const Length(5),
      busbarBreakBefore: breakBefore,
    );

void main() {
  group('1 — essential genset demand at the essential boards\' own VA', () {
    // MDP: 4 × 50 kW at cos φ 0.95 + a feeder to EMG (essential): 2 × 30 kW
    // at cos φ 0.72. Supply W = 260 kW, VA = 200/0.95 + 60/0.72
    // = 210.53 + 83.33 = 293.86 kVA ⇒ the old building ratio 1.130 printed
    // the essential bus at 60 × 1.130 = 67.8 kVA; its real VA is
    // 60 / 0.72 = 83.33 kVA.
    final project = ElectricalProject(
      id: 'g',
      name: 'G',
      earthingSystem: EarthingSystem.tnCs,
      sources: const ElectricalSources(
          generator: GeneratorSource(backupFraction: 0.1)),
      panels: [
        _p3('MDP', [
          for (var i = 0; i < 4; i++) _load('m$i', 50000, 0.95),
          _feeder('f-emg', 'EMG'),
        ]),
        _p3('EMG', [_load('c0', 30000, 0.72), _load('c1', 30000, 0.72)],
            fedBy: 'f-emg', essential: true),
      ],
    );

    test('essentialDemandVa = 60 kW / 0.72 = 83.3 kVA (was 67.8)', () {
      final sys = computeSystem(p, project);
      expect(sys.supply.demandW, closeTo(260000, 1));
      expect(sys.supply.demandVa.voltAmperes,
          closeTo(200000 / 0.95 + 60000 / 0.72, 2));
      final ess = essentialDemandVa(project, sys);
      expect(ess, closeTo(60000 / 0.72, 1));
      expect(sys.panels['EMG']!.demandVa, closeTo(60000 / 0.72, 1));
      // The genset backs max(0.1 × 293.9, 83.3) = 83.3 kVA.
      expect(gensetBackupDemandVa(project, sys).voltAmperes,
          closeTo(60000 / 0.72, 1));
    });
  });

  group('2 — a capacitor bank current is Q / (√3·U), whatever its cos φ', () {
    test('50 kvar 3φ: Ib = 50 000 / (√3 × 400) = 72.2 A at any stored cos φ',
        () {
      final expected = 50000 / (math.sqrt(3) * 400);
      expect(expected, closeTo(72.17, 0.01));
      for (final pf in [0.5, 0.72, 0.85, 1.0]) {
        final sys = computeSystem(
            p,
            ElectricalProject(
                id: 'c',
                name: 'C',
                earthingSystem: EarthingSystem.tnCs,
                panels: [
                  _p3('MDP', [_bank('b', 50000, phases: 3, cosPhi: pf)]),
                ]));
        final way = sys.panels['MDP']!.circuits.single;
        expect(way.designCurrent.amperes, closeTo(expected, 0.05),
            reason: 'cos φ $pf');
        // The incomer floor = 1.43 × 72.2 = 103.2 A, never × 1/0.85.
        expect(sys.panels['MDP']!.capacitorCurrentA,
            closeTo(expected * kCapacitorSwitchingFactor, 0.1),
            reason: 'cos φ $pf');
      }
    });
  });

  group('3 — busbar sections carry the capacitor switching current', () {
    test('a bank section and a feeder-to-CAP section are rated ≥ 206.4 A',
        () {
      // 100 kvar / (√3 × 400) = 144.3 A × 1.43 = 206.4 A switching current.
      final switching =
          100000 / (math.sqrt(3) * 400) * kCapacitorSwitchingFactor;
      expect(switching, closeTo(206.4, 0.1));
      final sys = computeSystem(
          p,
          ElectricalProject(
              id: 's',
              name: 'S',
              earthingSystem: EarthingSystem.tnCs,
              panels: [
                _p3('MDP', [
                  for (var i = 0; i < 4; i++) _load('l$i', 40000, 0.9),
                  _bank('b', 100000, phases: 3, breakBefore: true),
                  _feeder('f-cap', 'CAP', breakBefore: true),
                ]),
                _p3('CAP', [_bank('cb', 100000, phases: 3)], fedBy: 'f-cap'),
              ]));
      final sections = sys.panels['MDP']!.busbarSections;
      expect(sections.length, 3);
      for (final s in sections.skip(1)) {
        // (Ib is rounded to 0.1 A before the 1.43 multiple ⇒ 0.15 A slack.)
        expect(s.sectionCurrent.amperes, greaterThanOrEqualTo(switching - 0.15),
            reason: 'section ${s.index} ${s.circuitIds}');
        expect(s.busbar.ampacityA.amperes,
            greaterThanOrEqualTo(switching - 0.15),
            reason: 'section ${s.index}');
      }
    });
  });

  group('4 — unpinned single-phase banks spread one per line', () {
    test('three 1φ 10 kvar banks: L1/L2/L3, 61.9 A each, a 63 A incomer '
        '(any order, seeded)', () {
      // 10 000 / 231 × 1.43 = 61.9 A per line (U0 = 400/√3 rounded = 231 V).
      const perLine = 10000 / 231 * kCapacitorSwitchingFactor;
      expect(perLine, closeTo(61.9, 0.05));
      for (var seed = 0; seed < 12; seed++) {
        final ids = ['ba', 'bb', 'bc']..shuffle(math.Random(seed));
        final sys = computeSystem(
            p,
            ElectricalProject(
                id: 'b',
                name: 'B',
                earthingSystem: EarthingSystem.tnCs,
                panels: [
                  _p3('MDP', [for (final id in ids) _bank(id, 10000, phases: 1)]),
                ]));
        final pr = sys.panels['MDP']!;
        final lines = {for (final c in pr.circuits) c.phase};
        expect(lines.length, 3, reason: 'seed $seed: ${pr.circuits.map((c) => c.phase)}');
        expect(pr.capacitorCurrentA, closeTo(perLine, 0.1), reason: 'seed $seed');
        expect(pr.incomer.breaker.ratingA.amperes, 63, reason: 'seed $seed');
      }
    });
  });

  group('5 — the BOM orders each breaker at the kA the schedule prints', () {
    test('a 16 kA root: no MCCB below its specified (Ics-covered) kA', () {
      final project = ElectricalProject(
        id: 'k',
        name: 'K',
        earthingSystem: EarthingSystem.tnCs,
        originFaultLevelA: const Current(16000),
        panels: [
          _p3('MDP', [
            _load('a80', 45000, 0.9),
            _load('a100', 55000, 0.9),
            _load('a125', 70000, 0.9),
          ]),
        ],
      );
      final sys = computeSystem(p, project,
          originFaultLevel: const Current(16000));
      final adv = computeAdvancedStudy(p, project, sys,
          originFaultLevel: const Current(16000));
      final parts = fullCatalog();
      final bySku = {for (final x in parts) x.sku: x};
      final ka = faultSpecifiedKa(adv.fault);
      final bom = buildBom(sys,
          parts: parts,
          requiredIcuKaByPanelId: ka.bus,
          incomerKaByPanelId: ka.incomers,
          breakerKaByCircuitId: ka.breakers);
      final pr = sys.panels['MDP']!;
      for (final c in pr.circuits) {
        final specified = adv.fault.circuits[c.circuitId]!.breakerKa;
        // An MCCB at 16 kA needs Icu with 0.75·Icu ≥ 16 ⇒ Icu ≥ 21.3 ⇒ 25 kA.
        if (c.breaker.deviceClass == BreakerClass.mccb) {
          expect(specified, greaterThanOrEqualTo(16 / 0.75 - 1e-9));
        }
        final sku = matchBreakerSku(c.breaker, parts,
            poles: 3, minBreakingKa: specified);
        final part = bySku[sku];
        if (part?.breakingKa != null) {
          expect(part!.breakingKa!, greaterThanOrEqualTo(specified - 1e-9),
              reason: '${c.name} ${part.sku}');
        }
      }
      // And every breaker line the BOM actually orders clears its device kA
      // (a short line is flagged, never silently under-rated).
      for (final l in bom.lines.where((l) => l.category == PartCategory.breaker)) {
        final part = bySku[l.sku];
        if (part?.breakingKa == null || l.breakingCapacityShort) continue;
        expect(part!.breakingKa!, greaterThanOrEqualTo(16 / 0.75 - 1e-9),
            reason: l.description);
      }
    });
  });

  group('6 — unusable sub-board headroom is flagged', () {
    test('a 100 % headroom board behind a load-sized 63 A feeder', () {
      // SDP: one 30 kW 3φ heater (cos φ 1) ⇒ 30 000/(√3 × 400) = 43.3 A.
      // Future at +100 % = 86.6 A; the feeder sizes on today's 43.3 A.
      final sys = computeSystem(
          p,
          ElectricalProject(
              id: 'h',
              name: 'H',
              earthingSystem: EarthingSystem.tnCs,
              panels: [
                _p3('MDP', [_feeder('f-sdp', 'SDP')]),
                _p3('SDP',
                    [_load('heat', 30000, 1.0, kind: LoadKind.heating)],
                    fedBy: 'f-sdp',
                    headroom: const HeadroomSpec(sparePercentage: 100)),
              ]));
      final sdp = sys.panels['SDP']!;
      expect(sdp.demandCurrent.amperes, closeTo(30000 / (math.sqrt(3) * 400), 0.1));
      final feeder =
          sys.panels['MDP']!.circuits.firstWhere((c) => c.circuitId == 'f-sdp');
      final future = sdp.demandCurrent.amperes * 2;
      expect(feeder.breaker.ratingA.amperes, lessThan(future));
      final w = sys.warnings
          .where((w) => w.code == 'feeder-below-fed-headroom')
          .toList();
      expect(w, hasLength(1));
      expect(w.single.circuitId, 'f-sdp');
      expect(w.single.severity, WarningSeverity.warning);
      // Without headroom: nothing to flag (byte-identical warning set).
      final plain = computeSystem(
          p,
          ElectricalProject(
              id: 'h',
              name: 'H',
              earthingSystem: EarthingSystem.tnCs,
              panels: [
                _p3('MDP', [_feeder('f-sdp', 'SDP')]),
                _p3('SDP', [_load('heat', 30000, 1.0, kind: LoadKind.heating)],
                    fedBy: 'f-sdp'),
              ]));
      expect(plain.warnings.where((w) => w.code == 'feeder-below-fed-headroom'),
          isEmpty);
    });
  });

  // A sample-like single-root project: MDP → LP-1 at two power factors.
  ElectricalProject twoBoard() => ElectricalProject(
        id: 'o',
        name: 'O',
        earthingSystem: EarthingSystem.tnCs,
        panels: [
          _p3('MDP', [_load('m', 20000, 0.95), _feeder('f-lp', 'LP-1')]),
          _p3('LP-1', [_load('l', 18000, 0.72)], fedBy: 'f-lp'),
        ],
      );

  group('7 — the overview prints ONE kVA for one demand', () {
    test('node kVA == supply note kVA on a single-root sheet', () {
      final project = twoBoard();
      final sys = computeSystem(p, project);
      final root = sys.panels['MDP']!;
      // Per-board VA = 20/0.95 + 18/0.72 = 21.05 + 25.00 = 46.05 kVA — not
      // 38 kW / 0.85 = 44.7 kVA.
      expect(root.demandVa, closeTo(20000 / 0.95 + 18000 / 0.72, 2));
      expect(root.demandVa, closeTo(sys.supply.demandVa.voltAmperes, 1));
      final sheet = buildElectricalOverview(project: project, result: sys);
      final texts = sheet.prims.whereType<SldLabel>().map((l) => l.text);
      final mdpLine = texts.firstWhere(
          (t) => t.contains('kW / ') && t.startsWith('${_amps(root)}A'));
      final kva = RegExp(r'/ ([\d.]+)kVA').firstMatch(mdpLine)!.group(1)!;
      expect(double.parse(kva),
          closeTo(sys.supply.demandVa.voltAmperes / 1000, 0.051));
    });
  });

  group('8 — an unplaced service-entrance root sits on the GROUND band', () {
    for (final ground in [0, 1]) {
      test('groundIndex $ground: MDP on the entrance floor, LP-1 one up', () {
        final project = twoBoard();
        final sys = computeSystem(p, project);
        final building = BuildingLevels([
          if (ground == 1) const Floor('Basement', Length(3)),
          const Floor('Ground', Length(3.5)),
          const Floor('Level 1', Length(3.5)),
          const Floor('Level 2', Length(3.5)),
        ], groundIndex: ground);
        final sheet = buildElectricalRiser(
            project: project, result: sys, building: building);
        final labels = sheet.prims.whereType<SldLabel>().toList();
        double yOf(bool Function(String) f) =>
            labels.firstWhere((l) => f(l.text)).y;
        final groundY = yOf((t) => t.startsWith('Ground'));
        final level1Y = yOf((t) => t.startsWith('Level 1'));
        final level2Y = yOf((t) => t.startsWith('Level 2'));
        final mdpY = yOf((t) => t == 'MDP' || t.startsWith('MDP '));
        final lpY = yOf((t) => t == 'LP-1' || t.startsWith('LP-1 '));
        // y-down: the root is BELOW its child, in the Ground band (nearer the
        // Ground caption than the Level-1 caption), never up at Level 2.
        expect(mdpY, greaterThan(lpY));
        expect((mdpY - groundY).abs(), lessThan((mdpY - level1Y).abs()));
        expect((lpY - level1Y).abs(), lessThan((lpY - level2Y).abs()));
      });
    }
  });

  group('9 — source-spine board names clear their box border', () {
    test('every spine label fits its box at the floored plot size', () {
      final project = ElectricalProject(
        id: 'mv',
        name: 'MV',
        earthingSystem: EarthingSystem.tnCs,
        dualTransformer: true,
        panels: twoBoard().panels,
      );
      final sys = computeSystem(p, project);
      final prims = buildElectricalSourceSpine(project: project, result: sys)
          .prims;
      final rects = prims.whereType<SldRect>().toList();
      for (final l in prims.whereType<SldLabel>()) {
        final box = rects.where((r) =>
            l.x >= r.x - 1e-9 &&
            l.x <= r.x + r.w &&
            l.y >= r.y &&
            l.y <= r.y + r.h);
        if (box.isEmpty) continue;
        final r = box.first;
        // The plot fit can grow an 8-unit label to ~8.54; bold ≈ 1.1 × AFM.
        final right = l.x + helveticaTextWidth(l.text, 8.54) * 1.1;
        expect(right, lessThanOrEqualTo(r.x + r.w - 2),
            reason: '"${l.text}" ends at $right, box right ${r.x + r.w}');
        expect(l.x - r.x, greaterThanOrEqualTo(2), reason: l.text);
      }
    });
  });
}

String _amps(ElectricalPanelResult pr) {
  final a = pr.incomer.breaker.ratingA.amperes;
  return a == a.roundToDouble() ? '${a.toInt()}' : '$a';
}
