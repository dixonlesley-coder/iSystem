// Round 75 — parallel busbars are rated on their DERATED figure, and the
// neutral / PE bars past the table are orderable n × (100×10) sets.
//
// regression-1: n parallel flat bars do not share current evenly
// (proximity / skin effect). DIN 43671-style ratios (`// VERIFY
// notAnSniClause`): k(2) = 1.7, k(3) = 2.35, k(4) = 2.8, k(n ≥ 5) = 0.7·n.
// On the table's 1430 A single 100×10 bar:
//   2 bars 1.7 × 1430 = 2431 A, 3 bars 2.35 × 1430 = 3360.5 A,
//   4 bars 2.8 × 1430 = 4004 A, 5 bars 3.5 × 1430 = 5005 A.
// So a 2500 A ACB's bus is 3 bars (2431 < 2500 ≤ 3360.5) and a 4000 A bus
// 4 bars (3360.5 < 4000 ≤ 4004) — never 2 × 1430 = 2860 A / 3 × 1430 =
// 4290 A, which issued the bus above what it carries. The
// `busbar-beyond-standard-table` note is an acknowledgeable INFO: raised
// against the engine's own pick, a WARNING made every 1600 A+ MDP fail
// compliance permanently.
//
// elec-convergence-26: past the 1000 mm² table top the neutral and the PE
// follow the same `n × top` rule:
//   (a) phase 80×10 = 800 mm² / 1180 A, factor 1.73, sizing current 917 A
//       ⇒ need 1.73 × 917 = 1586.4 A > 1430 A ⇒ n = 2 (2431 A ≥ 1586.4),
//       neutral 2 × 1000 = 2000 mm² rated 2431 A (was an invented 1221 mm²
//       rated at the phase bar's 1180 A);
//   (b) a 2-bar phase set's full-size neutral is that 2-bar set, PE S/2 =
//       1000 mm² = one 100×10 bar; a 3-bar set's PE S/2 = 1500 mm² ⇒ the
//       2 × 1000 set;
//   (c) the legacy CSA path (no sizing current): 800 × 1.73 = 1384 mm² ⇒
//       the 2 × 1000 set (was ceil = 1384 mm²).
library;

import 'dart:math' as math;

import 'package:mechx_engine/electrical/bom.dart';
import 'package:mechx_engine/electrical/busbar.dart';
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/earthing.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/panel_results.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

const _p = PuilProfile();

double _k(int n) => n <= 1
    ? 1.0
    : n == 2
        ? 1.7
        : n == 3
            ? 2.35
            : n == 4
                ? 2.8
                : 0.7 * n;

ElectricalProject _board(int motors) => ElectricalProject(
      id: 'r75',
      name: 'Round 75',
      earthingSystem: EarthingSystem.tnS,
      panels: [
        ElectricalPanel(
          id: 'MDP',
          name: 'MDP',
          voltage: const Voltage(400),
          circuits: [
            for (var i = 0; i < motors; i++)
              ElectricalCircuit(
                  id: 'm$i',
                  name: 'Motor $i',
                  loadKind: LoadKind.motor,
                  motorKw: 110,
                  phases: 3,
                  length: const Length(20)),
          ],
        ),
      ],
    );

