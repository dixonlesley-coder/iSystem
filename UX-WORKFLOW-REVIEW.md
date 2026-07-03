# UX & Workflow Review — simple, user-friendly, powerful

**Date:** 2026-07-02 · **Scope:** the full product UX + the end-to-end engineering workflow,
reviewed at v1.9.0 (after all 5 waves of `CAD-OUTPUT-UX-REVIEW.md` landed)
**Method:** a 12-lens multi-agent review through a senior-Apple-engineer eye — first-run,
drawing loop, calibration/setup, inspector IA, electrical, riser, review→deliverables,
visual/HIG, keyboard/a11y, feedback/data-safety, an end-to-end workflow walkthrough, and
power-user velocity + copilot. Every raw finding was then **adversarially verified against the
code** by a second wave of 12 verifier agents instructed to refute (reject if the code doesn't
behave as claimed, if it's already implemented, if it re-reports a landed prior finding, if it's
vague, infeasible, or trivial). **115 raw findings → 113 code-confirmed, 2 refuted**, consolidated
below into **83 items** (a merged item carries the strongest evidence and the highest justified
severity of its sources): **32 high · 42 medium · 9 low**. Two claims were additionally proven
empirically with scratch widget tests (B4, I1). File:line citations are the state of the code today.

The two questions asked:

1. What stops a **first-time engineer** from succeeding in their first hour?
2. What stops a **working drafter** from being twice as fast?

---

## Executive summary

**First contact is the weakest hour of the product.** A fresh launch shows three fake placeholder
sheets stamped with internal build jargon ("PDF import in P1") and a fictional 30 kW "Sample
building" switchboard whose warnings light a red Issues badge — and both fabrications ride into
the user's saved `.mechx`, BOM, quotation and reports unless hand-deleted. The carefully-built
empty states with their Import/template actions are unreachable dead code. There is no File→New,
no recent-projects list, and nothing (not even language) survives a restart.

**The trust layer has real holes under the polish.** Saves are non-atomic (a crash mid-save can
destroy the only copy *and* the recovery snapshot it would have restored); recovery lives in one
global slot in `%TEMP%`; rooms/tanks/measurements and every design setting sit outside the undo
timeline so Ctrl+Z silently reverts the wrong domain; and a Backspace typed into the calibration
field deletes the selected node (proven in a widget test). Fourteen export paths bypass the shared
export guard the app built precisely to stop silently-wrong deliverables.

**Drawing is precise but lonely.** The Run tool cannot tee into an existing pipe — the most common
plumbing action silently produces a disconnected network that another screen later reports as a
defect. There are no single-key tool shortcuts, no batch property edit behind the app's own
"select similar", no group move, and paste stacks byte-identical fixtures invisibly on top of each
other. The engineer does the computer's repetition.

**The M+E+P promise is half-wired.** The provider that folds solved pump/fan/fire duties into
electrical circuits is dead code — placed equipment feeds catalog defaults, never the numbers the
app just computed; the auto-synced MEP panel silently rebuilds on any plan edit, wiping user
wiring; the compliance verdict is structurally incapable of reaching PASS; and "Commercial" prices
only the electrical discipline. Meanwhile the review found the prior review's own completion
banner is inaccurate: **six items it lists as landed never shipped** (see "Prior-review
discrepancies").

None of this needs an architectural change. Nearly every fix reuses machinery the app already has
— the export guard, the undo funnel, the empty-state card, the snap/split logic, the StringKey
mechanism — and the sequencing at the bottom orders them so trust lands first, speed second.

---

## Already excellent — keep, and build on

- **The interaction bright spots are genuinely first-class**: wheel-zoom-to-cursor + middle-drag
  pan, drag-place ghost previews with snap rings, the Measure tool's live dimension chip, the
  smart input bar (direct distance entry), staged calibration with live preview, the Esc ladder
  and mode pill on the Layout canvas, one-drag-one-undo, screen-clamped context menus.
- **One-geometry discipline** (`SldSheet` → PDF/DXF/canvas) held through every drawing family;
  the riser and electrical single-lines are professional-grade deliverables.
- **Honesty by construction** in the engine layer: data-gated callouts, `// VERIFY` registers,
  tiered standards provenance, placeholders that say they're placeholders — the gaps found below
  are almost all places the *app shell* fails to live up to the *engine's* standard.
- **The gate** (analyze + engine tests + app tests + goldens) and the additive/byte-identical
  discipline make every fix below safely landable.

## Prior-review discrepancies (correct the record)

`CAD-OUTPUT-UX-REVIEW.md` closes with "all 5 waves complete… every actionable finding landed or
explicitly dispositioned." Code verification found six items where that is not true — they appear
in no wave row of the §15 decisions log and the code confirms they never landed:

- **H4** (inspector section order): Sheet/Scale are still dead last, below Document control, and
  are the only major sections not collapsible (`project_panel.dart:902-1061`, `:995`). → E10
- **H7** (Network/Fire empty-state honesty): `BOM total 0.0 m`, dash rows, and a green "rated"
  fire verdict still render on a blank project (`project_panel.dart:2253`, `:2426-2438`). → E11
- **I4** (electrical Esc parity): `electrical_view.dart` has zero key handling. → G4
- **I2** (half): issue locations carry `circuitId` but the Review→Electrical jump forwards only
  the panel (`issues_card.dart:90-94`). → H7
- **J6** (zoom pill): still renders the Layout sheet's zoom on every screen (`app_shell.dart:266`,
  `:324-337`). → J3
- **J8** (copilot Esc): no `copilotOpenProvider` check ever appeared in any Esc handler. → I4

Amend that document's status note; the items are folded into the findings below.

---

## Part 1 — Trust: first contact and data safety

### A. First-run & the project lifecycle

1. **Kill the P0 demo scaffolding on first launch** *(high/medium)* — `SheetsController.build()`
   seeds three fake sheets ("Ground Floor"/"First Floor"/"Roof Plan", `sheets_store.dart:61-76`)
   and the placeholder page prints the internal milestone "PDF import in P1"
   (`sheet_canvas.dart:298-301`; dead-centre of golden 01). The landed J1 empty-state card with
   its `Import plan…`/`New from template…` actions is gated on `sheet == null` — unreachable on
   a cold launch (`layout_canvas.dart:599-624`). Work drawn on placeholder paper is a dead end
   that Import then discards. Seed `SheetsState()` empty in production, seed the demo sheets
   explicitly in tests, and rewrite the placeholder caption in plain language.
