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
