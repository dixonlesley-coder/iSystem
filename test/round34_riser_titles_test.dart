// Round 34 (fire-hvac-drawings-no-discipline-split) — every riser system
// carries a DISTINCT register title (two sheets of one riser set never share a
// title), and a fire riser DXF lands on its own F-* layer namespace.
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/ui/schematic/schematic_export.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/sld_export.dart';
import 'package:mechx_engine/report/sld_sheet.dart';

void main() {
  test('one distinct, ASCII riser title per service (and the combined sheet)',
      () {
    final titles = [
      riserDiagramTitle(null),
      for (final s in ServiceType.values) riserDiagramTitle(s),
    ];
    expect(titles.toSet().length, titles.length, reason: titles.join(' | '));
    for (final t in titles) {
      expect(RegExp(r'^[\x20-\x7E]+$').hasMatch(t), isTrue, reason: t);
    }
    expect(riserDiagramTitle(ServiceType.fireSprinkler),
        'DIAGRAM SISTEM SPRINKLER');
    expect(riserDiagramTitle(ServiceType.fireHydrant), 'DIAGRAM SISTEM HIDRAN');
  });

  test('a fire riser DXF uses F-*, a plumbing riser keeps M-*', () {
    expect(SldDxfLayers.forRiser(ServiceType.fireSprinkler), SldDxfLayers.fire);
    expect(SldDxfLayers.forRiser(ServiceType.fireHydrant), SldDxfLayers.fire);
    expect(SldDxfLayers.forRiser(ServiceType.coldWater),
        SldDxfLayers.mechanical);
    expect(SldDxfLayers.forRiser(null), SldDxfLayers.mechanical);
    const sheet = SldSheet(
      prims: [SldLabel(0, 10, 'SP-R1'), SldRect(0, 0, 20, 20)],
      minX: 0,
      minY: 0,
      maxX: 100,
      maxY: 100,
      legend: [],
      supplyNote: '',
    );
    final dxf = sldSheetToDxf(
        sheet: sheet,
        diagramTitle: riserDiagramTitle(ServiceType.fireSprinkler),
        layers: SldDxfLayers.forRiser(ServiceType.fireSprinkler));
    expect(dxf, contains('F-TEXT'));
    expect(dxf, contains('F-DETAIL'));
    expect(dxf.contains('M-TEXT'), isFalse);
  });
}
