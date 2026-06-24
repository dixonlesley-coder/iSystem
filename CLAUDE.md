# CLAUDE.md — iSystem (formerly MechX)

Guidance for working in this repository. iSystem (the merged M+E+P product;
formerly **MechX**, which was M+P) is an **offline native Windows desktop
Flutter app** for MEP (mechanical / electrical / plumbing) design of Indonesian
(**SNI / PUIL**-standard) buildings. NOTE: the product/UI is branded "iSystem",
but the internal Dart packages (`mechx_engine` engine, `mechx` app), the
`MechX*` class names, and the Windows `BINARY_NAME=mechx` are deliberately kept. An engineer loads PDF floor plans,
calibrates each sheet's scale, sets per-floor heights, draws duct/pipe/fire
elements, and MechX auto-sizes everything to SNI rules, sizes pumps/fans/fire
systems, draws a schematic riser diagram, shows a live pressure heatmap, and
outputs a Bill of Materials and a calculation report — all offline.

The authoritative spec + running history is `MEP-PDF-Sizing-Tool-Build-Plan.md`
(read its **§12 guardrails** and the **§15 decisions log** at the bottom).

## Golden rules (architecture guardrails, §12)

1. **The engine is pure Dart with ZERO Flutter imports.** Everything in
   `packages/mechx_engine/lib/**` must be framework-free and runnable under
   `dart test`. Never import `package:flutter/*` there.
2. **One unit system internally: SI**, via zero-cost Dart-3 `extension type`
   typed quantities in `units.dart` (Length, Diameter, Area, Velocity,
   FlowRate, Pressure, Head, Power, Roughness…). Convert at the boundary with
   `.mm` / `.litersPerSecond` / `.kiloPascals` constructors and `.inXxx`
   getters. Don't pass bare doubles across APIs where a typed quantity fits.
3. **Geometry + floor elevations are the single source of truth for length**
   (§10): horizontal run length = pixels × per-sheet calibration; vertical
   length = a **true-elevation delta**, NEVER measured from the PDF. Node
   elevation is role-aware (`nodeElevation` in `network.dart`): a `main` sits
   at the ceiling, a `fixture` at fixture height, `plant` at a datum.
4. **Gravity / pressurized / air are SEPARATE sizing code paths** (§7), routed
   by `ServiceType.regime` in `sizing/network_sizing.dart`. Never collapse them
   into one "size a pipe" routine.
5. **The diagram, heatmap, and zoning are GENERATED RENDERS of the one solve**
   (`network/pressure_solve.dart`), not parallel calculations.
6. **Standards are pluggable data with `// VERIFY` flags.** Values not confirmed
   verbatim against an SNI document are marked `// VERIFY` and surfaced to the
   user (the calc report has a dedicated "Unverified values" section sourced
   from `SniProfile.verifyChecklist`). Keep that honesty surface intact.
7. **Versioned project file from day one.** `data/project_document.dart` writes
   a `version` header; loading is tolerant (unknown enums fall back, newer
   versions are rejected with a message). Add a migration step rather than
   breaking old `.mechx` files.
8. **Custom design system — no Material/Fluent.** The app uses `WidgetsApp`
   (not `MaterialApp`) and `MechXTheme`; all styling comes from
   `ui/theme/design_tokens.dart` (8pt grid, one type scale, light/dark).

## Build / test / verify

The dev container has the Flutter SDK but **no display and no Windows/Linux
desktop build deps**, so you can run tests and `flutter analyze` but CANNOT
`flutter run` or `flutter build`. Verify changes via the test + golden pipeline.

```bash
# Engine (pure Dart) — run FROM the engine package:
cd packages/mechx_engine && dart test          # ~334 tests

# App (Flutter) — run FROM the repo root:
flutter test                                   # ~80 tests incl. golden screenshots
flutter analyze                                 # must be clean

# Regenerate the UI golden screenshots after any visual change:
flutter test --update-goldens test/screenshots_test.dart
```

`test/screenshots_test.dart` renders the full app to PNGs in `test/goldens/`
(01 plan dark, 02 plan light, 03 heatmap, 04 schematic) using bundled Roboto
fonts at a 1440×900 surface — this is how UI is "seen" without a display. Full
app widget tests size the surface to a desktop window via
`test/test_util.dart` (`setDesktopSurface`).

