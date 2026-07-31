# WORKFLOW-FRICTION-REVIEW — how the work is done (2026-07-30)

A fresh review of iSystem focused on **task execution** — the click-by-click
reality of an engineer's work — run AFTER the five prior campaigns fully landed
(UX-WORKFLOW, CAD-OUTPUT-UX, APPLE-DESIGN, WORKFLOW-GOLDENS incl. Wave 7
export-readiness, USABILITY, MODULE-AUDIT). Those passes fixed what the screens
*say* and what the engine *computes*; this one asks how the work *flows*:
between-step friction, repetition cost, recovery from mistakes, and whether the
features landed the same day are usable in the flow of work.

**Method.** Four parallel read-only reviewer lenses — W1 the first-project
walkthrough (launch → import → calibrate → building → draw → size → review →
export), W2 the daily grind (the five-hundredth edit), W3 mistakes/feedback +
the freshly-landed audit surfaces judged as a user, W4 all 18 goldens read as
images + the cross-workspace flows — each barred from re-reporting the landed
campaigns and required to ground every claim in file:line or a named golden.
69 raw findings then went through two independent **adversarial verifiers**
instructed to refute each one: **56 CONFIRMED, 13 ADJUSTED (detail corrected,
friction real), 0 REFUTED** (one half-refutation inside W2-9). Verifier
corrections are folded into the text below; the merge analysis groups the 69
into the themes used here. Every finding is actionable within the guardrails
(custom design system, offline, pure engine, additive `.mechx`).

**Status: CAMPAIGN COMPLETE (2026-07-31) — all four waves LANDED** in three
ultracode batches (11 agents + orchestrator seams; see the three §15 rows).
Every finding below is fixed or explicitly dispositioned. Batch 1: the Locate
contract A1–A5, riser contract B1–B4, data safety C1–C3/C6, undo granularity
D1–D2, draw scope E1, F3/F4-gate, G2, H3, H5. Batch 2: message quality
G1/G3–G7, A6, F1/F2/F5, F7–F12, D3, plus the orchestrator's A6 chips and the
mounting/report/undo seams. Batch 3: export surface I1/I2/I5, electrical
parity J1/J2/J4/J6/J7 + nudge parity, canvas polish J3/J5, C4/C5, E2/E3, F6,
I4 (store + the Paste-to-floors dialog + canvas-menu row). Recorded
residuals/dispositions: J3's corridor radius scales with mean node spacing, so
the sparse DEMO fixture still washes most of its small sheet (correct by
construction; dense real projects read as a corridor); the electrical canvas
selection stays set-valued in its own transient provider (true unification needs
`electricalSelectionProvider` to become set-valued); `movePanels` is now
unreferenced public API; canvas-view providers are not reset on project load
(matches the riser-store precedent, deliberate); the G7/E2 reject-messages and
menu rows are EN literals matching their neighbours; last-import-dir memory is
session-scoped (persisting it is a 4-line AppSettings follow-up); C1's
park-don't-delete means deleted equipment leaves one visibly-marked parked way
until the engineer removes it (narrated, by design).

---

## Theme A — "Locate" is not yet a navigation primitive
*The issue → fix → verify loop is the app's most-repeated workflow; today the
jump silently under-delivers at every step. One `locate()` path
(`lib/ui/review/issues_card.dart:270-279`) is missing four things its own
sibling branches already do.*

- **A1 (high; W2-1/W4-1)** Locate on a *mechanical* issue never leaves the
  Review hub. The sheet changes, the element is selected, `WorkspaceView.plan`
  is set — but `shellSectionProvider` is untouched, so the user stays staring
  at Review. The electrical (`:261`) and document-control (`:250`) branches DO
  set `ShellSection.design`; `runBatch` (`:289-292`) has the same gap.
  `issues_card_test.dart:83-118` pins everything except the section. *Fix:
  hoist the section set above the branches; extend the test.*
- **A2 (high; W2-2)** Locate never brings the element on screen: each sheet
  restores its last pan/zoom, so the target is frequently off-viewport.
  `CanvasViewState.centreOnWorld` (`canvas_view.dart:283`) exists — its sole
  caller is the minimap. *Fix: post-frame centre on the target after any
  programmatic selection.*
