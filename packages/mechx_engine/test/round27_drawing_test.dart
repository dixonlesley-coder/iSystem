/// Round 27 — issued DXF legibility:
///
/// * export-files-2-1 — the electrical layout DXF's title block sits ABOVE
///   the 'BELUM DITEMPATKAN' unplaced list, never drawn over it.
/// * export-files-2-3 — the SLD / riser DXF supply note wraps inside its
///   360-unit title box instead of running into the LEGEND.
library;

import 'package:mechx_engine/report/drawing_chrome.dart';
import 'package:mechx_engine/report/electrical_dxf_export.dart';
import 'package:mechx_engine/report/electrical_plan_export.dart';
import 'package:mechx_engine/report/sld_sheet.dart';
import 'package:test/test.dart';

/// Every TEXT / LINE entity of a DXF as (type, layer, values by group code).
List<({String type, String layer, Map<int, String> g})> _entities(String dxf) {
  final lines = dxf.split('\n');
  final out = <({String type, String layer, Map<int, String> g})>[];
  String? type;
  var g = <int, String>{};
  void flush() {
    final t = type;
    if (t != null) out.add((type: t, layer: g[8] ?? '', g: g));
  }

  for (var i = 0; i + 1 < lines.length; i += 2) {
    final code = int.tryParse(lines[i].trim());
    if (code == null) continue;
    final v = lines[i + 1];
    if (code == 0) {
      flush();
      type = (v == 'TEXT' || v == 'LINE') ? v : null;
      g = <int, String>{};
    } else if (type != null) {
      g[code] = v;
    }
  }
  flush();
  return out;
}

void main() {
  group('export-files-2-1 — layout DXF title block clear of the notes', () {
    const data = ElectricalPlanData(nodes: [
      ElectricalPlanNode(
          x: 100, y: 100, tag: 'LP-1', kind: ElectricalPlanNodeKind.panel),
    ], unplaced: [
      'LP-2 (Level 1)',
      '17 beban belum ditempatkan',
    ]);
    const chrome = DrawingChrome(
      clientName: 'PT Contoh',
      drawingNumber: 'E-101',
      revisionNumber: 'Rev. 0',
      dateString: '2026-10-18',
      drawnBy: 'AB',
      checkedBy: 'CD',
      approvedBy: 'EF',
      sheetIndex: 1,
      sheetTotal: 3,
    );

    for (final mpp in [null, 0.05]) {
      test('every title-block entity is above every note (mpp=$mpp)', () {
        final dxf = electricalPlanToDxf(
            data: data,
            projectName: 'Hotel',
            sheetName: 'Lantai Dasar',
            chrome: chrome,
            metersPerPixel: mpp);
        final es = _entities(dxf);
        final notes = es
            .where((e) =>
                e.type == 'TEXT' &&
                (e.g[1] == 'BELUM DITEMPATKAN:' ||
                    (e.g[1] ?? '').startsWith('- ')))
            .toList();
        expect(notes.length, 3);
        // A note's glyphs span [y, y + height] (DXF Y up, baseline at y).
        final noteTop = notes
            .map((e) => double.parse(e.g[20]!) + double.parse(e.g[40]!))
            .reduce((a, b) => a > b ? a : b);
        final frame = es.where((e) => e.layer == kDxfLayerEFrame).toList();
        expect(frame.where((e) => e.g[1] == 'REV'), isNotEmpty);
        for (final e in frame) {
          final ys = e.type == 'LINE'
              ? [double.parse(e.g[20]!), double.parse(e.g[21]!)]
              : [double.parse(e.g[20]!)];
          for (final y in ys) {
            expect(y, greaterThan(noteTop),
                reason: '${e.type} ${e.g[1] ?? ''} at $y over the notes '
                    '(top $noteTop)');
          }
        }
      });
    }
  });

  group('export-files-2-3 — SLD DXF supply note stays in its box', () {
    const note = 'Feed: gravity downfeed - roof tank - ground tank - pump';
    const sheet = SldSheet(
      prims: [SldLine(0, 0, 100, 0)],
      minX: 0,
      minY: 0,
      maxX: 100,
      maxY: 100,
      legend: [
        SldLegendEntry('CW', 'Air bersih (cold water)'),
        SldLegendEntry('HW', 'Air panas (hot water)'),
        SldLegendEntry('D', 'Air kotor & bekas (drainage)'),
        SldLegendEntry('V', 'Ven (vent)'),
      ],
      supplyNote: note,
    );

    test('the 54-char note wraps into the box, words intact', () {
      final dxf = electricalSldToDxf(sheet: sheet);
      final es = _entities(dxf);
      // The note lines: frame-layer TEXT at x = minX + 8 below the title.
      final noteLines = es
          .where((e) =>
              e.type == 'TEXT' &&
              e.layer == kDxfLayerEFrame &&
              note.contains(e.g[1] ?? '\u0000') &&
              (e.g[1] ?? '').isNotEmpty)
          .map((e) => e.g[1]!)
          .toList();
      expect(noteLines.length, greaterThanOrEqualTo(2));
      expect(noteLines.join(' '), note);
      // The wrap is computed at the em whose CAP height is the written 10:
      // 10 / 0.718 = 13.93 em, cell 360 - 16 = 344.
      final w = wrapTitleLines(note, 344,
              maxSize: 10 / kHelveticaCapHeightEm,
              minSize: 10 / kHelveticaCapHeightEm)
          .lines;
      expect(noteLines, w);
      // The legend's rows still start at minX + 408, clear of the box (360).
      expect(
          es.any((e) =>
              e.type == 'TEXT' &&
              e.g[1] == 'D  -  Air kotor & bekas (drainage)' &&
              double.parse(e.g[10]!) == 408),
          isTrue);
    });

    test('a short note keeps one line (byte-identical block)', () {
      const short = SldSheet(
        prims: [SldLine(0, 0, 100, 0)],
        minX: 0,
        minY: 0,
        maxX: 100,
        maxY: 100,
        legend: [],
        supplyNote: 'Supply: PLN 400 V',
      );
      final dxf = electricalSldToDxf(sheet: short);
      expect(dxf, contains('\n1\nSupply: PLN 400 V\n'));
    });
  });
}
