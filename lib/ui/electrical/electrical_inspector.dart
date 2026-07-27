/// Shared electrical EDIT overlays — the circuit inspector drawer and the
/// panel / circuit right-click context menus — extracted so BOTH the standalone
/// electrical single-line view and the unified Layout canvas drive the same
/// editing surfaces over the one [ElectricalProject].
///
/// Pure presentation: every mutation routes through the supplied
/// [ElectricalProjectController]. The control primitives live in
/// `electrical_controls.dart` (shared with the single-line view). Styled with
/// MechXTheme — no Material.
library;

import 'package:flutter/widgets.dart';
import 'package:mechx_engine/electrical/control/starter.dart' show StarterType;
import 'package:mechx_engine/electrical/enclosure.dart'
    show EnclosureResult, VentilationLabel;
import 'package:mechx_engine/electrical/geo_length.dart'
    show CircuitLengthSource;
import 'package:mechx_engine/electrical/headroom.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/panel_results.dart'
    show ElectricalCircuitResult, ElectricalPanelResult, PhaseAssignment;
import 'package:mechx_engine/report/electrical_sld_drawing.dart'
    show breakerScheduleLabel, cableLabel;
import 'package:mechx_engine/units.dart';

import '../../store/electrical_store.dart';
import '../inspector/disclosure_header.dart';
import '../strings/app_strings.dart';
import '../strings/plural.dart';
import '../theme/design_tokens.dart';
import '../theme/mechx_theme.dart';
import '../widgets/mechx_button.dart';
import 'electrical_controls.dart';
import 'electrical_format.dart'
    show fmtAmp, fmtBreaker, fmtBusbar, fmtKw, fmtNum, fmtRcdType;

/// The DRAFTING letter for a solved phase assignment — the R / S / T notation
/// every Indonesian board schedule prints (L1/L2/L3 in IEC terms), so the
/// inspector names a way's line exactly as the schedule and the canvas rails do.
String phaseLetterFor(PhaseAssignment p) => switch (p) {
      PhaseAssignment.l1 => 'R',
      PhaseAssignment.l2 => 'S',
      PhaseAssignment.l3 => 'T',
      PhaseAssignment.threePhase => '3ph',
    };

/// The same R / S / T notation for a user-PINNED line ([PhaseLine]).
String phaseLineLetter(PhaseLine p) => switch (p) {
      PhaseLine.l1 => 'R',
      PhaseLine.l2 => 'S',
      PhaseLine.l3 => 'T',
    };

/// Identifies a circuit being edited / menu'd (panel + circuit id).
class ElectricalEditTarget {
  final String panelId;
  final String circuitId;
  const ElectricalEditTarget(this.panelId, this.circuitId);
}

/// Identifies a panel right-click menu.
class ElectricalPanelMenuTarget {
  final String panelId;
  const ElectricalPanelMenuTarget(this.panelId);
}

/// The ONE feeder-source chooser row list, shared by the panel context menu
/// (rendered as a second menu page) and the panel inspector (rendered inline as
/// an [ElectricalChooserCard]) — so the two entry points can never offer
/// different sources or mark a different row as current.
///
/// The board already feeding this one (matched on its designation, the only
/// signal the host passes) is marked '(current)' and INERT: picking it would be
/// a no-op re-parent onto the same source.
List<ElectricalMenuAction> feedChooserItems({
  required List<({String id, String label})> candidates,
  required String? currentLabel,
  required void Function(String fromPanelId) onPick,
}) =>
    [
      for (final c in candidates)
        if (currentLabel != null && c.label == currentLabel)
          ElectricalMenuAction('${c.label} (current)', () {}, selected: true)
        else
          ElectricalMenuAction(c.label, () => onPick(c.id)),
    ];

// ── Context menus ─────────────────────────────────────────────────────────────

/// Circuit right-click menu: Edit / Duplicate / Remove from layout / Delete.
class ElectricalCircuitMenu extends StatelessWidget {
  final ElectricalEditTarget target;
  final ElectricalProjectController controller;
  final VoidCallback onEdit;
  final VoidCallback onDone;

  /// True when this way's LOAD is placed on the calibrated layout
  /// (`ElectricalCircuit.loadPos != null`) — the host knows the circuit, so it
  /// passes the flag rather than the menu re-looking it up. Additive.
  final bool hasLoadPos;

  /// Un-place the load (host calls `setLoadPos(panelId, circuitId, null)`),
  /// handing the run length back to the manual field. Null ⇒ no row.
  final VoidCallback? onUnplace;

  const ElectricalCircuitMenu({
    super.key,
    required this.target,
    required this.controller,
    required this.onEdit,
    required this.onDone,
    this.hasLoadPos = false,
    this.onUnplace,
  });

  @override
  Widget build(BuildContext context) {
    return ElectricalMenu(
      items: [
        ElectricalMenuAction(
            context.strings(StringKey.electricalMenuEdit), onEdit),
        ElectricalMenuAction(context.strings(StringKey.electricalMenuDuplicate),
            () {
          controller.duplicateCircuit(target.panelId, target.circuitId);
          onDone();
        }),
        // Only offered for a way that IS placed — un-placing an unplaced load
        // would be a no-op row that lies about the model.
        if (hasLoadPos && onUnplace != null)
          ElectricalMenuAction('Remove from layout', () {
            onUnplace!();
            onDone();
          }),
        ElectricalMenuAction(context.strings(StringKey.electricalMenuDelete),
            () {
          controller.deleteCircuit(target.panelId, target.circuitId);
          onDone();
        }, danger: true),
      ],
    );
  }
}

