// Round 19 (2026-10-18) — the engine half of the round-19 audit:
//
//   storm-raised-downpipe      a downpipe raised to its collector's bore is not
//                              flagged over-capacity when that collector
//                              carries the whole flow unsaturated
//   essential-name             life-safety-not-essential reads the SAME
//                              essential set (flag OR name) as the genset
//   non-essential-name         'NON ESENSIAL' / 'NON-ESSENTIAL' are not
//                              essential
import 'dart:math' as math;

import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/earthing.dart';
import 'package:mechx_engine/electrical/genset_backup.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/electrical_sld_drawing.dart' show cableLabel;
import 'package:mechx_engine/sizing/drainage_sizing.dart' as drain;
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/sizing/storm_sizing.dart' as storm;
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

NetNode _n(String id, double x, double y,
        {int floor = 0, NodeRole role = NodeRole.main, NodeComponent? c}) =>
    NetNode(
        id: id,
        sheetId: 's1',
        x: x,
        y: y,
        floorIndex: floor,
        role: role,
        component: c);

NetEdge _e(String id, String a, String b, {EdgeKind kind = EdgeKind.run}) =>
    NetEdge(
        id: id, fromId: a, toId: b, service: ServiceType.rainwater, kind: kind);

const _profile = PuilProfile();

