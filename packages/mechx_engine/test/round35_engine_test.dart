// Round 35 (2026-10-18) — engine fixes, each with a first-principles
// derivation and a seeded property where it fits:
//   mech-props-4-stack-foot-reducer   no auto-sized gravity pipe is smaller
//       than a pipe discharging into it (IPC 704.2).
//   elec-core-2-daya-ignores-worst-phase   the recommended PLN daya covers
//       the worst-phase current the service-capacity judge reads.
//   elec-core-2-genset-ignores-worst-phase   the genset per-phase rating
//       covers the heaviest line of the backed boards.
// (regression-1, the air-unit riser datum, lives in run_vertical_leg_test.)
import 'dart:math' as math;

import 'package:mechx_engine/electrical/advanced_study.dart';
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/genset_backup.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/sources.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

const _p = PuilProfile();

NetNode _n(String id, double x, double y,
        {int floor = 0,
        NodeRole role = NodeRole.main,
        NodeComponent? component}) =>
    NetNode(
        id: id,
        sheetId: 's$floor',
        x: x,
        y: y,
        floorIndex: floor,
        role: role,
        component: component);

NetEdge _e(String id, String a, String b, ServiceType s,
        {EdgeKind kind = EdgeKind.run}) =>
    NetEdge(id: id, fromId: a, toId: b, service: s, kind: kind);

/// Every gravity edge is at least as large as every edge whose flow arrives
/// at its from-node (unless that node is a plant / mover / pit, where a
/// pumped force main legitimately starts smaller). Returns the violations.
List<String> _reducers(Network net, Map<String, EdgeSizing> s) {
  final out = <String>[];
  bool stop(String id) {
    final n = net.nodeById(id)!;
    return n.role == NodeRole.plant ||
        n.component == NodeComponent.pump ||
        n.component == NodeComponent.boosterSet ||
        n.component == NodeComponent.groundTank;
  }

  for (final e in net.edges) {
    final se = s[e.id];
    final from = se?.flowFromId;
    if (se == null || from == null || stop(from)) continue;
    for (final u in net.edges) {
      if (u.id == e.id || u.service != e.service) continue;
      final su = s[u.id];
      final uf = su?.flowFromId;
      if (su == null || uf == null) continue;
      final uTo = uf == u.fromId ? u.toId : u.fromId;
      if (uTo != from) continue;
      if (su.diameter.inMillimeters > se.diameter.inMillimeters + 1e-6) {
        out.add('${u.id} DN${su.diameter.inMillimeters.round()} -> '
            '${e.id} DN${se.diameter.inMillimeters.round()}');
      }
    }
  }
  return out;
}

