import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/duct_sizing.dart' show standardDuctDiametersMm;
import 'package:mechx_engine/sizing/pipe_optimizer.dart';
import 'package:mechx_engine/standards/duct_products.dart';
import 'package:mechx_engine/standards/pipe_products.dart';
import 'package:mechx_engine/units.dart';

import '../../store/network_store.dart';
import '../../store/project_store.dart';
import '../../store/selection_store.dart';
import '../../store/sizing_store.dart';
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
  Offset globalPosition,
) {
  final overlay = Overlay.of(context, rootOverlay: true);
  final theme = MechXTheme.of(context);
  late OverlayEntry entry;
  entry = OverlayEntry(
    builder: (ctx) => MechXTheme(
      data: theme,
      child: _EdgeMenuLayer(
        anchor: globalPosition,
        edgeId: edgeId,
        onDismiss: () => entry.remove(),
      ),
    ),
  );
  overlay.insert(entry);
}

/// Show the per-junction right-click Fitting menu (Auto / Coupling / Elbow /
/// Tee / Wye / Tee-wye / Cross / End cap) for node [nodeId]. Same overlay /
/// barrier / theme-reprovide mechanics as [showEdgeContextMenu].
void showNodeFittingMenu(
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
      child: _NodeFittingLayer(
        anchor: globalPosition,
        nodeId: nodeId,
        onDismiss: () => entry.remove(),
      ),
    ),
  );
  overlay.insert(entry);
}

class _NodeFittingLayer extends ConsumerWidget {
  final Offset anchor;
  final String nodeId;
  final VoidCallback onDismiss;

  const _NodeFittingLayer({
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
    final ctrl = ref.read(networkControllerProvider.notifier);

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
              const MechXMenuHeader('Fitting'),
              for (final f in JunctionFitting.values)
                MechXMenuRow(
                  label: f.label,
                  selected: (node.fittingType ?? JunctionFitting.auto) == f,
                  onTap: () {
                    ctrl.setNodeFittingType(nodeId, f);
                    ref.read(selectionProvider.notifier).selectNode(nodeId);
                    onDismiss();
                  },
                ),
              const MechXMenuDivider(),
              MechXMenuRow(
                label: 'Select similar',
                onTap: () {
                  ref
                      .read(selectionProvider.notifier)
                      .selectSimilarNodes(nodeId);
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
  final VoidCallback onDismiss;

  const _EdgeMenuLayer({
    required this.anchor,
    required this.edgeId,
    required this.onDismiss,
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
            child: _EdgeMenuPanel(edge: edge, onDismiss: onDismiss),
          ),
        ),
      ],
    );
  }
}

class _EdgeMenuPanel extends ConsumerWidget {
  final NetEdge edge;
  final VoidCallback onDismiss;

  const _EdgeMenuPanel({required this.edge, required this.onDismiss});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ctrl = ref.read(networkControllerProvider.notifier);
    final isAir = edge.service.regime == FlowRegime.air;

    void close() => onDismiss();
    void afterEdit() {
      ref.read(selectionProvider.notifier).selectEdge(edge.id);
      close();
    }

    final children = <Widget>[];

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
          onTap: () {
            ctrl.setEdgeSizeOverride(edge.id, Diameter.mm(mm));
            afterEdit();
          },
        ));
      }
      if (edge.sizeOverride != null) {
        children.add(MechXMenuRow(
          label: 'Clear size override',
          muted: true,
          onTap: () {
            ctrl.setEdgeSizeOverride(edge.id, null);
            afterEdit();
          },
        ));
      }
      children.add(const MechXMenuDivider());
      // ── Duct: material + auto thickness ──────────────────────────────────
      children.add(const MechXMenuHeader('Duct material'));
      for (final p in DuctProduct.values) {
        children.add(MechXMenuRow(
          label: ductLabelFor(p),
          selected: edge.ductProduct == p,
          onTap: () {
            ctrl.setEdgeDuctProduct(edge.id, p);
            afterEdit();
          },
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
        final net = ref.watch(networkControllerProvider).network;
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
          onTap: () {
            ctrl.setEdgeDuctProduct(edge.id, null);
            afterEdit();
          },
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
          onTap: () {
            ctrl.setEdgeSizeOverride(edge.id, Diameter.mm(mm));
            afterEdit();
          },
        ));
      }
      if (edge.sizeOverride != null) {
        children.add(MechXMenuRow(
          label: 'Clear size override',
          muted: true,
          onTap: () {
            ctrl.setEdgeSizeOverride(edge.id, null);
            afterEdit();
          },
        ));
      }
      children.add(const MechXMenuDivider());
      children.add(const MechXMenuHeader('Pipe material'));
      for (final p in PipeProduct.values) {
        children.add(MechXMenuRow(
          label: labelFor(p),
          selected: edge.pipeProduct == p,
          onTap: () {
            ctrl.setEdgePipeProduct(edge.id, p);
            afterEdit();
          },
        ));
      }
      if (edge.pipeProduct != null) {
        children.add(MechXMenuRow(
          label: 'Clear material',
          muted: true,
          onTap: () {
            ctrl.setEdgePipeProduct(edge.id, null);
            afterEdit();
          },
        ));
      }
    }

    children.add(const MechXMenuDivider());
    // Offset — a parallel run at a typed distance. Only meaningful for a
    // horizontal run on a calibrated sheet (needs a real scale).
    final sheetId = ref.watch(networkControllerProvider).network
        .nodeById(edge.fromId)
        ?.sheetId;
    final calibrated = sheetId != null &&
        ref.watch(projectControllerProvider).calibrationFor(sheetId) != null;
    if (edge.kind == EdgeKind.run && calibrated) {
      children.add(MechXMenuRow(
        label: 'Offset…',
        onTap: () {
          // Open the dialog with the live context first, then dismiss the menu.
          showOffsetDialog(context, ref, edge.id);
          close();
        },
      ));
    }
    children.add(MechXMenuRow(
      label: 'Select similar',
      onTap: () {
        ref.read(selectionProvider.notifier).selectSimilarEdges(edge.id);
        close();
      },
    ));
    children.add(const MechXMenuDivider());
    children.add(MechXMenuRow(
      label: 'Delete ${edge.kind == EdgeKind.riser ? 'riser' : 'segment'}',
      danger: true,
      onTap: () {
        ctrl.deleteEdge(edge.id);
        ref.read(selectionProvider.notifier).clear();
        close();
      },
    ));

    // The menu can be tall (a full size ladder), so its body scrolls.
    return MechXContextMenu(scrollable: true, children: children);
  }
}
