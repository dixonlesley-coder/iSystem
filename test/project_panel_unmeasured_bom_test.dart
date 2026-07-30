/// L-1 — an uncalibrated sheet has no measurable length, so a run drawn on
/// it sizes to an exact-zero [BomLine.totalLength]. Before this fix that
/// printed as a MEASURED "0.0 m ×N" — reading as a real (tiny) measurement
/// rather than "we don't know". A BOM line with totalLength exactly 0 and a
/// positive segmentCount must instead render "unmeasured ×N", and the 'BOM
/// total' row must flip to "measured-total m + unmeasured" whenever at least one
/// such line exists — while a fully-measured project renders the exact
/// legacy strings unchanged.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/app.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';

import 'test_util.dart';

void main() {
  testWidgets(
      'an uncalibrated run renders "unmeasured ×N" instead of a fabricated '
      '"0.0 m" measurement, and the BOM total gains a "+ unmeasured" suffix',
      (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(MechXApp)),
      listen: false,
    );
    seedDemoSheets(container);
    await tester.pump();

    // A single cold-water run on the UNCALIBRATED demo sheet s1 — it sizes
    // to ZERO length (no scale to convert pixels into metres).
    const nodeA = NetNode(id: 'na', sheetId: 's1', x: 0, y: 0, floorIndex: 0);
    const nodeB =
        NetNode(id: 'nb', sheetId: 's1', x: 100, y: 0, floorIndex: 0);
    const edge = NetEdge(
        id: 'e1', fromId: 'na', toId: 'nb', service: ServiceType.coldWater);
    container.read(networkControllerProvider.notifier).loadNetwork(
          const Network(nodes: [nodeA, nodeB], edges: [edge]),
        );
    await tester.pump();

    // The per-line row is honest ("unmeasured"), never a fabricated zero.
    expect(find.text('unmeasured ×1'), findsOneWidget);
    expect(find.text('0.0 m ×1'), findsNothing);

    // The BOM total flips to the "measured + unmeasured" split rather than
    // implying the whole take-off is a real 0.0 m.
    expect(find.text('0.0 m + unmeasured'), findsOneWidget);
    expect(find.text('0.0 m'), findsNothing);
  });

  testWidgets(
      'a fully-measured (calibrated) project renders the exact legacy BOM '
      'strings — no "unmeasured" language appears', (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(MechXApp)),
      listen: false,
    );
    seedDemoSheets(container);
    await tester.pump();

    // Calibrate s1 at 0.02 m/px, then draw a run of a known real length:
    // 100 px * 0.02 m/px = 2.0 m exactly.
    container
        .read(projectControllerProvider.notifier)
        .setCalibration('s1', const ScaleCalibration(0.02));
    const nodeA = NetNode(id: 'na', sheetId: 's1', x: 0, y: 0, floorIndex: 0);
    const nodeB =
        NetNode(id: 'nb', sheetId: 's1', x: 100, y: 0, floorIndex: 0);
    const edge = NetEdge(
        id: 'e1', fromId: 'na', toId: 'nb', service: ServiceType.coldWater);
    container.read(networkControllerProvider.notifier).loadNetwork(
          const Network(nodes: [nodeA, nodeB], edges: [edge]),
        );
    await tester.pump();

    // Legacy per-line + total strings, byte-identical to the pre-fix output.
    expect(find.text('2.0 m ×1'), findsOneWidget);
    expect(find.text('2.0 m'), findsOneWidget);

    // No trace of the new "unmeasured" language on a fully-measured project.
    expect(find.textContaining('unmeasured'), findsNothing);
  });

  testWidgets(
      'a mixed project (one measured line, one unmeasured line) renders '
      'both honestly in the same BOM', (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(MechXApp)),
      listen: false,
    );
    seedDemoSheets(container);
    await tester.pump();

    // s2 is calibrated (measured); s1 stays uncalibrated (unmeasured). Two
    // DIFFERENT services so they never collapse into one BOM line.
    container
        .read(projectControllerProvider.notifier)
        .setCalibration('s2', const ScaleCalibration(0.02));

    const nodeA = NetNode(id: 'na', sheetId: 's1', x: 0, y: 0, floorIndex: 0);
    const nodeB =
        NetNode(id: 'nb', sheetId: 's1', x: 100, y: 0, floorIndex: 0);
    const edgeUnmeasured = NetEdge(
        id: 'e1', fromId: 'na', toId: 'nb', service: ServiceType.coldWater);

    const nodeC = NetNode(id: 'nc', sheetId: 's2', x: 0, y: 0, floorIndex: 0);
    const nodeD =
        NetNode(id: 'nd', sheetId: 's2', x: 100, y: 0, floorIndex: 0);
    const edgeMeasured = NetEdge(
        id: 'e2', fromId: 'nc', toId: 'nd', service: ServiceType.hotWater);

    container.read(networkControllerProvider.notifier).loadNetwork(
          const Network(
            nodes: [nodeA, nodeB, nodeC, nodeD],
            edges: [edgeUnmeasured, edgeMeasured],
          ),
        );
    await tester.pump();

    // Both lines render, each honestly: the measured one keeps its real
    // figure, the unmeasured one never fabricates a zero.
    expect(find.text('unmeasured ×1'), findsOneWidget);
    expect(find.text('2.0 m ×1'), findsOneWidget);

    // Total = the real measured total (2.0 m) plus the honest suffix.
    expect(find.text('2.0 m + unmeasured'), findsOneWidget);
  });
}
