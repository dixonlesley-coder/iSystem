import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../store/annotation_store.dart';
import '../../store/base_point_command_store.dart';
import '../../store/network_store.dart';
import '../../store/project_store.dart';
import '../../store/sheets_store.dart';
import '../../store/snap_settings_store.dart';
import '../strings/app_strings.dart';
import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';
import '../widgets/glass_surface.dart';
import '../widgets/mechx_focus_ring.dart';
import 'base_point_overlay.dart' show basePointKey, basePointModeLabel;
import 'edge_context_menu.dart'
    show matchPropertiesArmedProvider, trimExtendArmedProvider;
import 'service_style.dart';

/// A floating on-canvas MODE pill (top-centre): makes the active tool visible
/// on the canvas itself — the only other cue is the highlighted button inside
/// the (twice-collapsible) inspector, so the mode could be entirely invisible.
/// Shows the mode name (+ the service swatch for draw modes), an 'Esc' hint,
/// and a tappable Done that returns to Select. Renders NOTHING in plain Select
/// mode, so the at-rest canvas (and every golden) is unchanged.
class ModePill extends ConsumerWidget {
  const ModePill({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Only the tool + service (not the network): a drag frame never rebuilds it.
    final drawing = ref.watch(networkControllerProvider
        .select((d) => (tool: d.tool, service: d.service)));
    final measure = ref.watch(measureModeProvider);
    final tank = ref.watch(tankModeProvider);
    final room = ref.watch(roomModeProvider);
    final refLine = ref.watch(refLineModeProvider);
    // M4 — the select-mode ARMED actions (B18 trim/extend boundary pick, B27
    // match-properties brush) are modes too: named here with the same Esc /
    // Done exit, so the armed state is never invisible.
    final trimArmed = ref.watch(trimExtendArmedProvider) != null;
    final brush = ref.watch(matchPropertiesArmedProvider);
    // M8 — a live base-point Move / Copy / Rotate names its next pick.
    final cmd = ref.watch(basePointCommandProvider);

    // The modes are mutually exclusive by the toolbar's design; resolve in
    // the same priority order the overlays mount. [keyHint] echoes the
    // single-key shortcut (C3); [freeAngle] notes hold-Shift ortho override on
    // the run/riser modes (C9).
    String? label;
    String? keyHint;
    bool freeAngle = false;
    bool escHint = true;
    Color? swatch;
    void Function()? done;
    if (drawing.tool == DrawTool.drawRun) {
      label = 'Run · ${serviceLabel(drawing.service)}';
      keyHint = 'R';
      freeAngle = true;
      swatch = serviceColor(drawing.service);
      done = () => ref
          .read(networkControllerProvider.notifier)
          .setTool(DrawTool.select);
    } else if (drawing.tool == DrawTool.drawRiser) {
      // Say what the riser will CONNECT (C6): the floor span it spans to (up to
      // N+1, or down to N-1 on the top floor), mirroring `placeRiser`. The swatch
      // still carries the service colour.
      final sheets = ref.watch(sheetsContentProvider);
      final levelCount =
          ref.watch(projectControllerProvider).building.levelCount;
      final current = sheets.current;
      final n = current == null ? 0 : sheets.floorFor(current.id, levelCount);
      label = 'Riser · ${_riserSpanLabel(n, levelCount)}';
      keyHint = 'E';
      swatch = serviceColor(drawing.service);
      done = () => ref
          .read(networkControllerProvider.notifier)
          .setTool(DrawTool.select);
    } else if (measure) {
      label = 'Measure';
      keyHint = 'M';
      done = () => ref.read(measureModeProvider.notifier).set(false);
    } else if (tank) {
      label = 'Tank';
      keyHint = 'K';
      done = () => ref.read(tankModeProvider.notifier).set(false);
    } else if (room) {
      label = 'Room';
      keyHint = 'B';
      done = () => ref.read(roomModeProvider.notifier).set(false);
    } else if (refLine) {
      label = 'Ref line';
      done = () => ref.read(refLineModeProvider.notifier).set(false);
    } else if (trimArmed) {
      label = context.strings(StringKey.trimExtendArmedHint);
      done = () => ref.read(trimExtendArmedProvider.notifier).disarm();
    } else if (brush != null) {
      // The brush hint already ends '· Esc exits' — no second Esc cue.
      label = context.strings.format(StringKey.matchPropertiesArmedHint,
          {'service': serviceLabel(brush.service)});
      escHint = false;
      swatch = serviceColor(brush.service);
      done = () => ref.read(matchPropertiesArmedProvider.notifier).disarm();
    } else if (cmd != null) {
      label = basePointModeLabel(cmd);
      keyHint = basePointKey(cmd.kind);
      freeAngle = !cmd.pickingBase && cmd.kind != BasePointCommandKind.rotate;
      done = () => ref.read(basePointCommandProvider.notifier).cancel();
    }
    if (label == null) return const SizedBox.shrink();

    final colors = context.colors;
    final type = context.type;
    return GlassSurface(
      borderRadius: MechXRadii.control,
      blurSigma: MechXGlass.blurSigmaLight,
      shadow: MechXShadow.card,
      child: Padding(
        padding: const EdgeInsets.symmetric(
            horizontal: MechXSpacing.sm + 2, vertical: MechXSpacing.xs),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (swatch != null) ...[
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: swatch,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
              const SizedBox(width: MechXSpacing.xs + 2),
            ],
            Text(label,
                style: type.caption.copyWith(
                    color: colors.textPrimary, fontWeight: FontWeight.w600)),
            if (keyHint != null) ...[
              const SizedBox(width: MechXSpacing.xs + 2),
              _KeyCap(keyHint),
            ],
            if (freeAngle) ...[
              const SizedBox(width: MechXSpacing.xs + 2),
              Text('Shift: free angle',
                  style: type.micro.copyWith(color: colors.textMuted)),
            ],
            if (escHint) ...[
              const SizedBox(width: MechXSpacing.xs + 2),
              Text('Esc', style: type.micro.copyWith(color: colors.textMuted)),
            ],
            const SizedBox(width: MechXSpacing.sm),
            Container(width: 1, height: 16, color: colors.border),
            const SizedBox(width: MechXSpacing.sm),
            MechXFocusRing(
              onActivated: done,
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: done,
                  child: Text('Done',
                      style: type.caption.copyWith(
                          color: colors.accent, fontWeight: FontWeight.w600)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The floor span a riser dropped on floor [n] (0-based) of a [levelCount]-floor
/// building will connect (C6) — mirrors `NetworkController.placeRiser`: up to
/// N+1, else down to N-1 on the top floor, else (single floor) a note that there
/// is nothing to span. Displayed 1-based with an ASCII arrow (Roboto lacks →).
String _riserSpanLabel(int n, int levelCount) {
  if (n + 1 < levelCount) return 'Floor ${n + 1} -> ${n + 2}';
  if (n - 1 >= 0) return 'Floor ${n + 1} -> $n';
  return 'Floor ${n + 1} · no floor to span';
}

/// A small rounded "keycap" badge echoing a single-key shortcut (C3).
class _KeyCap extends StatelessWidget {
  final String label;
  const _KeyCap(this.label);

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: colors.canvas,
        borderRadius: MechXRadii.small,
        border: Border.all(color: colors.border),
      ),
      child: Text(
        label,
        style: type.micro.copyWith(
            color: colors.textSecondary, fontWeight: FontWeight.w600),
      ),
    );
  }
}
