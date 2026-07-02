# CAD Output & UX Review — the plan to professional parity

**Date:** 2026-07-02 · **Scope:** every drawing/report deliverable + the full UI/workflow
**Method:** a 10-dimension multi-agent review (5 CAD-drafting lenses over the export/drawing
pipeline, 5 Apple-designer lenses over the UI and workflow), 88 agents total. Every finding was
**adversarially verified against the code** (the verifier was instructed to reject anything already
implemented, infeasible under the architecture guardrails, or vague) — 78 findings survived, and
each cites the file/line evidence of what the code does today. Impact/effort tags come from the
review; file lists name the primary touch points.

The two questions asked:

1. What must change so the **output** (plan PDFs/DXFs, riser single-lines, electrical drawings,
   calc reports, BOM) is on par with what a professional CAD drafting office issues?
2. Through an **Apple designer's** eyes, what would streamline the UI and workflow?

---

## Executive summary

**CAD lens.** The riser and electrical single-lines already ride a genuinely professional
one-geometry pipeline (`SldSheet` → PDF/DXF/canvas) with Indonesian drafting conventions
(KETERANGAN, GRUP/DAYA schedule, riser tags, FFL gutters). The **plan drawings are the widest
gap**: they export the drawn network floating on a white page — no floor-plan underlay, no real
title block, an arbitrary auto-fit scale under a fake scale bar, a pixel-unit DXF with no layer
table, uniform line weight, and every node reduced to an anonymous dot. A drafting office would
reject them on first look, not for drafting *style* but for missing the basics of an issuable
sheet. The reports are honest and rigorous in content but are delivered as **Markdown files**,
which no consulting engineer can submit.

**Apple lens.** The app has real polish (glass chrome, drag previews, command palette, honest
empty-state discipline) but misses **document-app fundamentals**: no Ctrl+S/save-in-place, no
dirty guard on Open/Import/quit, no busy feedback on slow operations. The canvas has **mode-trap
problems** (Esc doesn't exit draw/measure modes; the current mode can be invisible). The
electrical workspace — a PanelMaker port — is the consistency hole: **no undo at all** (Ctrl+Z is
a data-loss trap), warnings outside the unified Review surface, and panels that can't be renamed
from the UI. The inspector buries the selection editor fifth in one long scroll and shows every
discipline's fields on every fixture.

**Counts:** 78 verified findings — 30 high-impact, 40 medium, 8 low. Recommended sequencing is at
the bottom; the single biggest CAD lift is the underlay + symbol work (Wave 3), the single biggest
UX lift is electrical undo (Wave 1/3).

---

## Already at professional level (keep, and build on)

- **One-geometry discipline is real**: the sealed `SldPrim` set is switched exhaustively in all
  four renderers; PDF, DXF and canvas provably draw the same drawing (`report/sld_sheet.dart`).
- **The electrical board schedule** carries the full BRI *Diagram Panel* column set with honest
  Indonesian notation (`1.500 WATT` dot-grouping, CADANGAN spare rows, V/A/Hz metering circles, CT
  note, busbar Icw header).
- **Provenance honesty**: every report prints its tiered "Unverified values" register; details are
  data-gated (no roof tank ⇒ no pump-set callout); model/spec is an explicit placeholder.
- **Engine-grade PDF/DXF writers**: dependency-free, byte-accurate xref tables, ASCII/WinAnsi-safe
  text by construction, chrome that is byte-identical when absent — all test-pinned.
- **Interaction bright spots**: wheel zoom-to-cursor + middle-drag pan, ghost-glyph drag previews
  with snap rings, the Measure tool's live dimension chip, the smart input bar (AutoCAD-style
  direct distance entry), screen-clamped context menus with an ASCII NPS ladder, staged
  calibration with a live preview, signature-compared autosave/recovery.
- **§10 length truth** everywhere: exports fold real calibrated run lengths and true elevation
  deltas; the exporters refuse to write when a sized edge resolves to zero length.

---