2. **Stop seeding the fictional "Sample building" switchboard** *(high/medium)* —
   `ElectricalProjectController.build()` returns `sampleElectricalProject()` (a fake MDP with
   chiller/booster pump/11 kW fire pump + LP-1, `electrical_store.dart:215`, `:1094-1201`);
   `buildDocument` persists it into every fresh project's `.mechx` (`autosave.dart:109`); the
   commercial pipeline prices it; its 2 warnings light the red `Issues (2)` badge on goldens
   05/08/11 for panels the user never created; and the guided electrical empty state is dead code
   (`electrical_view.dart:356`). The empty-project fallback at `autosave.dart:203-210` fixed only
   the *Open* path. Seed `const ElectricalProject()`; expose the sample behind a "Load sample
   project" action on the empty state (`resetToSample()` already exists at `:441`); re-seed the
   electrical goldens in the screenshot test.
3. **There is no File→New — and "New project from template" doesn't create one** *(high/small)* —
   the only path to a fresh project is relaunching the app. `applyTemplateTo` sets floors/
   occupancy/fire/rainfall only (`templates.dart:132-140`) while name, network, sheets,
   calibrations and the electrical project all survive — yet the card says "New project from
   template" (`projects_screen.dart:127`). Add a real New (dirty-guard → `applyDocument` a virgin
   document → clear `currentProjectPathProvider`/`lastSavedSignatureProvider`); relabel the
   template card honestly.
4. **Nothing survives a restart: no recents, no reopen-last, preferences reset** *(high/medium)* —
   no app-level persistence exists anywhere; `currentProjectPathProvider` is deliberately
   session-only (`app_state.dart:236-243`), locale re-seeds EN and theme dark on every launch
   (`:267-303`) — an Indonesian engineer re-picks Bahasa every morning, then hunts yesterday's
   file through the OS dialog. One small JSON settings file in an app dir (offline, plugin-free)
   carrying MRU + last-open + locale + theme + AI provider/key; MRU rows on the Projects screen
   and in the palette.
5. **Import always replaces ALL sheets — and the orphaned network keeps feeding deliverables**
   *(high/medium)* — `importPlan` only calls `loadSheets` (`project_io.dart:95`), never pruning
   nodes or calibrations; sizing/BOM iterate the whole network with no sheet-existence filter
   (`sizing_store.dart:134-149`), so after a replace, invisible phantom pipes pad the BOM and
   reports with zero surface anywhere (the Design-Issues loop iterates live sheets only,
   `design_issues_store.dart:213`). Worse, sheet ids are `'$stem#$i'` (`pdf_import.dart:33`), so
   re-importing rev B of `denah.pdf` re-marries the OLD calibration + drawn work to the new pages
   — the rail even shows a calibrated dot the user never earned. Offer Add-to-project vs Replace;
   add per-sheet "Replace plan…" keeping the sheet id (the real revision workflow); prune or
   surface orphans as a critical issue with a select-and-delete quick fix.
6. **A project cannot contain more than one imported file — DXF/DWG projects are single-floor**
   *(high/medium)* — the picker is `allowMultiple: false` (`project_io.dart:56`), `loadSheets`
   replaces, `addSheet` has zero UI callers (`sheets_store.dart:151`), and DXF/DWG importers
   return one sheet per file. Indonesian sets arrive as one file per floor; today that building
   cannot be modelled without merging in another tool. Add "Add sheets…" (multi-select, appends);
   give rail items a context menu (Rename / Assign floor / Calibrate / Remove).
7. **The OS window title is permanently "iSystem"** *(low/small)* — `WidgetsApp(title: 'iSystem')`
   is a constant (`app.dart:26`); the document name + edited dot exist only inside the top bar.
   Derive the title from watched state (`'name • — iSystem'`); goldens unaffected.
8. **The PDF page picker is text-only** *(medium/medium)* — choosing floor plans out of a real
   architecture set means guessing by "Page 17 · 1191 x 842" (`pdf_page_picker.dart:369-401`);
   the app already renders PDF pages via pdfrx. Small async thumbnails in the picker rows and the
   rail tiles.

### B. Data safety & the undo contract

1. **Saves and recovery writes are non-atomic — a crash mid-save can destroy the only copy**
   *(high/small)* — Save truncate-writes directly over the existing `.mechx`
   (`project_io.dart:142`), with no temp+rename, no `.bak`, and no in-flight lock (a second
   Ctrl+S can start a concurrent write); `writeRecovery` has the same flaw and `readRecovery`
   swallows ALL parse errors returning null (`recovery.dart:16-33`) — so a crash *during* an
   autosave tick tears the snapshot and the next launch silently shows no banner. Temp-write +
   rename everywhere (keep the displaced file as `.bak`); distinguish "absent" from "unreadable";
   no-op Ctrl+S while a save is in flight.
2. **Recovery: one global slot in `%TEMP%`, and Restore loses the file identity** *(high/small)*
   — `'${Directory.systemTemp.path}/mechx_recovery.mechx'` (`recovery.dart:11-12`) is shared by
   every project and instance (each clobbers the others every 15 s) and is purged by Windows
   Storage Sense; the snapshot carries no source path, and Restore never re-sets
   `currentProjectPathProvider` (`app_shell.dart:853-861`) so the next Ctrl+S is a Save-As that
   forks `tower (1).mechx`. Move under the app-support dir, key per project, store the source
   path, re-link on Restore.
3. **Rooms, tanks, measurements and every design setting sit outside undo — Ctrl+Z reverts the
   wrong domain** *(high/medium)* — `UndoDomain` is {network, project, sheets, electrical}
   (`history_store.dart:12`); the 620-line `annotation_store.dart` never snapshots or records;
   "Delete room"/"Delete tank" are one-click and unconfirmed (`project_panel.dart:1991-1998`,
   `:1693-1701`), and a secondary-click within 40 px deletes the nearest room while the Room tool
   is active (`room_overlay.dart:50-67`). A configured room (ceiling, ACH, type, equipment —
   minutes of input, feeding cooling loads and the electrical feed) dies to one mis-click, and
   Ctrl+Z then silently reverts an older, unrelated edit — the exact cross-domain trap the
   timeline was built to kill for electrical (I1), reintroduced. Add `UndoDomain.annotation`
   (the proven electrical pattern); drop right-click-nearest-delete for the standard context-menu
   idiom.
4. **Backspace/Delete/Ctrl+A typed into in-canvas text fields mutate the drawing** *(high/small;
   empirically proven)* — the Layout canvas's bubble-phase ancestor `Focus` handles Delete/
   Backspace/Ctrl+A/C/V with no text-entry guard (`layout_canvas.dart:434-480`), and the
   calibration "Known distance" field, smart input bar and electrical inspectors are its
   descendants: a widget-test probe confirmed Backspace inside the calibration field **deleted
   the selected node**. The Space handler right beside them already guards `textEntryPossible`
   (`:372-384`) — proving the hazard was known. Extend that guard to every destructive/selection
   shortcut here and in `electrical_canvas.dart`/`schematic_view.dart`.