**The gate (must stay green): `flutter analyze` clean + engine `dart test` +
app `flutter test`.** No change lands red.

### Watch-outs when running commands
- Bash `cwd` persists between calls. `dart test` only works inside
  `packages/mechx_engine`; `flutter test` only from the repo root. Double-check
  you're in the right directory (a stray `cd` has silently run engine tests
  when the app suite was intended).
- `flutter analyze` from inside `packages/mechx_engine` analyzes only the
  engine. Run it from the repo root to cover the app.
- Roboto lacks many symbol glyphs (→ ✓ ⚠ ↑ render as tofu). Use plain text
  ("OK"/"over"/"up") or the few that bundle (·). Goldens will catch tofu.
- Custom fonts: every on-canvas `TextStyle`/`TextSpan` must set
  `fontFamily: 'Roboto'` (or 'Roboto Mono') or it renders as boxes in goldens.

## Layout

```
packages/mechx_engine/lib/         PURE-DART CALC ENGINE (no Flutter)
  units.dart                       SI typed quantities (extension types)
  hydraulics.dart                  Darcy–Weisbach, Swamee-Jain/Colebrook (laminar-aware),
                                   Hazen–Williams, Manning, pump/fan power, P↔head
  pressure_field.dart              IDW scalar field for the heatmap
  standards/sni.dart               SniProfile: fixture-unit (UBAP) loads, Hunter demand
                                   curve, pressures/velocities, materials, verifyChecklist
  geometry/                        scale_calibration.dart, building.dart (floors,
                                   elevations, MountingHeights, ceiling/fixture elevations)
  network/                         network.dart (NetNode w/ role+elevation+fixture+airflow,
                                   NetEdge, nodeElevation, edgeLength), pressure_solve.dart
                                   (solvePressurized upfeed + solveDownfeed roof-tank),
                                   duct_static.dart (fan total static), zoning.dart (PRV)
  sizing/                          water_supply, drainage (DFU tables + true partial-full),
                                   duct (round/rect, velocity/equal-friction), storm,
                                   network_sizing (the dispatcher + accumulation), pump, fan,
                                   hot_water (recirc), bom (+ fittings), fire_sprinkler,
                                   fire_standpipe, supply_design, grille_sizing
  report/calc_report.dart          Markdown calculation report generator (pure)

lib/                               FLUTTER APP
  main.dart                        bootstrap: pdfrx init, autosave loop, recovery check,
                                   UncontrolledProviderScope
  app.dart                         MechXApp (WidgetsApp + MechXTheme)
  data/                            project_document.dart (versioned .mechx JSON),
                                   pdf_import.dart, recovery.dart + autosave.dart
  store/                           Riverpod controllers (the app's brain):
                                   network_store (drawing + edit + undo + duplicateFloor +
                                   ortho), project_store (floors/calibration + undo),
                                   sheets_store, selection_store, sizing_store, solve_store
                                   (solve/pump/fan/zones/bom/fittings/recirc), fire_store,
                                   calibration_store, app_state (brightness, schematic,
                                   feed strategy, occupancy, duct settings, load error)
  ui/                              app_shell (top bar, banners, status bar),
                                   canvas/ (CanvasView + ViewportTransform, overlays:
                                   drawing/selection/calibration/heatmap, network_layer,
                                   snapping), inspector/project_panel.dart (the big one),
                                   schematic/, sheets/, theme/, widgets/
```

## Feature state (what's built)

PDF import (pdfrx) + multi-sheet rail; per-sheet scale calibration; per-floor
heights + role-aware elevations; draw runs/risers for 10 services (cold/hot
water, drainage, vent, rainwater, supply/return/exhaust air, sprinkler,
hydrant); **select / edit / delete / drag** nodes & edges, **multi-floor
duplicate**, ortho snap, keyboard (Delete, Esc, Ctrl+Z/Y); auto-sizing per
regime (water via accumulated UBAP→Hunter; drainage/vent via DFU capacity
tables; ducts round/rect + velocity/equal-friction; rainwater via storm
table); per-fixture types + occupancy + diffuser airflow; **upfeed-pump vs
roof-tank-downfeed** solve with unified residual heatmap; PRV pressure zoning;
pump/fan duty + motor; hot-water recirculation; fire sprinkler + standpipe;
schematic riser diagram; **BOM + fittings + CSV export**; **Markdown calc
report export**; versioned `.mechx` save/open with viewport restore;
**autosave / crash-recovery**; light/dark.