## Part 1 — CAD-drafting parity (the output)

### A. Plan drawings (PDF + DXF) — the widest gap

1. **Print the floor-plan underlay beneath the exported network** *(high/large)* — all three plan
   exporters draw the network floating on white (`pdf_export.dart:59`, `plan_pdf_export.dart:78`,
   `dxf_export.dart:25`); the sheet's PDF raster (pdfrx) and parsed `DxfDrawing` both exist in the
   product but never reach an export. Add an optional underlay param (null ⇒ byte-identical, the
   chrome pattern): DXF sheets re-emit the parsed entities on a grey `underlay` layer; PDF sheets
   get an app-side pdfrx render embedded as a FlateDecode image XObject painted first. Caveat from
   verification: map the underlay through the same DXF→screen-pixel frame the canvas uses.
   `report/{pdf_export,plan_pdf_export,dxf_export}.dart`, `lib/ui/inspector/project_panel.dart`
2. **Real-world DXF: mm units, HEADER/TABLES, named layers with colors + linetypes** *(high/medium)*
   — today the DXF is ENTITIES-only R12 in **screen pixels** (nothing measures true in AutoCAD),
   with layers auto-created from Dart enum names (`coldWater`). Add `metersPerPixel` → mm
   coordinates + `$INSUNITS`, a LAYER table (ISO-13567-ish names, e.g. `M-CWS-PIPE`), LTYPE
   definitions, lineweights, and ~2.5 mm text heights. `report/dxf_export.dart`, `drawing_chrome.dart`
3. **Plot at a stated standard scale; make the scale bar honest** *(high/medium)* — the drawing is
   auto-fitted at an arbitrary ratio yet a divided scale bar prints anyway (`drawing_chrome.dart:187`)
   — a bar an engineer could scale wrong dimensions from. Snap the fit to 1:50/100/200/250/500,
   print `1 : 100 @ A3`, size the bar to real metres, and print `NTS` + no bar when uncalibrated.
4. **ISO 5457 sheet frame + ISO 7200 title block** *(high/medium)* — the plan PDFs stamp loose
   corner text; the electrical export already draws a real ruled title-block strip. Generalize it
   into shared `pdfSheetFrame`/`pdfTitleBlock` chrome (PROJECT/CLIENT/TITLE/DWG NO/REV/SCALE/DATE/
   DRAWN/CHECKED/APPROVED), fed by new `DesignSettings` document-control fields (see D3).
5. **Component symbols, riser UP/DN sense, flow arrows in exports** *(high/large)* — the model has
   ~30 `NodeComponent` kinds and the canvas draws proper glyphs, but exports collapse every node to
   a 2 pt dot and risers to anonymous circles. Add a pure engine plan-symbol library mirroring
   `segment_symbols` geometry, label risers `UP`/`DN` from the endpoints' floor indices, and arrow
   sized runs. `report/plan_symbols.dart` (new)
6. **Line-weight hierarchy + per-service linetypes in exports** *(medium/small)* — both PDFs stroke
   everything at `1.4 w`; no dash patterns anywhere; colour-only differentiation dies on a
   monochrome print. Three weight bands from `EdgeSizing`, dashed vent/return, dash-dot fire.
7. **Rotate/offset labels and avoid collisions** *(medium/medium)* — every label is horizontal at
   the exact midpoint (vertical runs get text lying across the line; parallel offsets overprint).
   Rotate to the edge bearing, offset perpendicular, greedy collision pass with leaders.
8. **Unify plan exports on the `SldSheet` pipeline + A1/A2 paper** *(medium/large)* — the plan is
   the one drawing family violating golden rule 5 (three hand-rolled renderers + a fourth on
   canvas). Introduce `buildPlanSheet(...) → SldSheet`; do it as the carrier refactor so findings
   5–7 land once, not three times.

### B. Mechanical riser single-line