5. **"Restart & update" is the one exit that bypasses the unsaved-work guard** *(medium/small)* —
   `launchInstaller` calls `exit(0)` (`update_service.dart:139-151`), which never triggers
   `AppLifecycleListener.onExitRequested`, and `installUpdate` does no dirty check
   (`update_provider.dart:74-78`). Loss is bounded by the 15 s autosave tick, but a guard that
   covers three of four exits trains false confidence. Run the same dirty check + dialog;
   `writeRecovery` synchronously before exiting.
6. **Editing the floor stack under a drawn network corrupts or crashes it — and the template
   dialog promises the opposite** *(high/medium)* — `setFloors`/`removeFloor` never remap node
   `floorIndex` (`project_store.dart:113-126`); `floorHeightOf`/`ceilingElevationOf` index
   `floors[index]` raw (`building.dart:63-75`), so a node above the new top throws a RangeError
   inside the always-on sizing provider; removing a middle floor silently re-elevates every
   higher node (§10 lengths rewritten under the engineer's feet). The template dialog claims "the
   drawn network and calibration are left untouched" (`templates_dialog.dart:86-91`) while
   calling `setFloors`. Remap/clamp in the same undo step or block with a count; clamp the engine
   accessors; add a critical Design Issue for out-of-range floor references; fix the dialog copy.
7. **Re-mapping a sheet to another floor makes its drawn work vanish — and the sheet→floor
   default silently piles pages onto the top floor** *(high/medium)* — nodes freeze `floorIndex`
   at creation; `setSheetFloor` edits only the mapping (`sheets_store.dart:123-129`) and the
   canvas filters on BOTH keys (`network_layer.dart:216`), so the natural correction hides
   everything drawn on that sheet while it keeps feeding sizing at the old elevation. `floorFor`
   silently clamps (`sheets_store.dart:40-44`): import 8 pages into the 3-floor default and pages
   4-8 all map to the top floor, invisibly (the rail shows no floor tag). Remap the sheet's nodes
   with the mapping in one undo step; warn on pile-up; stamp the mapped floor on the rail tile.
8. **The BYO AI key is saved in plaintext inside the shareable `.mechx` — and mirrored to
   `%TEMP%` every 15 s** *(medium/medium)* — `project_document.dart:207` writes
   `anthropicApiKey` unconditionally into a file the product deliberately makes portable for
   handoff; the autosave mirror copies it into the world-readable temp dir. Move the key to the
   machine-local settings file (A4); keep reading legacy keys for migration but stop writing;
   blank it in recovery/save encodes immediately.
9. **The Edited dot lags reality by up to 15 s in both directions — and a Save-then-Undo leaves
   dirty work with no recovery snapshot** *(low/small)* — `projectDirtyProvider` is only written
   inside the autosave tick (`autosave.dart:232-243`), and the tick's `lastWritten` closure is
   never reset by Save (`:231, 246-250`), so undoing back to a previously-mirrored state after a
   Save skips the rewrite: dirty project, zero snapshot. Flip the dirty flag eagerly on
   `historyProvider.record()`; hoist `lastWritten` into a provider cleared on Save/Open.

---

## Part 2 — Speed: the drawing loop and editing at scale

### C. The core drawing loop

1. **The Run tool cannot tee into an existing pipe — the most common action silently builds a
   disconnected network** *(high/medium)* — `placeRunPoint` resolves both endpoints via the
   node-only `_snap` (`network_store.dart:132-194`); the edge-splitting logic exists but only the
   free-node drag path uses it (`_tapFreeNodeIntoNearestEdge`, `:1100-1190`); the rubber-band
   ring marks nodes only. Ending a run ON a main looks connected, but the branch's demand never
   accumulates — undersized mains and a wrong BOM until Review reports the island the drawing
   tool just manufactured (`design_issues_store.dart:241`). Reuse the existing split logic for
   both Run endpoints; ring the edge-projection point when the click will tee in.
2. **The palette-drop preview advertises a snap that never happens for fittings/terminals/
   equipment** *(high/small)* — the snap ring + will-snap tint paint for every dragged item
   (`drop_overlay.dart:131-186`) under a comment claiming the ring marks "exactly the node a drop
   will attach to", but `addFitting`/`addTerminal`/`addComponentNode` create a FREE node with no
   merge (`network_store.dart:764-825`) — and the (?) guide even promises "Drag a Terminal onto a
   main to branch it", which never happens. A ringed drop that lands coincident-but-unconnected
   carries demand the solve never sees. Merge on drop within the ring radius (adopt the ringed
   node / tap into the edge); otherwise suppress the ring.
3. **Zero single-key shortcuts for tools or services** *(high/small)* — the complete canvas key
   set is modifier combos + Delete/Esc/Space (`layout_canvas.dart:367-527`); every Select↔Run or
   cold↔drainage switch is a mouse trip into a twice-collapsible inspector section
   (`project_panel.dart:1381-1455`). Add V/R/E/M/K/B tool keys + 1-5 service keys behind the
   existing `textEntryPossible` guard; echo them in tooltips, the mode pill and the (?) guide.
4. **Direct-distance entry needs a mouse trip first, and a typed exact length can silently snap
   elsewhere** *(medium/small)* — the smart input bar never takes focus when it appears
   (`smart_input_bar.dart:33-36, 76`), so "click, type 3000" does nothing until the user mouses
   into a 96-px field; its commit also omits `snapRadius` (`:69-73`), inheriting a zoom-
   inconsistent 12 *world*-px default that can merge a typed-exact point onto a nearby node.
   Autofocus while drawing; honour typed lengths (snapRadius 0 or declare the snap).
5. **The outlet-nub pull — the promoted mainline gesture — ignores ortho and shows no length or
   snap preview** *(medium/small)* — `_endPull` passes the raw release point (no `orthoSnap`;
   `selection_overlay.dart:76-89`) and `_PullPainter` draws a bare dashed line — no length chip,
   no ring — though `drawRunFromNode` does snap and split. Every nub-drawn main is slightly
   askew. Apply ortho (Shift overrides) and reuse the shared rubber-band painter.
6. **The Riser tool dead-ends silently on the top floor** *(medium/small)* — `placeRiser` returns
   without any state change when `floorIndex + 1 >= levelCount` (`network_store.dart:206`);
   armed tool, click-click-click, nothing — and an engineer on the roof plan (where downfeed
   work happens) cannot connect downward at all. Make the pill say what the riser will connect;
   place downward on the top floor or fire the status pill explaining.
7. **Permanently-visible outlet nubs read as blue confetti on a dense plan** *(medium/small)* —
   an accent-blue nub renders beside EVERY non-fixture node, always (`selection_overlay.dart:
   207-211, 328-367`), competing with the selection language over the drawing. Gate to hovered +
   selected nodes (`hoverTargetProvider` already publishes).
8. **Ctrl+Z mid-chain deletes the segment but also silently ends the run** *(medium/small)* —
   `undo()` rebuilds `DrawingState` without `pendingPoint` (`network_store.dart:331-340`), so the
   polyline-standard correction gesture drops the rubber band and invites a disconnected re-start
   (compounding C1). Preserve the chain anchor through undo while drawing.
9. **No hold-Shift ortho override** *(low/small)* — the one-off diagonal costs four inspector
   round-trip actions; treat effective ortho as `orthoProvider XOR shift` in preview + commit
   (`drawing_overlay.dart:77-79, 102`).

### D. Calibration & building setup

1. **No way to type the drawing's stated scale — and readouts speak scientific notation in three
   dialects** *(medium/small)* — the only path is the two-point measure, though a plotted PDF's
   `1:100` is exactly `metersPerPixel = 100 × 0.0254/72` from the known points basis
   (`pdf_import.dart:11-13`); the readouts are `1 px = 3.53e-2 m` (`project_panel.dart:1021`),
   `Scale approx 3.53e-2 m/px` (`calibration_overlay.dart:66`) and `1 m = 28 px` (`:46-48`) —
   never the `1 : N` the app's own exports print. Add a "Drawing scale 1 : N" type-in with ladder
   presets (two-point stays the verify path); one shared human formatter.
2. **"Apply scale to all sheets" silently overwrites different calibrations** *(medium/small)* —
   the button stamps ALL live sheets (`project_panel.dart:1048-1057`; `project_store.dart:
   165-176`) — including a 1:500 site plan among 1:100 floors — with no confirm, no status pill,
   no count; the safe uncalibrated-only variant exists only as a Review quick-fix. Default to
   uncalibrated-only; confirm before overwriting a differing scale; always report the count.
3. **A calibration misclick forces a full restart, and Space-pan is disabled while placing
   points** *(low/small)* — no back-step exists (`calibration_store.dart:46-63`), markers can't
   be re-placed, and the Space guard covers all phases though its rationale (the length field)
   exists only in `awaitingDistance` (`layout_canvas.dart:378-382`). Scope the guard per phase;
   let a click near an existing marker re-place it.
4. **Floor heights are ±0.1 m click-steppers — the H2 type-in wave never reached the Building
   screen** *(medium/small)* — `_StepperRow` in `building_screen.dart:187-223` has no type-in and
   no hold-repeat, on the screen that is the §10 source of truth; a 20-storey tower is 17 clicks
   plus ~7 per non-default height. Swap in the shared `SteppedValueField`; add "Add N levels @
   H m".
5. **Sheet→floor mapping is a ±1 glyph stepper** *(low/small)* — the one numeric row the H2 wave
   missed (`project_panel.dart:967-987`); remapping a sheet to Level 12 is 11 clicks. Type-in
   stepper or a floor-name dropdown.

### E. Editing at scale (20 rooms, 40 fixtures, 6 services)

1. **"Select similar" leads nowhere: no batch property editing exists at all** *(high/medium)* —
   the multi-selection editor offers exactly Copy/Paste/Delete (`project_panel.dart:2602-2658`);
   every setter is single-id (`network_store.dart:611-665`); and the size/material context menu
   both edits one edge and *destroys the multi-selection* via `afterEdit → selectEdge`
   (`edge_context_menu.dart:406-409`) — while `selection_store.dart:181` documents select-similar
   as "batch-edit size/material/delete in one gesture" and the Review quick-fix chips hand the
   user selections with nothing to do. Add plural setters (one undo step, mirroring `deleteMany`)
   + shared property editors on homogeneous multi-selections; context menu applies to the
   selection when the target is in it.
2. **A multi-selection cannot be moved** *(medium/small)* — dragging any member collapses the
   selection to that node (`selection_overlay.dart:302-305`) and moves it alone; no `moveMany`
   exists; arrow keys pan instead of nudging. Group-drag with one delta under the existing
   drag-merge undo pattern; arrows nudge when a selection exists.
3. **Repeated Ctrl+V stacks byte-identical fixtures invisibly** *(high/small)* — `paste()` applies
   a constant (24,24) offset to the *original* coordinates and never re-bases
   (`network_store.dart:1298-1318`), so the 2nd+ paste lands exactly atop the 1st: hidden
   duplicate demand or a phantom island. No count×spacing array exists for the 20-identical-
   toilets job. Cascade the offset by generation or paste at cursor; add "Paste N copies…".
4. **Replicating a typical floor up a tower is one hidden command at a time, failing silently**
   *(medium/small)* — the only UI is the palette's "Duplicate floor up" with three bare `return`s
   (`command_palette.dart:154-183`); a 20-storey tower is 19 sheet-switch+palette cycles whose
   no-op looks like success. A "Duplicate floor to…" range dialog looping the existing store
   method, + the status pill, + say when a target has no sheet.
5. **No reusable assemblies/blocks** *(medium/medium)* — the clipboard is session-only
   (`network_store.dart:56-57`) and templates stop at floor counts; the toilet group and pump-room
   hookup get redrawn every project. Additive `DesignSettings.savedAssemblies` (the paste clone
   map already re-instantiates); drag-drop cards via the existing palette/DropOverlay path; ship
   2-3 Indonesian starter assemblies.
6. **Rooms and tanks are not first-class canvas objects** *(high/medium)* — with the tool
   inactive the overlays are `IgnorePointer` (`room_overlay.dart:90-93`): a room can never be
   clicked, moved, or resized (the controllers expose no coordinate mutation), so a footprint
   drawn 0.5 m off means irreversible-delete + redraw + re-enter every property; inspector row
   taps don't frame the canvas footprint either. Select/drag/resize/double-click via the existing
   idioms, on the new annotation undo domain (B3).
7. **Every room is named "Room" and cannot be renamed — into the issued equipment schedule**
   *(medium/small)* — `RoomArea` defaults `name:'Room'`, `setName` has zero call sites, and the
   equipment schedule exports `service: r.name` (`project_panel.dart:568`) — 20 AHU rows all
   reading "Room". Seed "Room 1/2/…", show the name in row + caption, wire the dead setter to a
   text field.
8. **"Auto-place diffusers" stacks duplicates and strands terminals nothing checks**
   *(medium/small)* — re-running the button appends a full second generation exactly atop the
   first (`network_store.dart:838-905`, no idempotence), silently doubling carried airflow; and
   the placed terminals have no edges, so they're invisible to `airUnsizedProvider` (they carry
   faces), to connectivity (node set built from edges), and to sizing/BOM — the room's air is
   stranded with zero warning. Make placement idempotent (clear the room's prior terminals in the
   same undo step); emit a "diffuser not connected to any duct" issue for airflow-bearing,
   edge-less nodes.
