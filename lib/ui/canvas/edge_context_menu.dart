import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/duct_sizing.dart' show standardDuctDiametersMm;
import 'package:mechx_engine/sizing/grille_sizing.dart'
    show standardGrilleFacesMm;
import 'package:mechx_engine/sizing/pipe_optimizer.dart';
import 'package:mechx_engine/standards/duct_products.dart';
import 'package:mechx_engine/standards/pipe_products.dart';
import 'package:mechx_engine/units.dart';

import '../../store/ai_copilot_store.dart';
import '../../store/layer_store.dart';
import '../../store/network_store.dart';
import '../../store/project_store.dart';
import '../../store/selection_store.dart';
import '../../store/sizing_store.dart';
import '../strings/app_strings.dart';
import '../theme/mechx_theme.dart';
import '../widgets/context_menu.dart';
import 'offset_dialog.dart';

/// Render a nominal size in inches as plain ASCII (no Unicode fractions, which
/// Roboto lacks): 0.5 -> 1/2", 0.75 -> 3/4", 1.25 -> 1 1/4", 2.0 -> 2".
String npsLabel(double inches) {
  final whole = inches.floor();
  final frac = inches - whole;
  String fracStr;
  if (frac == 0) {
    fracStr = '';
  } else if ((frac - 0.25).abs() < 1e-9) {
    fracStr = '1/4';
  } else if ((frac - 0.5).abs() < 1e-9) {
    fracStr = '1/2';
  } else if ((frac - 0.75).abs() < 1e-9) {
    fracStr = '3/4';
  } else {
    fracStr = frac.toStringAsFixed(2);
  }
  if (whole == 0) return '$fracStr"';
  if (fracStr.isEmpty) return '$whole"';
  return '$whole $fracStr"';
}

// ── B18: Trim/Extend a run to a picked boundary ─────────────────────────────

/// B18 — the armed 'Trim/Extend to...' target: the run [edgeId] whose
/// endpoint [endNodeId] will be moved to meet the NEXT clicked boundary run.
/// Null when nothing is armed. Armed from this file's edge context menu;
/// consumed by the selection-overlay gesture layer (a click on a run calls
/// [NetworkController.trimExtendEdge], a miss stays armed).
@immutable
class TrimExtendTarget {
  final String edgeId;
  final String endNodeId;
  const TrimExtendTarget(this.edgeId, this.endNodeId);

  @override
  bool operator ==(Object other) =>
      other is TrimExtendTarget &&
      other.edgeId == edgeId &&
      other.endNodeId == endNodeId;

  @override
  int get hashCode => Object.hash(edgeId, endNodeId);
}

final trimExtendArmedProvider =
    NotifierProvider<TrimExtendArmedController, TrimExtendTarget?>(
  TrimExtendArmedController.new,
);

class TrimExtendArmedController extends Notifier<TrimExtendTarget?> {
  @override
  TrimExtendTarget? build() => null;

  void arm(TrimExtendTarget target) => state = target;
  void disarm() => state = null;
}

// ── B19: Fix corner ──────────────────────────────────────────────────────────

/// The single RUN edge incident to [nodeId] when it is a lone (degree-1) run
/// end (not a riser), else null — a read-only geometry probe mirroring
/// `NetworkController`'s own private eligibility check for `joinCorner`.
NetEdge? soleDanglingRunEdge(Network net, String nodeId) {
  NetEdge? found;
  for (final e in net.edges) {
    if (e.fromId == nodeId || e.toId == nodeId) {
      if (found != null) return null; // degree > 1
      found = e;
    }
  }
  if (found == null || found.kind == EdgeKind.riser) return null;
  return found;
}