1. **Export parity with the live canvas** *(high/large)* — the issued PDF/DXF is a stripped-down
   version of the on-screen Auto view: the canvas draws equipment symbols, flow arrows, capacity
   suffixes (`Roof tank · 237 m3`), the pump-set detail, valve-assembly callouts and system notes;
   `buildMechanicalRiserSld` emits none of them. Extend the builder (pure prims + optional
   app-supplied detail maps) so the deliverable ≥ the preview. `report/mechanical_sld_drawing.dart`
2. **Drainage/vent/rainwater get the clean-water treatment** *(high/medium)* — all H101-style
   callouts are gated to cold/hot water; a *Diagram Air Kotor* needs clean-outs at stack bases, the
   vent tee, and a VTR termination — the components already exist in the model. Data-gated, with an
   advisory (never a fabricated cleanout) when a stack lacks one.
3. **Issue a numbered drawing SET** *(high/medium)* — export currently emits one sheet for the
   focused service with `Sheet 1 of 1` hardcoded (`schematic_export.dart:95`). Add "Export all
   systems": per-service + combined sheets, real `Sheet i of t`, a date param (app passes the
   clock), multi-page PDF via a generalized `sldSheetsToPdf`.
4. **Line discipline + service identity in the export** *(medium/medium)* — a pipe run and a floor
   datum line are both `thin/normal` ink, and the combined view exports every service as the same
   dark line. Additive `layer`/`dashed` on `SldLine` (defaults ⇒ byte-identical), hairline datums,
   per-service DXF layers, dashed vent.
5. **Label collision avoidance** *(medium/medium)* — fixed offsets overlap on dense floors; greedy
   rect-tracking with leader lines, deterministic and unit-testable.
6. **Edit mode legibility** *(medium/small)* — every node is an identical grey dot and risers can
   render diagonal; reuse the Auto painter's symbols/labels and L-route riser edges.
7. **Unify canvas/export horizontal layout** *(low/medium)* — rank-spread vs world-x proportional
   placement means the preview doesn't match the issued sheet; extract one pure layout helper.
8. **One ASCII notation** *(low/small)* — the canvas mixes `m³`/`Ø` with the export's `m3`/`O`;
   converge on the ASCII forms everywhere.

### C. Electrical drawings

1. **Paginate the PDF single-line** *(high/medium)* — one fixed A3 auto-fits the whole stacked
   system; 6–8 panels push text to the 5 pt floor and overlap. One panel (group) per page with real
   `Sheet i of t` — the writer's object assembly generalizes mechanically to N pages. This also
   unblocks B3's multi-page riser set. `report/electrical_pdf_export.dart`
2. **Rule the board-schedule table** *(high/small)* — the BRI *Diagram Panel* is a fully ruled
   grid; today only three rules exist and columns align by whitespace. Emit vertical separators at
   the column boundaries + a horizontal rule per way row — pure `SldLine`s, all three renderers
   pick it up free. The **single highest-leverage CAD change in the repo.**
3. **Complete the title block** *(medium/medium)* — add client/drawn/checked/approved/date/scale
   (NTS) to `DrawingChrome` + the PDF/DXF title blocks, fed by the D3 document-control settings.
4. **DXF TABLES + class-based layers** *(medium/medium)* — same disease as the plan DXF: no
   HEADER/TABLES, three implicit layers, layer-by-weight heuristic. Define `E-BUS/E-BREAKER/
   E-FEEDER/E-TEXT/E-FRAME/E-ESSENTIAL` with ACI colors and route prims by class.
5. **Breaking capacity (kA) in device notation** *(medium/medium)* — reviewers check `MCCB 100A
   36kA` against the bus fault level; the fault study already selects real Icu ladders. Optional
   `icuKa` on `BreakerResult`, shown only when the study resolves it — never fabricated.
6. **Earthing symbol + system designation** *(medium/small)* — no output shows how the installation
   is earthed; add the IEC three-bar earth at the transformer neutral/LV main labelled `TN-C-S`/`TT`
   from the model's own `earthingSystem`.