9. **The selected edge's inspector displays size/material but cannot edit them** *(medium/small)*
   — `_edgeEditor` renders "Material: X" as plain text and offers only "Clear size override"
   (`project_panel.dart:3059-3064, 3131-3135`); the real editors live solely behind an
   unadvertised right-click (whose coaching line the declutter pass removed). Add the size ladder
   + material pills to the editor, calling the existing setters — the node editor already has the
   pattern.
10. **Inspector section order still fights the workflow (H4, never landed)** *(medium/small)* —
    Scale, the gating step, is dead last below Document control and cannot collapse
    (`project_panel.dart:902-1061`); on the goldens everything from Sizing down is below the
    fold while the app's own banner demands calibration first. Move Sheet + Scale under Building;
    wrap in DisclosureSections with calibration-aware defaults.
11. **Network/Fire empty-state honesty (H7, never landed)** *(low/small)* — a blank project shows
    `BOM total 0.0 m`, dash-filled rows, and a green "rated" fire ResultCard computed from
    building defaults alone (`project_panel.dart:2253, 2225-2226, 2426-2438`). Gate on real data
    with the HVAC-style muted caption; caption the fire card "draft demand from building
    defaults" until fire edges exist.

---

## Part 3 — Workspace parity

### F. The Riser workspace