/// B19 — the nearest OTHER degree-1 same-service dangling run end within
/// [thresholdWorld] world px of [nodeId] (same sheet/floor), or null when none
/// qualifies. A read-only probe for the 'Fix corner' action (context menu +
/// the loose-end Design Issue row) — the actual join is
/// [NetworkController.joinCorner], which independently re-verifies eligibility.
String? cornerJoinPartner(Network net, String nodeId,
    {double thresholdWorld = 30}) {
  final edge = soleDanglingRunEdge(net, nodeId);
  final node = net.nodeById(nodeId);
  if (edge == null || node == null) return null;
  String? best;
  var bestD2 = thresholdWorld * thresholdWorld;
  for (final other in net.nodes) {
    if (other.id == nodeId) continue;
    if (other.sheetId != node.sheetId || other.floorIndex != node.floorIndex) {
      continue;
    }
    final oe = soleDanglingRunEdge(net, other.id);
    if (oe == null || oe.id == edge.id || oe.service != edge.service) continue;
    final dx = other.x - node.x;
    final dy = other.y - node.y;
    final d2 = dx * dx + dy * dy;
    if (d2 <= bestD2) {
      bestD2 = d2;
      best = other.id;
    }
  }
  return best;
}

// ── B27: Match properties (brush one run's size/material/service onto others) ─

/// B27 — the armed 'Match properties' brush: the source run's service-safe
/// properties (size override, material, and the service itself), captured at
/// arm time. Consumed by the selection-overlay gesture layer: each subsequent
/// click on a run of the SAME discipline family (the same [ServiceRegime])
/// receives them, one click at a time; a click on a different family is
/// ignored (never forces a duct's rectangular sizing method onto a water
/// pipe, or vice-versa).
@immutable
class MatchPropertiesBrush {
  final String sourceEdgeId;
  final ServiceType service;
  final Diameter? sizeOverride;
  final DuctProduct? ductProduct;
  final PipeProduct? pipeProduct;

  const MatchPropertiesBrush({
    required this.sourceEdgeId,
    required this.service,
    this.sizeOverride,
    this.ductProduct,
    this.pipeProduct,
  });
}

final matchPropertiesArmedProvider =
    NotifierProvider<MatchPropertiesArmedController, MatchPropertiesBrush?>(
  MatchPropertiesArmedController.new,
);

class MatchPropertiesArmedController extends Notifier<MatchPropertiesBrush?> {
  @override
  MatchPropertiesBrush? build() => null;

  void arm(MatchPropertiesBrush brush) => state = brush;
  void disarm() => state = null;
}

/// Apply [brush] onto [target] when they share a discipline family (the same
/// flow regime): the size override, the regime-appropriate material, and the
/// service itself — in ONE undo step via [NetworkController.setEdgeProperties]
/// (so a single brush click is a single Ctrl+Z, not up to three). The setter
/// no-ops when nothing changes, so a target that already matches is a safe
/// no-op. Returns false — applying NOTHING — when the families differ.
bool applyMatchProperties(
    NetworkController ctrl, MatchPropertiesBrush brush, NetEdge target) {
  if (target.service.regime != brush.service.regime) return false;
  final air = brush.service.regime == FlowRegime.air;
  ctrl.setEdgeProperties(
    target.id,
    service: brush.service,
    sizeOverride: brush.sizeOverride,
    pipeProduct: air ? null : brush.pipeProduct,
    ductProduct: air ? brush.ductProduct : null,
  );
  return true;
}

/// Show the per-edge right-click menu as a custom positioned panel in the root
/// [Overlay] (NO Material / showMenu). [globalPosition] is where the user
/// right-clicked; the menu is clamped inside the screen. A full-screen
/// transparent barrier behind it dismisses on any outside tap.
///
/// The root overlay sits ABOVE the app's `MechXTheme`, so the captured theme is
/// re-provided inside the entry (otherwise `context.colors` asserts).
void showEdgeContextMenu(
  BuildContext context,
  WidgetRef ref,
  String edgeId,
  Offset globalPosition, {
  // B18 — the click's WORLD position (same sheet as the edge), used to pick
  // the nearer endpoint for 'Trim/Extend to...'. Null hides that row (a
  // caller with no world coordinate handy — e.g. the riser schematic canvas —
  // is unaffected; the row simply doesn't apply there).
  Offset? world,
}) {
  final overlay = Overlay.of(context, rootOverlay: true);
  final theme = MechXTheme.of(context);
  late OverlayEntry entry;
  entry = OverlayEntry(
    builder: (ctx) => MechXTheme(
      data: theme,
      child: _EdgeMenuLayer(
        anchor: globalPosition,
        edgeId: edgeId,
        world: world,
        onDismiss: () => entry.remove(),
      ),
    ),
  );
  overlay.insert(entry);
}

