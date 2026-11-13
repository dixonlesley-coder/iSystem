// Round 66 (elec-convergence-18-single-phase-root-transformer-sized-on-va-
// not-line-current) — a 1-phase service-entrance board beside a 3-phase one
// on an undeclared MV service is counted at its LINE current on the
// 3-phase transformer, never at its own V x I.
//
// Probe A: root A 3ph 400 V, 6 x 100 kW at cos phi 1; root B 1ph 230 V,
// 4 x 46 kW at cos phi 1 (no headroom, demand factor 1).
//
// First principles:
//   I_A = 600 kW / (sqrt3 x 400) = 866.0 A on every line;
//   I_B = 184 kW / 230 = 800.0 A, ALL on one line of the transformer.
//   The loaded line therefore carries 866 + 800 = 1666 A, which a 3-phase
//   unit carries only when rated sqrt3 x 400 x 1666 = 1154 kVA; at the 80 %
//   loading target 1154 / 0.8 = 1443 kVA => the 1600 kVA rung (FLC
//   1600e3 / (sqrt3 x 400) = 2309 A >= 1666 A). Counting B at 230 x 800 =
//   184 kVA gave (600 + 184) / 0.8 = 980 kVA => 1000 kVA, FLC 1443 A — the
//   loaded line at 1666 / 1443 = 115 % of the unit's FLC.
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
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

const _profile = PuilProfile();

ElectricalProject _probe() => ElectricalProject(
      id: 'p',
      name: 'Mixed roots',
      panels: [
        ElectricalPanel(serviceEntrance: true, id: 'A', name: 'MDP-A', circuits: [
          for (var i = 0; i < 6; i++)
            ElectricalCircuit(
                id: 'a$i',
                name: 'Load A$i',
                loadKind: LoadKind.motor,
                loadW: 100e3,
                cosPhi: 1,
                phases: 3,
                length: const Length(10)),
        ]),
        ElectricalPanel(serviceEntrance: true, 
            id: 'B',
            name: 'MDP-B',
            system: ElectricalSystem.singlePhase,
            voltage: const Voltage(230),
            circuits: [
              for (var i = 0; i < 4; i++)
                ElectricalCircuit(
                    id: 'b$i',
                    name: 'Load B$i',
                    loadKind: LoadKind.motor,
                    loadW: 46e3,
                    cosPhi: 1,
                    phases: 1,
                    length: const Length(10)),
            ]),
      ],
    );

void main() {
  test('1-phase root counted at sqrt3 x 400 x I on the transformer', () {
    final pr = _probe();
    final sys = computeSystem(_profile, pr);
    final ia = sys.panels['A']!.diversifiedDemandCurrent.amperes;
    final ib = sys.panels['B']!.diversifiedDemandCurrent.amperes;
    final la = sys.panels['A']!.largestDownstreamRunA;
    final lb = sys.panels['B']!.largestDownstreamRunA;
    final aA = math.max(ia, la), aB = math.max(ib, lb);
    // The per-root basis: A on its own 3ph system, B on the 3ph line basis.
    expect(rootServiceBasisVa(pr, sys, 'B'),
        closeTo(math.sqrt(3) * 400 * aB, math.sqrt(3) * 400 * 0.06));
    expect(rootServiceBasisVa(pr, sys, 'A'),
        closeTo(math.sqrt(3) * 400 * aA, math.sqrt(3) * 400 * 0.06));
    final s = studySupplyDesign(pr, sys);
    expect(s.transformerKva, isNotNull);
    // The unit's FLC carries the loaded line (A's current + all of B's).
    final flc = s.transformerKva! * 1000 / (math.sqrt(3) * 400) * s.units;
    expect(flc, greaterThanOrEqualTo(ia + ib));
    expect(s.transformerKva, 1600);
    final st = computeAdvancedStudy(_profile, pr, sys);
    expect(st.warnings.map((w) => w.code),
        isNot(contains('root-incomer-exceeds-transformer-flc')));
  });
}
