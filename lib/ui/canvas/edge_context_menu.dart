import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/pipe_optimizer.dart';
import 'package:mechx_engine/standards/duct_products.dart';
import 'package:mechx_engine/standards/pipe_products.dart';
import 'package:mechx_engine/units.dart';

import '../../store/network_store.dart';
import '../../store/project_store.dart';
import '../../store/selection_store.dart';
import '../../store/sizing_store.dart';
import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';

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
          child: _MenuEntrance(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: context.colors.surface,
                borderRadius: MechXRadii.card,
                border: Border.all(color: context.colors.border),
                boxShadow: const [
                  BoxShadow(
                      color: Color(0x40000000),
                      blurRadius: 18,
                      offset: Offset(0, 6)),
                ],
              ),
              child: ClipRRect(
                borderRadius: MechXRadii.card,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: MechXSpacing.xs),
                    const _MenuHeader('Fitting'),
                    for (final f in JunctionFitting.values)
                      _MenuRow(
                        label: f.label,
                        selected: (node.fittingType ?? JunctionFitting.auto) == f,
                        onTap: () {
                          ctrl.setNodeFittingType(nodeId, f);
                          ref.read(selectionProvider.notifier).selectNode(nodeId);
                          onDismiss();
                        },
                      ),
                    const SizedBox(height: MechXSpacing.xs),
                  ],
                ),
              ),
            ),
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
    final colors = context.colors;
    final ctrl = ref.read(networkControllerProvider.notifier);
    final isAir = edge.service.regime == FlowRegime.air;

    void close() => onDismiss();
    void afterEdit() {
      ref.read(selectionProvider.notifier).selectEdge(edge.id);
      close();
    }

    final children = <Widget>[];

    if (isAir) {
      // ── Duct: material + auto thickness ──────────────────────────────────
      children.add(const _MenuHeader('Duct material'));
      for (final p in DuctProduct.values) {
        children.add(_MenuRow(
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
        children.add(_MenuNote(note));
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
          children.add(_MenuNote(
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
          children.add(_MenuNote(
            'Accessories: ${acc.flangeAngleM.toStringAsFixed(1)} m covering angle'
            ' · ${acc.gasketM.toStringAsFixed(1)} m gasket · '
            '${acc.hangers} hanger${acc.hangers == 1 ? '' : 's'} · '
            '${acc.bolts} bolt set${acc.bolts == 1 ? '' : 's'}',
          ));
        }
      }
      if (edge.ductProduct != null) {
        children.add(_MenuRow(
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
      children.add(const _MenuHeader('Set size'));
      for (final inches in npsInches) {
        final mm = npsToMm(inches);
        final selected = edge.sizeOverride != null &&
            (edge.sizeOverride!.inMillimeters - mm).abs() < 0.5;
        children.add(_MenuRow(
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
        children.add(_MenuRow(
          label: 'Clear size override',
          muted: true,
          onTap: () {
            ctrl.setEdgeSizeOverride(edge.id, null);
            afterEdit();
          },
        ));
      }
      children.add(const _MenuDivider());
      children.add(const _MenuHeader('Pipe material'));
      for (final p in PipeProduct.values) {
        children.add(_MenuRow(
          label: labelFor(p),
          selected: edge.pipeProduct == p,
          onTap: () {
            ctrl.setEdgePipeProduct(edge.id, p);
            afterEdit();
          },
        ));
      }
      if (edge.pipeProduct != null) {
        children.add(_MenuRow(
          label: 'Clear material',
          muted: true,
          onTap: () {
            ctrl.setEdgePipeProduct(edge.id, null);
            afterEdit();
          },
        ));
      }
    }

    children.add(const _MenuDivider());
    children.add(_MenuRow(
      label: 'Delete ${edge.kind == EdgeKind.riser ? 'riser' : 'segment'}',
      danger: true,
      onTap: () {
        ctrl.deleteEdge(edge.id);
        ref.read(selectionProvider.notifier).clear();
        close();
      },
    ));

    // Entrance: scale-in (~0.92 → 1.0) + fade over MechXMotion.appear, anchored
    // at the top-left so the menu grows out of the click point. One-shot motion.
    return _MenuEntrance(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: MechXRadii.card,
          border: Border.all(color: colors.border),
          boxShadow: const [
            BoxShadow(
                color: Color(0x40000000), blurRadius: 18, offset: Offset(0, 6)),
          ],
        ),
        child: ClipRRect(
          borderRadius: MechXRadii.card,
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(vertical: MechXSpacing.xs),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: children,
            ),
          ),
        ),
      ),
    );
  }
}

/// A one-shot menu entrance: scales from ~0.92 → 1.0 and fades 0 → 1 over
/// [MechXMotion.appear], anchored top-left. Transient — the menu settles at its
/// natural size/opacity, so nothing changes at rest.
class _MenuEntrance extends StatelessWidget {
  final Widget child;
  const _MenuEntrance({required this.child});

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.0, end: 1.0),
      duration: MechXMotion.appear,
      curve: MechXMotion.emphasized,
      child: child,
      builder: (context, t, child) => Opacity(
        opacity: t.clamp(0.0, 1.0),
        child: Transform.scale(
          scale: 0.92 + 0.08 * t,
          alignment: Alignment.topLeft,
          child: child,
        ),
      ),
    );
  }
}

class _MenuHeader extends StatelessWidget {
  final String text;
  const _MenuHeader(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(
          MechXSpacing.sm + 2,
          MechXSpacing.xs,
          MechXSpacing.sm,
          MechXSpacing.xxs,
        ),
        child: Text(
          text.toUpperCase(),
          style: context.type.caption.copyWith(
            color: context.colors.textMuted,
            letterSpacing: 0.7,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
}

class _MenuNote extends StatelessWidget {
  final String text;
  const _MenuNote(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(
          MechXSpacing.sm + 2,
          MechXSpacing.xxs,
          MechXSpacing.sm,
          MechXSpacing.xs,
        ),
        child: Text(
          text,
          style: context.type.caption.copyWith(color: context.colors.textSecondary),
        ),
      );
}

class _MenuDivider extends StatelessWidget {
  const _MenuDivider();

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: MechXSpacing.xxs),
        child: Container(height: 1, color: context.colors.border),
      );
}

class _MenuRow extends StatefulWidget {
  final String label;
  final bool selected;
  final bool danger;
  final bool muted;
  final bool mono;
  final VoidCallback onTap;

  const _MenuRow({
    required this.label,
    required this.onTap,
    this.selected = false,
    this.danger = false,
    this.muted = false,
    this.mono = false,
  });

  @override
  State<_MenuRow> createState() => _MenuRowState();
}

class _MenuRowState extends State<_MenuRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    final Color fg = widget.danger
        ? colors.danger
        : widget.muted
            ? colors.textMuted
            : colors.textPrimary;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: MechXMotion.hover,
          curve: MechXMotion.standard,
          color: _hover ? colors.surfaceHover : const Color(0x00000000),
          padding: const EdgeInsets.symmetric(
            horizontal: MechXSpacing.sm + 2,
            vertical: MechXSpacing.xs + 1,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  widget.label,
                  style: (widget.mono ? type.mono : type.label).copyWith(
                    color: fg,
                    fontWeight: widget.selected ? FontWeight.w700 : null,
                  ),
                ),
              ),
              if (widget.selected)
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: colors.accent,
                    borderRadius: const BorderRadius.all(Radius.circular(3)),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
