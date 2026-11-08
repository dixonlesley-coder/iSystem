// Round 22 (2026-10-18) — the app half of the round-22 audit:
//
//   basement-datum-paste-to-floors-reversed-labels
//                       each 'Paste selection to floors' row names ITS floor
//   edit-fuzz-2-mep-loadpos-desync
//                       floor edits re-derive MEP load positions once
//   edit-fuzz-2-mep-edits-silently-reverted
//                       derived ways / the MEP board refuse delete & merge
//   edit-fuzz-2-mep-feeder-id-regenerated
//                       the auto-wired MEP feeder has a deterministic id
//   pressurized-3-1     a tank-head-only building gets no PRV zone

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/app_state.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx/store/history_store.dart';
import 'package:mechx/store/models/sheet.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/sheets_store.dart';
import 'package:mechx/store/solve_store.dart';
import 'package:mechx/ui/shell/duplicate_floor_dialog.dart';
import 'package:mechx/ui/theme/mechx_theme.dart';
import 'package:mechx_engine/electrical/geo_length.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';

import 'test_util.dart';

ProviderContainer _c() {
  final c = ProviderContainer();
  addTearDown(c.dispose);
  return c;
}

const _size = Size(1000, 800);
List<Sheet> _pages(int n) => [
      for (var i = 1; i <= n; i++)
        Sheet(id: 'p$i', name: 'Page $i', sizePx: _size),
    ];

Widget _host(Widget child) => WidgetsApp(
      color: const Color(0xFF000000),
      pageRouteBuilder: <T>(RouteSettings settings, WidgetBuilder builder) =>
          PageRouteBuilder<T>(
        settings: settings,
        pageBuilder: (context, _, _) => builder(context),
      ),
      home: MechXTheme(data: MechXThemeData.dark, child: child),
    );

/// The AC unit's id + its derived MEP way.
({NetNode node, ElectricalCircuit way, double lengthM}) _mep(
    ProviderContainer c) {
  final node = c
      .read(networkControllerProvider)
      .network
      .nodes
      .firstWhere((n) => n.component == NodeComponent.acDucted);
  final board = c
      .read(electricalProjectProvider)
      .panels
      .firstWhere((p) => p.id == kMepEquipmentPanelId);
  final way = board.circuits.firstWhere((w) => w.sourceEquipmentId != null);
  final r = c
      .read(electricalResultProvider)
      .panels[kMepEquipmentPanelId]!
      .circuits
      .firstWhere((x) => x.circuitId == way.id);
  return (node: node, way: way, lengthM: r.lengthM);
}

Future<ProviderContainer> _acOnP2() async {
  final c = _c();
  c.read(sheetsControllerProvider.notifier).loadSheets(_pages(2));
  c
      .read(projectControllerProvider.notifier)
      .setCalibration('p2', const ScaleCalibration(0.02));
  c.read(electricalProjectProvider); // build the controller (its listener)
  c.read(networkControllerProvider.notifier).addComponentNode(
      'p2', 1, const Offset(700, 200), NodeComponent.acDucted);
  await Future<void>.delayed(Duration.zero);
  c.read(electricalProjectProvider);
  c.read(electricalProjectProvider.notifier).setPanelLayoutPos(
      kMepEquipmentPanelId,
      const LayoutPos(sheetId: 'p2', floorIndex: 1, x: 400, y: 200));
  return c;
}

