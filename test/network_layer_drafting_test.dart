import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/sizing_store.dart';
import 'package:mechx/ui/canvas/network_layer.dart';
import 'package:mechx/ui/canvas/service_style.dart';
import 'package:mechx_engine/network/network.dart';
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
}
