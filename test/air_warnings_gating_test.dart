/// Gating tests for the air-warnings duct loop (`air_warnings_store.dart`):
/// an AUTO-sized duct must never be judged (the sizing engine's own pick is
/// not re-judged), a MANUALLY-sized duct is judged, and a return/exhaust duct
/// routes through the shared extract-duct band instead of the supply band.
///
/// Expected values are hand-computed; arithmetic shown in comments.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/air_warnings_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/air_velocity.dart';
import 'package:mechx_engine/units.dart';

const _sheetId = 's1';

NetNode _plant(String id) => NetNode(
      id: id,
      sheetId: _sheetId,
      x: 0,
      y: 0,
      floorIndex: 0,
      role: NodeRole.plant,
      component: NodeComponent.ahu,
    );

NetNode _sink({required String id, required FlowRate airflow}) => NetNode(
      id: id,
      sheetId: _sheetId,
      x: 100,
      y: 0,
      floorIndex: 0,
      role: NodeRole.fixture,
      airflow: airflow,
    );

void main() {
  test(
      '1) an AUTO-sized supply duct whose engine-picked velocity is below '
      'band produces NO entry (the sizer rounded up to the smallest '
      'standard 100 mm duct on a small flow — its own unavoidable pick, '
      'not the engineer\'s)', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    // 0.01 m³/s target at the default max duct velocity (5.0 m/s) ⇒ ideal
    // area = 0.01/5.0 = 0.002 m² ⇒ ideal Ø = sqrt(4·0.002/π) ≈ 50.5 mm,
    // rounded UP to the smallest standard 100 mm duct. Actual velocity at
    // 100 mm: area = π·0.05² ≈ 0.0078540 m²; v = 0.01/0.0078540 ≈ 1.27 m/s,
    // well below the 3.0 m/s supply-duct minimum.
    c.read(networkControllerProvider.notifier).loadNetwork(Network(
          nodes: [_plant('ahu'), _sink(id: 'd', airflow: const FlowRate(0.01))],
          edges: [
            const NetEdge(
                id: 'duct', fromId: 'ahu', toId: 'd', service: ServiceType.duct),
          ],
        ));
    expect(c.read(airVelocityChecksProvider).containsKey('duct'), isFalse);
  });

  test(
      '2) a MANUALLY-sized supply duct (sizeOverride set) out of band '
      'produces a warning entry', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    // Same small flow but pinned to a much larger 500 mm duct: area =
    // π·0.25² ≈ 0.19635 m²; v = 0.01/0.19635 ≈ 0.051 m/s ≪ 3.0 min.
    c.read(networkControllerProvider.notifier).loadNetwork(Network(
          nodes: [_plant('ahu'), _sink(id: 'd', airflow: const FlowRate(0.01))],
          edges: [
            const NetEdge(
              id: 'duct',
              fromId: 'ahu',
              toId: 'd',
              service: ServiceType.duct,
              sizeOverride: Diameter(0.5), // 500 mm
            ),
          ],
        ));
    final check = c.read(airVelocityChecksProvider)['duct'];
    expect(check, isNotNull);
    expect(check!.verdict, VelocityBandVerdict.tooLow);
    expect(check.isWarning, isTrue);
  });

  test(
      '3) a MANUALLY-sized EXHAUST duct at 6.5 m/s warns via the extract '
      'band (would PASS the supply band, which caps at 7.0) — proves '
      'service-based routing', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    // Pin a 100 mm duct (area = π·0.05² ≈ 0.0078540 m²) and choose the
    // airflow so v = 6.5 m/s: Q = 6.5 × 0.0078540 ≈ 0.0510509 m³/s.
    c.read(networkControllerProvider.notifier).loadNetwork(Network(
          nodes: [_plant('ahu'), _sink(id: 'd', airflow: const FlowRate(0.0510509))],
          edges: [
            const NetEdge(
              id: 'duct',
              fromId: 'ahu',
              toId: 'd',
              service: ServiceType.exhaust,
              sizeOverride: Diameter(0.1), // 100 mm
            ),
          ],
        ));
    // Sanity: 6.5 m/s is within the SUPPLY band (3.0-7.0) — would be OK there.
    expect(checkSupplyDuctVelocity(const Velocity(6.5)).verdict,
        VelocityBandVerdict.ok);
    // But the extract band caps at 6.0, so it warns too-high.
    final check = c.read(airVelocityChecksProvider)['duct'];
    expect(check, isNotNull);
    expect(check!.verdict, VelocityBandVerdict.tooHigh);
  });

  test(
      '4) terminal gating is unchanged: a supply diffuser with a chosen '
      'face and a too-high face velocity still warns', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    // 150×150 gross = 0.0225 m²; free = 0.018; v = 0.2/0.018 ≈ 11.1 m/s ≫ 3.0.
    c.read(networkControllerProvider.notifier).loadNetwork(Network(nodes: [
          NetNode(
            id: 'd',
            sheetId: _sheetId,
            x: 0,
            y: 0,
            floorIndex: 0,
            role: NodeRole.fixture,
            component: NodeComponent.supplyDiffuser,
            airflow: const FlowRate(0.2),
            faceWidthMm: 150,
            faceHeightMm: 150,
          ),
        ]));
    final check = c.read(airVelocityChecksProvider)['d'];
    expect(check, isNotNull);
    expect(check!.verdict, VelocityBandVerdict.tooHigh);
  });
}