## Conventions

- **Riverpod**: `Notifier`/`NotifierProvider` for mutable state, `Provider` for
  derived values. Controllers expose intent methods; widgets `ref.watch` state
  and `ref.read(...).notifier` for actions.
- **Undo**: `NetworkController` and `ProjectController` each keep a local
  snapshot stack, but every forward mutation also records its domain on a
  **single global timeline** (`store/history_store.dart`). Ctrl/Cmd+Z (and the
  Draw-panel Undo/Redo) call `historyProvider`, which pops the timeline and
  drives the owning controller's local revert — so undo reverts the genuinely
  most-recent edit across domains. `applyDocument` resets the timeline on load.
- **Tests are the spec.** Engine seed suites hand-compute expected values from
  first principles (see the arithmetic comments) — keep that. When a formula
  changes, update the test's derivation, don't just relax tolerances. Prefer
  deriving expected values from the engine's own primitives over magic numbers
  for orchestration-level tests.
- Add-only / minimal edits; match surrounding style; never push to a branch
  other than the assigned feature branch.
- **Keep the docs current after every feature.** When a feature lands, before
  committing it: (1) append a dated row to the **§15 decisions log** in
  `MEP-PDF-Sizing-Tool-Build-Plan.md` (the authoritative running history), and
  (2) update this file's **Feature state** / **Known gaps** / **Sizing-engine
  invariants** sections as needed. Treat the doc update as part of the feature,
  in the same commit — a feature is not done until its history is recorded.

## Known gaps / TODO (see decisions log for detail)