- **A3 (high; W2-3/W4-2/W1-12)** Locate carries no discipline/layer context:
  the target can arrive invisible (`_serviceVisible` skips hidden services —
  the selection halo included), ghosted at 0.28 alpha, or inert
  (locked/isolated services are excluded from every hit path), while the
  inspector happily shows its full editor. The document-control branch even
  expands the inspector; the mechanical one doesn't. *Fix: derive the
  discipline via `disciplineOf`, set it active, clear covering isolates,
  un-collapse the inspector.*
- **A4 (med; W3-9/W4-9)** A grouped issue row prints the FIRST member's
  message and N identical "Locate" links (`Locate Locate Locate Locate
  Locate` on golden 12). Which run is 3.4 m/s and which 2.1 is
  indistinguishable; stable element tags (`CW-R1`) exist and are unused here.
  *Fix: per-instance chips labelled sheet/floor + element tag; group line
  shows the worst member (or range).*
- **A5 (med; W4-10)** The compliance card's category rows — the headline
  verdict on the sign-off screen — are inert text; the actionable copy of the
  same category sits in a separate card below the fold. *Fix: each row
  scroll-to/expands its matching issue group.*
- **A6 (med; W3-10)** The Quick-fixes chips were never extended to the kinds
  landed by the module audit (water velocity, self-cleansing, over-capacity,
  loose ends, unfed panels) — `IssueBatchKind` still has exactly three
  members (`design_issues_store.dart:950-958`). *Fix: add the missing
  read-only multi-select batches.*

## Theme B — the riser breaks its cross-surface contract
*Risers are the one element that lives on two floors and two surfaces; three
confirmed defects make them lie on one surface about the other.*

- **B1 (high; W1-1)** A riser drawn on the plan is INVISIBLE on the floor
  above: the far-floor node is stamped with the SOURCE sheet's id
  (`network_store.dart:334-336`) and `_onThisFloor`
  (`network_layer.dart:283`) requires sheet AND floor to match — no reverse
  floor→sheet resolution exists anywhere in the paint path. The engineer
  cannot branch off the riser on the upper plan, draws a disconnected island,
  and meets it as a Review warning. `network_store_test.dart:276-287` asserts
  floorIndex only. *Fix: resolve the destination sheet by the floor's mapped
  sheet (the `building_screen.dart:55-60` lookup), fall back to the source
  sheet only when the floor has no plan.*
- **B2 (high; W4-4)** A riser dropped in Riser → Edit takes the ELEVATION
  DIAGRAM's world x and `y = 0` as its *plan* coordinates
  (`schematic_view.dart:1565-1581`), and `_sheetIdForFloor` falls back to the
  CURRENT sheet when the target floor is unmapped (`:1602-1612`) — producing
  a node whose sheetId maps to floor 0 while its floorIndex is 1: invisible
  on every sheet forever, yet sizing into the BOM
  (`elevation_edit_test.dart:105-117` proves it enters `sizingProvider`).
  *Fix: refuse the drop onto an unmapped floor with a status message; place
  at the sheet centre (or nearest same-service riser) otherwise.*
- **B3 (high; W4-5)** Dragging a riser sideways in the elevation — a
  diagram-decluttering gesture — writes the elevation x straight onto the
  plan nodes (`network_store.dart:430-441`; pinned by
  `elevation_edit_test.dart:132-139`), silently relocating the riser away
  from its shaft on the plan and every plan export. *Fix: a diagram-only
  `schematicX` (additive, tolerant `.mechx`), or at minimum a one-time
  warning naming the plan move.*
- **B4 (high; W2-8)** Riser tags are positional: `riserTags` sorts stacks by
  x (`riser_tags.dart:198-213`), so the B3 gesture — or any plan-side
  endpoint drag — RENUMBERS `CW-R1`/`CW-R2` across the plan labels, riser
  SLD, BOM tag column and calc report between revisions, with no diff and no
  warning. *Fix: seed tags from a first-assigned stable ordinal (the J3
  room-AHU pattern), x-order only for new stacks.*