/// Show the right-click menu for ANY node: the Fitting picker (Auto /
/// Coupling / Elbow / Tee / Wye / …) ONLY for a bare junction, the face-size
/// ladder for an air terminal (mirroring the inspector's picker), and Select
/// similar + Delete node for everything. Same overlay / barrier /
/// theme-reprovide mechanics as [showEdgeContextMenu].
void showNodeContextMenu(
  BuildContext context,
  WidgetRef ref,
  String nodeId,
  Offset globalPosition,
) {
  final overlay = Overlay.of(context, rootOverlay: true);
  final theme = MechXTheme.of(context);
  late OverlayEntry entry;
  entry = OverlayEntry(
    builder: (ctx) => MechXTheme(
      data: theme,
      child: _NodeMenuLayer(
        anchor: globalPosition,
        nodeId: nodeId,
        onDismiss: () => entry.remove(),
      ),
    ),
  );
  overlay.insert(entry);
}

/// Show the EMPTY-CANVAS right-click menu at [globalPosition]: Paste here
/// (when the clipboard holds something, pasted centred on the clicked [world]
/// point), Select all on this floor (scoped to the active discipline layer's
/// services), and Fit view (when the host provides the canvas handle).
void showCanvasContextMenu(
  BuildContext context,
  WidgetRef ref,
  Offset globalPosition, {
  required Offset world,
  required String sheetId,
  required int floorIndex,
  VoidCallback? onFitView,
}) {
  final overlay = Overlay.of(context, rootOverlay: true);
  final theme = MechXTheme.of(context);
  late OverlayEntry entry;
  entry = OverlayEntry(
    builder: (ctx) => MechXTheme(
      data: theme,
      child: _CanvasMenuLayer(
        anchor: globalPosition,
        world: world,
        sheetId: sheetId,
        floorIndex: floorIndex,
        onFitView: onFitView,
        onDismiss: () => entry.remove(),
      ),
    ),
  );
  overlay.insert(entry);
}

/// The multi-selection TRANSFORM rows (rotate / mirror about the selection's
/// bounding-box centre) plus a trailing divider — shown when 2+ elements are
/// picked. Each runs the matching [NetworkController] intent over the WHOLE
/// selection in ONE undo step (a transform leaves the node ids unchanged, so
/// the selection stays alive), then closes the menu. Reachable identically from
/// the edge + node menus, so a picked group — including a just-pasted or
/// stamped-assembly set (both leave their new elements as the multi-selection) —
/// can be turned or flipped in place. The selection is re-read at TAP time (not
/// captured at build), so the row always acts on the live set.
List<Widget> transformMenuRows(WidgetRef ref, VoidCallback close) {
  final ctrl = ref.read(networkControllerProvider.notifier);
  return [
    const MechXMenuHeader('Transform'),
    MechXMenuRow(
      label: 'Rotate 90 CW',
      onTap: () {
        final sel = ref.read(selectionProvider);
        ctrl.rotateSelection(sel.nodeIds, sel.edgeIds, clockwise: true);
        close();
      },
    ),
    MechXMenuRow(
      label: 'Rotate 90 CCW',
      onTap: () {
        final sel = ref.read(selectionProvider);
        ctrl.rotateSelection(sel.nodeIds, sel.edgeIds, clockwise: false);
        close();
      },
    ),
    MechXMenuRow(
      label: 'Mirror horizontal',
      onTap: () {
        final sel = ref.read(selectionProvider);
        ctrl.mirrorSelection(sel.nodeIds, sel.edgeIds, horizontal: true);
        close();
      },
    ),
    MechXMenuRow(
      label: 'Mirror vertical',
      onTap: () {
        final sel = ref.read(selectionProvider);
        ctrl.mirrorSelection(sel.nodeIds, sel.edgeIds, horizontal: false);
        close();
      },
    ),
    const MechXMenuDivider(),
  ];
}