7. **Power one-line onto the SldSheet pipeline** *(low/medium)* — the fourth output is still a
   centre-to-centre wireframe grid with no PDF variant; rebuild via `buildPowerOneLineSheet` reusing
   the existing IEC source-symbol emitters, and both formats come free.

### D. Reports, schedules, BOM

1. **A typeset PDF calculation report** *(high/large)* — the three flagship reports are raw
   Markdown files; no engineer submits `.md`. Refactor the builders to a neutral block list
   (heading/para/kv/table/note) that the existing Markdown renderer walks unchanged (test-pinned),
   then add a paginating pure-Dart PDF typesetter over the proven object-assembly technique: cover,
   running footer (`project · doc no · Page X of Y`), ruled tables, embedded riser/single-line
   figures (the SldSheets already exist as vector prims). `report/report_{blocks,pdf}.dart` (new)
2. **Honest compliance roll-up** *(high/small)* — `buildComplianceSummary` matches 3 issue titles
   by substring and misses duct over-capacity, connectivity warnings, and **all electrical
   warnings** — it can print `overall: PASS` beside ERROR-severity findings. Group *all*
   designIssues by category + a catch-all row + an electrical row. `lib/ui/inspector/project_panel.dart:169`
3. **Document control data source** *(high/medium)* — the engine supports revision tables and
   drawing numbers but the app never populates them. Additive `DesignSettings`: documentNumber,
   revision list, preparedBy/checkedBy/approvedBy — one small "Document control" card feeding every
   report head, PDF/DXF title block, and a drawings register in the unified report. Unblocks A4/C3.
4. **Bahasa Indonesia report bodies** *(medium/medium)* — the app is bilingual and the drawings
   speak Indonesian, but every report body is hardcoded English. Pure engine `report_strings.dart`
   EN/ID lookup, optional param defaulting EN (byte-identical), key-parity test.
5. **Spreadsheet deliverables** *(medium/small)* — the equipment schedule was explicitly designed
   for a CSV emitter that was never written; the BOM CSV concatenates two different-schema tables
   into one misaligned file. Add `equipmentScheduleToCsv`, split `-bom.csv` / `-fittings.csv`.
6. **Material take-off: per-floor grouping + stock/wastage** *(medium/medium)* — the cut-plan
   engine already computes purchased bars and waste % but it reaches no export; BOM has no floor
   column though every node carries `floorIndex`. Optional `groupByFloor` + join the cut plan into
   the CSV. Pure regrouping of solved data.
7. **Currency formatting in the quotation** *(low/small)* — raw `toString` doubles
   (`1181250` beside `3703.68`); shared `number_format.dart` reusing the `_wattsId` dot-grouping.

### E. On-canvas drafting quality (what the engineer sees all day)

1. **Per-service linetypes on canvas** *(high/medium)* — the unified Plumbing layer draws five
   services solid, distinguished by colour alone; dashed vent/return + dash-dot fire in
   `service_style.dart` + a dashed `_paintPipe` variant.
2. **Label rotation/offset/LOD** *(high/medium)* — the `DN15` chip sits horizontally ON the pipe at
   its midpoint (visible in golden 01); rotate along the run, offset clear, skip when the run is
   shorter than the text.
3. **Flow-direction chevrons** *(high/medium)* — the solve knows direction but discards it; additive
   `flowFromId` on `EdgeSizing` (null ⇒ byte-identical) + one faded chevron at the 2/3 point.
4. **True-width ducts when zoomed** *(medium/small)* — a 600×400 duct paints ~13 px at any zoom;
   the painter already has `metersPerPixel` + scale — grow to the physical footprint (capped) when
   zoomed in.
5. **Proper dimension style for Measure** *(medium/small)* — extension lines, offset dimension
   line, arrowheads, text above the line instead of a chip covering it.
6. **Plan ↔ riser cross-referencing** *(medium/small)* — tag plan riser markers with their `CW-R1`
   ids (the engine already assigns them) and append the service code to run labels on multi-service
   layers.
