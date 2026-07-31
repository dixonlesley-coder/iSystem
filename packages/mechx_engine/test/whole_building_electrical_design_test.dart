/// WHOLE-BUILDING ELECTRICAL DESIGN — an acceptance exercise + bug hunt.
///
/// A complete, realistic electrical design for a mid-size Indonesian office
/// (3 storeys, PLN 3φ 400 V LV service at the 197 kVA "daya tersambung" class,
/// TN-C-S earthing, a standby genset backing an essential board, a declared
/// capacitor bank) is pushed through the engine's PUBLIC API —
/// `computeSystem` + `computeAdvancedStudy` + the four `SldSheet` builders —
/// and then interrogated the way a reviewing senior engineer would read the
/// issued set:
///
///   1. every circuit is coordinated (Ib > 0, In ≥ Ib, Iz ≥ In, Vd in limit,
///      PE sized);
///   2. every feeder's CONDUCTOR is sized on its own load and its DEVICE lifts
///      toward the 1.6× discrimination target only as far as that conductor's
///      ampacity permits (audit E3/E4) — with the residuals that policy leaves
///      behind enumerated, not hidden;
///   3. phase balance is sane, a `phase-imbalance` warning fires ONLY when the
///      imbalance is genuinely reducible, and an irreducible one is still
///      NOTED (audit E7);
///   4. the fault study takes its origin from the DECLARED service size, every
///      device breaking capacity is adequate, ADS clears on every TN run, and
///      the findings that DO fire are exactly the enumerated, explained ones;
///   5. the demand aggregates add up root-to-leaf and sit inside the declared
///      connection capacity;
///   6. magnitudes an Indonesian engineer checks on sight (a ~2 kW lighting way
///      at ~9 A on a 10 A MCB curve B; an 11 kW 3φ motor at ~21 A on a 25 A
///      curve D; the MDP incomer off the headroom-uplifted demand);
///   7. the project round-trips through `toJson`/`fromJson` and recomputes
///      IDENTICALLY.
///
/// The topology (7 boards, 38 ways):
///
///   PLN 197 kVA -> MDP (3φ 400 V, 20 % headroom)
///     |- LP-1  3φ  lighting + sockets, floor 1
///     |- LP-2  3φ  lighting + sockets, floor 2
///     |- LP-3  1φ 220 V  lighting + sockets, floor 3 (a small board, mixed by
///     |                  design so the 1φ-sub-board-from-a-3φ-parent path runs)
///     |- PP-1  3φ  workshop sockets, water heaters, compressor, transfer pump
///     |- AC-1  3φ  AHUs on VFDs, condensing unit, splits, exhaust fans
///     `- EP-1  3φ  ESSENTIAL: fire pump + jockey (FRC, life-safety), lift, EM
///                  lighting, staircase pressurisation fan
///
/// Hand-derived values carry their arithmetic in a comment; orchestration-level
/// expectations are re-derived from the engine's OWN primitives (`loadCurrent`,
/// `voltageDrop`, `selectBreaker`) rather than pinned to magic numbers, per the
/// repo convention. Everything a reviewer would merely QUESTION (rather than
/// call wrong) is printed, not asserted — see the `REPORT` tests at the bottom.
library;

import 'package:mechx_engine/electrical/advanced_study.dart';
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/control/starter.dart';
import 'package:mechx_engine/electrical/earthing.dart';
import 'package:mechx_engine/electrical/fault.dart';
import 'package:mechx_engine/electrical/headroom.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/panel_results.dart';
import 'package:mechx_engine/electrical/sizing.dart';
import 'package:mechx_engine/electrical/sources.dart';
import 'package:mechx_engine/report/electrical_sld_drawing.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

// ───────────────────────────────────────────────────────────────────────────
// The design.
// ───────────────────────────────────────────────────────────────────────────

/// A lighting final circuit — NYM in conduit, 3 % drop limit, curve B.
ElectricalCircuit _lighting(String id, String name, double w, double m) =>
    ElectricalCircuit(
      id: id,
      name: name,
      loadW: w,
      cosPhi: 0.9,
      length: Length(m),
      loadKind: LoadKind.lighting,
      isLighting: true,
      cableType: 'NYM',
    );

/// A socket (stop-kontak) final circuit — NYM, 0.7 utilisation, curve C.
ElectricalCircuit _socket(String id, String name, double w, double m,
        {int points = 6}) =>
    ElectricalCircuit(
      id: id,
      name: name,
      loadW: w,
      points: points,
      cosPhi: 0.9,
      length: Length(m),
      loadKind: LoadKind.socket,
      demandFactor: 0.7,
      cableType: 'NYM',
    );

/// An MDP outgoing feeder to a sub-board — NYY.
ElectricalCircuit _feeder(String id, String name, String child, double m) =>
    ElectricalCircuit(
      id: id,
      name: name,
      length: Length(m),
      loadKind: LoadKind.feeder,
      cableType: 'NYY',
      feedsPanelId: child,
    );

