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
**autosave / crash-recovery**; light/dark; **draw-a-room AHU/FCU/fan air sizing**
(Room tool → footprint area from scale × ceiling × per-room-type ACH → CFM, then
auto-sized supply diffusers / return grilles / supply trunk / equipment duty via
`sizing/room_air.dart`, edited in the Rooms inspector, round-trips in `.mechx`;
**'Auto-place diffusers'** in the Rooms inspector closes the room→network loop —
`NetworkController.autoPlaceRoomTerminals` drops the sized supply diffuser count
(+ a return grille) as `supplyDiffuser`/`returnGrille` nodes carrying airflow +
face on a grid inside the room footprint, in one undo step, via the existing node
path);
**manual air routing + velocity warnings** (hand-route ducts, pick a duct size
[right-click → Ø ladder] and a diffuser face size [inspector picker], and the app
warns when the air velocity is too high/low via `sizing/air_velocity.dart` +
`airVelocityChecksProvider` — inspector verdict + an on-plan orange "!" badge);
**AC cooling-load + AC node types** (drop a Cassette / Split-wall / Ducted AC
node into a room and the Rooms inspector auto-computes the cooling requirement —
BTU/h + PK + per-unit recommendation — via `sizing/cooling_load.dart`);
**calibration quality-of-life** (`ProjectController.applyCalibrationToAllSheets` copies one
sheet's scale to all others in one undo step, surfaced as an 'Apply scale to all sheets'
button in the Scale inspector when the current sheet is calibrated; the slim sheet rail shows
a per-sheet calibrated/uncalibrated dot);
**project templates / smart defaults** (`store/templates.dart` `kBuildingTemplates` —
Residential highrise / Office tower / Hospital / Retail shop, each prefilling floors +
occupancy + fire hazard + design rainfall; a **'New from template'** dialog on the Projects
screen applies them via `ProjectController.setFloors` + the occupancy/fire/rainfall provider
`.set()` methods — additive, no `.mechx` change);
**unified Design Issues review panel** (`store/design_issues_store.dart`
`designIssuesProvider` — a read-only fan-in that aggregates every existing design warning
into one typed `DesignIssue` list: out-of-band air velocities + unsized air elements
[`airVelocityChecksProvider`/`airUnsizedProvider`], uncalibrated sheets, and unverified
`// VERIFY` standards [`SniProfile`/`SniVentilationProfile`/`PuilProfile.verifyChecklist`],
each with a severity + an optional `IssueLocation(sheetId, {nodeId, edgeId})`; surfaced as an
`IssuesCard` in the Review hub grouped Warnings/Advisory with a count, a locatable row jumping
to the element via sheet + selection + `WorkspaceView.plan` — no engine change);
**command palette + workflow stepper** (`store/command_store.dart` — `commandPaletteOpenProvider`
+ a pure `fuzzyScore`/`fuzzyMatches` + `workflowStageStateProvider` deriving the five
`WorkflowStage`s [Calibrate · Floors · Draw · Size · Report] done/active O(1) from project
state; `ui/shell/command_palette.dart` is a non-layout **Ctrl/Cmd+K** overlay [renders nothing
when closed] hosted at app-shell level — a centred `MechXTheme` card with a text filter + a
fuzzy-ranked action list [switch DESIGN view, toggle/edit a layer, pick a draw tool, New from
template, Start calibration, Export calc report, light/dark], each run through the existing
providers, Up/Down/Enter/Esc; `ui/shell/workflow_stepper.dart` is a compact status-bar stepper
with custom-painted marks. App-shell wiring is minimal: `AppShell` is a `ConsumerWidget` in a
non-focus-stealing ancestor `Focus` that catches Ctrl/Cmd+K [bubbles up, canvas keeps focus]
+ Esc; no persistence).
**Inspector clarity — collapsible sections + promoted headline results** (`ui/inspector/
disclosure_header.dart` + `result_card.dart` + `store/inspector_store.dart`
`sectionVisibilityProvider`): the dense `ProjectPanel`'s seven major sections (Draw / Tanks /
Rooms / Sizing / Network / Fire / HVAC) are wrapped in a reusable `DisclosureSection` — a tappable
header (replacing the section's `MechXSectionLabel`) with a custom-painted chevron that discloses
its body only when expanded. Expansion is TRANSIENT UI state in `sectionVisibilityProvider` (a
`Map<String,bool>` keyed by section name, read via the memoized `sectionExpandedProvider` family) —
NOT persisted to `.mechx`, so reopening a project restarts from the per-section defaults
(content-bearing sections default expanded; Tanks/Rooms keep their empty-state shrink). The 1–2
headline results per sizing section are promoted to a bold `ResultCard` with a colour-coded
success/warning/danger verdict (Network: pump motor kW, or PRV-zones worst-kPa OK/over; HVAC: fan
static + motor), demoting the supporting key/value rows beneath; each card renders only when its
result exists, so a blank launch is byte-identical (goldens shift only by the small chevron glyph).

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

- **Audit-fix wave (2026-06-28) — resolved** (`AUDIT-REPORT.md`, see the §15 row):
  the over-capacity air duct no longer THROWS (clamps + `EdgeSizing.overCapacity`
  flag → Review warning via `airOverCapacityProvider`); rectangular ducts honour
  equal-friction; looped water-supply diversifies the SUMMED UBAP once (no over-sized
  ring source); a cable that can't meet `Iz ≥ In` raises a `cable-ampacity-inadequate`
  ERROR instead of failing silently; TT feeders now require a 300 mA S-type RCD and
  an uncovered TT way warns `tt-no-earth-fault-protection`; hand-entered motor FLC
  includes a 0.88 efficiency factor. The over-capacity duct now also carries an
  **on-plan badge** — a red warning-TRIANGLE at the duct midpoint
  (`network_layer.dart`, distinct shape from the round velocity "!" dot, taking
  precedence over it), driven by `airOverCapacityProvider`, in addition to the
  Review-panel warning.
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
  zoom-LOD (summary card ↔ internal R-S-T busbar+breakers), loads hanging below as
  **IEC 60617-style schematic symbols** (`ui/electrical/load_symbols.dart` `LoadSymbol`,
  shared with the Loads palette + the layout markers — one symbol language; replaced the
  old text-tag glyph box),
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
  **Wave 4b commercial + i18n landed too:** a **Commercial workspace**
  (`lib/store/commercial_store.dart` + `lib/ui/commercial/**`) — electrical BOM over
  `fullCatalog()`, an editable pricelist (`sku→price`, kept OUT of the catalogue), and a
  costed quotation (labour/overhead/contingency/margin) with CSV/Markdown export
  (pure `electrical/commercial_export.dart`); and a **Material-free EN/ID i18n**
  mechanism (`AppLocale`/`localeProvider` + `ui/strings/app_strings.dart`'s `MechXStrings`
  InheritedWidget + `context.strings`, a Preferences language toggle; string batches so far =
  nav-rail + Preferences, then the whole **Commercial workspace** + the electrical **Export menu**
  + the Fold-1 Service & Earthing fields (26 more keys), then the **DESIGN-workspace chrome**
  (app shell top-bar/banners/status-bar + Schematic Auto/Edit toolbar + the `project_panel`
  inspector) — all EN byte-identical so goldens are unchanged. `MechXStrings.of` now degrades to
  EN when no provider ancestor is present (so widgets pumped standalone never throw). Both
  round-trip additively in
  `DesignSettings` (pricelist+markups; `localeCode`, tolerant unknown→en), no version bump.
  **Electrical export now has full mechanical parity** — `report/electrical_pdf_export.dart`
  adds a native vector-PDF single-line (single A3 page, no third-party dep; panels as stroked
  rects at their schematic x/y, feeders as lines, labels as text, auto-fitted) alongside the DXF
  + Markdown, wired as a 'PDF (vector)' row in the toolbar Export menu.
  The i18n mechanism also gained **parameterized templates** — `MechXStringsData.format(key,
  {…})` substitutes `{name}` placeholders (EN+ID templates carry identical placeholders, pinned
  by a test) — and the Commercial workspace's dynamic captions (BOM/pricelist leads, unpriced
  count, labour-rate/amount/hours labels) now use it.
  The **export OS save-dialog titles** (all 10, across mechanical/electrical/commercial) are now
  localized too — the export fns resolve the active locale via `ref.read(localeProvider)`, so no
  signature/call-site churn. Remaining in **Wave 4b** (deferred, incremental): only the
  heatmap/plan-canvas on-overlay abbreviation labels (`DN50 · 3.5 m`-style, golden-locked, low
  prose value) are still literals.
- **Release + auto-update (Workstream B, landed):** `.github/workflows/ci.yml`
  (the gate on ubuntu) + `release.yml` (windows-latest → `flutter build windows`
  → **Inno Setup** `installer/iSystem.iss` → GitHub Release with `latest.json`),
  and an offline-tolerant in-app updater in `lib/update/` (Riverpod + a
  MechXTheme banner). Version source of truth = `pubspec.yaml`. The web env has
  no Flutter SDK — a `.claude/` SessionStart hook installs Flutter 3.44.3 so the
  gate runs; `flutter build windows`/`iscc` only run on the Windows CI runner.
- Native PDF *drawing* export — **done**: `report/pdf_export.dart` (`networkToPdf`,
  the plain single-sheet vector PDF) and `report/plan_pdf_export.dart`
  (`planToPdf`, the **annotated** plan PDF — adds a project/sheet/date title block
  and real §10 run/riser LENGTHS folded into each DN/Ø/W×H label, nodes as dots,
  risers as markers; the app passes a `dateString` + pre-computed `edgeLengths` so
  the engine never reads the clock), wired in `projects_screen.dart` beside the
  DXF + Markdown-calc-report exports. **Issuable drawing chrome — done**: pure
  `report/drawing_chrome.dart` (`DrawingChrome` value object + shared PDF/DXF
  renderers for a service-colour LEGEND, a graphic SCALE BAR, a bearing-rotated
  NORTH arrow, and a top-right drawing-number/revision/sheet "X of Y" block) is
  threaded as an optional `chrome` param into all four exporters
  (`networkToPdf`/`planToPdf`/`networkToDxf`/`electricalSldToPdf`); null/empty ⇒
  byte-identical. The app builds it from live state in `project_panel`
  `_issuableChrome` (legend = on-floor services, sheet counter = rail position,
  north = page-up; drawing number/revision deferred to a future `DesignSettings`
  wave). The heatmap legend now shows both numeric `Low`/`High` kPa endpoints
  (uniform field too) and sits bottom-right, clear of the bottom-left zoom
  cluster. **Defensible report deliverables — done**: both calc reports now print
  a `## Design basis` (Inputs & Assumptions) register echoing the actual project
  inputs (mechanical: levels/height, occupancy, feed, target residual, rainfall+C,
  fire systems via `writeMechanicalDesignBasis`; electrical: supply/load/earthing
  + Fold-1 fault target via `writeElectricalDesignBasis`), an optional `## Revision
  history` table (`Revision(date, description)` in `standards/sni.dart`; empty list
  ⇒ no table ⇒ byte-identical), and inline `**citation**` next to each unverified
  value. New pure `report/mep_report.dart` `buildMepUnifiedReport(mechanical,
  electrical, compliance)` composes ONE M+E+P document — unified head + a single
  design-basis register from both disciplines + a `ComplianceSummary` pass/fail
  table (app-derived from `designIssuesProvider`, engine renders only) + the full
  mechanical & electrical bodies (each H1 stripped, demoted) + the merged revision
  history. Wired as a localized **'Export unified MEP report (MD)'** button beside
  the existing exports on the Projects screen (`project_panel.exportMepUnifiedReport`);
  no `.mechx` change (revisions/compliance are export-time inputs).
  **Equipment schedules — done**: new pure `report/equipment_schedule.dart`
  (`buildEquipmentScheduleRows`/`buildEquipmentScheduleMarkdown` over
  `EquipmentScheduleData` = `PumpScheduleItem`/`FanScheduleItem` wrappers + the solved
  `ElectricalSystemResult`) tabulates the procurement schedule — tag · service · duty ·
  size · model/spec placeholder · qty — grouped by `EquipmentCategory`
  (pump / fan / airHandling AHU-FCU-AC / panel), synthesising sequential tags
  (`P-01`/`F-01`/`AHU-01`) when a source carries none. The engine only TABULATES solved
  duties (no new physics); model/spec stays a "—" placeholder (a tag + qty are
  bookkeeping, so nothing to `// VERIFY`). Wired as a localized
  **'Export equipment schedule (MD)'** button on the Projects screen
  (`project_panel.exportEquipmentSchedule` — supply pump + standpipe fire pump, the
  duct fan, each room's AHU/FCU/AC duty, and every electrical panel from the live
  providers). No model churn (`PumpDuty`/`FanDuty` untouched; tags assigned at gather
  time) and no `.mechx` change (gathered at export time).
- **Landed (parallel batch):** **multi-select + copy/paste** (additive
  `Selection.nodeIds/edgeIds` sets + rubber-band marquee/shift-click in
  `selection_overlay`, in-memory clipboard `copySelection`/`paste`/`deleteMany` in
  `network_store` with fresh-id remap + single undo step, Ctrl/Cmd+C/V + multi-delete,
  `isMulti` inspector header); **user fixture libraries** (pure-engine `CustomFixture`
  + `fixture_library_store`/`fixture_library_editor`, `DesignSettings.fixtureLibrary`
  round-trip, `sizing_store` resolves `NetNode.customFixtureId` → UBAP/DFU/flush loads,
  inspector custom pills, built-in path byte-identical when empty); **per-outlet
  roof-area** (`NetNode.roofAreaM2` → per-outlet rainwater flow in `nodeFlowDemand`,
  inspector stepper, null ⇒ byte-identical). **Measurement annotations** also landed
  (`store/annotation_store.dart` `Measurement` + `measurementsProvider`/`measureModeProvider`;
  `ui/canvas/measurement_overlay.dart` — a DRAW-panel **Measure** tool: two-click dimension
  lines on the calibrated sheet with the real length via `ScaleCalibration.lengthForPixels`,
  secondary-click to delete; round-trips in `.mechx` as a top-level `measurements` list,
  tolerant/absent ⇒ empty). This **closes the Known-gaps editing list**.
  **Drafter-productivity suite** also landed (faster drafting, each simpler than its AutoCAD
  analogue): **select-similar** (`selection_store` `selectSimilarEdges`/`Nodes` + a row in both
  context menus → select every element of the same service/component for batch edit; pure
  selection, no undo; added `Network.edgeById`); a **smart input bar** (`store/smart_input_store.dart`
  pure `parseDrawingInput`/`polarRunTarget` + `drawHoverProvider`, `ui/canvas/smart_input_bar.dart`
  — type an exact run length in mm [`3000`, or `3000 90` to pin the bearing] while drawing,
  direct-distance entry along the live cursor; calls the existing `placeRunPoint`, mounted only
  while drawing so idle is byte-identical); **one-click issue sets** (`design_issues_store`
  `issueBatchActionsProvider` + "Quick fixes" chips in `issues_card` — SAFE batch actions:
  select-all-velocity-warnings, select-all-unsized-air, copy-scale-to-all-uncalibrated-sheets;
  read-only-derived, executor in the UI); and **offset run** (`NetworkController.offsetEdgeParallel`
  + `ui/canvas/offset_dialog.dart` — right-click a run → "Offset…" → distance+side → a parallel run
  in one undo step; auto-split-on-drag deferred).
  **In-app Claude copilot** also landed — Claude embedded in the app so the engineer selects a
  room/element and asks the AI to design or change it: **command registry** (`lib/ai/commands.dart`
  — a typed CLOSED `AiCommand` set [placeComponent/Terminal/Fitting/Segment, autoPlaceRoomTerminals,
  suggest], each pure JSON-round-trippable with a `preview` + the Anthropic tool-use schema; an
  unknown kind decodes to null = hallucination guard); **injectable client** (`lib/ai/ai_client.dart`
  — `AiClient` interface + `AnthropicAiClient` [raw HTTP `/v1/messages`, tool-use, BYO key, model
  `claude-sonnet-4-6`] + `FakeAiClient`; all failures TYPED `AiResult` ok/disabled/error, never
  throws; offline/no-key ⇒ graceful); **copilot store** (`lib/store/ai_copilot_store.dart`
  `CopilotController` — the plan→preview→confirm→apply loop: `ask()` gathers a compact context
  snapshot + proposes WITHOUT applying, `applyPlan()` runs each command through the existing
  `NetworkController` methods [one undo each, sizing recomputes reactively], `discard()`;
  `aiClientProvider` overridable for tests); **UI** (`lib/ui/ai/copilot_panel.dart` `CopilotOverlay`
  — right-side panel gated on `copilotOpenProvider` ⇒ `SizedBox.shrink` when closed so goldens are
  byte-identical; opened via a **"Ask Claude"** command-palette action); **BYO key** persists via
  additive `DesignSettings.anthropicApiKey`/`aiModel` (tolerant) + an API-key card in Preferences
  (masked). The registry + plan loop are fully covered offline via `FakeAiClient`; the live call
  needs the engineer's key.
  **Copilot multi-provider (OpenAI + GLM backups) + model dropdown landed:** the copilot now
  runs on **Anthropic** (primary), **OpenAI**, or **GLM** (Zhipu) so an engineer with any one of
  those keys gets the copilot — all three behind the same injectable `AiClient` seam. New
  `lib/ai/openai_client.dart` (`OpenAiAiClient` → `POST /v1/chat/completions`, the registry mapped
  to OpenAI function-tools via pure `openAiToolsFromRegistry()`, `tool_calls` decoded by pure
  `parseOpenAiResponse`) and `lib/ai/glm_client.dart` (`GlmAiClient` → Zhipu's OpenAI-compatible
  `…/paas/v4/chat/completions`, **reusing** the OpenAI client's two pure static helpers — only the
  endpoint/auth/system-prompt differ); same TYPED `AiResult` ok/disabled/error, offline-graceful.
  `ai_client.dart` adds `AiProviderKind` {anthropic, openai, glm} + `defaultModelForProvider`/
  `aiProviderFromName`/`modelFamilyMatches` + a per-provider **model catalog** (`kAnthropicModels`/
  `kOpenAiModels`/`kGlmModels` + `modelsForProvider`/`modelLabelFor`). `aiProviderProvider`
  (`app_state.dart`) drives `aiClientProvider`'s 3-way switch; the store resolves a **family-correct
  model** (`_effectiveModel` via `modelFamilyMatches` — never sends a `claude-*` id to GLM/OpenAI
  etc., even from a hand-edited file). Persists additively via `DesignSettings.aiProvider`
  (tolerant, unknown→anthropic). Preferences AI card: a 3-way **Provider** toggle (re-seeds the
  model to that provider's default on switch) + a custom MechXTheme **model dropdown**
  (`_ModelDropdown`, inline disclosure, no Material — closed ⇒ byte-identical so Preferences-not-in-
  goldens stays stable) listing the active provider's models. **Subscription/OAuth sign-in is still
  NOT built (for any provider)** — a live browser PKCE flow needs a provider-registered OAuth client
  ID that third-party apps can't obtain (Anthropic) and consumer ChatGPT login ≠ OpenAI API access;
  so the shippable path stays BYO-key per provider (no dead OAuth scaffolding, per the declutter
  direction).
  **Riser-view discoverability (declutter-consistent clarity):** the "Schematic" view is renamed
  **"Riser"** (nav + `WorkspaceView.label` + the command palette's "Go to Riser"). Two ON-DEMAND
  (behind the existing `?` guides, hidden by default ⇒ goldens byte-identical) clarity lines were
  added rather than persistent prose: the Layout canvas mechanical guide notes that risers drawn
  on the plan stack vertically in the Riser view, and the Riser-view Edit help legend leads with
  an Auto-vs-Edit mode explainer (`StringKey.schematicHelpModes`, EN+ID).
  **Mechanical ↔ electrical theme convergence landed (Apple-consistency pass):** the
  electrical workspace (a PanelMaker port) now reads as one app with the mechanical one.
  Driven by an audit + re-review, converged: the electrical **Loads palette to the RIGHT**
  (inspector side everywhere); a **shared drafting grid** (`ui/canvas/canvas_grid.dart`
  `paintCanvasGrid`) behind BOTH canvases; **shared right-bar widgets**
  (`ui/widgets/section_label.dart` `MechXSectionLabel` + `ui/widgets/palette_card.dart`
  generic `PaletteCard<T>`) used by both `SegmentPalette` + `ElectricalPalette`; **one
  selected-segment style** (LAYER switcher → tinted `accentMuted`+border, matching DRAW
  pills / electrical tabs / chips); a **shared `ui/canvas/zoom_controls.dart` `ZoomControls`**
  on both canvases (CanvasView gained an imperative zoom API via a per-sheet
  `GlobalKey<CanvasViewState>`); the electrical toolbar button on the canonical `MechXButton`
  soft-fill; a branded mechanical empty-state card; harmonised drop-target tint. New tokens:
  `MechXRadii.xs`, `MechXColors.onAccent`, `MechXTypography.micro`. (Goldens 01/02/03/05/06
  regenerated + visually verified; gate green.)
  **Predictable canvas interaction landed (drag-only / focus-only, goldens stable):**
  the mechanical drop overlay (`ui/canvas/drop_overlay.dart`, now stateful) paints a
  drag-place PREVIEW — a faint ghost glyph (`paintComponentSymbol`/`paintSegmentSymbol`)
  at the cursor + a snap ring/crosshair on the nearest fitting within the shared 14px
  radius (`_kSnapScreenPx`; nearest-node search mirrors the store `_snap`), with the
  canvas tint strengthening to a will-snap state — all mounted ONLY while a card hovers,
  so idle is byte-identical. A shared `ui/widgets/canvas_guide_popover.dart`
  (`CanvasGuideButton` + `CanvasGuideLegend`, lifted from the electrical canvas) adds the
  persistent **(?)** affordance to the mechanical Layout canvas with discipline-scoped
  gesture help. And `PaletteCard` gained an optional `onActivate` (via the existing
  `MechXFocusRing` Enter/Space) so a focused palette card drops at the current sheet's
  centre (`SegmentPalette.dropAtCentre`, same store add-actions). No engine / `.mechx`
  change.
  **Feedback loop + states landed (UI-only, goldens 01–07 shift):** silent/empty/
  colour-only states now give explicit feedback. The `IssuesCard` renders a positive
  **"No design issues found"** success card (custom-painted check) instead of
  `SizedBox.shrink()` when clean. A transient `statusMessageProvider` (`store/app_state.dart`,
  `showStatus()` self-clearing after 3 s, null at rest) drives a quiet success pill in the
  status bar (`_StatusConfirmation`) on a successful Save / Open / Import. The status-bar
  **workflow stepper is now clickable** (`workflow_stepper.dart` `_StageChip` →
  `MouseRegion`+`GestureDetector`): each stage jumps to where it's done (Calibrate → start
  calibration on Layout, Floors → Building, Draw/Size → Layout, Report → Review) via existing
  providers. Colour-only status gained **redundant glyph cues** — the sheet-rail calibration
  dot (`sheet_rail.dart` `_CalibrationGlyph`) and the issue-severity dot (`issues_card.dart`
  `_SeverityGlyph`) are now check-ring vs "!"-ring shapes paired with the success/warning
  colour. Cleanup: dropped the duplicate electrical `_WarningList` (review_hub), the dead
  no-op **Import loads** button (electrical_view), and the 'recent-projects coming soon'
  placeholder (projects_screen). New text only appears in non-golden states so EN stays
  byte-identical (no new `StringKey` keys). No engine / `.mechx` change (status message is
  transient; stepper reuses volatile providers).
  **Review-driven declutter (Batch A, subtraction) landed:** a 3-agent read-only review
  (declutter / polish / mechanical-electrical consistency) drove an Apple-style subtraction
  pass. Removed persistent how-to prose the on-demand `(?)` guides already cover — the
  electrical-layer help caption (`app_shell.dart`), the Loads-palette instruction line
  (`electrical_palette.dart`), the Projects-screen `HubNote`, the unplaced-riser-tray drag hint
  (`electrical_layer.dart`) — plus redundant section labels (the `'Palette'` header in
  `segment_palette.dart`, the `'LAYER'` header in `layer_switcher.dart` — reclaims canvas width)
  and inspector right-click/face-size coaching suffixes (`project_panel.dart`: calibration
  status, duct/face prompts trimmed to status-only). Goldens 01–07 regenerated + visually
  verified (tighter inspector/Layout chrome, no tofu/overflow); `network_store_test` dropped its
  `'PALETTE'` assertion. The companion **Batch B (shared-widget consolidation)** + **Batch C
  (token + a11y polish)** from the same review landed as follow-on passes, and the final
  **Batch D (electrical interaction parity)** is now done: the electrical drop targets
  (`_SheetDropTarget` in `layout/electrical_layer.dart`, `_CanvasDropTarget` in
  `electrical/electrical_canvas.dart`) paint a mechanical-`DropOverlay`-style **drag-place
  preview** — a cursor-following ghost `LoadSymbol` (+ a nearest-panel snap ring on the Layout
  layer; the single-line canvas has no ring as blank-canvas drops never attach), mounted ONLY
  during a drag so idle is byte-identical; the drop-tint is unified to the mechanical
  `accent.withAlpha(18→35 on will-snap)` + `MechXRadii.card` language; in-frame PanelMaker-isms
  are normalised (**"Daya" → "Demand (kVA)"**, badge **"ess" → "essential"**; R/S/T/N/PE/INC/UPS/kWh
  kept); and a single `MechXMotion.hoverLift` (1.03) / `pressScale` (0.98) token pair replaces the
  five hardcoded hover-scale literals. No engine / `.mechx` change.
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

- **Plumbing-rigour advisories + storm runoff C (additive, `// VERIFY`)**:
  `rainwaterDesignFlow` takes an optional `runoffCoefficient` (rational method
  `Q = C·i·A/3.6e6`, default **1.0** ⇒ byte-identical) threaded from the project
  input `DesignSettings.runoffCoefficientStorm`/`runoffCoefficientProvider`
  (default 0.9). `sizing/drainage_advisory.dart` (`drainageAdvisories`) is a
  JUDGE-ONLY layer — it flags a too-flat laid slope (< 0.005) and an over-long
  developed length (> 32 m) and NEVER resizes; `hot_water.dart` adds a modelled
  `returnTempC` (= `flowTempC` − ΔT) + `legionellaRisk` (< 55 °C). All three feed
  the Review panel via `drainageAdvisoryProvider` / `hotWaterLegionellaProvider`
  → `designIssuesProvider` (info-severity). All four thresholds live in
  `SniProfile.verifyChecklist` (`notAnSniClause`) and the calc report. The minSlope
  and Legionella checks sit AT their thresholds with the live defaults (slope 0.01,
  ΔT 5 K) so they don't fire until those inputs change — the developed-length and
  runoff-C paths are the ones exercised by a default project.
- **Looped sizing (`autoSizeNetwork`)**: a component with > (nodes − 1) edges is
  looped; for pressurized/air services its flows are split with Hardy-Cross
  (`balanceFlows`, resistance ∝ real edge length — pass `building`/`calibrations`
  so risers use the elevation delta) instead of unique-path accumulation, so no
  ring edge wrongly carries the full load. Do NOT iterate resistance against the
  velocity-sized diameters — it is unstable (see the inline note). Trees take the
  exact same code path as before. Don't route gravity loops through Hardy-Cross.
  Looped **water-supply** components accumulate RAW per-node UBAP, curve the
  SUMMED units ONCE via `probableFlowForFixtureUnits`, then split the diversified
  total by each node's UBAP share before Hardy-Cross (mirrors the tree path — a
  ring edge no longer carries an un-diversified full load).
- **Duct over-capacity NEVER throws (`sizing/duct_sizing.dart`)**: when the ideal
  diameter/side exceeds the largest standard size, `sizeByVelocity` /
  `sizeByEqualFriction` / `sizeRectangularByVelocity` / `sizeRectangularByEqualFriction`
  CLAMP to the largest size and set `overCapacity = true` (carrying the actual
  over-target friction) — they must NOT `orElse: throw` (a throw aborts the whole
  solve). `EdgeSizing.overCapacity` threads the flag through `sizeEdge`; the app
  surfaces it via `airOverCapacityProvider` → `designIssuesProvider` as a per-edge
  warning AND as an on-plan red warning-triangle badge at the duct midpoint
  (`network_layer.dart`, distinct shape from the round velocity "!" dot and taking
  precedence over it). `overCapacity` is a
  robustness flag, NOT a standards value (no `// VERIFY`). Defaults false ⇒
  in-range ducts byte-identical. Rectangular ducts now honour equal-friction
  (`sizeRectangularByEqualFriction`) when `ctx.ductMethod == equalFriction` (in
  both `network_sizing` and `room_air`); the velocity path is unchanged.
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
  `ductFrictionPaPerMetre(roughness:)`). A null **pipe** product falls back to the service
  default ⇒ **byte-identical**. A null **duct** product resolves via
  `effectiveDuctProductFor` to the SERVICE DEFAULT — **PU** for AC supply/return air, **BJLS**
  (galvanised steel) for exhaust (`defaultDuctProductForService`) — so an AC duct defaults to
  PU friction (smoother → lower fan static) and a 4 m PU section length, exhaust to BJLS /
  1.2 m; this same resolver drives the on-canvas material tag + the cut-plan section length.
  PN/pressure-class is NOT folded into hydraulics (a mechanical rating, no head-loss term). Fold-1 busbar withstand fault level + clearing time come from
  `ElectricalProject.originFaultLevelA`/`busbarClearingTimeS` (Service & Earthing inspector),
  with the store falling back to 16 kA / 0.1 s when unset.