void main() {
  // ── storm-raised-downpipe ─────────────────────────────────────────────────
  group('storm: a downpipe raised to its collector bore', () {
    // Roof drain R (floor 3) —collector c→ T —downpipe dp (riser)→ G —go→ out.
    final net = Network(nodes: [
      _n('R', 0, 0, floor: 3, role: NodeRole.fixture, c: NodeComponent.roofDrain),
      _n('T', 500, 0, floor: 3),
      _n('G', 500, 0),
      _n('out', 900, 0),
    ], edges: [
      _e('c', 'R', 'T'),
      _e('dp', 'T', 'G', kind: EdgeKind.riser),
      _e('go', 'G', 'out'),
    ]);

    Map<String, EdgeSizing> size(double lps, double slope) => autoSizeNetwork(
        net, SizingContext(drainageSlope: slope),
        leafDemand: {ServiceType.rainwater: FlowRate.litersPerSecond(lps)});

    test('66 L/s at 2 %: DN300 downpipe, raised, NOT over capacity', () {
      final s = size(66, 0.02);
      // Table top: DN200 carries 65 L/s, so 66 L/s saturates the table.
      expect(storm.sizeRainwaterDownpipe(FlowRate.litersPerSecond(66))
          .overCapacity, isTrue);
      // The collector is Manning part-full: half-full DN300 at 2 %, n 0.010
      //   Q_full = (1/n)·A·R^(2/3)·S^0.5
      //          = 100 × 0.07069 × 0.075^(2/3) × 0.02^0.5 ≈ 0.178 m3/s,
      //   half-full ≈ 89 L/s ≥ 66 L/s (DN250 half-full ≈ 55 L/s < 66).
      final qFull = 100 *
          (math.pi * 0.3 * 0.3 / 4) *
          math.pow(0.075, 2 / 3) *
          math.sqrt(0.02);
      expect(qFull / 2, greaterThan(0.066));
      final g = drain.sizeForFlow(
          flow: FlowRate.litersPerSecond(66),
          slope: 0.02,
          fillRatio: 0.5,
          manningN: 0.010);
      expect(s['c']!.diameter.inMillimeters, g.diameter.inMillimeters);
      expect(s['c']!.overCapacity, isFalse);
      // The downpipe is raised to the collector bore that carries the flow ⇒
      // the table-top flag no longer applies.
      expect(s['dp']!.stackRaisedForBranch, isTrue);
      expect(s['dp']!.diameter.inMillimeters, g.diameter.inMillimeters);
      expect(s['dp']!.overCapacity, isFalse);
    });

    test('66 L/s at 1 %: the collector itself saturates ⇒ the flag stays', () {
      final s = size(66, 0.01);
      expect(s['c']!.overCapacity, isTrue);
      expect(s['dp']!.overCapacity, isTrue);
    });

    test('property: never flagged when the collector carries it unsaturated',
        () {
      // Seeded sweep of flows above the table top and slopes 0.5–4 %: the
      // downpipe flag is exactly "collector saturated" whenever raised.
      final r = math.Random(19);
      for (var i = 0; i < 40; i++) {
        final lps = 65.5 + r.nextDouble() * 80;
        final slope = 0.005 + r.nextDouble() * 0.035;
        final s = size(lps, slope);
        final dp = s['dp']!;
        if (!dp.stackRaisedForBranch) continue;
        expect(dp.overCapacity, s['c']!.overCapacity,
            reason: '$lps L/s @ $slope');
      }
    });
  });

  // ── essential name ────────────────────────────────────────────────────────
  ElectricalPanel sub(String id, String name,
          {bool flag = false, List<ElectricalCircuit> circuits = const []}) =>
      ElectricalPanel(
          id: id,
          name: name,
          voltage: const Voltage(400),
          essential: flag,
          sourceType: PanelSource.feeder,
          fedByCircuitId: 'f$id',
          circuits: circuits);
  ElectricalCircuit feeder(String to) => ElectricalCircuit(
      id: 'f$to',
      name: 'To $to',
      loadKind: LoadKind.feeder,
      feedsPanelId: to,
      length: const Length(10));

  ElectricalProject twoBoards(String subName, {bool flag = false}) =>
      ElectricalProject(id: 'p', name: 'P', panels: [
        ElectricalPanel(
            id: 'MDP',
            name: 'MDP',
            voltage: const Voltage(400),
            circuits: [feeder('SUB')]),
        sub('SUB', subName, flag: flag, circuits: const [
          ElectricalCircuit(
              id: 'fp',
              name: 'Fire pump',
              loadKind: LoadKind.pump,
              motorKw: 30,
              lifeSafety: true,
              cableType: 'FRC',
              length: Length(20)),
        ]),
      ]);

  bool lifeSafetyWarned(ElectricalProject p) => computeSystem(_profile, p)
      .warnings
      .any((w) => w.code == 'life-safety-not-essential');

  group('essential name: one set for genset, SLD and the life-safety judge', () {
    for (final name in ['PANEL ESENSIAL', 'PANEL DARURAT', 'LP-EMERGENCY']) {
      test('"$name" (flag false) is backed AND raises no life-safety warning',
          () {
        final p = twoBoards(name);
        expect(isEssentialByName(name), isTrue);
        expect(gensetBackedPanelIds(p), contains('SUB'));
        expect(lifeSafetyWarned(p), isFalse);
      });
    }

    test('a plainly named board still warns (control)', () {
      expect(lifeSafetyWarned(twoBoards('PANEL POMPA')), isTrue);
      expect(lifeSafetyWarned(twoBoards('PANEL POMPA', flag: true)), isFalse);
    });
  });

  group('non-essential name: a negated word is the board to shed', () {
    test('Esensial / Non Esensial pair: only the first is essential', () {
      for (final neg in [
        'PANEL NON ESENSIAL',
        'LP NON-ESSENTIAL',
        'LP NONESSENTIAL',
        'PANEL TIDAK ESENSIAL',
        'PANEL BUKAN DARURAT',
        'non_emergency lighting',
        'PANEL_NON_ESENSIAL',
      ]) {
        expect(isEssentialByName(neg), isFalse, reason: neg);
      }
      for (final pos in [
        'PANEL ESENSIAL',
        'LP ESSENTIAL',
        'Panel Darurat',
        'PANEL EMERGENSI',
        // A negated word elsewhere does not cancel a real essential word.
        'ESSENTIAL (NON-UPS)',
        // Review follow-up: a word merely ENDING in NON/TIDAK/BUKAN is not a
        // negation (no separator before it).
        'CANON ESENSIAL',
        'PANEL_ANON_DARURAT',
      ]) {
        expect(isEssentialByName(pos), isTrue, reason: pos);
      }
    });

    test('the genset backs only the essential board of the pair', () {
      final p = ElectricalProject(id: 'p', name: 'P', panels: [
        ElectricalPanel(
            id: 'MDP',
            name: 'MDP',
            voltage: const Voltage(400),
            circuits: [feeder('E'), feeder('N')]),
        sub('E', 'Panel Esensial'),
        sub('N', 'Panel Non Esensial'),
      ]);
      expect(gensetBackedPanelIds(p), {'E'});
    });
  });

  // Review follow-up: the BOM description (GroundingResult.cableSpec) and the
  // drawing label (cableLabel) group conductors through ONE helper, so for
  // every section/phase/neutral combination they differ only in typography.
  test('cable make-up parity: BOM spec == drawing label (modulo glyphs)', () {
    for (final csa in [1.5, 2.5, 4.0, 10.0, 16.0, 35.0, 70.0, 150.0, 240.0]) {
      for (final three in [true, false]) {
        for (final hasN in [true, false]) {
          if (!three && !hasN) continue;
          final g = sizeGrounding(_profile,
              phaseCsaMm2: csa, threePhase: three, hasNeutral: hasN,
              cableType: 'NYY');
          final label = cableLabel(null, csa, three,
              cores: g.cores,
              peCsaMm2: g.peCsaMm2,
              neutralCsaMm2: hasN ? g.neutralCsaMm2 : null);
          final bom = g.cableSpec
              .replaceAll('×', 'x')
              .replaceAll(' + ', '+')
              .replaceAll(' mm²', '');
          // The label collapses an all-equal make-up to `NYY 5x16`; the BOM
          // groups it the same way (`5×16`), so the strings must match.
          expect(label.split(' ').last, bom.split(' ').last,
              reason: 'csa=$csa 3ph=$three N=$hasN ($label vs ${g.cableSpec})');
        }
      }
    }
  });
}