class _NodeMenuLayer extends ConsumerWidget {
  final Offset anchor;
  final String nodeId;
  final VoidCallback onDismiss;

  const _NodeMenuLayer({
    required this.anchor,
    required this.nodeId,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final net = ref.watch(networkControllerProvider).network;
    final node = net.nodeById(nodeId);
    if (node == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => onDismiss());
      return const SizedBox.shrink();
    }
    final size = MediaQuery.sizeOf(context);
    const menuWidth = 208.0;
    final left =
        anchor.dx.clamp(0.0, (size.width - menuWidth).clamp(0.0, size.width));
    final top = anchor.dy.clamp(0.0, (size.height - 80).clamp(0.0, size.height));
    final maxHeight = size.height - 16;
    final ctrl = ref.read(networkControllerProvider.notifier);
    final sel = ref.read(selectionProvider.notifier);

    // When this node is part of a MULTI-selection (kept alive by the
    // selection-overlay's right-click, mirroring the edge menu's E1 rule), the
    // menu batches: rotate/mirror the whole picked group + Delete N — and the
    // single-node Fitting/Face pickers stand down (they'd edit just this one).
    final selection = ref.watch(selectionProvider);
    final isMulti = selection.isMulti;

    // A bare junction (no component, main role) gets the Fitting picker; an
    // air terminal (a diffuser/grille component, or any node carrying airflow)
    // gets the face-size ladder — the same picker the inspector offers.
    final isBareJunction =
        node.component == null && node.role == NodeRole.main;
    final isAirTerminal = node.airflow != null ||
        node.component == NodeComponent.supplyDiffuser ||
        node.component == NodeComponent.returnGrille ||
        node.component == NodeComponent.exhaustGrille ||
        node.component == NodeComponent.linearDiffuser;

    final children = <Widget>[
      if (isMulti) ...transformMenuRows(ref, onDismiss),
      if (!isMulti && isBareJunction) ...[
        const MechXMenuHeader('Fitting'),
        for (final f in JunctionFitting.values)
          MechXMenuRow(
            label: f.label,
            selected: (node.fittingType ?? JunctionFitting.auto) == f,
            onTap: () {
              ctrl.setNodeFittingType(nodeId, f);
              sel.selectNode(nodeId);
              onDismiss();
            },
          ),
        const MechXMenuDivider(),
      ],
      if (!isMulti && isAirTerminal) ...[
        const MechXMenuHeader('Face size'),
        MechXMenuRow(
          label: 'Auto',
          selected: node.faceWidthMm == null || node.faceHeightMm == null,
          onTap: () {
            ctrl.setNodeFace(nodeId, null, null);
            sel.selectNode(nodeId);
            onDismiss();
          },
        ),
        for (final face in standardGrilleFacesMm)
          MechXMenuRow(
            label: '${face.$1.round()}x${face.$2.round()}',
            mono: true,
            selected:
                node.faceWidthMm == face.$1 && node.faceHeightMm == face.$2,
            onTap: () {
              ctrl.setNodeFace(nodeId, face.$1, face.$2);
              sel.selectNode(nodeId);
              onDismiss();
            },
          ),
        const MechXMenuDivider(),
      ],
      // B19 — 'Fix corner': offered only on a lone (degree-1) run end that has
      // another same-service dangling end within reach; a read-only probe, so
      // a node with nothing nearby to join simply never shows the row.
      if (!isMulti && cornerJoinPartner(net, nodeId) != null)
        MechXMenuRow(
          label: context.strings(StringKey.fixCornerAction),
          onTap: () {
            final partner = cornerJoinPartner(net, nodeId);
            if (partner != null) ctrl.joinCorner(nodeId, partner);
            sel.clear();
            onDismiss();
          },
        ),
      MechXMenuRow(
        label: 'Select similar',
        onTap: () {
          sel.selectSimilarNodes(nodeId);
          onDismiss();
        },
      ),
      const MechXMenuDivider(),
      if (isMulti)
        MechXMenuRow(
          label: 'Delete ${selection.nodeIds.length + selection.edgeIds.length} selected',
          danger: true,
          onTap: () {
            final s = ref.read(selectionProvider);
            ctrl.deleteMany(s.nodeIds, s.edgeIds);
            sel.clear();
            onDismiss();
          },
        )
      else
        MechXMenuRow(
          label: 'Delete node',
          danger: true,
          onTap: () {
            ctrl.deleteNode(nodeId);
            sel.clear();
            onDismiss();
          },
        ),
    ];

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onDismiss,
            onSecondaryTap: onDismiss,
            child: const SizedBox.expand(),
          ),
        ),
        Positioned(
          left: left,
          top: top,
          width: menuWidth,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxHeight),
            // The face ladder makes the air-terminal menu tall — it scrolls.
            child: MechXContextMenu(scrollable: true, children: children),
          ),
        ),
      ],
    );
  }
}

