/// ROUND 13 (2026-10-18) — electrical sizing/study rules, each pinned by a
/// hand-derived case and (where the rule is a property) a SEEDED property test.
///
///   1. A board holding capacitor ways (a dedicated PFC panel) floors its
///      incomer — and the feeder supplying it — at the bank's switching
///      current (1.43 × Q/(√3·U)).
///   2. A motor / A5-FLA way's DESIGN current carries its demand factor (the
///      same basis its watts feed upstream); its device + cable still size on
///      the undiversified FLC.
///   3. A final way's printed voltage drop is the drop at its UNDIVERSIFIED
///      current (the current that flows when the machine runs).
///   4. Several utility roots: the service (supply system / voltage, main
///      earthing + bonding) is governed by the largest root, not list order.
///   5. Every utility root is an SPD origin.
///   6. The genset backs max(fraction × demand, the essential boards' demand);
///      a forced nameplate below the essential demand is warned.
///   7. The PFC bank compensates the DIVERSIFIED demand.
library;

import 'dart:math' as math;

import 'package:mechx_engine/electrical/advanced_study.dart';
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/earthing.dart';
import 'package:mechx_engine/electrical/genset_backup.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/panel_results.dart';
import 'package:mechx_engine/electrical/power_factor.dart';
import 'package:mechx_engine/electrical/sizing.dart';
import 'package:mechx_engine/electrical/sources.dart';
import 'package:mechx_engine/electrical/spd.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

const p = PuilProfile();

ElectricalCircuitResult _way(ElectricalSystemResult r, String panel, String id) =>
    r.panels[panel]!.circuits.firstWhere((c) => c.circuitId == id);

ElectricalPanel _p3(String id, List<ElectricalCircuit> circuits,
        {String? fedBy, bool essential = false, double diversity = 1.0}) =>
    ElectricalPanel(
      id: id,
      name: id,
      system: ElectricalSystem.threePhase,
      voltage: const Voltage(400),
      essential: essential,
      diversityFactor: diversity,
      sourceType: fedBy == null ? PanelSource.utility : PanelSource.feeder,
      fedByCircuitId: fedBy,
      circuits: circuits,
    );

