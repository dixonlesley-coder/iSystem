// Drawing backlog (2026-11-13) — C-1..C-5 focused tests (pure layer).
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/fault.dart';
import 'package:mechx_engine/electrical/geo_length.dart' show LayoutPos;
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/panel_results.dart'
    show ElectricalSystemResult;
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/electrical_pagination.dart';
import 'package:mechx_engine/report/electrical_sld_drawing.dart';
import 'package:mechx_engine/report/riser_tags.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

import 'reference/apartment.dart' as apt;
import 'reference/reference_building.dart';
import 'reference/tower.dart' as tower;

BuildingLevels _levels(List<String> names, {int ground = 0}) =>
    BuildingLevels([for (final n in names) Floor(n, const Length(3.5))],
        groundIndex: ground);

void main() {
  group('C-1 level code follows the floor name', () {
    test('floorNameLevelCode recognises the drawing conventions', () {
      expect(floorNameLevelCode('Lantai 30'), 'L30');
      expect(floorNameLevelCode('lantai1'), 'L1');
      expect(floorNameLevelCode('  LANTAI   7 '), 'L7');
      expect(floorNameLevelCode('Basement 2'), 'B2');
      expect(floorNameLevelCode('B1'), 'B1');
      expect(floorNameLevelCode('b 3'), 'B3');
      expect(floorNameLevelCode('Ground'), 'GF');
      expect(floorNameLevelCode('GF'), 'GF');
      expect(floorNameLevelCode('Dasar'), 'GF');
      expect(floorNameLevelCode('Atap'), 'RF');
      expect(floorNameLevelCode('Roof'), 'RF');
      expect(floorNameLevelCode('Mezzanine'), isNull);
      expect(floorNameLevelCode('L1'), isNull);
    });

    test('a "Lantai N" stack prints LN on floor N (not the index one below)',
        () {
      final b = _levels([for (var i = 1; i <= 30; i++) 'Lantai $i']);
      expect(floorLocatorToken(0, b), 'L1');
      expect(floorLocatorToken(29, b), 'L30');
    });

    test('basements + ground + roof by name; unknown names keep the index rule',
        () {
      final b = _levels(['Basement 1', 'Dasar', 'Mezz', 'Atap'], ground: 1);
      expect(floorLocatorToken(0, b), 'B1');
      expect(floorLocatorToken(1, b), 'GF');
      expect(floorLocatorToken(2, b), 'L1'); // index rule (rel +1)
      expect(floorLocatorToken(3, b), 'RF');
    });

    test('ambiguous names fall back to the index rule for every floor', () {
      // 'Lantai 2' would collide with the index fallback 'L2' of 'Mezz'.
      final b = _levels(['Lantai 1', 'Mezz', 'Mezz B', 'Lantai 2']);
      expect([for (var i = 0; i < 4; i++) floorLocatorToken(i, b)],
          ['GF', 'L1', 'L2', 'L3']);
    });

    test('no building keeps the legacy F<n>', () {
      expect(floorLocatorToken(4, null), 'F5');
    });

    test('elementTags (plan / BOM / report) carry the name-derived code', () {
      final b = _levels(['Lantai 1', 'Lantai 2']);
      const net = Network(nodes: [
        NetNode(id: 'a', sheetId: 's', x: 0, y: 0, floorIndex: 1),
        NetNode(id: 'b', sheetId: 's', x: 10, y: 0, floorIndex: 1),
      ], edges: [
        NetEdge(id: 'e', fromId: 'a', toId: 'b', service: ServiceType.coldWater),
      ]);
      expect(elementTags(net, building: b)['e'], 'CW-L2');
    });
  });

  group('C-2 electrical riser: boards on their own floors', () {
    test('floorIndex round-trips and decodes tolerantly', () {
      const p = ElectricalPanel(id: 'a', name: 'PP-Lt3', floorIndex: 2);
      expect(ElectricalPanel.fromJson(p.toJson()).floorIndex, 2);
      expect(const ElectricalPanel(id: 'b', name: 'x').toJson(),
          isNot(contains('floorIndex')));
      expect(ElectricalPanel.fromJson({'id': 'c', 'floorIndex': -1}).floorIndex,
          isNull);
      expect(
          ElectricalPanel.fromJson({'id': 'c', 'floorIndex': 'x'}).floorIndex,
          isNull);
      expect(p.copyWith(clearFloorIndex: true).floorIndex, isNull);
    });

    (ElectricalProject, ElectricalSystemResult) solve(
        ReferenceBuilding b, ElectricalProject project) {
      final fault = estimatedServiceFaultLevelA(project) ??
          const Current(defaultLvUtilityFaultKa * 1000);
      return (
        project,
        computeSystem(const PuilProfile(), project,
            calibrationBySheet: b.calibrations,
            building: b.building,
            originFaultLevel: fault,
            busbarClearingTimeS: 0.1,
            phaseReassignThresholdA: 1.0)
      );
    }

    int floorOfName(String n) {
      final m = RegExp(r'^PP-Lt(\d+)$').firstMatch(n);
      return m == null ? 0 : int.parse(m.group(1)!) - 1;
    }

    String pageText(SldSheet s) =>
        [for (final p in s.prims) if (p is SldLabel) p.text].join(' | ');

    test('a declared floorIndex places the board on that band; '
        'a layout placement still wins', () {
      final b = apt.buildApartment();
      final project = b.electrical.withPanels([
        for (final p in b.electrical.panels)
          p.copyWith(floorIndex: floorOfName(p.name)),
      ]);
      final (pr, res) = solve(b, project);
      final floorOf = electricalRiserFloorOf(pr, res, b.building);
      for (var f = 0; f < 12; f++) {
        expect(floorOf[apt.aptFloorPanelId(f)], f, reason: 'PP-Lt${f + 1}');
      }
      expect(floorOf[apt.kAptMainPanelId], 0);
      final placed = pr.withPanels([
        for (final p in pr.panels)
          p.id == apt.aptFloorPanelId(5)
              ? p.copyWith(
                  layoutPos:
                      const LayoutPos(sheetId: 's', floorIndex: 7, x: 0, y: 0))
              : p,
      ]);
      expect(
          electricalRiserFloorOf(placed, res, b.building)[
              apt.aptFloorPanelId(5)],
          7);
    });

    test('every issued riser page carries a board (no label-only page); '
        'storeys left off are listed in the gutter', () {
      final b = apt.buildApartment();
      // Unplaced, no floorIndex: every floor board on one band above ground.
      final (pr, res) = solve(b, b.electrical);
      final pages = paginatedElectricalRiserSheets(
          project: pr, result: res, building: b.building);
      final names = {for (final p in pr.panels) p.name};
      for (final s in pages) {
        final t = pageText(s);
        expect(names.any(t.contains) || t.contains('TIPIKAL'), isTrue,
            reason: 'page without a board: $t');
      }
      final all = pages.map(pageText).join(' ');
      expect(all, contains('TANPA PANEL, DI ATAS:'));
      expect(all, contains('Lantai 12..Lantai 3'));
    });
  });

  group('C-3 building single-line density', () {
    // A main board feeding [n] unit boards; [wayW] varies a board's load.
    ElectricalProject units(int n, {double Function(int i)? wayW}) =>
        ElectricalProject(id: 'a', name: 'A', panels: [
          ElectricalPanel(id: 'MDP', name: 'MDP', circuits: [
            for (var i = 1; i <= n; i++)
              ElectricalCircuit(
                  id: 'f$i',
                  name: 'Unit $i',
                  loadKind: LoadKind.feeder,
                  feedsPanelId: 'U$i',
                  length: Length(10.0 + i)),
          ]),
          for (var i = 1; i <= n; i++)
            ElectricalPanel(
              id: 'U$i',
              name: 'PHB UNIT ${100 + i}',
              system: ElectricalSystem.singlePhase,
              voltage: const Voltage(220),
              sourceType: PanelSource.feeder,
              fedByCircuitId: 'f$i',
              circuits: [
                for (var k = 0; k < 3; k++)
                  ElectricalCircuit(
                      id: 'u$i-$k',
                      name: 'Way $k',
                      loadKind: LoadKind.socket,
                      loadW: wayW?.call(i) ?? 900,
                      cosPhi: 0.9,
                      phases: 1,
                      length: const Length(8)),
              ],
            ),
        ]);

    List<String> labels(SldSheet s) =>
        [for (final p in s.prims) if (p is SldLabel) p.text];

    test('typical groups: identical incomer + ways only, runs of >= 3', () {
      // Unit 105 differs (its ways carry 950 W): it splits the run.
      final pr = units(9, wayW: (i) => i == 5 ? 950 : 900);
      final r = computeSystem(const PuilProfile(), pr);
      final g = electricalOverviewTypicalGroups(pr, r);
      expect(g.values.toList(), [
        ['U1', 'U2', 'U3', 'U4'],
        ['U6', 'U7', 'U8', 'U9'],
      ]);
    });

    test('a typical node prints its name once and tabulates every member '
        'feeder once', () {
      final pr = units(6);
      final r = computeSystem(const PuilProfile(), pr);
      final g = electricalOverviewTypicalGroups(pr, r);
      final s = buildElectricalOverview(
          project: pr, result: r, typicalGroups: g);
      final t = labels(s);
      expect(t.where((x) => x == 'PHB UNIT 101..106 (TIPIKAL x6)'), hasLength(1));
      for (var i = 1; i <= 6; i++) {
        // Each member row in the table, never a second box.
        expect(t.where((x) => x == 'PHB UNIT ${100 + i}'), hasLength(1));
      }
      final feeders = t.where((x) => x.contains('MCB')).toList();
      expect(feeders, hasLength(6)); // one per member, all in the table
      expect(t, contains('FEEDER: LIHAT TABEL / SEE TABLE'));
    });

    test('a wide flat tier packs into a grid of rows (one feeder tag each)',
        () {
      final pr = units(12, wayW: (i) => 500.0 + 50 * i); // all different
      final r = computeSystem(const PuilProfile(), pr);
      final s = buildElectricalOverview(project: pr, result: r, gridColumns: 4);
      final boxes = [
        for (final p in s.prims)
          if (p is SldRect && (p.w - 168).abs() < 1e-6) p,
      ];
      final rowYs = {for (final b in boxes) b.y}..remove(boxes.first.y);
      expect(rowYs, hasLength(3)); // three rows of four under MDP
      final xs = {for (final b in boxes) b.x};
      expect(xs.length, lessThanOrEqualTo(5));
      final t = labels(s);
      expect(t.where((x) => x.contains('MCB')), hasLength(12));
    });

    test('tower: the building single-line issues on <= 4 pages, every page '
        'at the 7 pt floor', () {
      final b = tower.buildTower();
      final fault = estimatedServiceFaultLevelA(b.electrical) ??
          const Current(defaultLvUtilityFaultKa * 1000);
      final r = computeSystem(const PuilProfile(), b.electrical,
          calibrationBySheet: b.calibrations,
          building: b.building,
          originFaultLevel: fault,
          busbarClearingTimeS: 0.1,
          phaseReassignThresholdA: 1.0);
      final pages =
          paginatedElectricalOverviewSheets(project: b.electrical, result: r);
      expect(pages.length, lessThanOrEqualTo(4));
      final all = pages.expand(labels).toList();
      for (var f = 1; f <= 30; f++) {
        expect(all.where((x) => x == 'PP-Lt$f'), hasLength(1),
            reason: 'PP-Lt$f listed once');
      }
    });
  });
}