/// Panel right-click menu: properties / open / essential / critical / submeter /
/// disconnect / delete. Mirrors the electrical single-line canvas's panel menu.
class ElectricalPanelMenu extends StatefulWidget {
  final ElectricalPanel panel;
  final ElectricalProjectController controller;
  final VoidCallback onProperties;
  final VoidCallback onOpen;
  final VoidCallback onDone;

  /// Boards this panel could be fed FROM — the host filters out itself and any
  /// candidate that would form a cycle (`feederRefusalReason`). Empty ⇒ no
  /// "Feed from…" row (nothing to choose).
  final List<({String id, String label})> feedCandidates;

  /// Re-parent this board onto the chosen source (host calls
  /// `connectFeeder(fromPanelId, panel.id)`). Null ⇒ no "Feed from…" row.
  final void Function(String fromPanelId)? onFeedFrom;

  /// Pin every way on this board to the line the last solve gave it (host calls
  /// `pinPanelPhases`). Null ⇒ no "Pin phases" row.
  final VoidCallback? onPinPhases;

  /// Designation of the board currently feeding this one — marks that row
  /// '(current)' + inert in the chooser. Null ⇒ nothing is marked.
  final String? fedFromLabel;

  const ElectricalPanelMenu({
    super.key,
    required this.panel,
    required this.controller,
    required this.onProperties,
    required this.onOpen,
    required this.onDone,
    this.feedCandidates = const [],
    this.onFeedFrom,
    this.onPinPhases,
    this.fedFromLabel,
  });

  @override
  State<ElectricalPanelMenu> createState() => _ElectricalPanelMenuState();
}

class _ElectricalPanelMenuState extends State<ElectricalPanelMenu> {
  /// True while the menu is showing the feeder-source chooser in place of its
  /// normal action list (a second PAGE of the same menu, so no second overlay
  /// has to be anchored).
  bool _feedChooser = false;

  bool get _canChooseFeed =>
      widget.onFeedFrom != null && widget.feedCandidates.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final panel = widget.panel;
    final controller = widget.controller;
    final onDone = widget.onDone;

    if (_feedChooser) {
      return ElectricalMenu(
        items: [
          ElectricalMenuAction(
            'Back',
            () => setState(() => _feedChooser = false),
            muted: true,
          ),
          ...feedChooserItems(
            candidates: widget.feedCandidates,
            currentLabel: widget.fedFromLabel,
            onPick: (id) {
              widget.onFeedFrom!(id);
              onDone();
            },
          ),
        ],
      );
    }

    return ElectricalMenu(
      items: [
        ElectricalMenuAction(
            context.strings(StringKey.electricalPanelProperties),
            widget.onProperties),
        ElectricalMenuAction(
            context.strings(StringKey.electricalMenuOpenPanel), widget.onOpen),
        ElectricalMenuAction(
          context.strings(panel.essential
              ? StringKey.electricalMenuUnmarkEssential
              : StringKey.electricalMenuMarkEssential),
          () {
            controller.setPanelEssential(panel.id, !panel.essential);
            onDone();
          },
        ),
        ElectricalMenuAction(
          context.strings(panel.upsBacked
              ? StringKey.electricalMenuUnmarkCritical
              : StringKey.electricalMenuMarkCritical),
          () {
            controller.setPanelUpsBacked(panel.id, !panel.upsBacked);
            onDone();
          },
        ),
        ElectricalMenuAction(
            context.strings(panel.submeter
                ? StringKey.electricalMenuRemoveSubmeter
                : StringKey.electricalMenuAddSubmeter), () {
          controller.setPanelSubmeter(panel.id, !panel.submeter);
          onDone();
        }),
        // Duplicate the whole board (fresh ids, undoable — I5).
        ElectricalMenuAction(
            context.strings(StringKey.electricalMenuDuplicatePanel), () {
          controller.duplicatePanel(panel.id);
          onDone();
        }),
        // Re-parent the board onto a different source — sits directly above
        // Disconnect, the two feeder actions together.
        if (_canChooseFeed)
          ElectricalMenuAction(
            'Feed from…',
            () => setState(() => _feedChooser = true),
          ),
        if (widget.onPinPhases != null)
          ElectricalMenuAction('Pin phases', () {
            widget.onPinPhases!();
            onDone();
          }),
        if (panel.fedByCircuitId != null)
          ElectricalMenuAction(
              context.strings(StringKey.electricalMenuDisconnectFeeder), () {
            controller.disconnectFeeder(panel.id);
            onDone();
          }),
        ElectricalMenuAction(
            context.strings(StringKey.electricalMenuDeletePanel), () {
          controller.deletePanel(panel.id);
          onDone();
        }, danger: true),
      ],
    );
  }
}

// ── Circuit inspector (the Wave-4 drawer) ───────────────────────────────────

class ElectricalCircuitInspector extends StatelessWidget {
  final ElectricalPanel panel;
  final ElectricalCircuit circuit;
  final ElectricalProjectController controller;
  final VoidCallback onClose;

  /// When true the editor lays out INLINE inside the shared collapsible
  /// inspector column (C4): transparent (it floats on the column's Liquid-Glass
  /// surface), full column width, no slide-in — the standalone electrical
  /// workspace's selection-first idiom. When false (the default) it is the
  /// 340-px floating right-drawer the Layout-canvas electrical layer still uses.
  final bool inline;

  /// The way's SOLVED result (H2/H3 — the same breaker/RCD figures the board
  /// schedule prints), when the caller can resolve one. Null while the network
  /// hasn't solved yet, or for a circuit the current result doesn't carry — the
  /// protection line is simply omitted then (nothing fabricated).
  final ElectricalCircuitResult? circuitResult;

  /// The panel's resolved breaking-capacity (Icu, kA) — H3, the SAME figure
  /// `buildElectricalPanelDetail`/the board schedule show for this board's
  /// devices (the fault study's chosen rating; see `breakerIcuKaByPanel`).
  /// Null ⇒ no Icu suffix (never fabricated).
  final double? breakerIcuKa;

