// Drawing review — fix round 4 (2026-11-13): the three residual legibility
// defects of the re-checked set (`docs/DRAWING-REVIEW-RECORD.md` "Fix round
// 4"), each pinned on the shared pure layout layer the PDF and the DXF both
// draw from.
import 'package:mechx_engine/report/drawing_chrome.dart'
    show LabelBox;
import 'package:mechx_engine/report/plan_symbols.dart';
import 'package:test/test.dart';


/// Does segment [s] pass through the axis-aligned box [b] (interior)?
bool _segHitsBox(LabelSegment s, LabelBox b) {
  // Sample densely: the boxes here are a few points wide.
  for (var i = 0; i <= 400; i++) {
    final t = i / 400;
    final x = s.x1 + (s.x2 - s.x1) * t, y = s.y1 + (s.y2 - s.y1) * t;
    if (x > b.minX && x < b.maxX && y > b.minY && y < b.maxY) return true;
  }
  return false;
}

void main() {
  group('R1 a key leader never runs through text registered as a box', () {
    test('the leader steps round a detail caption instead of through it', () {
      const ts = 9.0;
      final layout = PlanLabelLayout();
      // A ring of plain (non-text) occupied boxes fills the hugging ring so
      // the key has to step out on a leader.
      for (final b in const [
        (minX: -4.05, minY: -4.05, maxX: 4.05, maxY: -1.35),
        (minX: -4.05, minY: 1.35, maxX: 4.05, maxY: 4.05),
        (minX: -4.05, minY: -4.05, maxX: -1.35, maxY: 4.05),
        (minX: 1.35, minY: -4.05, maxX: 4.05, maxY: 4.05),
      ]) {
        layout.addBox(b);
      }
      // A detail caption just above the element, under the first (straight
      // up) leader slot but clear of that slot's circle.
      const caption = (minX: -40.0, minY: 4.3, maxX: 40.0, maxY: 5.2);
      layout.addTextBox(caption);
      final k = placePlanLabel(
          ax: 0,
          ay: 0,
          bx: 1,
          by: 0,
          text: 'RA-L16 · 1200x700',
          textSize: ts,
          layout: layout,
          anchorPoint: (x: 0, y: 0),
          keys: PlanKeyRegistry(),
          keyOnly: true);
      expect(k.keyCircle, isNotNull);
      expect(k.leaderAnchor, isNotNull, reason: 'stepped out on a leader');
      final leader = (
        x1: k.leaderAnchor!.x,
        y1: k.leaderAnchor!.y,
        x2: k.leaderEnd!.x,
        y2: k.leaderEnd!.y
      );
      expect(_segHitsBox(leader, caption), isFalse,
          reason: 'the leader misses the caption');
    });
  });
}
