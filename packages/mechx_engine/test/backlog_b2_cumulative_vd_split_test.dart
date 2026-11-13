/// Backlog B-2 (2026-11-13) — THE LEAST-COPPER CURE OF A CUMULATIVE DROP.
///
/// Reference tower T3 always cured a final way's cumulative (origin → load)
/// voltage drop by enlarging the FEEDER above it (tower PP-Lt30 ended at
/// 95 mm² over 131 m because one 30 m lighting way owned 2.45 % of its 3 %).
/// Now each failing way (cumulative over its limit, own drop within it) picks
/// among the auto-sized cables on its chain — itself and every feeder above —
/// the one whose next section saves the most drop per added copper:
/// Δ%VD / (Δmm² × length × loaded cores); a feeder's saving is summed over
/// all failing ways below it; ties go to the final way. Picks apply at once
/// (order-independent); user-fixed cables are never grown.
library;

import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/earthing.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/panel_results.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

const _p = PuilProfile();

ElectricalCircuitResult _way(ElectricalSystemResult s, String panel, String id) =>
    s.panels[panel]!.circuits.firstWhere((c) => c.circuitId == id);

/// MDP (3φ) → SP (3φ) over a [feederM] feeder; SP carries [ways] 1φ 1500 W
/// lighting ways of [wayM] each (cos φ 0.9), spread over the lines.
ElectricalProject _project({
  required double feederM,
  required int ways,
  required double wayM,
  double wayW = 1500,
  double? wayCableMm2,
  Current? feederBreakerA,
  bool reversed = false,
}) {
  final mdp = ElectricalPanel(
    id: 'MDP',
    name: 'Main',
    system: ElectricalSystem.threePhase,
    voltage: const Voltage(400),
    circuits: [
      ElectricalCircuit(
        id: 'f1',
        name: 'Feeder to SP',
        loadKind: LoadKind.feeder,
        length: Length(feederM),
        feedsPanelId: 'SP',
        breakerOverrideA: feederBreakerA,
      ),
    ],
  );
  final sp = ElectricalPanel(
    id: 'SP',
    name: 'Sub',
    system: ElectricalSystem.threePhase,
    voltage: const Voltage(400),
    sourceType: PanelSource.feeder,
    fedByCircuitId: 'f1',
    circuits: [
      for (var i = 0; i < ways; i++)
        ElectricalCircuit(
          id: 'l$i',
          name: 'Lighting $i',
          loadKind: LoadKind.lighting,
          isLighting: true,
          loadW: wayW,
          cosPhi: 0.9,
          phases: 1,
          length: Length(wayM),
          cableOverrideMm2: i == 0 ? wayCableMm2 : null,
        ),
    ],
  );
  final panels = [mdp, sp];
  return ElectricalProject(
    id: 'pr',
    name: 'B-2',
    earthingSystem: EarthingSystem.tnS,
    panels: reversed
        ? [
            for (final p in panels.reversed)
              p.copyWith(circuits: p.circuits.reversed.toList()),
          ]
        : panels,
  );
}