  /// WHICH basis produced the length actually in force — `geo` when the panel
  /// and this way's load are both placed on a calibrated sheet (§10
  /// geometry-is-truth), `manual` when the typed [ElectricalCircuit.length]
  /// governs. Null ⇒ the host hasn't resolved it, so no length row + the manual
  /// field stays editable exactly as before.
  final CircuitLengthSource? lengthSource;

  /// The length [lengthSource] resolved to. Null ⇒ fall back to the circuit's
  /// own typed length (never a fabricated figure).
  final Length? effectiveLength;

  /// Where this way's LOAD sits, in words (e.g. 'Level 2 · Denah lantai 2') —
  /// the host resolves the sheet/floor names. Null ⇒ a bare 'Placed'.
  final String? placementLabel;

  /// Un-place the load (host calls `setLoadPos(panelId, circuitId, null)`) —
  /// hands the run length back to the manual field. Null ⇒ no action offered.
  final VoidCallback? onUnplace;

  /// The BOARD's electrical system, when the host resolves it independently of
  /// [panel] (e.g. a projection that already knows the supply). Null ⇒ read
  /// `panel.system`, so the phase-pin picker works with no host wiring.
  final ElectricalSystem? panelSystem;

  const ElectricalCircuitInspector({
    super.key,
    required this.panel,
    required this.circuit,
    required this.controller,
    required this.onClose,
    this.inline = false,
    this.circuitResult,
    this.breakerIcuKa,
    this.lengthSource,
    this.effectiveLength,
    this.placementLabel,
    this.onUnplace,
    this.panelSystem,
  });

  static const _cableTypes = <String?>[
    null,
    'NYY',
    'NYM',
    'NYA',
    'NYAF',
    'FRC',
  ];

  bool get _isMotor =>
      circuit.loadKind == LoadKind.motor || circuit.loadKind == LoadKind.pump;

  /// True when the length in force comes from the calibrated layout — the
  /// manual field is then READ-ONLY (editing it would be a lie: the geo length
  /// wins in `resolveCircuitLengthDetailed`).
  bool get _lengthFromLayout => lengthSource == CircuitLengthSource.geo;

  /// The length actually in force (geo or manual), falling back to the model's
  /// own typed length when the host resolved none.
  Length get _lengthInForce => effectiveLength ?? circuit.length;

  /// True only where the way is KNOWN to be single-phase: an explicit 1-phase
  /// input, or a solve that put it on ONE line. An unset `phases` with no
  /// solved result is UNKNOWN — treated as "not known to be single-phase", so
  /// the pin is never offered on a way that may well be three-phase.
  bool get _circuitIsSinglePhase =>
      circuit.phases == 1 ||
      (circuit.phases == null &&
          circuitResult != null &&
          !circuitResult!.threePhase);

  /// The phase-PIN picker only makes sense for a single-phase way on a
  /// three-phase board — a 3-phase way already spans every line, and a
  /// single-phase board has no other line to move to.
  bool get _showPhasePin =>
      (panelSystem ?? panel.system).isThreePhase && _circuitIsSinglePhase;

  /// The human drafting label for a [StarterType] in the picker — the same
  /// control terms the board-schedule token uses (DOL / VFD / star-delta …).
  /// Drafting acronyms are identical in EN/ID, so (like the cable-family
  /// options) only the "None" entry is localized.
  static String _starterLabel(StarterType s) => switch (s) {
        StarterType.dol => 'DOL',
        StarterType.starDelta => 'Star-delta',
        StarterType.reversing => 'Reversing',
        StarterType.softStarter => 'Soft-start',
        StarterType.vfd => 'VFD',
        StarterType.ats => 'ATS',
        StarterType.pump => 'Pump',
      };

  /// The way's protection notation, e.g. `MCB 16A 1ph · Icu 6kA · RCD 30mA A` —
  /// the SAME breaker/Icu/RCD tokens `buildElectricalPanelDetail` prints on the
  /// board-schedule DEVICE cell for this circuit (H2 RCD, H3 kA), read off the
  /// already-solved [circuitResult] rather than recomputed here. Null when the
  /// caller has no solved result for this circuit (nothing fabricated).
  String? _protectionLine() {
    final c = circuitResult;
    if (c == null) return null;
    final poles = c.threePhase ? 3 : 1;
    final ka = breakerIcuKa;
    final icu = (ka != null && ka > 0) ? ' · Icu ${fmtNum(ka)}kA' : '';
    final rcd = c.rcd.required
        ? ' · RCD ${c.rcd.ratingMa}mA'
            '${c.rcd.type != null ? ' ${fmtRcdType(c.rcd.type!)}' : ''}'
        : '';
    return '${breakerScheduleLabel(c.breaker, poles)}$icu$rcd';
  }

