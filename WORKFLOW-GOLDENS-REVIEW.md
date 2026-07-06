# WORKFLOW-GOLDENS-REVIEW.md — the two-lens ease-of-use review (2026-07-06)

**Status: PLAN OF RECORD for the next ease-of-use campaign.** A fresh, adversarially
verified review of the v1.12.0 workflow and the golden screenshots from two povs —
**a senior Apple UI/software engineer** and **a senior Indonesian MEP drafter/engineer**
— run AFTER the three prior campaigns (`UX-WORKFLOW-REVIEW.md`, `CAD-OUTPUT-UX-REVIEW.md`,
`APPLE-DESIGN-REVIEW.md`) fully landed. Its premise: those campaigns fixed what they saw;
this one asks what they never looked at, what regressed, and what still forces a
professional back into AutoCAD or Excel. The product goal ordering every priority here:
**user friendliness and ease of use first.**

**Addition (2026-07-06, same day):** the product owner sharpened the goal — the EXPORTS
must be construction-ready: a mandor (site foreman) and site engineers build from them
directly, with no AutoCAD redraw and no Excel supplement. An export-readiness audit
(Theme N: the real artifact set generated, rasterized, and reviewed by four site-lens
critics) was added ON TOP of the original review, and its 25 findings form an additional
**Wave 7 — export-ready deliverables**; Waves 1-6 stand unchanged.

## Method

- 12 scoped finder agents (6 Apple-UI scopes: first-run, canvas, inspector, riser UX,
  electrical UX, pure-screenshot visual critique; 6 MEP scopes: plan output, riser drawing
  fidelity, electrical deliverables, engineering trust, drafting velocity, project lifecycle),
  each reading the actual code AND looking at the 16 golden PNGs.
- A cross-lens dedup pass (70 raw -> 67 merged), then **every finding adversarially verified
  by an independent agent** whose default stance was refutation (checks: evidence exists;
  capability is really absent; not already landed/dispositioned by the prior campaigns;
  fix direction honours the §12 guardrails). **All 67 survived; 0 were refuted.** Verifier
  corrections (2 severity downgrades, several evidence refinements) are recorded inline.
- A completeness critic then identified three territories none of the prior campaigns ever
  covered — **performance-feel, keyboard/accessibility, Windows-desktop citizenship** — and
  a follow-up round confirmed 13 more findings there.
- One additional defect was found and verified directly by the orchestrating session (B9).
- **Export-readiness audit (Theme N):** a committed dev tool generated the REAL 13-artifact
  export set from a representative fixture; the PDFs were rasterized and four site-lens
  critics (foreman, mechanical site engineer, electrical kontraktor, document controller)
  reviewed the actual sheets. 26 raw findings, self-verified against exporter source with
  fixture artifacts excluded, merged to 25; the orchestrator independently re-verified the
  four riskiest claims (RCD contradiction, stack-vs-branch sizing, global drawing number,
  DXF layer bleed) before accepting them.

**Total: 106 verified findings — 33 high / 59 medium / 14 low** (81 from the two-lens
review, themes A–M; 25 from the export-readiness audit, Theme N). Grouped into 14 themes
and sequenced into seven implementation waves — the original six, plus Wave 7 for the
export-ready work.

## Executive summary — the six storylines

1. **The goldens themselves show defects.** The app's own regression screenshots ship
   clipped and colliding content: the riser help button eats the top-floor fan-out label
   (E1, goldens 09/10), the focused board schedule cuts off its own panel name, incomer,
   and TOTAL row (B9, golden 11), duct warning badges sit on top of size labels (B2), and
   the "uniform" heatmap washes the whole sheet — pipes or not — in warning-orange (E4).
   A golden that immortalises a defect normalises it; each of these should be a deliberate
   re-capture after the fix.
2. **The app still lies in places.** An empty state instructs users to use palette cards
   that do not exist (D1); "read-only" Auto mode commits a permanent edge on a single
   click (D3); the workflow stepper ticks Floors without the engineer ever seeing floor
   heights (A4); cancelling the template file picker still mutates the open project (A2);
   switching sheets mid-draw silently corrupts the network with a phantom node (B1); and
   the compliance verdict can read PASS while the pressure-zone check is over limit (I1).
   Honesty was the first campaign's theme; these are the leaks it missed.
3. **The drafter still redraws.** The riser diagram omits the hot-water return loop (G2)
   and treats drainage/vent/rainwater as second-class (G4); plan equipment carries no tags
   (G1) and the schedule re-invents them per export (J3); there is no plan-accurate
   electrical layout export at all (H1); RCDs — a legal requirement — are invisible on the
   very drawings that prove compliance (H2). These are the specific reasons a professional
   opens AutoCAD after using iSystem, and they are enumerable and closeable.
4. **Results exist but evidence does not.** Velocity is a code-driven sizing criterion the
   app never displays (I3); the heatmap has no absolute scale or probe, so it cannot answer
   the one question it exists for (I2); advisory acknowledgements — the mechanism that makes
   PASS reachable — record no author, time, or reason (I4). The sign-off workflow needs the
   outputs to become interrogable evidence.
5. **Three whole territories were never reviewed before.** Every drag frame re-runs the
   entire sizing + pressure-solve + BOM pipeline synchronously on the UI thread (K1) — fine
   on the demo, doom on a tower; the custom design system is only partially keyboard-capable
   (L1–L5); and the app skips Windows-native basics — no minimum window size, no remembered
   window state, no .mechx file association (M1–M4). These decide whether week-2 users stay.
6. **The issued set fails the site test — provably, on paper.** Generating and reading the
   real exports exposed what code review alone missed: the PDF encoder garbles the engine's
   own '·' separator to '?' inside cable-spec and starter cells (N1); socket RCDs appear in
   the calc report but not on the board schedule a panel is built from (N10); no sheet
   carries cable lengths, per-device kA, mounting heights, or setting-out ties (N4/N5/N8/N9);
   a drainage stack can size smaller than its branches (N17); one global drawing number
   stamps every sheet (N19); and the riser DXF puts plumbing on E-BREAKER layers (N15).
   These are the findings that decide whether the foreman builds from iSystem or from a
   redrawn AutoCAD set — they form their own dedicated Wave 7 below.

What is already excellent and must not regress: the one-geometry `SldSheet` pipeline, the
§10 elevation truth, the honesty/`// VERIFY` surface, the undo timeline, atomic saves, and
the calm token-driven visual language the Apple campaign landed. Every direction below is
additive and guardrail-safe (pure-Dart engine, no Material, offline, glass on chrome only).

## How to read the findings

- **ID** = theme letter + ordinal (A1, K3...). Waves reference IDs.
- **Severity** (after adversarial verification): high = blocks or seriously confuses a core
  task · medium = real friction on a common task · low = polish.
- **Effort:** S = under a day · M = days · L = a week+.
- **Kind:** gap / friction / inconsistency / regression / clarity.
- Findings are confirmed at the cited file:line as of `f54fbf1` (v1.12.0 + one test fix).

## Theme A — First-run and workflow honesty

What a new engineer meets in session one: the empty launch, the stepper, the templates, and whether the app ever claims something it did not do.

### A1. Cold-launch Layout workspace has no zero-file way to try the app
**HIGH** · effort M · gap · lens: apple · finders: apple-first-run

A brand-new install lands on the Design workspace with WorkspaceView.plan and zero sheets, whose ONLY empty-state actions are 'Import plan...' and 'New from template...' — both requiring the engineer to already possess a real PDF/DXF/DWG before anything (calibration, drawing, sizing, heatmap) can happen. The sibling Electrical workspace ships an explicit one-click 'Load sample project' precisely so a first-time user can see the app work without their own file.

