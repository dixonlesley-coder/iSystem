// drafting-6 / -8 / -9 (round 4): plotted text minimums on the title block and
// the plan DXF, legends that key what is drawn (and colour the service
// swatches), and sheet chrome that stays inside the frame.
import 'dart:convert';

import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/control/starter.dart';
import 'package:mechx_engine/electrical/geo_length.dart' show LayoutPos;
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/cover_sheet.dart';
import 'package:mechx_engine/report/drawing_chrome.dart';
import 'package:mechx_engine/report/dxf_export.dart';
import 'package:mechx_engine/report/electrical_sld_drawing.dart';
import 'package:mechx_engine/report/plan_pdf_export.dart';
import 'package:mechx_engine/report/riser_tags.dart' show riserServiceCode;
import 'package:mechx_engine/report/sld_export.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

EdgeSizing _dn(String id, double mm) => EdgeSizing(
      edgeId: id,
      service: ServiceType.coldWater,
      flow: FlowRate.litersPerSecond(1),
      diameter: Diameter.mm(mm),
      velocity: const Velocity(1.2),
    );

// A 220 px cold-water run at 0.02 m/px (4.4 m) on floor 0.
const _net = Network(nodes: [
  NetNode(id: 'a', sheetId: 's', x: 100, y: 300, floorIndex: 0),
  NetNode(id: 'b', sheetId: 's', x: 320, y: 300, floorIndex: 0),
], edges: [
  NetEdge(id: 'run', fromId: 'a', toId: 'b', service: ServiceType.coldWater),
]);