  /// The read-only RESULT rows for this way — Ib, protection, cable, voltage
  /// drop (own + cumulative), the R/S/T line, and the effective length WITH its
  /// basis. Every row is individually data-gated: with no solved result and no
  /// resolved length the list is EMPTY and [ElectricalResultBlock] renders
  /// nothing, so an un-wired host is byte-identical to before.
  List<Widget> _resultRows(BuildContext context) {
    final colors = context.colors;
    final rows = <Widget>[];
    final c = circuitResult;
    if (c != null) {
      rows.add(ElectricalResultRow(
        label: 'Ib',
        value: '${fmtNum(c.designCurrent.amperes)} A',
      ));
      final protection = _protectionLine();
      if (protection != null) {
        rows.add(ElectricalResultRow(
          label: context.strings(StringKey.electricalFieldProtection),
          value: protection,
        ));
      }
      // The SAME `family cores×csa` notation the board schedule's PENGHANTAR
      // cell prints (ASCII `mm2`), read off the solved cable.
      rows.add(ElectricalResultRow(
        label: 'Cable',
        value: '${cableLabel(circuit, c.cable.csaMm2, c.threePhase)} mm2',
      ));
      final vd = c.voltageDrop;
      rows.add(ElectricalResultRow(
        label: 'Vdrop',
        value: '${vd.dropPercent.toStringAsFixed(1)} %'
            ' · cum ${c.cumulativeDropPercent.toStringAsFixed(1)} %'
            ' (max ${fmtNum(vd.limitPercent)} %)',
        valueColor: vd.withinLimit ? null : colors.danger,
      ));
      rows.add(ElectricalResultRow(
        label: 'Phase',
        value: phaseLetterFor(c.phase),
      ));
    }
    if (lengthSource != null) {
      rows.add(ElectricalResultRow(
        label: 'Length',
        value: '${fmtNum(_lengthInForce.meters)} m'
            ' — ${_lengthFromLayout ? 'from layout' : 'manual'}',
      ));
    }
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;

    final inner = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                MechXSpacing.md,
                MechXSpacing.md,
                MechXSpacing.sm,
                MechXSpacing.sm,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      context.strings(StringKey.electricalCircuitEditTitle),
                      style: type.title.copyWith(color: colors.textPrimary),
                    ),
                  ),
                  MechXButton(
                    label: context.strings(StringKey.electricalClose),
                    tertiary: true,
                    onPressed: onClose,
                  ),
                ],
              ),
            ),
            Container(height: 1, color: colors.border),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(MechXSpacing.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // H2/H3 — the READ-ONLY block of SOLVED figures leading the
                    // editable fields: Ib, the way's protection (breaker +
                    // breaking-capacity + RCD — the SAME tokens the board
                    // schedule prints for this row), its cable, voltage drop
                    // (own + cumulative, coloured when over the limit), the
                    // R/S/T line and the effective length with its basis. So an
                    // engineer editing a way sees the verdict without switching
                    // back to the schedule view. Renders NOTHING (not even the
                    // heading) until the host resolves a result.
                    ElectricalResultBlock(
                      title: 'Result',
                      rows: _resultRows(context),
                    ),
                    ElectricalField(
                      label: context.strings(StringKey.electricalFieldName),
                      child: ElectricalTextInput(
                        value: circuit.name,
                        onChanged: (v) => controller.setCircuit(
                          panel.id,
                          circuit.id,
                          name: v,
                        ),
                      ),
                    ),
                    ElectricalField(
                      label: context.strings(StringKey.electricalFieldLoadKind),
                      child: ElectricalEnumPicker<LoadKind>(
                        value: circuit.loadKind,
                        options: const [
                          LoadKind.general,
                          LoadKind.lighting,
                          LoadKind.socket,
                          LoadKind.hvac,
                          LoadKind.motor,
                          LoadKind.pump,
                          LoadKind.heating,
                          LoadKind.ups,
                          LoadKind.evCharger,
                          LoadKind.welding,
                          // Power-factor correction is a real board load kind
                          // (its own cos φ / demand defaults); only `feeder`
                          // stays out of the picker — a way becomes a feeder by
                          // feeding a panel, never by being labelled one.
                          LoadKind.capacitor,
                          LoadKind.spare,
                        ],
                        label: (k) => loadDefaults[k]?.label ?? k.name,
                        onChanged: (k) => controller.setCircuit(
                          panel.id,
                          circuit.id,
                          loadKind: k,
                        ),
                      ),
                    ),
                    if (_isMotor)
                      ElectricalField(
                        label:
                            context.strings(StringKey.electricalFieldMotorPower),
                        child: ElectricalNumInput(
                          value: circuit.motorKw ?? 0,
                          onChanged: (v) => controller.setCircuit(
                            panel.id,
                            circuit.id,
                            motorKw: v,
                          ),
                        ),
                      )
                    else
                      ElectricalField(
                        label: context.strings(StringKey.electricalFieldLoadW),
                        child: ElectricalNumInput(
                          value: circuit.loadW,
                          onChanged: (v) => controller.setCircuit(
                            panel.id,
                            circuit.id,
                            loadW: v,
                          ),
                        ),
                      ),
                    // §10 — when both ends are placed on a calibrated sheet the
                    // length comes from GEOMETRY, and the typed field can no
                    // longer change it. Greyed (never hidden) so the figure in
                    // force is still readable, with the one way back to a
                    // manual length named in the hint.
                    ElectricalField(
                      label: context.strings(StringKey.electricalFieldRunLength),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          ElectricalNumInput(
                            key: const ValueKey('circuit-run-length'),
                            value: _lengthFromLayout
                                ? _lengthInForce.meters
                                : circuit.length.meters,
                            enabled: !_lengthFromLayout,
                            onChanged: (v) => controller.setCircuit(
                              panel.id,
                              circuit.id,
                              length: Length(v),
                            ),
                          ),
                          if (_lengthFromLayout)
                            const ElectricalHint(
                                'From layout — remove from layout to edit'),
                        ],
                      ),
                    ),
                    // Where the LOAD sits on the calibrated plan — the input
                    // that decides whether the length above is geometry or a
                    // typed figure, so it reads directly beneath it. Host-gated
                    // (a caller that wires neither the label nor the un-place
                    // action renders exactly the pre-existing form).
                    if (placementLabel != null || onUnplace != null)
                      ElectricalField(
                        label: 'Placement',
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              circuit.loadPos != null
                                  ? (placementLabel != null
                                      ? 'Placed — $placementLabel'
                                      : 'Placed')
                                  : 'Not placed — drag it from the Layout tray',
                              style: type.caption
                                  .copyWith(color: colors.textSecondary),
                            ),
                            if (circuit.loadPos != null &&
                                onUnplace != null) ...[
                              const SizedBox(height: MechXSpacing.xs),
                              Align(
                                alignment: Alignment.centerLeft,
                                child: MechXButton(
                                  label: 'Remove from layout',
                                  onPressed: onUnplace,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ElectricalField(
                      label:
                          context.strings(StringKey.electricalFieldSupplyPhase),
                      child: ElectricalEnumPicker<int>(
                        value: circuit.phases ?? 0,
                        options: const [0, 1, 3],
                        label: (p) => switch (p) {
                          1 => context.strings(StringKey.electricalPhase1),
                          3 => context.strings(StringKey.electricalPhase3),
                          _ => context.strings(StringKey.electricalPhaseAuto),
                        },
                        onChanged: (p) => p == 0
                            ? controller.setCircuit(
                                panel.id,
                                circuit.id,
                                clearPhases: true,
                              )
                            : controller.setCircuit(
                                panel.id,
                                circuit.id,
                                phases: p,
                              ),
                      ),
                    ),
                    // Pin the way to a LINE — the durable counterpart to the
                    // solver's auto-balancing, so a board already labelled on
                    // site keeps its R/S/T. Only meaningful for a single-phase
                    // way on a three-phase board.
                    if (_showPhasePin)
                      ElectricalField(
                        label: 'Pin phase',
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            ElectricalEnumPicker<PhaseLine?>(
                              value: circuit.phaseOverride,
                              options: const [
                                null,
                                PhaseLine.l1,
                                PhaseLine.l2,
                                PhaseLine.l3,
                              ],
                              label: (p) => p == null
                                  ? context
                                      .strings(StringKey.electricalPhaseAuto)
                                  : phaseLineLetter(p),
                              onChanged: (p) => p == null
                                  ? controller.setCircuit(
                                      panel.id,
                                      circuit.id,
                                      clearPhaseOverride: true,
                                    )
                                  : controller.setCircuit(
                                      panel.id,
                                      circuit.id,
                                      phaseOverride: p,
                                    ),
                            ),
                            const ElectricalHint(
                                'Pinned ways are excluded from auto-balancing'),
                          ],
                        ),
                      ),
                    ElectricalToggleRow(
                      label: context.strings(StringKey.electricalToggleLighting),
                      value: circuit.isLighting,
                      onChanged: (v) => controller.setCircuit(
                        panel.id,
                        circuit.id,
                        isLighting: v,
                      ),
                    ),
                    ElectricalToggleRow(
                      label:
                          context.strings(StringKey.electricalToggleLifeSafety),
                      value: circuit.lifeSafety,
                      onChanged: (v) => controller.setCircuit(
                        panel.id,
                        circuit.id,
                        lifeSafety: v,
                      ),
                    ),
                    // E4 — expert electrical parameters (power factor, demand
                    // factor, cable class) are demoted under a collapsed
                    // "Advanced" disclosure so the circuit's IDENTITY (name +
                    // load kind + magnitude) and its routine placement lead.
                    // Transient expansion state lives in
                    // sectionVisibilityProvider (not persisted to `.mechx`).
                    DisclosureSection(
                      name: 'Advanced',
                      defaultExpanded: false,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          ElectricalField(
                            label:
                                context.strings(StringKey.electricalFieldCosPhi),
                            // C6: a 0-1 ratio field — the honest range lives in
                            // the label (StringKey carries '(0-1)'), and an
                            // out-of-range commit is REJECTED (field-error
                            // idiom below the field), not silently clamped.
                            child: ElectricalNumInput(
                              value: circuit.cosPhi,
                              min: 0.0,
                              max: 1.0,
                              onChanged: (v) => controller.setCircuit(
                                panel.id,
                                circuit.id,
                                cosPhi: v,
                              ),
                            ),
                          ),
                          ElectricalField(
                            label: context
                                .strings(StringKey.electricalFieldDemandFactor),
                            child: ElectricalNumInput(
                              value: circuit.demandFactor,
                              min: 0.0,
                              max: 1.0,
                              onChanged: (v) => controller.setCircuit(
                                panel.id,
                                circuit.id,
                                demandFactor: v,
                              ),
                            ),
                          ),
                          ElectricalField(
                            label: context
                                .strings(StringKey.electricalFieldCableType),
                            child: ElectricalEnumPicker<String?>(
                              value: circuit.cableType,
                              options: _cableTypes,
                              label: (t) =>
                                  t ??
                                  context.strings(
                                      StringKey.electricalCablePanelDefault),
                              onChanged: (t) => t == null
                                  ? controller.setCircuit(
                                      panel.id,
                                      circuit.id,
                                      clearCableType: true,
                                    )
                                  : controller.setCircuit(
                                      panel.id,
                                      circuit.id,
                                      cableType: t,
                                    ),
                            ),
                          ),
                          // The three MANUAL SIZING overrides. Each is empty
                          // ("Auto") until the engineer sets one, marked
                          // '(set)' + cleared with the shared override idiom
                          // (the mechanical size/material overrides speak the
                          // same language) — so a hand-forced device/conductor
                          // can never look like an engine-sized one.
                          ElectricalOverrideField(
                            label: 'Breaker override (A)',
                            isSet: circuit.breakerOverrideA != null,
                            onClear: () => controller.setCircuit(
                              panel.id,
                              circuit.id,
                              clearBreakerOverrideA: true,
                            ),
                            child: ElectricalOptionalNumInput(
                              key: const ValueKey('circuit-breaker-override'),
                              value: circuit.breakerOverrideA?.amperes,
                              onChanged: (v) => v == null
                                  ? controller.setCircuit(
                                      panel.id,
                                      circuit.id,
                                      clearBreakerOverrideA: true,
                                    )
                                  : controller.setCircuit(
                                      panel.id,
                                      circuit.id,
                                      breakerOverrideA: Current(v),
                                    ),
                            ),
                          ),
                          ElectricalOverrideField(
                            label: 'Min cable (mm2)',
                            isSet: circuit.cableOverrideMm2 != null,
                            onClear: () => controller.setCircuit(
                              panel.id,
                              circuit.id,
                              clearCableOverrideMm2: true,
                            ),
                            child: ElectricalOptionalNumInput(
                              key: const ValueKey('circuit-cable-override'),
                              value: circuit.cableOverrideMm2,
                              onChanged: (v) => v == null
                                  ? controller.setCircuit(
                                      panel.id,
                                      circuit.id,
                                      clearCableOverrideMm2: true,
                                    )
                                  : controller.setCircuit(
                                      panel.id,
                                      circuit.id,
                                      cableOverrideMm2: v,
                                    ),
                            ),
                          ),
                          ElectricalOverrideField(
                            label: 'Grouping count',
                            isSet: circuit.groupingCountOverride != null,
                            onClear: () => controller.setCircuit(
                              panel.id,
                              circuit.id,
                              clearGroupingCountOverride: true,
                            ),
                            child: ElectricalOptionalNumInput(
                              key: const ValueKey('circuit-grouping-override'),
                              value:
                                  circuit.groupingCountOverride?.toDouble(),
                              integer: true,
                              onChanged: (v) => v == null
                                  ? controller.setCircuit(
                                      panel.id,
                                      circuit.id,
                                      clearGroupingCountOverride: true,
                                    )
                                  : controller.setCircuit(
                                      panel.id,
                                      circuit.id,
                                      groupingCountOverride: v.round(),
                                    ),
                            ),
                          ),
                          // C5 — the motor-control / STARTER type. Gated to
                          // motor/pump kinds (like the motor-power field above),
                          // this is the only hand-set path for
                          // ElectricalCircuit.starterType, which the board
                          // schedule drafter appends as a control token
                          // (DOL / VFD / star-delta) on the way's DEVICE cell.
                          // "None" clears it back to a bare breaker cell.
                          if (_isMotor)
                            ElectricalField(
                              label: context
                                  .strings(StringKey.electricalFieldStarter),
                              child: ElectricalEnumPicker<StarterType?>(
                                value: circuit.starterType,
                                options: const [
                                  null,
                                  StarterType.dol,
                                  StarterType.starDelta,
                                  StarterType.reversing,
                                  StarterType.softStarter,
                                  StarterType.vfd,
                                  StarterType.ats,
                                ],
                                label: (s) => s == null
                                    ? context.strings(
                                        StringKey.electricalStarterNone)
                                    : _starterLabel(s),
                                onChanged: (s) => s == null
                                    ? controller.setCircuit(
                                        panel.id,
                                        circuit.id,
                                        clearStarterType: true,
                                      )
                                    : controller.setCircuit(
                                        panel.id,
                                        circuit.id,
                                        starterType: s,
                                      ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );

    if (inline) {
      // Transparent, full-width, no slide-in — floats on the shared inspector
      // column's Liquid-Glass surface (the selection-first idiom, C4).
      return inner;
    }
    // The 340-px floating right-drawer with a slide-in + fade on open (and on
    // switching circuits, since the host keys this by panel/circuit), matching
    // the iOS sheet idiom — the Layout-canvas electrical layer path.
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: MechXMotion.appear,
      curve: MechXMotion.standard,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(
          offset: Offset(340 * (1 - t), 0),
          child: child,
        ),
      ),
      child: Container(
        width: 340,
        decoration: BoxDecoration(
          color: colors.surface,
          border: Border(left: BorderSide(color: colors.border)),
          boxShadow: MechXShadow.popover,
        ),
        child: inner,
      ),
    );
  }
}

