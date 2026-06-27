import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/design_issues_store.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/selection_store.dart';
import 'package:mechx/store/sheets_store.dart';
import 'package:mechx/store/solve_store.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/units.dart';

void main() {
  group('designIssuesProvider', () {
    ProviderContainer makeContainer() {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      return c;
    }

    test('uncalibrated demo sheets surface as warning issues with sheetId', () {
      final c = makeContainer();
      // The default SheetsState has three demo sheets and no calibration set,
      // so each should appear as a "Sheet not calibrated" warning.
      final issues = c.read(designIssuesProvider);
      final calibIssues =
          issues.where((i) => i.title == 'Sheet not calibrated').toList();
      expect(calibIssues, isNotEmpty);
      expect(calibIssues.every((i) => i.severity == IssueSeverity.warning),
          isTrue);
      // The locate target points at a real demo sheet id.
      final sheetIds =
          c.read(sheetsControllerProvider).sheets.map((s) => s.id).toSet();
      for (final i in calibIssues) {
        expect(i.locate, isNotNull);
        expect(sheetIds.contains(i.locate!.sheetId), isTrue);
      }
    });

    test('out-of-band air duct velocity surfaces with locate edge id', () {
      final c = makeContainer();
      // A duct run whose pinned size is far too large for the carried airflow:
      // a 500 mm Ø duct moving 50 L/s → v = 0.05 / (π·0.25²) ≈ 0.25 m/s, well
      // below the 3 m/s supply-duct minimum ⇒ a "too low" warning.
      const sheetId = 's1';
      final nodeA = NetNode(
        id: 'na',
        sheetId: sheetId,
        x: 0,
        y: 0,
        floorIndex: 0,
        airflow: const FlowRate(0.05),
      );
      const nodeB = NetNode(
        id: 'nb',
        sheetId: sheetId,
        x: 100,
        y: 0,
        floorIndex: 0,
      );
      const edge = NetEdge(
        id: 'e1',
        fromId: 'na',
        toId: 'nb',
        service: ServiceType.duct,
        sizeOverride: Diameter(0.5), // 500 mm
      );
      c.read(networkControllerProvider.notifier).loadNetwork(
            Network(nodes: [nodeA, nodeB], edges: [edge]),
          );

      final issues = c.read(designIssuesProvider);
      final velIssue = issues.firstWhere(
        (i) => i.title == 'Duct velocity out of band',
        orElse: () => fail('expected a duct velocity issue'),
      );
      expect(velIssue.severity, IssueSeverity.warning);
      expect(velIssue.locate, isNotNull);
      expect(velIssue.locate!.edgeId, 'e1');
      expect(velIssue.locate!.sheetId, sheetId);
    });

    test('unverified standards surface as info-level issues', () {
      final c = makeContainer();
      final infos = c
          .read(designIssuesProvider)
          .where((i) => i.title == 'Unverified standard')
          .toList();
      expect(infos, isNotEmpty);
      expect(infos.every((i) => i.severity == IssueSeverity.info), isTrue);
    });

    test('grouping puts all warnings before any info', () {
      final c = makeContainer();
      final issues = c.read(designIssuesProvider);
      final firstInfo =
          issues.indexWhere((i) => i.severity == IssueSeverity.info);
      final lastWarning =
          issues.lastIndexWhere((i) => i.severity == IssueSeverity.warning);
      // Both kinds are present (demo sheets give warnings; standards give info).
      expect(firstInfo, greaterThanOrEqualTo(0));
      expect(lastWarning, greaterThanOrEqualTo(0));
      expect(lastWarning, lessThan(firstInfo));
    });

    test('an over-long drainage branch surfaces as an info issue (locatable)',
        () {
      final c = makeContainer();
      const sheetId = 'sd';
      // Calibrate so 100 px → 40 m (> the 32 m developed-length limit).
      c.read(projectControllerProvider.notifier).setCalibration(
            sheetId,
            const ScaleCalibration(0.4), // 0.4 m/px
          );
      const nodeA =
          NetNode(id: 'da', sheetId: sheetId, x: 0, y: 0, floorIndex: 0);
      const nodeB =
          NetNode(id: 'db', sheetId: sheetId, x: 100, y: 0, floorIndex: 0);
      const edge = NetEdge(
        id: 'ed',
        fromId: 'da',
        toId: 'db',
        service: ServiceType.drainage,
      );
      c.read(networkControllerProvider.notifier).loadNetwork(
            Network(nodes: [nodeA, nodeB], edges: [edge]),
          );

      final issue = c.read(designIssuesProvider).firstWhere(
            (i) => i.title == 'Drainage branch too long',
            orElse: () => fail('expected a drainage developed-length issue'),
          );
      expect(issue.severity, IssueSeverity.info);
      expect(issue.locate, isNotNull);
      expect(issue.locate!.edgeId, 'ed');
      expect(issue.locate!.sheetId, sheetId);
    });

    test('no hot-water network ⇒ no Legionella advisory', () {
      final c = makeContainer();
      // Empty default network has no hot-water loop, so the provider is null and
      // no Legionella issue is raised.
      expect(c.read(hotWaterLegionellaProvider), isNull);
      final legionella = c
          .read(designIssuesProvider)
          .where((i) => i.title == 'Hot-water return temperature low');
      expect(legionella, isEmpty);
    });

    test('locating a duct issue seeds selection + sheet + Layout view', () {
      final c = makeContainer();
      const sheetId = 's2';
      final nodeA = NetNode(
        id: 'na',
        sheetId: sheetId,
        x: 0,
        y: 0,
        floorIndex: 0,
        airflow: const FlowRate(0.05),
      );
      const nodeB = NetNode(
        id: 'nb',
        sheetId: sheetId,
        x: 100,
        y: 0,
        floorIndex: 0,
      );
      const edge = NetEdge(
        id: 'e1',
        fromId: 'na',
        toId: 'nb',
        service: ServiceType.duct,
        sizeOverride: Diameter(0.5),
      );
      c.read(networkControllerProvider.notifier).loadNetwork(
            Network(nodes: [nodeA, nodeB], edges: [edge]),
          );
      // Start somewhere other than where the issue points.
      c.read(workspaceViewProvider.notifier).set(WorkspaceView.electrical);

      final issue = c.read(designIssuesProvider).firstWhere(
            (i) => i.title == 'Duct velocity out of band',
          );
      // Mimic the IssuesCard tap callback.
      final loc = issue.locate!;
      c.read(sheetsControllerProvider.notifier).selectSheetById(loc.sheetId);
      c.read(selectionProvider.notifier).selectEdge(loc.edgeId!);
      c.read(workspaceViewProvider.notifier).set(WorkspaceView.plan);

      expect(c.read(sheetsControllerProvider).current!.id, sheetId);
      expect(c.read(selectionProvider).edgeId, 'e1');
      expect(c.read(workspaceViewProvider), WorkspaceView.plan);
    });
  });
}