- **Evidence:** layout_canvas.dart:876-892 (MechXEmptyStateCard actions: only 'Import plan...' and 'New from template...'); contrast electrical_view.dart:1094-1114 (_EmptyState adds 'Load sample project' → resetToSample, electrical_store.dart:534-536); default landing confirmed by electrical_store.dart:74-79 (workspaceViewProvider => WorkspaceView.plan) and nav_rail.dart:28-30.
- **User impact:** An evaluator or new hire opening iSystem without a floor plan on hand (a very common trial scenario) cannot reach calibration, drawing, auto-sizing, or the pressure heatmap at all — the core value the mission's own success criterion asks about ('empty launch to a calibrated sheet with a first sized run') is unreachable. The app already solves this for Electrical but not for the workspace a new user actually lands on first.
- **Direction:** Add a 'Load sample project' / 'Try a sample plan' action to the Layout empty-state card that seeds a small placeholder sheet (as golden-01's fixture already does — a PlaceholderSheetPage), a plausible calibration, and a tiny pre-sized network, undoable like the electrical sample.


### A2. 'New from template' silently mutates project state when the forced file picker is cancelled
**MEDIUM** · effort S · friction · lens: apple · finders: apple-first-run

On an empty project, choosing a template applies the floor stack/occupancy/fire-hazard/rainfall immediately, then unconditionally opens the native file picker (importPlan with skipDiscardGuard) and unconditionally closes the template dialog afterward — including on cancel. importPlan's cancel path returns with no status message, so the user is dropped back on the same 'No sheet loaded' screen with no sign anything changed.

- **Evidence:** templates_dialog.dart:123-141 (applyTemplate runs, then importPlan(..., skipDiscardGuard:true) awaited, then Navigator.pop regardless of outcome); project_io.dart:139 ('if (result == null || result.files.isEmpty) return;' — no loadError/statusMessage call on cancel).
- **User impact:** A first-time user exploring 'Office tower'/'Hospital' without a plan file ready clicks Apply, gets thrown into an OS dialog, hits Cancel, and lands back on an apparently-unchanged empty canvas — with no indication the floor stack, occupancy, fire hazard class and rainfall were just silently overwritten. They may re-apply thinking nothing happened, or be confused later by unexpected floor counts.
- **Direction:** Show a status confirmation ('Template applied — import a plan when ready') even when the forced picker is cancelled, and return the user to the templates dialog or empty-state card instead of closing silently.


### A3. Onboarding calls step 2 'Floors'; the nav rail item you must click is called 'Building'
**MEDIUM** · effort S · inconsistency · lens: apple · finders: apple-first-run

Both the first-run orientation card and the workflow stepper name the second onboarding step 'Floors' ('set each level's height'), but the left nav-rail destination that hosts floor/height editing is captioned 'Building' everywhere else. The word 'Floors' never appears in the navigation.

- **Evidence:** first_run_guide.dart:30-36 (_kWorkflowSteps step 2 = ('Floors',...)); command_store.dart:77 (WorkflowStage.floors => 'Floors'); nav_rail.dart:168 (label: StringKey.navBuilding) and app_strings.dart:604 (navBuilding: 'Building').
- **User impact:** A new engineer who just read the welcome card's 5-step map, or glances at the stepper chip labelled 'Floors', looks at the rail for a matching 'Floors' entry and won't find one — they must infer that 'Building' is where floor heights live. Small but avoidable friction right in the critical first-run path the app built.
- **Direction:** Use one term everywhere — either rename the nav item to 'Floors' or change the orientation card/stepper stage label to 'Building' so all three surfaces agree.


### A4. Workflow stepper marks 'Floors' done just because something was drawn, without the engineer ever reviewing floor heights
**MEDIUM** · effort S · clarity · lens: apple · finders: apple-first-run

workflowStageStateProvider marks Floors done when the Building screen was visited OR the floor stack differs from the default seed OR — critically — the network has any edge (hasNetwork). That last clause means a user who starts drawing before opening Building gets a green 'Floors' checkmark while the project runs on the untouched default 3-floor seed, which per §10 is the sole source of truth for every riser's vertical length.

- **Evidence:** command_store.dart:170-190: 'final floorsSet = ref.watch(buildingVisitedProvider) || hasNetwork || !listEquals(project.floors, _kDefaultFloorStack);' — hasNetwork ticks Floors off without the engineer opening Building.
- **User impact:** In a first session where drawing happens before floor setup (a natural order), the stepper shows a fully green Calibrate>Floors>Draw>Size run while every riser length is silently computed from generic default heights never checked against the real building — plausible-looking but potentially wrong duty/BOM numbers with no nudge to verify.
- **Direction:** Keep hasNetwork from marking Floors fully done on its own — show a distinct 'unreviewed' visual state (not the same green tick as a confirmed stack) until the engineer has opened Building at least once, even if a network already exists.


### A5. The Projects-hub export surface is an unranked wall of identical buttons, with two near-duplicate PDF plan exports users can't tell apart
**MEDIUM** · effort M · friction · lens: apple+mep · finders: apple-visual, mep-plan-output

Beneath one blue primary 'Export submittal package...', projects_screen.dart lays out ~8 identically-styled secondary MechXButtons in a plain Wrap — calc report (MD/PDF), MEP report (MD/PDF), equipment schedule (MD/PDF), drawing (DXF/PDF), annotated plan (PDF) — with no sub-grouping, icons, or weight differentiation. Two of them, 'Export drawing (PDF)' (networkToPdf) and 'Export annotated plan (PDF)' (planToPdf), are visually identical and take the same chrome/underlay/symbols; the only functional difference is the annotated one folds real per-edge lengths into size labels.

- **Evidence:** projects_screen.dart:96-142 (8 back-to-back identical MechXButtons in one Wrap); :128-140 (the two adjacent PDF buttons); pdf_export.dart:97-106 vs plan_pdf_export.dart:118-131 (near-identical params, underlay/chrome in both). Golden 14_projects_hub.png shows eight indistinguishable gray pills.
- **User impact:** An engineer who wants 'the calc report as PDF' reads through 8 same-weight buttons with long overlapping labels with no hierarchy to shortcut the scan; and a user preparing a submittal has no cue which of two visually-identical 'PDF plan' exports to send, and could issue the lesser one — missing real run lengths on every size label — believing it a lighter variant.
- **Direction:** Group the buttons into sub-labeled clusters by deliverable kind (Reports / Schedules / Drawings), pair each kind with one button revealing a MD/PDF choice, and either drop the plain networkToPdf button from the primary surface (keep it in the command palette) or relabel it 'Export plan (no lengths)' so the two are distinguishable by name.


### A6. Projects hub gives its one primary (accent) button to Export, not to starting a project
**LOW** · effort S · clarity · lens: apple · finders: apple-first-run

On the Projects hub — a natural stop for a user looking for 'New project' or a template — the only solid-accent MechXButton on the whole screen is 'Export submittal package...'; 'New project' and 'Choose template...', the actual getting-started actions, are plain secondary-styled buttons.

- **Evidence:** golden 14_projects_hub.png shows a filled blue 'Export submittal package...' vs plain gray 'New project'/'Choose template...'; projects_screen.dart:71 ('New project', no primary:) vs :90-91 ('Export submittal package...', primary:true) vs :201 ('Choose template...', no primary:).
- **User impact:** A new user landing on Projects to start their first design sees the app's strongest visual affordance pointing at exporting a submittal package for a project that has nothing in it yet, while the buttons that actually begin a design read as ordinary equal-weight controls — the opposite of the top bar's own convention (Save turns primary only once there is dirty work).
- **Direction:** Make Export's primary styling conditional on there being real content to export (mirroring the top bar's dirty-state Save), or give 'New project'/'Choose template...' the primary treatment when the project is still empty.


## Theme B — Canvas interaction integrity

The direct-manipulation contract on the Layout canvas: no silent state corruption, no invisible modes, hit targets that match what is painted, feedback before commitment.

### B1. Switching sheets/floors mid-draw silently corrupts the network with a phantom node
**HIGH** · effort S · gap · lens: apple · finders: apple-canvas

DrawingState.pendingPoint is a bare Offset with no sheetId/floorIndex, and nothing cancels it when the active sheet changes. The next click after a sheet switch resolves the OLD point's raw pixel coordinates against the NEW sheet's geometry, planting a fresh junction node wherever that stale offset lands and wiring an edge to it.

- **Evidence:** network_store.dart:43-57 (pendingPoint, untyped Offset) and :175-223 (placeRunPoint resolves both pendingPoint! and the fresh click via _resolveDrawEndpoint using the caller's CURRENT sheetId/floorIndex, :201-206); sheets_store.dart:136-146 (selectSheet only touches currentIndex, never networkControllerProvider); drawing_overlay.dart:93-168 (keeps painting pendingPoint against the NEW viewport with no sheet-affinity check).
- **User impact:** An engineer mid-run who clicks the sheet rail to check another floor while still in the Run tool, then clicks, silently gets a bogus orphan node + edge added to the new floor at an arbitrary location. Zero feedback at the moment; it only surfaces later (if at all) as an unexplained loose-end/orphan Design Issue with no link back to the sheet-switch, after possibly skewing that floor's sizing/BOM.
- **Direction:** Cancel the pending run (reuse the existing cancelPending(), already wired to Esc and tool changes) whenever the current sheet/floor changes while tool != select, or store the pending point's originating sheetId/floorIndex and refuse a cross-sheet placement.


### B2. Air-duct warning badges collide with size labels instead of dodging them
**MEDIUM** · effort S · clarity · lens: apple · finders: apple-canvas

The over-capacity/velocity/unsized badge is painted at a hardcoded screen offset (mid.y - 13) regardless of the pipe's bearing or the size label already drawn nearby, and never participates in the label collision-avoidance the size text uses. On a horizontal-ish duct the two chips overlap; on a vertical duct the badge paints straight over the casing.

- **Evidence:** network_layer.dart:392-406 places the size label at mid + perp*off and tracks its bounds in placedLabels (used at :1059-1066); :411-419 then place the badge at a fixed (mid.dx, mid.dy-13) with no participation in that set, so the two spans overlap by 10+ px on a near-horizontal run.
- **User impact:** Exactly when an engineer most needs to read a warning clearly — a duct both sized and flagged over-capacity/out-of-band — the red triangle/exclamation renders jumbled into or under the DN/Ø chip, undermining the app's stated 'a warning is surfaced, never silent' invariant.
- **Direction:** Route the badge position through the same collision-avoidance the size label uses (add its bounds to placedLabels, or offset it perpendicular toward whichever side the label did NOT land).
- **Verification note:** severity adjusted high -> medium by the adversarial verifier


### B3. Dropping a riser on the top floor band silently reconnects it to the floor below, with no drop preview
**MEDIUM** · effort S · clarity · lens: apple · finders: apple-riser-ux

In Riser Edit mode, _onDrop computes the floor band under the cursor, but if that band is the topmost floor it silently substitutes floorIndex = levelCount - 2 so the riser actually spans First-Floor->Roof instead of the targeted floor. The only drag feedback is a single accent tint over the ENTIRE canvas — no per-band highlight and no post-drop message explaining the connection moved down a floor.

- **Evidence:** schematic_view.dart:1301-1327 (_onDrop, the floorIndex = levelCount - 2 reroute at :1315), :1405-1433 (whole-canvas tint). Reproduces on any building whose roof/top level hosts downfeed equipment (roof tank, boosters) — golden 04/07's 3-floor Ground/First/Roof building hits this on the Roof band.
- **User impact:** An engineer placing a downfeed/roof-tank riser drags the card onto the Roof band (the natural target for that equipment) and gets a riser drawn between First Floor and Roof — visually indistinguishable from a correct drop. They can't tell until inspecting node positions/tags, so a wrong-floor connection can go unnoticed into a submitted design.
- **Direction:** Show a per-floor-band highlight while dragging (reusing the mechanical DropOverlay ghost-preview idiom) and fire the existing statusMessage pill (e.g. 'Placed to Roof — connects down from First Floor') whenever the :1315 redirect fires.
- **Verification note:** severity adjusted high -> medium by the adversarial verifier


### B4. Auto mode is documented and labeled 'read-only' but a single click can add a permanent network edge
**MEDIUM** · effort S · inconsistency · lens: apple · finders: apple-riser-ux

The file header and the mode segment present 'Auto' as the read-only generated diagram vs 'Edit' as the editable surface. But when 'Infer risers' is on, _AutoElevationState._commit is wired to plain onTapUp and calls NetworkController.connectRiser, adding a real, sized network edge — a genuine structural mutation — inside the mode labeled read-only, with no confirmation (only a quiet status pill).

- **Evidence:** schematic_view.dart:1-6 (doc: 'Auto — the read-only generated riser diagram'), :790-799 (_commit calling connectRiser), :961-964 (wired directly to tap-up, no confirm).
- **User impact:** An engineer reviewing (not editing) toggles 'Infer risers' to sanity-check vertical alignment, then clicks a dashed connector out of curiosity or to pan — and unknowingly commits a new sized pipe to the design while believing they are in a view-only mode.
- **Direction:** Either move the commit-inferred-riser action into Edit mode (consistent with the mode's contract), or add a lightweight confirm affordance (hover tooltip 'Click to add this riser' plus a brief undo toast) so committing a real edge from Auto is never a bare unconfirmed single click.
- **Verification note:** severity adjusted high -> medium by the adversarial verifier


### B5. The clickable corridor around a pipe/duct stays a fixed ~8px band even as true-width zoom renders it up to 120px wide
**MEDIUM** · effort S · friction · lens: apple · finders: apple-canvas

_edgeAt's hit radius is a constant screen-equivalent 8px at any zoom, but _pipeOuterPx (the true-width feature) lets a large calibrated duct/pipe render up to 120 screen px wide once zoomed in. Once the visible pipe is that wide, only a thin invisible strip through its centreline responds to selection or the run-move drag — most of what the user sees as 'the pipe' is dead space.

- **Evidence:** selection_overlay.dart:623 'edgeHitR = 8/transform.scale' (used by _edgeAt/_distToSegment :621-652 and the run-move drag at ~:808); network_layer.dart:545-560 (_pipeOuterPx returns max(clamped, min(truePx,120.0)) once calibrated and zoomed).
- **User impact:** An engineer who zooms in to inspect a large calibrated trunk duct at its real footprint (the very reason true-width exists) has to hunt for a thin centreline to select, right-click-size, or drag — clicking anywhere else on the visibly wide pipe silently does nothing, reading as an unresponsive canvas.
- **Direction:** Scale the edge hit radius with the rendered _pipeOuterPx (e.g. max(8, outer/2 + margin) in screen space) so the clickable band tracks what is actually drawn.


### B6. The outlet-pull nub and the node's move handle have overlapping click boxes with no visible boundary
**MEDIUM** · effort S · inconsistency · lens: apple · finders: apple-canvas

Both the node's move handle and its outlet-pull nub are opaque rectangular GestureDetectors (not the circles they're painted as); the nub's 18x18 box (offset 15px up-right) and the node's 24x24 move-handle box overlap in a real corner region, where the nub — added later in the Stack — always wins the hit test.

- **Evidence:** selection_overlay.dart:334-341 (_dragHandle, r=12 on the node) and :421-430 (_outletNub, r=9 at node+{15,-15}); the squares overlap over a ~6x6 screen-px corner; build() (:301-313) paints outlets after handles, so the nub is hit-tested first there.
- **User impact:** A user grabbing a node slightly off-centre toward its upper-right — plausible, since the drawn dot is only 3-4.5px vs its 24px hit box — can, with no visual cue, trigger 'pull a new mainline' instead of 'move this node': a surprising gesture swap at the exact spot the eye is aiming for.
- **Direction:** Give the nub more clearance (increase the 15px offset or shrink the handle radius while a nub shows), or clip each GestureDetector's hit area to a circle instead of its bounding square.


### B7. The canvas minimap is an unlabeled void-colored box that collides with other floating overlays
**MEDIUM** · effort S · inconsistency · lens: apple · finders: apple-visual

CanvasMinimap fills its sheet silhouette with colors.canvas — the color of the empty margin BEHIND sheets (near-black in dark), not sheetPaper (white), the color the actual drawing sheet renders in. It carries no label anywhere. In the electrical Layout view it stacks directly above the differently-styled 'Not on this sheet' tray with no shared radius, spacing, or material.

- **Evidence:** canvas_minimap.dart:69-75 (fill: colors.canvas), :91. Visible in 01/02/03, 05, 06, 08/09/11 as a plain dark rectangle with a few dots, no caption. In 06 it sits ~8px above the gray-gradient 'Not on this sheet' card with a different corner radius and fill.
- **User impact:** A first-time user encountering this small dark rectangle in every canvas corner has no way to tell what it is (no label, and its color doesn't correspond to the white sheet it maps) until they experimentally drag it; with a second floating tray nearby, the corner looks cluttered and un-designed.
- **Direction:** Fill the minimap sheet silhouette with sheetPaper (matching the real sheet) instead of the void canvas color, and give it a caption or a consistent gap/shared radius with the 'Not on this sheet' tray so the two read as one family.


### B8. A size label that can't find a clear spot vanishes with no trace it exists
**LOW** · effort S · clarity · lens: apple · finders: apple-canvas

When all three label-placement candidates collide with an already-placed label, _label silently returns without drawing anything — no dot, tick, or affordance signals that a DN/Ø value exists on that run but was dropped for space.

- **Evidence:** network_layer.dart:1048-1066, culminating in 'if (center == null) return; // still colliding -> drop (size is one click away)'.
- **User impact:** On a busy floor with several closely-spaced or short runs, some genuinely-sized pipes/ducts show no size text at all — visually indistinguishable from an unsized run — so the engineer must click every suspect run just to learn whether it is sized, since nothing marks 'there is a value here, just not shown.'
- **Direction:** Fall back to a small distinct tick/dot at the run's midpoint when the label was dropped for space (distinct from the existing 'unsized advisory' ring), so density never silently reads as 'nothing here.'


### B9. The 'focus this panel' deep zoom clips the board schedule at both edges at common window widths
**HIGH** · effort S · clarity · lens: apple+mep · finders: orchestrator

focusPanelSchedule frames a board at a FIXED scale (kBoardScheduleThreshold + 0.3 = 1.65x) with no fit-to-width clamp. The engine board schedule is 920 world units wide, so at 1.65x it needs ~1518 px of canvas — more than the canvas offers at the app's own golden surface (1440x900 leaves ~1030 px) and at many real laptop widths. Centring then clips BOTH edges: the GRUP column, the panel name, the incomer sub-line, and the TOTAL footer all fall off the left edge. Golden 11 ships this state: 'in Distribution Panel [MDP]', 'her MCCB C100A/4P', and 'AL 36.2kW / 85.8A' are all visibly cut. Even the minimum schedule-rendering zoom (kLodThreshold-adjacent kBoardScheduleThreshold = 1.35 -> 1242 px) cannot fit that viewport, so on smaller windows there is NO zoom at which a full schedule row is readable without horizontal panning.

- **Evidence:** lib/ui/electrical/electrical_canvas.dart:785-799 (fixed s = kBoardScheduleThreshold + 0.3, no clamp to viewport width); :67 (kBoardScheduleThreshold = 1.35); the 920-unit schedule block width in packages/mechx_engine/lib/report/electrical_sld_drawing.dart; golden 11_electrical_schedule.png shows the clipped left edge, plus a clipped red warning-badge fragment in the toolbar row.
- **User impact:** Every Review->Locate jump and every summary-card expand chevron lands the engineer on a schedule whose identifying columns are cut off; on a 1366/1440-wide laptop no zoom level shows a whole way row. The app's own regression golden immortalises the defect, so it reads as intended behaviour.
- **Direction:** Clamp the focus scale to fit the board width (s = min(1.65, viewportWidth * 0.94 / boardWidth)) with kLodThreshold as the floor; if the clamped scale would fall below kLodThreshold, prefer fit-width and accept the summary card, or scroll-lock horizontally to the GRUP column. Re-capture golden 11 deliberately. Also chase the clipped warning-badge fragment in the toolbar (visible in the same golden).

### B10. Endpoint-resize and node drags ignore the ortho constraint, un-straightening drawn runs
**HIGH** · effort S · friction · lens: user-reported (2026-07-06, product owner)

Drawing snaps to 45-degree steps (orthoSnap, snapping.dart:9; Ortho default-on; Shift = one-off
free angle) and the nub-pull preview + release honour it — but the selected-run endpoint RESIZE
handles (endNodeDragWithSnap call sites, selection_overlay.dart:408/:556) and plain node drags
apply no angle snap at all. Stretching an endpoint or nudging a junction leaves a once-straight
run slightly askew, which then prints askew on the exported plan.

- **Evidence:** selection_overlay.dart:408/:556 (no orthoSnap on the resize path); snapping.dart:9.
- **User impact:** The drafter draws straight 45/90 runs, edits one endpoint, and the line is no
  longer straight — invisible on canvas at working zoom, visible on the issued sheet.
- **Direction:** Apply the same effectiveOrtho snap (anchor = the run's other endpoint) to the
  resize-handle live drag + release, and to degree-1 node drags while Ortho is on.

### B11. The outlet nub unmounts mid-pull, freezing the new run a short distance from the mainline
**HIGH** · effort S · friction · lens: user-reported (2026-07-06, product owner)

The outlet nub is mounted only while its node is hovered or selected (C7 gating,
selection_overlay.dart:238-245). During a pull from a merely-hovered node the pointer leaves the
18px nub, its own MouseRegion.onExit clears hoverTargetProvider (:439), the rebuild unmounts the
nub, and the active pan gesture DIES — the preview line freezes close to the mainline and cannot
be dragged further. Pulling works only when the node was clicked (selected) first, so the failure
looks intermittent.

- **Evidence:** selection_overlay.dart:238-245 (mount gate), :436-439 (onExit clears the latch
  that keeps it mounted), :442-451 (the pan handlers that die on unmount).
- **User impact:** The core tee-off gesture — dragging a new line out of the mainline — stops
  dead after a few pixels unless the user knows to click the node first; reads as a broken tool.
- **Direction:** Keep the nub mounted while its pull is active (gate adds `_pullFrom == n.id`)
  and skip the onExit hover-clear while `_pullFrom != null`; widget-test the full pull gesture
  from a hovered-unselected node.

### B12. Plan underlay geometry is not a snap surface — a riser cannot snap to the shaft wall
**HIGH** · effort M · gap · lens: user-reported (2026-07-06, product owner)

The imported plan is display-only. For DXF/DWG sheets the parsed vector geometry already exists
and is cached per sheet (dxf_sheet_page.dart:37 `_cache: Map<String, DxfDrawing?>`) but is never
consulted by the snapping layer, so drawing against a wall/shaft line is freehand eyeballing.
PDF sheets are raster (pdfrx) and have no geometry at all.

- **Evidence:** dxf_sheet_page.dart:37-51 (cached DxfDrawing, paint-only); the snap sites
  (network_store `_snap`, snapping.dart `snapOrTeePoint`, drop_overlay, endpoint drag) consult
  network nodes + the magnetic grid only — no underlay candidates.
- **User impact:** The drafter cannot place a riser snapped to the shaft wall or run pipe tight
  along a corridor wall — positions drift off the architecture, and the exported plan shows it.
- **Direction:** (1) DXF/DWG: expose the cached DxfDrawing to snapping, build a per-sheet
  segment spatial index, add underlay snap candidates (endpoint / nearest-on-segment /
  intersection) between node-snap and grid-snap precedence — every existing snap gesture
  inherits it, with the existing snap-ring feedback. (2) PDF: a 'trace reference line' tool —
  two clicks along a wall create a persisted snappable construction line (additive `.mechx`
  list, tolerant; doubles as the N4 gridline substrate). Optional later: raster snap-to-ink.


## Theme C — Inspector and information architecture

The right-hand column: selection-first behaviour, disclosure discipline, and whether every model field the app acts on is actually editable somewhere.

### C1. Electrical editing still uses floating right-side drawers instead of the converged persistent inline inspector
**MEDIUM** · effort M · regression · lens: apple · finders: apple-inspector, apple-electrical-ux

The C1/C4 convergence was supposed to replace the electrical workspace's floating slide-in drawer with an inline, selection-first inspector column shared with the mechanical shell, but two surfaces still diverge. On the unified Layout canvas's Electrical layer, double-clicking a panel/circuit opens a 340px Positioned drawer stacked on the canvas while the persistent right column keeps showing the static 'Electrical layer' Loads-palette title (never reacting to the selection). On the standalone Electrical workspace, the Service & Earthing, Sources, and Issues/Advanced-study buttons still open _AnimatedDrawerShell (340-420px) ON TOP of the canvas, sitting beside the always-visible CollapsibleInspector column — two right-side panels competing for the same role at once.

- **Evidence:** Layout: layout_canvas.dart:216-230 + :344-388 (ElectricalCircuit/PanelInspector as Positioned(top:0,right:0,bottom:0) overlays); app_shell.dart:300-327 _ElectricalInspectorColumn renders only a static title + ElectricalPalette(), no watch on any edit-target provider. Standalone: electrical_view.dart:1178-1239 (_AnimatedDrawerShell) instantiated by _ServiceInspector (:1261), _SourcesEditor (:1423), _AdvancedDrawer (:1587), all inside ElectricalView's Stack (:276) which sits left of the always-visible CollapsibleInspector (app_shell.dart:249-252). Golden 06_electrical_layout.png shows the static Loads column.
- **User impact:** An engineer coordinating M+E+P on one plan (the headline convergence feature) or doing routine electrical setup/verification double-clicks a panel or opens Service/Sources/Issues and gets a drawer overlapping the drawing, sitting beside a second seemingly-frozen inspector column still advertising 'Electrical layer' and a Loads palette that no longer applies. The canvas shrinks by ~650px combined, and it breaks the selection-first 'the inspector shows what's selected' model the rest of the app was redesigned around.
- **Direction:** Route both the Layout electrical-layer edit target and the standalone workspace's Service & Earthing / Sources / Advanced-study through the same electricalInspectorTargetProvider + inline inspector-column mechanism used for circuit/panel editing, falling back to the palette when nothing is selected; update golden 06 deliberately.
- **Verification note:** severity adjusted high -> medium by the adversarial verifier


### C2. Selection auto-scroll-to-top only fires the first time; re-selecting a different element while scrolled away leaves the updated editor invisible
**MEDIUM** · effort S · gap · lens: apple · finders: apple-inspector

The inspector pins the node/edge editor at the top and jumps the scroll to it — but only on the transition from 'nothing selected' to 'something selected'. If the user already has one element selected, scrolls down, then clicks a different element on canvas, the Selection editor silently updates with no scroll or cue, because the guard requires the previous selection to have been empty.

- **Evidence:** project_panel.dart:1099-1103: ref.listen(selectionProvider, (prev,next){ if((prev==null || prev.isEmpty) && !next.isEmpty && _scroll.hasClients) _scroll.jumpTo(0); }); — only empty→non-empty; a non-empty→different transition doesn't jump.
- **User impact:** A common workflow — clicking through several fixtures/runs in sequence to spot-check sizes while the inspector is scrolled to Results/Fire/HVAC — leaves the engineer looking at stale section content, unaware the Selection editor above has silently changed underneath the fold. They may edit the wrong element's properties.
- **Direction:** Jump to top on any change of next.nodeId/next.edgeId identity (not just empty→non-empty), or at minimum flash/highlight the Selection section when it updates while the panel is scrolled away.


### C3. The always-open 'Draw' section is the single largest block in the inspector and buries Sizing/Results/Fire/HVAC below the fold every session
**MEDIUM** · effort S · inconsistency · lens: apple · finders: apple-inspector

Every other content section gates defaultExpanded on real state (uncalibrated, fire pipework present, air elements exist, network solved) so an empty project stays a quiet collapsed header. 'Draw' has no such gate — it always opens, and it is the biggest section (Tools + Service chips + Undo/Redo/Ortho + the full SegmentPalette). On a new uncalibrated project it alone fills the entire 900px inspector viewport.

- **Evidence:** project_panel.dart:1144 (const _DrawSection(), no gating) vs :3052-3058 (Fire: defaultExpanded: hasFireEdges), :4223-4228 (HVAC), :1244-1246 (Scale). Section order at :1140-1171 puts Draw ahead of Tanks/Rooms/Design-inputs/Results/Fire/HVAC. Goldens 01/02 confirm the viewport is consumed by Building+Sheet+Scale+Draw with nothing below Draw visible.
- **User impact:** Any engineer setting up a new project (checking occupancy defaults, fire hazard class, HVAC method before drawing) must scroll past the entire tool palette every time, even before touching a draw tool. The sections engineers actually need mid-session (Results/Fire/HVAC) are consistently farthest away, contradicting the 'calmer inspector' data-gating applied everywhere else.
- **Direction:** Collapse Draw by default once the network has runs (first visit stays open, a returning session collapses it), or move it below the design-input/results sections it currently buries.


### C4. The Rooms (ACH/AHU) editor is the one major sizing surface that never got the identity-first / ResultCard treatment
**MEDIUM** · effort M · inconsistency · lens: apple · finders: apple-inspector

Node, edge, and the Sizing/Results/Fire/HVAC sections were all reworked to lead with identity/inputs and demote read-only figures into a ResultCard or collapsed disclosure. The Rooms expanded room card was not: it stacks ~a dozen equal-weight caption rows — CFM/L/s/m3, duct size+velocity, supply/return banks, equipment static+motor, cooling BTU/PK, THEN ceiling/ACH/room-type/equipment pills and an action — with only text colour distinguishing outputs from inputs, no ResultCard, no sub-grouping. The structurally-identical Tanks section stayed a clean 3-field editor.

- **Evidence:** project_panel.dart:2404-2607 (room body: outputs 2437-2496 interleaved with inputs 2497-2607, no ResultCard/disclosure) vs Tanks at :2219-2291 (3 fields, same _MasterRow), node editor's Placement demotion at :3822-3894, ResultCard promotions at :2775-2803/:3082-3095/:4272-4279.
- **User impact:** Whoever tunes room airflow/AC sizing (the densest per-item editor in the app) gets the least legible one — it takes real effort to tell 'the airflow the app computed' from 'the ACH you can override' at a glance, and the headline CFM/duct/AC numbers don't stand out the way a Fire or HVAC engineer's figures now do elsewhere in the same panel.
- **Direction:** Promote the CFM/duct or AC PK figure to a ResultCard and move ceiling/ACH/room-type/equipment-kind into a collapsed 'Room settings' disclosure below it, mirroring the node editor's identity-first + demoted-Placement pattern.


### C5. A circuit's starter/control type has no UI control anywhere, making the drafting feature it drives permanently unreachable by hand
**MEDIUM** · effort S · gap · lens: apple · finders: apple-inspector

ElectricalCircuit.starterType (DOL/star-delta/reversing/soft-start/VFD/ATS/pump) is read by the panel-schedule drafter (appends a control token to the way row), by the arc-flash/advanced study (starting exemption), and round-trips in .mechx — but the circuit editor's field list (including its 'Advanced' disclosure) never exposes it, and no auto-feed sets it either.

- **Evidence:** electrical_inspector.dart:222-398 lists every editable circuit field; starterType appears nowhere. Cross-ref model.dart:131 (field), compute.dart:525-526 and advanced_study.dart:175-185 (consumers), electrical_sld_drawing.dart:376-378 ('shown ONLY when a way carries a real starterType'). electrical_store.dart:1194/1236 only preserve an existing value on MEP re-sync; nothing sets one.
- **User impact:** An electrical drafter trying to get the real BRI-style panel schedule (with its DOL/star-delta/VFD control notation, a feature built for CAD credibility) has no way to make it appear for a hand-drawn or hand-edited circuit — the field is invisible and unsettable, so drawings always fall back to bare breaker notation.
- **Direction:** Add a starterType ElectricalEnumPicker (None/DOL/Star-delta/Reversing/Soft-start/VFD/ATS) to the circuit editor's 'Advanced' disclosure, gated to motor/pump load kinds like the motor-power field already is.


### C6. 0-1 ratio fields and an adjacent 0-100 percent field look identical and silently clamp on mismatch
**LOW** · effort S · clarity · lens: apple · finders: apple-inspector

cos phi, Demand factor, and Diversity factor all expect a 0.0-1.0 fraction and silently .clamp(0.0,1.0) whatever is typed; the neighbouring Headroom-spare field in the same Advanced disclosure expects 0-100 and is labelled '(%)'. All four render through the same bare ElectricalNumInput — a plain mono textbox with no unit suffix, range hint, or error state — so nothing distinguishes 'type 0.85' from 'type 85'.

- **Evidence:** electrical_inspector.dart:349-372 (cos phi / Demand factor, .clamp(0.0,1.0), labels carry no range) vs :573-586 (Headroom spare, 0-100, labelled '(%)' in app_strings.dart:996); electrical_controls.dart:84-108 (ElectricalNumInput has no suffix/unit slot) — contrast the mechanical SteppedValueField whose display bakes in the unit.
- **User impact:** An engineer used to specifying demand factor as a percentage types '85' expecting 85%, the value silently clamps to 1.0 (100%), and nothing signals the input was rejected or reinterpreted — the panel simply re-solves with a demand factor of 1.0, quietly changing the sizing result.
- **Direction:** Either scale these fields to 0-100 (%) to match Headroom spare, or add an explicit ratio hint ('(0-1)') to the label, and surface a visible correction (not a silent clamp) when the typed value falls outside range.


## Theme D — Workspace parity (Riser and Electrical)

The secondary surfaces measured against the Layout canvas bar: same idioms, same keyboard, no affordances that look live but are dead.

### D1. Power one-line's empty state tells the user to add sources 'from the Loads palette' but no such cards exist there
**HIGH** · effort S · gap · lens: apple · finders: apple-electrical-ux

The Power one-line tab's empty state reads 'Add a generator, solar PV or battery from the Loads palette...'. The actual Loads palette only contains Lighting/Sockets/Air-con/Water heater/EV/Industrial socket/UPS/Welding/Custom, Motors & Pumps, and Distribution — no generator, solar, or battery card. A generator is only addable via the separate 'Sources' drawer; solar and battery have no user-facing control anywhere.

- **Evidence:** power_oneline_view.dart:44-47 (the instruction text); electrical_palette.dart:60-120 (full card list — no source kinds); electrical_view.dart _SourcesEditor (~1398-1560) exposes only Genset/Transformer/Capacitor/Dual-transformer; electrical_store.dart:399-417 only preserves solar/battery, never sets them.
- **User impact:** A user who opens Power one-line with no sources, reads the guidance, and goes to the Loads palette to add a generator/solar/battery finds none of those items and cannot complete the task — a dead-end instruction on a first-run empty state.
- **Direction:** Either add solar/battery fields to the Sources drawer plus generator/solar/battery palette entries, or rewrite the empty-state copy to point at the actual 'Sources' button.


### D2. Electrical single-line canvas has no multi-select, marquee, arrow-nudge, or copy/paste — a real step down from the mechanical Layout canvas
**MEDIUM** · effort L · gap · lens: apple · finders: apple-electrical-ux

The mechanical Layout canvas supports rubber-band marquee multi-select, Shift-click, arrow-key nudge, and copy/paste with cascade. The electrical single-line canvas's selection model is a single nullable _CanvasSelection? (one panel or circuit at a time), and its own comment states the box-select gap is a deliberate permanent scope cut.

- **Evidence:** electrical_canvas.dart:92-96,157-166 (_CanvasSelection?, single-value); :284-286 'no box-select for this pass'; _onKey (:301-344) only handles Ctrl+Z/Y, Delete/Backspace on the lone selection, Esc — no arrow handling. Compare selection_overlay.dart (marquee, Shift-union) and layout_canvas.dart:726-732 (arrow-key nudge).
- **User impact:** A drafter who just used the mechanical canvas's marquee + group move + arrow-nudge switches to Electrical and loses all of it: cannot select two panels to mark both essential, cannot nudge a panel, cannot copy a sub-panel + its ways as a template. The electrical workspace feels bolted-on rather than a peer of Layout/Riser.
- **Direction:** At minimum add Shift-click multi-select for panels (batch essential/UPS/submeter toggles) and arrow-key nudge for the selected panel/load, reusing the existing setPanelPosition/moveCircuit intents.
- **Verification note:** severity adjusted high -> medium by the adversarial verifier


### D3. Main/run edges shown in Riser Edit mode look identical to risers but are completely inert
**MEDIUM** · effort S · clarity · lens: apple · finders: apple-riser-ux

_EditSchematicPainter renders every edge (riser or plain run) with the same colour/style, differing only by a 0.5px stroke-width delta imperceptible at normal zoom. But _riserAt filters to EdgeKind.riser only, and both left-click select/drag and right-click context menu silently no-op on any non-riser edge — _onSecondaryTapUp just returns with zero feedback.

- **Evidence:** schematic_view.dart:1144-1150 (_riserAt filters e.kind != riser), :1242-1248 (_onSecondaryTapUp returns silently when hit==null), :2891/:2921 (near-identical paint). Golden 07_riser_edit.png shows the horizontal 'DN15 · DN15 · DN15' main at Ground in the same blue/weight as the vertical risers above it.
- **User impact:** A drafter naturally tries to right-click a horizontal main (visible for context) to check or resize it — as they can for any edge on Layout — and nothing happens: no menu, no message, no cursor change. It reads as an unresponsive click, not a deliberate 'read-only here' design.
- **Direction:** Visually de-emphasize non-riser edges in Edit mode (dim/dash them, as already done for inferred connectors) so only interactive risers carry solid full-opacity service colour, or route a right-click on a main to a toast ('Edit this run on the Layout canvas').


### D4. The per-sheet/floor rail is shown on the Riser workspace but has no effect on it
**MEDIUM** · effort S · inconsistency · lens: apple · finders: apple-riser-ux

_DesignWorkspace explicitly omits SheetRail for Electrical because 'it is NOT sheet-based', but the Riser/Schematic workspace — equally not sheet-based, since Auto/Edit always render the WHOLE building across all floors regardless of selected sheet — still gets a SheetRail unconditionally. Nothing in schematic_view.dart reads the current-sheet selection; _sheetIdForFloor loops over every sheet to find one matching a floor index and never consults sheets.currentIndex.

- **Evidence:** app_shell.dart:234-241 ('not sheet-based -> omit SheetRail' applied only to Electrical), :290 (SheetRail() still rendered for Schematic); schematic_view.dart:1329-1341 (_sheetIdForFloor ignores 'current'). Goldens 04 and 07 show the '3 SHT' rail beside the Riser canvas.
- **User impact:** An engineer switching to Riser sees the same floor-numbered rail as Layout and tries clicking floor 2/3 expecting to jump/filter — nothing happens (both modes always show every floor stacked), so the rail is confusing dead chrome that wastes clicks and contradicts the reasoning used to remove it from Electrical.
- **Direction:** Omit SheetRail for WorkspaceView.schematic too, mirroring the Electrical case, and rely on the Riser-scoped inspector for building/floor context.


### D5. Riser Edit mode has no multi-select, marquee, or batch move — every riser is placed/dragged one at a time
**MEDIUM** · effort M · gap · lens: apple · finders: apple-riser-ux

_onKey in Edit mode only handles Ctrl+Z/Y, Esc, and Delete against a single selected edge; _draggingRiser is a single nullable String, so only one riser can be selected or dragged per gesture. Layout's canvas, by contrast, has rubber-band marquee multi-select and batch move.

- **Evidence:** schematic_view.dart:1250-1297 (_onKey, single-edge Delete only, no arrow-nudge, no Ctrl+A), :1178-1215 (single _draggingRiser), contrasted with selection_overlay.dart:27-29/654-657 and selection_store.dart:19-20.
- **User impact:** A building with several parallel riser stacks (cold/hot water, drainage, vent, rainwater, supply/return/exhaust air are all riser services in this toolbar) forces the drafter to select and nudge each riser individually to align or batch-check sizes, whereas the same task on Layout — which the app trained the user on first — supports marquee-select and group move.
- **Direction:** Extend the existing multi-select Selection set and rubber-band marquee (already built for Layout) to the Riser Edit canvas's edge hit-testing, at minimum for select + arrow-key nudge across several risers at once.


### D6. The Loads palette stays fully interactive-looking on the read-only Building-riser and Power-one-line tabs
**MEDIUM** · effort S · friction · lens: apple · finders: apple-electrical-ux

The right-side inspector column (Loads palette / circuit editor) renders independent of which electrical tab is active. Switching to 'Building riser' or 'Power one-line' — both read-only projections with no drop targets — leaves the drag-and-drop Loads palette sitting beside the diagram, unchanged and visually live.

- **Evidence:** Golden 10_electrical_riser.png shows the full 'LOADS' palette on the right of the static per-floor riser. app_shell.dart:242-256 renders CollapsibleInspector(child:_ElectricalWorkspaceInspectorColumn()) unconditionally for WorkspaceView.electrical, with no gating on the tab; _buildRiserArea (electrical_view.dart:437-455) returns a plain _SldProjectionArea with no DragTarget.
- **User impact:** A user on Building-riser/Power-one-line who tries the same drag-a-Lighting-card gesture that works on Single-line gets no feedback and no explanation for why nothing happened, because the palette gives no visual cue that it's inert on this tab.
- **Direction:** Grey out / disable the palette (or swap it for a short read-only caption) when _tab != _Tab.singleLine.


### D7. The on-canvas (?) guide explains Layout-to-Riser but never Layout's electrical layer to the Electrical workspace
**MEDIUM** · effort S · clarity · lens: apple · finders: apple-electrical-ux

The mechanical Layout canvas's (?) guide explicitly connects the two related surfaces ('Risers drawn here stack vertically in the Riser view'). The electrical-layer variant has no equivalent line connecting panels/loads placed on the Layout PDF to the standalone Electrical workspace, even though both read the same electricalProjectProvider model.

- **Evidence:** layout_canvas.dart:1250-1261 (_mechanicalLayerGuideItems ends with the Riser cross-reference); :1265-1271 (_electricalLayerGuideItems, 5 items, no line connecting to the Electrical nav-rail workspace).
- **User impact:** An engineer who places panels/loads on the calibrated PDF in the Layout electrical layer has no in-product hint that the same panels also appear (and can be edited) as boxes in the separate Electrical workspace's single-line canvas — the 'same model, two projections' relationship is undocumented on the one surface designed to explain exactly this.
- **Direction:** Add one line to _electricalLayerGuideItems, e.g. 'Panels placed here also appear in the Electrical workspace's single-line view'.


### D8. Two incompatible chrome material languages collide on the Riser single-line canvas
**MEDIUM** · effort S · inconsistency · lens: apple · finders: apple-visual

The PUMP-SET / DETAIL WATER METER / DETAIL PRV SET callouts are canvas-painted opaque boxes (dark fill, 4px hairline border, blue service-colored title), while the adjacent Notes (KETERANGAN) card is a genuine Liquid-Glass GlassSurface widget with a big popover shadow and card-radius corners. Both are the same conceptual thing (a toggleable drafting annotation under the shared Details/Notes chips) but render in two unrelated visual systems side by side.

- **Evidence:** _detailBox at schematic_view.dart:2344-2366 vs the Notes card at :3356-3387. Goldens 04/09/10 bottom-of-canvas: 'DETAIL WATER METER'/'DETAIL PRV SET' (flat, hairline, blue titles) sit inches from 'Notes' (frosted, shadowed, larger radius, gray text).
- **User impact:** On the one screen meant to look like a single coherent issuable drawing, two neighbouring reference boxes visibly disagree on material, weight, and radius — reads as two features bolted together rather than one drafted sheet, undermining the 'is this a real CAD deliverable' impression right before export.
- **Direction:** Render the Notes/KETERANGAN card with the same _detailBox canvas-paint treatment used by the other detail callouts, reserving Liquid Glass strictly for persistent navigation/control chrome per the golden rule.


### D9. Two 'reveal panel detail' gestures on the same summary card zoom to inconsistent, undocumented scales
**LOW** · effort S · inconsistency · lens: apple · finders: apple-electrical-ux

A summary card offers two ways to see detail: its expand chevron calls focusPanelSchedule, framing the board at the file's documented 'comfortable schedule-reading scale' of 1.35; double-tapping the adjacent merged 'N loads' node calls _expandLoadsAt, which zooms to only kLodThreshold + 0.06 (0.78) — barely past the tier boundary, nowhere near the comfortable scale.

- **Evidence:** electrical_canvas.dart:61-67 documents kBoardScheduleThreshold=1.35 used by focusPanelSchedule (wired at :682); :815-821 (_expandLoadsAt jumps to kLodThreshold+0.06=0.78, wired at :748 onDoubleTap).
- **User impact:** A user double-tapping the '3 loads' node next to a panel (a natural, discoverable gesture) lands at a zoom where the dense multi-column board schedule is rendered far smaller than if they'd clicked the card's chevron — an inconsistent, hard-to-read result from what looks like the same 'zoom in on this panel' action.
- **Direction:** Make _expandLoadsAt target the same kBoardScheduleThreshold (or close to it) instead of the bare tier-crossing minimum.


## Theme E — Visual language and colour semantics

The screenshot-level taste pass: colour that means one thing everywhere, labels that survive density, and the same drawing reading identically on canvas, PDF, and DXF.

### E1. The fixed on-canvas help button overlaps and clips real diagram labels in the Riser top-left corner
**HIGH** · effort S · clarity · lens: apple · finders: apple-riser-ux, apple-visual

The (?) CanvasGuideButton is pinned at a fixed screen position (left: MechXSpacing.md, top: MechXSpacing.sm) with no awareness of world-space diagram content. The Legend overlay was explicitly offset to clear it, but node/fixture labels and the per-floor fixture fan-out (which starts drawing at canvas-local x=8, y=top+20, and _bandTopY returns 0 for the topmost floor) were not — so the button's ~26x26 footprint (x:16-42, y:8-34) deterministically overlaps top-band content whenever the highest floor has any fixture/diffuser node and Details is on (on by default).

- **Evidence:** schematic_view.dart:1020-1027 (fixed-position button); _paintFloorFanOut at schematic_view.dart:2673-2727 (stubX=MechXSpacing.sm, y=top+20) and _bandTopY at :1846-1851 (returns 0 for top floor). Reproduces in goldens 09_single_line_symbols.png and 10_single_line_inferred.png: the '?' sits on top of a two-line label, clipping the first line to a bare 'e' with 'Supply diffuser' half-eaten beneath; 10 additionally crowds a 'Fixture' label.
- **User impact:** Any multi-floor project where the top floor has a fixture or diffuser (very common — a top-floor bathroom, roof AC) gets a genuinely illegible, half-eaten label under the help affordance, right in the corner an engineer looks at first. It reads as a rendering bug in a customer-facing drafting deliverable, exactly the density/label-collision failure a professional CAD sheet must avoid.
- **Direction:** Route the help button's corner through the same label-collision pass the painter already uses for pipe tags (~schematic_view.dart:1583-1654), or reserve a fixed top-left content margin, or move the button to a corner the fan-out never reaches (mirroring the legend's already-documented offset trick at :986-996).


### E2. Supply-air, return-air, and exhaust colors disagree between canvas, PDF, and DXF
**HIGH** · effort M · inconsistency · lens: mep · finders: mep-plan-output

The Layout canvas paints duct #8A7BD8, return air #6F8FC0, exhaust #5B6470; the PDF/DXF plan exporters use a completely different hue family for the same three services (duct green, return olive, exhaust purple), and the DXF ACI mapping disagrees with even that (duct is ACI 6 violet vs the PDF's green triple). service_style.dart admits the two tables are 'kept in step by hand', and no test pins them together. The other 7 of 10 services match.

- **Evidence:** service_style.dart:13-15 vs drawing_chrome.dart:172-174 & :586-588 (also pdf_export.dart:34-36, plan_pdf_export.dart:39-41); service_style.dart:23-27 notes the hand-sync.
- **User impact:** A drafter who colour-codes HVAC ductwork on screen then opens the issued PDF/DXF to check it sees the same service in an unrelated colour on each surface, and the PDF legend disagrees with the DXF layer colour for the same sheet — exactly the first-look colour-key inconsistency a drafting-office QA reviewer rejects a set for.
- **Direction:** Make serviceColor derive from (or be test-pinned against) drawing_chrome's serviceChromeColor for all 10 services, correct the DXF ACI picks for duct/exhaust to the same hue family, and regenerate the affected goldens.


### E3. Cold-water service color and the UI's own selection-accent color are nearly the same blue
**MEDIUM** · effort M · inconsistency · lens: apple · finders: apple-visual

The app's single UI accent (systemBlue, hue ~211°) signals every 'selected/active/primary' state — Save, active Select/Ortho tool, active nav workspace, focus rings. serviceColor() gives Cold water — the default, most-drawn service in every seed scene — #2D6CDF (hue ~219°), just 8° apart. Since Cold water is the pre-selected default service in every golden, the two meanings collapse into one color everywhere at once.

- **Evidence:** design_tokens.dart:193/:221 (accent) vs service_style.dart:8 (coldWater #2D6CDF); measured hues 211/210/219°. Visible in 01/02/03: the Save button, active Select tool pill, Ortho toggle, Cold water swatch, and the drawn CW-R1 pipe line are all the same blue simultaneously.
- **User impact:** A user scanning the Layout canvas can't use color alone to separate 'this control is active/selected' from 'this line is cold-water pipe' — the app's strongest visual signal (accent blue) is overloaded across two unrelated meanings (interactive state vs service identity) in the single most common working context (Plumbing + Cold water).
- **Direction:** Shift the cold-water service hue further from the UI accent (toward a cooler cyan/teal-blue, keeping the other nine services' relative spacing) or desaturate/darken it so it reads as 'drawing ink' distinct from 'interactive chrome'.
- **Verification note:** severity adjusted high -> medium by the adversarial verifier


### E4. The pressure heatmap's flat/uniform state renders as washed-out tan, not a confident data visualization
**MEDIUM** · effort S · clarity · lens: apple · finders: apple-visual

The heatmap ramp is red -> amber(#E0A53A) -> teal, but the painter draws every fill with .withAlpha(105) (~41% opacity) over white sheet paper, so the mid-ramp 'uniform' state — shown for any small/early project, including the shipped seed golden — renders as a pale, low-saturation tan rather than a legible amber.

- **Evidence:** Sampled pixel (600,400) in 03_heatmap.png = RGB(235,211,169) vs the nominal ramp mid #E0A53A = RGB(224,165,58) at full strength — confirms the ~41% alpha wash. heatmap_layer.dart:13-15 (ramp) and :196 (withAlpha(105)).
- **User impact:** The pressure heatmap is a headline feature, yet its most commonly-seen state (an early/small/uniform project) looks like a stained or discolored sheet of paper rather than a deliberate data overlay, undercutting confidence the first time an engineer opens it.
- **Direction:** Raise the fill opacity (or add a thin colored edge/legend tick at the sampled color) for the near-uniform case so the wash reads as an intentional flat color rather than a faded artifact, while keeping enough transparency elsewhere to see geometry.


### E5. No on-canvas legend for the colour-only Plumbing services while drawing
**MEDIUM** · effort S · gap · lens: mep · finders: mep-plan-output

Plumbing is one unified layer overlaying cold water, hot water, drainage, vent, rainwater; only vent gets a dash pattern — the rest differ by colour alone. The only service-colour legend lives inside export chrome (pdfLegend) or the Riser view's toggleable KETERANGAN box; the Layout/Plan canvas itself has no legend — CanvasGuideLegend is gesture help, not a colour key.

- **Evidence:** service_style.dart:7-32 (5 similar-toned colours, only 1 dashed); drawing_chrome.dart:197-222 (legend only in export chrome); layout_canvas.dart:1179 (CanvasGuideLegend is the (?) help popover, not a colour key).
- **User impact:** While actively drawing a real multi-service floor (cold/hot/drainage/vent/rainwater together, plus Fire/HVAC toggled visible), a drafter has no in-context reference for which of several similar-hue lines is which service and must memorize the mapping or open an export just to check — slowing every session on a non-trivial project.
- **Direction:** Add a small toggleable legend chip on the Layout canvas reusing the same service list/colour data that feeds pdfLegend, mirroring the Riser view's KETERANGAN box.


### E6. Floor elevation notation disagrees between the live canvas and the exported drawing
**MEDIUM** · effort S · inconsistency · lens: mep · finders: mep-riser-quality

The on-canvas Auto view labels each floor band 'Level 2  +7.5 m' (one decimal, no 'FFL'). The PDF/DXF export builder for the same sheet emits a separate line reading 'FFL +7.50' (two decimals, with the FFL abbreviation the on-screen view never shows).

- **Evidence:** schematic_view.dart:1978 ('${floor.name}  +${elevM.toStringAsFixed(1)} m') vs mechanical_sld_drawing.dart:187-196 (separate 'FFL +${ffl.toStringAsFixed(2)}' only in the exporter); goldens 04/07/09/10 show '+X.X m' with no 'FFL' anywhere on screen.
- **User impact:** An engineer authors and reviews the riser on the canvas, where elevations read '+7.5 m' with no FFL term. The first time 'FFL' (and a different precision) appears is on the exported sheet handed to the client/permit office — a reviewer comparing the working view against the deliverable could suspect a data mismatch, and the engineer has no way to preview the notation that will print.
- **Direction:** Use one shared elevation-label formatter (name, precision, and 'FFL' term) for both the canvas painter and the SldSheet exporter.


## Theme F — Drafting velocity

Where a production drafter is still slower than their AutoCAD muscle memory on a real tower.

### F1. No layer lock — the Select tool can grab and edit another discipline's faded reference elements
**HIGH** · effort M · gap · lens: mep · finders: mep-velocity

The Layout canvas shows non-active disciplines faded-but-visible for coordination, but NetworkSelectionOverlay mounts whenever the active layer is any mechanical discipline, and its hit-test helpers iterate every node/edge on the sheet/floor with zero ServiceType/discipline filter. So while HVAC is active and Plumbing renders faded, a click near a faded pipe selects it and it can be dragged or deleted exactly like an active element. Ctrl+A DOES correctly scope to the active layer — so bulk-select respects the boundary but a single click does not.

- **Evidence:** layer_store.dart:34,55-69,108-115; layout_canvas.dart:917 (mechanicalActive), :1079-1095 (mount gate), :496-511 (Delete handler); selection_overlay.dart:601-654 (_nodeAt/_edgeAt, no service/discipline check, grep-confirmed); Ctrl+A scoping at selection_store.dart:126-161.
- **User impact:** A drafter routing HVAC ducts on a busy coordination floor can accidentally nudge or delete a faded reference pipe belonging to another trade while working near it — no lock, no warning, no visual difference in the drag. The mistake surfaces later as a silently broken plumbing network at sizing/report time, not when it happened.
- **Direction:** Scope NetworkSelectionOverlay's hit-test (and thus select/drag/delete) to elements whose ServiceType belongs to the active DisciplineLayer, matching the servicesFor(activeDiscipline) filter Ctrl+A already uses — a faded coordination element becomes visible-but-inert until its own layer is active.


### F2. No rotate or mirror for pasted selections, arrays, or saved assemblies
**HIGH** · effort L · gap · lens: mep · finders: mep-velocity

The group-move primitive (moveMany) only translates by (dx,dy); paste/array/assembly-stamp all place clones with a positional offset only — none accepts a rotation angle or mirror axis. There is no rotate handle in selection_overlay.dart and no rotateSelection/mirrorSelection method anywhere (grepped lib/ for rotate/mirror/flip on node/edge geometry — none).

- **Evidence:** network_store.dart:2007-2029 (paste), :2031-2065 (pasteNCopies), :2095-2130 (stampAssembly), :2187-2210 (moveMany) — none take an angle/flip param; selection_overlay.dart has no rotation handle.
- **User impact:** Real towers routinely mirror core/shaft layouts between adjacent risers or odd/even floors. A drafter who saves a riser-shaft fixture group as an assembly or copies one shaft's WC group to the next cannot flip or rotate it to match a mirrored layout — every mirrored instance is drawn from scratch, defeating the assembly/array tools for exactly the repetitive geometry (8 risers) this persona lives on.
- **Direction:** Add rotate-about-centroid and mirror-about-axis transforms to the clone helper (_cloneClipboard) shared by paste/pasteNCopies/stampAssembly, exposed as an angle/flip param plus a lightweight on-canvas handle or numeric entry.


### F3. 'Duplicate floor to a range' records one undo step per target floor, not one for the whole batch
**MEDIUM** · effort S · friction · lens: mep · finders: mep-velocity

The range-duplicate dialog's own comment admits the limitation: _apply loops net.duplicateFloor(...) once per checked target floor, and each call ends in NetworkController._commit, which pushes its own undo/timeline entry.

- **Evidence:** duplicate_floor_dialog.dart:8-11 (doc comment acknowledging the limitation), :301-324 (_apply loop, one duplicateFloor per target); network_store.dart:1806-1865 (duplicateFloor, single _commit per call at :1861).
- **User impact:** A drafter duplicating one floor's layout to 12 upper floors in one dialog action gets 12 separate undo entries for what they experience as ONE action. If they later press Ctrl+Z once, they silently revert only the last target floor's copy rather than the batch they think atomic — and undoing the whole operation takes 12 presses, easy to over- or under-undo on a real job.
- **Direction:** Batch all target floors' clones into the same nodes/edges list and issue a single _commit (a duplicateFloorToTargets(source, targets) method committing once), so the whole range-duplicate collapses to one undo step.


### F4. Plumbing is one indivisible layer — no isolate for cold/hot/drainage/vent/rainwater individually
**MEDIUM** · effort M · gap · lens: mep · finders: mep-velocity

The unified Layout canvas has exactly 4 toggleable disciplines (DisciplineLayer {plumbing, fire, hvac, electrical}), and disciplineOf folds FIVE distinct ServiceTypes — cold water, hot water, drainage, vent, rainwater — into the single plumbing bucket. layerVisibilityProvider can only show/hide at that bucket granularity; there is no per-ServiceType visibility toggle anywhere.

- **Evidence:** layer_store.dart:34 (4-value enum), :55-69 (disciplineOf mapping 5 ServiceTypes to DisciplineLayer.plumbing), :108-134 (LayerVisibilityController, bucket-level only).
- **User impact:** On a floor with 8 risers, every plumbing service is drawn on the same visual layer at once. A drafter trying to route just the cold-water main can't hide the drainage/vent/rainwater/hot-water lines cluttering the same corridor — unlike AutoCAD's per-layer freeze/isolate, where a drafter routinely isolates one system at a time on a dense MEP floor.
- **Direction:** Add a secondary collapsible per-ServiceType visibility filter scoped to the active DisciplineLayer (a service-chip row under the Plumbing tab: Cold/Hot/Drainage/Vent/Rainwater), reusing the same faded-vs-hidden rendering the discipline layer already has.


### F5. Every terminal / fitting / equipment placement is a one-shot drag from the palette — no click-to-place-repeatedly mode
**MEDIUM** · effort M · friction · lens: mep · finders: mep-velocity

Fittings, terminals, and every equipment component can only be placed by dragging a PaletteCard onto DropOverlay's DragTarget — each drop a separate gesture. The keyboard alternative dropAtCentre always drops at the sheet centre, unusable for a real location. The Enter-repeats-last-tool shortcut only remembers the five _CanvasTool MODES (run/riser/measure/tank/room) — fittings/terminals/components aren't tools in that enum and are never repeated.

- **Evidence:** segment_palette.dart:72-95 (dropAtCentre — sheet-centre only); drop_overlay.dart (drag-and-drop is the only placement path); layout_canvas.dart:85 (_CanvasTool enum excludes point-placement kinds), :642-692 (_armTool/_isIdle scoped to the 5 modes).
- **User impact:** Laying out the first floor's ~40 fixtures (valves, cleanouts, sprinkler heads, diffusers) each requires finding the right palette card (possibly inside a collapsed group) and a full drag gesture to the exact spot — no AutoCAD-style 'insert, then click, click, click' repeat. Duplicate-floor mitigates later identical floors, but the initial floor and any atypical floor pays the full per-item drag cost.
- **Direction:** Let a palette card be 'armed' via a single click/keypress (a lightweight placement mode mirroring the draw-tool armed state), so subsequent canvas clicks place additional copies at the cursor without re-dragging; Esc or picking a new tool exits, matching the existing tool-arming idiom.


### F6. No way to reuse one imported floor plan across multiple repeated building floors
**MEDIUM** · effort M · friction · lens: mep · finders: mep-project-lifecycle

Duplicating a drawn network onto another floor ('Duplicate to…') only works if that target floor already has its OWN imported Sheet — there is no action to place the SAME already-imported plan (e.g. a repetitive-tower 'typical floor' PDF) onto a second floor without re-running the OS file picker.

- **Evidence:** duplicate_floor_dialog.dart:257-264 (disables a target checkbox with a 'no plan' note whenever sheetByFloor has no entry); sheet_rail.dart:566-579 (per-sheet context menu offers Rename/Assign floor/Calibrate/Replace plan/Duplicate to/Remove — no 'duplicate this sheet's source onto another floor').
- **User impact:** On a real tower where floors 2-19 share one identical architectural 'typical floor' PDF, the engineer must re-open the OS file picker and re-import that same file 18 separate times (each a distinct Sheet) before 'Duplicate floor to…' can even copy the drawn MEP network across them — a purely mechanical repetitive step the app could do in one action.
- **Direction:** Add a 'Duplicate sheet to floor…' context-menu action that clones the current sheet's source reference (path + page + size) onto a chosen floor as a new Sheet — no re-import dialog — then let the existing 'Duplicate to…' flow copy the network onto it.
- **Verification note:** corrected evidence: lib/ui/shell/duplicate_floor_dialog.dart:257-264 (not sheets/); lib/ui/sheets/sheet_rail.dart:569-577


## Theme G — Deliverable fidelity - mechanical drawings

What still forces the mechanical drafter to redraw the sheet in AutoCAD before issuing it.

### G1. Mechanical equipment on the plan carries no tag — cannot be told apart or cross-referenced
**HIGH** · effort L · gap · lens: mep · finders: mep-plan-output

NetNode has no name/tag field at all. The on-canvas glyph and the export symbol library draw only the equipment SYMBOL — a pump is a circle-with-impeller, a tank a rectangle, with nothing identifying which pump. The equipment schedule synthesises tags like 'P-01'/'AHU-1' only at export time from a running count, never written back to the drawing. On the same unified Layout canvas an electrical panel DOES carry a rendered name ('MDP' chip) — a direct M vs E inconsistency in the 'one product' convergence.

- **Evidence:** network.dart:309-378 (NetNode field list, no tag); network_layer.dart:869-890 (_componentGlyph draws only the symbol chip); equipment_schedule.dart:44 (tags synthesised at export); golden 06_electrical_layout.png shows the panel's 'MDP' label on-canvas.
- **User impact:** A consultant reviewing the issued mechanical plan sees an unlabeled pump icon next to an unlabeled tank icon with no way to tell 'P-1' from 'P-2', and cannot cross-check the plan against the equipment schedule/BOM line items — a routine QA step — because nothing on the drawing points at a schedule row.
- **Direction:** Add an optional NetNode.tag, editable in the node inspector (mirroring ElectricalPanel's name), render it as a small leader label beside the plan glyph in canvas + all three exporters, and feed it into buildEquipmentScheduleRows so an explicit tag beats the synthesized fallback.


### G2. Hot-water recirculation loop has no visual representation on the riser diagram
**HIGH** · effort L · gap · lens: mep · finders: mep-riser-quality

The engine sizes a full hot-water recirculation loop (circulating flow, loop friction, recirc pump, Legionella check) and prints it as report text, but the Network model has no ServiceType/edge concept for a 'return' leg — NetEdge carries no isReturn/loop flag. The auto single-line therefore draws a hot-water riser as a dead-end supply run even where the report describes a live recirculation loop with a named pump and flow rate.

- **Evidence:** network.dart:11-22 (ServiceType enum — no return-leg variant) and :495-526 (NetEdge fields, no return/loop flag); solve_store.dart:348 calls sizeHotWaterRecirculation but nothing downstream creates geometry; calc_report.dart:343-346 prints recirc only as text. No return-riser reference in schematic_view.dart or mechanical_sld_drawing.dart.
- **User impact:** A plumbing engineer on any building with hot-water recirculation (hotels, hospitals, apartments — this app's target buildings) opens the Riser/Auto sheet expecting a supply + return loop with per-floor balancing valves (the H-102 convention) and instead sees a plain dead-end riser. With no way to even draw a return leg, they must redraw the entire hot-water riser in AutoCAD to submit a credible permit sheet.
- **Direction:** Add a distinguishable hot-water-return edge/service (or a boolean on the hot-water edge) so the recirc loop the engine already sizes can be drawn as a second riser with balancing-valve nodes, at least behind the existing 'Details' toggle.


### G3. Auto-generated PUMP-SET DETAIL omits the suction/discharge valve train the app already models elsewhere
**MEDIUM** · effort M · inconsistency · lens: mep · finders: mep-riser-quality

The riser sheet's PUMP-SET DETAIL callout draws only a roof-tank glyph and a pump glyph with GRAVITASI/BOOSTER/TRANSFER text — no check valve, isolation gate valves, strainer, pressure gauge, or flexible joint — even though the engine has NodeComponent.checkValve/gateValve/strainer and draws exactly that valve train in the neighbouring generic DETAIL WATER METER and DETAIL PRV SET boxes on the same sheet. No design-issue check flags a missing check valve at a pump discharge either.

- **Evidence:** mechanical_sld_drawing.dart:676-760 (_emitPlantDetail: only roofTank/pump glyphs + text) vs :654-674 (_emitDetailBox: a real glyph-row valve train) called at :386-398; schematic_view.dart:2444-2544 vs 2551-2598; golden 09_single_line_symbols.png shows the PUMP-SET box with only a tank + pump icon next to two boxes each showing four connected valve/meter glyphs.
- **User impact:** The pump set is the single most safety- and reliability-critical assembly on an air-bersih riser sheet (isolation for maintenance, backflow prevention, priming). A drafter has to hand-add the entire suction/discharge valve arrangement in AutoCAD because the auto-generated detail is just clip-art icons, while less-critical generic callouts got the full treatment.
- **Direction:** Extend _emitPlantDetail to draw a standard suction (strainer + gate valve) / discharge (check valve + gate valve + pressure gauge) glyph row using the same _emitDetailBox machinery already used for the water-meter/PRV callouts.
- **Verification note:** severity adjusted high -> medium by the adversarial verifier


### G4. Drainage/vent/rainwater risers get none of clean water's reference-detail treatment, and there is no STP/septic/sewer terminus symbol
**HIGH** · effort L · gap · lens: mep · finders: mep-riser-quality

All detail callouts are gated to focus==null/coldWater/hotWater; switching the toolbar filter to Drainage/Vent/Rainwater shows none of them. There is also no NodeComponent for a septic tank, STP, grease trap, or inspection chamber, so a drainage riser simply stops at the last drawn node with no 'to STP'/'to city sewer' terminus mark. The decisions log confirms the STP process-flow diagram was queued and never built.

- **Evidence:** mechanical_sld_drawing.dart:375-400 (detailCallouts gated by waterFocus); network.dart:106-158 (NodeComponent has roofDrain/floorDrain/cleanout but no septic/STP/grease-trap); MEP-PDF-Sizing-Tool-Build-Plan.md:420 ('the STP process-flow diagram — queued').
- **User impact:** For any building outside a municipal-sewer catchment (the majority in Indonesia), the air-kotor riser sheet is exactly what a permit checker inspects first for a septic/STP connection and discharge detail. Right now that sheet ends abruptly with no terminus symbol, and switching to Drainage loses even the generic reference-detail chrome the water systems get — the drafter builds this part from scratch outside the app.
- **Direction:** Add a septic/STP/inspection-chamber NodeComponent so a drawn discharge point renders a real terminus glyph + label, and extend the detail-callout gate to include a drainage-focused reference box (e.g. DETAIL BAK KONTROL / SEPTIC TANK) mirroring the clean-water pattern.


### G5. Drainage/vent/rainwater runs never show their fall/slope on the plan
**MEDIUM** · effort S · gap · lens: mep · finders: mep-plan-output

SizingContext.drainageSlope is a single project-wide gradient fed into drainage sizing and checked for self-cleansing risk, but EdgeSizing never carries the slope value forward. The plan label routines print only 'DN100' or 'DN100 - 3.5 m' for every service, gravity or pressurized alike.

- **Evidence:** network_sizing.dart:90-115 (EdgeSizing has no slope field) and :301,757 (drainageSlope used only inside the solve); drainage_advisory.dart:62-93 (value already computed and judged); plan_pdf_export.dart:49-55 / dxf_export.dart:23-29 (label never includes it).
- **User impact:** A drafter issuing the 'Diagram Air Kotor' (soil/waste plan) cannot show installers the required fall for each branch on the drawing itself — every gravity run reads identically to a pressurized cold-water run except for its colour, despite the app already computing and internally checking that exact slope value.
- **Direction:** Append '@ 1:N' to the size label for gravity-regime (drainage/vent/rainwater) edges using the ctx.drainageSlope already in scope at label-build time, in canvas and both plan exporters.


### G6. No isolation valve is drawn, suggested, or flagged missing at a floor's riser branch takeoff
**MEDIUM** · effort M · gap · lens: mep · finders: mep-riser-quality

The per-floor branch fan-out (floorFanOuts) renders only plain fixture-name text stubs with no valve glyph, and unlike the drainage-stack cleanout check (drainageStackBasesLackingCleanout), there is no equivalent advisory anywhere for a floor tee lacking an isolation gate valve.

- **Evidence:** riser_tags.dart:452-494 (floorFanOuts only emits label text) contrasted with :389-399 (drainageStackBasesLackingCleanout, a real advisory for the equivalent drainage case); no gateValve/checkValve reference in design_issues_store.dart.
- **User impact:** A real air-bersih riser sheet shows a gate valve at every floor branch off the main riser for isolation/maintenance. Because the tool neither auto-places nor flags its absence (while it does exactly this for drainage cleanouts), a drafter has no signal distinguishing 'valve genuinely omitted by design' from 'engineer simply forgot it' — and the omission is invisible until a permit reviewer catches it.
- **Direction:** Mirror the drainage-cleanout advisory: add a floor-branch-lacking-isolation-valve check surfaced in Review, following honesty-by-construction (only flag, never fabricate a valve on the drawing).
- **Verification note:** corrected evidence: riser_tags.dart:464-494 (floorFanOuts emits label text only; finding cited 452-494); riser_tags.dart:389-399 (drainageStackBasesLackingCleanout); design_issues_store.dart:477-488 (cleanout advisory wired, no valve equivalent)


### G7. Generic DETAIL WATER METER / DETAIL PRV SET boxes draw unconditionally regardless of whether the project has those components
**LOW** · effort S · inconsistency · lens: mep · finders: mep-riser-quality

_emitDetailBox for the water-meter and PRV reference assemblies fires whenever 'Details' is on and the focus is water-related, with no check for whether the network actually contains a waterMeter or prv NodeComponent — unlike the neighbouring PUMP-SET DETAIL, which correctly gates on hasRoof/hasGround/hasPump before drawing.

- **Evidence:** mechanical_sld_drawing.dart:378-400 (unconditional draw inside the waterFocus branch) vs :684-705 (_emitPlantDetail's has()-gated early return); schematic_view.dart:2551-2598 (_paintValveCallouts, same unconditional pattern).
- **User impact:** A project with no PRV zoning at all still shows a 'DETAIL PRV SET' box on its permit sheet, indistinguishable from a project where a PRV is genuinely specified. A checker reading the sheet cold cannot tell boilerplate reference content from an as-designed detail, undermining the honesty-by-construction the rest of the sheet builds.
- **Direction:** Gate the water-meter/PRV reference boxes on the same has(NodeComponent...) pattern used for the plant detail, or clearly mark them 'TYPICAL' when no matching component is drawn.


## Theme H — Deliverable fidelity - electrical drawings

What still keeps the electrical schedule and single-line short of a buildable, issuable Diagram Panel.

### H1. No plan-accurate electrical layout export — only schematic single-lines
**HIGH** · effort L · gap · lens: mep · finders: mep-plan-output

The unified Layout canvas lets an engineer place electrical panels/loads at real x,y on the calibrated floor-plan underlay (golden 06 shows an 'MDP' panel + outlet/meter glyphs on the plan). But every electrical export is schematic: single-line, power one-line, overview, and floor-by-floor riser — none reads ElectricalPanel.x/y plus the floor-plan underlay to produce a position-accurate plan. The mechanical side has planToPdf/networkToDxf for exactly this; there is no electrical equivalent.

- **Evidence:** electrical_export.dart:79-357 (10 export functions, all schematic — grep confirms no layout/position exporter); golden 06_electrical_layout.png shows placement on the real plan; plan_pdf_export.dart / dxf_export.dart only accept a mechanical Network, never an ElectricalProject.
- **User impact:** An engineer who spends time placing sockets, lights, and panels on the real floor plan (the workflow the app promotes) gets zero printable output of that placement. For a submittal they fall back to the abstract single-line, which has no floor coordinates a contractor could use to install conduit, boxes, or fixtures — the one drawing type (denah instalasi listrik) every Indonesian building-permit electrical set requires is missing.
- **Direction:** Add an electricalLayoutToPdf/Dxf exporter mirroring planToPdf — draw the existing LoadSymbol/IEC glyph set at each panel/load's real x/y over the same floor-plan underlay + drawing_chrome frame/title-block/legend already shared by the mechanical exporters.


### H2. RCD/RCBO protection is invisible on the panel schedule and single-line drawing
**HIGH** · effort S · gap · lens: mep · finders: mep-electrical-quality

The engine fully computes per-circuit RCD requirements (RcdSpec: required/ratingMa/type) and the Markdown calc report prints them in a dedicated column, but the drawn panel schedule/single-line never renders any RCD/RCBO notation — not in the DEVICE cell, not as a symbol, not in the legend. A kontraktor or permit reviewer working from the issued Diagram Panel (the normal practice) has no way to see which ways need a 30/100/300 mA RCD or its type.

- **Evidence:** electrical_sld_drawing.dart:347-407 (DEVICE cell = breakerScheduleLabel + optional starter only; grep for 'rcd' returns zero). Contrast electrical_calc_report.dart:297-299 (renders c.rcd.required/ratingMa/type). Goldens 05_electrical.png and 11_electrical_schedule.png: every way shows only 'MCB 16A 1ph'-style cells with no RCD marking despite TT/earthing content.
- **User impact:** An electrical engineer preparing a permit/tender Diagram Panel omits life-safety RCD placement from the one document the contractor wires from; the contractor either misses required RCDs (a code-compliance and safety defect) or the engineer re-derives and hand-annotates RCD placement in a separate tool before issuing.
- **Direction:** Append the RCD spec to the DEVICE cell (e.g. '· RCBO 30mA' / '· RCD 300mA S') exactly as the starter token is appended, gated on circuit.rcd.required, and add an 'RCD/RCBO' row to the device legend.


### H3. Breaker short-circuit rating (Icu, kA) shows on the PDF/DXF export but never on the live canvas the engineer designs against
**MEDIUM** · effort S · inconsistency · lens: mep · finders: mep-electrical-quality

The interactive single-line canvas board schedule builds its sheet via buildElectricalPanelDetail with no breakerIcuKaByPanelId argument, so the kA suffix on every incomer/way breaker is always blank on-screen. Only the PDF/DXF export path re-builds the sheet with breakerIcuKaByPanel(ref). The busbar withstand figure ('Icw 19.0kA') IS always shown on-canvas (a different always-on Fold-1 computation), creating a half-populated, inconsistent withstand story on screen.

- **Evidence:** electrical_canvas.dart:1161-1165 (_sheet getter calls buildElectricalPanelDetail with no breakerIcuKaByPanelId) vs electrical_export.dart:87-91/:116-122 (breakerIcuKaByPanel(ref) passed only at export); electrical_sld_drawing.dart:238-242 derive kaSuffix solely from that map. Goldens 05/11 show 'Icw 19.0kA' on the busbar but no kA on the incomer or any way DEVICE cell.
- **User impact:** An engineer reviewing/adjusting breaker selections in-app (the primary design loop) cannot see whether a chosen MCB/MCCB meets the required breaking capacity at that board — the check only becomes visible after exporting a PDF, so a design error surfaces late instead of during editing.
- **Direction:** Thread the same breakerIcuKaByPanel(ref) map into the canvas's _PanelScheduleBody._sheet getter (via electricalAdvancedProvider) so the live and exported schedules agree.


### H4. CT ratio for revenue metering is computed but never reaches the drawing or the UI
**MEDIUM** · effort S · gap · lens: mep · finders: mep-electrical-quality

electrical/metering.dart (meterFor) already selects a real CT ratio (e.g. '150/5') and accuracy class ('0.5S') once a board's demand exceeds the 100 A direct-metering limit, threaded into AdvancedStudy.metering. But the panel schedule's incomer metering cluster hard-codes the literal 'CT' with no ratio, and the in-app Advanced-study row prints only meter.metering.label ('direct'/'ct'), never the ratio or class.

- **Evidence:** electrical_sld_drawing.dart:286-297 emit SldLabel(...,'CT',size:8) — a bare literal, no MeteringSpec reference in that file. electrical_view.dart:1741/1748 read advanced.metering[panel.panelId] but surface only meter.metering.label. metering.dart:41-107 show ctPrimaryA/ctRatio/ctClass fully computed and unused outside advanced_study.dart.
- **User impact:** For any board over 100 A demand (a common MDP on a real commercial project), the kontraktor procuring the CT-operated kWh meter set has no ratio on the drawing or in the app and must work it out by hand even though iSystem already derived the correct standard ratio.
- **Direction:** Replace the bare 'CT' label with the resolved meterFor(p.demandCurrent).ctRatio (fallback 'CT' when direct) and print the ratio/class in the Advanced-study row too.


### H5. Riser fan-out truncates circuit names mid-word with no ellipsis, producing garbled labels on an issued drawing
**MEDIUM** · effort S · clarity · lens: mep · finders: mep-electrical-quality

buildElectricalRiser's per-floor branch fan-out hard-truncates a way's name to 14 chars with a bare substring(0,14) and no ellipsis or word-boundary awareness, so 'Power socket ring — workshop' becomes 'Power socket r' and 'Lighting - Level 1' becomes 'Lighting - Lev'.

- **Evidence:** electrical_sld_drawing.dart:1538: 'final nm = cr.name.length > 14 ? cr.name.substring(0, 14) : cr.name;'. Visible in golden 10_electrical_riser.png: the Ground MDP fan-out reads 'Power socket r 16A', the Level-1 fan-out 'Lighting – Lev 10A' twice.
- **User impact:** A permit reviewer or contractor reading the issued floor-by-floor riser sees what looks like a typo or data-entry error ('socket r', '...Lev') rather than an intentional abbreviation, undermining confidence in an otherwise professional deliverable; the engineer can't fix it short of renaming the circuit.
- **Direction:** Truncate at a word boundary and append an ellipsis when cut (e.g. 'Power sock…'), or shrink the font/allow two lines, matching the KETERANGAN column's un-truncated treatment.


### H6. Large-CSA feeder cables silently drop all route/containment notation
**MEDIUM** · effort S · gap · lens: mep · finders: mep-electrical-quality

_conduitMm returns null once conductor CSA exceeds 70 mm² (where real installations move from conduit to cable tray/ladder), and the PENGHANTAR cell then prints nothing for the route — not even a generic 'tray' fallback — while every smaller way shows '· PVC NNmm'. The code's own comment says these cables 'run on tray/cable-ladder' but nothing is printed to say so.

- **Evidence:** electrical_sld_drawing.dart:132-152 (_conduitMm returns null above the 70 mm² rung) and :369-372 (conduit = conduitMm != null ? '· PVC ${conduitMm}mm' : '').
- **User impact:** On any real building where the main incomer or a large feeder exceeds 70 mm², that row silently loses its route method while its neighbours keep theirs — inconsistent presentation reads as an omission, and the engineer must annotate cable-tray routing for that run in AutoCAD before issue.
- **Direction:** When _conduitMm returns null, print an explicit fallback token (e.g. '· tray') so every row states a route method.


### H7. Phase-imbalance percentage is computed but never printed on the panel schedule itself
**LOW** · effort S · gap · lens: mep · finders: mep-electrical-quality

ElectricalPanelResult.imbalancePercent is computed and rendered in the Markdown calc report's per-panel phase-balance bullet, but the drawn schedule's TOTAL footer only prints the raw R/S/T amperes with no % imbalance figure.

- **Evidence:** electrical_calc_report.dart:259-264 print imb: _n(p.imbalancePercent) in the Markdown-only phase-balance line. electrical_sld_drawing.dart:427-441 (TOTAL footer) print only bold R/S/T amp values, no imbalance %.
- **User impact:** A reviewer checking only the issued single-line (the document actually submitted for permit) sees raw per-phase amps and must mentally compute imbalance to judge whether the design meets good-practice phase-balance limits, when the number is already available.
- **Direction:** Add a small 'Imbalance X%' label beside the TOTAL row's R/S/T figures on 3-phase panels, reusing the already-computed p.imbalancePercent.


## Theme I — Engineering trust and sign-off

What stops the licensed engineer from signing: results they cannot interrogate, checks that never reach the verdict, acknowledgements with no audit trail.

### I1. Pressure-zone over-limit check never reaches the compliance verdict
**HIGH** · effort S · gap · lens: mep · finders: mep-trust

The engine computes a real PRV/pressure-zone check (zonesProvider/zoneStaticsProvider against SniProfile.maxFixtureStaticPressure) and shows an OK/over verdict inline for downfeed buildings, but it is never fanned into designIssuesProvider or complianceSummaryProvider, so an over-pressure zone can never fail the Review-hub sign-off. For the upfeed (pump) strategy — arguably more common in Indonesian mid/high-rise — the inspector doesn't even show a pass/fail verdict, only a bare zone count, though the same zonesOk boolean is already computed in the same widget.

- **Evidence:** solve_store.dart:262-282 (zonesProvider/zoneStaticsProvider); project_panel.dart:2763 (zonesOk computed), :2796-2804 (verdict shown only for downfeed), :2886 ('Pressure zones' count, no verdict for upfeed); design_issues_store.dart and compliance_store.dart have no 'zone' match; golden 12_review_hub.png shows 7 compliance rows, pressure zoning absent.
- **User impact:** A licensed engineer reviewing the Review hub before signing sees only 7 named checks and could read a near-clean board as compliant, while a real max-fixture-static-pressure violation (an SNI 8153:2015 safety concern) sits invisible unless they are on downfeed AND manually scroll the Layout inspector's Results section. Upfeed projects get no signal at all.
- **Direction:** Fan zoneStatics/zonesOk into designIssuesProvider as a warning (locatable to the worst zone's floor) regardless of feed strategy, and add a 'Pressure zoning' row to complianceSummaryProvider so an over-limit zone blocks PASS the same way an uncalibrated sheet does.


### I2. The pressure heatmap has no absolute reference and no per-node readout — it cannot answer 'does this fixture pass?'
**HIGH** · effort M · gap · lens: mep · finders: mep-trust

The heatmap color-ramps residual pressure using ONLY the current view's own min/max — it is never anchored to the SNI target residual or max static pressure thresholds that define pass/fail. Its legend prints just two numbers with no code-limit marker. There is no way to read an exact value at a point: the layer is wrapped in IgnorePointer, no hover/tap probe exists, and selecting a node never surfaces its residual pressure (only a single downfeed 'Top residual' aggregate).

- **Evidence:** heatmap_layer.dart:33-53 (locally-normalized min/max), :55 (IgnorePointer), :94-159 (legend has no threshold reference); golden 03_heatmap.png legend reads 'Residual pressure — Uniform 31 kPa' with no PASS/FAIL cue; no residual-value display in the project_panel node editor (aggregate only at :2865-2866).
- **User impact:** The heatmap is marketed as the verification tool for the pressure solve, but an engineer trying to confirm 'is the top-floor bathroom fixture at or above the SNI minimum residual' gets only a relative red-to-teal gradient with no numeric value at that point and no code threshold — they must trust the aggregate and cannot independently spot-check a fixture from the visual tool built for exactly that.
- **Direction:** Anchor the ramp's color scale to the target residual / max static pressure (not local min/max), add a threshold tick on the legend, and add a click-to-probe readout (or at minimum print the selected node's residual pressure in its inspector row).


### I3. Water/drainage pipe velocity — a code-driven sizing input — is never displayed anywhere in the app or the calc report
**HIGH** · effort S · gap · lens: mep · finders: mep-trust

SNI 03-7065-2005's max supply velocity is now sniVerbatim and drives auto-sizing, but the resulting velocity for a pressurized pipe is invisible everywhere. Selecting a water/drainage edge shows kind/length/size/material only; the velocity readout is gated behind if(edge.service.isAir), so it appears only for air ducts. A repo-wide 'm/s' search under lib/ui/ turns up only four hits, all air. The calc report never mentions velocity; its BOM prints only service/type/size/length/segment-count.

- **Evidence:** project_panel.dart:3958-3973 (velocity block gated on edge.service.isAir); grep 'm/s' across lib/ui/ → only :2342,2347,2352,3963 (all air); calc_report.dart has no 'velocity' in its BOM/water-supply sections.
- **User impact:** A plumbing engineer who must certify every cold/hot-water run stays within the SNI velocity band has no way to see the velocity the auto-sizer used for any pipe — not on canvas, inspector, or deliverable. They'd have to re-derive it by hand from flow and diameter, defeating the purpose of an auto-sizing tool for the one figure that gates water-pipe compliance.
- **Direction:** Surface sizing.velocity for every service (not just air) in the edge inspector, and add a velocity column (or a flagged-only summary) to the calc report's BOM/water-supply section.


### I4. Advisory acknowledgement — the mechanism that makes PASS reachable — has no author, timestamp, or justification
**MEDIUM** · effort S · gap · lens: mep · finders: mep-trust

AcknowledgedIssuesController stores a bare Set<String> of issue keys, persisted as a plain List<String>. Acknowledging an unverified-standard advisory is a single tap with no confirmation or reason field, and the UI promotes bulk dismissal via a one-click 'Acknowledge all' (doc comment: 'the fast path to a reachable PASS'). The separate document-control preparedBy/checkedBy/approvedBy fields are project-level free text, disconnected from which specific advisories were accepted, by whom, or why.

- **Evidence:** design_issues_store.dart:638-663 (Set<String>, no metadata); project_document.dart:173,259-260,327-328 (acknowledgedIssueKeys round-trips as plain strings); issues_card.dart:199-215 (one-click acknowledge / acknowledge-all, no reason); document_control_store.dart:22-58 (preparedBy/checkedBy/approvedBy separate, unlinked).
- **User impact:** A licensed engineer signing a deliverable that relies on acknowledged advisories to reach PASS has no durable record of who decided an unverified SNI/PUIL value was acceptable, or their rationale — under later audit or handover the acknowledgement looks like an unexplained checkbox anyone (or a script) could have flipped, undermining the trust the sign-off feature is meant to establish.
- **Direction:** Attach a required short justification note (and the DocumentControl preparer/checker name + save-time timestamp) to each acknowledgement, persisted per-key, and print the accepted list with its justification in the calc report's compliance section instead of only a bare count.


### I5. The calc report's Bill of Materials cannot show which sizes were manually overridden, and never breaks results out per run
**MEDIUM** · effort M · gap · lens: mep · finders: mep-trust

NetEdge.sizeOverride is a bare Diameter? with no reason/flag distinguishing a manual override from an auto-sized result, and BomLine carries no override indicator either. The calc report's BOM table is aggregated strictly by (service, size) — total length and segment count only — with no per-edge listing. The inspector shows '(set)' next to an overridden edge's size, but that fact is dropped when the BOM/report is built.

- **Evidence:** network.dart:515 (sizeOverride, no reason field); bom.dart:18-37 (BomLine has no override flag); calc_report.dart:515-541 (BOM aggregated by service+size only); project_panel.dart:3936-3937 ('(set)' shown in inspector only).
- **User impact:** If a drafter forces a pipe to a larger/smaller diameter than the auto-sizer chose (overriding the SNI-driven result), the signed calc report and BOM present that pipe identically to every code-derived one — a reviewing engineer or later auditor has no way to find from the deliverable that a human override occurred, only by reopening the project and clicking through every edge.
- **Direction:** Carry an isOverride (or reason string) through BomLine/the report, and add a short 'Manual overrides' sub-table to the calc report listing each overridden edge's auto-computed vs final size.


### I6. The title-block Revision tag and the Revision-history table are two disconnected fields with no cross-check
**MEDIUM** · effort S · gap · lens: mep · finders: mep-project-lifecycle

revisionTag (a single free-text field like 'A', stamped on every exported drawing/report) and revisions (an independent list of date+description rows) are edited and persisted completely separately — setRevisionTag and addRevision never reference each other, and no history row carries its own revision letter.

- **Evidence:** document_control_store.dart:87-95 (setRevisionTag) and :138-140 (addRevision) are independent mutations; project_panel.dart:1731-1746 renders the 'Revision' field and the history list side by side with no linkage or validation.
- **User impact:** An engineer logs a new revision-history entry but forgets to bump the Revision field from 'A' to 'B' before exporting — every drawing/report title block then stamps 'Rev A' while the printed revision-history table inside the same PDF lists a later entry, an inconsistency a tender reviewer flags as a document-control failure.
- **Direction:** Give each revision-history row its own revision-letter column, and derive the title-block revisionTag from the latest history row (or warn inline when they disagree) instead of keeping two independently-typed fields.


### I7. Two fire-protection verdict strings leak hardcoded English into the Bahasa Indonesia calc report
**LOW** · effort S · inconsistency · lens: mep · finders: mep-trust

SprinklerRemoteAreaResult.verdict and FirePumpRatingResult.verdict return hardcoded English literals ('Remote head OK'/'under-pressure', 'Oversized pump curve'/'within standard range') from the pure-Dart engine. calc_report.dart passes them straight through as raw format substitutions rather than routing them through the localized ReportStrings/RptStringKey mechanism the way the analogous zone verdict is.

- **Evidence:** fire_sprinkler_hydraulic.dart:141-143; fire_pump_rating.dart:155-157; calc_report.dart:413,439 (raw ra.verdict/fp.verdict) vs :375-376 (localized verdictOk/verdictOver in the same file).
- **User impact:** An engineer issuing the report in Bahasa Indonesia (a shipped feature) sees two English sentences embedded in the Fire Protection section of an otherwise-Indonesian document — a small but visible polish gap in a document submitted to an Indonesian authority under the engineer's signature.
- **Direction:** Replace the two engine-level verdict getters with a boolean (meetsMinimumPressure / oversized, both already exist) and let calc_report.dart pick the localized RptStringKey the same way it does for zone verdicts.


## Theme J — Project lifecycle and coordination

The multi-week reality: plan revisions, submittal completeness, stable identities across exports, and multi-discipline coordination.

### J1. Replacing a mid-project plan revision silently keeps the old scale calibration with no re-verification prompt
**HIGH** · effort M · gap · lens: mep · finders: mep-project-lifecycle

The 'Replace plan…' action swaps a sheet's PDF/DXF/DWG source in place but never touches that sheet's calibration entry, and nothing warns the engineer to re-check scale. Because calibration is keyed by sheet id, a revised architectural PDF (different DPI, shifted title block, different plot scale) silently inherits the OLD meters-per-pixel value and still shows as 'Calibrated' (green check).

- **Evidence:** sheets_store.dart:210-227 (replaceSheetSource copies the new path+size, never touches the calibrations map); project_io.dart:312-362 (replaceSheetPlan, 'only the underlay changes', no scale-recheck); sheet_rail.dart:281 ('calibrated' = has a stored value, not valid for the source); Review hub only flags never-calibrated sheets (golden 12), so a stale-but-present calibration is invisible.
- **User impact:** An MEP engineer mid-project receives Rev B of a floor plan, uses 'Replace plan…' to swap it in (the exact workflow the comments describe), and every downstream run length, pipe/duct size, pressure solve, and BOM quantity is silently computed against the wrong scale — no banner, no dot color change, no Review-hub warning.
- **Direction:** On replaceSheetSource, compare the new source's natural pixel size (and/or a content hash) to the old; if it differs, clear that sheet's calibration (forcing recalibration) or flag it 'calibration unverified since last plan swap' in the Review hub, distinct from 'never calibrated'.


### J2. The one-folder submittal package only bundles the plan drawing for the currently active sheet, not every floor
**HIGH** · effort M · gap · lens: mep · finders: mep-project-lifecycle

'Export submittal package…' is billed as the whole deliverable set, but the annotated plan.pdf/plan.dxf it writes are built from sheets.current only — a single floor. Every other artifact (reports, schedule, BOM, quotation, riser/electrical single-lines) is project-wide, but the actual floor-plan drawings — the thing a tender reviewer checks first — cover just one sheet.

- **Evidence:** project_panel.dart:772-781 (doc comment scopes it to 'the current sheet's annotated plan'); :915-958 (implementation: final sheet = sheets.current; no loop over sheets.sheets), so a 5-floor project's folder gets one plan.pdf/plan.dxf.
- **User impact:** An engineer preparing a multi-floor Indonesian tender clicks the one advertised 'export everything' button, hands the folder to the client, and later finds only the floor they happened to be viewing was exported as a drawing — the rest of the building's plumbing/HVAC/electrical layouts are missing unless they separately switch to each sheet and run 'Export annotated plan' by hand.
- **Direction:** Loop the plan/DXF export over every sheet (or every sheet holding drawn network elements) inside _writeSubmittalPackage, naming each file by sheet, so the bundle is complete for a multi-floor set without extra manual steps.


### J3. Equipment-schedule tags (AHU-01, AHU-02…) are re-synthesized from room list order every export, not from stable room identity
**HIGH** · effort S · inconsistency · lens: mep · finders: mep-project-lifecycle

Each room carries a stable id, but the equipment schedule assigns AHU-NN tags by counting through roomAreasProvider in list order at export time (ahuSeq++). Deleting, reordering, or adding an earlier room between revisions silently shifts every subsequent AHU's tag number, even though the physical unit and its RoomArea.id haven't changed.

- **Evidence:** equipment_schedule.dart:43-45 (tags synthesized sequentially); project_panel.dart:499-518 (var ahuSeq = 0; for(final r in rooms){...; ahuSeq++; tag:'AHU-${...}'}) — driven purely by iteration position, never r.id.
- **User impact:** An engineer issues the Rev A schedule/BOM for procurement (AHU-03 ordered for the server room), later deletes/reorders an earlier room, regenerates for Rev B, and the server room's unit is now silently AHU-02 — same duty, different tag, no diff or warning, breaking traceability between what was ordered/installed and the latest documents.
- **Direction:** Derive the AHU tag suffix from a stable sort key (the room's persisted id, or a first-assigned index cached on the RoomArea) instead of live list position.


### J4. Duplicate floor silently drops any equipment node not wired into a run
**LOW** · effort S · gap · lens: mep · finders: mep-velocity

NetworkController.duplicateFloor only iterates edges with e.kind == EdgeKind.run and clones just the nodes those edges touch; it never copies a free-standing component node (e.g. a fire extinguisher, hose reel, or an AC unit placed before its duct is routed) that carries no run edge yet. The dialog subtitle ('only the runs are replicated') discloses this but doesn't call out that unconnected EQUIPMENT specifically vanishes.

- **Evidence:** network_store.dart:1806-1865 (loop filters to EdgeKind.run, no fallback for isolated component/fixture nodes); duplicate_floor_dialog.dart:184-186 (disclosure text).
- **User impact:** On a floor where fire-safety or AC equipment was placed but not yet piped/ducted (a common mid-drawing state), duplicating that floor to the other 19 floors silently omits those items floor by floor, with no per-target warning or count discrepancy — the gap is only noticed later when the BOM or fire-protection review comes up short.
- **Direction:** Extend duplicateFloor to also clone any node on the source floor carrying a NodeComponent with zero incident edges (mirroring the run-clone path), and surface a count of 'N components + M runs copied' so an omission is visible.
- **Verification note:** corrected evidence: lib/store/network_store.dart:1845-1865 (run-only clone loop); lib/ui/shell/duplicate_floor_dialog.dart:184-186 (disclosure text — finder's lib/ui/canvas path is wrong)


### J5. No spatial clash/coordination check between disciplines sharing the same calibrated plan
**LOW** · effort L · gap · lens: mep · finders: mep-project-lifecycle

The unified Design Issues panel only checks network TOPOLOGY (loose ends, orphans, unfed panels, unverified standards) — nothing checks geometric overlap between elements of different disciplines drawn on the same calibrated sheet (e.g. an electrical panel dropped on a drain run, or a duct crossing an annotated beam/shaft).

- **Evidence:** connectivity.dart:1-19 (scope is exactly noSource + disconnectedIsland); a repo-wide search for clash/overlap/collision logic across connectivity.dart and design_issues_store.dart returns nothing.
- **User impact:** Since Layout is explicitly one shared canvas where Plumbing/Fire/HVAC/Electrical are toggleable layers on one PDF (the stated M+E+P convergence), a mechanical and electrical engineer working the same building have no automated signal when their elements physically collide in the same space — coordination relies entirely on the ghosted/faded visual check, easy to miss on a busy sheet.
- **Direction:** Add an opt-in geometric-proximity pass (same-sheet, same-floor, cross-discipline elements within N pixels) surfaced as a low-severity 'possible clash' Design Issue — advisory only, never blocking, consistent with the app's judge-only-layer pattern.


## Theme K — Performance-feel on real projects

The app is fast on the demo network and was never profiled on a 20-storey model; the architecture recomputes far more than it must, on the UI thread. (Territory identified by the completeness critic — never covered by any prior campaign.)

### K1. Every node-drag frame re-runs the entire network sizing + pressure solve + BOM pipeline synchronously on the UI thread
**HIGH** · effort L · gap · lens: apple+mep · finders: extra:Performance-feel & responsiveness on large real-world projects

onPanUpdate calls NetworkController.moveNode on every pointer-move event during a node drag, publishing a brand-new Network each frame. sizingProvider and solveProvider/downfeedProvider are plain (non-debounced, non-memoized) Riverpod Providers that watch the whole network and recompute autoSizeNetwork + the full pressurized/downfeed solve (incl. up-to-500-iteration Hardy-Cross balancing for any looped component) from scratch on every one of those frames. The inspector's 'Results'/'Design inputs' sections (project_panel.dart _ResultsSection/_SizingSection) unconditionally ref.watch(solveProvider/downfeedProvider/pumpDutyProvider/zonesProvider/zoneStaticsProvider/bomProvider/fittingsProvider/hotWaterRecircProvider/sizingProvider) in their build() methods, and defaultExpanded is `hasNetworkResults` — true for any real, sized project. Collapsing the right inspector (CollapsibleInspector) does not stop this: the child widget stays mounted (only faded via AnimatedOpacity), so the watches keep firing regardless of panel state.

- **Evidence:** lib/ui/canvas/selection_overlay.dart:376-389 (onPanUpdate -> ctrl.moveNode every frame); lib/store/network_store.dart:2172-2185 (moveNode always replaces state.network); lib/store/sizing_store.dart:53-150 (sizingProvider watches networkControllerProvider, calls autoSizeNetwork unconditionally); lib/store/solve_store.dart:41-61 and 65-85 (solveProvider/downfeedProvider watch sizingProvider, run a full solve every recompute); lib/ui/inspector/project_panel.dart:2742-2818 (_ResultsSection watches 8 solve/BOM providers, defaultExpanded: hasNetworkResults); lib/ui/inspector/collapsible_inspector.dart:67-75 (collapsed inspector keeps `child` mounted via AnimatedOpacity, not removed from the tree); packages/mechx_engine/lib/network/hardy_cross.dart:69 (maxIterations 500 per looped component per recompute).
- **User impact:** On a real 20-40 floor highrise submittal (hundreds of nodes/edges across all floors, the exact target project), dragging a single fixture or riser node to reposition it will feel laggy/jittery at every frame because the whole multi-floor pipeline (sizing, Hardy-Cross, pressure solve, BOM, fittings, hot-water recirc) re-runs before the frame can render, even though only one node moved. This is felt on the single most common drafting action (nudge a node) throughout the whole session, not just once.
- **Direction:** Debounce/throttle moveNode's live-drag path (e.g. update node position visually every frame but only push into networkControllerProvider's canonical state at a lower cadence or on pan-end + a cheap local-position override for paint), and/or memoize sizingProvider/solveProvider so unaffected branches aren't recomputed on every keystroke of a drag (e.g. only resolve on pan-end, showing stale-but-cached results while dragging).


### K2. Opening a portable .mechx with embedded plans blocks the UI synchronously — the exact freeze Save was already fixed for
**MEDIUM** · effort S · inconsistency · lens: apple+mep · finders: extra:Performance-feel & responsiveness on large real-world projects

gatherSheetAssetsAsync explicitly moved the gzip+base64 embedding work for Save onto an Isolate, with an inline comment calling out 'a real window freeze on a large project' as the reason. rehydrateAssets — the symmetric extraction step run on every Open/crash-recovery — has no such treatment: it gunzip-decodes and synchronously writes every embedded plan to disk (File.writeAsBytesSync) directly on the UI thread. _applyOpenedFile does set a busyProvider label first, but then calls the fully synchronous ProjectDocument.decode + rehydrateAssets inline with nothing to keep pumping frames, so the label appears and the app then hangs rather than showing any real progress.

- **Evidence:** lib/data/project_assets.dart:73-83 (gatherSheetAssetsAsync, Isolate.run, comment 'a real window freeze on a large project'); lib/data/project_assets.dart:99-123 (rehydrateAssets: synchronous gzip.decode + file.writeAsBytesSync per asset, no Isolate); lib/ui/shell/project_io.dart:481-517 (_applyOpenedFile sets busyProvider.set(...) then calls the synchronous `rehydrateAssets(doc)` inline before clearing busy in `finally`).
- **User impact:** A drafter re-opening a portable multi-sheet 30-floor project (several embedded PDF plans, which is exactly what the portable-.mechx feature is for) hits a genuine multi-second freeze on Open with only a static 'Opening project...' label and no animation or way to tell the app hasn't crashed — while the identical amount of work on Save was deliberately made non-blocking.
- **Direction:** Move rehydrateAssets' decode+write loop onto an Isolate.run the same way gatherSheetAssetsAsync does for Save, keeping the busy pill visible for its real duration instead of a frozen label.


### K3. The heatmap's IDW field is recomputed from scratch on every pan/zoom frame, not just when the underlying solve changes
**MEDIUM** · effort S · gap · lens: apple+mep · finders: extra:Performance-feel & responsiveness on large real-world projects

_HeatmapPainter.paint() calls sampleField(...) — an O(rows*cols*nodes) inverse-distance-weighted interpolation — directly inside paint(), and shouldRepaint returns true whenever `transform` changes. Since `transform` is the live pan/zoom viewport (ref.watch(sheetsControllerProvider).viewportFor(sheetId)), panning or zooming the canvas with the heatmap on repaints and fully re-samples the field every frame even though the residual pressure data driving it hasn't changed at all — only the camera moved.

- **Evidence:** lib/ui/canvas/heatmap_layer.dart:174-181 (paint() calls sampleField fresh every invocation) and lib/ui/canvas/heatmap_layer.dart:208-212 (shouldRepaint fires on any transform change); packages/mechx_engine/lib/pressure_field.dart:104-129 (sampleField's nested row/col loop calls idw() per cell, each idw() an O(node-count) weighted sum) with no caching keyed on the residual map itself.
- **User impact:** An engineer reviewing the pressure heatmap on a floor with a non-trivial node count (03_heatmap.png shows the overlay in active use) will feel extra stutter while panning/zooming to inspect different parts of the plan, on top of whatever the underlying drag-driven resolve cost already is — pure wasted work since the camera move alone never changes which cell gets which colour value, only where it's drawn.
- **Direction:** Cache the sampled ScalarField keyed on the `nodes` list (residual values + positions) and only recompute it when that input changes; on a pure transform (pan/zoom) change, reuse the cached field and just redraw its cells at the new screen offsets/scale.


### K4. Autosave fully JSON-encodes the whole project on the UI thread every 15 seconds just to check if anything changed
**LOW** · effort M · gap · lens: apple+mep · finders: extra:Performance-feel & responsiveness on large real-world projects

startAutosave's Timer.periodic callback runs on the main (UI) isolate and unconditionally calls buildDocument(c.read).encode() every tick — a full serialization of the entire project (all floors, all sheets, the whole Network, the electrical sub-model, settings) — purely to compare against the last-saved signature and decide whether to write a recovery snapshot. Unlike the Save path's asset gathering (explicitly offloaded to an Isolate for exactly this class of problem), this per-tick full-document encode has no isolate offload, no incremental diff, and runs regardless of whether the engineer is mid-interaction.

- **Evidence:** lib/data/autosave.dart:291-327 (Timer.periodic every 15s; encoded = doc.encode() runs unconditionally each tick, only the subsequent disk WRITE is skipped when `clean`); lib/data/autosave.dart:97-156 (buildDocument pulls in projectControllerProvider, sheetsControllerProvider, the whole network, electrical project, commercial settings, document control, etc. — the full document graph) run synchronously with no `Isolate.run`/`compute()` anywhere in the file.
- **User impact:** On a large 30-floor project the periodic 15-second autosave tick can produce a brief but perceptible hitch/stutter completely independent of anything the engineer is doing — worse if it lands mid-drag or mid-pan, since it competes with the UI thread for the same frame budget as the already-expensive solve/heatmap work described above.
- **Direction:** Move the per-tick encode+compare off the UI thread (Isolate.run, mirroring gatherSheetAssetsAsync), or maintain a lightweight incremental dirty flag (bumped by the mutation call sites already threading through historyProvider) instead of re-encoding the entire document every 15 seconds to detect a diff.


## Theme L — Keyboard-only operation and accessibility

The custom design system re-implemented buttons and menus but only partially re-implemented focus, keyboard activation, and semantics. (Territory identified by the completeness critic — never covered by any prior campaign.)

### L1. Electrical Loads palette has no keyboard path — Tab+Enter is a dead end
**HIGH** · effort M · gap · lens: apple+mep · finders: extra:Keyboard-only operation & accessibility of the custom design system

Every card in the electrical Loads palette (used both on the standalone Electrical workspace and the unified Layout's Electrical layer) is a `PaletteCard` wrapped in the shared `MechXFocusRing`, so Tab reaches it and the focus ring lights up — but none of them pass `onActivate`, so Enter/Space does nothing. Adding a load/way to a panel is only ever wired through the canvas `DragTarget`'s drop callback; the panel right-click menu has no 'Add way' action either.

- **Evidence:** lib/ui/electrical/electrical_palette.dart:192-208 (PaletteCard<PaletteLoad> instances all omit `onActivate`) vs. lib/ui/canvas/segment_palette.dart:104-105,140-142,160-161,172-173 (every mechanical PaletteCard passes `onActivate: () => dropAtCentre(...)`); lib/ui/electrical/electrical_canvas.dart:690-709 (`_ctrl.addCircuit` is only called from the panel's `onDropLoad`, itself only fed by a drag-and-drop `DragTarget<PaletteLoad>`); lib/ui/electrical/electrical_view.dart:542-618 (`_buildPanelMenu` lists Properties/Open panel/Mark essential/Mark critical/Submeter/Duplicate/Disconnect feeder/Delete — no 'Add way' or 'Add circuit').
- **User impact:** An engineer building an electrical panel with the keyboard (or any pointing device that can click but not drag reliably) can Tab through every load card, see the focus ring, press Enter/Space, and place nothing — there is no fallback anywhere in the Electrical design workspace. Creating a single circuit/way is entirely drag-and-drop-only, which blocks a core task of one of the app's three DESIGN workspaces for anyone not doing a fluid mouse drag.
- **Direction:** Give each `PaletteCard<PaletteLoad>` an `onActivate` (mirroring `SegmentPalette.dropAtCentre`) that adds the way to the currently selected panel, or creates a new panel at a default canvas position when none is selected; also add an 'Add way…' row to the panel context menu (`_buildPanelMenu`) as a second, fully keyboard-reachable path.


### L2. Review-hub compliance actions (Locate / Acknowledge / quick-fix) are mouse-only
**HIGH** · effort S · gap · lens: apple+mep · finders: extra:Keyboard-only operation & accessibility of the custom design system

The Review hub's Issues card — the surface built specifically so an engineer can jump to a flagged element and sign off the design — implements its Locate link, its Acknowledge/Undo action, and its one-click 'quick fix' batch chips as bare `GestureDetector`/`MouseRegion` widgets with no `Focus`/`MechXFocusRing` anywhere in the file.

- **Evidence:** lib/ui/review/issues_card.dart:236-256 (`_AckAction`), :258-293 (`_BatchChip`), :312-399 (`_IssueRow`, the 'Locate' tap target at 381-393) — none import or use `mechx_focus_ring.dart`, unlike lib/ui/shell/workflow_stepper.dart or lib/ui/shell/nav_rail.dart which wrap equivalent tappables in `MechXFocusRing`.
- **User impact:** A keyboard-only user can read the issue list in the Review hub but cannot Tab to a single 'Locate' link, an 'Acknowledge' action, or a quick-fix chip (select-all-velocity-warnings, copy-scale-to-all-uncalibrated-sheets, etc.) — there is no command-palette equivalent for any per-issue or batch action. Reaching a design PASS via advisory acknowledgement, and jumping straight to a flagged element, is unreachable without a mouse.
- **Direction:** Wrap `_IssueRow`'s locate tap target, `_AckAction`, and `_BatchChip` in the existing `MechXFocusRing` (same pattern already used for `_StageChip` in workflow_stepper.dart) so Tab reaches them and Enter/Space fires the callback already wired to `onTap`.


### L3. Keyboard-focus support is inconsistently applied across dense-inspector and menu controls
**MEDIUM** · effort S · inconsistency · lens: apple+mep · finders: extra:Keyboard-only operation & accessibility of the custom design system

The app has a proven, working focus idiom (`MechXFocusRing`) used consistently in MechXButton, the nav rail, the workflow stepper, PaletteCard, and SteppedValueField — but several other frequently-used interactive widgets skip it entirely and fall back to bare `GestureDetector`/`MouseRegion`.

- **Evidence:** lib/ui/electrical/electrical_controls.dart:147-204 `ElectricalToggleRow` (line 164 `GestureDetector`) — the on/off switch used for every essential/UPS-backed/submeter/dual-transformer/advanced-study toggle in the electrical Panel and Circuit inspectors; lib/ui/canvas/offset_dialog.dart:187-222 `_SideButton` (the Offset dialog's Left/Right picker); lib/ui/widgets/context_menu.dart:150-225 `MechXMenuRow` — the ONE shared row rendered by every mechanical AND electrical right-click context menu.
- **User impact:** A keyboard user who reaches the electrical Panel/Circuit inspector, the Offset dialog, or any right-click menu (mechanical edge/fitting or electrical panel/circuit) cannot Tab to or activate these specific rows/switches — they must grab the mouse mid-task even though the surrounding screen is otherwise keyboard-operable, undermining the keyboard support built elsewhere in the same views.
- **Direction:** Sweep `ElectricalToggleRow`, `_SideButton`, and `MechXMenuRow` (plus any other bare-GestureDetector interactive widget found by the same audit) and wrap each in `MechXFocusRing`, exactly matching the idiom already proven in `MechXButton`/`PaletteCard`/`WorkflowStepper`.


### L4. Screen-reader labelling covers a small fraction of the app's interactive controls
**MEDIUM** · effort M · clarity · lens: apple+mep · finders: extra:Keyboard-only operation & accessibility of the custom design system

The shared `MechXFocusRing`'s `Semantics` wrapper only ever sets `button`/`enabled`/`onTap` — it has no `label`/`semanticLabel` parameter — so any control relying on it for accessibility exposes at best its own child text as the accessible name. Only 7 of 92 `.dart` files under lib/ui add an explicit `Semantics(...)` node at all.

- **Evidence:** lib/ui/widgets/mechx_focus_ring.dart:76-84 (the `Semantics` block has no `label` field); repo-wide, only mechx_button.dart, mechx_focus_ring.dart, workflow_stepper.dart, nav_rail.dart, disclosure_header.dart, app_shell.dart, and collapsible_inspector.dart add real `Semantics(...)` labels, out of 92 files under lib/ui.
- **User impact:** A screen-reader user tabbing through the dense Sizing/Rooms/Tanks/HVAC inspector hits dozens of `SteppedValueField` '−'/'+' glyph buttons (lib/ui/widgets/stepped_value_field.dart:227-239) with no field-specific label — the announced sequence would be an undifferentiated 'minus, button… plus, button…' with no way to tell which of the many numeric rows on screen each belongs to, effectively making that whole inspector unusable non-visually.
- **Direction:** Add an optional `semanticLabel` parameter to `MechXFocusRing` (default null, so existing callers are unaffected) and thread a real, field-specific label through the highest-traffic call sites first — `SteppedValueField`'s +/- glyphs (pass the field's own label) and `MechXMenuRow`/`PaletteCard`.


### L5. No visible hover-tooltip mechanism exists for icon-only chrome (one hidden exception)
**LOW** · effort M · clarity · lens: apple+mep · finders: extra:Keyboard-only operation & accessibility of the custom design system

A repo-wide search for `Tooltip(` returns exactly one hit — a custom hover-label the nav rail shows only when manually COLLAPSED to icon-only mode. No other icon/glyph-only control in the app (the on-canvas zoom cluster, the demoted top-bar theme toggle) shows any visible on-hover explanation.

- **Evidence:** lib/ui/shell/nav_rail.dart:375-396,511-519 (`_CollapsedLabelTooltip`/`OverlayPortal`, gated on `widget.collapsed`); lib/ui/canvas/zoom_controls.dart:53-103 (`_IconBtn` for the '+'/'−'/'fit' glyphs — no Semantics, no hover text); lib/ui/app_shell.dart:801-851 (`_ThemeToggleButton` — carries a Semantics label for screen readers but no visible tooltip for a sighted mouse user).
- **User impact:** A week-2 engineer hovering the zoom cluster's glyphs or the demoted theme-toggle icon in the top bar gets no on-screen hint beyond the bare glyph — they must guess or click to discover what it does, and the demoted (icon-only) theme toggle in particular has no textual cue at all pointing to what it is.
- **Direction:** Extract the nav rail's `_CollapsedLabelTooltip`/`OverlayPortal` pattern into a small shared `MechXTooltip` widget and apply it to the zoom cluster, the theme toggle, and other icon-only chrome, reusing the same text already supplied as each control's Semantics label.


## Theme M — Windows-desktop citizenship

An Apple-sensibility app that still has to behave like a native Windows program: window management, file association, display scaling. (Territory identified by the completeness critic — never covered by any prior campaign.)

### M1. No minimum window size and no responsive reflow — fixed-px chrome breaks at ordinary Windows widths, and was never actually tested below 1280x832
**HIGH** · effort L · gap · lens: apple+mep · finders: extra:Windows-desktop platform conventions & display-scaling reality

The custom Win32 runner never overrides WM_GETMINMAXINFO, so Windows will let the user shrink the window to its default tiny minimum (roughly 130px wide) with no floor set by the app. Meanwhile every major chrome element (nav rail, sheet rail, right inspector) is a hard-coded pixel width with no LayoutBuilder/MediaQuery-driven breakpoint anywhere in app_shell.dart, and the panels only collapse via a manual chevron the user has to discover and click — never automatically based on available width. Even the app's own shipped default launch size is smaller than the minimum its test suite documents as safe.

- **Evidence:** windows/runner/win32_window.cpp has no WM_GETMINMAXINFO handler (confirmed absent by search) so no native minimum size is enforced; windows/runner/main.cpp:29 launches at `Win32Window::Size(1280, 720)` on every run; test/test_util.dart:27-31 explicitly says 'Desktop apps have a sensible minimum window size; the default 800×600 test surface is narrower than MechX targets' and sets its own floor at 1280x832 — i.e. the app's real default launch HEIGHT (720) is already below the height the codebase's own comment calls the safe minimum (832), and nothing below 1280x832 is ever exercised by a widget test or a golden (test/screenshots_test.dart:43-44 locks 1440x900 @ DPR 1.0). lib/ui/app_shell.dart:288-297 lays the workspace out as a bare `Row(children: [SheetRail(), Expanded(canvas), inspector])` with no LayoutBuilder; lib/ui/shell/nav_rail.dart:69/73 (width 80, collapsedWidth 52) and lib/ui/inspector/project_panel.dart:1076 (width 272) are fixed and only shrink via a manual per-panel toggle (lib/ui/shell/nav_rail.dart:96 navRailCollapsedProvider, lib/ui/inspector/collapsible_inspector.dart:30-38), never automatically.
- **User impact:** An Indonesian MEP engineer using a common 1366x768 laptop at 125-150% Windows scaling, or simply using Windows 11 Snap Layouts (drag-to-edge / Win+Z, a mainstream daily workflow for putting the plan beside a reference PDF or email) gets a logical viewport well under the ~416px of default chrome plus a usable canvas. Because nothing reflows or clamps, the fixed-width rail/inspector/sheet-rail simply overflow the Row and get visually clipped/cut off by the window edge — with no scrollbar, no auto-collapse, and no warning — hiding the very canvas and inspector controls the engineer needs mid-drawing.
- **Direction:** Add a WM_GETMINMAXINFO handler in win32_window.cpp enforcing a real minimum (e.g. 900x600) so the OS itself can't shrink below a usable floor, and wrap the app_shell Row in a LayoutBuilder that auto-collapses the nav rail / sheet rail / inspector (reusing the existing collapsed states) once available width drops below a threshold, then extend the widget-test/golden matrix to cover at least one narrow width.


### M2. No .mechx file association and no command-line file-open handling — double-clicking a project in Explorer does nothing
**MEDIUM** · effort S · gap · lens: apple+mep · finders: extra:Windows-desktop platform conventions & display-scaling reality

installer/iSystem.iss has zero [Registry] entries associating the .mechx extension with the app (confirmed by search — the whole file contains no Registry section and no mention of '.mechx'), so Windows never learns iSystem opens .mechx files: no Explorer double-click, no 'Open with', no jump-list recent-file entry, no icon overlay. Compounding this, lib/main.dart's main() takes no arguments and never reads the command line, so even if a file path were ever passed to the exe it would be silently ignored and the app would just launch its normal empty/recovery flow.

- **Evidence:** installer/iSystem.iss — grep for 'Registry|\.mechx|FileType' returns nothing; the [Files]/[Icons]/[Run] sections only install and relaunch the exe, never register a file type. lib/main.dart:16 `void main() async {...}` never touches `Platform.executableArguments` or `args`, unlike windows/runner/main.cpp:22-25 which does gather `GetCommandLineArguments()` and forwards them as Dart entrypoint arguments — a path the Dart side never reads.
- **User impact:** An engineer who receives a colleague's .mechx file by email or a shared drive, or simply wants to reopen a recent project from Explorer/taskbar jump list the way every other Windows CAD tool (AutoCAD, Revit) supports, cannot — double-clicking the file does nothing (or, if a file-type default happens to exist from another tool, opens the wrong app). They must first launch iSystem manually and then use File > Open, which contradicts the app's own 'document-app' framing (project_io.dart:369-374 explicitly models Ctrl+S/O on 'every desktop authoring tool a CAD engineer is trained on').
- **Direction:** Add a [Registry] stanza to iSystem.iss associating .mechx with the installed exe (icon + 'open' verb), and read the first command-line argument in main() to auto-load that path through the existing _applyOpenedFile-style flow before the first frame.


### M3. Window position, size, and maximized state are never remembered across launches
**MEDIUM** · effort M · gap · lens: apple+mep · finders: extra:Windows-desktop platform conventions & display-scaling reality

The Win32 runner hard-codes the launch window to origin (10,10) and size 1280x720 on every start (windows/runner/main.cpp:28-29); there is no window_manager/bitsdojo-style plugin in the dependency tree and no window-geometry fields anywhere in the persisted app settings model, so nothing ever saves or restores where the user left the window.

- **Evidence:** windows/runner/main.cpp:28-29 — `Win32Window::Point origin(10, 10); Win32Window::Size size(1280, 720);` used unconditionally on every `wWinMain` call; lib/data/app_settings.dart's `AppSettings` class (grep for windowX/windowWidth/bounds/geometry) has no such fields, and grep of lib/ for `window_manager`/`bitsdojo` returns nothing.
- **User impact:** An engineer who maximizes the window, moves it to a second monitor (a common multi-monitor CAD setup — plan on one screen, spec/reference PDF on another), or resizes it to a comfortable size loses that arrangement every time they relaunch iSystem or the app auto-restarts after an update — they must re-maximize/re-position/re-resize at the start of every single session, a small but constant tax on a tool used for hours at a stretch.
- **Direction:** Persist window bounds + maximized flag (via GetWindowPlacement/SetWindowPlacement in the existing custom win32_window.cpp, written into the same offline app-settings JSON already used for theme/locale) and restore them before Show() on the next launch.


### M4. Several icon-only chrome controls have no Windows-style hover tooltip
**LOW** · effort S · gap · lens: apple+mep · finders: extra:Windows-desktop platform conventions & display-scaling reality

Windows users expect a hover tooltip on any icon-only control. iSystem has a working custom tooltip widget (_CollapsedLabelTooltip in nav_rail.dart) but it is wired up only for the collapsed nav-rail items; the inspector's collapse/expand chevron and the nav rail's own collapse toggle — both bare icon glyphs with no caption — have no tooltip and no visible on-hover label, only an accessibility-only semanticLabel on the theme toggle that a sighted mouse user never sees.

- **Evidence:** lib/ui/inspector/collapsible_inspector.dart:88-98 `_ToggleStrip`/`_ToggleStripState` — no Tooltip/semanticLabel/hover-label of any kind (grep for Tooltip in this file returns nothing). lib/ui/shell/nav_rail.dart:250-260 `_CollapseToggle` — same, no tooltip. lib/ui/app_shell.dart:716-721 `_ThemeToggleButton` only sets a `semanticLabel` for screen readers, not a hover-visible label. The one place a real tooltip exists (nav_rail.dart:513 `_CollapsedLabelTooltip`) is scoped to the collapsed nav items only.
- **User impact:** A first-time user hovering the unlabeled chevrons that collapse/expand the inspector or the nav rail gets no on-hover explanation of what the icon does — unlike every other icon in Windows Explorer/Office/VS Code, which shows a tooltip after ~1s of hover. It's a small but repeated moment of 'what does this button do?' friction during onboarding.
- **Direction:** Reuse the existing _CollapsedLabelTooltip pattern (already built and themed) to wrap the inspector chevron and nav-rail collapse toggle so every icon-only control gets a visible hover label, not just an accessibility-only one.
- **Verification note:** corrected evidence: collapsible_inspector.dart:98-144 `_ToggleStrip` DOES carry a Semantics(label:) (lines 114-116) but no hover tooltip; nav_rail.dart:260-299 `_CollapseToggle` has no label of any kind; app_shell.dart:716-721 `_ThemeToggleButton` semanticLabel only; nav_rail.dart:513 `_CollapsedLabelTooltip` scoped to collapsed nav items.


## Theme N — Export-readiness: what the issued set proved on paper

**(Added 2026-07-06, after the product owner set the goal: the exports must be
construction-ready — a mandor and site engineers build from them directly, no AutoCAD
redraw, no Excel supplement.)** Method: a committed dev tool
(`packages/mechx_engine/tool/generate_export_samples.dart`) built a representative
3-storey fixture and drove every real exporter to 13 artifacts; the PDFs were rasterized
and FOUR site-lens critics (mandor/foreman, mechanical site engineer, electrical
kontraktor, document controller) reviewed the actual sheets, each finding verified against
the exporter source (fixture artifacts excluded), the riskiest claims re-verified by the
orchestrator. 25 findings — 10 high / 13 medium / 2 low.

### N1. Every vector PDF garbles the '·' separator to '?' — inside the purchase-critical cells
**HIGH** · effort S · regression · lens: generation + elec-kontraktor + document-engineer

The PDF text emitters restrict output to printable ASCII and map every other character to '?', while the engine itself composes labels with a U+00B7 middle-dot separator. The corruption lands exactly where it hurts: the board schedule's PENGHANTAR cable/conduit spec ('NYY 3x16 mm2 + BC 16 mm2 ? PVC 32mm'), the DEVICE motor-starter token ('MCB 16A 3ph ? star-delta' on the fire pump, 'MCB 25A 3ph ? VFD'), compact-node sub-lines ('160A 4P ? 54.0kW / 63.5kVA'), and the mechanical riser equipment labels ('Pump ? 2.2 kW'). The DXF of the SAME set renders all 24 middle-dots correctly, so the two formats of one issued package contradict each other.

- **Evidence:** elec-detail-p1..p2.png, riser-mech-p1.png (visible '?'); elec-single-line.dxf lines 1178/2254 (correct '·'); the ASCII clamp in _pdfText in plan_pdf_export.dart / pdf_export.dart / electrical_pdf_export.dart; separators composed in electrical_sld_drawing.dart:384 and riser label builders.
- **User impact:** A contractor pricing from the PDF reads '? star-delta' as an unconfirmed starter (may quote a cheaper DOL on a life-safety pump) and '? PVC 32mm' as a missing conduit value — RFIs or wrong procurement on every affected way; cross-checking the DXF adds a document contradiction.
- **Direction:** Map U+00B7 to the WinAnsi 0xB7 byte in the PDF emitters (it exists in the encoding), or swap the engine separators to an ASCII token (' - '); add a regression test that no exporter output contains '?' unless the source text did.

### N2. The mechanical riser PDF titles itself 'Untitled project'
**MEDIUM** · effort S · gap · lens: generation

The discipline-neutral sldSheetToPdf wrapper has no project-name parameter, so the PROJECT row of the riser title block falls back to 'Untitled project' — the real project name appears only in a smaller sub-line. The flagship mechanical drawing introduces itself as untitled.

- **Evidence:** riser-mech-p1.png title block header; report/sld_export.dart sldSheetToPdf (no project param) vs electrical_pdf_export.dart _projectName(null) fallback.
- **User impact:** Every issued riser sheet carries a placeholder name a checker red-pens immediately; the document register lists an 'Untitled project' drawing.
- **Direction:** Add a project/title-block param to sldSheetToPdf/Dxf and thread the live project name from schematic_export.dart.

### N3. Colliding size tags fuse into unreadable strings on plan and riser — a wrong-diameter risk
**MEDIUM** · effort S · clarity · lens: generation + foreman

On dense branches adjacent tags overprint into single tokens: '15-CW-PPR25-CW-PPR' and '40-D-PVCV-PVC' on the riser, 'DN32 - 4.0m'/'DN'/'UP' pile-ups at plan riser bases. The label placer diverts along a short ladder but never suppresses, stacks, or leaders when two short branches share a midpoint.

- **Evidence:** riser-mech-p1.png Lantai 1/2 branch chains; plan-lantai1-p1.png riser-base clusters; mechanical_sld_drawing.dart _LabelPlacer.place (no leader/suppress path); plan_pdf_export.dart placeEdgeLabel greedy pass.
- **User impact:** Where tags fuse the foreman genuinely cannot tell DN15 from DN25 — reading it wrong means ordering and cutting the wrong pipe; every fused tag is a confirmation phone call.
- **Direction:** Give the placer a collision fallback: leader lines to clear space, or stack labels with a tie mark; add a collision-count assertion to the export tests so dense fixtures fail loudly.

### N4. Plans carry no setting-out data — no gridlines, no dimensions, no ties to structure
**HIGH** · effort M · gap · lens: foreman

The plan export draws the network, size+length labels, and chrome — but no column grid, no dimension strings, and no offset from any run to a wall, gridline, or datum. Even over the real underlay, nothing locates a pipe in the building.

- **Evidence:** plan-lantai1-p1.png (runs float with lengths but no position ties); plan_pdf_export.dart planToPdf has no dimension/gridline primitive (underlay, edges, nodes, chrome only).
- **User impact:** The mandor cannot mark the slab: a 4.2 m run with no start point or wall offset cannot be set out, and sleeve positions cannot be fixed. This is the single question that forces the call to the engineer before work starts.
- **Direction:** Support reference gridlines (imported or drawn) and auto-dimension ties from runs/risers to the nearest grid/wall reference at export; a first increment: dimension each riser and each run endpoint to two grid axes.

### N5. No mounting height or elevation on any plan run — every service is a flat 2D line
**HIGH** · effort M · gap · lens: foreman

Each run label is size + horizontal length only; no centreline height, FFL offset, or invert prints for water, vent, or ducts. The riser gives per-floor FFL but the plan never says how high above the floor each service runs.

- **Evidence:** plan_pdf_export.dart edge label = _sizeLabel + _lengthLabel only; plan-lantai1-p1.png CW/drainage/vent/O200 ducts all height-less. The model KNOWS heights (§10 role-aware nodeElevation, MountingHeights).
- **User impact:** Ceiling-void coordination is guesswork — CW, drain, vent and duct crossings clash and get reworked; nothing can be hung at a defensible level without an RFI.
- **Direction:** Print an elevation token on each run label (e.g. 'DN32 - 4.2 m - CL +2.70') derived from the already-modelled role elevations, with a per-service default the engineer can override.

### N6. The riser diagram carries no lengths — riser spools cannot be prefabricated from it
**MEDIUM** · effort M · gap · lens: foreman

Riser tags give SIZE-SERVICE-MATERIAL but no run carries metres; only the FFL gutter implies floor lifts, and horizontal branch stubs have no length at all — yet the riser is the sheet used for take-off and prefab.

- **Evidence:** riser-mech-p1.png; mechanical_sld_drawing.dart _pipeTag builds size/service/material/function only; buildMechanicalRiserSld receives no edgeLengths map (plan_pdf_export.dart is the only exporter that takes one).
- **User impact:** No cut lengths for risers or branch spools — material take-off means measuring the plan sheet by hand.
- **Direction:** Pass the same edgeLengths map the plan export already receives into buildMechanicalRiserSld and append '- x.x m' to riser/branch tags (§10 elevation deltas for risers).

### N7. No sheet lists every fixture a floor serves — the fan-out caps at 4 with '+N more'
**MEDIUM** · effort S · gap · lens: foreman

The riser's per-floor fan-out hard-caps at 4 entries and collapses the rest to '+N more' (Lantai 1 hides 5), and plan fixtures are anonymous triangles — so no artifact in the set enumerates the fixtures per floor with counts.

- **Evidence:** riser_tags.dart floorFanOuts(max:4); mechanical_sld_drawing.dart '+N more' row; plan_symbols.dart unlabeled fixture triangle; riser-mech-p1.png '+5 more'.
- **User impact:** The foreman cannot count or verify fixtures before roughing-in a branch; every floor needs a fixture list requested by phone.
- **Direction:** Emit a per-floor fixture schedule block (type x count) on the riser sheet or a companion table, and lift the fan-out cap into a grouped 'WC x3' notation instead of truncation.

### N8. No cable length or panel location anywhere in the electrical set
**HIGH** · effort M · gap · lens: foreman + elec-kontraktor

The schedule's PENGHANTAR column, the overview/riser feeder labels, and the calc-report cable table give family + cores x CSA + conduit but never metres — although run length drives the printed voltage-drop figures internally. Panels tie only to a floor, never a location, and there is no plan-accurate electrical layout export.

- **Evidence:** electrical_sld_drawing.dart schedule columns + _feederConnLabel (no length term); elec-calc-report.md table header (no length column); elec-riser-p1.png feeders 'NYY 5x6 mm2 ? MCB 32A 3ph' with no metres.
- **User impact:** Feeder cable cannot be taken off, priced, or cut; any assumed length silently diverges from the certified Vdrop. Site teams must scale a separate drawing or measure in place — the exact supplement the product exists to remove.
- **Direction:** Print the geometry-derived length (already computed for Vdrop) in the schedule as a LENGTH column, in feeder labels, and in the calc-report table; land the plan-accurate electrical layout export (H1) for routes/locations.

### N9. No breaker carries an interrupting capacity (kA) on a representative project
**HIGH** · effort M · gap · lens: elec-kontraktor

Every DEVICE cell prints class+rating+poles only; the per-device kA suffix exists but populates solely from the advanced fault study's incomerKa map, which is empty in a representative project — so no device, not even the incomer, shows an Icu on any sheet. The busbar 'Icw 19.0kA' is the only fault figure and is not a device rating.

- **Evidence:** electrical_sld_drawing.dart:382 breakerCell + kaSuffix (empty unless breakerIcuKaByPanelId maps the panel); electrical_export.dart:69-76 sources kA only from electricalAdvancedProvider fault results; elec-detail-p1..p4.png show no kA on any device.
- **User impact:** At a 16 kA board the builder has no Icu to procure against — under-rated 4.5/6 kA MCBs that cannot interrupt the fault are the default failure. The one number PUIL compliance hangs on is absent from the fabrication sheet.
- **Direction:** Fall back to the origin fault level / busbar withstand the project already carries (16 kA default) for the per-device kA when the fault study is absent, and always print it.

### N10. Socket RCDs appear in the calc report but not on the board schedule the panel is built from
**HIGH** · effort S · inconsistency · lens: elec-kontraktor

The calc report specifies '30 mA A' RCDs on LP-1 socket ways — PUIL-mandated earth-fault protection — but the board-schedule sheet has no RCD column or token, showing those ways as bare MCBs. Two documents in one issued set contradict on a life-safety device.

- **Evidence:** elec-calc-report.md LP-1 rows 95-96 ('30 mA A', from electrical_calc_report.dart:297-298 emitting c.rcd); electrical_sld_drawing.dart headers/DEVICE cell carry no RCD; elec-detail-p4.png W4/W5 read plain 'MCB 16A 1ph'. Spot-verified by the orchestrator.
- **User impact:** A panel built from the schedule ships sockets without RCBOs — non-compliant and unsafe — while the contradiction erodes trust in the whole package.
- **Direction:** Append the RCD token to the DEVICE cell (or a dedicated column) from the same c.rcd field the report prints; supersedes the schedule half of finding H2.

### N11. Metering prints as a bare 'CT' glyph — no ratio, class, or burden
**MEDIUM** · effort M · gap · lens: elec-kontraktor

Three-phase headers draw V/A/Hz circles and the literal string 'CT' with no ratio (e.g. 200/5 A), class, or burden, although the panel demand current needed to derive a standard ratio is already computed.

- **Evidence:** electrical_sld_drawing.dart:282-297 (meters as letters, 'CT' literal); elec-detail-p1/p3.png headers.
- **User impact:** CTs and meters cannot be quantified or purchased; metering becomes a spec-sheet chase. Extends finding H4 onto the drawing itself.
- **Direction:** Derive the next standard CT primary above demandCurrent and print 'CT 200/5A cl.1'; list the meters in the KETERANGAN legend.

### N12. MCCB incomers print a B/C/D curve code — 'MCCB C160A/4P' is not a valid designation
**LOW** · effort S · clarity · lens: elec-kontraktor

The curve-led breakerLabel always injects a curve letter, so moulded-case incomers read like MCBs; MCCBs are specified by frame/trip/Icu, not a fixed characteristic curve.

- **Evidence:** electrical_sld_drawing.dart breakerLabel:99-101 (unconditional _curveCode), used for the incomer at :274; elec-detail-p1.png 'Incomer MCCB C160A/4P'.
- **User impact:** Reads as an error on an issued sheet and invites a procurement query; low risk since rating/poles still order correctly.
- **Direction:** Suppress the curve code when deviceClass == mccb.

### N13. No shared element tag links plan, riser, BOM, and report — a run cannot be traced across the set
**HIGH** · effort L · inconsistency · lens: mech-site-engineer

The same pipe is labelled four different ways: plan 'DN32 - 4.2 m', riser '32-CW-PPR' + 'CW-R1', BOM/report 'Cold water | run | DN32 | 4.2'. The riser id and material exist ONLY on the riser; the only common token is the bare DN, which is ambiguous (four distinct CW DN32 runs in this small fixture alone).

- **Evidence:** plan_pdf_export.dart:54 (size-only label); riser-mech.dxf carries CW-R1/32-CW-PPR absent from plan-ground.dxf; bom.dart:18-40 BomLine has no id/material. Subsumes the plan-tag halves of G1/J3 for pipework.
- **User impact:** 'Which run on the plan is CW-R1?' has no answer — RFIs cannot reference an element, inspections match by guesswork, and the wrong DN32 run gets worked on.
- **Direction:** Thread the existing riserTags/riserServiceCode through the plan edge labels and add a tag/material column to BomLine and the report rows — one stable identifier on all four artifacts.

### N14. The BOM has no material column, and duct sizes file under 'nominal_dn_mm'
**HIGH** · effort M · gap · lens: mech-site-engineer

BomLine carries service/kind/diameter/length only — no material — although the model knows PPR vs PVC per edge and the riser prints it. Round ducts are forced into the DN column ('duct,run,2,200'), indistinguishable from DN200 pipe to any CSV consumer, and rectangular ducts have no WxH representation.

- **Evidence:** bom.dart:18-40 (no material field), :250-251 (CSV header nominal_dn_mm); bom.csv duct rows; calc-report.md BOM table columns.
- **User impact:** Pipe cannot be priced (PPR vs PVC differs several-fold) and a takeoff reads ducts as pipe — wrong-material procurement on a pressurized line is the failure mode.
- **Direction:** Add material (from pipeProduct/ductProduct or the service default) to BomLine, CSV, and the report table; give ducts their own size column (O or WxH).

### N15. The mechanical riser DXF writes plumbing onto ELECTRICAL layers (E-BREAKER/E-TEXT/E-FRAME)
**MEDIUM** · effort M · inconsistency · lens: mech-site-engineer

The riser exports through the electrical DXF renderer and inherits its layer names: only pipe runs land on service layers; all 114 text entities and 205 of 321 lines land on E-TEXT/E-FRAME/E-BREAKER — in a drawing with no breakers. Spot-verified: 212 E-BREAKER references vs 48 CW.

- **Evidence:** riser-mech.dxf layer counts; sld_export.dart sldSheetToDxf delegates to electricalSldToDxf; electrical_dxf_export.dart:186 routes un-layered prims to kDxfLayerEBreaker/EText/EFrame.
- **User impact:** Freezing electrical layers in CAD also hides the plumbing riser; layer-based takeoffs cross disciplines. The file must be re-layered by hand — the redraw the product promises to kill.
- **Direction:** Parameterize the DXF layer namespace (M-TEXT/M-FRAME/M-DETAIL defaults for the mechanical path) in the shared renderer.

### N16. The calc report never shows the per-run sizing basis (fixture units, flow, velocity)
**MEDIUM** · effort M · gap · lens: mech-site-engineer

The Water-supply section reports feed strategy, residual, and pump duty, but no per-run UBAP, probable flow, or velocity — all computed per edge and discarded at print time. A size cannot be checked against its basis from the issued set.

- **Evidence:** calc_report.dart:297-345 (no per-edge table); EdgeSizing carries flow/velocity that never prints. Companion to I5 (override provenance) and I3 (velocity display).
- **User impact:** 'Why is this DN32 not DN25?' becomes an RFI back to the designer for the calc sheet — the report fails its purpose as evidence.
- **Direction:** Add a per-service run/riser schedule (tag - DN - FU - L/s - m/s - length) from the existing EdgeSizing data.

### N17. A drainage stack can size SMALLER than the branches discharging into it (DN65 stack, DN75 branches)
**MEDIUM** · effort M · gap · lens: mech-site-engineer

Stack and branch size independently from separate DFU capacity tables with no cross-check, and the demo fixture already produces a DN65 stack receiving DN75 branches — a standard-drainage-rule violation printed on plan, riser, and BOM. Spot-verified in bom.csv (riser 65 / runs 75) and network_sizing.dart:748-751.

- **Evidence:** network_sizing.dart _sizeSanitaryEdge (independent drainDiameterForDfu calls, isStack split); bom.csv drainage rows; riser-mech-p1.png 75-D-PVC into 65-D-PVC.
- **User impact:** The issued set contains an apparent code conflict on every such stack; built as drawn the stack is undersized — an inspector must RFI before approving.
- **Direction:** After DFU sizing, clamp each stack diameter to at least the largest connected branch diameter and surface the raise as a note (engine rule + test).

### N18. One duct prints four ways across the set: Ø315, DN315, O315, and bare 315
**LOW** · effort S · inconsistency · lens: mech-site-engineer

The report BOM table writes Ø315, the report FITTINGS table writes DN315 for the same air duct, the plan/DXF write O315 (ASCII fallback), and the CSV writes 315 under nominal_dn_mm.

- **Evidence:** calc_report.dart:534 (Ø for air) vs :557 (DN for all fittings); plan_pdf_export.dart:54 ('O'); bom.dart:250.
- **User impact:** An estimator reconciling report vs CSV cannot tell duct from pipe in the fittings table; avoidable clarification queries.
- **Direction:** One notation everywhere (Ø round / WxH rect, DN pipe) including fittings and a neutral CSV column name.

### N19. One global drawing number stamps every exported sheet — the set has no unique DWG numbers
**HIGH** · effort M · gap · lens: document-engineer

documentControlProvider holds a single documentNumber reused verbatim by every exporter (plans, mech riser, all electrical). The distinct M-101/M-102/E-201 numbers in our artifact set were hand-injected by the test harness; a real user gets the same number (or blank) on every sheet — already visible where three different electrical drawings all read 'E-201 Rev. 0'. Spot-verified across project_panel.dart/schematic_export.dart/electrical_export.dart call sites.

- **Evidence:** project_panel.dart:624/:807 etc., schematic_export.dart:176, electrical_export.dart:52 all pass doc.documentNumber; elec-detail/overview/riser all 'E-201 Rev. 0'.
- **User impact:** The submittal cannot be registered: sheets cannot be uniquely referenced, transmittal-logged, or cross-referenced; the drawing register collapses at intake.
- **Direction:** Derive per-sheet numbers at export (discipline prefix + role + running index: M-101/M-102/M-201/E-201/E-301) from sheet role + rail position, keeping the manual field as the base/override.

### N20. Two incompatible title blocks across the set; SLD sheets lack DRAWN/CHECKED/APPROVED and sheet i-of-N
**HIGH** · effort L · inconsistency · lens: document-engineer

Plan PDFs render the full ISO tabular block (PROJECT/CLIENT/TITLE/DWG NO/REV/SCALE/DATE/DRAWN/CHECKED/APPROVED/SHEET); the mechanical riser and all electrical sheets render a different header-style block with no sign-off rows and no sheet counter (only the paginated schedule stamps its own 'Sheet 1 of 4').

- **Evidence:** drawing_chrome.dart:241-251 (tabular block, plan exporters only); sld_export.dart/electrical_pdf_export.dart contain no DRAWN/CHECKED/APPROVED/SHEET tokens; compare plan-lantai1-p1.png vs riser-mech-p1.png/elec-overview-p1.png.
- **User impact:** The reviewing engineer has nowhere to sign the riser or schedules; no coherent i-of-N spans the package, so completeness cannot be confirmed; a checker red-pens the set for non-uniform title blocks.
- **Direction:** Render the one drawing_chrome tabular block on every exporter (plan + SLD), with the set-wide sheet counter threaded through.

### N21. No cover sheet, drawing list (Daftar Gambar), or general-notes/master-symbol sheet is generated
**MEDIUM** · effort L · gap · lens: document-engineer

The set is individual drawings + reports with nothing enumerating them; no drawing-index generator exists in the report package. An Indonesian PBG/permit submittal opens with a cover + Daftar Gambar + general notes/legend sheet.

- **Evidence:** report/ package contains no drawing-list/cover builder (only the calc-report PDF's own cover page); the artifact set itself.
- **User impact:** The consultant hand-assembles the index outside the app on every issue — the manual reassembly the product should eliminate; an incomplete index risks intake rejection.
- **Direction:** A pure generator emitting cover + drawing list (number/title/rev/date per sheet, from the same chrome objects) + a general-notes/master-legend sheet as the package's first pages; pairs with J2 (all-sheets package).

### N22. The equipment schedule omits the transformer, genset, and capacitor bank the model already carries
**MEDIUM** · effort M · gap · lens: document-engineer

EquipmentCategory knows only pump/fan/airHandling/panel; the 630 kVA transformer, 40 kVA standby genset, and 50 kvar capacitor bank drawn on the source spine never reach the procurement schedule.

- **Evidence:** equipment_schedule.dart:29 (category enum); equipment-schedule.md vs elec-overview-p1.png source spine.
- **User impact:** The highest-value, longest-lead apparatus in the building is absent from the tender schedule — purchasing discovers it only by reading the single-line.
- **Direction:** Add source/apparatus categories populated from transformerKva/sources/capacitorBankKvar with kVA/kvar as duty.

### N23. Every equipment-schedule Model/spec is the '—' placeholder, with no app field to fill it
**MEDIUM** · effort M · gap · lens: document-engineer

buildEquipmentScheduleRows defaults modelSpec to '—' and no UI path exists to enter make/model, so the column always ships blank — the schedule is a duty worksheet, not an issuable tender document.

- **Evidence:** equipment_schedule.dart:179/200/218; equipment-schedule.md (all rows '—').
- **User impact:** Contractors cannot procure from it; the consultant retypes the whole schedule into Excel to add models.
- **Direction:** An editable per-equipment model/spec field persisted in .mechx, threading into the schedule rows.

### N24. Every sheet carries a different private legend; plan symbols are defined nowhere on the plan
**MEDIUM** · effort M · inconsistency · lens: document-engineer

The plan legend lists line colours only (never the UP/DN markers, flow chevrons, or fixture triangles actually drawn); the riser KETERANGAN lists service codes + fittings; the electrical legend lists device abbreviations. Three disjoint dictionaries, no master.

- **Evidence:** plan-lantai1-p1.png legend vs its own symbols; riser-mech-p1.png KETERANGAN; elec-detail-p1.png LEGEND (which also defines NYY and NYM with the identical text 'Cable construction').
- **User impact:** A reviewer moving between sheets is handed different symbol languages and must guess glyph meaning — an RFI generator.
- **Direction:** One shared master legend (services + symbols + line conventions) on the general-notes sheet (N21), per-sheet legends as subsets; fix the NYY/NYM copy while there.

### N25. The calc report reads unprofessionally for a permit office: emoji heading and a superseded-standard admission
**MEDIUM** · effort S · clarity · lens: document-engineer

The transparency section is titled '## ⚠ Unverified values', and the standards line ends 'NB: SNI 8153:2025 now supersedes the 2015 edition' — an unqualified admission of designing to a superseded edition, phrased as an aside.

- **Evidence:** calc-report.md line 5 and line 22; strings emitted by calc_report.dart.
- **User impact:** A permit office reading an emoji heading plus 'the edition we used is superseded' demands resubmission; the honesty surface needs professional wording, not removal.
- **Direction:** ASCII heading ('Unverified values'), and reword the basis note to a governed statement ('Designed to SNI 8153:2015; 2025 edition published — differences under review') sourced from the profile.


## Implementation plan — seven waves

Waves 1-6 are the original ease-of-use sequencing (visible/honesty defects first, then
feel, trust, deliverable fidelity, velocity, polish — unchanged). Wave 7 is the ADDITIONAL
export-ready wave from the 2026-07-06 audit: all 25 Theme-N findings as one deliverable
campaign, schedulable independently of the others. Each wave leaves the gate green
(`flutter analyze` + engine + app tests) and re-captures only deliberately-changed goldens.

### Wave 1 - Stop the lies, fix the visible defects

Everything here is small (S effort), user-visible, and either factually wrong on screen today or lets the app silently misbehave. This wave alone removes most of what makes v1.12.0 feel unfinished: labels clipped in the app's own goldens, an empty state that gives wrong instructions, a read-only mode that commits edits, a compliance verdict missing a whole check, and exports whose equipment tags change between runs.

| ID | Finding | Severity | Effort |
|---|---|---|---|
| E1 | The fixed on-canvas help button overlaps and clips real diagram labels in the Riser top-left corner | high | S |
| B1 | Switching sheets/floors mid-draw silently corrupts the network with a phantom node | high | S |
| B2 | Air-duct warning badges collide with size labels instead of dodging them | medium | S |
| B3 | Dropping a riser on the top floor band silently reconnects it to the floor below, with no drop preview | medium | S |
| B4 | Auto mode is documented and labeled 'read-only' but a single click can add a permanent network edge | medium | S |
| B9 | The 'focus this panel' deep zoom clips the board schedule at both edges at common window widths | high | S |
| D1 | Power one-line's empty state tells the user to add sources 'from the Loads palette' but no such cards exist there | high | S |
| D3 | Main/run edges shown in Riser Edit mode look identical to risers but are completely inert | medium | S |
| D7 | The on-canvas (?) guide explains Layout-to-Riser but never Layout's electrical layer to the Electrical workspace | medium | S |
| A2 | 'New from template' silently mutates project state when the forced file picker is cancelled | medium | S |
| A3 | Onboarding calls step 2 'Floors'; the nav rail item you must click is called 'Building' | medium | S |
| A4 | Workflow stepper marks 'Floors' done just because something was drawn, without the engineer ever reviewing floor heights | medium | S |
| E6 | Floor elevation notation disagrees between the live canvas and the exported drawing | medium | S |
| H5 | Riser fan-out truncates circuit names mid-word with no ellipsis, producing garbled labels on an issued drawing | medium | S |
| I1 | Pressure-zone over-limit check never reaches the compliance verdict | high | S |
| I7 | Two fire-protection verdict strings leak hardcoded English into the Bahasa Indonesia calc report | low | S |
| B8 | A size label that can't find a clear spot vanishes with no trace it exists | low | S |
| G7 | Generic DETAIL WATER METER / DETAIL PRV SET boxes draw unconditionally regardless of whether the project has those components | low | S |
| J3 | Equipment-schedule tags (AHU-01, AHU-02…) are re-synthesized from room list order every export, not from stable room identity | high | S |
| J4 | Duplicate floor silently drops any equipment node not wired into a run | low | S |
| L2 | Review-hub compliance actions (Locate / Acknowledge / quick-fix) are mouse-only | high | S |

### Wave 2 - Feel: responsiveness, input, and Windows basics

The app must feel native before it can feel polished. The headline item is decoupling the full sizing+solve+BOM pipeline from every drag frame; the rest are the Windows-citizenship and input-consistency items that make a desktop app trustworthy: async open, remembered window state, file association, keyboard reach, honest hit targets.

| ID | Finding | Severity | Effort |
|---|---|---|---|
| K1 | Every node-drag frame re-runs the entire network sizing + pressure solve + BOM pipeline synchronously on the UI thread | high | L |
| K2 | Opening a portable .mechx with embedded plans blocks the UI synchronously — the exact freeze Save was already fixed for | medium | S |
| K3 | The heatmap's IDW field is recomputed from scratch on every pan/zoom frame, not just when the underlying solve changes | medium | S |
| K4 | Autosave fully JSON-encodes the whole project on the UI thread every 15 seconds just to check if anything changed | low | M |
| L1 | Electrical Loads palette has no keyboard path — Tab+Enter is a dead end | high | M |
| L3 | Keyboard-focus support is inconsistently applied across dense-inspector and menu controls | medium | S |
| L5 | No visible hover-tooltip mechanism exists for icon-only chrome (one hidden exception) | low | M |
| M2 | No .mechx file association and no command-line file-open handling — double-clicking a project in Explorer does nothing | medium | S |
| M3 | Window position, size, and maximized state are never remembered across launches | medium | M |
| M4 | Several icon-only chrome controls have no Windows-style hover tooltip | low | S |
| B5 | The clickable corridor around a pipe/duct stays a fixed ~8px band even as true-width zoom renders it up to 120px wide | medium | S |
| B6 | The outlet-pull nub and the node's move handle have overlapping click boxes with no visible boundary | medium | S |
| B10 | Endpoint-resize and node drags ignore the ortho constraint, un-straightening drawn runs | high | S |
| B11 | The outlet nub unmounts mid-pull, freezing the new run a short distance from the mainline | high | S |
| B12 | Plan underlay geometry is not a snap surface — a riser cannot snap to the shaft wall | high | M |
| C2 | Selection auto-scroll-to-top only fires the first time; re-selecting a different element while scrolled away leaves the updated editor invisible | medium | S |
| D9 | Two 'reveal panel detail' gestures on the same summary card zoom to inconsistent, undocumented scales | low | S |

### Wave 3 - The trust surface: make sign-off possible

The MEP lens's sharpest verdict: results exist but cannot be interrogated. Pipe velocity is sized-to but never shown; the heatmap cannot answer 'does this fixture pass'; acknowledgements have no author or timestamp; a plan revision silently keeps a stale calibration; the submittal package quietly omits floors. This wave turns outputs into evidence.

| ID | Finding | Severity | Effort |
|---|---|---|---|
| I2 | The pressure heatmap has no absolute reference and no per-node readout — it cannot answer 'does this fixture pass?' | high | M |
| I3 | Water/drainage pipe velocity — a code-driven sizing input — is never displayed anywhere in the app or the calc report | high | S |
| E4 | The pressure heatmap's flat/uniform state renders as washed-out tan, not a confident data visualization | medium | S |
| I4 | Advisory acknowledgement — the mechanism that makes PASS reachable — has no author, timestamp, or justification | medium | S |
| I5 | The calc report's Bill of Materials cannot show which sizes were manually overridden, and never breaks results out per run | medium | M |
| I6 | The title-block Revision tag and the Revision-history table are two disconnected fields with no cross-check | medium | S |
| J1 | Replacing a mid-project plan revision silently keeps the old scale calibration with no re-verification prompt | high | M |
| J2 | The one-folder submittal package only bundles the plan drawing for the currently active sheet, not every floor | high | M |
| H2 | RCD/RCBO protection is invisible on the panel schedule and single-line drawing | high | S |
| H3 | Breaker short-circuit rating (Icu, kA) shows on the PDF/DXF export but never on the live canvas the engineer designs against | medium | S |
| H4 | CT ratio for revenue metering is computed but never reaches the drawing or the UI | medium | S |
| H7 | Phase-imbalance percentage is computed but never printed on the panel schedule itself | low | S |

### Wave 4 - Deliverable fidelity: kill the AutoCAD redraw

The drafter lens's redraw-forcers, in dependency order: stable equipment tags on the plan, the hot-water return loop and drainage/vent riser fidelity, valve trains at takeoffs and pump sets, slope annotation, one air-colour language across canvas/PDF/DXF, containment notation, and the missing plan-accurate electrical layout export.

| ID | Finding | Severity | Effort |
|---|---|---|---|
| G1 | Mechanical equipment on the plan carries no tag — cannot be told apart or cross-referenced | high | L |
| G2 | Hot-water recirculation loop has no visual representation on the riser diagram | high | L |
| G3 | Auto-generated PUMP-SET DETAIL omits the suction/discharge valve train the app already models elsewhere | medium | M |
| G4 | Drainage/vent/rainwater risers get none of clean water's reference-detail treatment, and there is no STP/septic/sewer terminus symbol | high | L |
| G5 | Drainage/vent/rainwater runs never show their fall/slope on the plan | medium | S |
| G6 | No isolation valve is drawn, suggested, or flagged missing at a floor's riser branch takeoff | medium | M |
| E2 | Supply-air, return-air, and exhaust colors disagree between canvas, PDF, and DXF | high | M |
| E5 | No on-canvas legend for the colour-only Plumbing services while drawing | medium | S |
| H1 | No plan-accurate electrical layout export — only schematic single-lines | high | L |
| H6 | Large-CSA feeder cables silently drop all route/containment notation | medium | S |
| C5 | A circuit's starter/control type has no UI control anywhere, making the drafting feature it drives permanently unreachable by hand | medium | S |

### Wave 5 - Drafting velocity and workspace parity

Production speed on real towers: layer lock and per-service isolate, rotate/mirror, click-to-place-repeatedly, one plan reused across repeated floors, batch undo, and bringing the electrical and riser canvases up to the Layout selection/editing bar (including finishing the inline-inspector convergence).

| ID | Finding | Severity | Effort |
|---|---|---|---|
| F1 | No layer lock — the Select tool can grab and edit another discipline's faded reference elements | high | M |
| F2 | No rotate or mirror for pasted selections, arrays, or saved assemblies | high | L |
| F3 | 'Duplicate floor to a range' records one undo step per target floor, not one for the whole batch | medium | S |
| F4 | Plumbing is one indivisible layer — no isolate for cold/hot/drainage/vent/rainwater individually | medium | M |
| F5 | Every terminal / fitting / equipment placement is a one-shot drag from the palette — no click-to-place-repeatedly mode | medium | M |
| F6 | No way to reuse one imported floor plan across multiple repeated building floors | medium | M |
| D2 | Electrical single-line canvas has no multi-select, marquee, arrow-nudge, or copy/paste — a real step down from the mechanical Layout canvas | medium | L |
| D5 | Riser Edit mode has no multi-select, marquee, or batch move — every riser is placed/dragged one at a time | medium | M |
| C1 | Electrical editing still uses floating right-side drawers instead of the converged persistent inline inspector | medium | M |
| D6 | The Loads palette stays fully interactive-looking on the read-only Building-riser and Power-one-line tabs | medium | S |

### Wave 6 - Structure and long-tail polish

The remaining information-architecture and visual-consistency items, the accessibility semantics pass, the minimum-window/reflow lift, and the one deliberately-scoped-out deep item (spatial clash checking) recorded as future work rather than silently dropped.

| ID | Finding | Severity | Effort |
|---|---|---|---|
| A1 | Cold-launch Layout workspace has no zero-file way to try the app | high | M |
| A5 | The Projects-hub export surface is an unranked wall of identical buttons, with two near-duplicate PDF plan exports users can't tell apart | medium | M |
| A6 | Projects hub gives its one primary (accent) button to Export, not to starting a project | low | S |
| B7 | The canvas minimap is an unlabeled void-colored box that collides with other floating overlays | medium | S |
| C3 | The always-open 'Draw' section is the single largest block in the inspector and buries Sizing/Results/Fire/HVAC below the fold every session | medium | S |
| C4 | The Rooms (ACH/AHU) editor is the one major sizing surface that never got the identity-first / ResultCard treatment | medium | M |
| C6 | 0-1 ratio fields and an adjacent 0-100 percent field look identical and silently clamp on mismatch | low | S |
| D4 | The per-sheet/floor rail is shown on the Riser workspace but has no effect on it | medium | S |
| D8 | Two incompatible chrome material languages collide on the Riser single-line canvas | medium | S |
| E3 | Cold-water service color and the UI's own selection-accent color are nearly the same blue | medium | M |
| L4 | Screen-reader labelling covers a small fraction of the app's interactive controls | medium | M |
| M1 | No minimum window size and no responsive reflow — fixed-px chrome breaks at ordinary Windows widths, and was never actually tested below 1280x832 | high | L |
| J5 | No spatial clash/coordination check between disciplines sharing the same calibrated plan | low | L |

### Wave 7 - Export-ready deliverables (Theme N)

The additional wave landing the export-readiness audit: everything the four site-lens
critics proved missing or wrong on the ISSUED artifact set, kept together so the exports
cross the "build from it directly" bar as one campaign. It is additive to Waves 1-6 and
independent of them — given the product priority on export readiness it can be scheduled
at any point, including first. The export-samples dev tool
(`packages/mechx_engine/tool/generate_export_samples.dart`) is this wave's acceptance
harness: regenerate the 13 artifacts and re-read the sheets after each batch. Suggested
internal order: the S-effort sheet-truth fixes (N1, N10, N2, N3, N7, N12, N18, N25), then
print-the-numbers (N8, N9, N6, N11, N16), then locate/set-out (N13, N4, N5, N14), then the
submittal set (N19, N20, N21, N22, N23, N24, N15) and the engine rule N17.

| ID | Finding | Severity | Effort |
|---|---|---|---|
| N1 | Every vector PDF garbles the '·' separator to '?' — inside the purchase-critical cells | high | S |
| N10 | Socket RCDs appear in the calc report but not on the board schedule the panel is built from | high | S |
| N4 | Plans carry no setting-out data — no gridlines, no dimensions, no ties to structure | high | M |
| N5 | No mounting height or elevation on any plan run — every service is a flat 2D line | high | M |
| N8 | No cable length or panel location anywhere in the electrical set | high | M |
| N9 | No breaker carries an interrupting capacity (kA) on a representative project | high | M |
| N13 | No shared element tag links plan, riser, BOM, and report — a run cannot be traced across the set | high | L |
| N14 | The BOM has no material column, and duct sizes file under 'nominal_dn_mm' | high | M |
| N19 | One global drawing number stamps every exported sheet — the set has no unique DWG numbers | high | M |
| N20 | Two incompatible title blocks across the set; SLD sheets lack DRAWN/CHECKED/APPROVED and sheet i-of-N | high | L |
| N2 | The mechanical riser PDF titles itself 'Untitled project' | medium | S |
| N3 | Colliding size tags fuse into unreadable strings on plan and riser — a wrong-diameter risk | medium | S |
| N6 | The riser diagram carries no lengths — riser spools cannot be prefabricated from it | medium | M |
| N7 | No sheet lists every fixture a floor serves — the fan-out caps at 4 with '+N more' | medium | S |
| N11 | Metering prints as a bare 'CT' glyph — no ratio, class, or burden | medium | M |
| N15 | The mechanical riser DXF writes plumbing onto ELECTRICAL layers (E-BREAKER/E-TEXT/E-FRAME) | medium | M |
| N16 | The calc report never shows the per-run sizing basis (fixture units, flow, velocity) | medium | M |
| N17 | A drainage stack can size SMALLER than the branches discharging into it (DN65 stack, DN75 branches) | medium | M |
| N21 | No cover sheet, drawing list (Daftar Gambar), or general-notes/master-symbol sheet is generated | medium | L |
| N22 | The equipment schedule omits the transformer, genset, and capacitor bank the model already carries | medium | M |
| N23 | Every equipment-schedule Model/spec is the '—' placeholder, with no app field to fill it | medium | M |
| N24 | Every sheet carries a different private legend; plan symbols are defined nowhere on the plan | medium | M |
| N25 | The calc report reads unprofessionally for a permit office: emoji heading and a superseded-standard admission | medium | S |
| N12 | MCCB incomers print a B/C/D curve code — 'MCCB C160A/4P' is not a valid designation | low | S |
| N18 | One duct prints four ways across the set: Ø315, DN315, O315, and bare 315 | low | S |

## Deferred / explicitly out of scope

- **J5 (spatial clash/coordination check)** is the one L-effort item consciously deferred:
  real value, but it needs a geometry-overlap engine layer designed on its own terms — it
  is recorded here so the gap stays visible rather than silently dropped.
- Anything requiring online services, Material widgets, or fabricated standards data stays
  out by guardrail.

## Review provenance

- Run 2026-07-06 against `f54fbf1` on `claude/workflow-goldens-review-c92v0x`; the
  export-readiness audit (Theme N) ran the same day against `2760963` (which adds the
  export-samples dev tool).
- 99 agents total: 12 finders + 1 dedup + 67 adversarial verifications + 1 completeness
  critic + 3 follow-up finders + 13 follow-up verifications + orchestration; ~9.4M tokens.
- Verification default stance was refutation; **zero findings were refuted** — the prior
  campaigns' "everything landed" claims held up (one 'regression' claim was reframed as a
  remaining consistency gap (C1) because the drawer form was a documented deliberate keep).

