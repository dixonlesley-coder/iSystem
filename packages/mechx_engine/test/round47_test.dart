// Round 47 (2026-10-18) — the paginated electrical riser draws every board on
// some issued sheet; a forced genset is judged on the basis the engine sizes
// it on; the power one-line prints the solved backup demand, never the typed
// nameplate; a prime set is scheduled as prime; the upfeed pump ASSUMED at a
// meter sits on its floor surface.
//
// Each group pins one confirmed finding with a first-principles derivation;
// where the counterexample generalises it is a seeded property.
import 'dart:math' as math;

import 'package:mechx_engine/electrical/advanced_study.dart';
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/genset_backup.dart';
import 'package:mechx_engine/electrical/geo_length.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/power_oneline.dart';
import 'package:mechx_engine/electrical/sources.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/hydraulics.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/network/pressure_solve.dart';
import 'package:mechx_engine/report/electrical_pagination.dart';
import 'package:mechx_engine/report/electrical_sld_drawing.dart';
import 'package:mechx_engine/report/equipment_schedule.dart';
import 'package:mechx_engine/report/report_strings.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

const _p = PuilProfile();

LayoutPos _at(int f) => LayoutPos(sheetId: 's', floorIndex: f, x: 0, y: 0);

/// Boards B0..B(n-1) named DB-i, B_k fed from B_parent[k], on floor[k], each
/// with one DISTINCT 3ph way (5 kW + 137 W × i) so no band collapses to a
/// TIPIKAL node by accident.
ElectricalProject _tree(Map<int, int> parent, Map<int, int> floor,
        {Map<int, String> names = const {}}) =>
    ElectricalProject(id: 'p', name: 'P', panels: [
      for (var i = 0; i < floor.length; i++)
        ElectricalPanel(
            id: 'B$i',
            name: names[i] ?? 'DB-$i',
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
                  loadW: 5000 + 137.0 * i,
                  cosPhi: 0.9,
                  phases: 3,
                  length: const Length(10)),
            ]),
    ]);

Set<String> _boards(SldSheet p) => {
      for (final l in p.prims.whereType<SldLabel>())
        if (l.size == 10 && l.bold) l.text,
    };
List<String> _texts(SldSheet p) =>
    [for (final l in p.prims.whereType<SldLabel>()) l.text];
bool _hasSpine(SldSheet p) => p.prims.any((x) =>
    (x is SldLabel && x.role == SldRole.source) ||
    (x is SldLine && x.role == SldRole.source));

/// The property every issued riser set must hold: every board (outside a
/// TIPIKAL collapse) is drawn on >= 1 page, every 'DARI (lembar lain)' parent
/// is drawn on some page, and the source spine is drawn on exactly one page.
void _expectComplete(ElectricalProject pr, BuildingLevels b, String reason) {
  final r = computeSystem(_p, pr);
  final pages =
      paginatedElectricalRiserSheets(project: pr, result: r, building: b);
  final drawn = <String>{for (final p in pages) ..._boards(p)};
  final typical = {
    for (final g in electricalRiserTypicalGroups(pr, r, b).values) ...g,
  };
  for (final panel in pr.panels) {
    if (typical.contains(panel.id)) continue;
    expect(drawn, contains(panel.name),
        reason: '$reason: ${panel.name} drawn on no page');
  }
  for (final p in pages) {
    final t = _texts(p);
    final at = t.indexOf('DARI (lembar lain):');
    if (at < 0) continue;
    for (final s in t) {
      if (!s.contains(' > ')) continue;
      final parent = s.split(' > ').first;
      expect(drawn, contains(parent),
          reason: '$reason: DARI names $parent, drawn on no page');
    }
  }
  expect(pages.where(_hasSpine).length, 1,
      reason: '$reason: source spine on exactly one page');
}