ElectricalProject buildOfficeProject() {
  final lp1 = ElectricalPanel(
    id: 'lp1',
    name: 'Lighting Panel L1',
    tag: 'LP-1',
    ambientTempC: 35,
    groupingCount: 3,
    diversityFactor: 0.9,
    sourceType: PanelSource.feeder,
    headroom: const HeadroomSpec(sparePercentage: 20, spareWays: 3),
    circuits: [
      _lighting('lp1-l1', 'Lighting zone A', 1800, 35),
      _lighting('lp1-l2', 'Lighting zone B', 1600, 40),
      _lighting('lp1-l3', 'Lighting corridor', 1200, 28),
      _socket('lp1-s1', 'Sockets zone A', 3000, 30),
      _socket('lp1-s2', 'Sockets zone B', 3000, 34),
      _socket('lp1-s3', 'Pantry sockets', 2200, 22, points: 4),
    ],
  );

  final lp2 = ElectricalPanel(
    id: 'lp2',
    name: 'Lighting Panel L2',
    tag: 'LP-2',
    ambientTempC: 35,
    groupingCount: 3,
    diversityFactor: 0.9,
    sourceType: PanelSource.feeder,
    headroom: const HeadroomSpec(sparePercentage: 20, spareWays: 3),
    circuits: [
      _lighting('lp2-l1', 'Lighting zone A', 1900, 38),
      _lighting('lp2-l2', 'Lighting zone B', 1500, 42),
      _lighting('lp2-l3', 'Lighting corridor', 1200, 30),
      _socket('lp2-s1', 'Sockets zone A', 3200, 32),
      _socket('lp2-s2', 'Sockets zone B', 2800, 36),
      _socket('lp2-s3', 'Meeting rooms sockets', 2400, 26, points: 5),
    ],
  );

  // Top floor: a small SINGLE-PHASE 220 V board off the 3φ MDP — the mixed
  // system real Indonesian projects use for a light top floor.
  final lp3 = ElectricalPanel(
    id: 'lp3',
    name: 'Lighting Panel L3',
    tag: 'LP-3',
    system: ElectricalSystem.singlePhase,
    voltage: const Voltage(220),
    ambientTempC: 35,
    groupingCount: 3,
    diversityFactor: 0.9,
    sourceType: PanelSource.feeder,
    headroom: const HeadroomSpec(sparePercentage: 20, spareWays: 2),
    circuits: [
      _lighting('lp3-l1', 'Lighting open plan', 1400, 30),
      _lighting('lp3-l2', 'Lighting corridor', 1000, 24),
      _socket('lp3-s1', 'Sockets open plan', 2600, 28),
      _socket('lp3-s2', 'Pantry sockets', 2000, 20, points: 4),
    ],
  );

  const pp1 = ElectricalPanel(
    id: 'pp1',
    name: 'Power Panel',
    tag: 'PP-1',
    ambientTempC: 35,
    groupingCount: 4,
    diversityFactor: 0.85,
    sourceType: PanelSource.feeder,
    headroom: const HeadroomSpec(sparePercentage: 25, spareWays: 4),
    circuits: [
      const ElectricalCircuit(
        id: 'pp1-wk',
        name: 'Workshop sockets 3ph',
        loadW: 6000,
        points: 3,
        cosPhi: 0.9,
        length: Length(28),
        loadKind: LoadKind.socket,
        demandFactor: 0.7,
        phases: 3,
        cableType: 'NYY',
      ),
      const ElectricalCircuit(
        id: 'pp1-wh1',
        name: 'Water heater P1',
        loadW: 4500,
        cosPhi: 1.0,
        length: Length(30),
        loadKind: LoadKind.heating,
        cableType: 'NYM',
      ),
      const ElectricalCircuit(
        id: 'pp1-wh2',
        name: 'Water heater P2',
        loadW: 4500,
        cosPhi: 1.0,
        length: Length(34),
        loadKind: LoadKind.heating,
        cableType: 'NYM',
      ),
      const ElectricalCircuit(
        id: 'pp1-cmp',
        name: 'Air compressor',
        motorKw: 11,
        cosPhi: 0.85,
        length: Length(24),
        loadKind: LoadKind.motor,
        cableType: 'NYY',
        starterType: StarterType.starDelta,
      ),
      const ElectricalCircuit(
        id: 'pp1-tp',
        name: 'Transfer pump',
        motorKw: 5.5,
        cosPhi: 0.85,
        length: Length(40),
        loadKind: LoadKind.pump,
        cableType: 'NYY',
        starterType: StarterType.dol,
      ),
    ],
  );

  const ac1 = ElectricalPanel(
    id: 'ac1',
    name: 'AC Panel',
    tag: 'AC-1',
    ambientTempC: 35,
    groupingCount: 4,
    diversityFactor: 0.9,
    sourceType: PanelSource.feeder,
    headroom: const HeadroomSpec(sparePercentage: 20, spareWays: 3),
    circuits: [
      const ElectricalCircuit(
        id: 'ac1-ahu1',
        name: 'AHU-1 ducted',
        loadW: 7500,
        cosPhi: 0.85,
        length: Length(30),
        loadKind: LoadKind.hvac,
        demandFactor: 0.9,
        cableType: 'NYY',
        starterType: StarterType.vfd,
      ),
      const ElectricalCircuit(
        id: 'ac1-ahu2',
        name: 'AHU-2 ducted',
        loadW: 7500,
        cosPhi: 0.85,
        length: Length(36),
        loadKind: LoadKind.hvac,
        demandFactor: 0.9,
        cableType: 'NYY',
        starterType: StarterType.vfd,
      ),
      const ElectricalCircuit(
        id: 'ac1-cu1',
        name: 'Condensing unit CU-1',
        loadW: 5200,
        cosPhi: 0.85,
        length: Length(42),
        loadKind: LoadKind.hvac,
        demandFactor: 0.9,
        cableType: 'NYY',
      ),
      const ElectricalCircuit(
        id: 'ac1-sp1',
        name: 'Split AC office A',
        loadW: 2500,
        cosPhi: 0.85,
        length: Length(26),
        loadKind: LoadKind.hvac,
        demandFactor: 0.9,
        cableType: 'NYM',
      ),
      const ElectricalCircuit(
        id: 'ac1-sp2',
        name: 'Split AC office B',
        loadW: 2500,
        cosPhi: 0.85,
        length: Length(32),
        loadKind: LoadKind.hvac,
        demandFactor: 0.9,
        cableType: 'NYM',
      ),
      const ElectricalCircuit(
        id: 'ac1-ef',
        name: 'Toilet exhaust fans',
        loadW: 1500,
        cosPhi: 0.85,
        length: Length(45),
        loadKind: LoadKind.hvac,
        demandFactor: 0.9,
        cableType: 'NYM',
      ),
    ],
  );

  const ep1 = ElectricalPanel(
    id: 'ep1',
    name: 'Essential Panel',
    tag: 'EP-1',
    ambientTempC: 35,
    groupingCount: 3,
    diversityFactor: 1.0,
    sourceType: PanelSource.feeder,
    essential: true,
    headroom: const HeadroomSpec(sparePercentage: 25, spareWays: 3),
    circuits: [
      const ElectricalCircuit(
        id: 'ep1-fp',
        name: 'Fire pump',
        motorKw: 15,
        cosPhi: 0.85,
        length: Length(35),
        loadKind: LoadKind.pump,
        lifeSafety: true,
        cableType: 'FRC',
        starterType: StarterType.starDelta,
      ),
      const ElectricalCircuit(
        id: 'ep1-jp',
        name: 'Jockey pump',
        motorKw: 3.7,
        cosPhi: 0.85,
        length: Length(35),
        loadKind: LoadKind.pump,
        lifeSafety: true,
        cableType: 'FRC',
        starterType: StarterType.dol,
      ),
      const ElectricalCircuit(
        id: 'ep1-lift',
        name: 'Lift motor',
        motorKw: 11,
        cosPhi: 0.85,
        length: Length(28),
        loadKind: LoadKind.motor,
        cableType: 'NYY',
        starterType: StarterType.vfd,
      ),
      const ElectricalCircuit(
        id: 'ep1-el',
        name: 'Emergency lighting',
        loadW: 1500,
        cosPhi: 0.9,
        length: Length(48),
        loadKind: LoadKind.lighting,
        isLighting: true,
        lifeSafety: true,
        cableType: 'FRC',
      ),
      const ElectricalCircuit(
        id: 'ep1-sf',
        name: 'Staircase pressurisation fan',
        loadW: 4000,
        cosPhi: 0.85,
        length: Length(40),
        loadKind: LoadKind.hvac,
        lifeSafety: true,
        cableType: 'FRC',
      ),
    ],
  );

  final mdp = ElectricalPanel(
    id: 'mdp',
    name: 'Main Distribution Panel',
    tag: 'MDP',
    ambientTempC: 35,
    groupingCount: 6,
    diversityFactor: 0.9,
    headroom: const HeadroomSpec(sparePercentage: 20, spareWays: 2),
    circuits: [
      _feeder('mdp-f-lp1', 'Feeder LP-1', 'lp1', 24),
      _feeder('mdp-f-lp2', 'Feeder LP-2', 'lp2', 30),
      _feeder('mdp-f-lp3', 'Feeder LP-3', 'lp3', 36),
      _feeder('mdp-f-pp1', 'Feeder PP-1', 'pp1', 22),
      _feeder('mdp-f-ac1', 'Feeder AC-1', 'ac1', 26),
      _feeder('mdp-f-ep1', 'Feeder EP-1', 'ep1', 20),
    ],
  );

  return ElectricalProject(
    id: 'office3',
    name: 'Gedung Kantor 3 Lantai',
    earthingSystem: EarthingSystem.tnCs,
    supplyKind: SupplyKind.pln,
    // Daya tersambung 197 kVA — the top of the PLN low-voltage (TR) ladder.
    supplyCapacityVa: const ApparentPower(197000),
    capacitorBankKvar: 30,
    occupancy: 'office',
    sources: const ElectricalSources(
      generator: GeneratorSource(
        backupFraction: 0.45,
        mode: GeneratorMode.standby,
        transfer: GeneratorTransfer.ats,
      ),
    ),
    panels: [mdp, lp1, lp2, lp3, pp1, ac1, ep1],
  );
}

// ───────────────────────────────────────────────────────────────────────────
// Helpers.
// ───────────────────────────────────────────────────────────────────────────

ElectricalCircuitResult _way(ElectricalPanelResult p, String id) =>
    p.circuits.firstWhere((c) => c.circuitId == id);

/// Every (panel, way) pair in the solved system.
Iterable<(ElectricalPanelResult, ElectricalCircuitResult)> _allWays(
    ElectricalSystemResult sys) sync* {
  for (final id in sys.order) {
    final p = sys.panels[id]!;
    for (final c in p.circuits) {
      yield (p, c);
    }
  }
}

/// The child panel each feeder way supplies (feeder circuit id → panel id).
Map<String, String> _feederTargets(ElectricalProject project) => {
      for (final p in project.panels)
        for (final c in p.circuits)
          if (c.feedsPanelId != null) c.id: c.feedsPanelId!,
    };

/// Reconstruct a board schedule's TEXT rows from an `SldSheet`: labels grouped
/// by their y ordinate, left-to-right. Reporting only — never asserted on.
List<String> _scheduleRows(SldSheet sheet) {
  final byY = <int, List<SldLabel>>{};
  for (final p in sheet.prims) {
    if (p is SldLabel) (byY[p.y.round()] ??= []).add(p);
  }
  final ys = byY.keys.toList()..sort();
  return [
    for (final y in ys)
      (byY[y]!..sort((a, b) => a.x.compareTo(b.x)))
          .map((l) => l.text)
          .join('  |  '),
  ];
}