1. **The Riser view mounts the entire Layout inspector — a wall of dead controls, including a
   'Riser' tool that isn't this view's riser tool** *(high/medium)* — `app_shell.dart:186-202`
   always shows the full ProjectPanel + sheet rail; the Draw tools and palette drags mutate the
   *Layout* canvas state (the schematic accepts only `_RiserDragData`,
   `schematic_view.dart:1049`), so golden 07 shows two independent selected "Cold water" controls
   and an Enter-drop lands on a canvas you can't see. Scope the inspector by workspace view
   (selection editor, Building, riser service picker, results) via the existing electrical-swap
   seam.
2. **Auto mode — the primary riser diagram — cannot zoom or pan** *(high/medium)* —
   `_AutoElevation` is a fixed viewport-fitted CustomPaint (`schematic_view.dart:663-694`; its
   own comment: "the Auto view has none today") while Edit mode beside it has full wheel/pan +
   ZoomControls. On a 10-20 storey building the tags and fan-outs compress to unreadable slivers
   with no recourse but exporting a PDF to read your own screen. Reuse the Edit-mode
   ViewportTransform pattern.
3. **Clicking a riser in Edit mode pushes a phantom undo step and destroys redo** *(high/small)*
   — `_onPointerDown` calls `pushUndoSnapshot()` on hit, before any movement
   (`schematic_view.dart:868-884`), which appends to the global timeline and clears `_redo`
   (`network_store.dart:1421-1427`). Select-to-inspect corrupts undo/redo — the exact class G4
   fixed elsewhere. Defer the snapshot to first movement (the onPanStart semantics the Layout and
   electrical canvases already use).