class _CanvasMenuLayer extends ConsumerWidget {
  final Offset anchor;
  final Offset world;
  final String sheetId;
  final int floorIndex;
  final VoidCallback? onFitView;
  final VoidCallback onDismiss;

  const _CanvasMenuLayer({
    required this.anchor,
    required this.world,
    required this.sheetId,
    required this.floorIndex,
    required this.onFitView,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final size = MediaQuery.sizeOf(context);
    const menuWidth = 208.0;
    final left =
        anchor.dx.clamp(0.0, (size.width - menuWidth).clamp(0.0, size.width));
    final top = anchor.dy.clamp(0.0, (size.height - 80).clamp(0.0, size.height));
    final ctrl = ref.read(networkControllerProvider.notifier);
    final fit = onFitView;

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onDismiss,
            onSecondaryTap: onDismiss,
            child: const SizedBox.expand(),
          ),
        ),
        Positioned(
          left: left,
          top: top,
          width: menuWidth,
          child: MechXContextMenu(
            children: [
              if (ctrl.hasClipboard)
                MechXMenuRow(
                  label: 'Paste here',
                  onTap: () {
                    ctrl.pasteAt(
                        sheetId: sheetId, floorIndex: floorIndex, world: world);
                    onDismiss();
                  },
                ),
              MechXMenuRow(
                label: 'Select all on this floor',
                onTap: () {
                  final services =
                      servicesFor(ref.read(activeDisciplineProvider)).toSet();
                  ref.read(selectionProvider.notifier).selectAllOnFloor(
                        sheetId,
                        floorIndex,
                        services: services.isEmpty ? null : services,
                      );
                  onDismiss();
                },
              ),
              if (fit != null)
                MechXMenuRow(
                  label: 'Fit view',
                  onTap: () {
                    fit();
                    onDismiss();
                  },
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _EdgeMenuLayer extends ConsumerWidget {
  final Offset anchor;
  final String edgeId;
  final Offset? world;
  final VoidCallback onDismiss;

  const _EdgeMenuLayer({
    required this.anchor,
    required this.edgeId,
    required this.onDismiss,
    this.world,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final net = ref.watch(networkControllerProvider).network;
    NetEdge? edge;
    for (final e in net.edges) {
      if (e.id == edgeId) {
        edge = e;
        break;
      }
    }
    // Edge gone (deleted elsewhere) — close.
    if (edge == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => onDismiss());
      return const SizedBox.shrink();
    }

    final size = MediaQuery.sizeOf(context);
    const menuWidth = 232.0;
    final left = anchor.dx.clamp(0.0, (size.width - menuWidth).clamp(0.0, size.width));
    // Cap the height so it never runs off-screen; the menu scrolls if needed.
    final maxHeight = size.height - 16;
    final top = anchor.dy.clamp(0.0, (size.height - 80).clamp(0.0, size.height));

    return Stack(
      children: [
        // Dismiss barrier.
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onDismiss,
            onSecondaryTap: onDismiss,
            child: const SizedBox.expand(),
          ),
        ),
        Positioned(
          left: left,
          top: top,
          width: menuWidth,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxHeight),
            child: _EdgeMenuPanel(edge: edge, onDismiss: onDismiss, world: world),
          ),
        ),
      ],
    );
  }
}

class _EdgeMenuPanel extends ConsumerWidget {
  final NetEdge edge;
  final VoidCallback onDismiss;
  final Offset? world;