## Theme C — destructive edits without confirmation, count, or undo
- **C1 (high; W2-5)** `syncMepEquipment` silently DESTROYS hand-edited
  derived ways: when a source pump/fan disappears (deleted, or the feed
  toggled off), the way is dropped (`electrical_store.dart:1798`) taking the
  engineer's typed name, cable family, length and starter — outside the undo
  funnel (`:511-522`), so Ctrl+Z cannot recover it; re-enabling re-mints
  defaults. Pinned by `electrical_store_test.dart:1445,1854`. *Fix: park
  orphaned ways (`sourceEquipmentId: null` + a "source removed" note) instead
  of deleting, or route the sync through an undo snapshot.*
- **C2 (high; W3-4)** Deleting a floor is unconfirmed (`building_screen.dart:
  91-92`) and `remapNodesForFloorChange` shifts only `fi > removedIndex`
  (`network_store.dart:500-501`): nodes ON the removed floor keep their
  index while the floor above shifts down INTO it — the two floors' drawn
  work silently fuses at the wrong elevation, in-range so no orphan check
  fires. The existing test pins only the above-the-removed case. *Fix: count
  the floor's elements, confirm ("Level 3 carries 47 drawn elements — delete
  them too?"), prune or refuse.*
- **C3 (med-high; W2-10/W4-8 + W4-2 delete-half)** The selection outlives
  sheet and workspace switches with no guard: the inspector shows a full
  editor for an off-sheet element, and Delete (`layout_canvas.dart:543-559`)
  fires on a selection that may be on another floor or a hidden/locked layer
  — silent cross-sheet deletion. *Fix: one precondition — selection must be
  on the current sheet and an interactive layer — for Delete and the batch
  appliers; badge the inspector header with the owning sheet otherwise.*
- **C4 (med; W3-16, adjusted)** With the Room tool armed, right-click deletes
  the nearest room within 40 px on pointer-DOWN — no menu, no confirm —
  everywhere else on the canvas secondary-click means "context menu". It IS
  undoable (verifier correction), but it also orphans the room's auto-placed
  diffusers/grilles, which keep feeding duct sizing and the BOM
  unattributed. Same idiom in the tank/measurement/reference-line overlays.
  *Fix: tap-up + confirm-or-menu, status pill naming the room + the
  terminals left behind.*