// ── Panel inspector (the I3 properties drawer) ───────────────────────────────

/// The panel PROPERTIES drawer — name / tag / diversity / headroom (spare % +
/// CADANGAN spare ways) / supply flags — opened on panel double-click or the
/// 'Panel properties' context-menu row. Same 340-px right-drawer idiom as
/// [ElectricalCircuitInspector]; every edit routes through the controller's
/// undoable intents.
class ElectricalPanelInspector extends StatefulWidget {
  final ElectricalPanel panel;
  final ElectricalProjectController controller;
  final VoidCallback onClose;

  /// See [ElectricalCircuitInspector.inline] — true lays this out inline in the
  /// shared collapsible inspector column (C4); false is the 340-px drawer.
  final bool inline;

  /// The board's SOLVED result — demand / incomer / busbar / sections / phase
  /// imbalance. Null ⇒ no result rows (nothing fabricated).
  final ElectricalPanelResult? panelResult;

  /// The board's enclosure envelope from the advanced study
  /// (`AdvancedStudy.enclosure[panelId]`). Null ⇒ no enclosure row.
  final EnclosureResult? enclosureResult;

  /// Designation (tag, else name) of the board feeding this one. Null ⇒ the
  /// board sits on the utility supply.
  final String? fedFromLabel;

  /// Boards this one could be fed FROM — the host filters itself out and drops
  /// any candidate `feederRefusalReason` refuses (a cycle). Empty ⇒ no chooser.
  final List<({String id, String label})> feedCandidates;

