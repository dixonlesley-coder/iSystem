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

/// Footprint (sheet px) of a placed load marker at world scale.
const double kLayoutLoadW = 92;
const double kLayoutLoadH = 50;

/// Callbacks the layout layer raises back to its host (the unified Layout
/// canvas) to open the inspector / context menus over the one shared model.
typedef LayoutPanelEdit = void Function(String panelId);
typedef LayoutCircuitEdit = void Function(String panelId, String circuitId);
typedef LayoutPanelMenu = void Function(String panelId, Offset globalPos);
typedef LayoutCircuitMenu = void Function(
    String panelId, String circuitId, Offset globalPos);
