// Round 46 (2026-10-18) — the paginated electrical riser keeps every drawn
// board's feeders, is as wide as the band it prints and draws a same-storey
// sub-main chain one link at a time; sub-board feeders ride their own riser
// lane; identical sub-boards are rotated onto the parent's light lines; and
// the layout's unplaced note is scoped to its own sheet.
//
// Each group pins one confirmed finding with a first-principles derivation;
// where the counterexample generalises it is a seeded property.
import 'dart:math' as math;

import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/geo_length.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/panel_results.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/report/drawing_chrome.dart' show kMinPlotLabelPt;
import 'package:mechx_engine/report/electrical_pagination.dart';
import 'package:mechx_engine/report/electrical_pdf_export.dart'
    show sldSinglePageMinLabelPt;
import 'package:mechx_engine/report/electrical_plan_export.dart';
import 'package:mechx_engine/report/electrical_sld_drawing.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

const _p = PuilProfile();
const _floor = kMinPlotLabelPt - kRiserLegibleTolerancePt;

LayoutPos _at(int f) => LayoutPos(sheetId: 's', floorIndex: f, x: 0, y: 0);

/// Boards B0..B(n-1) named DB-i, B_k fed from B_parent[k], on floor[k], each
/// with one identical 5 kW 3ph way.
ElectricalProject _tree(Map<int, int> parent, Map<int, int> floor) =>
    ElectricalProject(id: 'p', name: 'P', panels: [
      for (var i = 0; i < floor.length; i++)
        ElectricalPanel(
            id: 'B$i',
            name: 'DB-$i',
            layoutPos: _at(floor[i]!),
            circuits: [
              for (final e in parent.entries)
                if (e.value == i)
                  ElectricalCircuit(
                      id: 'f${e.key}',
                      name: 'to ${e.key}',
                      loadKind: LoadKind.feeder,
                      feedsPanelId: 'B${e.key}',
                      length: const Length(20)),
              ElectricalCircuit(
                  id: 'g$i',
                  name: 'G',
                  loadKind: LoadKind.general,
                  loadW: 5000,
                  cosPhi: 0.9,
                  phases: 3,
                  length: const Length(10)),
            ]),
    ]);

List<String> _boards(SldSheet p) => [
      for (final l in p.prims.whereType<SldLabel>())
        if (l.size == 10 && l.bold) l.text,
    ];
List<String> _texts(SldSheet p) =>
    [for (final l in p.prims.whereType<SldLabel>()) l.text];

/// Every positive-length stretch where two medium (feeder) lines lie on one
/// axis line — after the per-board merge, two different boards' cables
/// printed as one.
int _collinearFeederOverlaps(SldSheet s) {
  final ml = s.prims
      .whereType<SldLine>()
      .where((l) => l.weight == SldWeight.medium && l.role != SldRole.source)
      .toList();
  var n = 0;
  for (var i = 0; i < ml.length; i++) {
    for (var j = i + 1; j < ml.length; j++) {
      final a = ml[i], c = ml[j];
      final av = a.x1 == a.x2 && a.y1 != a.y2,
          cv = c.x1 == c.x2 && c.y1 != c.y2;
      final ah = a.y1 == a.y2 && a.x1 != a.x2,
          ch = c.y1 == c.y2 && c.x1 != c.x2;
      double lo, hi;
      if (av && cv && a.x1 == c.x1) {
        lo = math.max(math.min(a.y1, a.y2), math.min(c.y1, c.y2));
        hi = math.min(math.max(a.y1, a.y2), math.max(c.y1, c.y2));
      } else if (ah && ch && a.y1 == c.y1) {
        lo = math.max(math.min(a.x1, a.x2), math.min(c.x1, c.x2));
        hi = math.min(math.max(a.x1, a.x2), math.max(c.x1, c.x2));
      } else {
        continue;
      }
      if (hi - lo > 0.5) n++;
    }
  }
  return n;
}