  const _EdgeMenuPanel({required this.edge, required this.onDismiss, this.world});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ctrl = ref.read(networkControllerProvider.notifier);
    final net = ref.watch(networkControllerProvider).network;
    final isAir = edge.service.regime == FlowRegime.air;

    // E1: when the right-clicked edge is part of a MULTI-selection, every
    // size/material action applies to the selection (one undo step via the
    // setEdges* intents) and KEEPS the selection alive — so "select similar,
    // right-click, set DN" batch-edits instead of collapsing to one edge.
    final selection = ref.watch(selectionProvider);
    final multi =
        selection.containsEdge(edge.id) && selection.edgeIds.length > 1;
    // Size/material batches are SCOPED to edges of the same regime as the
    // right-clicked one — the ladder + material list shown are regime-specific
    // (Ø/duct vs DN/pipe), so a mixed air+water selection never gets a duct Ø
    // forced onto a water pipe as a sizeOverride (which the solve would honour
    // and mis-size). Delete, by contrast, acts on the WHOLE selection.
    final sizeIds = selection.edgeIds.where((id) {
      final e = net.edgeById(id);
      return e != null && (e.service.regime == FlowRegime.air) == isAir;
    }).toSet();

    void close() => onDismiss();
    void afterEdit() {
      ref.read(selectionProvider.notifier).selectEdge(edge.id);
      close();
    }

    // Size/material appliers: batch (keep selection) in multi, else the single
    // edge (re-select it, matching the prior behaviour).
    // A regime batch is "multi" only when >1 same-regime edge would receive it;
    // otherwise fall to the single-edge path (re-selecting the clicked edge).
    final sizeMulti = multi && sizeIds.length > 1;
    void applySize(Diameter? size) {
      if (sizeMulti) {
        ctrl.setEdgesSizeOverride(sizeIds, size);
        close();
      } else {
        ctrl.setEdgeSizeOverride(edge.id, size);
        afterEdit();
      }
    }

    void applyDuctProduct(DuctProduct? p) {
      if (sizeMulti) {
        ctrl.setEdgesDuctProduct(sizeIds, p);
        close();
      } else {
        ctrl.setEdgeDuctProduct(edge.id, p);
        afterEdit();
      }
    }

    void applyPipeProduct(PipeProduct? p) {
      if (sizeMulti) {
        ctrl.setEdgesPipeProduct(sizeIds, p);
        close();
      } else {
        ctrl.setEdgePipeProduct(edge.id, p);
        afterEdit();
      }
    }

    final children = <Widget>[];

    if (sizeMulti) {
      children.add(MechXMenuHeader('Apply to ${sizeIds.length} selected'));
      children.add(const MechXMenuDivider());
    }