7. **Hover pre-highlight for Select** *(medium/small)* — zero rollover feedback today; the hit-test
   helpers already exist, paint a subtle halo.
8. **Major/minor grid tied to round metres** *(low/small)* — the 32-px single-weight grid is
   texture, not a drafting aid; 1-2-5 snapped metre steps with a heavier major line.

---

## Part 2 — Apple-designer lens (UI + workflow)

### F. Document fundamentals (the biggest felt-quality gap)

1. **Save-in-place + Ctrl+S/O + edited indicator** *(high, two findings)* — every save is a
   Save-As; no current-path concept exists; no Save/Open shortcuts; no unsaved-changes cue.
   `currentProjectPathProvider`, `save()`/`saveAs()` split, Ctrl/Cmd+S/O in `AppShell._onKey`, an
   "Edited" dot driven by the existing autosave signature. `lib/ui/app_shell.dart:286`
2. **Guard unsaved work on Open / Import / quit** *(high/medium)* — Open replaces the project with
   no dirty check *and deletes the recovery snapshot*; Import resets all sheets silently orphaning
   drawn nodes; quit is unguarded. Signature-based dirty check + Save/Discard/Cancel dialog +
   `AppLifecycleListener.onExitRequested`.
3. **Busy feedback on slow operations** *(high/medium)* — DWG conversion (seconds of ODA shell-out),
   portable save (synchronous gzip of every plan **on the UI thread** — a real window freeze), and
   exports give zero feedback. `busyProvider` + status-bar busy pill; move `gatherSheetAssets` to
   `Isolate.run`.
4. **Recovery with context, discard made deliberate** *(low/small)* — the banner doesn't say what
   or when, and Dismiss instantly deletes the only copy; name + timestamp + two-step discard.

### G. Canvas modes & direct manipulation

1. **Esc always exits the mode; right-click ends a run** *(high/small)* — Esc never returns
   Run/Riser to Select and never exits Measure/Tank/Room; the only exit is a button inside a
   twice-collapsible inspector. Extend the Esc ladder; secondary-click finishes drawing (the CAD
   convention). `lib/ui/layout/layout_canvas.dart:384`
2. **On-canvas mode pill** *(high/small)* — the active tool is invisible when the inspector is
   collapsed and all draw modes share one cursor. A small glass pill (`Run · Cold water — Esc to
   finish`), rendered only in non-Select modes so goldens rest unchanged.
3. **Live length + snap ring on the run rubber band** *(high/small)* — the primary gesture shows a
   bare line while the secondary Measure tool shows a live dimension; reuse the measure chip + the
   drop overlay's snap ring so the user sees exactly where the click lands.
4. **One drag = one undo** *(medium/small)* — a drag-that-snaps pushes two undo entries; the first
   Ctrl+Z restores a weird unmerged intermediate. Commit-replacing-snapshot on the merge path.
5. **Right-click menus for equipment nodes + empty canvas** *(medium/medium)* — right-clicking a
   pump/tank/diffuser does nothing while edges get a rich menu and electrical gets Edit/Duplicate/
   Delete; generalize the node menu; add Paste-here/Select-all/Fit-view on empty space.
6. **Hold-Space pan + honest cursors** *(medium/medium)* — the canvas always shows a grab cursor
   but left-drag pan effectively never works with a mechanical layer active (marquee/overlays own
   it); Space-pan is the standard answer, and the guide text should stop promising drag-pan.
7. **Ctrl/Cmd+A select-all; Shift+marquee adds** *(medium/small)* — no select-all exists; Shift
   explicitly allows starting a marquee that then *replaces* the selection.
8. **Double-click opens the thing you clicked** *(medium/small)* — the electrical layer of the same
   canvas already does this; mechanical nodes/edges should open their inspector section.

### H. Inspector information architecture

1. **Selection editor first** *(high/small)* — clicking a node changes nothing visible: the
   selection section is fifth in one long scroll. Hoist it to the top + auto-scroll on selection.
   The Apple context-before-document split in one move. `project_panel.dart:570`