- Electrical ("E") domain — **now in scope**: this repo is being merged into the
  single M+E+P app **iSystem** (see the §15 decisions-log "Project merge" row).
  The electrical engine is being ported to pure Dart under
  `packages/mechx_engine/lib/electrical/` from the sibling **PanelMaker** (PUIL)
  spec. Landed so far: **A1** — SI typed quantities for current/voltage/VA/var/Ω/J
  in `units.dart`; **A2** — `standards/puil.dart` (`ElectricalStandardsProfile`
  interface + `PuilProfile`, reusing `StandardValue`/`VerificationStatus` from
  `sni.dart`; all values `secondarySource`, nothing `sniVerbatim` until the
  official PUIL PDF is checked); **A3 part 1** — `electrical/` Tier-1 sizing:
  `load_kind.dart` (LoadKind + defaults), `results.dart`, and `sizing.dart`
  (`loadCurrent`, `deratingFactor`, `voltageDrop`, `selectBreaker`, `sizeCable`),
  all consuming `PuilProfile`; **A3 part 2a** — `electrical/busbar.dart`
  (`sizeBusbar` + `sizeNeutralPeBars`; busbar table added to `PuilProfile`);
  **A3 part 2b** — `electrical/earthing.dart` (`EarthingSystem`/`RcdType`,
  `recommendedRcdType`, `sizeGrounding` cable make-up, `computeEarthing`,
  `circuitRcd`); **A4** — `electrical/{model,panel_results,compute}.dart`: the
  `ElectricalProject`/`Panel`/`Circuit` model (circuit carries the A5 link fields
  `sourceEquipmentId`/`flaOverrideA`) + `computePanel`/`computeSystem` (per-circuit
  sizing, phase balance, incomer/busbar + section split, bottom-up diversified
  demand over the feeder tree with cycle detection, cumulative voltage drop,
  earthing). A4 advanced passes (fault/PF/transformer/sources/arc-flash/harmonics/
  containment/enclosure/occupancy/metering/SPD/lightning) are **deferred to A8**.
  **A5** (`electrical/load_list.dart`: MechX `PumpDuty`/`FanDuty` → `ElectricalCircuit`
  with derived `flaOverrideA`), **A6** (`.mechx` electrical sub-model + version 1→2,
  tolerant load), and **A7** (`lib/store/electrical_store.dart` + `lib/ui/electrical/`
  + plan/schematic/electrical view switch + goldens) have landed, and the two
  integration **seams are wired**: `lib/store/electrical_feed.dart` reads the live
  pump/fan/fire-pump duty providers → A5 `buildEquipmentCircuits` →
  `ElectricalProjectController.syncMepEquipment` (the MEP→E auto-feed), and
  `buildDocument`/`applyDocument` round-trip the electrical project in `.mechx`.
  The product-string **rebrand to "iSystem"** is done (in-app labels + window
  title; the internal package names + `MechX*` classes + Windows `BINARY_NAME`
  stay). The full PanelMaker engine is now ported AND the **A8 advanced passes
  are wired** via `electrical/advanced_study.dart` (`computeAdvancedStudy` →
  `AdvancedStudy`; `electricalAdvancedProvider`) over additive model fields
  (`starterType`, panel backup tiers, project `sources`/dual-tx/occupancy/site)
  that round-trip in `.mechx` — the `computeSystem`/`computePanel` core untouched.
  An **MEP materials catalog** (`standards/pipe_products.dart` PPR/PVC/cast-iron/
  acoustic-PVC/HDPE + `standards/duct_products.dart` BJLS auto-thickness + PU)
  backs the mechanical canvas. **Wave 4 (UI) — the two canvas editors landed**
  (one shared direct-manipulation language): the **mechanical drag-drop canvas**
  (`ui/canvas/segment_palette.dart` + `drop_overlay.dart` + `edge_context_menu.dart`)
  — drag pipe-segment/fitting/terminal/duct cards onto the calibrated canvas,
  drag edge endpoints to resize+snap to fittings (`endNodeDragWithSnap`), right-
  click to set **nominal size in inches** (NPS ladder → additive `NetEdge.sizeOverride`,
  honoured by `autoSizeNetwork(sizeOverrides:)` via continuity v=Q/A) or pick a
  pipe/duct **material** (`NetEdge.pipeProduct`/`ductProduct`, `.mechx`-persisted);
  and the **electrical canvas editor** (`ui/electrical/electrical_view.dart`) —
  `Draggable<LoadKind>` palette → panel `DragTarget` (`addCircuit`), double-click
  inspector, right-click Edit/Duplicate/Delete, add-panel/+Way, and a read-only
  **Advanced-study** card over `electricalAdvancedProvider`. All edits route
  through the store's field-preserving `_withProject`; calc core untouched.
  **Wave 5 — PanelMaker-faithful electrical canvas + left-nav shell landed**: the
  electrical workspace is now a **single-line spatial canvas** (`ui/electrical/electrical_canvas.dart`,
  a port of PanelMaker `BuildingSingleLine.tsx`) — panels as nodes wired by feeders,
  zoom-LOD (summary card ↔ internal R-S-T busbar+breakers), loads hanging below,
  Loads palette (`Draggable<LoadKind>`), outlet-drag-to-feeder, minimap, zoom controls,
  Single-line / Power one-line tabs + canvas toolbar; additive `ElectricalPanel.x/y`
  (no math change). The app shell is now PanelMaker's **248-px left navigation rail**
  (`ui/shell/nav_rail.dart`): DESIGN (Plan/Schematic/Electrical, still driven by
  `workspaceViewProvider`) · Review · Commercial · pinned Projects/Preferences,
  replacing the top-bar view switch (`ShellSection`).
  **iOS / Apple-HIG visual polish landed** (token refresh in `ui/theme/design_tokens.dart`
  — systemBlue accent, grouped backgrounds + label tiers + hairline separators, continuous
  radii, soft `MechXShadow`, SF-like Roboto scale; `MechXButton` = the iOS filled/tinted
  hierarchy), token-driven so it propagates app-wide. **Electrical Layout view landed**
  (`ui/electrical/electrical_layout_view.dart`, a 3rd `_Tab.layout`): the calibrated **PDF
  floor plan as canvas** with panels/loads placed on it → **cable length from geometry**
  (`electricalResultProvider` threads the mechanical `projectControllerProvider`'s
  `calibrations`+`building` into `computeSystem`; placed→geo, unplaced→manual, default
  byte-identical), a co-equal projection of the *same* model as Single-line (add/move/delete
  in either → both update), an **unplaced tray**, **multi-floor** sheet selector, zoom-LOD,
  and an "Electrical layer" chip.
  **Mechanical vertical riser mode landed** (`ui/schematic/schematic_view.dart`): the elevation
  surface now has **Auto** (read-only generated diagram) + **Edit** modes — floors stacked by true
  elevation, a Riser palette, drag-to-place across floors (`placeRiserAt`), drag-sideways to move
  (`moveRiserHorizontal`, length stays the elevation delta), right-click to size (shared
  `edge_context_menu`); mirrors the Plan/electrical direct-manipulation language.
  **Unified one-PDF layered Layout canvas landed — the convergence** (`lib/store/layer_store.dart`
  + `lib/ui/layout/{layout_canvas,layer_switcher,electrical_layer}.dart`): the mechanical Plan
  and the electrical Layout merged into ONE **Layout** workspace on one shared PDF/viewport with
  a **Plumbing · HVAC · Electrical** layer switcher + visibility toggles. The active layer edits
  (DRAW inspector scoped to its services for Plumbing/HVAC via `isAir`; the Loads palette +
  place/move for Electrical); visible-but-inactive layers render **faded/ghosted** for
  coordination; hidden layers omitted; both ride the same sheet viewport + §10 geometry. Left-nav
  **"Plan" → "Layout"** (the `WorkspaceView.plan` enum kept); `ElectricalView` dropped its
  redundant Layout tab (Single-line + Power one-line stay); the riser elevation stays the
  Schematic view. This closes the M+E+P convergence: one calibrated PDF substrate, disciplines
  as layers, geometry-derived lengths, with the abstract Single-line / Power-one-line / riser
  views as companions.
  **Canvas-focus UI + sizing folds LIVE + full catalogue landed (parallel batch):** the floor
  picker is now a **slim numbered rail** (`sheet_rail.dart`) and the right inspector is
  **collapsible** (chevron; both the DRAW/ProjectPanel and the electrical Loads column, on
  Layout + Schematic) so the PDF canvas is the largest region. The **two sizing-mutating folds**
  are folded into `computePanel` and **wired live**: **busbar short-circuit withstand** (Fold 1,
  IEC 61439-1 adiabatic; opt-in `computeSystem(originFaultLevel, busbarClearingTimeS)`, default
  omitted ⇒ byte-identical — the store passes 16 kA at a realistic **0.1 s** clearing time) and
  **triplen-harmonic neutral oversize** (Fold 2, IEC 60364-5-52; always-on, self-guarding to ×1.0
  for linear panels). The **full multi-brand parts catalogue** is ported verbatim into
  `electrical/catalog_data/**` + `catalog.dart` — **534 globally-unique parts** across Schneider /
  Mitsubishi / LS / ABB / Legrand / Chint + generic cables (matchers/`bom.dart`/`quotation.dart`
  unchanged). **`v1.0.0` is SHIPPED** — the work was merged to the default branch
  (`claude/laughing-carson-4vhyf7`) via PRs #1/#2/#3 and the Release workflow published
  `iSystem-1.0.0-setup.exe` + `latest.json` (feed sha256 matches the installer). Two first-release
  CI fixes the Windows runner exposed: goldens are platform-locked (~2% font-AA diff on Windows) so
  the screenshot suite is tagged `golden` and the **release** gate runs `flutter test
  --exclude-tags golden` (the ubuntu `ci.yml` still enforces them); and `iscc` needs
  `MSYS_NO_PATHCONV=1` so Git-Bash doesn't mangle the `/dAppVersion=` define.
  **Wave 4b (electrical drawings export) landed**: pure-engine
  `report/electrical_calc_report.dart` (Markdown over the sized system + power one-line
  + verify items) and `report/electrical_dxf_export.dart` (R12 DXF single-line —
  panels as boxes at their schematic x/y, feeders as LINEs, labels as TEXT; + a
  power-one-line variant), wired behind an Export menu on the electrical toolbar
  (`ui/electrical/electrical_export.dart`). The **per-segment material→hydraulic-solve
  fold landed** (see Sizing-engine invariants) and **Fold-1 fault level + clearing time
  are now project settings** (additive `ElectricalProject.originFaultLevelA` +
  `busbarClearingTimeS`, edited in the Service & Earthing inspector, `.mechx`-persisted,
  defaulting to 16 kA / 0.1 s so an untouched project is byte-identical).
  Remaining in **Wave 4b**: commercial UI (BOM/quotation screens over the catalogue) and
  workflow/i18n (EN/ID).
