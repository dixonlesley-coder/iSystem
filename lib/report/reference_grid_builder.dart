/// Build the engine's N4 [ReferenceGrid] (setting-out column/row axes) from the
/// app's traced [ReferenceLine]s (B12) for one sheet. AXIS-ALIGNED lines become
/// grid axes — a (near-)vertical line is a COLUMN axis (constant sheet-x, lettered
/// A/B/C… left-to-right), a (near-)horizontal line a ROW axis (constant sheet-y,
/// numbered 1/2/3… top-to-bottom), matching the engine's own convention
/// (plan_symbols.dart). A line with a non-empty [ReferenceLine.label] keeps it;
/// otherwise it is auto-labelled in sorted order. NON-axis-aligned (diagonal)
/// reference lines are snap-only — they never become a grid axis.
///
/// Pure (no Flutter, no providers): the export call site passes the current
/// sheet's reference lines in, and threads the result into `planToPdf` /
/// `networkToDxf`'s `grid:` param.
library;

import 'dart:math' as math;

import 'package:mechx_engine/report/plan_symbols.dart';

import '../store/reference_line_store.dart';

/// A reference line is treated as an axis when its minor-axis span is within
/// this many pixels (absolute floor) OR this fraction of its length — a
/// hand-traced line snapped to ortho is exactly axis-aligned; a freehand one gets
/// a small tolerance.
const double _kAxisAbsTolPx = 2.0;
const double _kAxisRelTol = 0.02;

/// Build the [ReferenceGrid] for [sheetId] from [lines]. Empty when the sheet has
/// no axis-aligned reference lines ⇒ the exporters draw no grid (byte-identical).
ReferenceGrid buildReferenceGrid(List<ReferenceLine> lines, String sheetId) {
  // Collect axis-aligned lines with their constant position, split by axis.
  final cols = <_Axis>[]; // vertical lines → column axes (constant x)
  final rows = <_Axis>[]; // horizontal lines → row axes (constant y)
  for (final l in lines) {
    if (l.sheetId != sheetId) continue;
    final dx = (l.x2 - l.x1).abs();
    final dy = (l.y2 - l.y1).abs();
    final len = math.sqrt(dx * dx + dy * dy);
    if (len <= 0) continue;
    final tol = math.max(_kAxisAbsTolPx, _kAxisRelTol * len);
    final label = (l.label != null && l.label!.trim().isNotEmpty)
        ? l.label!.trim()
        : null;
    if (dx <= tol && dy > tol) {
      // Vertical → column axis at the average x.
      cols.add(_Axis((l.x1 + l.x2) / 2, label));
    } else if (dy <= tol && dx > tol) {
      // Horizontal → row axis at the average y.
      rows.add(_Axis((l.y1 + l.y2) / 2, label));
    }
    // else: diagonal — snap-only, not a grid axis.
  }

  cols.sort((a, b) => a.pos.compareTo(b.pos)); // left → right
  rows.sort((a, b) => a.pos.compareTo(b.pos)); // top → bottom

  return ReferenceGrid(
    columns: _label(cols, _columnLabel),
    rows: _label(rows, _rowLabel),
  );
}

/// Assign each axis a label: its own when set, else the next auto label (which
/// only advances for UNLABELLED axes, so an explicit label never eats a slot).
List<GridAxis> _label(List<_Axis> axes, String Function(int) auto) {
  final out = <GridAxis>[];
  var autoIdx = 0;
  for (final a in axes) {
    out.add(GridAxis(a.label ?? auto(autoIdx++), a.pos));
  }
  return out;
}

/// A → B → … → Z → AA → AB … for column [i] (0-based).
String _columnLabel(int i) {
  var n = i;
  final buf = StringBuffer();
  do {
    buf.write(String.fromCharCode('A'.codeUnitAt(0) + (n % 26)));
    n = n ~/ 26 - 1;
  } while (n >= 0);
  // Assembled low-digit-first; reverse for conventional order.
  return String.fromCharCodes(buf.toString().codeUnits.reversed);
}

/// 1, 2, 3 … for row [i] (0-based).
String _rowLabel(int i) => '${i + 1}';

class _Axis {
  final double pos;
  final String? label;
  _Axis(this.pos, this.label);
}