void main() {
  const profile = PuilProfile();

  final project = buildOfficeProject();
  final feederTargets = _feederTargets(project);

  // The DECLARED-service fault estimate is what the app's Fold-1 chain resolves
  // (explicit originFaultLevelA → this estimate → the flat 16 kA default), so
  // the busbar withstand and the printed device kA share one basis.
  final originFault = estimatedServiceFaultLevelA(project);

  final sys = computeSystem(
    profile,
    project,
    originFaultLevel: originFault,
    busbarClearingTimeS: 0.1,
  );
  // No explicit originFaultLevel — the advanced study must resolve the SAME
  // 10 kA through its own chain (that equality is asserted below).
  final advanced = computeAdvancedStudy(profile, project, sys);

  final everyWarning = <ElectricalWarning>[
    ...sys.warnings,
    ...advanced.fault.warnings,
  ];

  // ── 0. the solve itself ──────────────────────────────────────────────────
  group('0 — the design solves', () {
    test('every panel is sized and ordered root-first', () {
      expect(sys.order.first, 'mdp');
      expect(sys.order.toSet(),
          {'mdp', 'lp1', 'lp2', 'lp3', 'pp1', 'ac1', 'ep1'});
      expect(sys.panels.length, 7);
      // 6 MDP feeders + 6 + 6 + 4 + 5 + 6 + 5 branch ways = 38.
      expect(_allWays(sys).length, 38);
    });

    test('the supply is a 3φ 400 V TN-C-S service', () {
      expect(sys.supply.system, ElectricalSystem.threePhase);
      expect(sys.supply.voltage.volts, 400);
      expect(sys.earthing.system, EarthingSystem.tnCs);
    });

    test('the single-phase top-floor board is fed by a single-phase feeder', () {
      // A feeder follows the system of the panel it FEEDS, even from a 3φ parent.
      expect(sys.panels['lp3']!.system, ElectricalSystem.singlePhase);
      expect(sys.panels['lp3']!.incomer.poles, 2);
      expect(_way(sys.panels['mdp']!, 'mdp-f-lp3').threePhase, isFalse);
      expect(_way(sys.panels['mdp']!, 'mdp-f-lp1').threePhase, isTrue);
    });
  });

  // ── 1. per-circuit coordination ──────────────────────────────────────────
  group('1 — every circuit is coordinated', () {
    test('Ib > 0 on every load-bearing way', () {
      for (final (p, c) in _allWays(sys)) {
        expect(c.designCurrent.amperes, greaterThan(0),
            reason: '${p.name} / ${c.name} carries no design current');
      }
    });

    test('In >= Ib (the device carries the load)', () {
      for (final (p, c) in _allWays(sys)) {
        expect(c.breaker.ratingA.amperes,
            greaterThanOrEqualTo(c.designCurrent.amperes),
            reason: '${p.name} / ${c.name}: In ${c.breaker.ratingA.amperes} A '
                '< Ib ${c.designCurrent.amperes} A');
      }
    });

    test('Iz >= In and the ampacity was actually reached (In <= Iz)', () {
      // PUIL cl 2.2.8.3 / IEC 60364-4-43: Ib <= In <= Iz. `ampacityReached` is
      // false only on the terminal fallback where no section met Iz.
      for (final (p, c) in _allWays(sys)) {
        expect(c.cable.ampacityReached, isTrue,
            reason: '${p.name} / ${c.name}: ${c.cable.appliedRule}');
        expect(c.cable.deratedIz.amperes,
            greaterThanOrEqualTo(c.breaker.ratingA.amperes),
            reason: '${p.name} / ${c.name}: Iz ${c.cable.deratedIz.amperes} A '
                '< In ${c.breaker.ratingA.amperes} A');
        // And Iz also clears the PUIL 125 % continuous-load floor.
        expect(c.cable.deratedIz.amperes,
            greaterThanOrEqualTo(1.25 * c.designCurrent.amperes - 1e-6),
            reason: '${p.name} / ${c.name}: Iz below 1.25*Ib');
      }
    });

    test('every run holds its OWN voltage-drop limit', () {
      for (final (p, c) in _allWays(sys)) {
        expect(c.voltageDrop.withinLimit, isTrue,
            reason: '${p.name} / ${c.name}: ${c.voltageDrop.dropPercent}% '
                '> ${c.voltageDrop.limitPercent}%');
        expect(c.voltageDrop.limitPercent, c.name.contains('ighting') ? 3 : 5);
      }
    });

    test('the CUMULATIVE chain over-runs on exactly two long lighting runs', () {
      // Re-derived 2026-07-30 (audit E3). `sizeCable` holds each run inside its
      // OWN limit; the cumulative origin→load chain is a separate, judge-only
      // check. It used to pass here only because the old selectivity floor
      // inflated the feeders' copper (LP-2's feeder was 35 mm², LP-3's 50 mm²),
      // which incidentally shrank the upstream share. With the conductor back at
      // its load size the two longest 3 %-limited lighting runs cross the line —
      // a REAL design finding on this fixture, and exactly what the warning is
      // for. Both are named, with their arithmetic:
      //   LP-3 "Lighting open plan": 2.52 % (30 m on 1.5 mm² at 220 V) +
      //     1.08 % (the 36 m / 16 mm² single-phase feeder) = 3.60 % > 3 %;
      //   LP-2 "Lighting zone A":    2.41 % (42 m on 2.5 mm² at 231 V) +
      //     0.66 % (the 30 m / 6 mm² three-phase feeder)   = 3.07 % > 3 %.
      final feederIds = feederTargets.keys.toSet();
      final over = <String>[];
      for (final (p, c) in _allWays(sys)) {
        if (feederIds.contains(c.circuitId)) continue; // sub-bus, not a load
        if (c.cumulativeDropPercent > c.voltageDrop.limitPercent + 1e-9) {
          over.add('${p.panelId}/${c.circuitId}');
        }
      }
      expect(over.toSet(), {'lp3/lp3-l1', 'lp2/lp2-l1'});
      expect(_way(sys.panels['lp3']!, 'lp3-l1').cumulativeDropPercent, 3.6);
      expect(_way(sys.panels['lp2']!, 'lp2-l1').cumulativeDropPercent, 3.07);
      // Each is surfaced, once, as a locatable warning.
      final w = everyWarning
          .where((w) => w.code == 'cumulative-voltage-drop-exceeded')
          .toList();
      expect(w.map((x) => x.circuitId).toSet(), {'lp3-l1', 'lp2-l1'});
    });

    test('the drop the engine prints is the drop its own primitive computes',
        () {
      // Re-derive one run from `voltageDrop` itself rather than a magic number:
      // LP-2 "Lighting zone A", 1φ on a 3φ board ⇒ 231 V, 2.5 mm², 38 m.
      final c = _way(sys.panels['lp2']!, 'lp2-l1');
      final again = voltageDrop(
        profile,
        current: c.designCurrent,
        length: Length(c.lengthM),
        csaMm2: c.cable.csaMm2,
        cosPhi: 0.9,
        threePhase: false,
        voltage: const Voltage(231),
        isLighting: true,
      );
      // The solve uses the UNROUNDED Ib; designCurrent is rounded to 0.1 A, so
      // allow a hair of slack rather than pretending to bit-equality.
      expect(again.dropPercent, closeTo(c.voltageDrop.dropPercent, 0.02));
      expect(again.limitPercent, 3.0);
    });

    test('every way carries a sized PE conductor', () {
      for (final (p, c) in _allWays(sys)) {
        expect(c.grounding.peCsaMm2, greaterThan(0),
            reason: '${p.name} / ${c.name} has no PE');
        // IEC 60364-5-54 §543: PE = S up to 16 mm², then >= S/2.
        if (c.cable.csaMm2 <= 16) {
          expect(c.grounding.peCsaMm2, greaterThanOrEqualTo(c.cable.csaMm2));
        } else {
          expect(c.grounding.peCsaMm2,
              greaterThanOrEqualTo(c.cable.csaMm2 / 2 - 1e-9));
        }
      }
    });

    test('socket finals get a 30 mA RCD; life-safety runs deliberately do not',
        () {
      // TN-C-S: additional protection on socket outlets (30 mA); a life-safety
      // run is RCD-exempt (availability prevails).
      expect(_way(sys.panels['lp1']!, 'lp1-s1').rcd.required, isTrue);
      expect(_way(sys.panels['lp1']!, 'lp1-s1').rcd.ratingMa, 30);
      expect(_way(sys.panels['ep1']!, 'ep1-fp').rcd.required, isFalse);
      // A lighting final is not a socket ⇒ no RCD required on TN.
      expect(_way(sys.panels['lp1']!, 'lp1-l1').rcd.required, isFalse);
    });

    test('life-safety runs are all FRC (no life-safety-cable warning)', () {
      expect(everyWarning.where((w) => w.code == 'life-safety-cable'), isEmpty);
    });
  });

  // ── 2. feeders ───────────────────────────────────────────────────────────
  group('2 — every feeder is load-sized, and lifts only as far as it may', () {
    test('the CONDUCTOR is never inflated for discrimination (E3)', () {
      // The one-line guard: a feeder conductor carries what its own design
      // current asks for, within a single section step. Under the old policy
      // PP-1's 42.9 A feeder took 150 mm² (Iz/Ib > 3) purely to carry a floored
      // 160 A device.
      final mdp = sys.panels['mdp']!;
      for (final c in mdp.circuits) {
        expect(c.cable.deratedIz.amperes / c.designCurrent.amperes,
            lessThan(1.6),
            reason: '${c.name}: Iz ${c.cable.deratedIz.amperes} A on '
                '${c.cable.csaMm2} mm2 for Ib ${c.designCurrent.amperes} A');
      }
    });

    test('the DEVICE sits at the largest rung its conductor protects', () {
      // The floor targets 1.6 × the fed board's incomer; where the load-sized
      // cable cannot carry that rung the device stops at the cap — but it does
      // reach the cap, so the lift is real wherever there is headroom:
      //   LP-1 16 -> 20 A (Iz 23.6), LP-3 32 -> 40 A (Iz 42.9),
      //   AC-1 40 -> 50 A (Iz 56.3), EP-1 63 -> 80 A (Iz 85.7);
      //   LP-2 (20 A) and PP-1 (50 A) were already at their cap.
      final mdp = sys.panels['mdp']!;
      final ladder = profile.standardBreakerRatingsA;
      for (final entry in feederTargets.entries) {
        final feeder = _way(mdp, entry.key);
        final inA = feeder.breaker.ratingA.amperes;
        final izA = feeder.cable.deratedIz.amperes;
        // In ≤ Iz — the conductor is always protected.
        expect(inA, lessThanOrEqualTo(izA), reason: feeder.name);
        // ... and it is the LARGEST such rung: the next rung up would exceed Iz.
        final largestUnderIz = ladder.where((r) => r <= izA).last;
        expect(inA, largestUnderIz,
            reason: '${feeder.name}: In $inA A vs the cap $izA A');
      }
      expect(mdp.circuits.every((c) => !c.breaker.overridden), isTrue);
      // Not one feeder could reach its full 1.6× target on this design.
      expect(sys.feederFloorsApplied, isEmpty);
    });

    test('RESIDUAL: none of the six pairs reaches 1.6x, and all six are '
        'reported', () {
      // Feeder In / fed-board incomer:
      //   LP-1 20/25 = 0.80   LP-2 20/25 = 0.80   LP-3 40/40 = 1.00
      //   PP-1 50/80 = 0.63   AC-1 50/63 = 0.79   EP-1 80/100 = 0.80
      // All below 1.6 ⇒ `non-selective`, which is NEVER suppressed. Buying
      // discrimination here would mean paying for it in copper, which is exactly
      // the trade the E3 policy refuses; the honest fixes on paper are a breaker
      // override with a matching cable, an MCCB with settings, or a smaller
      // fed-board incomer.
      expect(advanced.fault.selectivity.length, 6);
      for (final s in advanced.fault.selectivity) {
        expect(s.nonSelective, isTrue,
            reason: '${s.upstreamCircuitId} -> ${s.downstreamPanelId}');
        expect(s.upstreamRatingA / s.downstreamRatingA,
            lessThan(selectivityRatio));
        // Breaking capacity / service capacity / bus withstand all still pass.
        expect(s.icuAdequate, isTrue);
        expect(s.icsAdequate, isTrue);
        expect(s.icwAdequate, isTrue);
      }
      expect(
          everyWarning.where((w) => w.code == 'non-selective').length, 6);
      // Nothing was floored to target, so nothing is suppressed either.
      expect(everyWarning.where((w) => w.code == 'selectivity-partial'),
          isEmpty);
    });

    test('RESIDUAL: one feeder rounds below its board worst-phase demand', () {
      // A feeder's Ib is the fed board's diversified demand W converted at a
      // BALANCED power factor; the board's incomer is its WORST-PHASE current.
      // PP-1's imbalance is inherent (37.9 %, two equal 1φ heaters), so those
      // two figures diverge: 42.9 A vs 58.0 A. The load-sized 50 A feeder
      // therefore sits below what PP-1 draws on L1/L2 — a real finding the old
      // copper-inflating floor used to mask, raised (never resized) by the
      // judge-only check.
      final mdp = sys.panels['mdp']!;
      final below = <String>[];
      for (final entry in feederTargets.entries) {
        final feeder = _way(mdp, entry.key);
        final child = sys.panels[entry.value]!;
        if (feeder.breaker.ratingA.amperes < child.demandCurrent.amperes) {
          below.add(entry.key);
        }
      }
      expect(below, ['mdp-f-pp1']);
      expect(_way(mdp, 'mdp-f-pp1').breaker.ratingA.amperes, 50);
      expect(sys.panels['pp1']!.demandCurrent.amperes, 58.0);
      final w = everyWarning
          .where((w) => w.code == 'feeder-below-fed-demand')
          .toList();
      expect(w.map((x) => x.circuitId), ['mdp-f-pp1']);
      // The message offers the achievable action, not "rebalance".
      expect(w.single.message, contains('inherent'));
      expect(w.single.message, contains('raise the feeder rating'));
    });
  });

  // ── 3. phase balance ─────────────────────────────────────────────────────
  group('3 — phase balance', () {
    test('a single-phase board loads L1 only, with zero imbalance', () {
      final lp3 = sys.panels['lp3']!;
      expect(lp3.phaseBalance.l2, 0);
      expect(lp3.phaseBalance.l3, 0);
      expect(lp3.imbalancePercent, 0);
    });

    test('the well-mixed lighting boards balance under 15 %', () {
      for (final id in ['lp1', 'lp2', 'ac1', 'ep1', 'mdp']) {
        expect(sys.panels[id]!.imbalancePercent,
            lessThanOrEqualTo(kPhaseImbalanceWarnPercent),
            reason: '${sys.panels[id]!.name} imbalance');
      }
    });

    test('PP-1 IS imbalanced — and the engine correctly calls it irreducible',
        () {
      // PP-1 carries three 3φ ways (workshop sockets 6.7 A, compressor 21.2 A,
      // transfer pump 10.6 A = 38.5 A on EVERY line) plus exactly TWO 1φ water
      // heaters at 4500 W / 231 V / cosφ 1.0 = 19.48 A -> 19.5 A each.
      //   best possible split of {19.5, 19.5} over three lines = one each on two
      //   lines, nothing on the third ⇒ spread 19.5 A;
      //   lines = 38.5+19.5 / 38.5+19.5 / 38.5 = 58.0 / 58.0 / 38.5,
      //   average 51.5 A ⇒ imbalance 19.5/51.5 = 37.86 % -> 37.9 %.
      // Two equal single-phase ways can NEVER load three lines evenly, so the
      // imbalance is inherent: reducible == false and no warning fires.
      final pp1 = sys.panels['pp1']!;
      expect(pp1.phaseBalance.l1, 58.0);
      expect(pp1.phaseBalance.l2, 58.0);
      expect(pp1.phaseBalance.l3, 38.5);
      expect(pp1.imbalancePercent, 37.9);
      expect(pp1.imbalancePercent,
          greaterThan(kPhaseImbalanceWarnPercent)); // over the reporting limit
      expect(pp1.phaseBalance.imbalanceReducible, isFalse);
      // The achievable floor equals the actual spread — nothing to act on.
      expect(minimumPhaseSpreadA(const [19.5, 19.5]), closeTo(19.5, 1e-9));
    });

    test('no phase-imbalance warning anywhere (none is reducible)', () {
      expect(everyWarning.where((w) => w.code == 'phase-imbalance'), isEmpty);
      for (final id in sys.order) {
        final p = sys.panels[id]!;
        if (p.phaseBalance.imbalanceReducible) {
          fail('${p.name} reports a reducible imbalance but no warning fired');
        }
      }
    });

    test('FIXED (E7): the irreducible imbalance is NOTED, with a real action',
        () {
      // The 37.9 % used to appear only on the schedule TOTAL footer. It is now
      // an INFO note that names the figure, says why redistribution cannot help,
      // and offers the action that can (a third leg / a 3-phase appliance).
      // Exactly one board qualifies: PP-1 at 37.9 % (MDP sits at 15.0 %, which
      // is NOT over the strict `> 15 %` limit; every other board is under).
      final notes = everyWarning
          .where((w) => w.code == 'phase-imbalance-inherent')
          .toList();
      expect(notes.map((w) => w.panelId), ['pp1']);
      expect(notes.single.severity, WarningSeverity.info);
      expect(notes.single.message, contains('37.9%'));
      expect(notes.single.message, contains('inherent to the single-phase'));
      expect(notes.single.message, contains('third leg'));
      expect(sys.panels['mdp']!.imbalancePercent, 15.0); // at, not over
    });

    test('the worst-loaded phase is what the incomer is sized against', () {
      final pp1 = sys.panels['pp1']!;
      expect(pp1.demandCurrent.amperes, 58.0); // max(58, 58, 38.5)
      // 25 % headroom: 58.0 x 1.25 = 72.5 A -> first rung >= 72.5 is 80 A.
      expect(pp1.futureLoadW, (pp1.demandW * 1.25).roundToDouble());
      expect(pp1.incomer.breaker.ratingA.amperes, 80);
      expect(pp1.headroomApplied, isTrue);
      expect(pp1.spareWaysReserved, 4);
    });
  });

  // ── 4. fault study ───────────────────────────────────────────────────────
  group('4 — fault study', () {
    test('the origin fault comes from the DECLARED 197 kVA service', () {
      // 197 000 VA is exactly the PLN TR ceiling ⇒ the `lvServiceFaultKa` rung.
      expect(originFault, isNotNull);
      expect(originFault!.amperes, lvServiceFaultKa * 1000); // 10 000 A
      // The advanced study, given NO explicit level, resolves the same chain.
      expect(advanced.fault.originFaultkA, 10.0);
    });

    test('every device breaking capacity covers its prospective fault', () {
      for (final (p, c) in _allWays(sys)) {
        final f = advanced.fault.circuits[c.circuitId];
        expect(f, isNotNull, reason: '${p.name} / ${c.name} missing from study');
        expect(f!.breakerAdequate, isTrue,
            reason: '${p.name} / ${c.name}: Icu ${f.breakerKa} kA vs '
                '${f.faultkA} kA');
        expect(f.breakerKa, greaterThanOrEqualTo(f.faultkA));
      }
      for (final id in sys.order) {
        final f = advanced.fault.panels[id]!;
        expect(f.incomerAdequate, isTrue, reason: id);
      }
    });

    test('every busbar withstands the fault at its own bus', () {
      for (final id in sys.order) {
        final p = sys.panels[id]!;
        expect(p.busbar.withstand, isNotNull, reason: '$id has no withstand');
        expect(p.busbar.withstand!.adequate, isTrue,
            reason: '${p.name}: Icw ${p.busbar.withstand!.icwKa} kA vs '
                '${p.busbar.withstand!.faultKa} kA');
        for (final s in p.busbarSections) {
          expect(s.busbar.withstand?.adequate, isTrue, reason: '${p.name} sec');
        }
      }
    });

    test('ADS disconnects in time on every TN circuit (Zs <= Zs_max)', () {
      for (final (p, c) in _allWays(sys)) {
        final f = advanced.fault.circuits[c.circuitId]!;
        // TN-C-S ⇒ the loop is modelled, so Zs / adsOk must be present.
        expect(f.zsOhm, isNotNull, reason: '${p.name} / ${c.name}');
        expect(f.adsOk, isTrue,
            reason: '${p.name} / ${c.name}: Zs ${f.zsOhm} > '
                'Zs_max ${f.zsMaxOhm}');
        expect(f.zsOhm!, lessThanOrEqualTo(f.zsMaxOhm!));
      }
      expect(everyWarning.where((w) => w.code == 'ads-disconnection'), isEmpty);
      expect(
          everyWarning.where((w) => w.code == 'tt-no-earth-fault-protection'),
          isEmpty);
    });

    test('NO ERRORS: nothing error-severity fires anywhere', () {
      final bad = everyWarning
          .where((w) => w.severity == WarningSeverity.error)
          .map((w) => '${w.severity.name} ${w.code}: ${w.message}')
          .toList();
      expect(bad, isEmpty, reason: bad.join('\n'));
    });

    test('the findings are EXACTLY the enumerated, explained residuals', () {
      // Re-derived 2026-07-30 (audit E3/E4/E6/E7). The design was previously
      // "clean" only because the selectivity floor bought discrimination with
      // conductor copper, which also shrank the upstream voltage-drop share.
      // With copper back at the load size the honest finding set is:
      //
      //   warning  non-selective                  x6  every MDP feeder — the
      //            ampacity cap holds the device below 1.6x the fed incomer
      //            (group 2 derives each ratio);
      //   warning  cumulative-voltage-drop-exceeded x2  LP-3 / LP-2's longest
      //            3 %-limited lighting runs (group 1 derives both sums);
      //   warning  feeder-below-fed-demand         x1  PP-1, whose inherent
      //            37.9 % imbalance splits demand-W from worst-phase-A;
      //   info     fire-pump-protection            x2  the FRC fire + jockey
      //            pumps (E6 — a specification note, no sizing change);
      //   info     phase-imbalance-inherent        x1  PP-1 (E7).
      //
      // Nothing else, and in particular NO `selectivity-partial`: nothing
      // reached its floor target, so nothing is suppressed and nothing is
      // advisory-only either.
      final byCode = <String, int>{};
      for (final w in everyWarning) {
        byCode[w.code] = (byCode[w.code] ?? 0) + 1;
      }
      expect(byCode, {
        'non-selective': 6,
        'cumulative-voltage-drop-exceeded': 2,
        'feeder-below-fed-demand': 1,
        'fire-pump-protection': 2,
        'phase-imbalance-inherent': 1,
      });
      expect(everyWarning.length, 12);
      for (final w in everyWarning) {
        expect(
          w.severity,
          w.code.startsWith('fire-pump') || w.code.startsWith('phase-imbalance')
              ? WarningSeverity.info
              : WarningSeverity.warning,
          reason: w.code,
        );
      }
    });
  });

  // ── 5. demand aggregation ────────────────────────────────────────────────
  group('5 — demand aggregation', () {
    test('MDP connected load == the sum of its children diversified demands',
        () {
      final mdp = sys.panels['mdp']!;
      final childSum = ['lp1', 'lp2', 'lp3', 'pp1', 'ac1', 'ep1']
          .fold(0.0, (s, id) => s + sys.panels[id]!.demandW);
      expect(mdp.connectedW, closeTo(childSum, 1.0));
      // MDP's own 0.9 diversity then gives the origin demand.
      expect(mdp.demandW, closeTo(childSum * 0.9, 1.0));
      expect(sys.totalDemandW, mdp.demandW);
    });

    test('the building connected load counts LEAF loads only (no feeder '
        'double-counting)', () {
      var leaves = 0.0;
      for (final p in project.panels) {
        for (final c in p.circuits) {
          if (c.feedsPanelId == null) leaves += circuitConnectedW(c);
        }
      }
      expect(sys.supply.connectedW, closeTo(leaves, 1.0));
      // ... and the diversified demand is genuinely below it.
      expect(sys.supply.demandW, lessThan(sys.supply.connectedW));
    });

    test('demand VA sits inside the declared 197 kVA connection capacity', () {
      // demandVa = demandW / assumedBuildingPf (0.85).
      expect(sys.supply.demandVa.voltAmperes,
          closeTo(sys.totalDemandW / assumedBuildingPf, 1.0));
      expect(sys.supply.demandVa.voltAmperes,
          lessThan(project.supplyCapacityVa!.voltAmperes));
      // The recommended PLN daya step also fits under the declared capacity.
      expect(advanced.recommendedDayaVa,
          lessThanOrEqualTo(project.supplyCapacityVa!.voltAmperes));
      // The supply stays an LV (TR) service — no fabricated MV substation.
      expect(advanced.supply.transformerKva, isNull);
    });

    test('no service-capacity / Ics inadequacy is raised on this declaration',
        () {
      expect(everyWarning.where((w) => w.code == 'service-capacity-inadequate'),
          isEmpty);
    });
  });

  // ── 6. magnitudes an engineer checks on sight ────────────────────────────
  group('6 — magnitude spot checks (hand-derived)', () {
    test('a ~1.9 kW lighting way is ~9 A on a 10 A MCB curve B', () {
      // 1φ way on a 3φ 400 V board ⇒ U = round(400/sqrt3) = 231 V.
      // Ib = 1900 / (231 x 0.90) = 9.138 A -> printed 9.1 A.
      // Ladder 6 10 16 ... ⇒ first rung >= 9.138 is 10 A, MCB (<= 63 A),
      // curve B (lighting).
      final c = _way(sys.panels['lp2']!, 'lp2-l1');
      expect(c.designCurrent.amperes, 9.1);
      expect(c.breaker.ratingA.amperes, 10);
      expect(c.breaker.deviceClass, BreakerClass.mcb);
      expect(c.breaker.curve, BreakerCurve.b);
      expect(c.threePhase, isFalse);
      // Cross-check against the engine's own primitive.
      expect(
        loadCurrent(
                power: const Power(1900),
                voltage: const Voltage(231),
                cosPhi: 0.9,
                threePhase: false)
            .amperes,
        closeTo(9.139, 0.002),
      );
    });

    test('an 11 kW 3φ motor is ~21 A on a 25 A MCB curve D', () {
      // Shaft 11 kW / 0.88 assumed efficiency = 12.5 kW electrical input.
      // Ib = 12500 / (sqrt3 x 400 x 0.85) = 12500 / 588.897 = 21.23 A -> 21.2.
      // First rung >= 21.23 is 25 A; motor ⇒ curve D.
      final c = _way(sys.panels['pp1']!, 'pp1-cmp');
      expect(c.designCurrent.amperes, 21.2);
      expect(c.breaker.ratingA.amperes, 25);
      expect(c.breaker.curve, BreakerCurve.d);
      expect(c.threePhase, isTrue);
      // The lift motor is the same machine on EP-1 — same answer.
      expect(_way(sys.panels['ep1']!, 'ep1-lift').breaker.ratingA.amperes, 25);
    });

    test('a 15 kW 3φ fire pump is ~29 A on a 32 A curve D, FRC-cabled', () {
      // 15 / 0.88 = 17.045 kW ⇒ 17045 / 588.897 = 28.94 A -> 28.9 A ⇒ 32 A.
      final c = _way(sys.panels['ep1']!, 'ep1-fp');
      expect(c.designCurrent.amperes, 28.9);
      expect(c.breaker.ratingA.amperes, 32);
      expect(c.breaker.curve, BreakerCurve.d);
      // FRC sizes on the 90 degC (XLPE) class, not the panel PVC default.
      expect(c.cable.csaMm2, 10.0);
      expect(c.cable.deratedIz.amperes, greaterThanOrEqualTo(32));
    });

    test('a 3.7 kW pump goes three-phase; motors below 3 kW would not', () {
      // motorThreePhaseKw = 3 ⇒ 3.7 kW jockey pump is 3φ (no impractical
      // single-phase-large-motor warning anywhere).
      expect(_way(sys.panels['ep1']!, 'ep1-jp').threePhase, isTrue);
      expect(everyWarning.where((w) => w.code == 'single-phase-large-motor'),
          isEmpty);
    });

    test('the MDP incomer is the headroom-uplifted worst-phase demand', () {
      final mdp = sys.panels['mdp']!;
      // Re-derived 2026-07-30 (audit E8a): LP-3 is a 220 V single-phase board,
      // so its feeder now converts LP-3's 5058 W demand at 220 V rather than the
      // 3φ parent's 231 V phase voltage — 5058/(220 × 0.85) = 27.05 A instead of
      // 25.75 A, i.e. +1.2 A on the worst-loaded line. MDP's worst phase reads
      // 198.2 A (was 197.0).
      // Worst phase 198.2 A x 1.20 headroom = 237.84 A ⇒ first rung >= 237.84
      // is 250 A ⇒ MCCB (> 63 A), 4-pole on a 3φ board.
      expect(mdp.demandCurrent.amperes, 198.2);
      expect(mdp.incomer.breaker.ratingA.amperes, 250);
      expect(mdp.incomer.breaker.deviceClass, BreakerClass.mccb);
      expect(mdp.incomer.poles, 4);
      expect(
        selectBreaker(profile,
                designCurrent: const Current(237.84), loadKind: LoadKind.feeder)
            .ratingA
            .amperes,
        250,
      );
      // The main bus is rated for the incoming device, not merely the demand.
      expect(mdp.busbar.ampacityA.amperes, greaterThanOrEqualTo(250));
      // Linear board ⇒ the neutral bar is NOT triplen-oversized.
      expect(mdp.neutralPeBars.neutralOversizeFactor, 1.0);
      expect(mdp.neutralPeBars.neutralCsaMm2, mdp.busbar.csaMm2);
    });

    test('every breaker frame matches its rating (MCB <= 63 A, else MCCB)', () {
      for (final (p, c) in _allWays(sys)) {
        expect(c.breaker.deviceClass,
            c.breaker.ratingA.amperes <= 63 ? BreakerClass.mcb : BreakerClass.mccb,
            reason: '${p.name} / ${c.name}');
      }
    });

    test('every conductor is a standard section on the PUIL ladder', () {
      for (final (p, c) in _allWays(sys)) {
        expect(profile.standardSectionsMm2, contains(c.cable.csaMm2),
            reason: '${p.name} / ${c.name}');
        // 3φ trunk minimum 4 mm2; lighting final minimum 1.5 mm2.
        expect(c.cable.csaMm2, greaterThanOrEqualTo(1.5));
      }
      for (final entry in feederTargets.keys) {
        expect(_way(sys.panels['mdp']!, entry).cable.csaMm2,
            greaterThanOrEqualTo(4.0));
      }
    });
  });

  // ── 7. round-trip ────────────────────────────────────────────────────────
  group('7 — JSON round-trip', () {
    final back = ElectricalProject.fromJson(buildOfficeProject().toJson());
    final sys2 = computeSystem(
      profile,
      back,
      originFaultLevel: estimatedServiceFaultLevelA(back),
      busbarClearingTimeS: 0.1,
    );
    final advanced2 = computeAdvancedStudy(profile, back, sys2);

    test('the project fields survive the trip', () {
      expect(back.supplyKind, SupplyKind.pln);
      expect(back.supplyCapacityVa!.voltAmperes, 197000);
      expect(back.capacitorBankKvar, 30);
      expect(back.earthingSystem, EarthingSystem.tnCs);
      expect(back.occupancy, 'office');
      expect(back.sources!.generator!.backupFraction, 0.45);
      expect(back.sources!.generator!.transfer, GeneratorTransfer.ats);
      expect(back.panels.length, 7);
      expect(back.panels.first.headroom!.sparePercentage, 20);
      final ep = back.panels.firstWhere((p) => p.id == 'ep1');
      expect(ep.essential, isTrue);
      expect(ep.circuits.first.lifeSafety, isTrue);
      expect(ep.circuits.first.cableType, 'FRC');
      expect(ep.circuits.first.starterType, StarterType.starDelta);
      expect(ep.circuits.first.motorKw, 15);
    });

    test('the recomputed system is identical, panel for panel', () {
      expect(sys2.order, sys.order);
      expect(sys2.totalDemandW, sys.totalDemandW);
      expect(sys2.supply.connectedW, sys.supply.connectedW);
      expect(sys2.supply.demandVa.voltAmperes, sys.supply.demandVa.voltAmperes);
      for (final id in sys.order) {
        final a = sys.panels[id]!;
        final b = sys2.panels[id]!;
        expect(b.demandW, a.demandW, reason: id);
        expect(b.demandCurrent.amperes, a.demandCurrent.amperes, reason: id);
        expect(b.incomer.breaker.ratingA.amperes,
            a.incomer.breaker.ratingA.amperes,
            reason: id);
        expect(b.busbar.csaMm2, a.busbar.csaMm2, reason: id);
        expect(b.busbar.withstand!.icwKa, a.busbar.withstand!.icwKa,
            reason: id);
        expect(b.imbalancePercent, a.imbalancePercent, reason: id);
        expect(b.neutralPeBars.peCsaMm2, a.neutralPeBars.peCsaMm2, reason: id);
      }
    });

    test('the recomputed system is identical, way for way', () {
      for (final id in sys.order) {
        final a = sys.panels[id]!;
        final b = sys2.panels[id]!;
        expect(b.circuits.length, a.circuits.length, reason: id);
        for (var i = 0; i < a.circuits.length; i++) {
          final x = a.circuits[i];
          final y = b.circuits[i];
          final where = '$id/${x.circuitId}';
          expect(y.designCurrent.amperes, x.designCurrent.amperes,
              reason: where);
          expect(y.breaker.ratingA.amperes, x.breaker.ratingA.amperes,
              reason: where);
          expect(y.breaker.curve, x.breaker.curve, reason: where);
          expect(y.cable.csaMm2, x.cable.csaMm2, reason: where);
          expect(y.cable.deratedIz.amperes, x.cable.deratedIz.amperes,
              reason: where);
          expect(y.voltageDrop.dropPercent, x.voltageDrop.dropPercent,
              reason: where);
          expect(y.cumulativeDropPercent, x.cumulativeDropPercent,
              reason: where);
          expect(y.phase, x.phase, reason: where);
          expect(y.grounding.peCsaMm2, x.grounding.peCsaMm2, reason: where);
          expect(y.lengthM, x.lengthM, reason: where);
        }
      }
    });

    test('the recomputed advanced study is identical', () {
      expect(advanced2.fault.originFaultkA, advanced.fault.originFaultkA);
      expect(advanced2.fault.warnings.length, advanced.fault.warnings.length);
      expect(advanced2.recommendedDayaVa, advanced.recommendedDayaVa);
      expect(advanced2.powerFactor.existingPf, advanced.powerFactor.existingPf);
      for (final e in advanced.fault.circuits.entries) {
        expect(advanced2.fault.circuits[e.key]!.breakerKa, e.value.breakerKa,
            reason: e.key);
        expect(advanced2.fault.circuits[e.key]!.zsOhm, e.value.zsOhm,
            reason: e.key);
      }
    });
  });

  // ── 8. the drawings ──────────────────────────────────────────────────────
  group('8 — the drawings build off the one solve', () {
    test('the full single-line carries every panel', () {
      final sheet = buildElectricalSld(project: project, result: sys);
      expect(sheet.isEmpty, isFalse);
      final texts = sheet.prims.whereType<SldLabel>().map((l) => l.text);
      for (final p in project.panels) {
        expect(texts.where((t) => t.contains(p.name)), isNotEmpty,
            reason: '${p.name} missing from the single-line');
      }
      expect(sheet.maxX, greaterThan(sheet.minX));
      expect(sheet.maxY, greaterThan(sheet.minY));
      expect(sheet.legend, isNotEmpty);
    });

    test('the per-panel detail is one board only, re-origined', () {
      final detail = buildElectricalPanelDetail(
          project: project, result: sys, panelId: 'mdp');
      final texts =
          detail.prims.whereType<SldLabel>().map((l) => l.text).toList();
      expect(texts.where((t) => t.contains('Main Distribution Panel')),
          isNotEmpty);
      expect(texts.where((t) => t.contains('Lighting Panel L1  [')), isEmpty);
      // One way row per outgoing circuit + the 2 reserved spare ways.
      expect(texts.where((t) => RegExp(r'^W\d+$').hasMatch(t)).length, 8);
      expect(texts.where((t) => t.contains('CADANGAN')).length, 2);
      // Every feeder row names the board it supplies.
      for (final p in ['Lighting Panel L1', 'Power Panel', 'Essential Panel']) {
        expect(texts.where((t) => t == '-> $p'), isNotEmpty, reason: p);
      }
      // The TOTAL footer carries the demand + the honest imbalance figure
      // (15.0 % since E8a lifted the LP-3 feeder onto the fed board's 220 V —
      // the printed token drops the trailing zero).
      expect(texts.where((t) => t.contains('TOTAL')).single,
          contains('imbalance 15%'));
    });

    test('every panel builds its own detail sheet without throwing', () {
      for (final id in sys.order) {
        final s = buildElectricalPanelDetail(
            project: project, result: sys, panelId: id);
        expect(s.isEmpty, isFalse, reason: id);
      }
      // An unknown panel id degrades to an empty sheet rather than throwing.
      expect(
        buildElectricalPanelDetail(
                project: project, result: sys, panelId: 'nope')
            .isEmpty,
        isTrue,
      );
    });

    test('the overview shows all 7 boards, EP-1 in the essential colour', () {
      final ov = buildElectricalOverview(
          project: project, result: sys, sourceChain: true);
      final labels = ov.prims.whereType<SldLabel>().toList();
      for (final p in project.panels) {
        expect(labels.where((l) => l.text.contains(p.name)), isNotEmpty,
            reason: p.name);
      }
      // Only the genset-backed board is drawn essential.
      final essentialNames = labels
          .where((l) => l.role == SldRole.essential && l.text.contains('['))
          .map((l) => l.text)
          .toList();
      expect(essentialNames.length, 1);
      expect(essentialNames.single, contains('EP-1'));
      // The source spine is honest about an LV (TR) service: the PLN head
      // carries the DECLARED capacity and there is no fabricated MV station.
      final texts = labels.map((l) => l.text).toList();
      expect(texts, contains('PLN 197 kVA'));
      expect(texts.where((t) => t.contains('MV STATION')), isEmpty);
      expect(texts.where((t) => t.startsWith('GENSET')), isNotEmpty);
      expect(texts, contains('CAPACITOR BANK'));
      expect(texts, contains('TN-C-S (PME)'));
    });

    test('the riser builds and annotates every feeder', () {
      final riser = buildElectricalRiser(
          project: project, result: sys, sourceChain: true);
      expect(riser.isEmpty, isFalse);
      final texts = riser.prims.whereType<SldLabel>().map((l) => l.text);
      for (final p in project.panels) {
        expect(texts.where((t) => t.contains(p.name)), isNotEmpty,
            reason: p.name);
      }
      // Each feeder annotation carries the real cable + breaker + length. The
      // heaviest feeder (EP-1) is now an MCCB 80 A on 50 mm² — under the old
      // copper-inflating floor this read `MCCB 160A 3ph` on 150 mm².
      expect(texts.where((t) => t.contains('NYY 5x50 mm2 · MCCB 80A 3ph')),
          isNotEmpty);
    });

    test('the source spine is non-empty for a declared service', () {
      expect(
        buildElectricalSourceSpine(project: project, result: sys).isEmpty,
        isFalse,
      );
      // A bare project (no sources, no demand) draws nothing new.
      const bare = ElectricalProject(id: 'x', name: 'x');
      final bareSys = computeSystem(profile, bare);
      expect(
        buildElectricalSourceSpine(project: bare, result: bareSys).isEmpty,
        isTrue,
      );
    });
  });

  // ── 9. documented findings (facts asserted, judgement REPORTED) ───────────
  group('9 — documented findings', () {
    test('FIXED (E1): the per-CIRCUIT kA map stamps each way its own rating',
        () {
      // WAS: `buildElectricalSld(breakerIcuKaByPanelId:)` took ONE kA per BOARD
      // (the fault study's `incomerKa`, snapped to the INCOMER's frame ladder)
      // and appended it to every way, so MDP's MCCB incomer stamped `16kA` on
      // its own MCB ways — a rating no MCB is built to.
      // NOW: `breakerKaByCircuitId` carries the fault study's per-way
      // `breakerKa` (each snapped to its OWN device class ladder) and WINS per
      // way; the panel map remains the fallback / incomer figure.
      final mdpFault = advanced.fault.panels['mdp']!;
      expect(mdpFault.prospectiveFaultkA, 10.0);
      expect(mdpFault.incomerKa, 16.0); // MCCB ladder: 16 25 36 50 70
      expect(advanced.fault.circuits['mdp-f-lp1']!.breakerKa, 10.0); // MCB
      // Re-derived 2026-07-30 (audit E3): with copper back at the load size the
      // PP-1 feeder is a 50 A MCB (was a floored 160 A MCCB), so the only MCCB
      // way left on MDP is the 80 A EP-1 feeder.
      expect(advanced.fault.circuits['mdp-f-ep1']!.breakerKa, 16.0); // MCCB
      expect(advanced.fault.circuits['mdp-f-pp1']!.breakerKa, 10.0); // now MCB
      expect(breakingCapacityKa[BreakerClass.mcb], isNot(contains(16.0)));

      final sheet = buildElectricalPanelDetail(
        project: project,
        result: sys,
        panelId: 'mdp',
        breakerIcuKaByPanelId: {
          for (final e in advanced.fault.panels.entries)
            e.key: e.value.incomerKa,
        },
        breakerKaByCircuitId: {
          for (final e in advanced.fault.circuits.entries)
            e.key: e.value.breakerKa,
        },
      );
      final devices = sheet.prims
          .whereType<SldLabel>()
          .map((l) => l.text)
          .where((t) => t.startsWith('MCB ') || t.startsWith('MCCB '))
          .toList();
      // MCB ways now carry the MCB-ladder 10 kA; the impossible token is gone.
      expect(devices, contains('MCB 50A 3ph 10kA'));
      expect(devices, isNot(contains('MCB 50A 3ph 16kA')));
      expect(devices.where((d) => d.startsWith('MCB ') && d.contains('16kA')),
          isEmpty);
      // The one MCCB way keeps the MCCB-ladder 16 kA. (E8b: the 1-phase LP-3
      // feeder off this 3-phase board is a 2-POLE device, so its token reads
      // `2P` — it is a 40 A MCB now that the floor no longer inflates it.)
      expect(devices, contains('MCCB 80A 3ph 16kA'));
      expect(devices, contains('MCB 40A 2P 10kA'));
      // The INCOMER sub-line still carries the board figure (the panel map).
      expect(
          sheet.prims.whereType<SldLabel>().map((l) => l.text).where(
              (t) => t.startsWith('Incomer ') && t.contains('MCCB 250A/4P 16kA')),
          isNotEmpty);
    });

    test('FINDING: the schedule conduit token contradicts the containment study',
        () {
      // `report/electrical_sld_drawing.dart` `_conduitMm` is a CSA ladder;
      // `electrical/containment.dart` sizes on an estimated cable OD + fill.
      // They still disagree on the SAME run. (Re-derived 2026-07-30: the E3
      // policy shrank the feeder conductors, so the specific rows moved — the
      // "tray vs 63 mm at 72 % fill" example is gone with the 150 mm² cable —
      // but the two bases contradict each other exactly as before. E2 is a
      // separate wave.)
      final sheet = buildElectricalPanelDetail(
          project: project, result: sys, panelId: 'mdp');
      final cables = sheet.prims
          .whereType<SldLabel>()
          .map((l) => l.text)
          .where((t) => t.startsWith('NYY '))
          .toList();
      final byName = {
        for (final cc in advanced.containment['mdp']!.conduits)
          cc.name: cc.conduit,
      };
      // 6 mm2 3φ feeder: schedule says PVC 32 mm, containment says 25 mm.
      expect(cables.where((c) => c.contains('5x6 mm2')).first,
          contains('PVC 32mm'));
      expect(byName['Feeder LP-1']!.conduitSizeMm, 25.0);
      // 25 mm2 feeder: schedule says PVC 50 mm, containment says 40 mm.
      expect(cables.where((c) => c.contains('5x25 mm2')).first,
          contains('PVC 50mm'));
      expect(byName['Feeder PP-1']!.conduitSizeMm, 40.0);
      // The two only happen to agree on the single-phase LP-3 run (32 mm).
      expect(cables.where((c) => c.contains('3x16 mm2')).first,
          contains('PVC 32mm'));
      expect(byName['Feeder LP-3']!.conduitSizeMm, 32.0);
      // And the ampacity that sized the cable used the CONDUIT reference
      // method (the panel default), not a tray method — a third basis.
      expect(project.panels.first.installMethod, CableInstallMethod.conduit);
    });

    test('FIXED (E3): the floor moves the DEVICE, never the feeder CABLE', () {
      // WAS: the floor lifted the feeder breaker to 1.6x the fed board's
      // incomer and `sizeCable` then had to satisfy Iz >= In, so the CONDUCTOR
      // inflated with it — PP-1, a board drawing 42.9 A, took a 160 A MCCB on
      // 150 mm2 NYY, and the 5 kW single-phase LP-3 board took an 80 A MCCB on
      // 3x50 mm2.
      // NOW: the cable sizes on the LOAD and the device floors only as far as
      // that cable's derated Iz protects (In <= Iz).
      final mdp = sys.panels['mdp']!;

      // PP-1 — Ib = 25 245/(sqrt3 x 400 x 0.85) = 42.87 A -> load rung 50 A.
      // Derating 0.94 (35 degC PVC) x 0.57 (grouping 6) = 0.5358;
      //   Iz >= max(50, 1.25 x 42.87 = 53.59): 16 mm2 -> 80 x 0.5358 = 42.9 no;
      //   25 mm2 -> 105 x 0.5358 = 56.3 yes.  Cap 56.3 -> largest rung 50 A, so
      //   the 1.6 x 80 = 128 -> 160 A target is out of reach and the device
      //   does not move at all.
      final pp1Feeder = _way(mdp, 'mdp-f-pp1');
      expect(pp1Feeder.designCurrent.amperes, 42.9);
      expect(pp1Feeder.breaker.ratingA.amperes, 50);
      expect(pp1Feeder.cable.csaMm2, 25.0);
      // 150 mm2 gave Iz/Ib > 3.0; 25 mm2 gives well under 1.5.
      expect(pp1Feeder.cable.deratedIz.amperes / pp1Feeder.designCurrent.amperes,
          lessThan(1.5));

      // LP-3 — 1-phase at the FED board's 220 V (E8a): Ib = 5058/(220 x 0.85)
      // = 27.05 A -> load rung 32 A; Iz >= max(32, 33.81): 10 mm2 -> 32.1 no,
      // 16 mm2 -> 42.9 yes. Cap 42.9 -> largest rung 40 A, so the device lifts
      // ONE rung (32 -> 40) toward the 1.6 x 40 = 64 -> 80 A target and stops.
      final lp3Feeder = _way(mdp, 'mdp-f-lp3');
      expect(lp3Feeder.threePhase, isFalse);
      expect(sys.panels['lp3']!.demandW, lessThan(6000));
      expect(lp3Feeder.breaker.ratingA.amperes, 40);
      expect(lp3Feeder.cable.csaMm2, 16.0);

      // Neither reached its target, so neither is claimed as floored.
      expect(sys.feederFloorsApplied, isEmpty);
    });

    test('FIXED (E5): a final socket way sizes on its UNDIVERSIFIED load', () {
      // WAS: `circuitConnectedW` folded `demandFactor` into the load before the
      // design current, so a socket way's own MCB/cable sized on the diversified
      // figure — LP-2 "Sockets zone B" (2.8 kW x 0.7 = 1960 W -> 9.43 A) landed
      // on a 10 A MCB beside a 3.0 kW neighbour on 16 A.
      // NOW: the DEVICE + CABLE size on the undiversified 2800 W
      //   Ib_size = 2800 / (231 x 0.9) = 13.47 A -> rung 16 A,
      // while the printed Ib and every demand figure keep the diversified
      // current (the utilisation factor is a coincidence factor across ways).
      final s = _way(sys.panels['lp2']!, 'lp2-s2');
      expect(s.loadW, closeTo(1960.0, 1e-6)); // still 2800 x 0.7 for aggregation
      expect(s.designCurrent.amperes, 9.4); // the operating current, unchanged
      expect(s.breaker.ratingA.amperes, 16);
      expect(s.cable.csaMm2, 4.0);
      // Its 3.0 kW neighbour now matches it — adjacent stop-kontak ways no
      // longer straddle rungs purely from a utilisation factor.
      expect(_way(sys.panels['lp1']!, 'lp1-s1').breaker.ratingA.amperes, 16);
      // Every socket final on the design lands on the uniform 16 A device.
      for (final (p, c) in _allWays(sys)) {
        if (c.loadKind != LoadKind.socket) continue;
        if (c.threePhase) continue; // PP-1's 3-phase workshop way is not a final
        expect(c.breaker.ratingA.amperes, 16, reason: '${p.name} / ${c.name}');
      }
      // A LIGHTING final is untouched (no demand factor, and not a socket).
      expect(_way(sys.panels['lp2']!, 'lp2-l1').breaker.ratingA.amperes, 10);
    });

    test('FIXED (E6): a life-safety pump carries a fire-pump protection note',
        () {
      // The SIZING is deliberately unchanged — the engine has no data for a
      // locked-rotor-rated fire-pump controller and will not fabricate one — but
      // the specification requirement is now carried on the schedule as an INFO
      // note instead of being silently absent.
      final fp = _way(sys.panels['ep1']!, 'ep1-fp');
      expect(fp.breaker.ratingA.amperes, 32);
      expect(fp.breaker.curve, BreakerCurve.d);
      expect(fp.rcd.required, isFalse);
      expect(fp.designCurrent.amperes * 6, lessThan(20 * 32));

      final notes =
          everyWarning.where((w) => w.code == 'fire-pump-protection').toList();
      // Both life-safety pumps on EP-1 (fire + jockey); the lift motor is NOT
      // life-safety and the FRC emergency-lighting way is not a motor.
      expect(notes.map((w) => w.circuitId).toSet(), {'ep1-fp', 'ep1-jp'});
      for (final n in notes) {
        expect(n.severity, WarningSeverity.info);
        expect(n.message, contains('overload-trip-disabled protection'));
        expect(n.message, contains('NFPA 20'));
      }
    });

    test('FIXED (E8a): a feeder drops at the FED board voltage', () {
      // WAS: the 1-phase LP-3 feeder computed Ib and Vd% at the 3-phase parent's
      // 231 V phase voltage while LP-3's own ways used 220 V — two bases mixed
      // into one cumulative chain.
      // NOW: Ib = 5058/(220 x 0.85) = 27.05 A -> 27.0 A, and the drop is a
      // percentage of 220 V. Cross-checked against the engine's own primitive.
      final f = _way(sys.panels['mdp']!, 'mdp-f-lp3');
      expect(f.designCurrent.amperes, 27.0);
      expect(
        loadCurrent(
                power: const Power(5058),
                voltage: const Voltage(220),
                cosPhi: 0.85,
                threePhase: false)
            .amperes,
        closeTo(27.05, 0.01),
      );
      final again = voltageDrop(
        profile,
        current: f.designCurrent,
        length: Length(f.lengthM),
        csaMm2: f.cable.csaMm2,
        cosPhi: 0.85,
        threePhase: false,
        voltage: const Voltage(220),
        isLighting: false,
      );
      expect(again.dropPercent, closeTo(f.voltageDrop.dropPercent, 0.02));
      // A 3-phase feeder to a 400 V board is untouched by the change.
      expect(_way(sys.panels['mdp']!, 'mdp-f-lp1').threePhase, isTrue);
      // And the cumulative chain LP-3's own ways inherit is that same base.
      expect(_way(sys.panels['lp3']!, 'lp3-l1').cumulativeDropPercent,
          closeTo(f.voltageDrop.dropPercent + 2.52, 0.011));
    });
  });

  // ── 10. reporting (no assertions) ────────────────────────────────────────
  group('10 — REPORT', () {
    test('MDP board schedule (buildElectricalPanelDetail labels)', () {
      final sheet = buildElectricalPanelDetail(
        project: project,
        result: sys,
        panelId: 'mdp',
        breakerIcuKaByPanelId: {
          for (final e in advanced.fault.panels.entries)
            e.key: e.value.incomerKa,
        },
      );
      final rows = _scheduleRows(sheet);
      // ignore: avoid_print
      print('\n===== MDP BOARD SCHEDULE (as issued) =====');
      for (final r in rows) {
        // ignore: avoid_print
        print(r);
      }
      // ignore: avoid_print
      print('===== ${rows.length} rows =====\n');
      expect(rows, isNotEmpty);
    });
  });
}