- **Room air sizing (`sizing/room_air.dart`)**: `sizeRoomAir` is pure
  ORCHESTRATION — it computes the airflow (`airChangeFlow` = floor area × ceiling ×
  ACH / 3600) then *composes* the existing primitives (`duct_sizing`, `grille_sizing`,
  `fan.sizeFan`); it adds NO new hydraulics. Supply diffusers / return grilles are
  auto-split so each face stays ≤ its noise limit (never falls back to an
  over-velocity face). The equipment total static is a documented first-pass
  ESTIMATE (kind internal allowance + duct friction × assumed run × fitting factor +
  terminal drops) for equipment selection — the drawn-network `duct_static` solve
  stays the authority. ACH values (`standards/ventilation.dart`) are all
  `secondarySource` (UNVERIFIED) until the SNI 03-6572-2001 PDF is checked. `RoomArea`
  is an annotation (like `TankArea`): it NEVER feeds the pressurized network solve.
- **Fire-protection rigour (`sizing/fire_sprinkler_hydraulic.dart` +
  `sizing/fire_pump_rating.dart`)**: both are pure ORCHESTRATION over
  `hydraulics.dart`/`pump.dart` (NO new physics) layered over the density/area
  (`fire_sprinkler.dart`) + standpipe (`fire_standpipe.dart`) modules, additive and
  byte-identical-by-default. **Sprinkler:** `remoteAreaHydraulics` checks the most-
  remote head with the discharge law `Q = K·√P` (`P = (Q/K)²`, K in L/min/bar^0.5,
  P in bar) for the head's density/area share, adds branch-line friction via the
  engine's own `headLossHazenWilliams`, and emits a minimum-operating-pressure
  verdict. Defaults K = 80 / min 0.5 bar / 20 m·25 mm·C 120 branch are general
  practice (`// VERIFY`, NOT an SNI clause). **Fire pump:** `checkFirePumpRating`
  builds the NFPA 20 acceptance curve — churn (140 % head @ 0 % flow), rated, overload
  (65 % head @ 150 % flow) — sizes the motor on the governing (rated) point via
  `selectMotor` (flags 'Oversized pump curve' when the standard frame saturates),
  recommends a jockey pump (1 % rated flow @ churn head + 5 m) and a duty/standby
  designation. The curve ratios (140 %/65 %/150 %/1 %) are NFPA 20 acceptance *limits*
  (`secondarySource`/`// VERIFY`), not a specific pump's certified curve. Wired via
  `fire_store.dart` (`firePerHeadKFactorProvider`, `sprinklerRemoteAreaProvider`,
  `firePumpRatingProvider`) and surfaced under the calc report's **Fire protection**
  section (nullable `CalcReportData.sprinklerRemoteArea`/`firePumpRating` ⇒ section
  unchanged when absent). No `.mechx` change — providers derive from existing state.
