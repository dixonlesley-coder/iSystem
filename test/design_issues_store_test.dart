import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/design_issues_store.dart';
import 'package:mechx/store/electrical_focus_store.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/selection_store.dart';
import 'package:mechx/store/sheets_store.dart';
import 'package:mechx/store/sizing_store.dart';
import 'package:mechx/store/solve_store.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/geometry/building.dart';
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

    test('a drainage stack base without a cleanout surfaces an info advisory; '
        'a served base stays silent', () {
      final c = makeContainer();
      const sheetId = 's1';
      const title = 'Drainage stack has no cleanout at its base';
      // A soil riser dropping from floor 1 to its base on floor 0, no cleanout
      // anywhere — the base is surfaced as a muted (info) locatable advisory.
      const j1 = NetNode(id: 'j1', sheetId: sheetId, x: 0, y: 0, floorIndex: 1);
      const base =
          NetNode(id: 'base', sheetId: sheetId, x: 0, y: 100, floorIndex: 0);
      const soil = NetEdge(
        id: 'soil',
        fromId: 'j1',
        toId: 'base',
        service: ServiceType.drainage,
        kind: EdgeKind.riser,
      );
      c.read(networkControllerProvider.notifier).loadNetwork(
            const Network(nodes: [j1, base], edges: [soil]),
          );
      final issue = c.read(designIssuesProvider).firstWhere(
            (i) => i.title == title,
            orElse: () => fail('expected the cleanout advisory'),
          );
      expect(issue.severity, IssueSeverity.info);
      expect(issue.locate, isNotNull);
      expect(issue.locate!.nodeId, 'base');
      expect(issue.locate!.sheetId, sheetId);

      // Branching a cleanout beside the base clears the advisory (never a
      // fabricated symbol — the engineer placed the real component).
      const co = NetNode(
        id: 'co',
        sheetId: sheetId,
        x: 40,
        y: 100,
        floorIndex: 0,
        role: NodeRole.fixture,
        component: NodeComponent.cleanout,
      );
      const branch = NetEdge(
        id: 'cob',
        fromId: 'base',
        toId: 'co',
        service: ServiceType.drainage,
      );
      c.read(networkControllerProvider.notifier).loadNetwork(
            const Network(nodes: [j1, base, co], edges: [soil, branch]),
          );
      expect(
          c.read(designIssuesProvider).where((i) => i.title == title), isEmpty);
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

    test('an uncalibrated sheet that carries drawn edges escalates to critical',
        () {
      final c = makeContainer();
      // Two nodes joined by a coldWater run on demo sheet s1, which is left
      // uncalibrated — edgeLength returns Length(0), so the run sizes to zero
      // length. That sheet's calibration issue must be CRITICAL.
      const sheetId = 's1';
      const nodeA = NetNode(id: 'na', sheetId: sheetId, x: 0, y: 0, floorIndex: 0);
      const nodeB =
          NetNode(id: 'nb', sheetId: sheetId, x: 100, y: 0, floorIndex: 0);
      const edge = NetEdge(
        id: 'e1',
        fromId: 'na',
        toId: 'nb',
        service: ServiceType.coldWater,
      );
      c.read(networkControllerProvider.notifier).loadNetwork(
            const Network(nodes: [nodeA, nodeB], edges: [edge]),
          );

      final issues = c.read(designIssuesProvider);
      final calib =
          issues.where((i) => i.title == 'Sheet not calibrated').toList();
      // s1 (edge-bearing) is critical; the other edge-free demo sheets stay
      // warning.
      final s1Issue = calib.firstWhere((i) => i.locate?.sheetId == 's1');
      expect(s1Issue.severity, IssueSeverity.critical);
      expect(
          calib.where((i) => i.severity == IssueSeverity.warning), isNotEmpty);
      expect(c.read(designIssueCriticalCountProvider), greaterThanOrEqualTo(1));
    });

    test('a blank uncalibrated sheet stays a warning (byte-identical)', () {
      final c = makeContainer();
      // Default empty network: no sheet bears edges, so every demo-sheet
      // calibration issue is a plain warning and NONE is critical.
      final calib = c
          .read(designIssuesProvider)
          .where((i) => i.title == 'Sheet not calibrated')
          .toList();
      expect(calib, isNotEmpty);
      expect(calib.every((i) => i.severity == IssueSeverity.warning), isTrue);
      expect(c.read(designIssueCriticalCountProvider), 0);
    });

    test('a source-less pressurized component surfaces a "Network has no '
        'source" warning locatable to its sheet', () {
      final c = makeContainer();
      const sheetId = 's1';
      // A coldWater run A–B with no plant/source. (s1 is also uncalibrated, but
      // that is a separate calibration issue.)
      const nodeA = NetNode(id: 'a', sheetId: sheetId, x: 0, y: 0, floorIndex: 0);
      const nodeB = NetNode(
          id: 'b',
          sheetId: sheetId,
          x: 100,
          y: 0,
          floorIndex: 0,
          role: NodeRole.fixture);
      const edge = NetEdge(
        id: 'e1',
        fromId: 'a',
        toId: 'b',
        service: ServiceType.coldWater,
      );
      c.read(networkControllerProvider.notifier).loadNetwork(
            const Network(nodes: [nodeA, nodeB], edges: [edge]),
          );

      final issue = c.read(designIssuesProvider).firstWhere(
            (i) => i.title == 'Network has no source',
            orElse: () => fail('expected a no-source connectivity issue'),
          );
      expect(issue.severity, IssueSeverity.warning);
      expect(issue.locate, isNotNull);
      expect(issue.locate!.sheetId, sheetId);
    });

    test('grouping still puts critical + warning before info', () {
      final c = makeContainer();
      // An edge-bearing uncalibrated sheet ⇒ a critical issue present.
      const nodeA = NetNode(id: 'na', sheetId: 's1', x: 0, y: 0, floorIndex: 0);
      const nodeB = NetNode(id: 'nb', sheetId: 's1', x: 100, y: 0, floorIndex: 0);
      const edge = NetEdge(
          id: 'e1', fromId: 'na', toId: 'nb', service: ServiceType.coldWater);
      c.read(networkControllerProvider.notifier).loadNetwork(
            const Network(nodes: [nodeA, nodeB], edges: [edge]),
          );

      final issues = c.read(designIssuesProvider);
      expect(issues.any((i) => i.severity == IssueSeverity.critical), isTrue);
      final firstInfo =
          issues.indexWhere((i) => i.severity == IssueSeverity.info);
      final lastNonInfo = issues.lastIndexWhere(
          (i) => i.severity != IssueSeverity.info);
      expect(firstInfo, greaterThanOrEqualTo(0));
      // Every critical + warning precedes every info: order [critical, warning,
      // info].
      expect(lastNonInfo, lessThan(firstInfo));
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

    test(
        'zeroLengthSizedEdgeCountProvider counts only SIZED edges that resolve '
        'to zero length on an uncalibrated sheet', () {
      final c = makeContainer();
      // An empty default network has no sized edges ⇒ the loop is empty ⇒ 0.
      expect(c.read(zeroLengthSizedEdgeCountProvider), 0);
      expect(c.read(exportHasZeroLengthEdgesProvider), isFalse);

      // A single horizontal cold-water run on the UNCALIBRATED demo sheet s1.
      // It is auto-sized (appears in sizingProvider), and edgeLength returns
      // Length(0) for an uncalibrated run (network.dart) ⇒ count 1.
      const sheetId = 's1';
      const nodeA =
          NetNode(id: 'na', sheetId: sheetId, x: 0, y: 0, floorIndex: 0);
      const nodeB =
          NetNode(id: 'nb', sheetId: sheetId, x: 100, y: 0, floorIndex: 0);
      const edge = NetEdge(
        id: 'e1',
        fromId: 'na',
        toId: 'nb',
        service: ServiceType.coldWater,
      );
      c.read(networkControllerProvider.notifier).loadNetwork(
            const Network(nodes: [nodeA, nodeB], edges: [edge]),
          );
      // Sanity: the edge actually got sized (so the loop body runs for it).
      expect(c.read(sizingProvider).containsKey('e1'), isTrue);
      expect(c.read(zeroLengthSizedEdgeCountProvider), 1);
      expect(c.read(exportHasZeroLengthEdgesProvider), isTrue);

      // Calibrate s1 (100 px = 1 m): the run now resolves to a positive length,
      // so it drops out of the count.
      c.read(projectControllerProvider.notifier).setCalibration(
            sheetId,
            const ScaleCalibration(0.01), // 0.01 m/px ⇒ 100 px = 1 m
          );
      expect(c.read(zeroLengthSizedEdgeCountProvider), 0);
      expect(c.read(exportHasZeroLengthEdgesProvider), isFalse);
    });

    test(
        'a riser (vertical) edge is NOT counted as zero-length even on an '
        'uncalibrated sheet', () {
      final c = makeContainer();
      // Two floors with distinct true elevations: floor 0 ground, floor 1 above.
      c.read(projectControllerProvider.notifier).setFloors(const [
        Floor('L1', Length(3.0)),
        Floor('L2', Length(3.0)),
      ]);
      const sheetId = 's1'; // left UNCALIBRATED on purpose
      const nodeA = NetNode(
          id: 'ra', sheetId: sheetId, x: 0, y: 0, floorIndex: 0);
      const nodeB = NetNode(
          id: 'rb', sheetId: sheetId, x: 0, y: 0, floorIndex: 1);
      const edge = NetEdge(
        id: 'er',
        fromId: 'ra',
        toId: 'rb',
        service: ServiceType.coldWater,
        kind: EdgeKind.riser,
      );
      c.read(networkControllerProvider.notifier).loadNetwork(
            const Network(nodes: [nodeA, nodeB], edges: [edge]),
          );
      // edgeLength for a riser uses the |elevation delta| (> 0), never the
      // calibration, so the guard must NOT count it even on an uncalibrated
      // sheet — the guard keys off the engine's §10 length, not just
      // "uncalibrated sheet".
      expect(c.read(sizingProvider).containsKey('er'), isTrue);
      expect(c.read(zeroLengthSizedEdgeCountProvider), 0);
      expect(c.read(exportHasZeroLengthEdgesProvider), isFalse);
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

  group('electrical warnings fan-in', () {
    ProviderContainer makeContainer() {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      return c;
    }

    // A single-phase panel with one heavy socket way crushed by an extreme
    // derating (60 °C ambient ⇒ ×0.5, 9 grouped circuits ⇒ ×0.5 ⇒ df 0.25) so
    // even the largest cable can't reach the required Iz: the breaker In then
    // exceeds the conductor Iz ⇒ a `cable-ampacity-inadequate` ERROR warning.
    // (Mirrors the engine's electrical_compute_test fixture.)
    const heavyPanel = ElectricalPanel(
      id: 'HV',
      name: 'Heavy',
      system: ElectricalSystem.singlePhase,
      voltage: Voltage(230),
      ambientTempC: 60,
      groupingCount: 9,
      circuits: [
        ElectricalCircuit(
          id: 'big',
          name: 'Big load',
          loadKind: LoadKind.socket,
          loadW: 200000, // ~870 A single-phase
          cosPhi: 1.0,
          length: Length(5),
        ),
      ],
    );

    test('an error-severity electrical warning surfaces as a critical '
        'DesignIssue located on its panel', () {
      final c = makeContainer();
      c.read(electricalProjectProvider.notifier).setProject(
            const ElectricalProject(id: 'p', name: 'p', panels: [heavyPanel]),
          );

      // Sanity: the solved system really does raise the error warning.
      final elec = c.read(electricalResultProvider);
      final w = elec.warnings
          .where((w) => w.code == 'cable-ampacity-inadequate')
          .toList();
      expect(w, hasLength(1));

      final issues = c.read(designIssuesProvider);
      final issue = issues.firstWhere(
        (i) => i.title == 'Electrical: cable ampacity inadequate',
        orElse: () => fail('expected an electrical ampacity DesignIssue'),
      );
      // error ⇒ critical, and it locates on the panel (not a sheet).
      expect(issue.severity, IssueSeverity.critical);
      expect(issue.message, w.single.message);
      expect(issue.locate, isNotNull);
      expect(issue.locate!.panelId, 'HV');
      expect(issue.locate!.circuitId, 'big');
      expect(issue.locate!.sheetId, '');
      // It bumps the critical count the export gate reads.
      expect(c.read(designIssueCriticalCountProvider), greaterThanOrEqualTo(1));
    });

    test('an empty electrical project adds no electrical issues '
        '(mechanical list byte-identical)', () {
      final c = makeContainer();
      // Baseline mechanical-only issue list (default network + the sample
      // electrical project's own non-error warnings, if any).
      c.read(electricalProjectProvider.notifier).setProject(
            const ElectricalProject(id: 'e', name: 'e'),
          );
      final issues = c.read(designIssuesProvider);
      // No electrical-sourced issue title and no panel-located issue at all.
      expect(issues.where((i) => i.title.startsWith('Electrical:')), isEmpty);
      expect(issues.where((i) => i.locate?.panelId != null), isEmpty);
      // An empty electrical system raises no error warnings ⇒ no criticals from
      // the electrical side (the default demo network is blank ⇒ 0 criticals).
      expect(c.read(designIssueCriticalCountProvider), 0);
    });

    test('locate-request store round-trip: request then clear', () {
      final c = makeContainer();
      expect(c.read(electricalFocusProvider), isNull);
      c.read(electricalFocusProvider.notifier).request('MDP');
      expect(c.read(electricalFocusProvider), 'MDP');
      c.read(electricalFocusProvider.notifier).clear();
      expect(c.read(electricalFocusProvider), isNull);
    });
  });
}