void main() {
  group('mech-props-4: no reducer below an auto-sized stack', () {
    // GT (ground tank, L0) <- S0 <-riser- S1 <-riser- S2; lav (1 DFU) on L1
    // -> S1, kitchen sink (2 DFU) on L2 -> S2.
    //   stk2 carries 2 DFU -> stack table (2,40) -> DN40
    //   stk1 carries 3 DFU -> stack table (10,50) -> DN50
    //   drain S0 -> GT carries 3 DFU -> branch table (3,40) -> DN40 on its
    //   own: a reduction in the direction of flow. IPC 704.2 => DN50.
    final net = Network(nodes: [
      _n('GT', 400, 0,
          role: NodeRole.plant, component: NodeComponent.groundTank),
      _n('S0', 100, 0),
      _n('S1', 100, 0, floor: 1),
      _n('S2', 100, 0, floor: 2),
      _n('lav', 0, 0, floor: 1, role: NodeRole.fixture),
      _n('sink', 0, 0, floor: 2, role: NodeRole.fixture),
    ], edges: [
      _e('b2', 'sink', 'S2', ServiceType.drainage),
      _e('stk2', 'S2', 'S1', ServiceType.drainage, kind: EdgeKind.riser),
      _e('b1', 'lav', 'S1', ServiceType.drainage),
      _e('stk1', 'S1', 'S0', ServiceType.drainage, kind: EdgeKind.riser),
      _e('bd', 'S0', 'GT', ServiceType.drainage),
    ]);
    final s = autoSizeNetwork(net, const SizingContext(),
        leafDemand: const {},
        nodeDrainageUnits: const {'lav': 1, 'sink': 2});

    test('the 3-DFU stack is DN50 and the building drain follows it', () {
      expect(s['stk2']!.diameter.inMillimeters, closeTo(40, 1e-6));
      expect(s['stk1']!.diameter.inMillimeters, closeTo(50, 1e-6));
      expect(s['bd']!.diameter.inMillimeters, closeTo(50, 1e-6));
      expect(s['bd']!.stackRaisedForBranch, isTrue);
      expect(s['bd']!.belowCodeMinimum, isFalse);
      expect(_reducers(net, s), isEmpty);
    });

    test('a hand pick below the stack it receives is flagged, not resized',
        () {
      final o = autoSizeNetwork(net, const SizingContext(),
          leafDemand: const {},
          nodeDrainageUnits: const {'lav': 1, 'sink': 2},
          sizeOverrides: {'bd': Diameter.mm(40)});
      expect(o['bd']!.diameter.inMillimeters, closeTo(40, 1e-6));
      expect(o['bd']!.belowCodeMinimum, isTrue);
    });

    test('property: no auto reducer in 300 seeded drainage buildings', () {
      final rng = math.Random(3535);
      for (var trial = 0; trial < 300; trial++) {
        final nodes = <NetNode>[
          _n('GT', 900, 0,
              role: NodeRole.plant, component: NodeComponent.groundTank),
        ];
        final edges = <NetEdge>[];
        final dfu = <String, double>{};
        final floors = 2 + rng.nextInt(4);
        final stacks = 1 + rng.nextInt(2);
        var eid = 0;
        String e(String a, String b, {EdgeKind kind = EdgeKind.run}) {
          final id = 'e${eid++}';
          edges.add(_e(id, a, b, ServiceType.drainage, kind: kind));
          return id;
        }

        for (var st = 0; st < stacks; st++) {
          final x = 100.0 + st * 300;
          for (var f = 0; f < floors; f++) {
            nodes.add(_n('S${st}_$f', x, 0, floor: f));
            if (f > 0) {
              e('S${st}_$f', 'S${st}_${f - 1}', kind: EdgeKind.riser);
            }
            final fixtures = rng.nextInt(4);
            for (var k = 0; k < fixtures; k++) {
              final id = 'fx${st}_${f}_$k';
              nodes.add(_n(id, x - 50 - 10 * k, 20.0 * k,
                  floor: f, role: NodeRole.fixture));
              dfu[id] = [1.0, 2.0, 3.0, 4.0, 6.0][rng.nextInt(5)];
              // Sometimes through a bare branch junction.
              if (rng.nextBool()) {
                final j = 'J${st}_${f}_$k';
                nodes.add(_n(j, x - 25, 20.0 * k, floor: f));
                e(id, j);
                e(j, 'S${st}_$f');
              } else {
                e(id, 'S${st}_$f');
              }
            }
          }
          // Stack foot -> a collector junction -> the tank.
          nodes.add(_n('C$st', x + 50, 0));
          e('S${st}_0', 'C$st');
          if (st > 0) {
            e('C$st', 'C${st - 1}');
          }
        }
        e('C0', 'GT');
        final net = Network(nodes: nodes, edges: edges);
        final s = autoSizeNetwork(net, const SizingContext(),
            leafDemand: const {}, nodeDrainageUnits: dfu);
        expect(_reducers(net, s), isEmpty, reason: 'trial $trial');
      }
    });
  });

  ElectricalProject heaters(double w, List<PhaseLine?> lines,
          {double? declaredVa, ElectricalSources? sources}) =>
      ElectricalProject(
        supplyCapacityVa: declaredVa == null ? null : ApparentPower(declaredVa),
        sources: sources,
        panels: [
          ElectricalPanel(
            id: 'mdp',
            name: 'MDP',
            circuits: [
              for (var i = 0; i < lines.length; i++)
                ElectricalCircuit(
                  id: 'h$i',
                  name: 'Heater $i',
                  loadKind: LoadKind.heating,
                  loadW: w,
                  cosPhi: 1.0,
                  phases: 1,
                  length: const Length(10),
                  phaseOverride: lines[i],
                ),
            ],
          ),
        ],
      );

  group('elec-core-2: the recommended daya covers the worst phase', () {
    // 3φ 400 V root, two 1φ 5 kW heaters (cos φ 1) on L1 / L2:
    //   each Ib = 5000 / (400/√3) = 21.65 A ⇒ worst phase 21.6 A (0.1 A),
    //   demandVa = 10 000 VA (the balanced view ⇒ the 10 600 VA tier, a
    //   limiter of 10 600 / (√3·400) = 15.3 A — trips).
    //   Per-phase basis: √3·400·21.6 = 14 965 VA ⇒ the 16 500 VA tier
    //   (16 500 / (√3·400) = 23.8 A ≥ 21.6 A).
    test('2 x 5 kW 1φ heaters => 16 500 VA, and declaring it is clean', () {
      final p = heaters(5000, const [PhaseLine.l1, PhaseLine.l2]);
      final sys = computeSystem(_p, p);
      final worst = sys.panels['mdp']!.diversifiedDemandCurrent.amperes;
      // The engine carries the phase current at 0.1 A: 21.65 -> 21.6 A.
      expect(worst, closeTo(5000 / (400 / math.sqrt(3)), 0.06));
      final study = computeAdvancedStudy(_p, p, sys);
      expect(study.recommendedDayaVa, 16500);
      final sys2 = computeSystem(_p, heaters(5000, const [PhaseLine.l1, PhaseLine.l2],
          declaredVa: study.recommendedDayaVa));
      expect(
          sys2.warnings
              .followedBy(sys2.panels.values.expand((r) => r.warnings))
              .where((w) => w.code == 'service-capacity-below-demand'),
          isEmpty);
    });

    test('property: declaring the recommended daya never trips the judge', () {
      final rng = math.Random(35);
      for (var t = 0; t < 120; t++) {
        final n = 1 + rng.nextInt(5);
        final w = 500.0 + rng.nextInt(60) * 250;
        final lines = [
          for (var i = 0; i < n; i++)
            rng.nextInt(4) == 0 ? null : PhaseLine.values[rng.nextInt(3)],
        ];
        final p = heaters(w, lines);
        final study = computeAdvancedStudy(_p, p, computeSystem(_p, p));
        final daya = study.recommendedDayaVa;
        if (daya == null) continue; // beyond the LV catalogue
        final sys2 = computeSystem(_p, heaters(w, lines, declaredVa: daya));
        expect(
            sys2.panels.values
                .expand((r) => r.warnings)
                .followedBy(sys2.warnings)
                .where((x) => x.code == 'service-capacity-below-demand'),
            isEmpty,
            reason: 'trial $t: $n x $w W on $lines -> $daya VA');
      }
    });
  });

  group('elec-core-2: the genset per-phase rating covers the heaviest line',
      () {
    // Full-backup genset on a 3φ MDP with two 1φ 7 kW heaters (L1, L2):
    //   Ib = 7000 / 230.9 = 30.31 A on L1 and L2, 14 kVA / 14 kW in total.
    //   Balanced basis: max(14 kVA, 14 kW / 0.8 = 17.5 kVA) ⇒ the 20 kVA set,
    //   rated 20 000 / (√3·400) = 28.9 A per phase < 30.3 A.
    //   Per-phase basis: √3·400·30.31 = 21.0 kVA ⇒ the next rung above
    //   (25 kVA, 36.1 A per phase).
    const gen = ElectricalSources(generator: GeneratorSource());
    test('2 x 7 kW 1φ heaters => 21.0 kVA requirement => the 25 kVA rung', () {
      final p = heaters(7000, const [PhaseLine.l1, PhaseLine.l2], sources: gen);
      final sys = computeSystem(_p, p);
      final need = gensetBackupDemandVa(p, sys).voltAmperes;
      // The engine carries the phase current at 0.1 A (30.31 -> 30.3 A), so
      // the per-phase requirement is √3·400·30.3 = 20 992 VA ≈ 21.0 kVA.
      expect(need, closeTo(math.sqrt(3) * 400 * 30.3, 1));
      expect(need, greaterThan(17500 + 1));
      final g = sizeGenerator(gensetBackupDemandVa(p, sys),
          backupPower: gensetBackupDemandW(p, sys));
      expect(g.ratingKva.inKilovoltAmperes, greaterThanOrEqualTo(21.0));
      expect(lineCurrentPerPhase(g.ratingKva.voltAmperes),
          greaterThanOrEqualTo(30.3));
    });

    test('a balanced board is unchanged (per-phase basis == demand VA)', () {
      final p = heaters(7000, const [PhaseLine.l1, PhaseLine.l2, PhaseLine.l3],
          sources: gen);
      final sys = computeSystem(_p, p);
      expect(gensetBackupDemandVa(p, sys).voltAmperes,
          closeTo(sys.supply.demandVa.voltAmperes, 1));
    });

    test('a forced nameplate below the heaviest line is judged', () {
      final p = heaters(7000, const [PhaseLine.l1, PhaseLine.l2],
          sources: const ElectricalSources(
              generator: GeneratorSource(kva: ApparentPower(20000))));
      final w = gensetBackupWarnings(p, computeSystem(_p, p));
      expect(w.map((x) => x.code), contains('genset-phase-overload'));
      // The printed per-phase rating uses the SUPPLY's own system (3φ here):
      // 20 000 / (√3·400) = 28.87 A ⇒ '28.9 A' (never a hard-coded 3φ).
      final msg = w.firstWhere((x) => x.code == 'genset-phase-overload').message;
      expect(msg, contains('28.9 A'));
    });
  });
}

double lineCurrentPerPhase(double va) => va / (math.sqrt(3) * 400);