- **Release + auto-update (Workstream B, landed):** `.github/workflows/ci.yml`
  (the gate on ubuntu) + `release.yml` (windows-latest → `flutter build windows`
  → **Inno Setup** `installer/iSystem.iss` → GitHub Release with `latest.json`),
  and an offline-tolerant in-app updater in `lib/update/` (Riverpod + a
  MechXTheme banner). Version source of truth = `pubspec.yaml`. The web env has
  no Flutter SDK — a `.claude/` SessionStart hook installs Flutter 3.44.3 so the
  gate runs; `flutter build windows`/`iscc` only run on the Windows CI runner.
- Native PDF *drawing* export (DXF drawing export and the Markdown calc report
  are done; both convert to PDF externally).
- Multi-select / copy-paste / measurement-annotation; per-outlet roof-area UI
  for storm (rainfall intensity is tunable; roof area is a fixed default);
  user fixture libraries.
- Looped networks: ring/grid **pressurized & air** mains are balanced with
  Hardy-Cross (`network/hardy_cross.dart`) at sizing time and the balanced flows
  feed the heatmap. The split uses resistance ∝ **real edge length** at a
  consistent ring diameter (runs via calibration, risers via the §10 elevation
  delta when `building`/`calibrations` are passed; pixel-length fallback
  otherwise). Iterating resistance against velocity-sized diameters is
  deliberately NOT done — with D ∝ √Q it is unstable (drives the longer leg to
  zero); residual loop-vs-tree friction from per-segment diameters is
  second-order (`// VERIFY` for strongly non-uniform rings). Gravity loops
  (drainage/vent/rainwater) still use the tree path (physical rings there are
  nonsensical).