void main() {
  group('drafting-6: plotted text minimums', () {
    test('wrapTitleLines keeps 14 pt and wraps, every line inside the cell', () {
      const cellW = 130.0;
      final w = wrapTitleLines('DIAGRAM SISTEM AIR BERSIH & AIR KOTOR', cellW);
      expect(w.size, kTitleBlockTitlePt);
      expect(w.lines.join(' '), 'DIAGRAM SISTEM AIR BERSIH & AIR KOTOR');
      for (final l in w.lines) {
        expect(helveticaTextWidth(l, w.size), lessThanOrEqualTo(cellW));
      }
      // A single word wider than the cell shrinks only as far as it must (to
      // no less than the 12 pt title minimum when that is enough).
      final long = wrapTitleLines('ELEKTRIKALMEKANIKAL', cellW);
      expect(long.lines, ['ELEKTRIKALMEKANIKAL']);
      expect(long.size, lessThan(kTitleBlockTitlePt));
      expect(helveticaTextWidth('ELEKTRIKALMEKANIKAL', long.size),
          lessThanOrEqualTo(cellW + 1e-6));
      expect(wrapTitleLines('', cellW).lines, isEmpty);
    });

    test('title-block field names print at the 7 pt minimum, title at 14 pt',
        () {
      final tb = pdfTitleBlock(const DrawingChrome(drawingNumber: 'M-101'),
          pageW: 1190.55,
          pageH: 841.89,
          margin: 40,
          projectName: 'P',
          titleTextOverride: 'PLAN');
      expect(tb.ops, contains('BT /F1 7.00 Tf 0.4 0.4 0.4 rg'));
      expect(tb.ops, isNot(contains('BT /F1 6 Tf')));
      expect(tb.ops, contains('BT /F1 14.00 Tf 0 0 0 rg'));
      expect(tb.ops, contains('(PLAN) Tj'));
    });

    test('A3 plotted scale for a plan extent snaps up the standard ladder', () {
      // The A3 drawing area is (1190.55 - 80) pt = 391.8 mm wide and
      // (841.89 - 80 - 160) pt = 212.3 mm tall.
      expect(a3PlottedScaleDenominatorFor(4400, 0), 20); // 4.4 m / 391.8 = 11.2
      expect(a3PlottedScaleDenominatorFor(30000, 15000), 100); // 76.6 / 70.7
      expect(a3PlottedScaleDenominatorFor(0, 0), isNull);
      expect(a3PlottedScaleDenominatorFor(1e7, 1e7), isNull); // > 1:1000
    });

    test('plan DXF text is 2.5 mm on paper at the A3 plotted scale', () {
      // The 4.4 m extent plots at 1:20 on A3 ⇒ 2.5 mm x 20 = 50 mm model
      // height (was span / 80 = 55 mm, an arbitrary 2.75 mm on paper).
      final dxf = networkToDxf(
        net: _net,
        sizing: {'run': _dn('run', 32)},
        sheetId: 's',
        floorIndex: 0,
        metersPerPixel: 0.02,
      );
      expect(dxf, contains('\n40\n50.0\n'));
      expect(dxf, isNot(contains('\n40\n55.0\n')));
    });
  });

  group('drafting-9: chrome inside the frame', () {
    test('the plan scale bar figures + legend sit inside the frame', () {
      final pdf = latin1.decode(planToPdf(
        net: _net,
        sizing: {'run': _dn('run', 32)},
        edgeLengths: const {'run': Length(4.4)},
        sheetId: 's',
        floorIndex: 0,
        projectName: 'P',
        sheetName: 'S',
        dateString: '2026-01-01',
        metersPerPixel: 0.02,
        chrome: const DrawingChrome(
            drawingNumber: 'M-101',
            legendServices: [ServiceType.coldWater]),
      ));
      const margin = 48.0; // planToPdf's frame margin
      // The '0' figure under the bar prints ABOVE the frame line.
      final zero = RegExp(r'([0-9.]+) ([0-9.]+) Td \(0\) Tj').firstMatch(pdf)!;
      expect(double.parse(zero.group(2)!),
          closeTo(margin + kScaleBarFrameInset - 10, 0.01));
      expect(double.parse(zero.group(2)!), greaterThan(margin));
      // The LEGEND title starts kLegendFrameInset inside the left frame line.
      final legend =
          RegExp(r'([0-9.]+) ([0-9.]+) Td \(LEGEND\) Tj').firstMatch(pdf)!;
      expect(double.parse(legend.group(1)!), margin + kLegendFrameInset);
    });

    test('the riser bounds rise to the top label\'s glyphs, not its baseline',
        () {
      final p = _riserProject();
      final r = computeSystem(const PuilProfile(), p);
      final s = buildElectricalRiser(
          project: p, result: r, building: _levels, sourceChain: true);
      for (final l in s.prims.whereType<SldLabel>()) {
        expect(s.minY, lessThanOrEqualTo(l.y - l.size + 1e-9), reason: l.text);
      }
    });

    test('the MV / LV main captions clear their box bottom edge', () {
      final p = _riserProject();
      final r = computeSystem(const PuilProfile(), p);
      final s = buildElectricalRiser(
          project: p, result: r, building: _levels, sourceChain: true);
      for (final cap in ['MV main', 'LV main']) {
        final l = s.prims
            .whereType<SldLabel>()
            .firstWhere((x) => x.text == cap);
        // The box is the SldRect whose left edge is the caption's x and whose
        // bottom is just above it.
        final box = s.prims.whereType<SldRect>().where((b) =>
            b.x == l.x && b.y + b.h <= l.y && l.y - (b.y + b.h) < 20).single;
        // Capitals (0.72 em) clear the bottom edge even at 1.3 x the size.
        expect(l.y - 0.72 * l.size * 1.3, greaterThan(box.y + box.h), reason: cap);
      }
    });
  });

  group('drafting-8: legends key what is drawn', () {
    test('master legend service swatches ride their service layer + colour', () {
      final sheet = buildGeneralNotesSheet(
          services: const [ServiceType.coldWater, ServiceType.drainage]);
      final swatches = sheet.prims
          .whereType<SldLine>()
          .where((l) => l.layer != null)
          .map((l) => l.layer)
          .toSet();
      expect(swatches, {
        riserServiceCode(ServiceType.coldWater),
        riserServiceCode(ServiceType.drainage),
      });
      // The PDF strokes each swatch in its service's plan colour.
      final pdf = latin1.decode(sldSheetToPdf(sheet: sheet));
      String rg(ServiceType s) {
        final (r, g, b) = serviceChromeColor(s);
        return '${r.toStringAsFixed(2)} ${g.toStringAsFixed(2)} '
            '${b.toStringAsFixed(2)} RG';
      }

      expect(pdf, contains(rg(ServiceType.coldWater)));
      expect(pdf, contains(rg(ServiceType.drainage)));
      expect(rg(ServiceType.coldWater), isNot(rg(ServiceType.drainage)));
    });

    test('the panel schedule KETERANGAN keys RCD, conduit + starter tokens', () {
      const p = ElectricalProject(id: 'x', name: 'X', panels: [
        ElectricalPanel(id: 'DB', name: 'DB-1', circuits: [
          ElectricalCircuit(
              id: 's1',
              name: 'Sockets',
              loadKind: LoadKind.socket,
              loadW: 1800,
              length: Length(20)),
          ElectricalCircuit(
              id: 'm1',
              name: 'Pump',
              loadKind: LoadKind.motor,
              motorKw: 4,
              phases: 3,
              starterType: StarterType.starDelta,
              length: Length(15)),
        ]),
      ]);
      final r = computeSystem(const PuilProfile(), p);
      final s = buildElectricalSld(project: p, result: r);
      final text =
          s.prims.whereType<SldLabel>().map((l) => l.text).join('\n');
      final codes = s.legend.map((e) => e.code).toSet();
      // Each token the rows print is keyed …
      expect(text, contains('RCD 30mA')); // the socket way's RCD token
      expect(codes, contains('RCD'));
      expect(text, contains('star-delta'));
      expect(codes, contains('star-delta'));
      expect(text, contains('PVC ')); // a conduit token
      expect(codes, contains('PVC'));
      // … and an unused starter is not.
      expect(codes, isNot(contains('VFD')));
      expect(codes, isNot(contains('DOL')));
    });
  });
}

const _levels = BuildingLevels([
  Floor('G', Length(4)),
  Floor('L1', Length(4)),
]);

ElectricalProject _riserProject() => const ElectricalProject(
      id: 'r',
      name: 'R',
      transformerKva: ApparentPower(630000),
      panels: [
        ElectricalPanel(
          id: 'MDP',
          name: 'MDP',
          layoutPos: LayoutPos(sheetId: 's', floorIndex: 0, x: 0, y: 0),
          circuits: [
            ElectricalCircuit(
                id: 'f1',
                name: 'Feeder LP-1',
                loadKind: LoadKind.feeder,
                feedsPanelId: 'LP1',
                length: Length(12)),
          ],
        ),
        ElectricalPanel(
          id: 'LP1',
          name: 'LP-1',
          sourceType: PanelSource.feeder,
          layoutPos: LayoutPos(sheetId: 's', floorIndex: 1, x: 0, y: 0),
          circuits: [
            ElectricalCircuit(
                id: 'l1',
                name: 'Lighting',
                loadKind: LoadKind.lighting,
                isLighting: true,
                loadW: 1200,
                length: Length(15)),
          ],
        ),
      ],
    );
