// Fix round 6 (T1, 2026-11-20) — a riser node is drawn inside its OWN floor
// band. The pitch escalation scales the service-lane pitch up to 3x without
// growing the band: the tower's ground-floor fire pump room (hydrant lane
// -2.2) rose 2.2 x 14 x 3 = 92.4 units above the band centre, past the
// 75-unit half band, and was drawn and keyed on Lantai 2. The lane pitch is
// now capped at (band / 2 - symbol / 2) / max|lane| = (75 - 10) / 3.4 =
// 19.12 units on the 150-unit band.
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/mechanical_sld_drawing.dart';
import 'package:mechx_engine/report/riser_tags.dart';
import 'package:test/test.dart';

void main() {
  _layoutGroup();
  test('the outermost lane is exhaust / hydrant side: max |lane| = 3.4', () {
    expect(kRiserServiceLaneMax, closeTo(3.4, 1e-12));
    expect(riserServiceLane(ServiceType.fireHydrant), -2.2);
  });

  test('every escalation step keeps every lane inside the band', () {
    for (final p in kMechRiserPitchSteps) {
      for (final k in [...kMechRiserBandSteps, ...kMechRiserKeyBandSteps]) {
        final band = 150.0 * k;
        final pitch = riserLanePitch(p, band);
        for (final s in ServiceType.values) {
          final off = riserServiceLane(s).abs() * pitch;
          expect(off + kRiserSymbolSize / 2, lessThanOrEqualTo(band / 2 + 1e-9),
              reason: 'pitch $p band $band $s');
        }
      }
    }
  });

  test('pitch 1.0 / 1.25 unchanged; 3.0 on a 150 band capped at 19.12', () {
    expect(riserLanePitch(1.0, 150), 14);
    expect(riserLanePitch(1.25, 150), 17.5);
    // (75 - 10) / 3.4 = 19.1176.
    expect(riserLanePitch(3.0, 150), closeTo(19.1176, 1e-4));
    // Hydrant: 2.2 x 19.1176 = 42.06 < 75 (was 92.4).
    expect(2.2 * riserLanePitch(3.0, 150), lessThan(75));
  });
}

// Fix round 6 (T3) — two risers of different services at ONE plan x get two
// columns; (T6) a pipe-less cassette rides the air lane, never the
// cold-water band centre.
NetNode _n(String id, double x, int f, {NodeComponent? c, NodeRole? role}) =>
    NetNode(
        id: id,
        sheetId: 's',
        x: x,
        y: 0,
        floorIndex: f,
        component: c,
        role: role ?? c?.role ?? NodeRole.main);
NetEdge _e(String id, String a, String b, ServiceType s, EdgeKind k) =>
    NetEdge(id: id, fromId: a, toId: b, service: s, kind: k);

final _twoRisers = Network(nodes: [
  _n('H0', 100, 0), _n('H1', 100, 1), // hydrant riser at x 100
  _n('S0', 100, 0), _n('S1', 100, 1), // sprinkler riser, same x
  _n('C0', 300, 0), _n('W0', 400, 0, c: NodeComponent.waterOutlet),
  _n('AC', 500, 0, c: NodeComponent.acCassette),
], edges: [
  _e('h', 'H0', 'H1', ServiceType.fireHydrant, EdgeKind.riser),
  _e('s', 'S0', 'S1', ServiceType.fireSprinkler, EdgeKind.riser),
  _e('c', 'C0', 'W0', ServiceType.coldWater, EdgeKind.run),
]);

void _layoutGroup() {
  test('T3: same-x risers of two services get two columns', () {
    final pos = riserLayoutPositions(_twoRisers);
    expect(pos['H0'], pos['H1']);
    expect(pos['S0'], pos['S1']);
    expect(pos['H0'], isNot(pos['S0']));
  });
  test('T6: a cassette rides the supply-air lane (-2.8), off the CW centre',
      () {
    final lanes = riserServiceLanes(_twoRisers);
    expect(lanes['AC'], riserServiceLane(ServiceType.duct));
    expect(lanes['AC'], -2.8);
    expect(lanes.containsKey('C0'), isFalse); // cold water: lane 0
  });
}
