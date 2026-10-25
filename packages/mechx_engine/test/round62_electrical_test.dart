// Round 62 (2026-10-18) — electrical.
//
//   elec-convergence-14-flc-judge-condemns-undeclared-study-transformer-on-
//   diversified-board — an UNDECLARED study transformer is sized on the
//     root's DIVERSIFIED worst-phase demand; its incomer sizes on the
//     undiversified current. The Round-41 FLC judge now reads the basis the
//     engine's own unit was sized on, so panel diversity never makes it
//     condemn the engine's pick; a DECLARED transformer keeps the incomer-
//     rung judge.
//
//     First principles: 12 x 25 kW 3ph at cos phi 0.85 on 400 V =
//     300 000 / (sqrt3 x 400 x 0.85) = 509.4 A undiversified -> the 630 A
//     incomer. At diversity 0.6 the worst phase is 305.6 A = 211.7 kVA,
//     / 0.8 = 264.7 kVA -> the 315 kVA unit, FLC 315 000 / (sqrt3 x 400) =
//     454.7 A -> the 500 A rung. Judged on 305.6 A (the unit's own basis)
//     it is under the rung; a DECLARED 315 kVA unit under the same 630 A
//     incomer is still flagged (630 > 500).
//
//   elec-convergence-14-riser-floor-runs-issued-below-7pt-when-each-band-
//   is-legible — a tower of NON-identical floor boards (ways named per unit,
//     so nothing collapses to TIPIKAL) prints every floor legibly on its own
//     page plan; the issued riser is paged through that same plan, so every
//     page reaches 7 pt and every board is drawn once.
import 'package:mechx_engine/electrical/advanced_study.dart';
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/earthing.dart';
import 'package:mechx_engine/electrical/geo_length.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/report/electrical_pagination.dart';
import 'package:mechx_engine/report/electrical_sld_drawing.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

const _p = PuilProfile();

ElectricalProject _mdp(double diversity, {double? declaredTxKva}) =>
    ElectricalProject(
      id: 'p',
      name: 'Diversified',
      earthingSystem: EarthingSystem.tnS,
      transformerKva:
          declaredTxKva == null ? null : ApparentPower(declaredTxKva * 1000),
      panels: [
        ElectricalPanel(
          id: 'MDP',
          name: 'MDP',
          voltage: const Voltage(400),
          diversityFactor: diversity,
          circuits: [
            for (var k = 0; k < 12; k++)
              ElectricalCircuit(
                  id: 'c$k',
                  name: 'Load $k',
                  loadKind: LoadKind.general,
                  loadW: 25000,
                  cosPhi: 0.85,
                  phases: 3,
                  length: const Length(20)),
          ],
        ),
      ],
    );

List<String> _flc(ElectricalProject pr) {
  final sys = computeSystem(_p, pr);
  return [
    for (final w in computeAdvancedStudy(_p, pr, sys).warnings)
      if (w.code == 'root-incomer-exceeds-transformer-flc') w.message,
  ];
}

LayoutPos _at(int f) => LayoutPos(sheetId: 's', floorIndex: f, x: 0, y: 0);

/// MDP + SDP on GF; 40 single-phase unit boards, 4 per floor on L1..L10,
/// each fed from the MDP and carrying ways named for ITS unit (no TIPIKAL).
ElectricalProject _tower() {
  final units = [for (var i = 0; i < 40; i++) 'U${101 + i}'];
  return ElectricalProject(id: 't', name: 'Tower', panels: [
    ElectricalPanel(
      id: 'MDP',
      name: 'MDP',
      layoutPos: _at(0),
      circuits: [
        const ElectricalCircuit(
            id: 'fSDP',
            name: 'to SDP',
            loadKind: LoadKind.feeder,
            feedsPanelId: 'SDP',
            length: const Length(10)),
        for (var i = 0; i < 40; i++)
          ElectricalCircuit(
              id: 'f$i',
              name: 'to ${units[i]}',
              loadKind: LoadKind.feeder,
              feedsPanelId: 'B$i',
              length: Length(10.0 + 3 * (1 + i ~/ 4))),
      ],
    ),
    ElectricalPanel(
      id: 'SDP',
      name: 'SDP',
      layoutPos: _at(0),
      circuits: const [
        ElectricalCircuit(
            id: 'sdp-g',
            name: 'Pumps',
            loadKind: LoadKind.general,
            loadW: 8000,
            phases: 3,
            length: Length(15)),
      ],
    ),
    for (var i = 0; i < 40; i++)
      ElectricalPanel(
        id: 'B$i',
        name: 'PHB UNIT ${units[i]}',
        system: ElectricalSystem.singlePhase,
        voltage: const Voltage(230),
        layoutPos: _at(1 + i ~/ 4),
        circuits: [
          ElectricalCircuit(
              id: 'B$i-l',
              name: '${units[i]}-L lighting',
              loadKind: LoadKind.lighting,
              loadW: 400,
              length: const Length(12)),
          ElectricalCircuit(
              id: 'B$i-s',
              name: '${units[i]}-S sockets',
              loadKind: LoadKind.socket,
              loadW: 1800,
              length: const Length(12)),
        ],
      ),
  ]);
}

void main() {
  group('the FLC judge reads the undeclared unit on its own basis', () {
    for (final df in [1.0, 0.8, 0.6, 0.5]) {
      test('diversity $df: no warning on the engine\'s own transformer', () {
        expect(_flc(_mdp(df)), isEmpty);
      });
    }

    test('diversity 0.6 sizes the 315 kVA unit under a 630 A incomer', () {
      final pr = _mdp(0.6);
      final sys = computeSystem(_p, pr);
      expect(sys.panels['MDP']!.incomer.breaker.ratingA.amperes, 630);
      final s = studySupplyDesign(pr, sys);
      expect(s.transformerKva, 315);
    });

    test('a DECLARED 315 kVA unit under the 630 A incomer is still flagged',
        () {
      final w = _flc(_mdp(0.6, declaredTxKva: 315));
      expect(w, hasLength(1));
      expect(w.single, contains('630 A incomer'));
      expect(w.single, contains('500 A breaker rung'));
    });
  });

  test('tower of distinct unit boards: every riser page reaches 7 pt', () {
    final pr = _tower();
    final b = BuildingLevels([
      const Floor('GF', Length(4)),
      for (var f = 1; f <= 10; f++) Floor('L$f', const Length(3.2)),
    ]);
    final r = computeSystem(_p, pr);
    final pages =
        paginatedElectricalRiserSheets(project: pr, result: r, building: b);
    for (final (i, p) in pages.indexed) {
      expect(p.belowMinLabelPt, isNull, reason: 'page $i flagged');
    }
    // Every board drawn on some page (no TIPIKAL collapse here).
    expect(electricalRiserTypicalGroups(pr, r, b), isEmpty);
    final drawn = <String>{
      for (final p in pages)
        for (final l in p.prims.whereType<SldLabel>())
          if (l.size == 10 && l.bold) l.text,
    };
    for (final panel in pr.panels) {
      expect(drawn, contains(panel.name), reason: panel.name);
    }
  });
}
