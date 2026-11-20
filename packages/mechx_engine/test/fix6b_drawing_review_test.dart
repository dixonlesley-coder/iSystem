// Fix round 6 part 2 (2026-11-20) — T4 plan legend naming and window
// growth, Obs 7 E-501 ratings.
import 'package:mechx_engine/electrical/power_oneline.dart';
import 'package:mechx_engine/electrical/sources.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/plan_detail.dart';
import 'package:mechx_engine/report/plan_detail_sheet.dart';
import 'package:mechx_engine/report/plan_symbols.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

NetNode _n(String id, NodeComponent c, {double x = 0}) => NetNode(
    id: id,
    sheetId: 's',
    x: x,
    y: 0,
    floorIndex: 0,
    role: c.role,
    component: c);

void main() {
  test(
      'T4: a break tank keys "Fire break tank", a genuine roof tank '
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
        Network(
            nodes: [...net.nodes, _n('RT', NodeComponent.roofTank, x: 20)],
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

  test('T4 (part 3): a break mark is a double slash across the cut run', () {
    // Run leaves the window at (0, 0) heading into it along +x.
    final m = planBreakMarkLines(0, 0, 10, 0);
    expect(m, hasLength(2));
    // Centres 1.2 and 2.4 mm into the window, each stroke 3 mm long at 45
    // deg: half-length 1.5 x (cos 45, sin 45) = (1.0607, 1.0607).
    for (final (i, l) in m.indexed) {
      final cx = (l.x1 + l.x2) / 2, cy = (l.y1 + l.y2) / 2;
      expect(cx, closeTo(1.2 * (i + 1), 1e-9));
      expect(cy, closeTo(0, 1e-9));
      expect((l.x2 - l.x1).abs(), closeTo(2.1213, 1e-4));
      expect((l.y2 - l.y1).abs(), closeTo(2.1213, 1e-4));
    }
    expect(planBreakMarkLines(5, 5, 5, 5), isEmpty);
  });

  test(
      'Part 4 (Obs 9): an optional tag prints only in a legal spot and '
      'otherwise changes nothing', () {
    // Clear paper: the optional tag takes its first beside-the-run slot.
    final free = PlanLabelLayout();
    free.addRun('r', 0, 0, 100, 0);
    final keys = PlanKeyRegistry();
    final ok = placeOptionalPlanLabel(
        ax: 0,
        ay: 0,
        bx: 100,
        by: 0,
        text: 'CW-L5 · DN15',
        textSize: 3,
        layout: free,
        ownRunId: 'r',
        keys: keys);
    expect(ok, isNotNull);
    expect(free.labelCount, 1);
    expect(keys.isEmpty, isTrue);
    // Boxed in on every side: a required tag would be keyed; the optional
    // one is skipped and leaves the layout, the key registry and the
    // overlap count exactly as they were.
    final full = PlanLabelLayout(
        boxes: [(minX: -500.0, minY: -500.0, maxX: 500.0, maxY: 500.0)]);
    full.addRun('r', 0, 0, 100, 0);
    final k2 = PlanKeyRegistry();
    final skipped = placeOptionalPlanLabel(
        ax: 0,
        ay: 0,
        bx: 100,
        by: 0,
        text: 'CW-L5 · DN15',
        textSize: 3,
        layout: full,
        ownRunId: 'r',
        keys: k2);
    expect(skipped, isNull);
    expect(full.labelCount, 0);
    expect(full.unresolvedCount, 0);
    expect(k2.isEmpty, isTrue);
    // The same tag placed as REQUIRED is keyed (the contrast).
    placePlanLabel(
        ax: 0,
        ay: 0,
        bx: 100,
        by: 0,
        text: 'CW-L5 · DN15',
        textSize: 3,
        layout: full,
        ownRunId: 'r',
        keys: k2);
    expect(k2.isEmpty, isFalse);
  });

  test('Part 4 (key 7): a key circle never sits on its own run', () {
    final layout = PlanLabelLayout();
    layout.addRun('v', 0, -60, 0, 60);
    final k = placePlanLabel(
        ax: 0,
        ay: -60,
        bx: 0,
        by: 60,
        text: 'FH-L15 · DN150',
        textSize: 3,
        layout: layout,
        ownRunId: 'v',
        keys: PlanKeyRegistry(),
        keyOnly: true);
    final c = k.keyCircle!;
    // The run (x = 0) stays outside 0.85 r of the circle's centre.
    expect(c.x.abs(), greaterThanOrEqualTo(0.85 * c.r));
    expect(layout.unresolvedCount, 0);
  });

  test('Part 4 (Obs 9): a coarse window tags its margin optionally', () {
    // A 50 x 40 px box at 0.05 m/px (2.5 x 2.0 m) is drawn at 1:20 here;
    // its window shows a margin beyond the box (n3 at x = 55, the run e2
    // ending there): OPTIONAL tags, never unlabelled outright, never keyed.
    final net = Network(nodes: [
      for (var i = 0; i < 4; i++)
        NetNode(
            id: 'n$i', sheetId: 's', x: 10.0 + 15 * i, y: 20, floorIndex: 0),
    ], edges: [
      for (var i = 0; i < 3; i++)
        NetEdge(
            id: 'e$i',
            fromId: 'n$i',
            toId: 'n${i + 1}',
            service: ServiceType.coldWater),
    ]);
    final plot = planDetailSheetPlot(
      net: net,
      sizing: const {},
      edgeLengths: const {},
      sheetId: 's',
      floorIndex: 0,
      metersPerPixel: 0.05,
      details: const [
        PlanDetailCallout(
            letter: 'A',
            rectPx: (minX: 0, minY: 0, maxX: 50, maxY: 40),
            sheetRef: 'M-501'),
      ],
      areaMm: (minX: 10, minY: 10, maxX: 400, maxY: 250),
    );
    expect(plot.details.single.scaleDenominator,
        greaterThan(kPlanDetailLabelAllScale));
    final shown = {for (final n in plot.net.nodes) n.id};
    expect(shown, contains('n3'));
    expect(plot.optionalLabelIds, contains('n3'));
    expect(plot.unlabelledIds, isNot(contains('n3')));
    expect(plot.optionalLabelIds, isNot(contains('n0')));
  });
}
