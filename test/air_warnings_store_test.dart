import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/air_warnings_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/air_velocity.dart';
import 'package:mechx_engine/units.dart';

NetNode _diffuser({
  required String id,
  required FlowRate airflow,
  double? faceW,
  double? faceH,
  NodeComponent component = NodeComponent.supplyDiffuser,
}) =>
    NetNode(
      id: id,
      sheetId: 's1',
      x: 0,
      y: 0,
      floorIndex: 0,
      role: NodeRole.fixture,
      component: component,
      airflow: airflow,
      faceWidthMm: faceW,
      faceHeightMm: faceH,
    );

void main() {
  test('small face → too-high face-velocity warning', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    // 150×150 gross = 0.0225 m²; free = 0.018; v = 0.2/0.018 = 11.1 m/s ≫ 3.0.
    c.read(networkControllerProvider.notifier).loadNetwork(Network(nodes: [
          _diffuser(id: 'd', airflow: const FlowRate(0.2), faceW: 150, faceH: 150),
        ]));
    final check = c.read(airVelocityChecksProvider)['d']!;
    expect(check.verdict, VelocityBandVerdict.tooHigh);
    expect(check.isWarning, isTrue);
    expect(c.read(airWarningCountProvider), 1);
  });

  test('over-large face on the same airflow → too-low warning', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    // 600×600 gross = 0.36 m²; free = 0.288; v = 0.2/0.288 = 0.69 m/s < 1.0.
    c.read(networkControllerProvider.notifier).loadNetwork(Network(nodes: [
          _diffuser(id: 'd', airflow: const FlowRate(0.2), faceW: 600, faceH: 600),
        ]));
    expect(c.read(airVelocityChecksProvider)['d']!.verdict,
        VelocityBandVerdict.tooLow);
  });

  test('return grille tolerates a higher face velocity than a supply diffuser',
      () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    // 600×150 gross = 0.09 m²; free = 0.072; v = 0.25/0.072 = 3.47 m/s.
    //   Supply band caps at 3.0 (would warn) but a RETURN tolerates up to 4.0.
    c.read(networkControllerProvider.notifier).loadNetwork(Network(nodes: [
          _diffuser(
            id: 'ret',
            airflow: const FlowRate(0.25),
            faceW: 600,
            faceH: 150,
            component: NodeComponent.returnGrille,
          ),
        ]));
    expect(c.read(airVelocityChecksProvider)['ret']!.verdict,
        VelocityBandVerdict.ok);
  });

  test('a diffuser with no chosen face is not judged (nothing to warn about)',
      () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    c.read(networkControllerProvider.notifier).loadNetwork(Network(nodes: [
          _diffuser(id: 'd', airflow: const FlowRate(0.2)),
        ]));
    expect(c.read(airVelocityChecksProvider).containsKey('d'), isFalse);
    expect(c.read(airWarningCountProvider), 0);
  });

  test('an air terminal with no chosen face is flagged as unsized', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    c.read(networkControllerProvider.notifier).loadNetwork(Network(nodes: [
          _diffuser(id: 'd', airflow: const FlowRate(0.1)),
        ]));
    expect(c.read(airUnsizedProvider), contains('d'));
    expect(c.read(airUnsizedCountProvider), 1);
    // It is NOT a velocity warning (nothing to judge without a face).
    expect(c.read(airWarningCountProvider), 0);
  });

  test('choosing a face clears the unsized advisory', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final ctrl = c.read(networkControllerProvider.notifier);
    ctrl.loadNetwork(Network(nodes: [
      _diffuser(id: 'd', airflow: const FlowRate(0.1)),
    ]));
    expect(c.read(airUnsizedProvider), contains('d'));
    ctrl.setNodeFace('d', 300, 300);
    expect(c.read(airUnsizedProvider), isEmpty);
  });

  test('an air duct carrying flow with no size override is flagged unsized', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    // AHU (plant source) → duct → diffuser (airflow): the duct carries 0.1 m³/s.
    c.read(networkControllerProvider.notifier).loadNetwork(Network(
          nodes: [
            const NetNode(
              id: 'ahu',
              sheetId: 's1',
              x: 0,
              y: 0,
              floorIndex: 0,
              role: NodeRole.plant,
              component: NodeComponent.ahu,
            ),
            _diffuser(
                id: 'd', airflow: const FlowRate(0.1), faceW: 300, faceH: 300),
          ],
          edges: [
            const NetEdge(
                id: 'duct', fromId: 'ahu', toId: 'd', service: ServiceType.duct),
          ],
        ));
    // The duct carries air and has no override ⇒ unsized advisory.
    expect(c.read(airUnsizedProvider), contains('duct'));
    // The terminal has a face ⇒ not unsized.
    expect(c.read(airUnsizedProvider).contains('d'), isFalse);
  });

  test('an oversize air duct is flagged over-capacity (badge source)', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    // AHU → duct → diffuser carrying a huge airflow (20 m³/s): no standard duct
    // (≤ 1000 mm round) can hold it within the velocity band, so the auto-sizer
    // CLAMPS to the largest size and flags EdgeSizing.overCapacity — which
    // airOverCapacityProvider surfaces (and the canvas paints as a red triangle).
    c.read(networkControllerProvider.notifier).loadNetwork(Network(
          nodes: [
            const NetNode(
              id: 'ahu',
              sheetId: 's1',
              x: 0,
              y: 0,
              floorIndex: 0,
              role: NodeRole.plant,
              component: NodeComponent.ahu,
            ),
            _diffuser(
                id: 'd', airflow: const FlowRate(20.0), faceW: 600, faceH: 600),
          ],
          edges: [
            const NetEdge(
                id: 'duct', fromId: 'ahu', toId: 'd', service: ServiceType.duct),
          ],
        ));
    expect(c.read(airOverCapacityProvider), contains('duct'));
  });

  test('an in-range air duct is NOT flagged over-capacity', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    c.read(networkControllerProvider.notifier).loadNetwork(Network(
          nodes: [
            const NetNode(
              id: 'ahu',
              sheetId: 's1',
              x: 0,
              y: 0,
              floorIndex: 0,
              role: NodeRole.plant,
              component: NodeComponent.ahu,
            ),
            _diffuser(
                id: 'd', airflow: const FlowRate(0.1), faceW: 300, faceH: 300),
          ],
          edges: [
            const NetEdge(
                id: 'duct', fromId: 'ahu', toId: 'd', service: ServiceType.duct),
          ],
        ));
    expect(c.read(airOverCapacityProvider), isEmpty);
  });

  test('setNodeFace sets then clears the face, preserving the airflow', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final ctrl = c.read(networkControllerProvider.notifier);
    ctrl.loadNetwork(Network(nodes: [
      _diffuser(id: 'd', airflow: const FlowRate(0.05)),
    ]));
    ctrl.setNodeFace('d', 300, 300);
    var n = c.read(networkControllerProvider).network.nodeById('d')!;
    expect(n.faceWidthMm, 300);
    expect(n.faceHeightMm, 300);
    expect(n.airflow!.cubicMetersPerSecond, closeTo(0.05, 1e-12));

    ctrl.setNodeFace('d', null, null);
    n = c.read(networkControllerProvider).network.nodeById('d')!;
    expect(n.faceWidthMm, isNull);
    expect(n.faceHeightMm, isNull);
    expect(n.airflow, isNotNull); // still an air terminal
  });
}
