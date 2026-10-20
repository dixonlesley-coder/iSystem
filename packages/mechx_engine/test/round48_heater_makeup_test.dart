// Round 48 — a water heater's cold feed carries its hot draw, and the cold
// main upstream carries every fixture's total once
// (mech-convergence-3-water-heater-cold-makeup-zero).
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/standards/sni.dart';
import 'package:test/test.dart';

const _sni = SniProfile();

NetNode _n(String id, double x, int f,
        {NodeRole role = NodeRole.main, NodeComponent? c}) =>
    NetNode(
        id: id,
        sheetId: 's1',
        x: x,
        y: 0,
        floorIndex: f,
        role: role,
        component: c);

NetEdge _e(String id, String a, String b,
        {ServiceType s = ServiceType.coldWater, EdgeKind k = EdgeKind.run}) =>
    NetEdge(id: id, fromId: a, toId: b, service: s, kind: k);

/// [floors]-storey apartment, upfeed booster; each unit: a flush-tank WC
/// (2.5 UBAP, cold only) + lavatory 1 + shower 2 + kitchen sink 2 (cold AND
/// hot, from a per-unit heater WH_f whose cold feed is U_f -> WH_f).
({Network net, Map<String, double> units}) _apartment(int floors,
    {bool heaters = true}) {
  final nodes = <NetNode>[
    _n('GT', 0, 0, role: NodeRole.plant, c: NodeComponent.groundTank),
    _n('BP', 10, 0, role: NodeRole.plant, c: NodeComponent.boosterSet),
  ];
  final edges = <NetEdge>[
    _e('gb', 'GT', 'BP'),
    _e('br', 'BP', 'R0'),
  ];
  final units = <String, double>{};
  for (var f = 0; f < floors; f++) {
    nodes.addAll([
      _n('R$f', 20, f),
      _n('U$f', 30, f),
      _n('WC$f', 40, f, role: NodeRole.fixture),
      _n('LV$f', 50, f, role: NodeRole.fixture),
      _n('SH$f', 60, f, role: NodeRole.fixture),
      _n('KS$f', 70, f, role: NodeRole.fixture),
      if (heaters) ...[
        _n('WH$f', 35, f, role: NodeRole.plant),
        _n('HJ$f', 45, f),
      ],
    ]);
    units.addAll({'WC$f': 2.5, 'LV$f': 1, 'SH$f': 2, 'KS$f': 2});
    if (f > 0) edges.add(_e('r$f', 'R${f - 1}', 'R$f', k: EdgeKind.riser));
    edges.addAll([
      _e('u$f', 'R$f', 'U$f'),
      _e('wc$f', 'U$f', 'WC$f'),
      _e('lv$f', 'U$f', 'LV$f'),
      _e('sh$f', 'U$f', 'SH$f'),
      _e('ks$f', 'U$f', 'KS$f'),
      if (heaters) ...[
        _e('wf$f', 'U$f', 'WH$f'),
        _e('hj$f', 'WH$f', 'HJ$f', s: ServiceType.hotWater),
        _e('hlv$f', 'HJ$f', 'LV$f', s: ServiceType.hotWater),
        _e('hsh$f', 'HJ$f', 'SH$f', s: ServiceType.hotWater),
        _e('hks$f', 'HJ$f', 'KS$f', s: ServiceType.hotWater),
      ],
    ]);
  }
  return (net: Network(nodes: nodes, edges: edges), units: units);
}

Map<String, EdgeSizing> _size(Network net, Map<String, double> units) =>
    autoSizeNetwork(
      net,
      const SizingContext(),
      leafDemand: const {},
      leafFixtureUnits: const {
        ServiceType.coldWater: 0,
        ServiceType.hotWater: 0,
      },
      nodeFixtureUnits: units,
    );

double _q(double ubap) =>
    _sni.probableFlowForFixtureUnits(ubap).cubicMetersPerSecond;

void main() {
  final a = _apartment(20);
  final sized = _size(a.net, a.units);

  test('the building trunk carries curve(20 x 7.5 = 150 UBAP)', () {
    // Each unit's fixture TOTAL = 2.5 + 1 + 2 + 2 = 7.5 UBAP; every litre
    // (hot included) enters through the booster, so the trunk is the curve of
    // the summed totals — not curve(20 x 6.25) of the cold shares alone.
    expect(sized['br']!.flow.cubicMetersPerSecond, closeTo(_q(150), 1e-12));
    expect(sized['br']!.flow.cubicMetersPerSecond, greaterThan(_q(125) + 1e-6));
  });

  test('each unit branch carries curve(7.5); each heater feed curve(3.75)', () {
    for (var f = 0; f < 20; f++) {
      // Branch R_f -> U_f: cold shares 2.5 + 0.75 x 5 = 6.25, + the heater's
      // hot 0.75 x 5 = 3.75, less the double-counted 0.5 x 5 => 7.5.
      expect(sized['u$f']!.flow.cubicMetersPerSecond, closeTo(_q(7.5), 1e-12),
          reason: 'u$f');
      // The heater's cold feed carries its hot draw (0.75 x 5 = 3.75 UBAP).
      expect(sized['wf$f']!.flow.cubicMetersPerSecond, closeTo(_q(3.75), 1e-12),
          reason: 'wf$f');
      expect(sized['wf$f']!.flow.cubicMetersPerSecond, greaterThan(0));
      // The hot side keeps its own 0.75 share (3.75 UBAP at the heater).
      expect(
          sized['hj$f']!.flow.cubicMetersPerSecond, closeTo(_q(3.75), 1e-12));
    }
  });

  test('a cold network with no heater is byte-identical', () {
    final b = _apartment(20, heaters: false);
    final s = _size(b.net, b.units);
    // Cold only: every fixture carries its full UBAP => 20 x 7.5 = 150.
    expect(s['br']!.flow.cubicMetersPerSecond, closeTo(_q(150), 1e-12));
    expect(s['u0']!.flow.cubicMetersPerSecond, closeTo(_q(7.5), 1e-12));
  });
}
