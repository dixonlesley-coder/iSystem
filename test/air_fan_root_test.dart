import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/electrical_feed.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/sizing_store.dart';
import 'package:mechx/store/solve_store.dart';
import 'package:mechx_engine/electrical/load_list.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/duct_static.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/fan.dart';
import 'package:mechx_engine/units.dart';

/// Source n2 at x=0, a junction n3 30 m along (0.01 m/px), and two diffusers
/// n10 (2 m past the junction) and n11 (10 m past), 0.2 m³/s each. No AHU
/// node: the fan must root at the SIZER's source (n2), not at 'n10' — which
/// is lexicographically smaller than 'n2'.
Network _airTree(ServiceType service) {
  NetNode n(String id, double x, {FlowRate? airflow}) => NetNode(
        id: id,
        sheetId: 's1',
        x: x,
        y: 0,
        floorIndex: 0,
        role: NodeRole.main,
        airflow: airflow,
      );
  const q = FlowRate(0.2);
  return Network(
    nodes: [
      n('n2', 0),
      n('n3', 3000),
      n('n10', 3200, airflow: q),
      n('n11', 4000, airflow: q),
    ],
    edges: [
      NetEdge(id: 'e1', fromId: 'n2', toId: 'n3', service: service),
      NetEdge(id: 'e2', fromId: 'n3', toId: 'n10', service: service),
      NetEdge(id: 'e3', fromId: 'n3', toId: 'n11', service: service),
    ],
  );
}

ProviderContainer _container(ServiceType service) {
  final c = ProviderContainer();
  c
      .read(projectControllerProvider.notifier)
      .setCalibration('s1', const ScaleCalibration(0.01));
  c.read(networkControllerProvider.notifier).loadNetwork(_airTree(service));
  return c;
}

Pressure _staticFrom(ProviderContainer c, ServiceType service, String fan) {
  final net = c.read(sizingNetworkProvider);
  final sizing = c.read(sizingProvider);
  final project = c.read(projectControllerProvider);
  return solveDuctStatic(
    net: net,
    service: service,
    fanNodeId: fan,
    edgeFlows: {for (final e in sizing.entries) e.key: e.value.flow},
    sizing: sizing,
    calibrationBySheet: project.calibrations,
    building: project.building,
  ).totalStaticPressure;
}

void main() {
  test('wiring-4: supply fan static is rooted at the sizer source, not n10', () {
    final c = _container(ServiceType.duct);
    addTearDown(c.dispose);
    final fan = c.read(ductFanProvider)!;

    final fromSource = _staticFrom(c, ServiceType.duct, 'n2');
    final fromDiffuser = _staticFrom(c, ServiceType.duct, 'n10');
    // Rooted at the real source the index run includes the 30 m, 400 L/s
    // trunk, so it is strictly larger than the diffuser-rooted figure.
    expect(fromSource.pascals, greaterThan(fromDiffuser.pascals));
    expect(fan.totalStaticPressure.pascals, closeTo(fromSource.pascals, 1e-9));
    // Trunk airflow = both diffusers = 0.4 m³/s.
    expect(fan.airflow.cubicMetersPerSecond, closeTo(0.4, 1e-9));
  });

  group('wiring-5: a drawn exhaust system gets its own fan duty', () {
    test('exhaustFanProvider sizes the exhaust index run (separate fan)', () {
      final c = _container(ServiceType.exhaust);
      addTearDown(c.dispose);
      expect(c.read(sizingProvider), hasLength(3));
      // No supply/return drawn ⇒ the AHU fan stays absent …
      expect(c.read(ductFanProvider), isNull);
      // … but the exhaust fan is sized on its OWN trunk + index run.
      final ex = c.read(exhaustFanProvider)!;
      final expected = sizeFan(
        airflow: const FlowRate(0.4),
        totalStaticPressure: _staticFrom(c, ServiceType.exhaust, 'n2'),
      );
      expect(ex.airflow.cubicMetersPerSecond, closeTo(0.4, 1e-9));
      expect(ex.totalStaticPressure.pascals,
          closeTo(expected.totalStaticPressure.pascals, 1e-9));
      expect(ex.selectedMotor.watts, expected.selectedMotor.watts);

      // … and it feeds the MEP electrical model as its own circuit.
      final load = c
          .read(mepEquipmentLoadsProvider)
          .singleWhere((l) => l.source == MepLoadSource.exhaustFan);
      expect(load.id, 'exhaust-fan');
      expect(load.name, kExhaustFanLoadName);
      expect(load.mechanicalPower.watts, ex.selectedMotor.watts);
      expect(mepMintedCircuitNames, contains(kExhaustFanLoadName));
    });

    test('no exhaust drawn ⇒ no exhaust fan', () {
      final c = _container(ServiceType.duct);
      addTearDown(c.dispose);
      expect(c.read(exhaustFanProvider), isNull);
    });
  });
}
