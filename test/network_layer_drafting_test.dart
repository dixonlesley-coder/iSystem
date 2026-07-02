import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/selection_store.dart';
import 'package:mechx/store/sizing_store.dart';
import 'package:mechx/ui/canvas/network_layer.dart';
import 'package:mechx/ui/canvas/service_style.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/riser_tags.dart';
import 'package:mechx_engine/units.dart';

/// On-canvas drafting upgrade (CAD review E1 linetypes / E2 labels / E3 flow
/// arrows). The pixel result is verified centrally by the golden screenshots;
/// these are the non-golden guards — the pure linetype lookup, the engine→app
/// flow-orientation wiring, and that the new paint paths render without throwing.
void main() {
  group('serviceDashPattern (E1 linetypes)', () {
    test('vent and return air read dashed [6, 4]', () {
      expect(serviceDashPattern(ServiceType.vent), [6, 4]);
      expect(serviceDashPattern(ServiceType.returnAir), [6, 4]);
    });

    test('the two fire services read dash-dot [10, 3, 2, 3]', () {
      expect(serviceDashPattern(ServiceType.fireSprinkler), [10, 3, 2, 3]);
      expect(serviceDashPattern(ServiceType.fireHydrant), [10, 3, 2, 3]);
    });

    test('every other service is solid (null)', () {
      for (final s in const [
        ServiceType.coldWater,
        ServiceType.hotWater,
        ServiceType.drainage,
        ServiceType.rainwater,
        ServiceType.duct,
        ServiceType.exhaust,
      ]) {
        expect(serviceDashPattern(s), isNull, reason: '$s should be solid');
      }
    });
  });

  // A network with one edge of every linetype class plus a supply edge that the
  // solve can orient (chevron), all far enough apart on the identity viewport to
  // exceed the LOD/chevron length thresholds.
  Network seedNet() => const Network(
        nodes: [
          NetNode(id: 'src', sheetId: 's1', x: 20, y: 40, floorIndex: 0),
          NetNode(
            id: 'd',
            sheetId: 's1',
            x: 320,
            y: 40,
            floorIndex: 0,
            role: NodeRole.fixture,
            airflow: FlowRate(0.5),
          ),
          NetNode(id: 'v1', sheetId: 's1', x: 20, y: 120, floorIndex: 0),
          NetNode(id: 'v2', sheetId: 's1', x: 320, y: 120, floorIndex: 0),
          NetNode(id: 'f1', sheetId: 's1', x: 20, y: 200, floorIndex: 0),
          NetNode(id: 'f2', sheetId: 's1', x: 320, y: 200, floorIndex: 0),
        ],
        edges: [
          NetEdge(id: 'duct', fromId: 'src', toId: 'd', service: ServiceType.duct),
          NetEdge(id: 'vent', fromId: 'v1', toId: 'v2', service: ServiceType.vent),
          NetEdge(
            id: 'fire',
            fromId: 'f1',
            toId: 'f2',
            service: ServiceType.fireSprinkler,
          ),
        ],
      );

  test('the solve threads flow orientation into the app sizing map (E3 wiring)',
      () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    c.read(networkControllerProvider.notifier).loadNetwork(seedNet());
    final sizing = c.read(sizingProvider);

    // Supply (air + pressurized) edges are oriented FROM their source node.
    expect(sizing['duct']!.flowFromId, 'src');
    expect(sizing['fire']!.flowFromId, 'f1');
    // A vent carries no flow → no direction.
    expect(sizing['vent']!.flowFromId, isNull);
  });

  testWidgets(
      'NetworkLayer paints dashed / dash-dot / oriented runs + labels without '
      'throwing', (tester) async {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    c.read(networkControllerProvider.notifier).loadNetwork(seedNet());
    c.read(showSizingProvider.notifier).toggle(); // draw the rotated labels too

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: const Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            width: 400,
            height: 300,
            child: NetworkLayer(sheetId: 's1', floorIndex: 0),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
  });

  // A network spanning two floors with a cold-water riser and a second plumbing
  // service (drainage) so the multi-service label path (E6) and the riser-tag
  // markers exercise, on a CALIBRATED sheet so the E4 true-width branch runs.
  Network riserNet() => const Network(
        nodes: [
          NetNode(id: 'cw0', sheetId: 's1', x: 100, y: 100, floorIndex: 0),
          NetNode(id: 'cw1', sheetId: 's1', x: 100, y: 100, floorIndex: 1),
          NetNode(id: 'cwEnd', sheetId: 's1', x: 400, y: 100, floorIndex: 0),
          NetNode(id: 'd0', sheetId: 's1', x: 200, y: 260, floorIndex: 0),
          NetNode(id: 'd1', sheetId: 's1', x: 460, y: 260, floorIndex: 0),
        ],
        edges: [
          NetEdge(
            id: 'cwRiser',
            fromId: 'cw0',
            toId: 'cw1',
            service: ServiceType.coldWater,
            kind: EdgeKind.riser,
          ),
          NetEdge(
            id: 'cwRun',
            fromId: 'cw0',
            toId: 'cwEnd',
            service: ServiceType.coldWater,
          ),
          NetEdge(
            id: 'dRun',
            fromId: 'd0',
            toId: 'd1',
            service: ServiceType.drainage,
          ),
        ],
      );

  test('the engine assigns a per-service riser tag the layer draws (E6)', () {
    // The layer reads riserTags(net, null) and riserServiceCode from the engine;
    // guard the wiring — a cold-water riser is tagged CW-R1.
    final tags = riserTags(riserNet(), null);
    expect(tags['cwRiser'], 'CW-R1');
    expect(riserServiceCode(ServiceType.coldWater), 'CW');
    expect(riserServiceCode(ServiceType.drainage), 'D');
  });

  testWidgets(
      'NetworkLayer paints a calibrated multi-service network with a riser + a '
      'hovered element without throwing (E4 true-width / E6 tags / E7 hover)',
      (tester) async {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    c.read(networkControllerProvider.notifier).loadNetwork(riserNet());
    // Calibrate so the E4 physical-footprint branch is exercised.
    c
        .read(projectControllerProvider.notifier)
        .setCalibration('s1', const ScaleCalibration(0.01));
    c.read(showSizingProvider.notifier).toggle(); // draw the DN-CW labels
    // Hover an edge → the subtler halo paints under any selection halo.
    c.read(hoverTargetProvider.notifier).set((nodeId: null, edgeId: 'cwRun'));

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: const Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            width: 500,
            height: 400,
            child: NetworkLayer(sheetId: 's1', floorIndex: 0),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);

    // A STALE hover id (an element that no longer exists) must be tolerated —
    // the painter iterates real elements, so it simply matches nothing.
    c.read(hoverTargetProvider.notifier).set((nodeId: 'ghost', edgeId: null));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