- **C5 (low; W3-19)** Two destructive cascades never state their collateral:
  sheet Remove prunes every node drawn on it behind a bare "Sheet removed"
  (`sheets_store.dart:344-358`), and `deletePanel`'s topology sanitize drops
  the parent's feeder way and silently converts orphaned children to utility
  roots (`topology.dart:50-63,102-107`). *Fix: count collateral into the
  status pill ("47 elements pruned · Ctrl+Z to undo"; "MDP way 4 removed,
  LP-2 LP-3 now unfed").*
- **C6 (med; W2-9, adjusted)** Plan equipment tags (`P-01`…) renumber on any
  delete (`plan_symbols.dart:414-427` counts live node order). The Model/spec
  reattachment half was REFUTED — the schedule keys off stable tags
  (`project_panel.dart:499-503`) — but the plan's `P-02` and the schedule's
  `P-01` can disagree, which `plan_symbols.dart:405-409` itself admits.
  *Fix: derive plan suffixes from the same stable ordinal as the schedule.*

## Theme D — one gesture should be one undo step
- **D1 (high; W1-6/W2-6)** Typing a project or floor name pushes one undo
  entry PER KEYSTROKE (`projects_screen.dart:82`, `building_screen.dart:
  172-173` → `_snapshot()` each) — "Gedung BRI Cabang Jakarta" is 25
  entries, evicting real edits from the 200-cap stacks. The commit-on-blur
  mechanism exists (`mechx_text_field.dart:16-22`) and is used correctly
  elsewhere. *Fix: `onCommitted` at both call sites.*
- **D2 (high; W2-7)** Every arrow-key nudge is its own undo step on both
  canvases (`layout_canvas.dart:834-835`; `electrical_canvas.dart:832`),
  while drags coalesce correctly. *Fix: snapshot on the first nudge,
  coalesce within an idle window (the drag-session pattern).*
- **D3 (med-high; W4-7)** Flipping feed strategy silently rewrites the whole
  pressure solve, riser tags, PRV zones and pump duty — from either of two
  workspaces, outside the undo timeline (`app_state.dart:57` is a bare
  setter; no settings `UndoDomain`). The reflexive Ctrl+Z reverts an
  unrelated drawing edit instead. *Fix: a status message naming what moved +
  a `UndoDomain.settings` (the annotation-domain pattern).*

## Theme E — draw-time scope: the canvas ignores its own filters
- **E1 (med; W3-8)** The draw endpoint's `_snap` filters only sheet+floor
  (`network_store.dart:175-196`): a cold-water run latches onto a duct or
  drainage node — including one on a HIDDEN or LOCKED service the user then
  cannot see or unpick. `inertServicesProvider` is consumed only by the
  selection overlay. *Fix: thread the active service + inert set into the
  draw/drop snap exactly as the marquee does.*
- **E2 (med; W2-11, adjusted)** Select-similar spans the entire building
  (`selection_store.dart:188-213`, no sheet/floor predicate) and the batch
  header counts but doesn't say the span — "Apply to 14 selected" changes DN
  building-wide when the drafter meant this floor. *Fix: default to
  sheet+floor scope with an explicit all-floors variant; name the span in the
  header.*
- **E3 (med; W2-13)** Flipping the discipline layer resets the drawing
  service to `scoped.first` (`project_panel.dart:2261-2268`) — Exhaust
  becomes Supply after any Plumbing round-trip. *Fix: remember the last
  service per layer.*

## Theme F — the first project: honesty and batons
- **F1 (high; W1-2)** After the two calibration clicks, the length field
  never takes focus — and a typed digit falls through to the canvas key
  handler, which SWITCHES THE DRAW SERVICE (`layout_canvas.dart:580` gates on
  `!isTextEntryFocused()`, which is false until the user clicks the field).
  *Fix: `autofocus` on the distance field; suppress bare-key service
  switching while calibration is active.*
- **F2 (high; W1-3)** The first solve's only feedback says "sizes shown on
  the plan" — but `showSizingProvider` defaults false and nothing sets it;
  the golden only shows DN labels because the test toggles it. *Fix: the
  one-shot nudge flips the toggle on, or the string names the toggle.*
- **F3 (high; W4-3, adjusted)** In the everyday Layout state there is no
  visible drawing TOOL: DRAW auto-collapses the instant the first element
  lands (`project_panel.dart:2331 defaultExpanded: !networkExists`) and the
  on-canvas tool cluster mounts only when the whole inspector is collapsed
  (`layout_canvas.dart:1339`). Two individually-sound fixes composing into a
  dead state; the entry point (the DRAW › header) survives, the tools don't.
  *Fix: mount the cluster whenever the DRAW section isn't expanded.*
- **F4 (med-high; W1-4 + W1-10)** Calibration completeness is never named at
  the moment of action: the stepper ticks Calibrate on `sheets.any(...)`, the
  export block names no sheet and offers no action (Dismiss-only banner),
  and the post-calibration baton always says "next: Building" even with four
  uncalibrated sheets — while `uncalibratedAmong` +
  `applyCalibrationToAllSheets` + the Review batch chip all exist. *Fix:
  branch the baton on the uncalibrated count; the export gate names the
  sheets and carries the batch action; stepper requires every edge-bearing
  sheet.*
- **F5 (med-high; W1-5)** Fixtures are placed generically: one Terminal card,
  `fixture: null`, silently sized at the 2.0-UBAP placeholder — into mains,
  pump, BOM and the issued report, with no marker and no issue (the air side
  has `air-terminal-unsized`; plumbing has nothing). *Fix: a
  `fixture-untyped` advisory + per-fixture palette cards feeding the
  existing `addTerminal(fixture:)`.*
- **F6 (med; W1-7)** A just-drawn room/tank is not selected (`add` returns
  void), so its type/ceiling/ACH inputs are a hunt; every drawn NODE gets
  selection-first treatment. *Fix: `add` returns the id; `_onPanEnd`
  selects.*
- **F7 (med; W1-8, adjusted)** Rooms are created at a hard-coded 3.0 m
  ceiling regardless of the floor the engineer just configured; the right
  seed is `floorHeight − ceilingDrop` (verifier correction), one lookup
  away, and it multiplies into ACH volume, CFM, ducts and cooling load.
  *Fix: seed from the floor at creation; field stays editable.*
- **F8 (med; W1-9)** `MountingHeights` (ceiling drop 0.3 / fixture height
  1.1) shapes every vertical length and static lift, is documented "editable
  per project", is constructed only as defaults, has no UI, no `.mechx`
  field, and no design-basis row in the report. *Fix: two Building-page
  steppers → a persisted project `MountingHeights` + two design-basis rows.*
- **F9 (med; W1-11)** Saving as `Gedung-BRI.mechx` leaves every title block
  "Untitled project": Save seeds the dialog from the name but never adopts
  the chosen filename back. *Fix: on first save with the default name, adopt
  the file stem.*
- **F10 (med; W1-13 + W1-14)** The Building page shows only the FIRST sheet
  per floor, hiding the pile-up it is the natural place to fix; and a
  template's forced import leaves floors 4-12 planless with the typical-floor
  tool (`duplicateSheetToFloor`) never offered. *Fix: per-level plan counts +
  list; post-template shortfall prompt offering assign/duplicate.*
- **F11 (med; W4-13)** The stepper ticks **Size** done while the BOM says
  `unmeasured ×5` (`command_store.dart:189` has no calibration gate) — the
  same honesty class the Floors tick was fixed for. *Fix: `sized &&
  calibrated`.*
- **F12 (low; W1-15)** Clicking the stepper's Calibrate with no plan arms an
  invisible mode (the empty state early-returns before the overlay mounts).
  *Fix: route to import when `sheets.isEmpty`.*

## Theme G — messages that name actions the app cannot perform
*The audit wave's new checks are honest physics with unusable prose.*

- **G1 (high; W3-3, adjusted)** `drainage-self-cleansing` fires on every
  DN50–DN80 branch of a DEFAULT project (1:100 default slope ⇒ 0.46-0.54
  m/s, the engine's own doc), and its advice — "use a smaller pipe" —
  violates the DFU minimum table; the one real lever (slope) is on another
  screen with no link. *Fix: fire only when the DN exceeds the DFU minimum;
  action becomes "Open drainage slope"; drop the smaller-pipe advice.*
- **G2 (high; W3-2)** One over-velocity water edge raises TWO warnings —
  `water-over-capacity` + `water-velocity:<id>` — the same physics on the
  same edge (the gravity dedupe at `design_issues_store.dart:369-373` proves
  the pattern was known). *Fix: mirror the gravity guard.*
- **G3 (med; W3-14)** The capped-selectivity message says "verify against
  manufacturer curves" but never says the device is already at the largest
  rung the load cable's Iz protects — the user's obvious move (raise the
  breaker) is precisely what the engine forbids; the real lever (raise the
  CABLE) is unnamed. No `feederFloorCapped` set exists to branch on. *Fix:
  record the capped set; branch the message: "device capped at the cable's
  Iz — increase the cable to N mm² to reach the 1.6× target".*
- **G4 (med; W3-12)** `pump-motor-oversized` is a permanent, unlocatable,
  unacknowledgeable compliance blocker whose advice ("specify a custom
  motor") has no in-app field — a legitimate large building can never PASS.
  *Fix: demote to info (the ResultCard already carries the honest verdict) +
  locate to Results.*
- **G5 (med; W3-11, adjusted)** `fire-pump-protection` instructs specifying
  overload-trip-disabled protection — no such field exists, and (verifier)
  its own comment claims it is "carried onto the schedule" while the code
  reaches neither schedule nor drawing. *Fix: reword as a documentation note
  AND actually print it in the schedule KETERANGAN.*
- **G6 (med; W3-13)** "Target held by design" appears ONLY on a uniform
  field; a real non-uniform upfeed ramp shows an uncaveated Min tick — the
  engineer reads PASS off an unfalsifiable inequality; and the caption never
  points at the falsifiable question (the pump duty). *Fix: caption both
  branches; append "the real check is the pump duty".*
- **G7 (med; W3-18 + W3-15 + W3-7, adjusted)** The Building design inputs
  explain nothing: the slope stepper's `+` makes the number smaller
  (1:100→1:90), "5 K" is unexplained, the AC basis radio doesn't say what
  changes, no confirmation says sizing propagated — and all sit on
  `SteppedValueField`, which silently clamps/reverts invalid input while the
  electrical fields reject with a message. Calibration's Set-scale also
  no-ops silently on a bad length. *Fix: effect captions + steeper/flatter
  hints + a status pill on commit; give `SteppedValueField` the reject-path;
  disable Set-scale until a length parses.*

## Theme H — silent cross-workspace effects
- **H1 (high; W4-6)** Placing a pump on the plan silently creates a board,
  sizes a circuit and appends an MDP feeder in another workspace — no
  toast, no badge (the palette drop path narrates richly; the sync path has
  zero `showStatus`). *Fix: the same toast idiom from the sync + a nav
  badge when the machine-owned board changes.*
- **H2 (high; W3-5)** Declaring ANY source (a rooftop PV, a battery)
  switches off `electricalConnectivityDefects` PROJECT-WIDE
  (`connectivity.dart:81,97` — `sources != null` ⇒ every board skipped), so
  a genuinely floating sub-panel is no longer reported anywhere. *Fix: gate
  per-panel — an extra root is legitimate only if essential or
  source-reachable.*
- **H3 (high; W3-6)** Export-with-nothing-to-export is a total no-op: the
  write fns return false (= "user cancelled") so `runExportGuarded` says
  nothing — including the global **P** accelerator. *Fix: separate
  "cancelled" from "nothing to write"; raise the error surface.*
- **H4 (med; W3-17)** No long operation is cancellable; the ODA convert has
  no timeout (`dwg_converter.dart:171`), and DXF import parses on the UI
  isolate (`dxf_import.dart:33`) though Open was isolate-offloaded. *Fix:
  timeout+cancel on the process; move import parsing onto the Open isolate
  helper.*
- **H5 (high; W3-1, understated)** The new drainage-slope input drives
  sizing and the report — but every DRAWING stamps the hard-coded default
  fall: plan DXF, plan PDF, annotated PDF, the submittal package (PDF+DXF),
  the on-canvas label, and (verifier) the live invert readout
  (`drawing_overlay.dart:279`) — six sites passing
  `const SizingContext().drainageSlope` against the contract stated verbatim
  at `plan_symbols.dart:436`. The issued sheet contradicts the signed
  report. *Fix: thread `drainageSlopeProvider` at all six sites.*

## Theme I — the export surface and cross-project continuity
- **I1 (high; W2-4, adjusted)** The remember-last-folder wrapper is used by
  10 dialogs; 14 raw `FilePicker.saveFile` sites bypass it (electrical ×7,
  riser ×4, commercial ×2, save-as) — a revision re-navigates the OS picker
  over and over. *Fix: route all through `pickExportSave`; a sibling seeds
  imports.*
- **I2 (med; W2-16)** The submittal package omits the riser DXF, electrical
  overview PDF/DXF, electrical riser, power one-line and electrical calc
  report — each its own menu trip + dialog every revision. *Fix: extend
  `writeSubmittalPackageToDir` behind an include-list.*
- **I3 (med; W2-14)** The drafter's own library — custom fixtures, saved
  assemblies (whose doc promises "across projects"), pricelist, sign-off
  identity — lives only in the `.mechx`; File→New wipes it. *Fix: seed-able
  defaults in the machine-local `AppSettings`; the `.mechx` copy stays
  authoritative.*
- **I4 (med; W2-15)** No selection-to-multiple-floors paste: a shaft group up
  six floors is six switches + six pastes; the only batch clones the WHOLE
  floor. *Fix: `pasteToTargets` over the existing clipboard clone, one
  undo.*
- **I5 (low; W3-20)** The export blocker still says "element(s)" (the purged
  dev-speak) and import failures print raw `FormatException`s. *Fix:
  `pluralCount` + mapped messages ("That file isn't a readable DXF — is it a
  DWG?").*

## Theme J — workspace parity and chrome
- **J1 (med; W2-12/W4-11, adjusted)** The electrical canvas is the one
  workspace that forgets where you were: transform + selection live in
  widget State destroyed on every hop (and it never reads
  `electricalSelectionProvider`, so the two electrical surfaces disagree on
  selection). The riser fixed exactly this via `schematic_view_store`.
  *Fix: lift both into a transient provider.*
- **J2 (med; W4-12)** Read-only electrical tabs show 20 disabled palette
  cards; the mechanical Riser shows a live SYSTEM summary. *Fix: an
  electrical `RiserSystemSummary` equivalent (boards / ways / demand /
  essential split) on read-only tabs.*
- **J3 (med; W4-14, adjusted)** The heatmap IDW washes the entire sheet —
  colour in empty corners is extrapolation presented as measurement, over
  the plan the user draws against. (The "Min tick outside the ramp" half was
  corrected: the tick is deliberately clamp-pinned; the defect is
  mis-position, not out-of-range.) *Fix: mask the field to a corridor around
  the network.*
- **J4 (med; W4-15)** The electrical layer paints phase colours with no
  legend anywhere on the canvas (the legend chip renders nothing for
  electrical; the same palette is column-headed R/S/T in the schedule).
  *Fix: electrical legend content (R/S/T/feeder/essential) via the same
  chip + a muted group for ghosted disciplines.*
- **J5 (low-med; W4-16)** The per-service funnel renders after the Electrical
  row though it filters Plumbing, and an isolate persists invisibly when its
  owning layer goes inactive (the funnel hides, the filter keeps applying).
  *Fix: render beside the active segment; park the isolate with its layer.*
- **J6 (low; W4-17)** Two minimap implementations (Layout's shared
  `CanvasMinimap` vs the electrical private `_MiniMap`); the riser has none
  (recorded deferral). *Fix: point electrical at the shared widget.*
- **J7 (low; W4-18)** Commercial still leads with "the electrical bill of
  materials" above a Mechanical BOM, exports `-mep-bom.csv` under the guard
  name "electrical BOM", and 'Mechanical BOM' is an unlocalized literal.
  *Fix: one M+E+P string batch.*

---

## Waves

- **Wave 1 — the broken loop + data safety (highest yield):** A1 A2 A3
  (the Locate contract), C1 (sync data loss), C2 (floor-delete fusion), C3
  (cross-sheet Delete guard), H5 (the wrong fall on issued drawings), H2
  (connectivity check going dark), B1 (riser invisible upstairs), G2 (the
  duplicate warning), H3 (silent export no-op).
- **Wave 2 — draw-time flow:** F1 F2 F3 (calibrate-type-draw honesty), B2 B3
  B4 (the riser contract + stable tags), C6, D1 D2 D3 (undo granularity),
  E1 E2 E3 (scope filters), F5 F6 F7 (fixtures + rooms).
- **Wave 3 — messages + review quality:** G1 G3 G4 G5 G6 G7, A4 A5 A6, F4
  F8 F9 F10 F11 F12, H1 H4.
- **Wave 4 — export + parity + polish:** I1 I2 I3 I4 I5, J1–J7, C4 C5.

The three highest-conviction fixes across all lenses (each independently
nominated by 2+ reviewers): **the Locate contract (A1-A3)** — one function,
four omissions, the app's most-repeated loop; **C1 + C2** — the two silent
data-destroyers; **H5** — the only finding that prints a wrong number on an
issued construction drawing.
