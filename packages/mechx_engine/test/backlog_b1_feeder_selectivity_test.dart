/// Backlog B-1 (2026-11-13) — FEEDER DISCRIMINATION ON AN AUTO-SIZED CABLE.
///
/// The selectivity floor (feeder device ≥ 1.6 × the fed board's incomer) used
/// to move the DEVICE only, capped at the largest rung the load-sized cable's
/// Iz protects, so the app warned `non-selective` against its own auto-sized
/// pick. An AUTO-sized feeder cable (no cable override, one run per phase)
/// now steps up the section ladder until its Iz carries the floor's rung
/// (In ≤ Iz kept, ADS still met on every source), flagged
/// `cableRaisedForSelectivity`. A user-fixed cable never grows and keeps the
/// warning; a case the single-run ladder cannot reach keeps the load-sized
/// cable and the warning. BOUNDED (reviewer, 2026-11-13): at most two section
/// sizes, never a device above the feeder's own board incomer — the refusals
/// are pinned in electrical_feeder_floor_capped_test.dart (A1) / (A2).
///
/// Hand values from the `PuilProfile` tables: conduit = IEC B.52.4 B1 Cu/PVC
/// (4→28, 6→36, 10→50, 16→68, 25→89 A); R70 Ω/km 4→5.52, 6→3.69,
/// 10→2.19, 16→1.38, 25→0.87; X 0.08 Ω/km; breaker ladder 6 10 16 20 25 32
/// 40 50 63 | 80 100 …; continuous factor 1.25.
library;

import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/earthing.dart';
import 'package:mechx_engine/electrical/fault.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/panel_results.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

const _p = PuilProfile();

ElectricalCircuitResult _way(ElectricalSystemResult s, String panel, String id) =>
    s.panels[panel]!.circuits.firstWhere((c) => c.circuitId == id);

