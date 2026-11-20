// Backlog K-4 (2026-11-20) — the G-003 master legend (KETERANGAN / LEGEND)
// keys a fire zone BREAK tank by the zone chain's derived naming: a break
// tank contributes the row 'BT  Fire break tank' (drawn with its own tank
// glyph), and 'RT  Roof tank' is keyed only when a genuine roof tank is
// drawn. Before K-4 the row was keyed on the symbol type, so a drawing whose
// only roof-typed tank was a break tank printed 'RT  Roof tank'.
//
// The reference tower draws a genuine roof tank RT (top storey) and the
// roof-TYPED fire break tank BT on Lantai 15 (`fireBreakTankIds` = {BT}, the
// app's `fireBreakTankIdsProvider`, pinned by backlog Z-4).
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/cover_sheet.dart';
import 'package:mechx_engine/report/sld_sheet.dart';
import 'package:test/test.dart';

import 'reference/tower.dart';

List<(String, String)> _equipmentRows(List<MasterLegendSection> sections) => [
      for (final s in sections)
        if (s.title.startsWith('PERALATAN'))
          for (final e in s.entries) (e.code, e.meaning),
    ];

void main() {
  final tower = buildTower().network;

  test('no break tank: byte-identical (RT Roof tank keyed on the type)', () {
    final split = masterLegendComponentsOf(tower, const {});
    final rows = _equipmentRows(buildMasterLegendSections(
      components: split.components,
      fireBreakTankComponents: split.fireBreakTankComponents,
    ));
    expect(split.fireBreakTankComponents, isEmpty);
    expect(rows, contains(('RT', 'Roof tank')));
    expect(rows.where((r) => r.$1 == 'BT'), isEmpty);
    // Same rows as the pre-K-4 call.
    expect(
        rows,
        _equipmentRows(buildMasterLegendSections(components: {
          for (final n in tower.nodes)
            if (n.component != null) n.component!,
        })));
  });

  test('tower: RT keeps its row, BT adds "BT Fire break tank" after it', () {
    final split = masterLegendComponentsOf(tower, const {kTowerBreakTank});
    // RT is still drawn as a genuine roof tank.
    expect(split.components, contains(NodeComponent.roofTank));
    expect(split.fireBreakTankComponents, {NodeComponent.roofTank});
    final sections = buildMasterLegendSections(
      components: split.components,
      fireBreakTankComponents: split.fireBreakTankComponents,
    );
    final rows = _equipmentRows(sections);
    final rt = rows.indexOf(('RT', 'Roof tank'));
    final bt = rows.indexOf(('BT', 'Fire break tank'));
    expect(rt, greaterThanOrEqualTo(0));
    expect(bt, rt + 1);
    // The row is drawn with the break tank's own (roof-tank) glyph.
    final entry = sections
        .expand((s) => s.entries)
        .singleWhere((e) => e.code == kFireBreakTankLegendCode);
    expect(entry.component, NodeComponent.roofTank);
  });

  test('a drawing whose ONLY roof-typed tank is a break tank keys no '
      '"Roof tank"', () {
    // The tower without its genuine roof tanks (every roofTank but BT).
    final net = Network(
      nodes: [
        for (final n in tower.nodes)
          if (n.component != NodeComponent.roofTank || n.id == kTowerBreakTank)
            n,
      ],
      edges: tower.edges,
    );
    final split = masterLegendComponentsOf(net, const {kTowerBreakTank});
    expect(split.components, isNot(contains(NodeComponent.roofTank)));
    final rows = _equipmentRows(buildMasterLegendSections(
      components: split.components,
      fireBreakTankComponents: split.fireBreakTankComponents,
    ));
    // Before K-4: ('RT', 'Roof tank'). After: ('BT', 'Fire break tank').
    expect(rows.where((r) => r.$2 == 'Roof tank'), isEmpty);
    expect(rows, contains(('BT', 'Fire break tank')));
    // The G-003 sheet prints the same strings.
    final texts = [
      for (final p in buildGeneralNotesSheet(
        components: split.components,
        fireBreakTankComponents: split.fireBreakTankComponents,
      ).prims)
        if (p is SldLabel) p.text,
    ];
    expect(texts, containsAll(['BT', 'Fire break tank']));
    expect(texts, isNot(contains('Roof tank')));
  });
}