void main() {
  // ── paste-to-floors labels ────────────────────────────────────────────────
  testWidgets('the top row is the TOP floor: Level 2 pastes onto floor 2',
      (tester) async {
    setDesktopSurface(tester);
    late BuildContext dialogContext;
    final rootKey = GlobalKey();
    await tester.pumpWidget(ProviderScope(
      child: _host(Builder(builder: (context) {
        dialogContext = context;
        return SizedBox.expand(key: rootKey);
      })),
    ));
    final c = ProviderScope.containerOf(rootKey.currentContext!);
    seedDemoSheets(c); // s1→Ground(0), s2→Level 1(1), s3→Level 2(2)
    final net = c.read(networkControllerProvider.notifier);
    net.setService(ServiceType.coldWater);
    net.setTool(DrawTool.drawRun);
    net.placeRunPoint('s1', 0, const Offset(100, 100));
    net.placeRunPoint('s1', 0, const Offset(300, 100));
    net.setTool(DrawTool.select);
    final network = c.read(networkControllerProvider).network;
    net.copySelection({for (final n in network.nodes) n.id},
        {for (final e in network.edges) e.id});
    await tester.pumpAndSettle();

    showPasteToFloorsDialog(dialogContext);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Level 2'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Paste'));
    await tester.pumpAndSettle();

    final byFloor = <int, int>{};
    final after = c.read(networkControllerProvider).network;
    for (final e in after.edges) {
      final f = after.nodeById(e.fromId)!.floorIndex;
      byFloor[f] = (byFloor[f] ?? 0) + 1;
    }
    // The source run stays on Ground; the copy lands on Level 2 (floor 2),
    // never stacked onto the source floor.
    expect(byFloor, {0: 1, 2: 1});
  });

  // ── MEP load positions follow their node once ─────────────────────────────
  group('edit-fuzz-2 MEP load position', () {
    test('baseline: 300 px × 0.02 m/px = 6.0 m', () async {
      final c = await _acOnP2();
      final m = _mep(c);
      expect(m.way.loadPos!.floorIndex, m.node.floorIndex);
      expect(m.lengthM, closeTo(6.0, 1e-9));
    });

    test('addBasement moves the way with its node (no phantom storey)',
        () async {
      final c = await _acOnP2();
      c.read(projectControllerProvider.notifier).addBasement(1, 3.0);
      final m = _mep(c);
      expect(m.node.floorIndex, 2);
      expect(m.way.loadPos!.floorIndex, 2);
      expect(m.lengthM, closeTo(6.0, 1e-9));
    });

    test('removeFloor(0) keeps the way placed with its node', () async {
      final c = await _acOnP2();
      c.read(projectControllerProvider.notifier).removeFloor(0);
      final m = _mep(c);
      expect(m.node.floorIndex, 0);
      expect(m.way.loadPos, isNotNull);
      expect(m.way.loadPos!.floorIndex, 0);
      expect(m.lengthM, closeTo(6.0, 1e-9));
    });
  });

  // ── MEP-derived rows refuse delete / merge ────────────────────────────────
  group('edit-fuzz-2 MEP derived rows', () {
    test('deleting a derived way is refused with a message', () async {
      final c = await _acOnP2();
      final e = c.read(electricalProjectProvider.notifier);
      final way = _mep(c).way;
      final before = c.read(electricalProjectProvider);
      e.deleteCircuit(kMepEquipmentPanelId, way.id);
      expect(identical(c.read(electricalProjectProvider), before), isTrue);
      expect(e.isMepDerivedWay(kMepEquipmentPanelId, way.id), isTrue);
      expect(c.read(statusMessageProvider), contains('equipment on the plan'));
    });

    test('merging a derived way and deleting the MEP board are refused',
        () async {
      final c = await _acOnP2();
      final e = c.read(electricalProjectProvider.notifier);
      final way = _mep(c).way;
      e.addCircuit(kMepEquipmentPanelId, kind: LoadKind.socket);
      final hand = c
          .read(electricalProjectProvider)
          .panels
          .firstWhere((p) => p.id == kMepEquipmentPanelId)
          .circuits
          .firstWhere((w) => w.sourceEquipmentId == null);
      final before = c.read(electricalProjectProvider);
      e.mergeCircuit(kMepEquipmentPanelId, hand.id, way.id);
      e.mergeCircuit(kMepEquipmentPanelId, way.id, hand.id);
      e.deletePanel(kMepEquipmentPanelId);
      e.deletePanels([kMepEquipmentPanelId]);
      expect(identical(c.read(electricalProjectProvider), before), isTrue);
      expect(e.isMepBoardLocked(kMepEquipmentPanelId), isTrue);
      // A user-added way on the same board is still deletable.
      e.deleteCircuit(kMepEquipmentPanelId, hand.id);
      expect(
          c
              .read(electricalProjectProvider)
              .panels
              .firstWhere((p) => p.id == kMepEquipmentPanelId)
              .circuits
              .any((w) => w.id == hand.id),
          isFalse);
    });
  });

  // ── deterministic MEP feeder id ───────────────────────────────────────────
  test('undo → redo of placing equipment re-creates the same feeder id',
      () async {
    final c = _c();
    seedDemoSheets(c);
    final e = c.read(electricalProjectProvider.notifier);
    e.addPanelAt(name: 'MDP', x: 0, y: 0);
    final mdp = c.read(electricalProjectProvider).panels.single.id;
    e.addCircuit(mdp, kind: LoadKind.lighting);
    c.read(networkControllerProvider.notifier).addComponentNode(
        's1', 0, const Offset(700, 200), NodeComponent.fcu);
    await Future<void>.delayed(Duration.zero);
    List<String> feeders() => [
          for (final p in c.read(electricalProjectProvider).panels)
            for (final w in p.circuits)
              if (w.feedsPanelId == kMepEquipmentPanelId) w.id,
        ];
    expect(feeders(), [kMepEquipmentFeederId]);
    final board = c
        .read(electricalProjectProvider)
        .panels
        .firstWhere((p) => p.id == kMepEquipmentPanelId);
    expect(board.fedByCircuitId, kMepEquipmentFeederId);
    c.read(historyProvider.notifier).undo();
    await Future<void>.delayed(Duration.zero);
    c.read(electricalProjectProvider);
    expect(feeders(), isEmpty);
    c.read(historyProvider.notifier).redo();
    await Future<void>.delayed(Duration.zero);
    c.read(electricalProjectProvider);
    expect(feeders(), [kMepEquipmentFeederId]);
  });

  // ── tank-head-only building: no PRV zone ──────────────────────────────────
  test('a 3-storey downfeed under the tank head needs no PRV station', () {
    final c = _c();
    seedDemoSheets(c);
    c.read(feedStrategyProvider.notifier).set(FeedStrategy.downfeed);
    final statics = c.read(zoneStaticsProvider);
    expect(statics.length, 1);
    expect(statics.single.viaPrv, isFalse);
    expect(statics.single.withinLimit, isTrue);
  });
}