4. **The Riser workspace is a keyboard dead zone** *(medium/small)* — Edit's `_onKey` handles
   only Delete/Backspace (`:932-944`); no Ctrl+Z/Y (though every drag pushes a snapshot you then
   can't pop from here), no Esc anywhere (export menu and help close only by scrim/button), no
   autofocus. Copy the Layout canvas's history + Esc ladder; autofocus on arrival.
5. **Toolbar chip soup — modes, a filter, five view toggles and an action all look identical, and
   chips clip off-screen** *(medium/medium)* — everything is the same `_TabButton`
   (`schematic_view.dart:362-443`); Export is an action styled as a never-selected toggle with a
   hardcoded EN label; golden 07 clips "Exhau…" mid-word with Sprinkler/Hydrant scrolled out of
   existence (fire drawing effectively hidden). Tabs stay tabs; Export becomes a MechXButton;
   Legend/Title-block fold into a View popover or the Export menu; wrap or fade the chip strip.
6. **Auto-view labels repeat per segment and collide with floor labels** *(medium/medium)* — one
   main carries three identical `15-CW-PPR-GRAVITASI` tags and a riser tag prints across the
   floor label (golden 04); `_paintEdges` stamps every edge's midpoint with no merging or
   collision pass (`schematic_view.dart:1583-1654`) while the *export* builder got B5's
   collision-managed labels — the preview is dirtier than the deliverable. Label once per
   continuous run; reuse the export's occupied-rect pass.
7. **Every Riser-view setting resets on each hop to Layout and back** *(medium/small)* — mode,
   focus filter, toggles and Edit's viewport are all widget-local state destroyed on workspace
   swap (`schematic_view.dart:80-116`; `app_shell.dart:186-188`), punishing the core
   hop-fix-hop-back loop. Lift into a transient provider (the `sectionVisibilityProvider`
   precedent).
8. **Riser empty states are dead ends** *(medium/small)* — "No network drawn" with no path
   forward; the <2-floors banner names the fix but carries no button (`schematic_view.dart:
   653-659, 1080-1090`). "Go to Layout" / "Edit floors…" actions via the J1 pattern.
9. **The Notes card and exported KETERANGAN assert "(roof tank)" the design doesn't contain**
   *(medium/small)* — both hardcode `Feed: gravity downfeed (roof tank)` from the strategy alone
   (`schematic_view.dart:2759-2762`; `schematic_export.dart:103-107`) — golden 04 shows the claim
   on a tankless network, on the same sheet whose plant detail honestly omits the tank. Append
   "(roof tank)" only when a roofTank exists (the conditional `_supplyNote` already implements
   exactly this).

### G. The Electrical workspace

1. **The flagship MEP→electrical bridge never delivers the solved duties — the full-sync provider
   is dead code** *(high/medium)* — auto-sync consumes only `placedEquipmentCircuitsProvider`
   (`electrical_store.dart:211-214`); `mepEquipmentCircuitsProvider` — the one that folds the
   solved pump/fan/fire-pump duties into circuits — has ZERO consumers outside tests
   (`electrical_feed.dart:171`), and no "Sync MEP equipment" button exists. Even placed nodes feed
   `defaultMotorKw` catalog fallbacks, never the solved duty (`electrical_feed.dart:140`), and a
   placed pump used as a fire pump loses life-safety treatment (`load_list.dart:78`). The
   engineer re-types the numbers the app just computed — the double-entry the M+E+P merge exists
   to eliminate. Wire the duty circuits visibly (e.g. "Add to electrical panel" on the pump/fan/
   fire ResultCards → `syncMepEquipment`), map placements onto solved duties via `flaOverrideA`,
   and give fire-pump components a fire-pump source.
2. **Any plan edit silently rebuilds the "MEP Equipment" panel, wiping user edits — with no cue
   it is machine-owned** *(high/medium)* — `syncMepEquipment` drops and reconstructs the panel
   (fixed name/tag, no feeder/position/diversity/headroom, `electrical_store.dart:1070-1087`),
   undo-exempt by design, re-fired by ANY network/room/calibration change — yet the panel renders
   as an ordinary editable board that accepts drops and edits. Renames, cable types, run lengths
   and the MDP→MEP feeder evaporate un-undoably when a node is nudged. Make the sync an UPSERT
   keyed by `sourceEquipmentId` (preserve user fields + added ways, drop only removed equipment);
   badge the panel "auto — from plan" and guard drops with the status pill.
3. **Every inspector keystroke is one undo step — and transient parses briefly re-size the whole
   system** *(high/small)* — the circuit/panel fields commit per character through `_commit`
   (snapshot + global-timeline entry each, `electrical_inspector.dart:233-326, 480-529`;
   `mechx_text_field.dart:104-107`), so renaming a panel buries the user's real last action under
   ~16 entries, and typing `0.85` into cos φ momentarily commits `0`, re-sizing breakers
   project-wide. The mechanical `SteppedValueField` already solved this (Enter/blur commit).
   Commit-on-blur/Enter for the electrical fields, or coalesce same-field snapshots in the store.
4. **Esc is dead in the electrical workspace (I4, never landed)** *(medium/small)* — five stacked
   overlay types (inspectors, drawers, export popover, context menus) close only by scrim/button;
   `electrical_view.dart` has zero key handling. One Focus with the standard Esc ladder — all
   close paths already exist as setState calls.
5. **The workspace's own Issues drawer lists warnings as inert text** *(medium/small)* —
   `ElectricalWarning` carries `panelId`/`circuitId` and the jump seam is live in the same file
   for Review-originated issues (`electrical_view.dart:172-179`), yet `_WarningRow` renders
   glyph + message with no tap target (`:1713-1757`) — the user hunts a 20-way board for
   `cable-ampacity-inadequate`. Make rows tappable → `focusPanelSchedule` + select the way.
6. **At schedule zoom, clicking the panel title (or a CADANGAN row) yanks the camera out — and a
   panel can't be selected at all in detail LOD** *(medium/small)* — the header carrying
   `_selectPanel` isn't rendered at detail (`electrical_canvas.dart:1409-1416`) and every non-row
   tap maps to `collapseToSummary` (`:1200-1207`), including spare rows (`_wayIndexAt` clamps to
   `circuits.length` while the sheet includes spares). Header tap = select; collapse only on the
   explicit chevron; spare-row taps no-op.
7. **A board's phase system and voltage are frozen at creation** *(medium/small)* — the panel
   inspector edits name/tag/diversity/headroom only; no store intent exists for system/voltage
   though `copyWith` carries both (`model.dart:439-473`), and the canvas's own encouraged flow
   (drop a floating load → 1φ 220 V stub board) produces boards that can never become the 3φ
   sub-board the design needs — except by delete-and-recreate, losing every way. One
   `setPanelSystem` intent + an enum picker row.
8. **"Add panel" mints duplicate SP-N tags after any deletion** *(medium/small)* — both mint
   sites use `count + 1` (`electrical_view.dart:404-412`; `electrical_canvas.dart:2277-2289`);
   delete SP-2 of three, add, and two boards print "SP-3" on every issued schedule — violating
   the no-duplicate-designation rule `duplicatePanel`'s own comment states
   (`electrical_store.dart:699-704`). Mint the first free ordinal.

---

## Part 4 — The deliverable and the last mile

### H. Review, compliance & the submittal

1. **The compliance verdict is structurally incapable of PASS — so it stops informing**
   *(high/small)* — `PuilProfile` permanently carries 5 `secondarySource` values (KHA/derating
   tables + the nominal voltages, unpromotable without the official PUIL PDF per CLAUDE.md),
   `designIssuesProvider` unconditionally surfaces each (`design_issues_store.dart:359-377`), and
   "Standards verification" passes only at zero (`project_panel.dart:339, 376-380`) — so every
   project forever reads REVIEW REQUIRED, the IssuesCard's "No design issues" state is dead code,
   and the engineer learns to ignore the one surface that also carries real blockers. Score
   info-severity items as pass-with-advisory (the summary already does this for other advisories),
   collapse the N identical rows into one, and/or add a persisted per-item acknowledgement —
   keeping the full tiered register in the report (guardrail 6 intact).
2. **The Review hub's verdict is a stale snapshot** *(high/small)* — `buildComplianceSummary`
   uses `ref.read` and both cards are `const` children (`review_hub.dart:55, 91`;
   `project_panel.dart:314, 357`), so fixing an issue via the quick-fix chips updates the live
   IssuesCard while the PASS/REVIEW verdict above it keeps the old answer until you leave and
   return — on the screen where the issue decision is made. Lift into a watched provider.
3. **Fourteen export paths bypass the shared export guard** *(high/small)* — all 10 electrical
   exports (`electrical_export.dart`, zero try/catch in the file), both commercial exports, and
   the single-sheet riser PDF/DXF (`schematic_export.dart:180-222`) write bare — no zero-length
   gate (golden 04's exact state: "Uncalibrated" + sized edges = fabricated riser lengths,
   exported silently), no success pill, no error handling (a locked file = an invisible no-op),
   no Report-stage credit — while their sibling riser-SET exports in the same file are guarded,
   and the guard's own doc says everything should route through it (`project_panel.dart:152-155`).
   Two power-one-line exports additionally silent-return when no sources exist. Route all 14
   through `runExportGuarded`; replace the silent no-ops with a status message.
4. **The export surface is scattered across six screens (~32 buttons), and the one card claiming
   the job misdirects** *(high/medium)* — Projects (9, incl. the ONLY plan exports), Review card
   (6 reports), riser menu (4), electrical menu (10), Commercial (2), plus a BOM CSV buried in
   the Layout inspector; the deliverables card's hint sends users to Layout, which has no drawing
   export at all (`review_hub.dart:185-189`); 23 `FilePicker.saveFile` sites, none remembering a
   folder; plan exports are current-sheet-only with no cue which sheet that is. Make the Review
   card the complete grouped package list, fix the hint, add one "Export submittal package…"
   (pick a folder once → the whole consistent-named set), and pass `initialDirectory` everywhere.
5. **Document control — the identity every sheet stamps — is invisible from every export surface**
   *(medium/small)* — it's the collapsed 8th section of the Layout inspector
   (`project_panel.dart:1255-1257`) while every export chrome consumes it, silently omitting
   unset fields; users discover the blank title block when a reviewer bounces the drawing. A
   one-line summary + "Set up" link on the Projects and Review export surfaces.
6. **Critical issues have no ambient signal — the count providers are dead code and blockers hide
   under "Warnings"** *(medium/small)* — the three count providers have zero consumers (one's
   doc-comment even claims the export gate consumes it — it doesn't), the Review nav item carries
   no badge (`nav_rail.dart:160-164`), and ERROR-severity electrical findings group under
   "Warnings" (`issues_card.dart:75-79`). Badge the nav item (danger when criticals exist);
   retitle the group when blockers are present.
7. **Review→Electrical "Locate" drops the circuit (the missing half of I2)** *(medium/small)* —
   the issue location carries `circuitId` but the jump forwards only `panelId`
   (`issues_card.dart:90-94`; `electrical_focus_store.dart:31-32`) while `selectCircuit` sits
   unused. Extend the focus request to (panel, circuit?) and select the way row.
8. **Export naming leaks and label lies** *(low/small)* — `mechx-bom.csv` (the internal codename,
   the only export not `$projectName-…`), "(MD)" buttons that also write an unannounced CSV, a
   single-file save dialog that writes N DXFs, and a HubNote still pointing at the Markdown
   report though the typeset PDF ships below it. Four one-line fixes.
9. **The Review/Commercial/Projects screens have zero golden coverage** *(medium/small)* — the
   app's only "eyes" (per its own doctrine) never render the sign-off and pricing surfaces
   (`screenshots_test.dart:85-216`); H2's stale-verdict bug is exactly the class a golden would
   pin. Add three goldens on the existing harness.
10. **"Commercial" prices only the electrical discipline — and prints a confident total even with
    zero prices set** *(high/large)* — the whole pipeline hangs off `electricalResultProvider`
    (`commercial_store.dart:120-147`); the mechanical BOM/fittings/cut-plan/consumables (all
    already computed) have no pricing path; and since labour derives from quantities while
    overhead/contingency/margin load the prime cost, an all-unpriced BOM still yields a non-zero
    sell price with no warning (exports also bypass the guard, H3). Short-term: title the
    workspace/proposal "Commercial — Electrical" and warn on unpriced lines at export. Real fix:
    a mechanical pricelist keyed by (product, DN)/fitting/consumable over the existing BOM data,
    folded into ONE project quotation with per-discipline subtotals.

### I. Keyboard, command layer & the copilot

1. **Ctrl+K / Ctrl+S / Ctrl+O silently die on every hub screen** *(high/small; empirically
   proven)* — the shell hotkey Focus never holds focus (`app_shell.dart:102-108`) and only the
   two canvases autofocus, so on Projects/Review/Commercial/Building/Preferences (and the Riser
   view) key events start at the root FocusScope and never reach the handler — a widget-test
   probe confirmed Ctrl+K opens the palette on the canvas and does nothing on Projects. Save
   dies exactly where the pre-export reflex fires, and palette navigation strands itself after
   one hop. Register the shell hotkeys focus-independently (`HardwareKeyboard.addHandler` or a
   root Shortcuts map).
2. **The command palette hasn't kept pace with the product — and it's hardcoded English**
   *(medium/small)* — ~27 commands: no Open, no Import, no Undo/Redo, no Measure/Tank/Room, no
   fit-view, and exactly ONE export of the app's ~32 (`command_palette.dart:49-217`); zero
   `StringKey` references in the file; title-only fuzzy matching, no recency ranking, shortcut
   hints on 2 rows. Register every existing intent (each a one-line closure), localize, match
   subtitles, rank recent, show shortcuts.
3. **Enter never commits — `MechXTextField` has no `onSubmitted`** *(medium/small)* — the
   calibration card and Offset dialog force a mouse trip to their primary button
   (`mechx_text_field.dart:104-115`; `calibration_overlay.dart:182-186`;
   `offset_dialog.dart:170-174`) while `SteppedValueField` proves the app's own convention. Add
   the optional callback; wire both dialogs (+ Preferences/fixture/pricelist fields).
4. **Esc closes every overlay except the Claude copilot (J8, never landed)** *(low/small)* —
   with the panel open, Esc falls through and *mutates the canvas underneath* (cancels
   calibration, clears the selection being asked about). Two lines in the shell Esc branch.
5. **The copilot apply loop is blind and unaccountable** *(high/medium)* — the context sent to
   the model omits the current sheet id, sheet extent, and floor list while the system prompt
   demands sheet-pixel coordinates (`ai_copilot_store.dart:185-200`; `ai_client.dart:163-170`) —
   the model must hallucinate placement inputs, and an invented `sheetId` creates nodes that
   render on NO sheet (`:127-146`, unvalidated); apply is N separate undo steps ("one undo step
   each", `:95-105`) that silently skips undecodable commands and reports nothing. One bad
   experience writes the headline AI feature off permanently. Send the frame (sheet id + extent +
   floors + selected-element descriptions); validate before applying; batch to ONE undo step;
   report "Applied M of N — K skipped".
6. **The copilot is hidden behind one palette row and over-promises** *(medium/small)* — the only
   opener is the palette's "Ask Claude" (`command_palette.dart:145-147`); the panel says "design
   or change it" while the closed command set is place-only + suggest (`commands.dart:15-22`)
   though the change verbs all exist as store intents. Add an affordance where the work happens
   (inspector button + context-menu row pre-scoped to the element); extend the registry with
   setSize/setMaterial/delete/connectRiser/offset — or soften the copy.
7. **Assistive tech stops at the token layer; one control is keyboard-unreachable** *(low/medium)*
   — two `Semantics` nodes in the whole UI; `MechXButton` declares no button role/label (the
   custom design system gets nothing for free, so every gap is permanent by construction); the
   clickable workflow-stepper chips are bare GestureDetectors while the visually identical zoom
   segments are focus-ring-wrapped (`workflow_stepper.dart:157-166` vs `zoom_controls.dart:68`).
   Fix at the two shared widgets — it propagates app-wide.

### J. Visual consistency & i18n

1. **No scroll indicator exists anywhere in the app** *(high/small)* — zero
   Scrollbar/RawScrollbar matches under `lib/`; the goldens show the consequences: "Hide sizes"
   clipped in half at the inspector's fold (01/02) and "Exhau…" chopped with whole services
   scrolled out of existence (07). On a mouse-driven desktop app, content below the fold is
   undiscoverable and clipped chips read as rendering bugs. One themed wrapper on `RawScrollbar`
   (plain `widgets.dart`, no Material) over the ~10 scrollables + an edge fade on the horizontal
   strips.
2. **The heatmap legend ellipsizes the numbers it exists to show** *(low/small)* — hard 148-px
   row + ellipsizing mono labels (`heatmap_layer.dart:113-149`); golden 03 ships "Low 31 k… /
   High 31 …". Intrinsic width, unit in the title.
3. **The top-bar zoom pill reports the Layout sheet's zoom on every screen (J6, never landed —
   plus worse)** *(medium/small)* — it renders on all sections (`app_shell.dart:122, 266-268`),
   so goldens 04/05/07/11 all show "57%" over canvases with their own different zoom — a wrong
   instrument beside the zoom-driven LOD it contradicts. Bind to the visible surface; hide
   elsewhere.
4. **Export — the deliverable action — is styled in the disabled idiom on the electrical
   toolbar** *(medium/small)* — `MechXButtonTone.muted` renders tertiary grey, visually adjacent
   to the true disabled state (`electrical_view.dart:705-708`; `mechx_button.dart:84-88,
   128-130`), and each workspace styles export differently. Normal tone; one convention.
5. **The electrical "Not on this sheet" tray stretches to full canvas height for three chips**
   *(medium/small)* — `Positioned(top:, bottom:)` forces the glass slab tall
   (`electrical_layer.dart:188-198`); golden 06 shows ~600 px of empty frost occluding the plan
   it exists to coordinate against. Pin top-only + max-height.
6. **Light mode is a golden blind spot with hardcoded dark-tuned colors** *(medium/small)* — one
   light frame exists (02); every electrical/riser/heatmap golden is dark-only while the
   electrical canvases hardcode near-black pills and raw white glyphs outside the token system
   (`electrical_canvas.dart:1026, 1656, 1740, 2069`; `electrical_layer.dart:526`). Two light
   goldens + a `canvasChip` token.
7. **ID localization is a patchwork across exactly the surfaces a first-time Indonesian user
   meets** *(medium/medium)* — the core drawing toolbox (8 `context.strings` calls in the
   3316-line `project_panel.dart`; every tool label a literal), the Projects hub + templates
   dialog + empty-state card, all save/open/export toasts (`project_io.dart:84-191` — beside
   localized busy strings in the same functions), the Review deliverables buttons, the copilot,
   the fixture editor, the electrical badges/stat labels/drop toasts/refusal sentences, and the
   palette (I2) — contradicting CLAUDE.md's "only canvas overlay labels remain". Also:
   `sectionVisibilityProvider` keys expansion state by the *display string*
   (`inspector_store.dart:38-46`), so localizing naively forks per-locale UI state — split into
   stable id + label first. One StringKey batch (EN byte-identical, goldens safe) + typed refusal
   enums localized at the call site.

---

## Recommended sequencing

Five waves, ordered so **trust lands before speed, speed before parity, parity before the last
mile** — matching how a user's confidence actually builds. Every item is additive or
byte-identical-by-default; goldens regenerate only where a change is deliberately visible.

**Wave 1 — Ship honesty & stop the bleeding (small fixes, ~1 cycle). ✅ LANDED 2026-07-03**
A1 empty first launch · A2 empty electrical seed · H3 route all 14 exports through the guard ·
B1 atomic writes · B4 text-field key guard · I1 focus-independent shell hotkeys · F3 riser
phantom undo · H2 reactive compliance verdict · F9 roof-tank line · J2 heatmap legend ·
G8 SP-N ordinals · B5 update-exit guard · B9 eager dirty dot · H8 export naming.
(See the §15 decisions-log row for the change detail; adversarial review then fixed a
phantom-recovery-on-update, a modal-unsafe hotkey, and an unused `.bak` fallback.)

**Wave 2 — The safety net (undo + data model). ✅ LANDED 2026-07-03**
B3 annotation undo domain + confirmable deletes · G2 MEP-panel upsert + auto badge · B6 floor
remap/guards + honest template dialog · B7 sheet→floor remap + pile-up warning · A5 import
add/replace + orphan pruning · B2 recovery slot + restore identity · G3 commit-on-blur fields ·
B8 API key out of `.mechx` · A3 File→New · A4 settings file: MRU + locale/theme persistence.
(See the §15 row. Adversarial review then fixed 5 defects — phantom-recovery on New/Open,
import add-collision, the AI-key migration clobber, the updater's per-project slot, and the
B6/B7 undo atomicity via a compound `UndoDomain.structural` coordinator. Residual noted: A4's
`lastOpenPath` is persisted but reopen-last-on-launch is deliberately not wired — the MRU top
entry already serves it, and auto-open would clobber crash recovery.)

**Wave 3 — Drafting velocity (the 2× drafter). ✅ LANDED 2026-07-03**
C1 tee-in (reuse the existing split) · C2 drop-merge honesty · C3 single-key tools + I2 palette
completeness · E1 batch property edit + E2 group move · E3 paste cascade + array ·
E4 duplicate-floor range · C4-C9 drawing-loop polish · D1 direct 1:N scale entry + one formatter ·
D2 apply-scale scope · D3 calibration back-step · D4/D5 stepper fields · I3 Enter commits ·
E8 idempotent auto-place + stranded-terminal issue · E9 edge editor parity · E5 assemblies.
(See the §15 decisions-log row for the change detail; adversarial review then fixed 7 defects —
the smart-input typed-length run disconnecting at its start, a stamped multi-floor assembly
flattening to a zero-length riser, the C1 tee-in splitting an unrelated-service pipe, the edge
context-menu batch cross-applying a duct size onto water pipes, the drop-ring/snap nearest-vs-first
mismatch, a phantom fixture-undo, and the held-arrow undo flood.)

**Wave 4 — Workspace parity**
F1 riser-scoped inspector · F2 Auto zoom/pan · F4 riser keyboard · F5 toolbar grammar ·
F6 canvas label discipline · F7 sticky view state · F8 riser empty-state actions · G4 electrical
Esc · G5 tappable Issues drawer · G6 LOD tap semantics · G7 panel system/voltage ·
J1 scrollbars everywhere · J3 honest zoom pill · J4 export button tone · J5 tray height ·
E6 first-class rooms/tanks · E7 room names · E10 section order · E11 empty-state honesty.

**Wave 5 — The submittal & the business (completing M+E+P)**
G1 wire the solved-duty bridge · H4 one-folder submittal package + consolidated export surface ·
H5 document control at the export moment · H1 reachable PASS + acknowledgements · H6 nav badge ·
H7 circuit-level locate · H10 mechanical pricing → one M+E+P quotation · A6 multi-file sheets ·
A8 page-picker thumbnails · I5/I6 copilot context, batching, reach · J6 light goldens + H9
Review/Commercial goldens · J7 the i18n batch (stable section ids first) · I7 semantics at the
token layer · A7 window title.

---

**Refuted in verification (for the record):** a "3 SHT rail label" complaint (the 64-px rail
width makes the abbreviation a documented deliberate trade-off) and a "dead status-bar hint
string" claim (git history shows the hint was mounted and then deliberately removed in declutter
pass 4 — an explicit product decision, not dropped work).

Every recommendation above follows the house rules: additive/optional params defaulting to
byte-identical behavior, pure-Dart engine untouched except safe clamps, no Material imports
(scrollbars via `widgets.dart` `RawScrollbar`), fully offline (settings/MRU as a local JSON, no
plugins), EN strings byte-identical so goldens shift only where intended, and every claim above
carries the `file:line` evidence a fixing session can start from.