  /// Re-parent onto the chosen source (host calls `connectFeeder`).
  final void Function(String fromPanelId)? onFeedFrom;

  /// Drop the incoming feeder (host calls `disconnectFeeder`).
  final VoidCallback? onDisconnectFeeder;

  /// Populate an EMPTY board from a preset (host calls `applyPanelTemplate`).
  final VoidCallback? onApplyTemplate;

  /// Pin every way to the line the last solve gave it (host calls
  /// `pinPanelPhases`).
  final VoidCallback? onPinPhases;

  const ElectricalPanelInspector({
    super.key,
    required this.panel,
    required this.controller,
    required this.onClose,
    this.inline = false,
    this.panelResult,
    this.enclosureResult,
    this.fedFromLabel,
    this.feedCandidates = const [],
    this.onFeedFrom,
    this.onDisconnectFeeder,
    this.onApplyTemplate,
    this.onPinPhases,
  });

  @override
  State<ElectricalPanelInspector> createState() =>
      _ElectricalPanelInspectorState();
}

class _ElectricalPanelInspectorState extends State<ElectricalPanelInspector> {
  /// True while the inline feeder-source chooser is disclosed (transient UI
  /// state — never persisted, and reset whenever the drawer is re-keyed).
  bool _feedChooser = false;

  bool get _canChooseFeed =>
      widget.onFeedFrom != null && widget.feedCandidates.isNotEmpty;