2. **Type-in + hold-repeat on every stepper** *(high/medium)* — an 850 m² roof area is 17 clicks
   today; one shared `SteppedValueField` (−/+, click-to-type, Enter/blur commit, hold-to-repeat)
   replacing ~10 hand-rolled rows.
3. **Scope node fields to the node's discipline** *(high/small)* — a WC currently shows a diffuser
   airflow stepper and a roof-area stepper; derive the service set from connected edges and gate
   each field group.
4. **Order sections to match the workflow** *(medium/small)* — Scale (the gating step, per the
   app's own stepper) is the *last* section; move Sheet + Scale to the top, wrap in
   DisclosureSections.
5. **Fire's invisible input** *(medium/small)* — the Fire section is results-only; hazard class is
   settable nowhere outside the template dialog. One pill row wired to the existing provider.
6. **Master-detail for Rooms/Tanks** *(medium/medium)* — eight rooms ≈ 3000 px of always-expanded
   editor cards in a 272-px panel; compact rows + one expanded editor at a time + `+N more` BOM cap.
7. **True empty states + plain labels** *(medium/small)* — Network shows dash-filled rows and a
   `BOM total 0.0 m` on a blank project; Fire shows solved-looking numbers with no fire piping
   drawn. Muted captions (HVAC already has the pattern); rename `HW recirc` etc.
8. **Kill headline/kv duplication; ResultCard for Fire** *(low/small)*.

### I. Electrical ↔ mechanical parity (one product, one language)

1. **Electrical undo** *(high/medium)* — the electrical store has **zero undo** while the same
   window's mechanical half undoes everything; Ctrl+Z with an electrical edit pending silently
   reverts some *other* domain's edit. `UndoDomain.electrical` + a snapshot stack through the
   existing `_withProject` funnel; exempt `syncMepEquipment`. The single most dangerous UX defect
   found. `lib/store/electrical_store.dart`
2. **Electrical warnings into Design Issues** *(high/medium)* — ERROR-severity items like
   `cable-ampacity-inadequate` never reach the Review IssuesCard or the compliance summary (its
   clean state is a lie for M+E+P). Map `ElectricalWarning` → `DesignIssue` with panel/circuit
   locations that jump-and-focus.
3. **Panel properties editor** *(high/medium)* — `renamePanel`/`setPanelDiversity` exist in the
   store with no UI; every panel ships as `Sub-panel 3` into the issued drawings. A right-drawer
   panel inspector (name/tag/diversity/headroom) on double-click; unlocks two already-built engine
   features (diversity, CADANGAN spare ways).
4. **Esc + keyboard parity in the standalone workspace** *(medium/small)* — Esc does nothing there
   while the same menus close with Esc on the Layout canvas.
5. **Selectable loads, Delete, duplicate panel** *(medium/medium)* — clicking a load *clears* the
   selection; no copy/duplicate exists for panels.
6. **Localize the electrical chrome** *(medium/medium)* — the one remaining hardcoded-English
   workspace in a bilingual app.
7. **LOD transition legibility** *(medium/small)* — the summary→schedule flip is an invisible
   threshold, and the documented middle tier is dead code; delete it, add an explicit expand
   chevron (`focusPanelSchedule` already exists).
8. **Minimap truthfulness** *(low/small)* — ignores dragged positions, shows no viewport, accepts
   no taps.

### J. Shell, navigation & workflow handoffs

1. **Empty states carry their actions** *(high/small, two findings)* — first launch shows "Import a
   PDF floor plan to begin…" with `actions: const []` while the card supports action buttons and
   the electrical empty state already has them. `Import plan…` + `New from template…` buttons.
2. **Stage handoffs speak** *(medium/small)* — calibration commits silently; first auto-size is
   silent (a first-timer never learns the app sized their pipes). One-shot status pills:
   `Scale set — next: floor heights`, `Auto-sized N runs`.
3. **Review hands off to export** *(medium/small)* — the pre-flight verdict screen's only path to
   deliverables is prose pointing at another screen; add an Export-deliverables card under the
   verdict.
4. **Honest stepper** *(medium/small)* — Report derives done from the same predicate as Size, so it
   claims completion before any report exists (visible in golden 01); make it real via the shared
   export helper or subtract the stage.
5. **Naming: "Riser SLD" → "Riser"; disambiguate the electrical "Riser" tab** *(medium/small)* —
   jargon in the nav, and one word naming two destinations.
6. **Subtract non-document top-bar controls** *(medium/small)* — the theme toggle is triple-exposed;
   the zoom pill renders on screens with no canvas.
7. **Shortcut discoverability** *(medium/small)* — Ctrl+K appears in zero user-visible strings; the
   rich existing shortcut set is surfaced nowhere. Status-bar caption + a Keyboard block in the (?)
   guides + palette row hints.
8. **Demote Building from the rail; unify Esc for the copilot overlay** *(medium/small, two
   findings)* — Building is a settings form posing as a workspace (already reachable three other
   ways); the copilot panel is the one overlay Esc won't close.

---

## Recommended sequencing

Dependencies to respect: **document-control settings (D3)** feed the title blocks (A4, C3) and
report heads; **DXF TABLES (A2/C4)** precede linetype/layer work; **PDF pagination (C1)** precedes
the riser drawing set (B3); the **plan SldSheet unification (A8)** is the carrier for symbols/
lineweights/labels (A5–A7) if scheduled first — otherwise land those per-exporter and fold later.

**Wave 1 — high-impact small fixes (1 short cycle, mostly app-side). ✅ LANDED 2026-07-02**
(see the §15 decisions-log row for the change detail)
C2 ruled schedule · D2 compliance roll-up · G1 Esc ladder + right-click-end · G2 mode pill ·
G3 rubber-band feedback · F1 Ctrl+S/current-file · J1 empty-state actions · H1 selection-first ·
H3 discipline-scoped fields · H5 fire input · J4 honest stepper · J5 naming · B8 ASCII notation.

**Wave 2 — issuable-sheet credibility (engine, medium). ✅ LANDED 2026-07-02**
(see the §15 decisions-log row for the change detail)
D3 document control → A4/C3 title blocks + sheet frame · A2/C4 DXF units + TABLES/layers ·
A3 true scale/NTS · C1 pagination → B3 drawing set · A6 + B4 + E1 lineweights/linetypes ·
C5 kA · C6 earthing · A7/B5/E2 label discipline · E3 flow arrows.

**Wave 3 — the two big CAD lifts + the electrical-parity track (parallel). ✅ LANDED 2026-07-02**
(see the §15 decisions-log row for the change detail)
A1 underlay (PDF image XObject + DXF re-emit) · A5 symbol library + UP/DN ·
B1 riser export parity · B2 drainage/vent treatment ‖ I1 electrical undo · I2 issues fan-in ·
I3 panel editor · F2 dirty guards · F3 busy feedback.

**Wave 4 — the submittal package.**
D1 typeset PDF report (block-list refactor first, Markdown pinned byte-identical) · D4 ID bodies ·
D5 CSVs · D6 MTO/wastage · J2/J3 stage handoffs + Review→export.

**Wave 5 — structural consolidation.**
A8 plan exports onto SldSheet + A1/A2 paper · H2 stepper fields + H6 master-detail inspector ·
G4–G8 interaction completeness · I5–I8 electrical selection/i18n/LOD/minimap · B6/B7 riser edit
mode + layout unification · E4–E8 canvas drafting polish · remaining low items.

Every engine change above follows the house rules: additive/optional params defaulting to
byte-identical output, no fabricated standards data (kA only when the fault study resolves it, no
invented cleanouts, `NTS` when uncalibrated), pure-Dart engine, sealed-prim exhaustiveness, ASCII
text, and goldens regenerated only where a change is deliberately visible.