    if (isAir) {
      // ── Duct: set size (manual routing) ──────────────────────────────────
      children.add(const MechXMenuHeader('Set size'));
      for (final mm in standardDuctDiametersMm) {
        final selected = edge.sizeOverride != null &&
            (edge.sizeOverride!.inMillimeters - mm).abs() < 0.5;
        children.add(MechXMenuRow(
          label: 'Ø${mm.round()}',
          mono: true,
          selected: selected,
          onTap: () => applySize(Diameter.mm(mm)),
        ));
      }
      if (edge.sizeOverride != null) {
        children.add(MechXMenuRow(
          label: 'Clear size override',
          muted: true,
          onTap: () => applySize(null),
        ));
      }
      children.add(const MechXMenuDivider());
      // ── Duct: material + auto thickness ──────────────────────────────────
      children.add(const MechXMenuHeader('Duct material'));
      for (final p in DuctProduct.values) {
        children.add(MechXMenuRow(
          label: ductLabelFor(p),
          selected: edge.ductProduct == p,
          onTap: () => applyDuctProduct(p),
        ));
      }
      // Thickness note (derived from the sized W×H / diameter).
      final sizing = ref.watch(sizingProvider)[edge.id];
      if (edge.ductProduct != null && sizing != null) {
        final largest = sizing.isRectangular
            ? (sizing.width!.inMillimeters > sizing.height!.inMillimeters
                ? sizing.width!.inMillimeters
                : sizing.height!.inMillimeters)
            : sizing.diameter.inMillimeters;
        final note = edge.ductProduct == DuctProduct.bjls
            ? 'BJLS sheet ${bjlsThicknessMm(largest).toStringAsFixed(2)} mm '
                '(auto by size)'
            : 'PU panel ${puPanelThicknessMm().toStringAsFixed(0)} mm';
        children.add(MechXMenuNote(note));
      }
      // Sheet-material takeoff for this segment: developed area (perimeter ×
      // length) + the number of standard sheets/panels of the effective product.
      if (sizing != null) {
        final project = ref.watch(projectControllerProvider);
        final len = edgeLength(edge, net,
                calibrationBySheet: project.calibrations,
                building: project.building)
            .meters;
        final t = ductSheetTakeoff(edge, sizing, len);
        if (t != null) {
          children.add(MechXMenuNote(
            'Sheet material: ${t.developedAreaM2.toStringAsFixed(2)} m2 '
            '(perimeter x length) = ${t.sheets} '
            '${t.product == DuctProduct.pu ? 'panel' : 'sheet'}'
            '${t.sheets == 1 ? '' : 's'} @ '
            '${t.sheetAreaM2.toStringAsFixed(2)} m2',
          ));
        }
        // Accessories takeoff: covering angle (siku) + gasket + hangers + bolts.
        final acc = computeDuctAccessories(edge, sizing, len);
        if (acc != null) {
          children.add(MechXMenuNote(
            'Accessories: ${acc.flangeAngleM.toStringAsFixed(1)} m covering angle'
            ' · ${acc.gasketM.toStringAsFixed(1)} m gasket · '
            '${acc.hangers} hanger${acc.hangers == 1 ? '' : 's'} · '
            '${acc.bolts} bolt set${acc.bolts == 1 ? '' : 's'}',
          ));
        }
      }
      if (edge.ductProduct != null) {
        children.add(MechXMenuRow(
          label: 'Clear material',
          muted: true,
          onTap: () => applyDuctProduct(null),
        ));
      }
    } else {
      // ── Pipe: set size + material ────────────────────────────────────────
      children.add(const MechXMenuHeader('Set size'));
      for (final inches in npsInches) {
        final mm = npsToMm(inches);
        final selected = edge.sizeOverride != null &&
            (edge.sizeOverride!.inMillimeters - mm).abs() < 0.5;
        children.add(MechXMenuRow(
          label: '${npsLabel(inches)}   DN${mm.round()}',
          mono: true,
          selected: selected,
          onTap: () => applySize(Diameter.mm(mm)),
        ));
      }
      if (edge.sizeOverride != null) {
        children.add(MechXMenuRow(
          label: 'Clear size override',
          muted: true,
          onTap: () => applySize(null),
        ));
      }
      children.add(const MechXMenuDivider());
      children.add(const MechXMenuHeader('Pipe material'));
      for (final p in PipeProduct.values) {
        children.add(MechXMenuRow(
          label: labelFor(p),
          selected: edge.pipeProduct == p,
          onTap: () => applyPipeProduct(p),
        ));
      }
      if (edge.pipeProduct != null) {
        children.add(MechXMenuRow(
          label: 'Clear material',
          muted: true,
          onTap: () => applyPipeProduct(null),
        ));
      }
    }

