// Round 74 (regression-2) — a main busbar past the standard flat-bar table
// is issued as n PARALLEL top-rung bars (100 x 10, 1000 mm2, 1430 A each)
// with a `busbar-beyond-standard-table` warning, never an invented 0 x 0
// density-estimate section (1539 mm2 could not be ordered).
//
// First principles:
//   n = max(ceil(required / 1430 A), ceil(csa floor / 1000 mm2), 2)
//   csa = n · 1000 mm2, ampacity = n · 1430 A
library;

import 'dart:math' as math;

import 'package:mechx_engine/electrical/bom.dart';
import 'package:mechx_engine/electrical/busbar.dart';
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/earthing.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/panel_results.dart';
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
      final n = math.max(
          2, math.max((req / 1430 - 1e-9).ceil(), (floor / 1000 - 1e-9).ceil()));
      expect(b.parallelBars, n, reason: 'req $req floor $floor');
      expect(b.widthMm, 100);
      expect(b.thicknessMm, 10);
      expect(b.csaMm2, n * 1000);
      expect(b.ampacityA.amperes, n * 1430);
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
    // The incomer is past 1430 A, so the bus needs ≥ 2 parallel 1000 mm2 bars.
    expect(mdp.incomer.breaker.ratingA.amperes, greaterThan(1430));
    expect(bar.parallelBars,
        (mdp.incomer.breaker.ratingA.amperes / 1430 - 1e-9).ceil());
    expect(bar.widthMm, 100);
    expect(bar.csaMm2, bar.parallelBars * 1000);
    final warns = mdp.warnings.where((w) => w.code == _code).toList();
    expect(warns, isNotEmpty);
    expect(warns.first.severity, WarningSeverity.warning);
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

  test('a board inside the table stays one bar with no warning', () {
    final sys = computeSystem(_profile, _board(2),
        originFaultLevel: const Current(16000), busbarClearingTimeS: 0.1);
    final mdp = sys.panels['MDP']!;
    expect(mdp.busbar.parallelBars, 1);
    expect(mdp.warnings.where((w) => w.code == _code), isEmpty);
  });
}
