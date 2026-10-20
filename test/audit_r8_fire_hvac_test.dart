/// Audit round 8 — fire / HVAC honesty (app side).
///
///   fire-hvac-3  a drawn sprinkler system whose design-area demand or pressure
///                the one scheduled fire pump cannot meet is a Review warning.
///   fire-hvac-4  the 'Internal gains' AC basis says what it omits (label,
///                caption, and an info advisory while active).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/annotation_store.dart';
import 'package:mechx/store/app_state.dart';
import 'package:mechx/store/design_issues_store.dart';
import 'package:mechx/store/fire_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/ui/strings/app_strings.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/fire_sprinkler.dart';
import 'package:mechx_engine/sizing/pump.dart';
import 'package:mechx_engine/units.dart';

ProviderContainer _sprinklerNet(
    {List<Override> overrides = const [],
    bool withHydrant = false,
    bool drawnPump = true}) {
  final c = ProviderContainer(overrides: overrides);
  c.read(networkControllerProvider.notifier).loadNetwork(Network(nodes: [
        if (withHydrant)
          const NetNode(
              id: 'hb',
              sheetId: 's1',
              x: 0,
              y: 200,
              floorIndex: 0,
              role: NodeRole.fixture,
              component: NodeComponent.hydrantBox),
        NetNode(
            id: 'fp',
            sheetId: 's1',
            x: 0,
            y: 0,
            floorIndex: 0,
            role: NodeRole.plant,
            component: drawnPump ? NodeComponent.pump : null),
        const NetNode(
            id: 'sh',
            sheetId: 's1',
            x: 200,
            y: 0,
            floorIndex: 0,
            role: NodeRole.fixture,
            component: NodeComponent.sprinklerHead),
      ], edges: [
        const NetEdge(
            id: 's', fromId: 'fp', toId: 'sh', service: ServiceType.fireSprinkler),
        if (withHydrant)
          const NetEdge(
              id: 'h', fromId: 'fp', toId: 'hb', service: ServiceType.fireHydrant),
      ]));
  return c;
}