- SNI verification debt: values carry a `VerificationStatus` tier —
  `sniVerbatim` (confirmed against the SNI text), `secondarySource` (real but
  pending the official clause), or `notAnSniClause` (deliberately general
  practice). Anything not `sniVerbatim` stays `verified == false` and MUST
  surface (with its tier) in any report. Genuine verbatim confirmation requires
  the official SNI PDF — do NOT flip a flag from a secondary source.
- App lifecycle: the root `ProviderContainer` and autosave `Timer` in `main`
  live for the whole process and are not explicitly disposed (fine for a
  single-window desktop app; revisit if multi-window).

## Sizing-engine invariants (don't regress)

- **Looped sizing (`autoSizeNetwork`)**: a component with > (nodes − 1) edges is
  looped; for pressurized/air services its flows are split with Hardy-Cross
  (`balanceFlows`, resistance ∝ real edge length — pass `building`/`calibrations`
  so risers use the elevation delta) instead of unique-path accumulation, so no
  ring edge wrongly carries the full load. Do NOT iterate resistance against the
  velocity-sized diameters — it is unstable (see the inline note). Trees take the
  exact same code path as before. Don't route gravity loops through Hardy-Cross.
- **Network rooting (`autoSizeNetwork`)**: each service component is rooted at
  its *source* — a `plant`, else a non-fixture/non-demand entry leaf, else the
  busiest demand-free junction. The root's own demand never traverses an edge,
  so a fixture must never be chosen as root or its load vanishes. Demand is
  collected from *every* demand-bearing node (including inline degree-2
  fixtures/diffusers), not just leaves.
- **Units in reports**: typed quantities store SI base units (Pressure in Pa);
  a `StandardValue.unit` is a display label (e.g. "kPa"). Never print
  `value`+`unit` together — surface the human-readable `note`. (See
  `calc_report.dart` / `StandardValue.toString`.)
- **Per-segment material → solve**: `pressure_solve` (`solvePressurized`/`solveDownfeed`)
  honours `edge.pipeProduct` via a per-edge Hazen–Williams C (`hazenWilliamsCFor`, still
  pure H-W — only the C is swapped, never Darcy on the pressurized path); `duct_static`
  honours `edge.ductProduct` via a per-edge Darcy roughness (`ductRoughnessFor` →
  `ductFrictionPaPerMetre(roughness:)`). A null product falls back to the service default
  ⇒ **byte-identical**. PN/pressure-class is NOT folded into hydraulics (a mechanical
  rating, no head-loss term). Fold-1 busbar withstand fault level + clearing time come from
  `ElectricalProject.originFaultLevelA`/`busbarClearingTimeS` (Service & Earthing inspector),
  with the store falling back to 16 kA / 0.1 s when unset.
- **Persistence**: design settings (occupancy, feed, ducts, rainfall, fire
  hazard, theme) round-trip via `DesignSettings` in the `.mechx` file; autosave
  only writes recovery when the work differs from the last clean Save
  (`lastSavedSignatureProvider`), so a saved project leaves no phantom recovery.