- **Air-velocity warnings (`sizing/air_velocity.dart` + `airVelocityChecksProvider`)**:
  a JUDGE-ONLY layer over the manually routed air network — it never resizes
  anything. Duct edges use the live `EdgeSizing.velocity`; air terminals use
  `faceVelocityFor(airflow, grossFaceArea)` from the node's chosen
  `faceWidthMm`/`faceHeightMm`. Bands are plain constants (supply duct 3–7 m/s,
  supply face 1.0–3.0, return/exhaust face 1.0–4.0) — general practice, NOT an SNI
  clause (`// VERIFY`). A non-positive velocity or a terminal with no chosen face is
  reported OK (nothing to warn about), so a project with no manual air sizing is
  byte-identical (no badges, goldens unchanged). A separate `airUnsizedProvider`
  flags air ducts/terminals that carry air but have no manual size/face yet (a
  muted advisory marker, distinct from the orange out-of-band warning, which
  always takes precedence).
- **AC cooling load (`sizing/cooling_load.dart`)**: pure ORCHESTRATION — an
  area-density estimate (floor area × per-`RoomType` density × ceiling
  correction → BTU/h) mapped to **PK** (1 PK ≈ 9000 BTU/h, convention) + a
  standard-ladder `selectAc`. It adds NO heat-gain physics (not a CLTD solve);
  the density + PK convention are `secondarySource`/`// VERIFY`. It is surfaced
  only when an AC node (`acCassette`/`acSplitWall`/`acDucted`) sits inside a
  `RoomArea` footprint — an annotation read, never part of the network solve. A
  placed AC's ELECTRICAL load tracks that PK: `electrical_feed` derives its panel
  circuit from the room cooling (split across the room's AC units) via
  `acInputPowerW` (output ÷ COP 3.0, `// VERIFY`); an explicit `electricalLoadW`
  override wins, and an AC in no scaled room falls back to `defaultMotorKw`.
- **Detailed cooling load (`sizing/cooling_load_detailed.dart`)**: an opt-in
  heat-gain alternative to the area-density rule — still pure ORCHESTRATION, no
  transient CLTD/RTS solve. `estimateDetailedCoolingLoad` sums the physical
  streams split into **SENSIBLE** (envelope U·A·ΔT over walls/roof/glazing +
  solar SHGC·irradiance·area + people-sensible + lighting + equipment +
  ventilation ρ·cp·V̇·ΔT) and **LATENT** (people-latent + ventilation
  ρ·h_fg·V̇·Δw), → BTU/h + PK + `selectAc` (which rejects sensible + latent).
  Every coefficient (U-values, SHGC, design ΔT/Δw, gain densities, infiltration
  ACH, air ρ/cp/h_fg) is a single representative steady-state default tagged
  `secondarySource`/`// VERIFY` and surfaced via `detailedCoolingVerifyChecklist`.
  The simple `cooling_load.dart` stays the fallback; `DesignSettings.coolingLoadMethod`
  (`'simple'`/`'detailed'`, default `'simple'`) selects, round-tripping additively.
- **Multi-zone HVAC (`room_air.dart` `multiZoneAirSystem`)**: aggregates several
  already-sized `RoomAirResult`s onto one central AHU/fan — pure summation + a
  **diversity/coincidence factor** k ∈ (0,1] (default 0.9, `// VERIFY`) scaling
  the summed airflow to the simultaneous peak, re-sizing the central duty via
  `sizeFan` against the diversified airflow at the **governing** (worst-zone)
  static. Adds NO air physics. `ExhaustStrategy` (returnAll/supplyAll/balanced)
  drives an informational make-up/exhaust balance note (net supply vs net
  extract), advisory only. `DesignSettings.multiZoneDiversityFactor` (clamped to
  (0,1]) + `multiZoneExhaustStrategy` round-trip additively (no version bump).
- **Cable family → ampacity class**: a circuit's `cableType` (NYY/NYM/NYA/NYAF/FRC)
  selects the insulation temperature-class for the KHA lookup via
  `electrical/cable_family.dart` (`insulationForCableType`): **FRC → XLPE 90 °C**,
  the others → PVC 70 °C, `null`/unknown → the panel-wide fallback. `compute.dart`
  threads it into both `sizeCable` and `deratingFactor`, so a typed run sizes/derates
  on its own class (notably FRC life-safety cable is no longer mis-rated at the panel
  default). Null `cableType` ⇒ **byte-identical**. The KHA *numbers* are the
  Supreme/SUCACO-ported tables; per-family number tables that depart from the generic
  method table remain a `// VERIFY` refinement pending the Supreme datasheet.
- **Cable ampacity-inadequate is SURFACED, never silent (`electrical/{results,compute}.dart`)**:
  `CableResult.ampacityReached` (default true) is false only when the cable cannot
  satisfy `Iz ≥ In` even at the largest CSA (the vd-only fallback still REACHED
  ampacity → true). `compute.dart` `_computeCircuit` emits a `WarningSeverity.error`
  `cable-ampacity-inadequate` (IEC 60364-4-43 / PUIL 2.2.8.3, names Iz vs In) when
  `!ampacityReached` — fires only on a previously-silent unsafe design ⇒ byte-identical
  otherwise. The `csaMm2`/`deratedIz` numbers are unchanged.
- **TT feeders get earth-fault protection (`electrical/{earthing,fault}.dart`)**:
  `circuitRcd` adds a TT-FEEDER branch (below the TT-final branch) requiring a
  **300 mA S-type time-delayed** RCD (selective above the 30/100 mA finals; reason
  `// VERIFY`); spare/life-safety early-returns still win and TN feeders are unchanged.
  `fault.dart` warns `tt-no-earth-fault-protection` for a TT way covered by neither
  ADS nor an RCD (e.g. an RCD-exempt life-safety run). TT finals now carry
  `rcd.required = true`, so existing TT invariants (`zsOhm`/`adsOk` null, no
  `ads-disconnection`) are preserved and they no longer warn.
- **Motor FLC includes efficiency (`electrical/compute.dart`)**: a hand-entered
  motor's `motorKw` is SHAFT power; the `motorLike` branch divides it by a file-level
  `_assumedMotorEfficiency = 0.88` (`// VERIFY` `secondarySource`, deliberately NOT in
  a standards profile to avoid implying SNI/PUIL provenance) before deriving Ib — so
  the input current reflects the supply, not the shaft. The A5 `flaOverrideA` feed
  path (MEP pump/fan duty) is untouched. NOT byte-identical: hand-entered motor Ib
  rose ~13.8 % (the affected test's phase-balance/section-current/imbalance were
  re-derived to the new first-principles values; the protection/cable/incomer/busbar
  ladder rungs were unaffected).
- **Pump/fan operating point (`sizing/operating_point.dart`)**: pure
  ORCHESTRATION over `hydraulics.dart` — the system-resistance curve
  (`H_sys = H_static + k·Q²` pump / `Δp_sys = k·Q²` fan) × a representative
  equipment parabola (pinned to the design point, 125 % shutoff), intersected in
  CLOSED FORM (`Q_op = √((H_shutoff − H_static)/(k + a))`, no iteration) with a
  `stable` flag for no-real-root / near-tangent crossings. The system **k is a
  DESIGN INPUT, never fitted from the solved network** — back-solved through the
  design point when omitted. Pumps also get `NPSH_available` vs a `// VERIFY`
  `NPSH_required` estimate with a conservative `cavitationRisk` flag
  (`NPSH_a < 1.5·NPSH_r`). All curve coefficients are representative
  `secondarySource`/`// VERIFY` estimates, NOT certified machine data. Composed
  additively: `PumpDuty`/`FanDuty.operatingPoint` is null unless `sizePump`/
  `sizeFan` is called with `withOperatingPoint` / a system-curve param ⇒
  byte-identical otherwise. `SizingContext` carries the design-input coefficients
  (`systemHeadStatic`/`systemResistanceK`/`airSystemResistanceK`, default null).
- **Electrical spare-ways / future-load headroom (`electrical/headroom.dart`)**:
  `HeadroomSpec(sparePercentage, spareWays)` on `ElectricalPanel.headroom` (nullable,
  additive). `computePanel` sizes the **incomer + main/section busbar** against the
  FUTURE line current (`demandCurrentA × (1 + %/100)`) and counts reserved spare ways
  toward the busbar way capacity; **per-circuit sizing is untouched** (today's circuits
  keep today's load). Null / 0 %-0-way spec ⇒ multiplier 1.0, no spare ways ⇒
  incomer/busbar/section count **byte-identical**. `ElectricalPanelResult` carries
  read-only `futureLoadW`/`headroomApplied`/`spareWaysReserved` for reporting. A spare
  allowance is the engineer's design input, not a PUIL clause (no standards table).
- **Electrical selectivity refinement (`electrical/fault.dart`)**: a coarse
  rating-ratio time-current ZONE model (`classifySelectivity`: non-selective <1.6× ≤
  partial <2.5× ≤ total) — a documented SIMPLIFIED stand-in for manufacturer
  selectivity tables, NOT a fabricated TCC. `estimatedMotorFaultA(FLA)` ≈ 6×-FLA
  sub-transient + `systemMotorFaultContributionA(sys)` (sum over motor/pump/HVAC
  circuits) fold into `faultStudy(..., estimatedMotorFaultContributionA:)` as a
  conservative origin-fault uplift — **default 0 ⇒ byte-identical**. `SelectivityResult`
  gains `zone` + `icuAdequate`/`icsAdequate` (IEC 60947-2, MCCB Ics≈0.75·Icu) /
  `icwAdequate` (busbar Icw vs the upstream bus fault). All device numbers are
  `secondarySource`/`notAnSniClause` `// VERIFY`, surfaced via `faultStudyVerifyItems`.
- **Electrical diversity library (`electrical/diversity_library.dart`)**: occupancy +
  load-kind demand factors (`DiversityLibrary` interface + `PuilDiversityLibrary`).
  `computePanel`/`computeSystem` take an optional `diversityLibrary`; when BOTH it and
  `ElectricalPanel.diversityLibraryId` are set, each circuit's `demandFactor` is
  overridden by occupancy + kind (**feeders never re-diversified** — they already carry
  the fed panel's diversified demand). Null id OR no library ⇒ the per-circuit factor as
  before ⇒ **byte-identical**. Every factor is `secondarySource` `// VERIFY` (IEC
  60364-1 / NEC 220 practice, not a PUIL clause), surfaced via `diversityLibraryVerifyItems`
  (added to `AdvancedStudy.verifyItems` only when a panel references the library).
- **Persistence**: design settings (occupancy, feed, ducts, rainfall, fire
  hazard, theme) round-trip via `DesignSettings` in the `.mechx` file; autosave
  only writes recovery when the work differs from the last clean Save
  (`lastSavedSignatureProvider`), so a saved project leaves no phantom recovery.
