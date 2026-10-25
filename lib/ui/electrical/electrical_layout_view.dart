/// Shared layout constants + callback typedefs for placing electrical PANELS
/// and LOADS on the calibrated PDF floor-plan sheet (so each circuit's cable run
/// length comes from REAL geometry, §10 geometry-is-truth).
///
/// The placement RENDERING + interactions now live on the unified Layout canvas
/// as the Electrical discipline layer (`ui/layout/electrical_layer.dart`) — a
/// co-equal projection of the SAME `electricalProjectProvider` model as the
/// abstract Single-line canvas. This file is the small contract both share:
/// marker footprints, the zoom LOD threshold, and the edit/menu callback types.
library;

import 'package:flutter/widgets.dart';

/// LOD threshold for the layout markers — at/above this zoom a load/panel shows
/// its fuller node; below it, a compact marker + tag.
const double kLayoutLod = 0.65;

/// Footprint (sheet px) of a placed panel marker at world scale.
const double kLayoutPanelW = 150;
const double kLayoutPanelH = 56;

/// Footprint (sheet px) of a placed load marker at world scale. Round 13
/// (ui-journey-2) — 58 tall: the detail body is a 30 px chip + 2 px gap + a
/// ~24 px two-line caption (9 pt name + 8 pt amps/utilisation, 1.3 line
/// height, 2 px padding) = ~56 px, which overflowed the old 50 px box by 6 px
/// on every sized load at detail zoom (the amps line clipped).
const double kLayoutLoadW = 92;
const double kLayoutLoadH = 58;

/// Largest on-screen scale a plan marker reaches. Below it a marker tracks the
/// zoom (it is placed equipment, sized to the plan); above it the marker stays
/// this size, so zooming in to trace a wall never balloons a board into a
/// slab that hides the plan it sits on (a panel marker tops out at 225 x 84 px).
const double kLayoutMarkerMaxScale = 1.5;

/// The on-screen scale of a plan marker at canvas [zoom] — the ONE figure the
/// marker's layout box, its hit rect, the marquee and the drop-onto radius all
/// use, so what is drawn is exactly what is hit.
double layoutMarkerScale(double zoom) =>
    zoom < kLayoutMarkerMaxScale ? zoom : kLayoutMarkerMaxScale;

/// Callbacks the layout layer raises back to its host (the unified Layout
/// canvas) to open the inspector / context menus over the one shared model.
typedef LayoutPanelEdit = void Function(String panelId);
typedef LayoutCircuitEdit = void Function(String panelId, String circuitId);
typedef LayoutPanelMenu = void Function(String panelId, Offset globalPos);
typedef LayoutCircuitMenu = void Function(
    String panelId, String circuitId, Offset globalPos);