void main() {
  test('parallelBarFactor: 1 / 1.7 / 2.35 / 2.8 / 0.7n', () {
    for (var n = 1; n <= 8; n++) {
      expect(parallelBarFactor(n), closeTo(_k(n), 1e-12), reason: '$n');
      // Every added bar still adds rating (never fewer amps for more copper).
      if (n > 1) {
        expect(parallelBarFactor(n), greaterThan(parallelBarFactor(n - 1)));
      }
      // And never the naive n × one bar beyond one.
      if (n > 1) expect(parallelBarFactor(n), lessThan(n));
    }
  });

  test('a 2500 A bus is 3 bars (>= 2500 A), a 4000 A bus 4 bars', () {
    final b2500 = sizeBusbar(_p, const Current(2250),
        minAmpacityA: const Current(2500));
    expect(b2500.parallelBars, 3);
    expect(b2500.ampacityA.amperes, 3361); // 3360.5 rounded
    expect(b2500.ampacityA.amperes, greaterThanOrEqualTo(2500));
    final b4000 = sizeBusbar(_p, const Current(3600),
        minAmpacityA: const Current(4000));
    expect(b4000.parallelBars, 4);
    expect(b4000.ampacityA.amperes, 4004);
    final b1600 = sizeBusbar(_p, const Current(1440),
        minAmpacityA: const Current(1600));
    expect(b1600.parallelBars, 2);
    expect(b1600.ampacityA.amperes, 2431);
  });

  test('seeded: the rated set always covers the requirement and n is the '
      'smallest derated count', () {
    final rnd = math.Random(7510);
    for (var i = 0; i < 300; i++) {
      final req = 1431 + rnd.nextDouble() * 9000;
      final floor = rnd.nextBool() ? 0.0 : rnd.nextDouble() * 6000;
      final b = sizeBusbar(_p, Current(req), minCsaMm2: floor);
      final n = b.parallelBars;
      expect(1430 * _k(n), greaterThanOrEqualTo(req - 1e-9), reason: '$req');
      expect(n * 1000.0, greaterThanOrEqualTo(floor - 1e-9));
      // One bar fewer would fail the current or the section floor.
      if (n > 2) {
        expect(1430 * _k(n - 1) < req || (n - 1) * 1000.0 < floor, isTrue,
            reason: '$req / $floor -> $n');
      }
      expect(b.ampacityA.amperes, (1430 * _k(n)).roundToDouble());
    }
  });

  test('10 x 110 kW board: the bus carries the incomer; the beyond-table '
      'note is an INFO, never a warning', () {
    final sys = computeSystem(_p, _board(10),
        originFaultLevel: const Current(16000), busbarClearingTimeS: 0.1);
    final mdp = sys.panels['MDP']!;
    expect(mdp.busbar.parallelBars, greaterThan(1));
    expect(mdp.busbar.ampacityA.amperes,
        greaterThanOrEqualTo(mdp.incomer.breaker.ratingA.amperes));
    final notes = sys.warnings
        .where((w) => w.code == 'busbar-beyond-standard-table')
        .toList();
    expect(notes, isNotEmpty);
    for (final w in notes) {
      expect(w.severity, WarningSeverity.info);
    }
  });

  group('neutral / PE past the table (elec-convergence-26)', () {
    test('(a) FOLD-2 current path: 1586 A neutral = 2 x (100x10), 2431 A',
        () {
      final n = sizeNeutralPeBars(800, const Current(1180),
          profile: _p,
          neutralOversizeFactor: 1.73,
          triplenFraction: 1.0,
          phaseSizingCurrentA: 917);
      expect(n.neutralCsaMm2, 2000);
      expect(n.neutralParallelBars, 2);
      expect(n.neutralAmpacityA.amperes, 2431);
      expect(n.neutralAmpacityA.amperes, greaterThanOrEqualTo(1.73 * 917));
      expect(n.oversized, isTrue);
      expect(neutralBarSpec(n), '2 × (100×10 mm) (2000 mm²)');
    });

    test('(b) a 2-bar phase set: neutral = the set, PE one 100x10', () {
      final n = sizeNeutralPeBars(2000, const Current(2431),
          profile: _p, phaseParallelBars: 2);
      expect(n.neutralCsaMm2, 2000);
      expect(n.neutralParallelBars, 2);
      expect(n.peCsaMm2, 1000);
      expect(n.peParallelBars, 1);
      final n3 = sizeNeutralPeBars(3000, const Current(3361),
          profile: _p, phaseParallelBars: 3);
      expect(n3.neutralParallelBars, 3);
      expect(n3.peCsaMm2, 2000); // S/2 = 1500 -> 2 x 1000
      expect(n3.peParallelBars, 2);
    });

    test('(c) the legacy CSA path never invents a section', () {
      final n = sizeNeutralPeBars(800, const Current(1180),
          profile: _p, neutralOversizeFactor: 1.73, triplenFraction: 1.0);
      expect(n.neutralCsaMm2, 2000); // 1384 -> 2 x 1000
      expect(n.neutralParallelBars, 2);
    });

    test('seeded: every neutral / PE section is a rung or n x 1000, the '
        'neutral carries factor x I, the BOM key never a non-rung', () {
      final rungs = {for (final b in _p.copperBusbarTable) b.csaMm2};
      final rnd = math.Random(7511);
      for (var i = 0; i < 300; i++) {
        final req = 50 + rnd.nextDouble() * 6000;
        final bus = sizeBusbar(_p, Current(req));
        final f = rnd.nextBool() ? 1.0 : 1 + rnd.nextDouble() * 0.9;
        final np = sizeNeutralPeBars(bus.csaMm2, bus.ampacityA,
            profile: _p,
            neutralOversizeFactor: f,
            triplenFraction: f > 1 ? 1.0 : 0,
            phaseSizingCurrentA: req,
            phaseParallelBars: bus.parallelBars);
        bool orderable(double csa, int n) =>
            n > 1 ? csa == n * 1000 : rungs.contains(csa) || csa < 24;
        expect(orderable(np.neutralCsaMm2, np.neutralParallelBars), isTrue,
            reason: '$req x $f -> N ${np.neutralCsaMm2}');
        if (bus.parallelBars > 1) {
          expect(orderable(np.peCsaMm2, np.peParallelBars), isTrue,
              reason: '$req -> PE ${np.peCsaMm2}');
          expect(np.neutralParallelBars,
              greaterThanOrEqualTo(bus.parallelBars));
        }
        expect(np.neutralAmpacityA.amperes,
            greaterThanOrEqualTo(f * req - 0.5),
            reason: '$req x $f');
      }
    });

    test('computed boards: the BOM neutral / PE lines carry the make-up and '
        'never a non-rung key', () {
      final rungs = {for (final b in _p.copperBusbarTable) b.csaMm2};
      // A 3φ board of 60 single-phase 9 kW UPS ways (triplen share 100 %,
      // factor 1.73) and the 10 x 110 kW motor board (a parallel phase set).
      final ups = ElectricalProject(
        id: 'u',
        name: 'u',
        earthingSystem: EarthingSystem.tnS,
        panels: [
          ElectricalPanel(
            id: 'UPS',
            name: 'UPS',
            voltage: const Voltage(400),
            circuits: [
              for (var i = 0; i < 60; i++)
                ElectricalCircuit(
                    id: 'u$i',
                    name: 'UPS $i',
                    loadKind: LoadKind.ups,
                    loadW: 9000,
                    cosPhi: 0.9,
                    length: const Length(15)),
            ],
          ),
        ],
      );
      for (final proj in [ups, _board(10)]) {
        final sys = computeSystem(_p, proj,
            originFaultLevel: const Current(16000), busbarClearingTimeS: 0.1);
        for (final pr in sys.panels.values) {
          final np = pr.neutralPeBars;
          final lines = buildPanelBom(pr);
          for (final (prefix, n) in [
            ('Neutral bar', np.neutralParallelBars),
            ('PE / earth bar', np.peParallelBars),
          ]) {
            final l = lines.firstWhere((l) => l.description.startsWith(prefix));
            final tail = l.priceKey!.split(':').last;
            if (n > 1) {
              expect(tail, '${n}x1000', reason: l.priceKey);
              expect(l.description, contains('$n × (100×10 mm)'));
            } else if (pr.busbar.parallelBars > 1 || np.oversized) {
              expect(rungs.contains(double.parse(tail)), isTrue,
                  reason: l.priceKey);
            }
          }
          if (np.neutralOversizeFactor > 1) {
            expect(np.neutralAmpacityA.amperes,
                greaterThanOrEqualTo(np.neutralOversizeFactor *
                        pr.busbar.totalCurrentA.amperes -
                    1));
          }
        }
      }
    });
  });
}