/// MDP (3φ) → SP (3φ), SP carrying one 3φ heater [loadW] at cos φ 1.0.
ElectricalProject _project({
  required double loadW,
  required double feederM,
  double? cableMm2,
  bool reversed = false,
}) {
  final mdp = ElectricalPanel(
    id: 'MDP',
    name: 'Main',
    system: ElectricalSystem.threePhase,
    voltage: const Voltage(400),
    circuits: [
      const ElectricalCircuit(
        id: 'spare',
        name: 'Heater MDP',
        loadKind: LoadKind.heating,
        loadW: 2000,
        cosPhi: 1.0,
        phases: 3,
        length: Length(5),
      ),
      ElectricalCircuit(
        id: 'f1',
        name: 'Feeder to SP',
        loadKind: LoadKind.feeder,
        cosPhi: 1.0,
        length: Length(feederM),
        feedsPanelId: 'SP',
        cableOverrideMm2: cableMm2,
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
      ElectricalCircuit(
        id: 's1',
        name: 'Heater',
        loadKind: LoadKind.heating,
        loadW: loadW,
        cosPhi: 1.0,
        phases: 3,
        length: const Length(10),
      ),
    ],
  );
  final panels = [mdp, sp];
  return ElectricalProject(
    id: 'pr',
    name: 'B-1',
    earthingSystem: EarthingSystem.tnS,
    // A declared 33 kVA 3φ service floors MDP's incomer at 47.6 A ⇒ 50 A, so
    // a 40 A feeder device stays under its own incomer (the bounded B-1
    // upstream rule).
    supplyCapacityVa: const ApparentPower(33000),
    panels: reversed
        ? [
            for (final p in panels.reversed)
              p.copyWith(circuits: p.circuits.reversed.toList()),
          ]
        : panels,
  );
}

void main() {
  group('an auto-sized feeder grows to the floor rung', () {
    // SP: 15 kW 3φ at cos φ 1 ⇒ Ib = 15 000 / (√3 × 400) = 21.65 A ⇒ SP
    // incomer 25 A. f1 carries the same 21.65 A ⇒ load-sized 25 A; Iz ≥
    // max(25, 1.25 × 21.65 = 27.06) ⇒ 4 mm² (Iz 28). Floor 1.6 × 25 = 40 A
    // ⇒ rung 40: 4 mm² 28 ✗, 6 mm² 36 ✗, 10 mm² 50 ✓ ⇒ 10 mm², MCB 40 A.
    final project = _project(loadW: 15000, feederM: 20);
    final sys = computeSystem(_p, project);
    final f = _way(sys, 'MDP', 'f1');

    test('10 mm2, 40 A, flagged, the floor applied', () {
      expect(sys.panels['SP']!.incomer.breaker.ratingA.amperes, 25);
      expect(f.cable.csaMm2, 10);
      expect(f.cable.deratedIz.amperes, 50);
      expect(f.cable.izRequired!.amperes, 40);
      expect(f.breaker.ratingA.amperes, 40);
      expect(f.cableRaisedForSelectivity, isTrue);
      expect(sys.feederFloorsApplied, {'f1'});
      // The final way below and the board demand are untouched.
      expect(_way(sys, 'SP', 's1').cableRaisedForSelectivity, isFalse);
      expect(sys.panels['SP']!.demandW, 15000);
    });

    test('no selectivity finding on the engine\'s own pick', () {
      final fs = faultStudy(sys, project, _p);
      expect(fs.selectivity.single.upstreamRatingA, 40);
      expect(fs.warnings.map((w) => w.code), isNot(contains('non-selective')));
    });

    test('order-independent: reversed panels and ways size the same', () {
      final r = computeSystem(
          _p, _project(loadW: 15000, feederM: 20, reversed: true));
      final g = _way(r, 'MDP', 'f1');
      expect(g.cable.csaMm2, f.cable.csaMm2);
      expect(g.breaker.ratingA.amperes, f.breaker.ratingA.amperes);
      expect(g.voltageDrop.dropPercent, f.voltageDrop.dropPercent);
      expect(g.cableRaisedForSelectivity, isTrue);
    });
  });

  test('a user-fixed cable never grows and keeps the warning', () {
    // The same board with the load-sized 4 mm² fixed: the device stops at
    // the largest rung Iz 28 protects, 25 A (ratio 1.0 ⇒ non-selective).
    final project = _project(loadW: 15000, feederM: 20, cableMm2: 4);
    final sys = computeSystem(_p, project);
    final f = _way(sys, 'MDP', 'f1');
    expect(f.cable.csaMm2, 4);
    expect(f.breaker.ratingA.amperes, 25);
    expect(f.cableRaisedForSelectivity, isFalse);
    expect(sys.feederFloorsCapped, {'f1'});
    expect(faultStudy(sys, project, _p).warnings.map((w) => w.code),
        contains('non-selective'));
  });

  test('ADS at the floored device grows the cable further, never caps it', () {
    // A 150 m feeder: its LOAD-sized cable is already 10 mm² (voltage
    // drop), whose Iz 50 carries the 40 A rung — but a C-curve 40 A needs
    // Zs ≤ 0.95 × 230 / (10 × 40) = 0.546 Ω and the loop is 0.843 Ω
    // (passing only the load-sized 25 A, 0.874 Ω). Before B-1 the Round-40
    // cap held the device at 25 A (non-selective); now the auto-sized cable
    // grows one rung: 16 mm² (PE 16) gives 0.533 Ω ≤ 0.546 ⇒ 40 A holds.
    final project = _project(loadW: 15000, feederM: 150);
    final sys = computeSystem(_p, project);
    final f = _way(sys, 'MDP', 'f1');
    final fs = faultStudy(sys, project, _p);
    expect(fs.circuits['f1']!.zsOhm, closeTo(0.533, 1e-9));
    expect(fs.circuits['f1']!.zsMaxOhm, closeTo(0.547, 1e-9));
    expect(f.breaker.ratingA.amperes, 40);
    expect(f.cableRaisedForSelectivity, isTrue);
    expect(f.cable.csaMm2, 16);
    expect(fs.circuits['f1']!.adsOk, isTrue);
    expect(fs.warnings.map((w) => w.code), isNot(contains('non-selective')));
  });
}