    children.add(const MechXMenuDivider());
    // Offset — a parallel run at a typed distance. Only meaningful for a SINGLE
    // horizontal run on a calibrated sheet (needs a real scale); hidden while a
    // multi-selection is the target (it's a one-edge geometric op).
    final sheetId = ref.watch(networkControllerProvider).network
        .nodeById(edge.fromId)
        ?.sheetId;
    final calibrated = sheetId != null &&
        ref.watch(projectControllerProvider).calibrationFor(sheetId) != null;
    if (!multi && edge.kind == EdgeKind.run && calibrated) {
      children.add(MechXMenuRow(
        label: 'Offset…',
        onTap: () {
          // Open the dialog with the live context first, then dismiss the menu.
          showOffsetDialog(context, ref, edge.id);
          close();
        },
      ));
    }
    // B18 — 'Trim/Extend to...': arms a boundary pick against the endpoint
    // nearer the right-click. Needs a world position (the caller-supplied
    // click point) to disambiguate the two ends; single-run only.
    if (!multi && edge.kind == EdgeKind.run && world != null) {
      final a = net.nodeById(edge.fromId);
      final b = net.nodeById(edge.toId);
      if (a != null && b != null) {
        final da = (Offset(a.x, a.y) - world!).distanceSquared;
        final db = (Offset(b.x, b.y) - world!).distanceSquared;
        final endId = da <= db ? a.id : b.id;
        children.add(MechXMenuRow(
          label: context.strings(StringKey.edgeMenuTrimExtend),
          onTap: () {
            ref.read(matchPropertiesArmedProvider.notifier).disarm();
            ref
                .read(trimExtendArmedProvider.notifier)
                .arm(TrimExtendTarget(edge.id, endId));
            close();
          },
        ));
      }
    }
    // B27 — 'Match properties': arms a brush carrying this run's service-safe
    // properties (size override, material, service); single-run only.
    if (!multi && edge.kind == EdgeKind.run) {
      children.add(MechXMenuRow(
        label: context.strings(StringKey.edgeMenuMatchProperties),
        onTap: () {
          ref.read(trimExtendArmedProvider.notifier).disarm();
          ref.read(matchPropertiesArmedProvider.notifier).arm(
                MatchPropertiesBrush(
                  sourceEdgeId: edge.id,
                  service: edge.service,
                  sizeOverride: edge.sizeOverride,
                  ductProduct: edge.ductProduct,
                  pipeProduct: edge.pipeProduct,
                ),
              );
          close();
        },
      ));
    }
    // F2: with a group picked (2+ elements, kept alive by E1's right-click),
    // offer rotate/mirror about the selection's bounding-box centre — the same
    // intents the just-pasted / stamped-assembly set can be turned/flipped with.
    if (selection.isMulti) {
      children.addAll(transformMenuRows(ref, close));
    }
    children.add(MechXMenuRow(
      label: 'Select similar',
      onTap: () {
        ref.read(selectionProvider.notifier).selectSimilarEdges(edge.id);
        close();
      },
    ));
    // I6 — reach the copilot where the work is: pre-scope it to THIS run
    // (select it so the copilot's context frame describes it) and open the panel.
    children.add(MechXMenuRow(
      label: 'Ask Claude…',
      onTap: () {
        ref.read(selectionProvider.notifier).selectEdge(edge.id);
        ref.read(copilotOpenProvider.notifier).open();
        close();
      },
    ));
    children.add(const MechXMenuDivider());
    if (multi) {
      // Delete the whole selection (edges + any selected nodes) in one step —
      // NOT regime-scoped: deleting removes everything selected.
      children.add(MechXMenuRow(
        label: 'Delete ${selection.edgeIds.length} selected',
        danger: true,
        onTap: () {
          ctrl.deleteMany(selection.nodeIds, selection.edgeIds);
          ref.read(selectionProvider.notifier).clear();
          close();
        },
      ));
    } else {
      children.add(MechXMenuRow(
        label: 'Delete ${edge.kind == EdgeKind.riser ? 'riser' : 'segment'}',
        danger: true,
        onTap: () {
          ctrl.deleteEdge(edge.id);
          ref.read(selectionProvider.notifier).clear();
          close();
        },
      ));
    }

    // The menu can be tall (a full size ladder), so its body scrolls.
    return MechXContextMenu(scrollable: true, children: children);
  }
}
