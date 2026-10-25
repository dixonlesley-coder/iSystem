import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/calc_report.dart';
import 'package:mechx_engine/sizing/fan.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/standards/sni.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

NetNode _n(String id, double x, {NodeRole role = NodeRole.main}) => NetNode(
    id: id, sheetId: 's1', x: x, y: 0, floorIndex: 0, role: role);

void main() {
  group('serviceComponentRoots — the sizer\'s root ladder, exposed', () {
    // n2 (entry) — n3 (junction) — {n10, n11} diffusers carrying airflow.
    final net = Network(
      nodes: [_n('n2', 0), _n('n3', 30), _n('n10', 32), _n('n11', 40)],
      edges: const [
        NetEdge(id: 'e1', fromId: 'n2', toId: 'n3', service: ServiceType.duct),
        NetEdge(id: 'e2', fromId: 'n3', toId: 'n10', service: ServiceType.duct),
        NetEdge(id: 'e3', fromId: 'n3', toId: 'n11', service: ServiceType.duct),
      ],
    );

    test('a demand-bearing leaf is never the root (n10 < n2 lexically)', () {
      final roots = serviceComponentRoots(net, ServiceType.duct,
          demandNodeIds: const {'n10', 'n11'});
      // Every member of the one component maps to the demand-free entry leaf.
      expect(roots, {'n2': 'n2', 'n3': 'n2', 'n10': 'n2', 'n11': 'n2'});
    });

    test('a plant wins over any leaf', () {
      final withPlant = Network(
        nodes: [
          _n('n2', 0),
          _n('n3', 30, role: NodeRole.plant),
          _n('n10', 32),
          _n('n11', 40),
        ],
        edges: net.edges,
      );
      final roots = serviceComponentRoots(withPlant, ServiceType.duct,
          demandNodeIds: const {'n10', 'n11'});
      expect(roots['n10'], 'n3');
    });

    test('agrees with autoSizeNetwork: the root edge carries the full load',
        () {
      const q = FlowRate(0.2);
      final sizing = autoSizeNetwork(
        net,
        const SizingContext(),
        leafDemand: const {},
        nodeFlowDemand: const {'n10': q, 'n11': q},
      );
      // Rooted at n2, e1 carries both diffusers (0.4 m³/s).
      expect(sizing['e1']!.flow.cubicMetersPerSecond, closeTo(0.4, 1e-12));
      expect(serviceComponentRoots(net, ServiceType.duct,
              demandNodeIds: const {'n10', 'n11'})['n3'],
          'n2');
    });

    test('a service with no edges ⇒ empty', () {
      expect(serviceComponentRoots(net, ServiceType.exhaust), isEmpty);
    });
  });

  group('calc report — exhaust fan rows', () {
    const profile = SniProfile();
    CalcReportData data({FanDuty? exhaustFan}) => CalcReportData(
          projectName: 'X',
          date: 'd',
          standardsName: profile.name,
          standardsRevision: profile.revision,
          verifyItems: const [],
          building: const BuildingLevels([Floor('G', Length(3))]),
          feedStrategy: 'Roof-tank downfeed',
          targetResidual: const Pressure(225000),
          bom: const [],
          fittings: const [],
          exhaustFan: exhaustFan,
        );

    test('absent ⇒ no exhaust rows (byte-identical)', () {
      expect(buildCalcReportMarkdown(data()), isNot(contains('Exhaust')));
    });

    test('present ⇒ airflow / static / motor printed under HVAC', () {
      final ex = sizeFan(
          airflow: const FlowRate(0.4),
          totalStaticPressure: const Pressure(150));
      final md = buildCalcReportMarkdown(data(exhaustFan: ex));
      expect(md, contains('## HVAC'));
      expect(md, contains('Exhaust airflow:'));
      expect(md, contains('**400 L/s**'));
      expect(md, contains('**150 Pa**'));
      expect(md,
          contains('**${ex.selectedMotor.inKiloWatts.toStringAsFixed(2)} kW**'));
    });
  });
}
