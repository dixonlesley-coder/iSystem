// Backlog K-2 (2026-11-20) — the delivered field upstream of a ground tank
// is on MAINS pressure (`mainsFeedHeads`): the meter reads the available
// mains head, each node of its feed that head less the true elevation rise
// and the sized feed friction from the meter, and the tank inlet the
// remaining head (`MainsPressureCheck.inletHead`) — the SAME terms the W-2
// check (`mainsPressureCheck`) judges.
//
// Fixture: WM (explicit elevation 0.5 m) -> J (a bare main, 3.5 m) -> GT
// (ground tank, 4.0 m). Both pipes DN25 at 0.5 L/s, PVC (Hazen–Williams
// C 150); WM -> J is 6.0 m, J -> GT 2.0 m; mains 10.0 m.
//
// Hazen–Williams: j = 10.67 x (5e-4)^1.852 / (150^1.852 x 0.025^4.8704)
// = 0.0486641 m/m, so WM -> J loses 6.0 j = 0.291985 m and J -> GT
// 2.0 j = 0.097328 m (0.389313 m in all).
//  * WM: flowing = no-flow = 10.0 m.
//  * J: rise 3.5 - 0.5 = 3.0 m. No-flow 10.0 - 3.0 = 7.0 m; flowing
//    7.0 - 0.291985 = 6.708015 m.
//  * The tank inlet: lift 4.0 - 0.5 = 3.5 m; 10.0 - 3.5 - 0.389313 =
//    6.110687 m (>= the 5.0 m float-valve residual: required 3.5 +
//    0.389313 + 5.0 = 8.889313 m <= 10).
//  * GT itself is not in the list (its free surface is the pump-side datum).
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/tank_fill.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

void main() {
  const net = Network(
    nodes: [
      NetNode(
        id: 'WM',
        sheetId: 's',
        x: 0,
        y: 0,
        floorIndex: 0,
        component: NodeComponent.waterMeter,
        elevation: const Length(0.5),
      ),
      NetNode(
        id: 'J',
        sheetId: 's',
        x: 100,
        y: 0,
        floorIndex: 0,
        elevation: const Length(3.5),
      ),
      NetNode(
        id: 'GT',
        sheetId: 's',
        x: 200,
        y: 0,
        floorIndex: 1,
        role: NodeRole.plant,
        component: NodeComponent.groundTank,
        elevation: const Length(4.0),
      ),
    ],
    edges: [
      NetEdge(id: 'a', fromId: 'WM', toId: 'J', service: ServiceType.coldWater),
      // Drawn tank -> junction: the walk follows the chain, not the drawing.
      NetEdge(id: 'b', fromId: 'GT', toId: 'J', service: ServiceType.coldWater),
    ],
  );
  const lengths = {'a': 6.0, 'b': 2.0};
  final sized = {
    for (final id in ['a', 'b'])
      id: (flow: const FlowRate(5e-4), diameter: const Diameter(0.025)),
  };
  final feed = meterFeedsToGroundTanks(net).single;
  const j = 0.0486641;

  test('the feed is WM -> J -> GT', () {
    expect(feed.meterId, 'WM');
    expect(feed.tankId, 'GT');
    expect(feed.edgeIds, ['a', 'b']);
  });

  test('meter and junction read the mains head less rise and friction', () {
    final heads = mainsFeedHeads(
      net: net,
      feed: feed,
      sized: sized,
      available: const Head(10.0),
      lengthOf: (e) => lengths[e.id]!,
      elevationOf: (n) => n.elevation!.meters,
    )!;
    expect([for (final h in heads) h.nodeId], ['WM', 'J']);
    expect(heads[0].flowing.meters, 10.0);
    expect(heads[0].noFlow.meters, 10.0);
    expect(heads[1].noFlow.meters, closeTo(7.0, 1e-12));
    expect(heads[1].flowing.meters, closeTo(7.0 - 6.0 * j, 1e-6));
    expect(heads[1].flowing.meters, closeTo(6.708015, 1e-6));
  });

  test('the tank inlet reads the remaining head, from the same terms', () {
    final c = mainsPressureCheck(
      net: net,
      feed: feed,
      sized: sized,
      available: const Head(10.0),
      lengthOf: (e) => lengths[e.id]!,
      elevationOf: (n) => n.elevation!.meters,
    )!;
    expect(c.liftM, closeTo(3.5, 1e-12));
    expect(c.frictionM, closeTo(8.0 * j, 1e-6));
    expect(c.inletHead.meters, closeTo(6.110687, 1e-6));
    expect(c.required.meters, closeTo(8.889313, 1e-6));
    expect(c.ok, isTrue);
    // inletHead >= the float-valve residual exactly when ok.
    expect(c.inletHead.meters >= c.inletResidualM, c.ok);
  });

  test('an unsized feed pipe gives no mains-side heads (never fabricated)', () {
    expect(
      mainsFeedHeads(
        net: net,
        feed: feed,
        sized: {'a': sized['a']!},
        available: const Head(10.0),
        lengthOf: (e) => lengths[e.id]!,
        elevationOf: (n) => n.elevation!.meters,
      ),
      isNull,
    );
  });
}
