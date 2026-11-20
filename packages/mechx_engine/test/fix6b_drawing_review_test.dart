// Fix round 6 part 2 (2026-11-20) — T4 plan legend naming and window
// growth, Obs 7 E-501 ratings.
import 'package:mechx_engine/electrical/power_oneline.dart';
import 'package:mechx_engine/electrical/sources.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/plan_detail.dart';
import 'package:mechx_engine/report/plan_symbols.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

NetNode _n(String id, NodeComponent c, {double x = 0}) => NetNode(
    id: id, sheetId: 's', x: x, y: 0, floorIndex: 0, role: c.role, component: c);

void main() {
  test('T4: a break tank keys "Fire break tank", a genuine roof tank '
      '"Roof tank"', () {
    final net = Network(nodes: [
      _n('BT', NodeComponent.roofTank),
      _n('P', NodeComponent.pump, x: 10),
    ], edges: const []);
    final only = planLegendSymbolRows(net,
        sheetId: 's', floorIndex: 0, fireBreakTankIds: const {'BT'});
    expect(only.names, ['Pump', 'Fire break tank']);
    expect(only.symbols, [NodeComponent.pump, NodeComponent.roofTank]);
    final both = planLegendSymbolRows(
        Network(nodes: [...net.nodes, _n('RT', NodeComponent.roofTank, x: 20)],
            edges: const []),
        sheetId: 's',
        floorIndex: 0,
        fireBreakTankIds: const {'BT'});
    expect(both.names, ['Pump', 'Roof tank', 'Fire break tank']);
    // No break tank: exactly the plain symbols and labels.
    final none = planLegendSymbolRows(net, sheetId: 's', floorIndex: 0);
    expect(none.symbols, planLegendSymbols(net, sheetId: 's', floorIndex: 0));
  });

  test('T4: a window grows to take in whole a symbol it cuts', () {
    // Seeds at 0..10, margin 2 -> box -2..12; a pump at 13 with a 3 px
    // glyph radius is cut (10..16 meets the box): the box grows to 16.
    final r = planDetailClusterRects(
      seeds: const [(x: 0, y: 0), (x: 10, y: 0)],
      elements: const [],
      linkPx: 20,
      marginPx: 2,
      nodesPx: const [(x: 13, y: 0)],
      nodeRadiusPx: 3,
    );
    expect(r.single.maxX, 16);
    // A symbol clear of the box (at 30) is left out wholly.
    final r2 = planDetailClusterRects(
      seeds: const [(x: 0, y: 0), (x: 10, y: 0)],
      elements: const [],
      linkPx: 20,
      marginPx: 2,
      nodesPx: const [(x: 30, y: 0)],
      nodeRadiusPx: 3,
    );
    expect(r2.single.maxX, 12);
  });

  test('Obs 7: E-501 boxes print the E-301 ratings', () {
    final ol = buildPowerOneLine(
      const ElectricalSources(generator: GeneratorSource()),
      demand: const ApparentPower(100000),
      mainPanelSub: 'LVMDP 250A 4P',
      mainBusRatingA: 250,
      transferSub: 'PP-E 125A 4P',
    );
    String? sub(String id) => ol.nodes.firstWhere((n) => n.id == id).sub;
    expect(sub('main'), 'LVMDP 250A 4P');
    expect(sub('bus'), '400 V · 250 A');
    expect(sub('ats'), 'transfer switch · PP-E 125A 4P');
  });
}