void main() {
  group('one long feeder, one failing 30 m lighting way: the way grows', () {
    // SP: one 1500 W lighting way, 1500 / (231 × 0.9) = 7.215 A, incomer
    // 10 A. Its feeder (3φ, 130 m) floors to 1.6 × 10 ⇒ 16 A (B-1) and is
    // held for ADS at 6 mm²: √3 × 7.215 × 130 × (3.69 × 0.9 + 0.08 ×
    // 0.4359) / 1000 = 5.45 V = 1.36 %. The way on 1.5 mm²: 2 × 7.215 × 30 ×
    // (14.5 × 0.9 + 0.0349) / 1000 = 5.665 V / 231 = 2.45 % (within 3 %),
    // cumulative 3.81 % > 3 %.
    // Scores (Δ% / Δmm²·m·loaded cores): the way 1.5 → 2.5 saves 2.45 × (1 −
    // 8.018 / 13.085) = 0.949 % for 1 × 30 × 2 = 60 ⇒ 0.0158; the feeder
    // 6 → 10 saves 1.36 × (1 − 2.006 / 3.356) = 0.547 % for 4 × 130 × 4 =
    // 2080 ⇒ 0.00026. The way wins: 2.5 mm², 1.50 %, cumulative 2.86 %.
    final project = _project(feederM: 130, ways: 1, wayM: 30);
    final sys = computeSystem(_p, project);
    final f = _way(sys, 'MDP', 'f1');
    final w = _way(sys, 'SP', 'l0');

    test('the way is raised, the feeder is not', () {
      expect(f.cable.csaMm2, 6);
      expect(f.voltageDrop.dropPercent, closeTo(1.36, 1e-9));
      expect(f.cableRaisedForDownstreamVd, isFalse);
      expect(w.cable.csaMm2, 2.5);
      expect(w.cableRaisedForCumulativeVd, isTrue);
      expect(w.voltageDrop.dropPercent, closeTo(1.50, 1e-9));
      expect(w.cumulativeDropPercent, closeTo(2.86, 1e-9));
      expect(sys.warnings.map((x) => x.code),
          isNot(contains('cumulative-voltage-drop-exceeded')));
    });

    test('order-independent', () {
      final r = computeSystem(
          _p, _project(feederM: 130, ways: 1, wayM: 30, reversed: true));
      expect(_way(r, 'SP', 'l0').cable.csaMm2, w.cable.csaMm2);
      expect(_way(r, 'MDP', 'f1').cable.csaMm2, f.cable.csaMm2);
    });
  });

  test('a user-fixed final way is never grown and keeps its finding', () {
    // The same way with its cable set by the engineer (1.5 mm²): it is not
    // a candidate, and (the T3 rule) only auto-sized ways drive a feeder
    // raise, so the cumulative 3.81 % stays reported.
    final sys = computeSystem(
        _p, _project(feederM: 130, ways: 1, wayM: 30, wayCableMm2: 1.5));
    final w = _way(sys, 'SP', 'l0');
    expect(w.cable.csaMm2, 1.5);
    expect(w.cableRaisedForCumulativeVd, isFalse);
    expect(_way(sys, 'MDP', 'f1').cableRaisedForDownstreamVd, isFalse);
    expect(sys.warnings.map((x) => x.code),
        contains('cumulative-voltage-drop-exceeded'));
  });

  group('many failing ways under one feeder: the summed saving picks it', () {
    // 60 × 500 W lighting ways (2.405 A each, 20 per line ⇒ 48.1 A), 30 m on
    // 1.5 mm²: 2 × 2.405 × 30 × 13.085 / 1000 = 1.888 V / 231 = 0.82 %. The
    // feeder (90 m, device fixed at 50 A so no selectivity floor applies):
    // Iz ≥ max(50, 1.25 × 48.1 = 60.1) ⇒ 16 mm² (Iz 68), √3 × 48.1 × 90 ×
    // (1.38 × 0.9 + 0.0349) / 1000 = 9.575 V = 2.39 % ⇒ cumulative 3.21 %
    // on all 60 ways.
    // Scores: a way 1.5 → 2.5 saves 0.82 × (1 − 8.018 / 13.085) = 0.317 %
    // for 60 ⇒ 0.0053; the feeder 16 → 25 saves 2.39 × (1 − 0.8179 /
    // 1.2769) = 0.859 % on EACH of the 60 ways (Σ 51.5 %) for 9 × 90 × 4 =
    // 3240 ⇒ 0.0159. The feeder wins: 25 mm², 1.53 %, cumulative 2.35 %.
    final project = _project(
        feederM: 90,
        ways: 60,
        wayM: 30,
        wayW: 500,
        feederBreakerA: const Current(50));
    final sys = computeSystem(_p, project);

    test('the feeder is raised once, no way is', () {
      final f = _way(sys, 'MDP', 'f1');
      expect(f.cable.csaMm2, 25);
      expect(f.cableRaisedForDownstreamVd, isTrue);
      expect(f.voltageDrop.dropPercent, closeTo(1.53, 1e-9));
      for (final w in sys.panels['SP']!.circuits) {
        expect(w.cable.csaMm2, 1.5, reason: w.circuitId);
        expect(w.cableRaisedForCumulativeVd, isFalse, reason: w.circuitId);
        expect(w.cumulativeDropPercent, closeTo(2.35, 1e-9),
            reason: w.circuitId);
      }
    });

    test('order-independent', () {
      final r = computeSystem(
          _p,
          _project(
              feederM: 90,
              ways: 60,
              wayM: 30,
              wayW: 500,
              feederBreakerA: const Current(50),
              reversed: true));
      expect(_way(r, 'MDP', 'f1').cable.csaMm2, 25);
      for (var i = 0; i < 60; i++) {
        expect(_way(r, 'SP', 'l$i').cable.csaMm2, 1.5);
      }
    });
  });
}
