// Fix round 6 (third drawing review, 2026-11-20) — cross-surface
// consistency: C1 one pump-head formatter, C5 the '(auto)' mark defined on
// G-003, C9 G-003 line styles as the plans draw them.
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/cover_sheet.dart';
import 'package:mechx_engine/report/drawing_chrome.dart' show helveticaTextWidth;
import 'package:mechx_engine/report/number_format.dart';
import 'package:mechx_engine/report/plan_detail.dart';
import 'package:mechx_engine/report/sld_sheet.dart';
import 'package:test/test.dart';

void main() {
  test('C1: formatPumpHead is the schedule precision', () {
    expect(formatPumpHead(142.536), '142.5'); // report used to print 143
    expect(formatPumpHead(146.536), '146.5'); // and 147
    expect(formatPumpHead(210.151), '210.2'); // and 210
    expect(formatPumpHead(180.06), '180.1'); // apartment jockey (180)
    expect(formatPumpHead(0.03), '0.03'); // HW recirc (was '0.0')
    expect(formatPumpHead(0.106), '0.11');
    expect(formatPumpHead(98.5), '98.5'); // office fire pump (was '99')
  });

  test('C5: G-003 defines (auto) only when the set prints it', () {
    String? autoRow(bool on) => [
          for (final s in buildMasterLegendSections(autoMark: on))
            for (final e in s.entries)
              if (e.code == kAutoMark) e.meaning,
        ].firstOrNull;
    expect(autoRow(false), isNull);
    expect(autoRow(true), kAutoMarkMeaning);
    final texts = [
      for (final p in buildGeneralNotesSheet(autoMark: true).prims)
        if (p is SldLabel) p.text,
    ];
    expect(texts, containsAll([kAutoMark, kAutoMarkMeaning]));
  });

  test('C9: fire services swatch dash-dot, vent dashed, cold water solid', () {
    final sheet = buildGeneralNotesSheet(services: const [
      ServiceType.coldWater,
      ServiceType.vent,
      ServiceType.fireSprinkler,
      ServiceType.fireHydrant,
    ]);
    // The swatches are the thick lines on a service layer.
    final swatches = {
      for (final p in sheet.prims)
        if (p is SldLine && p.weight == SldWeight.thick && p.layer != null)
          p.layer!: p,
    };
    expect(swatches['SP']!.dashDot, isTrue);
    expect(swatches['FH']!.dashDot, isTrue);
    expect(swatches['SP']!.dashed, isFalse);
    expect(swatches['V']!.dashed, isTrue);
    expect(swatches['V']!.dashDot, isFalse);
    expect(swatches['CW']!.dashed || swatches['CW']!.dashDot, isFalse);
  });

  // Fix round 6 (T5) — a short detail scale bar never prints '0' against its
  // end figure: the '0' is dropped unless the end label clears it.
  test('T5: a short scale bar drops its 0, a long one keeps it', () {
    for (final n in [10, 20, 25, 50]) {
      for (final maxLen in [null, 8.0, 12.0, 20.0, 40.0]) {
        final b = planDetailScaleBar(
            n: n, x0: 0, y0: 0, textMm: 2.0, maxLenMm: maxLen);
        final end = b.texts.last;
        if (b.texts.any((t) => t.text == '0')) {
          // The end label starts at least half a text height past the 0.
          expect(end.x,
              greaterThanOrEqualTo(helveticaTextWidth('0', 2.0) + 1.0 - 1e-9),
              reason: 'n $n max $maxLen');
        }
      }
    }
  });
}