void main() {
  // ── 1. dedicated capacitor (PFC) panel ────────────────────────────────────
  group('1 — a dedicated PFC panel and its feeder carry the bank', () {
    ElectricalProject project(double kvar) => ElectricalProject(
          id: 'pfc',
          name: 'PFC',
          panels: [
            _p3('LVMDP', const [
              ElectricalCircuit(
                id: 'm',
                name: 'Motor 75 kW',
                loadKind: LoadKind.motor,
                motorKw: 75,
                cosPhi: 0.85,
                phases: 3,
                length: Length(30),
              ),
              ElectricalCircuit(
                id: 'f-cap',
                name: 'Feeder PANEL KAPASITOR',
                loadKind: LoadKind.feeder,
                length: Length(10),
                feedsPanelId: 'CAP',
              ),
            ]),
            _p3('CAP', [
              ElectricalCircuit(
                id: 'bank',
                name: 'Capacitor bank',
                loadKind: LoadKind.capacitor,
                loadW: kvar,
                cosPhi: 1.0,
                phases: 3,
                length: const Length(5),
              ),
            ], fedBy: 'f-cap'),
          ],
        );

    test('100 kvar 3φ: bank way, PFC incomer and feeder all ≥ 206 A', () {
      final sys = computeSystem(p, project(100000));
      // Ib = Q/(√3·U) = 100 000/(√3·400) = 144.34 A; switching current
      // 1.43 × 144.34 = 206.4 A ⇒ the first rung ≥ 206.4 is 250 A.
      final ib = 100000 / (math.sqrt(3) * 400);
      final switching = kCapacitorSwitchingFactor * ib;
      expect(switching, closeTo(206.4, 0.05));
      final bank = _way(sys, 'CAP', 'bank');
      expect(bank.breaker.ratingA.amperes, 250);
      // The PFC board's own incomer was 6 A (demand current 0).
      final cap = sys.panels['CAP']!;
      expect(cap.demandCurrent.amperes, 0); // bank adds no balance current
      expect(cap.capacitorCurrentA, closeTo(switching, 0.11));
      expect(cap.incomer.breaker.ratingA.amperes, 250);
      // The LVMDP feeder was 10 A / 4 mm² on Ib = 0.
      final feeder = _way(sys, 'LVMDP', 'f-cap');
      expect(feeder.breaker.ratingA.amperes, greaterThanOrEqualTo(250));
      expect(feeder.cable.deratedIz.amperes,
          greaterThanOrEqualTo(switching - 1e-6));
      expect(feeder.cable.csaMm2, greaterThan(4));
      // Demand W is still 0 for the PFC board (kvar is not kW).
      expect(cap.demandW, 0);
    });

    test('property: the feeder and PFC incomer always carry 1.43 × Ib', () {
      final rnd = math.Random(20261018);
      for (var trial = 0; trial < 40; trial++) {
        final kvar = 5000 + rnd.nextInt(200000).toDouble();
        final sys = computeSystem(p, project(kvar));
        final switching =
            kCapacitorSwitchingFactor * kvar / (math.sqrt(3) * 400);
        final why = 'trial $trial, $kvar var';
        final cap = sys.panels['CAP']!;
        expect(cap.incomer.breaker.ratingA.amperes,
            greaterThanOrEqualTo(switching - 0.1),
            reason: why);
        final feeder = _way(sys, 'LVMDP', 'f-cap');
        expect(feeder.breaker.ratingA.amperes,
            greaterThanOrEqualTo(switching - 0.1),
            reason: why);
        // In ≤ Iz still holds on the feeder (unless the ladder ran out).
        if (feeder.cable.ampacityReached) {
          expect(feeder.cable.deratedIz.amperes,
              greaterThanOrEqualTo(switching - 0.1),
              reason: why);
        }
      }
    });

    test('a board with no capacitor anywhere below is untouched', () {
      final sys = computeSystem(p, project(100000));
      expect(sys.panels['LVMDP']!.capacitorCurrentA,
          closeTo(sys.panels['CAP']!.capacitorCurrentA, 1e-9));
      final plain = computeSystem(
          p,
          ElectricalProject(id: 'x', name: 'x', panels: [
            _p3('B', const [
              ElectricalCircuit(
                id: 'h',
                name: 'Heater',
                loadKind: LoadKind.heating,
                loadW: 9000,
                cosPhi: 1,
                phases: 3,
                length: Length(10),
              ),
            ]),
          ]));
      expect(plain.panels['B']!.capacitorCurrentA, 0);
    });
  });

  // ── 2. motor design current carries its demand factor ─────────────────────
  group('2 — a motor way diversifies on the same basis as its watts', () {
    ElectricalProject project({required bool asMotorKw, double df = 0.5}) {
      ElectricalCircuit pump(String id) => ElectricalCircuit(
            id: id,
            name: 'Pump $id',
            loadKind: LoadKind.pump,
            motorKw: asMotorKw ? 30 : null,
            loadW: asMotorKw ? 0 : 30000 / kAssumedMotorEfficiency,
            cosPhi: 0.85,
            phases: 3,
            demandFactor: df,
            length: const Length(15),
          );
      return ElectricalProject(id: 'mcc', name: 'MCC', panels: [
        _p3('MDP', const [
          ElectricalCircuit(
            id: 'f-mcc',
            name: 'Feeder MCC',
            loadKind: LoadKind.feeder,
            length: Length(20),
            feedsPanelId: 'MCC',
          ),
        ]),
        _p3('MCC', [pump('p1'), pump('p2')], fedBy: 'f-mcc'),
      ]);
    }

    test('motorKw 30 at df 0.5 == the same machine entered as watts', () {
      final kw = computeSystem(p, project(asMotorKw: true));
      final w = computeSystem(p, project(asMotorKw: false));
      // FLC = 30 000 / 0.88 / (√3·400·0.85) = 57.88 A undiversified.
      final flc = 30000 / kAssumedMotorEfficiency / (math.sqrt(3) * 400 * 0.85);
      expect(flc, closeTo(57.88, 0.01));
      final p1 = _way(kw, 'MCC', 'p1');
      // Design current = FLC × 0.5 = 28.94 → 28.9 A (was 57.9 A).
      expect(p1.designCurrent.amperes, closeTo(roundTo(flc * 0.5, 1), 1e-9));
      // Its own device still sizes on the undiversified 57.88 A ⇒ ≥ 63 A.
      expect(p1.breaker.ratingA.amperes, greaterThanOrEqualTo(flc));
      // Board demand current 2 × 28.94 = 57.88 → 57.9 A (Round 43: the exact
      // way currents summed and rounded once, never 2 × 28.9) ⇒ incomer 63 A
      // (was 125 A), identical to the watts entry.
      final mccKw = kw.panels['MCC']!;
      final mccW = w.panels['MCC']!;
      expect(mccKw.demandCurrent.amperes, closeTo(roundTo(flc, 1), 1e-9));
      expect(mccKw.demandCurrent.amperes, mccW.demandCurrent.amperes);
      expect(mccKw.incomer.breaker.ratingA.amperes,
          mccW.incomer.breaker.ratingA.amperes);
      // The MDP incomer can no longer sit below the sub-board incomer, and the
      // engine no longer contradicts itself with feeder-below-fed-demand.
      expect(kw.panels['MDP']!.incomer.breaker.ratingA.amperes,
          greaterThanOrEqualTo(mccKw.incomer.breaker.ratingA.amperes));
      expect(kw.warnings.where((x) => x.code == 'feeder-below-fed-demand'),
          isEmpty);
    });

    test('property: motorKw and watts entries agree on every demand figure',
        () {
      final rnd = math.Random(13013);
      for (var trial = 0; trial < 30; trial++) {
        final df = 0.3 + rnd.nextDouble() * 0.7;
        final kw = computeSystem(p, project(asMotorKw: true, df: df));
        final w = computeSystem(p, project(asMotorKw: false, df: df));
        final why = 'trial $trial df $df';
        expect(kw.panels['MCC']!.demandCurrent.amperes,
            closeTo(w.panels['MCC']!.demandCurrent.amperes, 0.11),
            reason: why);
        expect(kw.panels['MDP']!.demandW, closeTo(w.panels['MDP']!.demandW, 1),
            reason: why);
      }
    });
  });

  // ── 3. final-way voltage drop at the undiversified current ────────────────
  test('3 — a df-0.5 heater prints the drop at its full running current', () {
    final sys = computeSystem(
        p,
        ElectricalProject(id: 'vd', name: 'vd', panels: [
          _p3('SDP', const [
            ElectricalCircuit(
              id: 'h',
              name: 'Heater',
              loadKind: LoadKind.heating,
              loadW: 20000,
              cosPhi: 1,
              phases: 3,
              demandFactor: 0.5,
              cableOverrideMm2: 10,
              length: Length(150),
            ),
          ]),
        ]));
    final h = _way(sys, 'SDP', 'h');
    // Running current 20 000/(√3·400) = 28.87 A; the diversified 14.4 A used
    // to halve the printed drop (2.05 % vs the real 4.11 % on 10 mm²).
    final full = 20000 / (math.sqrt(3) * 400);
    final expected = voltageDrop(
      p,
      current: Current(full / (h.cable.runsPerPhase ?? 1)),
      length: const Length(150),
      csaMm2: h.cable.csaMm2,
      cosPhi: 1,
      threePhase: true,
      voltage: const Voltage(400),
      isLighting: false,
    );
    expect(h.voltageDrop.dropPercent, expected.dropPercent);
    // Design current stays diversified (14.4 A) for the demand roll-up.
    expect(h.designCurrent.amperes, closeTo(roundTo(full * 0.5, 1), 1e-9));
  });

  // ── 4 + 5. several utility roots ──────────────────────────────────────────
  group('4/5 — several utility roots', () {
    const rootA = ElectricalPanel(
      id: 'A',
      name: 'A',
      system: ElectricalSystem.singlePhase,
      voltage: Voltage(230),
      circuits: [
        ElectricalCircuit(
          id: 'l',
          name: 'Lighting',
          loadKind: LoadKind.lighting,
          loadW: 1000,
          length: Length(10),
        ),
      ],
    );
    final rootB = _p3('B', const [
      ElectricalCircuit(
        id: 'h',
        name: 'Heater',
        loadKind: LoadKind.heating,
        loadW: 150000,
        cosPhi: 1,
        phases: 3,
        length: Length(10),
      ),
    ]);
    ElectricalProject proj(List<ElectricalPanel> panels) => ElectricalProject(
          id: 'mr',
          name: 'mr',
          earthingSystem: EarthingSystem.tnCs,
          externalLps: true,
          panels: panels,
        );

    test('the service follows the 250 A root in either list order', () {
      final ab = computeSystem(p, proj([rootA, rootB]));
      final ba = computeSystem(p, proj([rootB, rootA]));
      expect(ab.earthing.mainEarthingConductorMm2,
          ba.earthing.mainEarthingConductorMm2);
      expect(ab.earthing.mainBondingConductorMm2,
          ba.earthing.mainBondingConductorMm2);
      expect(ab.supply.system, ElectricalSystem.threePhase);
      expect(ab.supply.voltage.volts, 400);
      // Governed by B's incomer: the 16 mm² printed for [A, B] was the 1φ
      // lighting board's.
      expect(ab.earthing.mainEarthingConductorMm2, greaterThan(16));
    });

    test('property: shuffled roots never change the service', () {
      final rnd = math.Random(77);
      for (var trial = 0; trial < 20; trial++) {
        final roots = <ElectricalPanel>[
          for (var i = 0; i < 2 + rnd.nextInt(3); i++)
            _p3('R$i', [
              ElectricalCircuit(
                id: 'w$i',
                name: 'Load $i',
                loadKind: LoadKind.general,
                loadW: 1000 + rnd.nextInt(120000).toDouble(),
                phases: 3,
                length: const Length(10),
              ),
            ]),
        ];
        final base = computeSystem(p, proj(roots));
        final shuffled = [...roots]..shuffle(rnd);
        final other = computeSystem(p, proj(shuffled));
        expect(other.earthing.mainEarthingConductorMm2,
            base.earthing.mainEarthingConductorMm2,
            reason: 'trial $trial');
        expect(other.supply.voltage.volts, base.supply.voltage.volts);
      }
    });

    test('every utility root is an SPD origin (Type 1+2 with an LPS)', () {
      for (final order in [
        [rootA, rootB],
        [rootB, rootA],
      ]) {
        final project = proj(order);
        final sys = computeSystem(p, project);
        final study = computeAdvancedStudy(p, project, sys);
        expect(originPanelIdsOf(sys, project), {'A', 'B'});
        for (final id in ['A', 'B']) {
          expect(study.spd[id]!.recommended, isTrue, reason: id);
          expect(study.spd[id]!.type, SpdType.type1plus2, reason: id);
        }
      }
    });
  });

  // ── 6. genset backs the essential boards ──────────────────────────────────
  group('6 — the genset carries the essential sub-tree', () {
    ElectricalProject project({ApparentPower? forced}) => ElectricalProject(
          id: 'g',
          name: 'g',
          sources: ElectricalSources(
              generator: GeneratorSource(backupFraction: 0.3, kva: forced)),
          panels: [
            _p3('MDP', const [
              ElectricalCircuit(
                id: 'h',
                name: 'Heater',
                loadKind: LoadKind.heating,
                loadW: 80000,
                cosPhi: 1,
                phases: 3,
                length: Length(10),
              ),
              ElectricalCircuit(
                id: 'f-emg',
                name: 'Feeder EMG',
                loadKind: LoadKind.feeder,
                length: Length(10),
                feedsPanelId: 'EMG',
              ),
            ]),
            _p3('EMG', const [
              ElectricalCircuit(
                id: 'eh',
                name: 'Essential heater',
                loadKind: LoadKind.heating,
                loadW: 120000,
                cosPhi: 1,
                phases: 3,
                length: Length(10),
              ),
            ], fedBy: 'f-emg', essential: true),
          ],
        );

    test('backup = max(30 % × demand, the EMG demand)', () {
      final proj = project();
      final sys = computeSystem(p, proj);
      // Round 14 re-derivation: supply VA at the REAL per-circuit cos φ. Both
      // loads are cos φ 1.0 heaters ⇒ VA = W = 200 kVA (not the old flat
      // 200 kW / 0.85 = 235.3 kVA). 30 % = 60.0 kVA.
      final demandVa = sys.supply.demandVa.voltAmperes;
      expect(demandVa, closeTo(200000, 1));
      // EMG 120 kW at the same pf basis ⇒ ≈ 120 kVA > 60 kVA.
      final essentialVa = 120000 * demandVa / sys.supply.demandW;
      expect(essentialDemandVa(proj, sys), closeTo(essentialVa, 1));
      expect(gensetBackupDemandVa(proj, sys).voltAmperes,
          closeTo(essentialVa, 1));
      // The power one-line's genset now covers the essential board.
      final study = computeAdvancedStudy(p, proj, sys);
      final gen =
          study.powerOneLine!.nodes.firstWhere((n) => n.id == 'gen');
      final kva = double.parse(
          RegExp(r'([\d.]+) kVA').firstMatch(gen.sub!)!.group(1)!);
      expect(kva * 1000, greaterThanOrEqualTo(essentialVa));
      expect(study.warnings, isEmpty);
    });

    test('a forced nameplate below the essential demand is warned', () {
      final proj = project(forced: ApparentPower.kilovoltAmperes(100));
      final sys = computeSystem(p, proj);
      final study = computeAdvancedStudy(p, proj, sys);
      // 100 kVA < the 120 kVA essential VA (cos φ 1 heater), AND — Round 17,
      // the engine's kW limit — 0.8 × 100 = 80 kW < the 120 kW essential W.
      expect(study.warnings.map((w) => w.code),
          ['genset-below-essential-demand', 'genset-below-essential-power']);
    });
  });

  // ── 7. PFC on the diversified demand ──────────────────────────────────────
  test('7 — the PFC bank compensates the diversified kW', () {
    ElectricalProject proj(double diversity) =>
        ElectricalProject(id: 'pf', name: 'pf', panels: [
          _p3('MDP', const [
            ElectricalCircuit(
              id: 'a',
              name: 'A',
              loadKind: LoadKind.general,
              loadW: 100000,
              cosPhi: 0.7,
              phases: 3,
              length: Length(10),
            ),
            ElectricalCircuit(
              id: 'b',
              name: 'B',
              loadKind: LoadKind.general,
              loadW: 100000,
              cosPhi: 0.7,
              phases: 3,
              length: Length(10),
            ),
          ], diversity: diversity),
        ]);
    final full = proj(1.0);
    final half = proj(0.5);
    final pfFull = powerFactorCorrection(computeSystem(p, full), full);
    final pfHalf = powerFactorCorrection(computeSystem(p, half), half);
    expect(pfFull.totalKw, closeTo(200, 1e-6));
    expect(pfHalf.totalKw, closeTo(100, 1e-6));
    // Qreq = P·(tan acos 0.7 − tan acos 0.95) = 100 × (1.0202 − 0.3287)
    //      = 69.15 kvar (was 138.3 kvar at diversity 0.5).
    final q = 100 * (math.tan(math.acos(0.7)) - math.tan(math.acos(0.95)));
    expect(pfHalf.requiredKvar, closeTo(q, 0.05));
    expect(pfHalf.requiredKvar, closeTo(pfFull.requiredKvar / 2, 0.05));
  });
}