void main() {
  // ── the riser pagination never drops a board ──────────────────────────────
  group('regression-riser-pages-drop-upper-same-storey-boards-and-main-board',
      () {
    test(
        'single storey LVMDP -> SDP-1 -> SSDP-1 -> DB-1..12: LVMDP, SDP-1 and '
        'the PLN head are drawn (on an ancestor page issued first)', () {
      // B0 = LVMDP, B1 = SDP-1, B2 = SSDP-1, B3..B14 = DB-1..DB-12.
      final par = {1: 0, 2: 1, for (var i = 3; i < 15; i++) i: 2};
      final fl = {for (var i = 0; i < 15; i++) i: 0};
      final names = {
        0: 'LVMDP',
        1: 'SDP-1',
        2: 'SSDP-1',
        for (var i = 3; i < 15; i++) i: 'DB-${i - 2}',
      };
      final pr = _tree(par, fl, names: names);
      const b = BuildingLevels([Floor('GF', Length(4))]);
      final r = computeSystem(_p, pr);
      final pages =
          paginatedElectricalRiserSheets(project: pr, result: r, building: b);
      // More than one page (the 12 distinct DBs cannot print on one sheet).
      expect(pages.length, greaterThan(1));
      final withMain =
          pages.where((p) => _boards(p).contains('LVMDP')).toList();
      expect(withMain, isNotEmpty);
      expect(pages.where((p) => _boards(p).contains('SDP-1')), isNotEmpty);
      // The ancestor page comes BEFORE the column pages of its band.
      expect(_boards(pages.first), contains('LVMDP'));
      expect(_hasSpine(pages.first), isTrue);
      _expectComplete(pr, b, 'factory');
    });

    test(
        'seeded property: 150 trees (6..45 boards, 1..6 storeys) — every '
        'board drawn, every DARI parent drawn, the spine on exactly one page',
        () {
      for (var seed = 0; seed < 150; seed++) {
        final rnd = math.Random(seed);
        final n = 6 + rnd.nextInt(40);
        final nf = 1 + rnd.nextInt(6);
        // Bias toward wide same-storey chains: a parent is often the last
        // few boards (deep chains) on the same floor.
        final par = {
          for (var i = 1; i < n; i++)
            i: rnd.nextBool()
                ? rnd.nextInt(i)
                : math.max(0, i - 1 - rnd.nextInt(3)),
        };
        final fl = <int, int>{0: 0};
        for (var i = 1; i < n; i++) {
          fl[i] = rnd.nextInt(3) == 0 ? rnd.nextInt(nf) : fl[par[i]!]!;
        }
        final pr = _tree(par, fl);
        final b = BuildingLevels(
            [for (var k = 0; k < nf; k++) Floor('F$k', const Length(3.5))]);
        _expectComplete(pr, b, 'seed $seed');
      }
    });
  });

  // ── a forced genset is judged on the engine's own backup basis ────────────
  group('elec-convergence-forced-genset-below-full-backup-silent', () {
    ElectricalProject proj({
      required double forcedKva,
      bool essential = false,
      double fraction = 1.0,
    }) =>
        ElectricalProject(
          id: 'g',
          name: 'g',
          sources: ElectricalSources(
              generator: GeneratorSource(
                  kva: ApparentPower(forcedKva * 1000),
                  backupFraction: fraction)),
          panels: [
            ElectricalPanel(
              id: 'MDP',
              name: 'MDP',
              system: ElectricalSystem.threePhase,
              voltage: const Voltage(400),
              circuits: [
                for (var i = 0; i < 3; i++)
                  ElectricalCircuit(
                    id: 'h$i',
                    name: 'Heater $i',
                    loadKind: LoadKind.general,
                    loadW: 30000,
                    cosPhi: 1,
                    phases: 3,
                    length: const Length(10),
                  ),
                const ElectricalCircuit(
                    id: 'fe',
                    name: 'to EMDP',
                    loadKind: LoadKind.feeder,
                    feedsPanelId: 'EMDP',
                    length: Length(10)),
              ],
            ),
            ElectricalPanel(
              id: 'EMDP',
              name: 'EMDP',
              system: ElectricalSystem.threePhase,
              voltage: const Voltage(400),
              essential: essential,
              sourceType: PanelSource.feeder,
              fedByCircuitId: 'fe',
              circuits: const [
                ElectricalCircuit(
                  id: 'e1',
                  name: 'Essential',
                  loadKind: LoadKind.general,
                  loadW: 10000,
                  cosPhi: 1,
                  phases: 3,
                  length: Length(10),
                ),
              ],
            ),
          ],
        );

    for (final essential in [false, true]) {
      test(
          'forced 50 kVA vs the 100 kVA whole-building basis (fraction 1.0, '
          'EMDP essential=$essential): both -demand and -power raise', () {
        final pr = proj(forcedKva: 50, essential: essential);
        final sys = computeSystem(_p, pr);
        // Demand = 3 × 30 kW + 10 kW = 100 kW at cos φ 1 ⇒ 100 kVA; the
        // basis is max(1.0 × 100 kVA, essential ≤ 10 kVA) = 100 kVA.
        expect(gensetBackupDemandVa(pr, sys).voltAmperes, closeTo(100000, 1));
        final codes = {for (final w in gensetBackupWarnings(pr, sys)) w.code};
        // 50 kVA < 100 kVA; 0.8 × 50 = 40 kW < 100 kW.
        expect(
            codes,
            containsAll([
              'genset-below-essential-demand',
              'genset-below-essential-power'
            ]));
        final w = gensetBackupWarnings(pr, sys)
            .firstWhere((w) => w.code == 'genset-below-essential-demand');
        expect(w.message, contains('100.0 kVA'));
        expect(w.message, contains('backup fraction 100 %'));
        expect(computeAdvancedStudy(_p, pr, sys).warnings.map((w) => w.code),
            contains('genset-below-essential-demand'));
      });
    }

    test('fraction 0.45: a forced 30 kVA set is judged against 45 kVA', () {
      final pr = proj(forcedKva: 30, essential: true, fraction: 0.45);
      final sys = computeSystem(_p, pr);
      // Basis = max(0.45 × 100 kVA, 10 kVA essential) = 45 kVA > 30 kVA;
      // kW basis = max(45 kW, 10 kW) = 45 kW > 0.8 × 30 = 24 kW.
      expect(gensetBackupDemandVa(pr, sys).voltAmperes, closeTo(45000, 1));
      final codes = {for (final w in gensetBackupWarnings(pr, sys)) w.code};
      expect(codes, contains('genset-below-essential-demand'));
      expect(codes, contains('genset-below-essential-power'));
    });

    test('property: a forced set >= the basis (kVA and 0.8·kVA) is silent', () {
      for (var kva = 20.0; kva <= 160; kva += 5) {
        for (final f in [0.3, 0.45, 1.0]) {
          final pr = proj(forcedKva: kva, essential: true, fraction: f);
          final sys = computeSystem(_p, pr);
          final basisVa = gensetBackupDemandVa(pr, sys).voltAmperes;
          final basisW = gensetBackupDemandW(pr, sys).watts;
          final codes = {for (final w in gensetBackupWarnings(pr, sys)) w.code};
          expect(codes.contains('genset-below-essential-demand'),
              kva * 1000 + 1e-6 < basisVa,
              reason: '$kva kVA @ $f');
          expect(codes.contains('genset-below-essential-power'),
              kva * 1000 * kGeneratorPf + 1e-6 < basisW,
              reason: '$kva kVA @ $f');
        }
      }
    });
  });

  // ── the power one-line prints the solved backup basis ─────────────────────
  group('cross-surface-oneline-essential-bus-prints-forced-nameplate', () {
    PowerOneLine oneLine(double? forced) => buildPowerOneLine(
          ElectricalSources(
              generator: GeneratorSource(
                  kva: forced == null ? null : ApparentPower(forced * 1000),
                  backupFraction: 0.45)),
          demand: const ApparentPower(100000),
          backupDemand: const ApparentPower(45000),
        );
    String? essBus(PowerOneLine l) =>
        l.nodes.where((n) => n.id == 'ess-bus').single.sub;

    test('unforced: the essential bus prints the 45 kVA basis', () {
      expect(essBus(oneLine(null)), '45 kVA');
    });

    test('forced 30 kVA: the bus still prints 45 kVA, the set its nameplate',
        () {
      final l = oneLine(30);
      // backup = 0.45 × 100 kVA = 45 kVA — the load the set must carry,
      // whatever nameplate was typed.
      expect(essBus(l), '45 kVA');
      final gen = l.nodes.where((n) => n.id == 'gen').single;
      expect(gen.sub, contains('30 kVA'));
      expect(l.nodes.map((n) => n.sub ?? '').join(' '),
          isNot(contains('backing 30')));
    });

    test('forced 100 kVA (oversized) does not inflate the bus', () {
      expect(essBus(oneLine(100)), '45 kVA');
    });
  });

  // ── a prime genset is scheduled as prime ──────────────────────────────────
  group('cross-surface-prime-genset-scheduled-as-standby', () {
    ElectricalProject proj(GeneratorMode mode) => ElectricalProject(
          id: 'p',
          name: 'B',
          sources: ElectricalSources(
              generator:
                  GeneratorSource(kva: const ApparentPower(82000), mode: mode)),
          panels: const [
            ElectricalPanel(id: 'MDP', name: 'MDP', circuits: [
              ElectricalCircuit(
                  id: 'c1',
                  name: 'Load',
                  loadKind: LoadKind.general,
                  loadW: 20000,
                  length: Length(20)),
            ]),
          ],
        );
    EquipmentScheduleRow genRow(GeneratorMode mode, {bool id = false}) {
      final pr = proj(mode);
      return buildEquipmentScheduleRows(
              EquipmentScheduleData(
                projectName: 'B',
                date: 'd',
                electrical: computeSystem(_p, pr),
                electricalProject: pr,
              ),
              id ? const ReportStrings.id() : const ReportStrings.en())
          .firstWhere((r) => r.category == EquipmentCategory.generator);
    }

    test('prime: never "Standby" / "cadangan"', () {
      expect(genRow(GeneratorMode.prime).service, 'Prime generator');
      expect(genRow(GeneratorMode.prime, id: true).service, 'Genset prime');
      expect(genRow(GeneratorMode.prime, id: true).service,
          isNot(contains('cadangan')));
    });

    test('standby: byte-identical label', () {
      expect(genRow(GeneratorMode.standby).service, 'Standby generator');
      expect(
          genRow(GeneratorMode.standby, id: true).service, 'Genset cadangan');
    });
  });

  // ── the assumed upfeed pump sits on its floor surface ─────────────────────
  group('mech-convergence-2-assumed-upfeed-pump-at-ceiling-datum', () {
    const building =
        BuildingLevels([Floor('L0', Length(3.5)), Floor('L1', Length(3.2))]);
    const cw = ServiceType.coldWater;
    const target = Pressure(225000);
    NetNode n(String id, double x, int f,
            {NodeRole role = NodeRole.main, NodeComponent? c}) =>
        NetNode(
            id: id,
            sheetId: 's',
            x: x,
            y: 0,
            floorIndex: f,
            role: c?.role ?? role,
            component: c);
    NetEdge run(String id, String a, String b, {EdgeKind k = EdgeKind.run}) =>
        NetEdge(id: id, fromId: a, toId: b, service: cw, kind: k);

    // M (meter, L0) -> R0 -riser- R1 -> F1 (fixture, L1); with [pumped] a
    // pump P drawn at the meter: M -> P -> R0.
    PressureSolution solve(bool pumped) {
      final net = Network(nodes: [
        n('M', 0, 0, c: NodeComponent.waterMeter),
        if (pumped) n('P', 10, 0, c: NodeComponent.pump),
        n('R0', 20, 0),
        n('R1', 20, 1),
        n('F1', 40, 1, role: NodeRole.fixture),
      ], edges: [
        if (pumped) ...[run('e0', 'M', 'P'), run('e1', 'P', 'R0')] else
          run('e1', 'M', 'R0'),
        run('e2', 'R0', 'R1', k: EdgeKind.riser),
        run('e3', 'R1', 'F1'),
      ]);
      final sizing = autoSizeNetwork(net, const SizingContext(),
          leafDemand: const {cw: FlowRate(0.0002)},
          nodeFlowDemand: const {'F1': FlowRate(0.0002)},
          building: building);
      final source = pumped ? 'P' : 'M';
      return solvePressurized(
        net: net,
        service: cw,
        sourceId: source,
        edgeFlows: {for (final e in sizing.entries) e.key: e.value.flow},
        sizing: sizing,
        calibrationBySheet: const {},
        building: building,
        targetResidual: target,
        sourceElevation:
            assumedPumpSourceElevation(net.nodeById(source), building),
      );
    }

    test('the meter-only drawing sizes the SAME head as the drawn pump', () {
      final meter = solve(false);
      final pump = solve(true);
      // Same riser friction on both; the static term is (critical − the
      // pump's floor surface 0.0 m) for BOTH drawings, never (critical − the
      // meter's 3.5 m L0 ceiling datum), which was the drop.
      expect(meter.requiredPumpHead.meters,
          closeTo(pump.requiredPumpHead.meters, 1e-9));
      // Without the datum the meter drawing read the ceiling: lower by
      // exactly the L0 ceiling height.
      final legacy = solvePressurized(
        net: Network(nodes: [
          n('M', 0, 0, c: NodeComponent.waterMeter),
          n('R0', 20, 0),
          n('R1', 20, 1),
          n('F1', 40, 1, role: NodeRole.fixture),
        ], edges: [
          run('e1', 'M', 'R0'),
          run('e2', 'R0', 'R1', k: EdgeKind.riser),
          run('e3', 'R1', 'F1'),
        ]),
        service: cw,
        sourceId: 'M',
        edgeFlows: const {},
        sizing: const {},
        calibrationBySheet: const {},
        building: building,
        targetResidual: target,
      );
      // No sizing ⇒ zero friction ⇒ head = target + (F1 − M ceiling).
      final f1 =
          nodeElevation(n('F1', 40, 1, role: NodeRole.fixture), building);
      final mCeiling =
          nodeElevation(n('M', 0, 0, c: NodeComponent.waterMeter), building);
      expect(mCeiling.meters,
          closeTo(building.ceilingElevationOf(0).meters, 1e-12));
      expect(
          legacy.requiredPumpHead.meters,
          closeTo(headFromPressure(target).meters + f1.meters - mCeiling.meters,
              1e-9));
      expect(meter.requiredPumpHead.meters - legacy.requiredPumpHead.meters,
          greaterThan(mCeiling.meters - 1e-9));
    });

    test('a drawn plant keeps its own elevation (helper returns null)', () {
      expect(
          assumedPumpSourceElevation(
              n('P', 0, 0, c: NodeComponent.pump), building),
          isNull);
      expect(
          assumedPumpSourceElevation(
                  n('M', 0, 1, c: NodeComponent.waterMeter), building)!
              .meters,
          closeTo(3.5, 1e-12));
    });
  });
}