void main() {
  test('fire-hvac-3: Extra Hazard demand > the standpipe pump flow ⇒ warning',
      () {
    // Round 17 — the pump is STANDPIPE-rated only when a hydrant is drawn too
    // (a sprinkler-only network now rates its pump on the sprinkler demand).
    final c = _sprinklerNet(withHydrant: true);
    addTearDown(c.dispose);
    c.read(fireHazardProvider.notifier).set(FireHazardClass.extraHazard);
    final remote = c.read(sprinklerRemoteAreaProvider);
    final pump = c.read(firePumpDutyProvider)!;
    // The finding's numbers: EH demand ≈ 43 L/s vs the 500 gpm (31.5 L/s) pump.
    expect(remote.remoteAreaDemand.inLitersPerSecond,
        greaterThan(pump.flow.inLitersPerSecond));
    final chk = c.read(sprinklerPumpCheckProvider)!;
    expect(chk.flowShort, isTrue);
    expect(chk.demandLps, closeTo(remote.remoteAreaDemand.inLitersPerSecond, 1e-9));
    final issues = c.read(designIssuesProvider);
    expect(issues.any((i) => i.kind == 'sprinkler-flow-exceeds-fire-pump'),
        isTrue);
  });

  test('Round 17: sprinkler-only ⇒ the pump is rated on the sprinkler demand',
      () {
    final c = _sprinklerNet();
    addTearDown(c.dispose);
    c.read(fireHazardProvider.notifier).set(FireHazardClass.extraHazard);
    final remote = c.read(sprinklerRemoteAreaProvider);
    final pump = c.read(firePumpDutyProvider)!;
    // Rated flow = the remote-area demand (not the 31.5 L/s standpipe).
    expect(pump.flow.inLitersPerSecond,
        closeTo(remote.remoteAreaDemand.inLitersPerSecond, 1e-9));
    // Head = lift to the top ceiling + branch base pressure + 15 m allowance,
    // so the lower-bound coverage check is met by construction.
    final chk = c.read(sprinklerPumpCheckProvider)!;
    expect(chk.flowShort, isFalse);
    expect(chk.headShort, isFalse);
    expect(pump.head.meters, closeTo(chk.requiredHeadM + 15, 1e-9));
  });

  test('fire-hvac-3: OH1 sits under the pump flow ⇒ no flow warning', () {
    final c = _sprinklerNet();
    addTearDown(c.dispose);
    expect(c.read(sprinklerPumpCheckProvider)!.flowShort, isFalse);
    expect(
        c.read(designIssuesProvider)
            .any((i) => i.kind == 'sprinkler-flow-exceeds-fire-pump'),
        isFalse);
  });

  test('fire-hvac-3: head lower bound = lift to the top ceiling + branch base',
      () {
    const weak = PumpDuty(
      flow: FlowRate(0.05),
      head: Head(10),
      hydraulicPower: Power(4900),
      shaftPower: Power(7000),
      motorInputPower: Power(7800),
      selectedMotor: Power(7500),
    );
    // Round 29 — no pump drawn on the sprinkler system, so the check falls
    // back to the governing (scheduled) fire pump, overridden here.
    final c = _sprinklerNet(
        drawnPump: false,
        overrides: [firePumpDutyProvider.overrideWith((ref) => weak)]);
    addTearDown(c.dispose);
    final b = c.read(projectControllerProvider).building;
    final remote = c.read(sprinklerRemoteAreaProvider);
    // Round 49 (fire-convergence-zone-lift-is-whole-building) — the lift is
    // the SYSTEM's own: its pump datum floor (0) to its highest sprinkler
    // head's ceiling. The only head 'sh' is on floor 0, so the lift is floor
    // 0's ceiling — not the top storey of the (default multi-storey)
    // building, which no head of this system reaches.
    const top = 0;
    final expected = b.ceilingElevationOf(top).meters -
        b.elevationOf(0).meters +
        remote.branchBasePressure.pascals / (1000 * 9.81);
    final chk = c.read(sprinklerPumpCheckProvider)!;
    expect(chk.requiredHeadM, closeTo(expected, 1e-9));
    expect(chk.headShort, isTrue);
    expect(
        c.read(designIssuesProvider)
            .any((i) => i.kind == 'sprinkler-head-exceeds-fire-pump'),
        isTrue);
  });

  test('fire-hvac-3: no sprinkler drawn ⇒ no check at all', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    c.read(fireHazardProvider.notifier).set(FireHazardClass.extraHazard);
    expect(c.read(sprinklerPumpCheckProvider), isNull);
  });

  test(
      'Round 29: a sprinkler system with its own pump beside a separate '
      'hydrant tower is judged on ITS pump (no false warning)', () {
    NetNode n(String id, double x, NodeRole r, NodeComponent? c) => NetNode(
        id: id, sheetId: 's1', x: x, y: 0, floorIndex: 0, role: r, component: c);
    final c = ProviderContainer();
    addTearDown(c.dispose);
    c.read(networkControllerProvider.notifier).loadNetwork(Network(nodes: [
          n('aGT', 0, NodeRole.plant, NodeComponent.groundTank),
          n('aSP', 100, NodeRole.plant, NodeComponent.pump),
          n('aSH', 200, NodeRole.fixture, NodeComponent.sprinklerHead),
          n('bGT', 1000, NodeRole.plant, NodeComponent.groundTank),
          n('bHP', 1100, NodeRole.plant, NodeComponent.pump),
          n('bHB', 1200, NodeRole.fixture, NodeComponent.hydrantBox),
        ], edges: const [
          NetEdge(id: 'a1', fromId: 'aGT', toId: 'aSP', service: ServiceType.fireSprinkler),
          NetEdge(id: 'a2', fromId: 'aSP', toId: 'aSH', service: ServiceType.fireSprinkler),
          NetEdge(id: 'b1', fromId: 'bGT', toId: 'bHP', service: ServiceType.fireHydrant),
          NetEdge(id: 'b2', fromId: 'bHP', toId: 'bHB', service: ServiceType.fireHydrant),
        ]));
    c.read(fireHazardProvider.notifier).set(FireHazardClass.extraHazard);
    final remote = c.read(sprinklerRemoteAreaProvider);
    final demand = remote.remoteAreaDemand.inLitersPerSecond;
    final byNode = c.read(firePumpBasisByNodeProvider);
    // The sprinkler pump is rated on its own remote-area demand (≈ 43 L/s);
    // the governing (scheduled) pump is the 500 gpm hydrant one (31.5 L/s),
    // which the pre-Round-29 judge compared against and flagged.
    expect(byNode['aSP']!.sprinklerOnly, isTrue);
    expect(byNode['aSP']!.flow.inLitersPerSecond, closeTo(demand, 1e-9));
    expect(c.read(firePumpDutyProvider)!.flow.inLitersPerSecond,
        lessThan(demand));
    final chk = c.read(sprinklerPumpCheckProvider)!;
    expect(chk.pumpLps, closeTo(demand, 1e-9));
    expect(chk.flowShort, isFalse);
    expect(chk.headShort, isFalse);
    expect(
        c.read(designIssuesProvider).any((i) =>
            i.kind == 'sprinkler-flow-exceeds-fire-pump' ||
            i.kind == 'sprinkler-head-exceeds-fire-pump'),
        isFalse);
  });

  test('fire-hvac-4: the Internal-gains basis raises an info advisory + is '
      'labelled for what it omits', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    c.read(roomAreasProvider.notifier).set(const [
      RoomArea(id: 'r0', sheetId: 's1', floorIndex: 0, ax: 0, ay: 0, bx: 100, by: 100),
    ]);
    bool has() => c
        .read(designIssuesProvider)
        .any((i) => i.kind == 'cooling-internal-gains-only');
    expect(has(), isFalse);
    c.read(coolingLoadMethodProvider.notifier).set(CoolingLoadMethod.detailed);
    final issue = c
        .read(designIssuesProvider)
        .firstWhere((i) => i.kind == 'cooling-internal-gains-only');
    expect(issue.severity, IssueSeverity.info);
    for (final loc in AppLocale.values) {
      final s = MechXStringsData(loc);
      expect(s(StringKey.designInputAcBasisHeatGain), isNotEmpty);
    }
    expect(MechXStringsData(AppLocale.en)(StringKey.designInputAcBasisHeatGain),
        contains('no envelope'));
  });
}