void main() {
  // ── column pages keep the drawn boards' off-band feeders ─────────────────
  group('elec-props-12-riser-column-page-drops-offband-feeders', () {
    test(
        'threeTier(12) placed (MDP GF / SDP-i L1 / UNIT-i L2): every page '
        'drawing SDP-i also draws UNIT-i or cuts its feeder with LANJUT KE '
        'L2', () {
      const n = 12;
      final pr = ElectricalProject(id: 'p', name: 'P', panels: [
        ElectricalPanel(id: 'MDP', name: 'MDP', layoutPos: _at(0), circuits: [
          for (var i = 0; i < n; i++)
            ElectricalCircuit(
                id: 'fs$i',
                name: 'S$i',
                loadKind: LoadKind.feeder,
                feedsPanelId: 'S$i',
                length: Length(30.0 + i)),
        ]),
        for (var i = 0; i < n; i++)
          ElectricalPanel(
              id: 'S$i',
              name: 'SDP-$i',
              layoutPos: _at(1),
              circuits: [
                ElectricalCircuit(
                    id: 'fu$i',
                    name: 'U$i',
                    loadKind: LoadKind.feeder,
                    feedsPanelId: 'U$i',
                    length: Length(10.0 + i)),
                ElectricalCircuit(
                    id: 'gs$i',
                    name: 'G',
                    loadKind: LoadKind.general,
                    loadW: 1000.0 + 1000 * i,
                    cosPhi: 0.9,
                    phases: 3,
                    length: const Length(10)),
              ]),
        for (var i = 0; i < n; i++)
          ElectricalPanel(
              id: 'U$i',
              name: 'UNIT-$i',
              layoutPos: _at(2),
              circuits: [
                ElectricalCircuit(
                    id: 'gu$i',
                    name: 'G',
                    loadKind: LoadKind.general,
                    loadW: 1000.0 + 997 * i,
                    cosPhi: 0.9,
                    phases: 3,
                    length: const Length(10)),
              ]),
      ]);
      const building = BuildingLevels([
        Floor('GF', Length(4)),
        Floor('L1', Length(3.5)),
        Floor('L2', Length(3.5)),
        Floor('ROOF', Length(3)),
      ]);
      final r = computeSystem(_p, pr);
      final pages = paginatedElectricalRiserSheets(
          project: pr, result: r, building: building);
      var sdpPages = 0;
      for (final p in pages) {
        expect(sldSinglePageMinLabelPt(p), greaterThanOrEqualTo(_floor));
        expect(p.belowMinLabelPt, isNull);
        final b = _boards(p), t = _texts(p);
        for (var i = 0; i < n; i++) {
          if (!b.contains('SDP-$i')) continue;
          sdpPages++;
          expect(b.contains('UNIT-$i') || t.contains('LANJUT KE L2'), isTrue,
              reason: 'SDP-$i drawn without its feeder to UNIT-$i: $b');
        }
      }
      expect(sdpPages, greaterThanOrEqualTo(n));
    });
  });

  // ── a rest page is as wide as the band it prints ──────────────────────────
  group('elec-props-12-riser-rest-page-inherits-other-band-width', () {
    test(
        '13 boards on GF / L1 / L2: the L1 floor (3 boards, legible alone) is '
        'issued at the 7 pt floor, never at 6.42 pt', () {
      final par = {
        1: 0, 2: 0, 3: 1, 4: 1, 5: 3, 6: 2, 7: 1, 8: 0, 9: 3, 10: 3, //
        11: 2, 12: 7,
      };
      final fl = {
        for (var i = 0; i < 13; i++)
          i: const [0, 1, 8].contains(i)
              ? 0
              : (const [2, 4, 6].contains(i) ? 1 : 2),
      };
      final pr = _tree(par, fl);
      final r = computeSystem(_p, pr);
      const b3 = BuildingLevels([
        Floor('GF', Length(4)),
        Floor('L1', Length(3.5)),
        Floor('L2', Length(3.5)),
      ]);
      final pages =
          paginatedElectricalRiserSheets(project: pr, result: r, building: b3);
      final l1 = pages.where((p) => _boards(p).contains('DB-4')).single;
      expect(_boards(l1), containsAll(['DB-2', 'DB-4', 'DB-6']));
      for (final p in pages) {
        expect(sldSinglePageMinLabelPt(p), greaterThanOrEqualTo(_floor));
        expect(p.belowMinLabelPt, isNull);
      }
    });

    test(
        'a page is no wider for boards on the bands it crops away: the GF '
        'window of MDP -> 8 boards on L1 has the width of a 1-board band', () {
      // MDP (GF) feeds DB-1..DB-8 (L1). The GF window prints MDP alone; its
      // width is gutter 150 + gap 24 + box 168 + gap 24 = 366 (+ the
      // channel 40 and the lanes), never the 8-board L1 band's 1686.
      final pr = _tree({for (var i = 1; i <= 8; i++) i: 0},
          {0: 0, for (var i = 1; i <= 8; i++) i: 1});
      final r = computeSystem(_p, pr);
      const b2 =
          BuildingLevels([Floor('GF', Length(4)), Floor('L1', Length(3.5))]);
      final gf = buildElectricalRiser(
          project: pr, result: r, building: b2, floorRange: (lo: 0, hi: 0));
      final rects = gf.prims.whereType<SldRect>().toList();
      expect(rects, hasLength(1));
      // Every line ends left of the band's channel lanes (366 + 40 + lanes).
      final maxLine = gf.prims
          .whereType<SldLine>()
          .map((l) => math.max(l.x1, l.x2))
          .reduce(math.max);
      expect(maxLine, lessThan(366 + 40 + 3 * 12 + 1));
    });
  });

  // ── a same-storey sub-main chain draws one link per page ─────────────────
  group('elec-props-12-riser-same-band-ancestor-chain-illegible', () {
    test(
        'B0 (GF) -> B1 -> B2 -> B3 -> B4 -> B8 on L1 (+ siblings): no page is '
        'flagged; a page draws only the NEAREST same-storey feeding board and '
        'names the one above it (DARI)', () {
      final par = {
        1: 0,
        2: 1,
        3: 2,
        4: 3,
        8: 4,
        5: 1,
        6: 1,
        9: 1,
        11: 1,
        7: 2,
        10: 7,
      };
      final fl = {for (var i = 0; i < 12; i++) i: i == 0 ? 0 : 1};
      final pr = _tree(par, fl);
      final r = computeSystem(_p, pr);
      const b2 =
          BuildingLevels([Floor('GF', Length(4)), Floor('L1', Length(3.5))]);
      final pages =
          paginatedElectricalRiserSheets(project: pr, result: r, building: b2);
      for (final p in pages) {
        expect(sldSinglePageMinLabelPt(p), greaterThanOrEqualTo(_floor));
        expect(p.belowMinLabelPt, isNull);
      }
      // The deep chain's page draws DB-2 (the nearest feeding board of the
      // DB-3 unit) but not DB-1, which it names in the gutter instead.
      final deep = pages.where((p) => _boards(p).contains('DB-8')).single;
      expect(_boards(deep), contains('DB-2'));
      expect(_boards(deep), isNot(contains('DB-1')));
      expect(_texts(deep), contains('DARI (lembar lain):'));
      expect(_texts(deep), contains('DB-1 > DB-2'));
    });
  });

  // ── the generalised property ──────────────────────────────────────────────
  group('elec-props-12 seeded property', () {
    test(
        '60 random placed trees (8..26 boards, 2..4 storeys): every page >= '
        '7 pt unless it draws one board; every drawn board\'s children are '
        'drawn, cut with a LANJUT KE stub or named; no two boards\' feeders '
        'share a line', () {
      for (var seed = 0; seed < 60; seed++) {
        final rnd = math.Random(seed);
        final n = 8 + rnd.nextInt(19);
        final nf = 2 + rnd.nextInt(3);
        final par = {for (var i = 1; i < n; i++) i: rnd.nextInt(i)};
        final fl = {
          for (var i = 0; i < n; i++) i: i == 0 ? 0 : rnd.nextInt(nf)
        };
        final pr = _tree(par, fl);
        final r = computeSystem(_p, pr);
        final b = BuildingLevels(
            [for (var k = 0; k < nf; k++) Floor('F$k', const Length(3.5))]);
        final whole = buildElectricalRiser(
            project: pr, result: r, building: b, sourceChain: true);
        expect(_collinearFeederOverlaps(whole), 0, reason: 'seed $seed');
        expect(whole.overlapCount, 0, reason: 'seed $seed');
        final floorOf = electricalRiserFloorOf(pr, r, b);
        final typical = {
          for (final g in electricalRiserTypicalGroups(pr, r, b).values) ...g,
        };
        for (final p in paginatedElectricalRiserSheets(
            project: pr, result: r, building: b)) {
          final boards = _boards(p).where((x) => x.startsWith('DB-')).toSet();
          final texts = _texts(p);
          // Every PAGE, not only the whole sheet: a board fed from another
          // sheet (its `DARI` stub) never shares a line with its own feeders.
          expect(_collinearFeederOverlaps(p), 0,
              reason: 'seed $seed page $boards');
          expect(p.overlapCount, 0, reason: 'seed $seed page $boards');
          if (boards.length > 1) {
            expect(sldSinglePageMinLabelPt(p), greaterThanOrEqualTo(_floor),
                reason: 'seed $seed $boards');
          }
          for (var i = 0; i < n; i++) {
            if (!boards.contains('DB-$i')) continue;
            for (final e in par.entries) {
              if (e.value != i) continue;
              final k = e.key;
              if (boards.contains('DB-$k') || typical.contains('B$k')) continue;
              final ok = floorOf['B$k'] != floorOf['B$i']
                  ? texts.any((t) => t.startsWith('LANJUT KE'))
                  : texts.contains('LANJUT (lembar lain):');
              expect(ok, isTrue,
                  reason: 'seed $seed: DB-$i drawn, DB-$k neither drawn, cut '
                      'nor named on $boards');
            }
          }
        }
      }
    });
  });

  // ── a sub-board's feeders ride their own lane ─────────────────────────────
  group('drawings-7-riser-subfeeders-on-parent-channel', () {
    test(
        'MDP (GF) feeds DB-L1 + U1 (L1), DB-L1 feeds U2 (L1): no segment is '
        'drawn twice, DB-L1 leaves 8 below its entry, and its riser rides '
        'its own lane 12 right of the MDP\'s', () {
      final pr = _tree({1: 0, 2: 0, 3: 1}, {0: 0, 1: 1, 2: 1, 3: 1});
      final r = computeSystem(_p, pr);
      const b2 =
          BuildingLevels([Floor('GF', Length(4)), Floor('L1', Length(3.5))]);
      final s = buildElectricalRiser(project: pr, result: r, building: b2);
      final ml = s.prims
          .whereType<SldLine>()
          .where((l) => l.weight == SldWeight.medium);
      final keys = [for (final l in ml) '${l.x1},${l.y1},${l.x2},${l.y2}'];
      expect(keys.toSet(), hasLength(keys.length));
      expect(_collinearFeederOverlaps(s), 0);
      expect(s.overlapCount, 0);
      // Geometry: the L1 band sits at y 0 (top), boxes 46 high ⇒ centre-line
      // 23; DB-1 is the band's first board (x 174, right edge 342). Its
      // incoming branch enters at y 23; its own feeder leaves at 23 + 8 = 31.
      bool hasLine(double x1, double y1, double x2, double y2) =>
          ml.any((l) => l.x1 == x1 && l.y1 == y1 && l.x2 == x2 && l.y2 == y2);
      expect(hasLine(342, 23, 354, 23), isTrue); // incoming stub (jog x 354)
      expect(hasLine(342, 31, 358, 31), isTrue); // outgoing, jog 354 + 4
      // Channel: three boards on L1 ⇒ sheetMaxX 174 + 3 × 192 = 750 ⇒
      // channel 790 (the MDP's lane); DB-1's riser spans its own bus row to
      // U2's and overlaps the MDP's, so it takes lane 790 + 12 = 802.
      final verticals790 = ml.where((l) => l.x1 == 790 && l.x2 == 790);
      final verticals802 = ml.where((l) => l.x1 == 802 && l.x2 == 802);
      expect(verticals790, isNotEmpty);
      expect(verticals802, isNotEmpty);
      // The MDP's lane reaches its GF board (centre y 167 + 23 = 190); DB-1's
      // lane never leaves the L1 band.
      expect(verticals790.any((l) => math.max(l.y1, l.y2) == 190), isTrue);
      expect(verticals802.every((l) => math.max(l.y1, l.y2) < 46), isTrue);
    });
  });

  // ── identical sub-boards rotated onto the parent's light lines ────────────
  group('drawings-7-phase-label-bias-inherent-verdict', () {
    // LVMDP feeds 12 identical floor DBs (8 × 2.2 kW 1ph tenants + 400 W
    // corridor lighting each) and a 7.5 kW pump.
    ElectricalProject tower({List<PhaseLine> Function(int f)? pins}) =>
        ElectricalProject(id: 't', name: 'Tower', panels: [
          ElectricalPanel(id: 'MDP', name: 'LVMDP', circuits: [
            for (var f = 1; f <= 12; f++)
              ElectricalCircuit(
                  id: 'f$f',
                  name: 'DB-L$f',
                  loadKind: LoadKind.feeder,
                  feedsPanelId: 'DB$f',
                  length: const Length(20)),
            const ElectricalCircuit(
                id: 'pump',
                name: 'Pump',
                loadKind: LoadKind.pump,
                motorKw: 7.5,
                phases: 3,
                length: Length(15)),
          ]),
          for (var f = 1; f <= 12; f++)
            ElectricalPanel(id: 'DB$f', name: 'DB-L$f', circuits: [
              for (var u = 1; u <= 8; u++)
                ElectricalCircuit(
                    id: 'u$f-$u',
                    name: 'Unit $f$u',
                    loadKind: LoadKind.general,
                    loadW: 2200,
                    cosPhi: 0.9,
                    phases: 1,
                    phaseOverride: pins?.call(f)[u - 1],
                    length: const Length(15)),
              ElectricalCircuit(
                  id: 'c$f',
                  name: 'Corridor',
                  loadKind: LoadKind.lighting,
                  loadW: 400,
                  cosPhi: 0.9,
                  phases: 1,
                  phaseOverride: pins?.call(f)[8],
                  length: const Length(15)),
            ]),
        ]);
    // The SAME pattern pinned on every floor (3 + 3 + 2 tenants, corridor
    // on L3): the stacking the engine's own lowest-line tie-break produced.
    List<PhaseLine> same(int f) => [
          for (var u = 1; u <= 8; u++) PhaseLine.values[(u - 1) % 3],
          PhaseLine.l3,
        ];
    double worst(PhaseBalanceResult b) => [b.l1, b.l2, b.l3].reduce(math.max);

    test(
        'unpinned: every DB keeps its 3 + 3 + 2 spread, but the LVMDP sees '
        'each light line once per three floors — 0 % imbalance, never 28.6 %',
        () {
      final stacked = computeSystem(_p, tower(pins: same));
      final rotated = computeSystem(_p, tower());
      final db = rotated.panels['DB1']!.phaseBalance;
      final dbStacked = stacked.panels['DB1']!.phaseBalance;
      // Each DB's own figures are unchanged by the rotation (same spread).
      expect(db.imbalancePercent, dbStacked.imbalancePercent);
      expect([db.l1, db.l2, db.l3]..sort(),
          [dbStacked.l1, dbStacked.l2, dbStacked.l3]..sort());
      // The pump's line current is what the light line carries beyond the
      // twelve stacked light lines: pumpA = MDP.l3 − 12 × DB.l3 (stacked).
      final ms = stacked.panels['MDP']!.phaseBalance;
      final pumpA = ms.l3 - 12 * dbStacked.l3;
      // Rotated: four DBs put their light line on each phase, so every MDP
      // line carries 4 × (l1 + l2 + l3) of one DB plus the pump.
      final expected = 4 * (db.l1 + db.l2 + db.l3) + pumpA;
      final m = rotated.panels['MDP']!;
      expect(m.phaseBalance.l1, closeTo(expected, 0.2));
      expect(m.phaseBalance.l2, closeTo(expected, 0.2));
      expect(m.phaseBalance.l3, closeTo(expected, 0.2));
      expect(m.phaseBalance.imbalancePercent, lessThanOrEqualTo(0.1));
      expect(worst(m.phaseBalance), lessThan(worst(ms) - 30));
      expect(m.warnings.map((w) => w.code),
          isNot(contains('phase-imbalance-inherent')));
    });

    test(
        'every DB pinned to the same pattern: the LVMDP imbalance is '
        'REDUCIBLE by rotating sub-boards — a phase-imbalance warning naming '
        'them, never "inherent, no redistribution helps"', () {
      final r = computeSystem(_p, tower(pins: same));
      final m = r.panels['MDP']!;
      final codes = m.warnings.map((w) => w.code).toList();
      expect(codes, contains('phase-imbalance'));
      expect(codes, isNot(contains('phase-imbalance-inherent')));
      expect(m.phaseBalance.imbalanceReducible, isTrue);
      final w = m.warnings.firstWhere((w) => w.code == 'phase-imbalance');
      expect(w.message, contains('Rotate R/S/T at DB-L'));
      expect(w.message, contains('0.0% is achievable'));
    });

    test(
        'persisted (stacked) labels: relabelled when the LVMDP worst line '
        'drops by more than the 1 A stability threshold; kept (and named) '
        'when it does not', () {
      // The stacked labels as persisted assignments (no pins).
      final stacked = computeSystem(_p, tower(pins: same));
      final prior = {
        for (var f = 1; f <= 12; f++)
          'DB$f': {
            for (final c in stacked.panels['DB$f']!.circuits)
              c.circuitId: c.phase,
          },
      };
      final relabelled = computeSystem(_p, tower(),
          priorAssignments: prior, phaseReassignThresholdA: 1.0);
      expect(relabelled.panels['MDP']!.phaseBalance.imbalancePercent,
          lessThanOrEqualTo(0.1));
      final kept = computeSystem(_p, tower(),
          priorAssignments: prior, phaseReassignThresholdA: 1000);
      expect(worst(kept.panels['MDP']!.phaseBalance),
          closeTo(worst(stacked.panels['MDP']!.phaseBalance), 0.1));
      expect(kept.panels['MDP']!.warnings.map((w) => w.code),
          contains('phase-imbalance'));
    });

    test(
        'the rotation is a fixed point: re-solving with the solved labels '
        'persisted keeps every label', () {
      final first = computeSystem(_p, tower());
      final stamped = tower().withPanels([
        for (final p in tower().panels)
          p.copyWith(circuits: [
            for (final c in p.circuits)
              switch (first.panels[p.id]!.circuits
                  .firstWhere((x) => x.circuitId == c.id)
                  .phase) {
                PhaseAssignment.l1 => c.copyWith(assignedPhase: PhaseLine.l1),
                PhaseAssignment.l2 => c.copyWith(assignedPhase: PhaseLine.l2),
                PhaseAssignment.l3 => c.copyWith(assignedPhase: PhaseLine.l3),
                PhaseAssignment.threePhase => c,
              },
          ]),
      ]);
      final again = computeSystem(_p, stamped, phaseReassignThresholdA: 1.0);
      for (final p in first.panels.values) {
        for (final c in p.circuits) {
          final c2 = again.panels[p.panelId]!.circuits
              .firstWhere((x) => x.circuitId == c.circuitId);
          expect(c2.phase, c.phase, reason: '${p.panelId}/${c.circuitId}');
        }
      }
    });
  });

  // ── the layout's unplaced note is scoped to its sheet ─────────────────────
  group('drawings-7-layout-unplaced-count-projectwide', () {
    LayoutPos on(String sheet, int f) =>
        LayoutPos(sheetId: sheet, floorIndex: f, x: 100, y: 100);
    // MDP on GF (sheet g), DB-L1 on L1 (sheet a), DB-L2 on L2 (sheet b), and
    // UNIT boards unplaced under each floor DB (3 ways each, unplaced). An
    // ORPHAN board placed nowhere with 2 unplaced ways and no parent.
    ElectricalProject project() =>
        ElectricalProject(id: 'p', name: 'P', panels: [
          ElectricalPanel(
              id: 'MDP',
              name: 'MDP',
              layoutPos: on('g', 0),
              circuits: const [
                ElectricalCircuit(
                    id: 'f1',
                    name: 'L1',
                    loadKind: LoadKind.feeder,
                    feedsPanelId: 'D1'),
                ElectricalCircuit(
                    id: 'f2',
                    name: 'L2',
                    loadKind: LoadKind.feeder,
                    feedsPanelId: 'D2'),
              ]),
          for (final (id, sheet, f) in [('D1', 'a', 1), ('D2', 'b', 2)])
            ElectricalPanel(
                id: id,
                name: 'DB-$id',
                layoutPos: on(sheet, f),
                circuits: [
                  ElectricalCircuit(
                      id: '$id-u',
                      name: 'U',
                      loadKind: LoadKind.feeder,
                      feedsPanelId: 'U$id'),
                  ElectricalCircuit(
                      id: '$id-c',
                      name: 'Corridor',
                      loadKind: LoadKind.lighting,
                      loadW: 400),
                ]),
          for (final id in ['D1', 'D2'])
            ElectricalPanel(id: 'U$id', name: 'UNIT-$id', circuits: [
              for (var k = 0; k < 3; k++)
                ElectricalCircuit(
                    id: 'U$id-$k',
                    name: 'W$k',
                    loadKind: LoadKind.socket,
                    loadW: 900),
            ]),
          ElectricalPanel(id: 'ORPH', name: 'ORPHAN', circuits: [
            for (var k = 0; k < 2; k++)
              ElectricalCircuit(
                  id: 'o$k',
                  name: 'O$k',
                  loadKind: LoadKind.socket,
                  loadW: 500),
          ]),
        ]);

    test(
        'each floor sheet counts only its own boards\' unplaced loads (DB-L1 '
        'corridor 1 + UNIT 3 = 4), never the project-wide 9', () {
      final a = buildElectricalPlanData(
          project: project(),
          sheetId: 'a',
          floorIndex: 1,
          listUnhomedUnplaced: false);
      expect(a.unplaced, contains('Panel UNIT-D1 (belum ditempatkan)'));
      expect(a.unplaced, isNot(contains('Panel UNIT-D2 (belum ditempatkan)')));
      expect(a.unplaced, isNot(contains('Panel ORPHAN (belum ditempatkan)')));
      expect(a.unplaced,
          contains('4 beban belum ditempatkan (panel di lembar ini)'));
      expect(a.unplaced.any((u) => u.contains('tanpa lembar')), isFalse);
      // The MDP sheet: no unplaced load of its own, no unplaced child.
      final g = buildElectricalPlanData(
          project: project(),
          sheetId: 'g',
          floorIndex: 0,
          listUnhomedUnplaced: false);
      expect(g.unplaced.where((u) => u.contains('belum ditempatkan')), isEmpty);
    });

    test(
        'a board placed nowhere up its feeder chain is listed ONCE, on the '
        'designated sheet', () {
      final first = buildElectricalPlanData(
          project: project(), sheetId: 'g', floorIndex: 0);
      expect(first.unplaced, contains('Panel ORPHAN (belum ditempatkan)'));
      expect(first.unplaced,
          contains('2 beban belum ditempatkan (panel tanpa lembar)'));
      // Summed over every sheet (the designated one listing the orphan),
      // each of the 9 unplaced loads is reported exactly once.
      var total = 0;
      for (final (s, f, home) in [
        ('g', 0, true),
        ('a', 1, false),
        ('b', 2, false)
      ]) {
        final d = buildElectricalPlanData(
            project: project(),
            sheetId: s,
            floorIndex: f,
            listUnhomedUnplaced: home);
        for (final u in d.unplaced) {
          final m = RegExp(r'^(\d+) beban').firstMatch(u);
          if (m != null) total += int.parse(m.group(1)!);
        }
      }
      expect(total, 2 * (1 + 3) + 2);
    });
  });
}
