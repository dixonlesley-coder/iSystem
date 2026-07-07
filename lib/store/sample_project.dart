/// A1 (workflow-goldens review): the Layout workspace's zero-file "try the
/// app" path. The sibling Electrical workspace ships an explicit one-click
/// 'Load sample project' (`resetToSample` in `electrical_store.dart`); before
/// this, Layout's empty state offered only Import / New-from-template, both
/// of which require a real plan file before ANYTHING — calibration, drawing,
/// auto-sizing, the pressure heatmap — becomes reachable.
///
/// [loadSampleLayoutProject] seeds a `PlaceholderSheetPage` sheet (the same
/// no-pdf/no-dxf idiom `kDemoSheets` and the golden fixture use), a plausible
/// per-sheet calibration, the app's own default 3-floor stack, and a tiny
/// cold-water + drainage run (a water meter feeding a lavatory that drains to
/// a stack/main) — small enough to read at a glance, real enough that sizing,
/// the calc report, and the heatmap all have something to show. Sizing itself
/// needs no seeding: `sizingProvider` is a live derived provider over the
/// network + calibration + floors, so it recomputes the moment these land.
///
/// Composed ENTIRELY from ordinary, already-undoable store intents — the same
/// calls the segment palette / draw tools use — so the seed is undoable and
/// dirty-tracked exactly like hand-drawn work, and (like every sheet-add in
/// this app, e.g. Import) never touches disk on its own; the project is only
/// written on an explicit Save. Mirrors `applyTemplateTo`'s
/// `WidgetRef`/`ProviderContainer`-agnostic `read` shape (`store/templates.dart`).
library;

import 'package:flutter/widgets.dart' show Offset, Size;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/standards/sni.dart';
import 'package:mechx_engine/units.dart';

import 'models/sheet.dart';
import 'network_store.dart';
import 'project_store.dart';
import 'sheets_store.dart';

/// The seeded sheet's id — a placeholder page (no pdf/dxf/dwg path), so the
/// canvas renders it via `PlaceholderSheetPage` like every other unimported
/// sheet.
const String kSampleSheetId = 'sample-sheet';

Sheet get kSampleSheet => const Sheet(
      id: kSampleSheetId,
      name: 'Sample floor plan',
      sizePx: Size(1684, 1190),
    );

/// The app's own default 3-floor stack (`ProjectController.build()`), spelled
/// out here so the seed is deterministic even when the engineer already
/// edited the floor stack (Building is reachable before any sheet is loaded).
List<Floor> get kSampleFloors => const [
      Floor('Ground', Length(4.0)),
      Floor('Level 1', Length(3.5)),
      Floor('Level 2', Length(3.5)),
    ];

/// 100 px = 1 m — a plausible round scale for a placeholder sheet with no
/// real plot to calibrate against.
const ScaleCalibration kSampleCalibration = ScaleCalibration(0.01);

/// Seed the demo project into the live app (a `WidgetRef` from the UI).
void loadSampleLayoutProject(WidgetRef ref) =>
    loadSampleLayoutProjectTo(ref.read);

/// Container-friendly core of [loadSampleLayoutProject]: [read] is the `read`
/// of a `WidgetRef` (from the UI) or a `ProviderContainer` (from tests/other
/// stores) — both expose the same `read(provider)` shape (mirrors
/// `applyTemplateTo` in `store/templates.dart`).
void loadSampleLayoutProjectTo(
  T Function<T>(ProviderListenable<T> provider) read,
) {
  // The sheet itself is a plain additive load — not undoable, matching every
  // other sheet-add in the app (e.g. Import, `SheetsController.addSheet`).
  read(sheetsControllerProvider.notifier).addSheet(kSampleSheet);

  // The floor stack + this sheet's scale — each an ordinary, already-undoable
  // project edit (`ProjectController.setFloors`/`setCalibration`).
  read(projectControllerProvider.notifier).setFloors(kSampleFloors);
  read(projectControllerProvider.notifier)
      .setCalibration(kSampleSheetId, kSampleCalibration);

  // The tiny cold-water + drainage run, laid out with the same palette-drop /
  // draw-a-run intents an engineer would use by hand — each its own undo
  // step: a water meter (entry), a lavatory (the shared fixture — one node
  // carries both a cold-water AND a drainage connection), and a drain/stack
  // main it empties into.
  final net = read(networkControllerProvider.notifier);
  const floor = 0;
  const meterAt = Offset(400, 600);
  const lavAt = Offset(700, 600);
  const drainAt = Offset(1000, 600);

  final meterId = net.mergeOrAddComponent(
      kSampleSheetId, floor, meterAt, NodeComponent.waterMeter);
  final lavId = net.mergeOrAddTerminal(kSampleSheetId, floor, lavAt,
      fixture: PlumbingFixture.lavatory);
  net.drawRunFromNode(meterId, lavAt, service: ServiceType.coldWater);
  net.mergeOrAddFitting(kSampleSheetId, floor, drainAt);
  net.drawRunFromNode(lavId, drainAt, service: ServiceType.drainage);
}
