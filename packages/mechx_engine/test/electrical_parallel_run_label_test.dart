/// A PARALLEL-RUN way names every cable it pulls.
///
/// When no single standard section carries the design current the sizer
/// parallels N cables per phase ([CableResult.runsPerPhase]). The board
/// schedule's PENGHANTAR cell used to print ONE cable (`NYM 5x240 mm2`) for a
/// way that actually pulls two complete cables — under-stating the take-off by
/// half and contradicting the containment beside it. Every label surface now
/// prints `2x(NYM 5x240 mm2)` through the ONE [cableRunLabel] notation.
library;

import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/report/electrical_sld_drawing.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

/// MDP feeds SDP; both carry a large 3-phase load. Hand derivation of why the
/// sizer parallels: a 350 kW general load at 400 V, pf ~0.85 draws
///   Ib = 350000 / (sqrt(3) * 400 * 0.85) ≈ 594 A
/// so In = 630 A. The largest standard section's derated Iz is below 630 A, so
/// one cable cannot be protected by that breaker and two runs per phase are
/// needed. The run count itself is read back from the engine (orchestration
/// level) rather than re-derived here.
const _project = ElectricalProject(id: 'pr', name: 'Parallel', panels: [
  ElectricalPanel(
    id: 'MDP',
    name: 'MDP',
    system: ElectricalSystem.threePhase,
    voltage: Voltage(400),
    circuits: [
      ElectricalCircuit(
        id: 'big',
        name: 'Chiller',
        loadKind: LoadKind.general,
        loadW: 350000,
        phases: 3,
        length: Length(40),
      ),
      ElectricalCircuit(
        id: 'f',
        name: 'SDP feed',
        loadKind: LoadKind.general,
        phases: 3,
        feedsPanelId: 'SDP',
        length: Length(40),
      ),
      ElectricalCircuit(
        id: 'small',
        name: 'Lights',
        loadKind: LoadKind.lighting,
        isLighting: true,
        loadW: 800,
        length: Length(20),
      ),
    ],
  ),
  ElectricalPanel(
    id: 'SDP',
    name: 'SDP',
    system: ElectricalSystem.threePhase,
    voltage: Voltage(400),
    circuits: [
      ElectricalCircuit(
        id: 'b2',
        name: 'Load',
        loadKind: LoadKind.general,
        loadW: 300000,
        phases: 3,
        length: Length(20),
      ),
    ],
  ),
]);

void main() {
  group('cableRunLabel notation', () {
    test('a single cable is exactly the legacy label + mm2', () {
      expect(
          cableRunLabel(null, 16, true), '${cableLabel(null, 16, true)} mm2');
      expect(cableRunLabel(null, 16, true, runs: 1),
          '${cableLabel(null, 16, true)} mm2');
    });

    test('parallel runs wrap the whole cable in an N x ( ) group', () {
      expect(cableRunLabel(null, 185, true, cores: 5, runs: 2),
          '2x(NYY 5x185 mm2)');
      expect(cableRunLabel(null, 240, true, cores: 4, runs: 3),
          '3x(NYY 4x240 mm2)');
    });

    test('Round 19: a reduced PE / neutral prints the grouped make-up', () {
      // 3L + N at 35 mm², PE 16 mm² (25–35 mm² phase ⇒ 16 mm² PE).
      expect(cableRunLabel(null, 35, true, cores: 5, peCsaMm2: 16),
          'NYY 4x35+16 mm2');
      // Motor (no neutral): 3L at 70, PE 35 (S/2).
      expect(cableRunLabel(null, 70, true, cores: 4, peCsaMm2: 35),
          'NYY 3x70+35 mm2');
      // Reduced neutral AND PE: 3×240 + 120 + 120 ⇒ 3x240+2x120.
      expect(
          cableRunLabel(null, 240, true,
              cores: 5, runs: 2, peCsaMm2: 120, neutralCsaMm2: 120),
          '2x(NYY 3x240+2x120 mm2)');
      // PE at the phase section ⇒ the plain count (byte-identical).
      expect(cableRunLabel(null, 16, true, cores: 5, peCsaMm2: 16),
          'NYY 5x16 mm2');
    });
  });

  group('every drawing surface carries the run count', () {
    final sys = computeSystem(const PuilProfile(), _project);
    final mdp = sys.panels['MDP']!;
    final big = mdp.circuits.firstWhere((c) => c.circuitId == 'big');
    final feed = mdp.circuits.firstWhere((c) => c.circuitId == 'f');
    final small = mdp.circuits.firstWhere((c) => c.circuitId == 'small');

    test('the fixture really is a parallel-run design (engine read-back)', () {
      expect(big.cable.runsPerPhase, greaterThan(1));
      expect(feed.cable.runsPerPhase, greaterThan(1));
      expect(small.cable.runsPerPhase ?? 1, 1);
    });

    test('board schedule PENGHANTAR cell', () {
      final sheet = buildElectricalPanelDetail(
          project: _project, result: sys, panelId: 'MDP');
      final labels =
          sheet.prims.whereType<SldLabel>().map((l) => l.text).toList();
      final n = big.cable.runsPerPhase!;
      // Round 19 — 3L + N at the phase section, PE reduced (S/2 → standard).
      expect(big.grounding.neutralCsaMm2, big.cable.csaMm2);
      expect(big.grounding.peCsaMm2, lessThan(big.cable.csaMm2));
      final expected = '${n}x(NYM 4x${big.cable.csaMm2.round()}'
          '+${big.grounding.peCsaMm2.round()} mm2)';
      expect(labels.where((t) => t.startsWith(expected)), hasLength(1));
      // No row prints a bare single parallel-section cable.
      expect(
          labels.where((t) => t.startsWith(
              'NYM ${big.grounding.cores}x${big.cable.csaMm2.round()} mm2')),
          isEmpty);
      // A single-cable way stays un-grouped (byte-identical).
      expect(labels.where((t) => t.startsWith('NYM 3x')), isNotEmpty);
    });

    test('overview AND riser feeder labels', () {
      final n = feed.cable.runsPerPhase!;
      expect(feed.grounding.neutralCsaMm2, feed.cable.csaMm2);
      final prefix = '${n}x(NYM 4x${feed.cable.csaMm2.round()}'
          '+${feed.grounding.peCsaMm2.round()} mm2) · ';
      final ov = buildElectricalOverview(project: _project, result: sys);
      expect(
          ov.prims
              .whereType<SldLabel>()
              .where((l) => l.text.startsWith(prefix)),
          hasLength(1));
      final riser = buildElectricalRiser(project: _project, result: sys);
      expect(
          riser.prims
              .whereType<SldLabel>()
              .where((l) => l.text.startsWith(prefix)),
          hasLength(1));
    });
  });
}