  /// The read-only RESULT rows for this board. Individually data-gated — with
  /// neither a solved result nor an enclosure the list is EMPTY and the block
  /// renders nothing (an un-wired host is byte-identical to before).
  List<Widget> _resultRows() {
    final rows = <Widget>[];
    final r = widget.panelResult;
    if (r != null) {
      rows.add(ElectricalResultRow(
        label: 'Demand',
        value: '${fmtAmp(r.demandCurrent.amperes)} · ${fmtKw(r.demandW)}',
      ));
      rows.add(ElectricalResultRow(
        label: 'Incomer',
        value: '${fmtBreaker(r.incomer.breaker)} ${r.incomer.poles}P',
      ));
      final withstand = r.busbar.withstand;
      rows.add(ElectricalResultRow(
        label: 'Busbar',
        value: fmtBusbar(r.busbar) +
            (withstand != null ? ' · Icw ${fmtNum(withstand.icwKa)} kA' : ''),
      ));
      rows.add(ElectricalResultRow(
        label: 'Sections',
        value: '${r.busbarSections.length}',
      ));
      rows.add(ElectricalResultRow(
        label: 'Imbalance',
        value: '${r.phaseBalance.imbalancePercent.toStringAsFixed(1)} %',
      ));
    }
    final e = widget.enclosureResult;
    if (e != null) {
      rows.add(ElectricalResultRow(
        label: 'Enclosure',
        // ASCII 'x' — this reads beside the drawing notation, never a glyph
        // the bundled face lacks.
        value: '${fmtNum(e.widthMm)}x${fmtNum(e.heightMm)}x${fmtNum(e.depthMm)}'
            ' mm · ${e.modules}M/${pluralCount(e.rows, 'row', 'rows')}'
            ' · ${e.ventilation.label}',
      ));
    }
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.type;
    final panel = widget.panel;
    final controller = widget.controller;
    final headroom = panel.headroom ?? HeadroomSpec.none;

    final inner = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                MechXSpacing.md,
                MechXSpacing.md,
                MechXSpacing.sm,
                MechXSpacing.sm,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      context.strings(StringKey.electricalPanelProperties),
                      style: type.title.copyWith(color: colors.textPrimary),
                    ),
                  ),
                  MechXButton(
                    label: context.strings(StringKey.electricalClose),
                    tertiary: true,
                    onPressed: widget.onClose,
                  ),
                ],
              ),
            ),
            Container(height: 1, color: colors.border),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(MechXSpacing.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // The board's SOLVED envelope leads its editable identity —
                    // what the incomer/bus/enclosure actually came out as. Data-
                    // gated: renders nothing until the host resolves a result.
                    ElectricalResultBlock(
                      title: 'Result',
                      rows: _resultRows(),
                    ),
                    ElectricalField(
                      label: context.strings(StringKey.electricalFieldName),
                      child: ElectricalTextInput(
                        value: panel.name,
                        onChanged: (v) => controller.renamePanel(panel.id, v),
                      ),
                    ),
                    ElectricalField(
                      label: context.strings(StringKey.electricalFieldTag),
                      child: ElectricalTextInput(
                        value: panel.tag ?? '',
                        onChanged: (v) => controller.setPanelTag(panel.id, v),
                      ),
                    ),
                    // G7 — the board's electrical system (and its paired nominal
                    // voltage) is now editable, so a 1-phase stub board (the
                    // drop-a-floating-load flow) can become the 3-phase sub-board
                    // a design needs without delete-and-recreate (which would
                    // lose every way). EN literal — Wave 5 owns i18n.
                    ElectricalField(
                      label: 'Electrical system',
                      child: ElectricalEnumPicker<ElectricalSystem>(
                        value: panel.system,
                        options: ElectricalSystem.values,
                        label: (s) => s == ElectricalSystem.singlePhase
                            ? '1-phase (220 V)'
                            : '3-phase (400 V)',
                        onChanged: (s) =>
                            controller.setPanelSystem(panel.id, s),
                      ),
                    ),
                    // WHERE THE BOARD IS FED FROM — its place in the
                    // distribution tree, stated in words plus the two actions
                    // that change it (re-parent / drop the feeder). A board with
                    // no incoming feeder honestly reads as utility-fed. Shown
                    // once the host wires ANY of the three (label / chooser /
                    // disconnect); a caller that wires none renders exactly the
                    // pre-existing form.
                    if (widget.fedFromLabel != null ||
                        _canChooseFeed ||
                        widget.onDisconnectFeeder != null)
                      ElectricalField(
                        label: 'Fed from',
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              widget.fedFromLabel ?? 'Utility supply',
                              style:
                                  type.body.copyWith(color: colors.textPrimary),
                            ),
                            if (_canChooseFeed ||
                                (widget.onDisconnectFeeder != null &&
                                    panel.fedByCircuitId != null)) ...[
                              const SizedBox(height: MechXSpacing.xs),
                              Wrap(
                                spacing: MechXSpacing.xs,
                                runSpacing: MechXSpacing.xs,
                                children: [
                                  if (_canChooseFeed)
                                    MechXButton(
                                      label: 'Feed from…',
                                      onPressed: () => setState(
                                          () => _feedChooser = !_feedChooser),
                                    ),
                                  if (widget.onDisconnectFeeder != null &&
                                      panel.fedByCircuitId != null)
                                    MechXButton(
                                      label: context.strings(StringKey
                                          .electricalMenuDisconnectFeeder),
                                      onPressed: widget.onDisconnectFeeder,
                                    ),
                                ],
                              ),
                            ],
                            if (_feedChooser && _canChooseFeed) ...[
                              const SizedBox(height: MechXSpacing.xs),
                              ElectricalChooserCard(
                                title: 'Feed from',
                                items: feedChooserItems(
                                  candidates: widget.feedCandidates,
                                  currentLabel: widget.fedFromLabel,
                                  onPick: (id) {
                                    widget.onFeedFrom!(id);
                                    setState(() => _feedChooser = false);
                                  },
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ElectricalToggleRow(
                      label:
                          context.strings(StringKey.electricalToggleEssential),
                      value: panel.essential,
                      onChanged: (v) =>
                          controller.setPanelEssential(panel.id, v),
                    ),
                    ElectricalToggleRow(
                      label: context.strings(StringKey.electricalToggleCritical),
                      value: panel.upsBacked,
                      onChanged: (v) =>
                          controller.setPanelUpsBacked(panel.id, v),
                    ),
                    ElectricalToggleRow(
                      label: context.strings(StringKey.electricalToggleSubmeter),
                      value: panel.submeter,
                      onChanged: (v) =>
                          controller.setPanelSubmeter(panel.id, v),
                    ),
                    // Populating a board from a preset only makes sense while it
                    // is EMPTY — a template replays a canned way list, so on a
                    // populated board it would duplicate real design work.
                    if (widget.onApplyTemplate != null && panel.circuits.isEmpty)
                      Padding(
                        padding:
                            const EdgeInsets.only(bottom: MechXSpacing.md),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Align(
                              alignment: Alignment.centerLeft,
                              child: MechXButton(
                                label: 'Apply template…',
                                onPressed: widget.onApplyTemplate,
                              ),
                            ),
                            const ElectricalHint(
                                'Fill this empty board with a typical way list'),
                          ],
                        ),
                      ),
                    if (widget.onPinPhases != null)
                      Padding(
                        padding:
                            const EdgeInsets.only(bottom: MechXSpacing.md),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Align(
                              alignment: Alignment.centerLeft,
                              child: MechXButton(
                                label: 'Pin phases',
                                onPressed: widget.onPinPhases,
                              ),
                            ),
                            const ElectricalHint(
                                'Fix every way to its current R/S/T line'),
                          ],
                        ),
                      ),
                    // E4 — expert board parameters (diversity factor, spare
                    // headroom % + CADANGAN spare ways) are demoted under a
                    // collapsed "Advanced" disclosure so the board's IDENTITY
                    // (name + tag + system) and its supply classification lead.
                    // Transient expansion state (not persisted to `.mechx`).
                    DisclosureSection(
                      name: 'Advanced',
                      defaultExpanded: false,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          ElectricalField(
                            label: context
                                .strings(StringKey.electricalFieldDiversity),
                            // C6: a 0-1 ratio field, same treatment as cos phi
                            // / demand factor above — honest range in the
                            // label, out-of-range REJECTED not clamped.
                            child: ElectricalNumInput(
                              value: panel.diversityFactor,
                              min: 0.0,
                              max: 1.0,
                              onChanged: (v) =>
                                  controller.setPanelDiversity(panel.id, v),
                            ),
                          ),
                          ElectricalField(
                            label: context.strings(
                                StringKey.electricalFieldHeadroomSpare),
                            // C6: the 0-100 percent field — a '%' suffix baked
                            // onto the at-rest display so it never looks like
                            // the adjacent 0-1 ratio fields above.
                            child: ElectricalNumInput(
                              value: headroom.sparePercentage,
                              suffix: '%',
                              onChanged: (v) => controller.setPanelHeadroom(
                                panel.id,
                                HeadroomSpec(
                                  sparePercentage: v.clamp(0.0, 100.0),
                                  spareWays: headroom.spareWays,
                                ),
                              ),
                            ),
                          ),
                          ElectricalField(
                            label: context
                                .strings(StringKey.electricalFieldSpareWays),
                            child: ElectricalNumInput(
                              value: headroom.spareWays.toDouble(),
                              onChanged: (v) => controller.setPanelHeadroom(
                                panel.id,
                                HeadroomSpec(
                                  sparePercentage: headroom.sparePercentage,
                                  spareWays: v.round().clamp(0, 60),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );

    if (widget.inline) {
      return inner;
    }
    // Slide-in from the right + fade on open (host keys this by panel), the
    // same iOS sheet idiom as the circuit inspector.
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: MechXMotion.appear,
      curve: MechXMotion.standard,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(
          offset: Offset(340 * (1 - t), 0),
          child: child,
        ),
      ),
      child: Container(
        width: 340,
        decoration: BoxDecoration(
          color: colors.surface,
          border: Border(left: BorderSide(color: colors.border)),
          boxShadow: MechXShadow.popover,
        ),
        child: inner,
      ),
    );
  }
}
