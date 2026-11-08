// Round 74 (regression-2) — a main busbar past the standard flat-bar table
// is issued as n PARALLEL top-rung bars (100 x 10, 1000 mm2, 1430 A each)
// with a `busbar-beyond-standard-table` warning, never an invented 0 x 0
// density-estimate section (1539 mm2 could not be ordered).
//
// First principles (re-derived Round 75 — parallel-bar derating k(n) =
// 1.7 / 2.35 / 2.8 / 0.7·n for 2 / 3 / 4 / ≥5 bars):
//   n = the smallest count ≥ max(2, ceil(csa floor / 1000 mm2)) with
//       1430 A · k(n) ≥ required
//   csa = n · 1000 mm2, ampacity = 1430 A · k(n)
library;

import 'dart:math' as math;

import 'package:mechx_engine/electrical/bom.dart';
import 'package:mechx_engine/electrical/busbar.dart';
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/earthing.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/panel_results.dart';
import 'package:mechx_engine/report/electrical_calc_report.dart';
import 'package:mechx_engine/report/electrical_sld_drawing.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

const _profile = PuilProfile();
const _code = 'busbar-beyond-standard-table';

ElectricalProject _board(int motors) => ElectricalProject(
      id: 'r74',
      name: 'Round 74',
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
  test('sizeBusbar past the table: n parallel top bars (seeded property)', () {
    final top = _profile.copperBusbarTable.last;
    expect(top.csaMm2, 1000);
    expect(top.ampacityA.amperes, 1430);
    final rnd = math.Random(74);
    for (var i = 0; i < 200; i++) {
      final req = 1431 + rnd.nextDouble() * 6000;
      final floor = rnd.nextBool() ? 0.0 : rnd.nextDouble() * 5000;
      final b = sizeBusbar(_profile, Current(req), minCsaMm2: floor);
      double k(int n) =>
          n == 2 ? 1.7 : n == 3 ? 2.35 : n == 4 ? 2.8 : 0.7 * n;
      var n = math.max(2, (floor / 1000 - 1e-9).ceil());
      while (1430 * k(n) < req) {
        n++;
      }
      expect(b.parallelBars, n, reason: 'req $req floor $floor');
      expect(b.widthMm, 100);
      expect(b.thicknessMm, 10);
      expect(b.csaMm2, n * 1000);
      expect(b.ampacityA.amperes, (1430 * k(n)).roundToDouble());
      expect(b.ampacityA.amperes, greaterThanOrEqualTo(req));
      expect(b.csaMm2, greaterThanOrEqualTo(floor));
    }
    // Inside the table: one bar, unchanged.
    final inTable = sizeBusbar(_profile, const Current(1430));
    expect(inTable.parallelBars, 1);
    expect(inTable.csaMm2, 1000);
  });

  test('10 x 110 kW board: parallel-bar main bus, warning, BOM + schedule '
      'carry the make-up', () {
    final p = _board(10);
    final sys = computeSystem(_profile, p,
        originFaultLevel: const Current(16000), busbarClearingTimeS: 0.1);
    final mdp = sys.panels['MDP']!;
    final bar = mdp.busbar;
    // The incomer is past 1430 A, so the bus needs ≥ 2 parallel 1000 mm2
    // bars — Round 75: enough that the DERATED set carries the incomer
    // (2 bars 2431 A, 3 bars 3360.5 A, 4 bars 4004 A).
    final inA = mdp.incomer.breaker.ratingA.amperes;
    expect(inA, greaterThan(1430));
    final expectN = inA <= 2431 ? 2 : inA <= 3360.5 ? 3 : 4;
    expect(bar.parallelBars, expectN);
    expect(bar.ampacityA.amperes, greaterThanOrEqualTo(inA));
    expect(bar.widthMm, 100);
    expect(bar.csaMm2, bar.parallelBars * 1000);
    final warns = mdp.warnings.where((w) => w.code == _code).toList();
    expect(warns, isNotEmpty);
    // Round 75 — an acknowledgeable INFO (the set is rated on its derated
    // figure; a warning against the engine's own pick blocked compliance).
    expect(warns.first.severity, WarningSeverity.info);
    expect(sys.warnings.where((w) => w.code == _code), isNotEmpty);

    final lines = buildPanelBom(mdp);
    final bus =
        lines.firstWhere((l) => l.description.startsWith('Busbar set'));
    expect(bus.description, contains('${bar.parallelBars} × (100×10 mm)'));
    expect(bus.priceKey, endsWith(':${bar.parallelBars}x1000'));

    final sheet = buildElectricalSld(project: p, result: sys);
    final labels = sheet.prims.whereType<SldLabel>().map((l) => l.text);
    expect(labels.any((t) => t.contains('Cu bus ${bar.parallelBars}x(100x10)')),
        isTrue);
  });

  test('r2: the calc report names the parallel-bar count, never one bar '
      'beside the summed section', () {
    final p = _board(10);
    final sys = computeSystem(_profile, p,
        originFaultLevel: const Current(16000), busbarClearingTimeS: 0.1);
    final n = sys.panels['MDP']!.busbar.parallelBars;
    expect(n, greaterThan(1));
    final md = buildElectricalCalcReport(ElectricalCalcReportData(
      projectName: 'R74',
      date: '2026-11-08',
      standardsName: _profile.name,
      standardsRevision: _profile.revision,
      project: p,
      result: sys,
    ));
    expect(md, contains('$n × (100×10 mm) (${n * 1000} mm²)'));
    // A 100×10 bar is 1000 mm²: the summed section never sits beside one
    // bar's geometry alone.
    expect(md, isNot(contains('100×10 mm (${n * 1000} mm²)')));
  });

  test('r2: a one-bar board keeps the bare geometry in the report', () {
    final p = _board(2);
    final sys = computeSystem(_profile, p,
        originFaultLevel: const Current(16000), busbarClearingTimeS: 0.1);
    final b = sys.panels['MDP']!.busbar;
    expect(b.parallelBars, 1);
    final md = buildElectricalCalcReport(ElectricalCalcReportData(
      projectName: 'R74',
      date: '2026-11-08',
      standardsName: _profile.name,
      standardsRevision: _profile.revision,
      project: p,
      result: sys,
    ));
    expect(md, isNot(contains(' × (')));
  });

  test('a board inside the table stays one bar with no warning', () {
    final sys = computeSystem(_profile, _board(2),
        originFaultLevel: const Current(16000), busbarClearingTimeS: 0.1);
    final mdp = sys.panels['MDP']!;
    expect(mdp.busbar.parallelBars, 1);
    expect(mdp.warnings.where((w) => w.code == _code), isEmpty);
  });
}
