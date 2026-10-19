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
   `ui/theme/design_tokens.dart` (8pt grid, one type scale, light/dark). The
   FLOATING CHROME is **Liquid Glass** (`ui/widgets/glass_surface.dart`
   `GlassSurface` + `MechXGlass`/`MechXColors.glassFill/glassSheen/glassEdge`):
   nav rail, top/status bars, inspector, sheet rail, electrical palette/toolbar
   are translucent backdrop-blur surfaces; **content** (cards, tables, reports)
   stays opaque for legibility. Apply glass to the navigation/control layer
   only, never to content.

## Build / test / verify

The dev container has the Flutter SDK but **no display and no Windows/Linux
desktop build deps**, so you can run tests and `flutter analyze` but CANNOT
`flutter run` or `flutter build`. Verify changes via the test + golden pipeline.

```bash
# Engine (pure Dart) — run FROM the engine package:
cd packages/mechx_engine && dart test          # ~1057 tests

# App (Flutter) — run FROM the repo root:
flutter test                                   # ~481 tests incl. golden screenshots
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
                                   elevations, MountingHeights, ceiling/fixture elevations),
                                   dxf_drawing.dart (parseDxf → DxfDrawing for the canvas background)
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
  report/sld_sheet.dart            discipline-neutral single-line DRAWING primitives
                                   (SldSheet/SldPrim/Line/Rect/Label/Circle/LegendEntry) —
                                   one geometry, rendered by PDF/DXF/canvas (golden rule 5)
  report/riser_tags.dart           pure riser FUNCTION-suffix + per-service tag + floorFanOuts
                                   (shared by the schematic painter AND the mech riser builder)
  report/mechanical_sld_drawing.dart buildMechanicalRiserSld → SldSheet (floors by §10
                                   elevation, SIZE-SERVICE-MATERIAL tags, fan-out, KETERANGAN)
  report/sld_export.dart           sldSheetToPdf/sldSheetToDxf — render ANY SldSheet to vector

lib/                               FLUTTER APP
  main.dart                        bootstrap: pdfrx init, autosave loop, recovery check,
                                   UncontrolledProviderScope
  app.dart                         MechXApp (WidgetsApp + MechXTheme)
  data/                            project_document.dart (versioned .mechx JSON),
                                   pdf_import.dart, dxf_import.dart, dwg_import.dart +
                                   dwg_converter.dart (ODA DWG→DXF), recovery.dart + autosave.dart
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

PDF import (pdfrx) **+ DXF import** (pure-engine `geometry/dxf_drawing.dart`
`parseDxf` → LINE/LWPOLYLINE/POLYLINE/CIRCLE/ARC + INSERT/BLOCKS expansion,
rendered by `ui/canvas/dxf_sheet_page.dart` as a calibratable background via
`Sheet.dxfPath`; a DISPLAY substrate only, length still from calibration)
**+ DWG import** (`data/dwg_converter.dart` `OdaDwgConverter` shells out to the
ODA File Converter for DWG→DXF, then the DXF pipeline; `Sheet.dwgPath` keeps the
source; binary resolution = `ODA_CONVERTER` env → bundled `{app}\oda\` →
auto-detected Program-Files ODA install (`systemOdaCandidates`) → PATH, so a
normal ODA MSI install is found with zero config; the bundled copy is fetched at
release-build time via `release.yml` from an `ODA_ZIP_URL` secret / `vendor-oda`
repo release asset, absent ⇒ no-op)
+ multi-sheet rail; per-sheet scale calibration; per-floor
heights + role-aware elevations (a **ground-relative datum** — `BuildingLevels.groundIndex`:
ground reads 0.0, **BASEMENTS negative**, upper floors positive; a constant offset that leaves
every elevation DELTA / riser length unchanged, default `groundIndex == 0` ⇒ byte-identical.
Basements are added on the Building page's ONE consolidated add control — `N levels @ H m` with
**Add on top** / **Add basement** — via `ProjectController.addBasement`/`addFloorsOnTop`, which
shift the datum + drawn nodes in one structural undo step; `groundIndex` round-trips additively in
`.mechx`); draw runs/risers for 10 services (cold/hot
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
a per-sheet calibrated/uncalibrated dot; the current sheet's state is stated ONCE — the Layout
breadcrumb's tappable ' · Not calibrated' / ' · 1 : N' tail, the status bar only on Riser/Electrical);
**project templates / smart defaults** (`store/templates.dart` `kBuildingTemplates` —
Residential highrise / Office tower / Hospital / Retail shop, each prefilling floors +
occupancy + fire hazard + design rainfall; a **'New from template'** dialog (Projects page: a quiet 'Apply building template...' button in
the Project card) applies them via `ProjectController.setFloors` + the occupancy/fire/rainfall provider
`.set()` methods — additive, no `.mechx` change);
**unified Design Issues review panel** (`store/design_issues_store.dart`
`designIssuesProvider` — a read-only fan-in that aggregates every existing design warning
into one typed `DesignIssue` list: out-of-band air velocities + unsized air elements
[`airVelocityChecksProvider`/`airUnsizedProvider`], uncalibrated sheets, unverified
`// VERIFY` standards [`SniProfile`/`SniVentilationProfile`/`PuilProfile.verifyChecklist`], and
**network connectivity** — component-level no-source/island [`network/connectivity.dart`
`networkConnectivityDefects`] PLUS per-element **unconnected** checks: a loose run/duct END
(a degree-1 bare-`main` junction that isn't a fixture / terminal / plant / another run) and an
ORPHAN (a node placed but joined to nothing, incl. unplaced equipment) via `networkElementDefects`,
and an **unfed electrical panel** via `electrical/connectivity.dart` `electricalConnectivityDefects`
(all read-only, never resize; each a warning with a stable per-element `kind` + locate) —
each with a severity + an optional `IssueLocation(sheetId, {nodeId, edgeId})` (or `panelId`);
surfaced as an `IssuesCard` in the Review hub grouped Warnings/Advisory with a count, a locatable
row jumping to the element via sheet + selection + `WorkspaceView.plan`);
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
**Standard desktop accelerators + the F1 shortcuts sheet** (`ui/shell/shell_shortcuts.dart` —
a PURE, unit-tested accelerator TABLE: `matchShellShortcut(key, {mod, shift, alt})` → a
`ShellCommand`, with `app_shell.dart`'s pre-focus `HardwareKeyboard` handler reduced to a dispatch
`switch` that runs the SAME entry points the top bar / nav rail / palette use, so an accelerator
can never diverge from its clicked equivalent). Bindings: **Ctrl/Cmd+N** new · **O** open ·
**S** / **Shift+S** save / save-as · **I** import plan · **P** export the annotated plan PDF
(the app's "print", `runExportGuarded`) · **E** the ONE Export sheet · **Z** / **Y** / **Shift+Z** undo/redo on the ONE
`historyProvider` timeline (now global, so undo works on the hub screens where nothing holds
focus) · **K** / **Shift+P** command palette · **1..8** (+ numpad) the nav-rail destinations,
DESTINATION-bound [1 Layout · 2 Riser · 3 Electrical · 4 Building · 5 Review · 6 Commercial ·
7 Projects · 8 Preferences — kept when the rail was regrouped 2026-10-17; the F1 sheet lists the
'Go to' rows in rail order, each with its own keycap] · **,** Preferences · bare **F1** the shortcuts sheet. Two rules are part of the
table: **Alt NEVER matches** (Windows AltGr reports as Ctrl+Alt — swallowing it would eat real
characters on an ID/EU layout) and `ShellCommand.deferToTextField` marks undo/redo as combos a
focused field owns (the shell stands down via the shared `isTextEntryFocused()` so
`DefaultTextEditingShortcuts` edits the FIELD). Deliberately NOT claimed globally: the canvas
zoom family (Ctrl +/-/0), the selection combos (Ctrl+A/C/V, Delete) and Esc — they stay with the
focused canvas — and Ctrl+Q (not a Windows quit convention; Alt+F4 / the close button already
route through `_ExitGuard`). `ui/shell/shortcuts_sheet.dart` `ShortcutsSheetOverlay` is the F1
cheat sheet (gated on `shortcutsSheetOpenProvider`, renders nothing when closed ⇒ goldens
byte-identical): the global bindings beside the CANVAS ones (tools V/R/E/M/K/B, ortho O, service
1-9, Shift+R/M, hold-Space pan, F fit…), so the whole keyboard is learnable in one place; Esc
closes it pre-focus (it has no text field, so the bubble listener never sees the key on a hub
screen) and opening either overlay closes the other. The palette carries matching keycaps + a
'Keyboard shortcuts' command.
**Trimmed top bar (2026-10-17)**: title/dirty dot/file name, `Ctrl K` hint, Open, Save, Export only —
the zoom % lives in the Layout `ZoomControls` (tap = eased reset to 100% via `CanvasViewState.zoomTo`),
Import plan is the sheet rail's trailing '+' tile (+ Ctrl+I / palette / empty state), and theme
switching is Preferences + the palette `theme.toggle`.
**ONE Export sheet (Ctrl/Cmd+E, 2026-10-17)** (`ui/shell/export_sheet.dart` over the transient
`exportSheetProvider`, closed ⇒ renders nothing): identity bar + the primary submittal package +
counted Drawings/Reports/Data/Electrical/Commercial groups, every row an existing guarded
`exportXxx(ref)`. Opened from the top-bar 'Export', Ctrl+E, the palette, Review/Projects 'All
exports...' and the Riser/Electrical toolbar Export buttons (which pre-expand their group) — the
per-page export menus/button walls are gone.
**Inspector clarity — collapsible sections + promoted headline results** (`ui/inspector/
disclosure_header.dart` + `result_card.dart` + `store/inspector_store.dart`
`sectionVisibilityProvider`): the dense `ProjectPanel`'s major sections (Draw / Tanks / Rooms /
Results / Fire / HVAC — the sheet→floor control was dropped as redundant with the sheet rail, and
the design INPUTS [occupancy/rainfall/runoff + the water FEED STRATEGY (2026-10-17; the Layout/Riser inspectors show only a read-only `FeedStrategyLine` with a Change link, palette: Switch feed strategy)] moved to the Building setup page, leaving only the
Show/Hide-sizes canvas toggle atop Results; since 2026-10-17 the panel is LAYER-SCOPED — after the fixed Selection/Building/Scale/Draw head only the active discipline's sections show [Plumbing: Tanks+Results · Fire: Fire · HVAC: Rooms+HVAC], and Document control sign-off/revisions + the equipment model/spec editor moved to the Projects page's Document control card [`ui/shell/document_control_card.dart`, palette: Edit document control / Edit equipment specs]) are wrapped in a reusable `DisclosureSection` — a tappable
header (replacing the section's `MechXSectionLabel`) with a custom-painted chevron that discloses
its body only when expanded. Expansion is TRANSIENT UI state in `sectionVisibilityProvider` (a
`Map<String,bool>` keyed by section name, read via the memoized `sectionExpandedProvider` family) —
NOT persisted to `.mechx`, so reopening a project restarts from the per-section defaults
(content-bearing sections default expanded; Tanks/Rooms keep their empty-state shrink). The 1–2
headline results per sizing section are promoted to a bold `ResultCard` with a colour-coded
success/warning/danger verdict (Network: pump motor kW, or PRV-zones worst-kPa OK/over; HVAC: fan
static + motor), demoting the supporting key/value rows beneath; each card renders only when its
result exists, so a blank launch is byte-identical (goldens shift only by the small chevron glyph).

**Audit round 8 (2026-10-18) — fire/HVAC, advanced electrical, costing, MEP coupling**: judge-only sprinkler-vs-fire-pump Review warnings (`sprinkler-flow-exceeds-fire-pump` / `sprinkler-head-exceeds-fire-pump` via `sprinklerPumpCheckProvider`), the AC-load basis relabelled 'Internal gains (no envelope)' + a `cooling-internal-gains-only` advisory, life-safety electrical checks (`life-safety-cable`, `life-safety-not-essential`), the drawn plant node and its solved duty bound to ONE electrical way (`mepDutyBindingProvider`), material/W×H-aware mechanical price keys + `elec:` price keys for every electrical BOM line, and a locale-aware money input (`ui/commercial/money_input.dart` `parseMoneyInput`). See the §15 row for the full list + recorded residuals.

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

- **Workflow-friction review (2026-07-30) — `WORKFLOW-FRICTION-REVIEW.md` (root),
  a post-campaign review of HOW THE WORK IS DONE — is COMPLETE: all four waves
  LANDED 2026-07-31** (three ultracode batches, 11 agents + orchestrator seams —
  see the §15 rows and the doc's status note). Four parallel lenses (first-project
  walkthrough / daily grind / mistakes+the same-day audit surfaces /
  goldens-as-images + cross-workspace), 69 raw findings adversarially verified to
  **56 confirmed / 13 adjusted / 0 refuted**, 10 themes (A–J), all fixed or
  dispositioned. Headlines now IN the product: Review Locate is a real navigation
  primitive (section + centring + layer/visibility/lock restore + tagged instance
  links + clickable compliance rows); the riser cross-surface contract holds (far
  node on the destination floor's sheet, diagram-only elevation drags,
  stable-identity riser/equipment tags); the two data-destroyers are gone
  (`syncMepEquipment` parks + narrates + re-adopts; floor delete confirms with a
  count and takes its drawn work in one structural undo step); the six
  drainage-fall sites read the real slope; calibration/typing/stepper honesty;
  MountingHeights + fixture typing are first-class inputs; one remembered export
  folder + the complete submittal set; sticky electrical canvas + summary +
  legend + shared minimap; heatmap corridor mask; per-layer service memory;
  paste-to-floors. Residuals/dispositions are in the doc's status note.

- **Whole-product audit (2026-07-30) — `MODULE-AUDIT-REVIEW.md` (root) is the CURRENT
  plan of record**: a four-workstream parallel audit (every mechanical engine module
  probe-confirmed read-only; reports/exports/persistence; the 16-artifact export
  harness + rasterized-sheet eyeballing; a complete 3-storey/7-board/38-way electrical
  design driven through the public engine API and committed as
  `packages/mechx_engine/test/whole_building_electrical_design_test.dart`, 52 tests
  with 8 findings pinned as documentation tests). 38 consolidated findings in 4 themes,
  sequenced into waves A (wrong verdicts + lost sizing flags: PRV zoner datum mismatch,
  equal-friction velocity cap, upfeed PASS-by-construction, N−1 return grilles…),
  B (the issued electrical deliverable: per-circuit kA tokens, containment one-source,
  reports on the combined warning surface, BOM CSV material/override columns, the
  selectivity floor's cable-inflation trade-off, fire-pump protection), C (platform
  integrity: undo-cap phantom entries, un-awaited autosave write…), D (dead-feature
  policy: operating point / detailed cooling / multi-zone / dark thresholds — wire or
  remove). The bundled sample's fire-pump ADS defect is already FIXED (6 mm² pin +
  `test/sample_project_health_test.dart` guarding zero error-severity findings).
  **ALL FOUR WAVES HAVE SINCE LANDED the same day** (two ultracode batches — see the
  two §15 rows and the doc's status note): zones compliant by construction, equal
  friction velocity-capped, upfeed verdicts 'held by design', all N return grilles
  placed, per-circuit kA + containment-sourced conduit tokens + real core counts on
  the schedule, reports on the combined warning surface, the BOM CSV on the engine
  takeoff format, phantom undo drop-and-retry, autosave awaited, the E3/E4 floor
  redesigned device-only + ampacity-capped (see the Sizing-engine invariant), and
  wave-D wired real (drainage slope / HW temps / AC-load basis as Building-page
  design inputs; dead multi-zone settings dropped). Residuals are in the doc's
  status note; the operating-point module is fixed but deliberately still unwired.

- **Design-craft campaign (2026-07-27) — LANDED** (`DESIGN-CRAFT-REVIEW.md`, root): a
  design-skills pass over EVERY page (incl. fresh captures of the never-golden-covered Building
  + Preferences via the committed `test/design_captures_test.dart` → `test/goldens_design/`,
  tagged golden+sim). Cross-cutting: `MechXMotion.resolve(context, duration)` — the
  REDUCED-MOTION gate every animated duration must pass through (OS `disableAnimations` ⇒
  `Duration.zero`; `AnimatedSize` must branch on zero instead — framework assert, documented on
  the helper), and `MechXTypography.tabular(style)` — layout-stable `tnum` figures for ANY
  number that updates while visible (adopted across inspector readouts, stat tiles, schedules,
  steppers). DisclosureSection bodies now EASE (AnimatedSize, `fast`) instead of snapping; the
  status pill fades/settles in. Per-page: inspector values never truncate mid-number (the value
  wins the row; BOM leaders shorten instead), the Riser inspector gained the data-gated
  `RiserSystemSummary` card (services/risers/tags/Σ riser length — a projection, no new
  physics) + legible floor labels, the electrical canvas fits-to-content on first open
  (LOD-honest extents; any explicit transform forfeits the one-shot), Review's stat tiles are
  one consistent grid, Commercial's `line(s)` dev-speak died (pre-pluralized `pluralCount`
  phrases, EN+ID), Building's add-level control is a labelled form with ≥40px hit targets, and
  Preferences converged on ONE `MechXSegment` radio idiom (Dark/Light · EN/ID ·
  Anthropic/OpenAI/GLM) under two section labels. Motion frequency-gate rejections are recorded
  in the review doc (command palette, tool switching, zoom, drag stay unanimated). Test-harness
  rule learned: seeding/toggling now animates section sizes, so widget tests settle before
  tapping inspector content and the golden harness settles 200ms past the seed.

- **Workflow + goldens two-lens review + export-readiness audit (2026-07-06) — the CURRENT plan
  of record (7 waves: the original 6 + the additional export-ready Wave 7)**:
  `WORKFLOW-GOLDENS-REVIEW.md` (root) is a fresh,
  adversarially-verified review of the v1.12.0 workflow and the 16 golden screenshots from two
  POVs — a senior Apple UI/software engineer and a senior Indonesian MEP drafter/engineer — run
  AFTER the three prior campaigns (UX-workflow, CAD-output, Apple-design) fully landed, then
  **extended the same day on the product owner's direction: the EXPORTS are the product**
  (a mandor/foreman and site engineers must build from the issued set directly — no AutoCAD
  redraw, no Excel supplement). **106 verified findings** (33 high / 59 medium / 14 low) in
  **14 themes (A–N)**: 81 from the two-lens review (70 raw → 67 merged → **0 refuted** by an
  independent adversarial pass, + 13 from a completeness critic + 1 orchestrator-verified) plus
  **Theme N — a 25-finding export-readiness audit** in which a committed dev tool
  (`packages/mechx_engine/tool/generate_export_samples.dart`, the campaign's acceptance harness)
  generated the REAL 13-artifact export set from a representative 3-storey fixture, the PDFs were
  rasterized, and four site-lens critics (foreman, mechanical site engineer, electrical
  kontraktor, document controller) reviewed the actual sheets. Headline Theme-N proof: every
  vector PDF garbles the engine's own `·` separator to `?` INSIDE cable-spec/starter cells (the
  DXF of the same set is correct — the two formats contradict); socket RCDs print in the calc
  report but NOT on the board schedule a panel is built from; no sheet anywhere carries cable
  lengths (though length drives the printed Vdrop), per-device kA, mounting heights, or
  setting-out ties; a drainage stack can auto-size SMALLER than its branches (DN65 stack / DN75
  branch — no stack≥branch clamp in `_sizeSanitaryEdge`); ONE global `documentNumber` stamps
  every exported sheet; the mech riser DXF writes plumbing onto E-BREAKER/E-TEXT layers; the
  riser PDF titles itself "Untitled project". Sequenced into **seven waves — the ORIGINAL six
  unchanged** (W1 stop-the-lies/visible defects [clipped goldens 09/10/11, "read-only" Auto mode
  committing an edge, the phantom mid-draw node, zone-check→compliance, unstable tags] → W2 feel
  [the every-drag-frame full re-solve, keyboard reach, Windows basics: .mechx association, window
  state, min-size] → W3 trust surface [heatmap probe/scale, velocity display, audited acks,
  stale-calibration prompt, all-sheets submittal, RCD/kA/CT visibility] → W4 deliverable fidelity
  [equipment tags, HW-recirc + drainage/vent riser fidelity + STP terminus, valve trains, slope,
  one air-colour language, plan-accurate electrical export] → W5 velocity/parity [layer lock,
  rotate/mirror, repeat-place, shared plan, multi-select parity] → W6 structure/polish + the one
  deferred item: spatial clash checking) **plus the ADDITIONAL Wave 7 — export-ready
  deliverables**: all 25 Theme-N findings as one campaign, additive to and schedulable
  independently of Waves 1–6 (including first), with the dev tool as its acceptance harness
  (regenerate the 13 artifacts + re-read the sheets after each batch). Three territories NO prior
  campaign covered: performance-feel, keyboard-only/accessibility, Windows-desktop citizenship.
  **Wave 1 (stop-the-lies / visible defects) HAS LANDED** (2026-07-06, see the §15 row): all 19
  items — riser corner reserved for the (?) button (goldens 09/10 unclipped), fit-width board
  schedule + the un-clipped toolbar issues pill (golden 11), honest Auto-mode commit hint + Edit
  drop preview/redirect toast, ghosted inert edges, one `FFL +X.XX` notation (shared engine
  `fflLabel`), data-gated valve detail boxes, phantom mid-draw node cancelled on sheet switch,
  duct badge dodges the size chip, dropped-label tick mark, duplicate-floor keeps loose
  equipment, template-cancel status toast, 'Building' naming converged, stepper Floors no longer
  ticked by drawing alone, corrected power-one-line empty state, electrical-layer guide line,
  PRV zone-over-limit → compliance verdict, fire verdicts localized, stable equipment tags,
  keyboard-reachable Review actions. Goldens 01–15 regenerated; engine 1263 / app 842 / analyze
  clean. **Wave 7 (export-ready deliverables — all 25 Theme-N findings) HAS ALSO LANDED**
  (2026-07-06, see the §15 row): the PDFs now render the real `·`/`Ø` glyphs via WinAnsi (0 `?`
  bytes, PDF==DXF), the board schedule carries LENGTH + per-device kA (3-tier fallback) + RCD +
  CT-ratio tokens and MCCBs drop the curve letter, riser tags carry lengths and grouped fixture
  counts, plan labels carry CL elevations + gridline bubbles/tie dimensions, drainage stacks
  clamp ≥ their largest branch (`stackRaisedForBranch`), the BOM gained material/tag + honest
  duct-size columns (CSV headers changed: `nominal_size_mm`+`material`), the calc report gained
  a per-run sizing-basis schedule + governed standards wording, the equipment schedule gained
  TX/genset/capacitor rows + an editable Model/spec map (`DesignSettings.equipmentModelSpecs`),
  every export stamps a distinct per-sheet DWG number (pure `DrawingSeries`), every PDF sheet
  renders ONE tabular title block with the DRAWN/CHECKED/APPROVED sign-off trio + SHEET i-of-N,
  the mech riser DXF uses M-* layers, and a bilingual cover + Daftar Gambar generator leads the
  submittal set. Acceptance harness: the 13 artifacts regenerate + 25/25 on-paper verdicts PASS.
  Gate: engine 1341 / app 844 / analyze clean; only electrical goldens 05/08/10/11 shifted.
  Residuals recorded: panel/apparatus Model-spec hooks, the 190 pt title-cell width.
  **Wave 2 batch 1 (the user-reported B10/B11/B12 drafting-feel fixes + N4 app wiring) HAS ALSO
  LANDED** (2026-07-06, see the §15 row): the outlet nub survives a full pull (B11), ortho 45°
  applies to endpoint-resize + degree-1 node drags (B10), and the plan underlay is a snap
  surface (B12) — DXF vector snapping (pure grid-bucketed index over the cached `DxfDrawing`),
  two-click traced reference lines (additive `.mechx`, exported as N4 gridline bubbles when
  axis-aligned + labelled), and PDF raster snap-to-ink (pure `findInkSnap` over an async LRU
  luminance cache) — one candidate path at every snap gesture with precedence node > vector >
  reference line > ink > grid, gated by a default-ON 'Snap to plan' toggle beside Ortho.
  Gate: engine 1341 / app 899 / analyze clean; goldens 01/02/03 shifted (new DRAW chip+toggle).
  Residual: the legacy `sheet_canvas.dart` host lacks only the trace-tool overlay.
  **Snap-to-plan now HIGHLIGHTS the feature it's snapping to (user-reported) HAS ALSO LANDED**
  (2026-07-08, see the §15 row): the underlay snap carries its SOURCE geometry —
  `UnderlaySnapCandidate.segment`/`segment2` (the wall/line, plus the 2nd crossing wall at an
  intersection) → `UnderlaySnapHit.segments` → `_EndSnap.segments` — and the draw rubber-band
  (`RubberBandPainter.snapSegmentsScreen`) paints that wall/line in the service accent (like the
  B25 parallel-reference highlight) UNDER the OSNAP marker, so while drawing you see WHICH plan
  part is being latched (a PDF-ink ridge carries no segment ⇒ marker only). Gesture-time only
  (mounted during an active DrawRun hover) ⇒ goldens byte-identical. Gate: engine 1377 / app 1106
  / analyze clean.
  **Drafting-feel batch 2 (user-reported B13–B16) HAS ALSO LANDED** (2026-07-07, see the §15
  row): the CAD auto-elbow (off-ray snap targets reached as two exact 45° legs via a bend
  junction, at draw/nub/resize commit, L-shaped live preview, one undo step), the pull grip
  centred ON the endpoint with a concentric pull/move hit contract + full tap parity, the
  riser marker as the drafting-standard circle-with-chevrons (canvas + plan exports, one
  convention), and true-diameter zoom rendering (glyphs/halos size off the widest incident
  pipe via `glyphRadiusPx`; unsized byte-identical). Gate: engine 1371 / app 1025; goldens
  01/02/03 re-captured. **Drafting-feel batch 3 (B17–B30) HAS ALSO LANDED** (2026-07-07, see the §15 row):
  two-click ortho routing with Tab leg-flip (`orthoRoute`/`commitRoute`, composes with the
  auto-elbow), trim/extend to intersection, corner-join (+ the loose-end issue's 'Fix corner'
  action), segment grip-drag, dimension-driven length editing, the cursor polar chip, the live
  gravity invert readout, draw auto-pan, smart alignment guides, the OSNAP `SnapKind` marker
  vocabulary + midpoint/perpendicular-foot candidates, Alt parallel-offset lock, the
  window/crossing marquee, the match-properties brush (atomic `setEdgeProperties` after a
  review-caught undo fix), and hover measurement chips. All gesture-time only — goldens
  byte-identical. Gate: engine 1371 / app 1093 / analyze clean.
  **Drafting-feel follow-up — a free run endpoint's grip STRETCHES (extend/trim), doesn't pull
  (user-reported) HAS ALSO LANDED** (2026-07-08, see the §15 row): a bare `main` node at the
  loose END of a run used to mount the concentric outlet nub (B14), so grabbing the point and
  dragging pulled a NEW mainline out instead of moving the endpoint. Now `_isFreeRunEndpoint`
  (a component-free `main` with exactly one incident edge, a `run`) flips that grip's drag to
  MOVE the node — extend/trim, reusing the single-node move path (degree-1 ortho vs the sole
  neighbour, `endNodeDragWithSnap` merge/grid/underlay on release); tap-select / double-click /
  right-click unchanged, cursor becomes `move`. Risers, junctions (degree ≥ 2), lone dropped
  fittings (degree 0, the bootstrap pull point) and plant/valve nodes keep the pull nub; branch
  a real loose end via the Run tool's tee-in. Gate: engine 1371 / app 1096 / analyze clean;
  goldens byte-identical (the grip mounts only on hover/selection).
  **The Wave 2 remainder HAS ALSO LANDED** (2026-07-06, see the §15 row): K1 drag-session
  throttle (no heavy re-solve per drag frame; at-rest byte-identical), K3 heatmap field
  memoization, K2 isolate-offloaded Open, K4 threshold-gated isolate autosave encode with a
  TOCTOU-safe tick, L1 Loads-palette keyboard path, L3 focus-ring sweep, L5+M4 one custom
  tooltip mechanism on icon-only chrome, C2 every-selection auto-scroll, D9 converged reveal
  zoom, B5 width-scaled hit corridors, B6 nub/handle hit separation, M2 `.mechx` association +
  CLI open, M3 Windows window-placement persistence (Windows-CI-verified). Gate: engine 1341 /
  app 927 / analyze clean; goldens byte-identical. **Wave 3 (the trust surface) HAS ALSO LANDED
  IN FULL** (2026-07-06, see the two §15 rows): the heatmap became an instrument — an SNI-target
  tick + 'Min NN kPa' on the legend gradient and a per-node 'Residual NN kPa' PASS/LOW probe in
  the node inspector (I2), with the uniform-field state rendering a calm neutral tint + an
  honest 'Uniform NN kPa · PASS/LOW' verdict (E4, golden 03 re-captured); live water/drainage
  velocity verdicts in the edge inspector via `waterVelocityChecksProvider` reusing the engine
  `checkVelocityBand` against `SniProfile` caps (I3); auditable acknowledgements —
  `IssueAck{key,author,note,date}` persisted additively (legacy bare-string acks load
  tolerantly), an initials+reason inline form on Acknowledge, and 'Acknowledged: … — author,
  date: note' rows in the report's compliance section (I4); a revision-tag vs revision-history
  advisory (I6); manual-override '*' marks + footnote in the BOM CSV/report (I5, default
  byte-identical); H2/H3/H4 verified closed by Wave-7's N10/N9/N11 (the live canvas paints the
  same engine schedule) plus a read-only RCD/kA line in the circuit editor; and the 3-phase
  phase-imbalance % on the schedule TOTAL footer (H7, hand-derived test). The review pass
  caught + fixed a kPa-vs-Pa tolerance mismatch between legend and probe. Gate: engine 1348 /
  app 954 / analyze clean; goldens 03/05/11 re-captured + visually verified. J1/J2 detail:
  replacing a sheet's plan mid-project
  (`SheetsController.replaceSheetSource`, "Replace plan…") now flags its surviving calibration
  STALE (additive `ProjectState.staleCalibrations`, tolerant `.mechx`, no version bump) —
  surfaced as a distinct locatable Design Issue ('Plan replaced — re-verify scale', EN+ID), a
  warning-state sheet-rail dot, and a Scale-inspector **'Scale confirmed'** button
  (`ProjectController.confirmCalibration`) that clears it without re-measuring; re-calibrating
  (or `applyCalibrationToAllSheets`) clears it too. The one-folder submittal package's plan/DXF
  export now loops EVERY sheet in the rail (was: `sheets.current` only) via a new testable
  `writeSubmittalPackageToDir`, each sheet keeping its own N19 drawing number + a disambiguated
  filename, with the Daftar Gambar front matter listing one row per bundled sheet and progress on
  the shared busy pill. **Wave 4 (deliverable fidelity) HAS ALSO LANDED** (2026-07-06, see the
  §15 row): one pure `equipmentNodeTags` source prints P-01/TK-01/AHU-01 beside equipment on
  canvas + all plan exports (G1, review-caught app-wiring fix included); a data-gated HW-recirc
  return leg with HWR tags + recirc pump on the riser (G2); real suction/discharge valve trains
  in the pump-set detail (G3); floor-drain/VTR reference details + an honestly-generic drainage
  terminus (G4); real design-slope '1:100' + fall arrows on gravity runs (G5); an on-canvas
  service-colour legend chip (E5); ONE service-colour source with a PDF↔DXF parity test (E2);
  the plan-accurate ELECTRICAL LAYOUT export (`electrical_plan_drawing.dart`, E-1xx, honest
  unplaced note — artifact 14 of the dev-tool harness) wired into Export + the submittal set
  (H1); size-matched conduit tokens (H6); a starter picker in the circuit editor (C5); and the
  two Wave-7 residuals closed (TX/genset/cap-bank Model-spec hooks; the auto-fitting title
  cell). Gate: engine 1371 / app 957 / analyze clean; goldens 01/02/03/09/10_single_line
  re-captured; harness 16 artifacts, all verdicts PASS. **Wave 5 (velocity + parity) HAS ALSO
  LANDED** (2026-07-06, see the §15 row): per-discipline layer LOCK excluded from every hit
  path (F1), per-service view isolate chips inside multi-service layers (F4, view-only),
  click-to-place-repeatedly armed palette mode (F5), one-undo duplicate-floor-to-range (F3),
  rotate/mirror selection transforms with exact 45° preservation + Shift+R/Shift+M bindings
  (F2), 'Use plan on another floor…' shared-source sheets (F6, dedupe-verified), the FINISHED
  inline-inspector convergence — no more drawer overlays anywhere electrical (C1), electrical
  marquee/multi-select/nudge (D2), riser-edit multi-select + batch move (D5), and honestly
  disabled palettes on read-only tabs (D6). The review caught + fixed a marquee edge-capture
  gap in the inert-service filter. Gate: engine 1371 / app 997 / analyze clean; goldens
  01/02/03/06/10_electrical_riser re-captured. **Wave 6 (structure & polish) HAS ALSO LANDED** (2026-07-06, see the §15
  row) — 'Load sample project' on the Layout empty state (A1), the ranked export surface +
  primary-accent correction on the Projects hub (A5/A6), the Draw section default-collapsing
  once a network exists (C3), the Rooms editor's identity-first ResultCards (C4), honest
  percent/ratio fields that reject instead of clamp (C6), minimap chrome (B7), the Riser rail
  hidden + chrome converged (D4/D8), a native 1024×700 minimum window + reflow test (M1), the
  Semantics sweep (L4), and the cold-water cobalt split from the selection accent through the
  one colour source (E3). **THE WORKFLOW-GOLDENS-REVIEW CAMPAIGN IS COMPLETE: all 7 waves
  landed — 108 of its 109 findings (106 + the 3 user-reported B10/B11/B12) shipped or
  explicitly dispositioned; the sole deferred item is J5 spatial clash checking.** Final
  gate: engine 1371 / app 1015 / analyze clean; goldens re-captured throughout; the
  16-artifact export harness green.
- **Apple-design review (2026-07-04) — the prior plan of record for ease-of-use/UX polish (fully landed)**:
  `APPLE-DESIGN-REVIEW.md` (root) is a fresh senior-Apple-UI-designer review run AFTER the 83-finding
  UX-workflow review shipped (v1.10.0) — its premise is that the infrastructure is mature and the
  remaining gap is *consistency + restraint of application* and *orientation between steps*. 8 themes
  (A orientation · B one-vocabulary · C one-app · D findable-power · E calmer-inspector · F visual-
  restraint · G canvas-frame · H speak-clearly), every finding file:line-grounded, sequenced into 5
  implementation waves. **Waves 1 + 2 HAVE LANDED** (see the two §15 rows). **Wave 1 (Themes A + D —
  orientation & discoverability):** a one-time first-run orientation card, an honest workflow stepper
  (Floors no longer pre-ticks the default seed), the template card routes into Import, a first-draw
  hint, import navigates to the plan, one "Building" name, honest "Floor N of M", a "Ctrl K" palette
  affordance + palette keycaps. **Wave 2 (Theme B one-vocabulary + Theme H copy H2–H5/H7):** one noun
  for a drawn edge ("run"), "sheet" vs "plan", matched abbreviations (BOM/calc), scoped "Issues"
  counts; a pure `plural`/`pluralCount` helper (`ui/strings/plural.dart`) kills the "(s)" dev-speak,
  "Tap again to discard", a localized auto-sized toast + torn-recovery message, and specific
  "Unverified: <value>" titles behind a stable `DesignIssue.isVerify` discriminator. Every fix is
  additive / guardrail-safe (custom design system, offline, byte-identical-when-idle, opaque content,
  ASCII+Roboto on canvas) and touches UI/app-shell/strings only. **Wave 3 (Themes E + F — calmer
  inspector + visual restraint) HAS ALSO LANDED** (see the §15 row): data-gated result sections
  (Fire no longer shows a phantom fire-pump duty), identity-first node/edge/electrical editors with
  expert params under disclosures, honest section names (Sizing→"Design inputs", Network→"Results"),
  the size ladder collapsed to a `SteppedValueField`; one tinted selected-segment idiom across the
  draw tools, content cards that RAISE (`surface`), AA-legible headings (`textSecondary`), a top-bar
  primary anchor (Save accent when dirty + a demoted theme icon), and motion literals routed through
  `MechXMotion`. **Wave 4 (Theme G — the canvas frame) HAS ALSO LANDED** (see the §15 row): a reusable
  minimap on the Layout canvas (top-right; the Riser minimap deferred — its viewport model differs), a
  MAGNETIC calibrated grid (grid-intersection snapping as the lowest-precedence snap, ortho-gated,
  wired at the draw/nub-pull/drag sites, the typed-exact-length path excluded), an inspector-collapsed
  on-canvas tool cluster, eased programmatic viewport changes, and left-drag-a-run-to-move-it.
  **Wave 5a (H1 + H6 — localize the TRUST surface) HAS ALSO LANDED** (see the §15 row): the compliance
  verdict + category rows + detail messages, the whole Review hub + issues card, and every
  `DesignIssue` title/message now resolve through the i18n mechanism (123 new EN+ID keys), so the
  Bahasa sign-off surface renders in Indonesian; to keep acknowledgements + the compliance fan-in
  working across locales, `DesignIssue` gained a stable locale-independent `kind` discriminator (its
  ack `key` is `kind`-based, not the localized title, and the compliance store matches on `kind`, not
  English title substrings); H6 localized the Ask-Claude copilot + the half-localized "Load sample
  project" / "Apply a building template" (EN byte-identical ⇒ goldens hold). **Wave 5b (Theme-C
  consistency C2/C3/C5) HAS ALSO LANDED** (see the §15 row): one segment idiom (the forked
  `_LayerSegment` + Riser `_TabButton` → the canonical `MechXSegment` for radios, with independent
  toggles split to a distinct checkbox/eye idiom — the Riser toolbar no longer shows Auto+Details+Notes
  as identical "selected" pills), the shared `CanvasGuideButton` help everywhere incl. Riser Auto, and
  the Riser inspector converged onto `MechXSectionLabel` + the tinted selected-segment idiom. **The
  final tier-5 item — C1/C4, the electrical-shell restructure — HAS ALSO LANDED** (a dedicated
  follow-up after the campaign merged): the standalone electrical workspace (`WorkspaceView.electrical`)
  now renders through the SAME shared `_DesignWorkspace` scaffold as Layout/Riser (canvas-backdrop +
  `CollapsibleInspector`, no `SheetRail`); its editing was lifted from local `_editing`/`_panelEditing`
  to a transient `electricalInspectorTargetProvider` (sealed `ElectricalCircuitTarget`/`ElectricalPanelTarget`)
  so the floating 340-px drawer is replaced by a selection-first `_ElectricalWorkspaceInspectorColumn`
  (circuit/panel editor INLINE on top, else the Loads palette); the editors gained an `inline` mode with
  the Layout electrical LAYER keeping the drawer form (golden 06 byte-identical). **With this, EVERY
  finding of `APPLE-DESIGN-REVIEW.md` (all 8 themes A–H, C1–C5 included) is landed — nothing deferred.**
- **UX & workflow review (2026-07-02) — the plan of record for the prior UX/workflow work**:
  `UX-WORKFLOW-REVIEW.md` (root) holds 83 consolidated, adversarially code-verified findings
  (from 115 raw across 12 review lenses; 32 high / 42 medium / 9 low, two proven with widget
  tests) covering first-run honesty (demo sheets + the sample switchboard leak into real
  deliverables), data safety (non-atomic saves, the %TEMP% recovery slot, annotation/settings
  undo holes, text-field key bleed, 14 unguarded exports), drafting velocity (no tee-in, no
  batch edit, no group move, no tool hotkeys), workspace parity (riser/electrical keyboard +
  inspector gaps), and the last mile (compliance can never PASS, export scatter, electrical-only
  Commercial, the dead solved-duty MEP→E bridge). Sequenced into 5 waves (trust → safety net →
  velocity → parity → submittal/business). **ALL 5 WAVES HAVE LANDED** (see the five §15 rows):
  Wave 1 (trust & honesty — empty first launch, atomic saves, text-field key guard,
  focus-independent shell hotkeys, reactive compliance, export-guard routing), Wave 2 (the safety
  net — File→New, offline settings/MRU file, import add/replace + orphan prune, per-project
  recovery slots, annotation undo domain, structural undo atomicity, API key out of `.mechx`),
  Wave 3 (drafting velocity — Run-tool tee-in, drop-merge honesty, single-key tool/service
  shortcuts, batch property edit + group move + arrow nudge, paste cascade/array, duplicate-floor
  range, C7 nub gating, direct 1:N scale entry, idempotent auto-place, edge-editor parity, saved
  assemblies), Wave 4 (workspace parity — riser zoom/pan + keyboard + sticky state + label
  dedup, electrical Esc/tappable-issues/LOD-taps/`setPanelSystem`, first-class rooms/tanks +
  names, inspector reorder + honest empty states, riser-scoped inspector, honest zoom pill,
  `MechXScrollbar` everywhere, the fixed unplaced tray), and Wave 5 (submittal & business — the
  solved-duty MEP→E bridge wired + persisted, the copilot context/validation/reach, one M+E+P
  quotation with mechanical costing [H10], multi-file sheets + rail context menu + pdfrx
  thumbnails, window title + a11y semantics, reachable compliance PASS via advisory
  acknowledgements [errors still block], the submittal-package + document-control export surface,
  the Review nav badge, circuit-level electrical locate, and Review/Commercial/Projects hub
  golden coverage). **Every actionable finding of the 83 is shipped or explicitly dispositioned**
  — the one deferred item is **J7's Wave-1..5 EN-literal i18n tail** (the mechanism + major
  workspaces are already localized; the tail is EN-byte-identical mechanical churn, batched
  incrementally as a follow-up). It also corrected the record: six items the CAD review's banner
  claimed landed never shipped (H4, H7, I4, I2-half, J6, J8) — folded into this review's findings
  and now shipped.
- **CAD-output + UX review (2026-07-02) — the plan of record for output/UX parity**:
  `CAD-OUTPUT-UX-REVIEW.md` (root) holds 78 code-verified findings — professional-CAD
  gaps in the plan/riser/electrical exports + reports, and Apple-lens UI/workflow gaps —
  grouped into themes A–J and sequenced into 5 implementation waves. Work new
  output/UX improvements from that document rather than re-reviewing. **Wave 1
  (the 13 high-impact small fixes) LANDED** (see the §15 row): ruled board-schedule
  grid (C2), complete compliance roll-up incl. electrical errors (D2), Esc-exits-any-mode
  + right-click-ends-run (G1), on-canvas mode pill (G2), rubber-band live length + snap
  ring (G3), save-in-place + Ctrl+S/O + edited dot (F1, `ui/shell/project_io.dart`),
  empty-state actions (J1), selection-first inspector w/ auto-scroll (H1),
  discipline-scoped node fields (H3), fire hazard-class input (H5), honest Report stage
  via `reportExportedProvider` (J4), 'Riser'/'Building riser' naming (J5), ASCII `m3`/`O`
  notation on the riser canvas (B8). **Wave 2 (issuable-sheet credibility) LANDED**
  (see the §15 row): shared ISO title block/sheet frame + honest real-metre scale bar +
  AIA-style DXF layer/linetype/ACI tables in `drawing_chrome.dart`; plan exporters take
  `metersPerPixel` (mm-unit DXF w/ HEADER+TABLES, snapped `1 : N @ A3` or honest NTS,
  stroke bands + service dashes, rotated/collision-managed labels via `placeEdgeLabel`);
  `SldLine.layer/dashed` across all renderers; electrical DXF class layers (E-BUS…);
  `electricalSldToPdfPaginated` (one schedule per page) + `sldSheetsToPdf`;
  breaker kA notation (`breakerIcuKaByPanelId` from the fault study's `incomerKa`) +
  source-spine IEC earth mark; mech riser per-service layers/dashed vent/medium pipes +
  label collision w/ leaders; canvas linetypes + rotated/LOD labels + `flowFromId`
  chevrons; document control (`DesignSettings` + `document_control_store` + inspector
  section) feeding title blocks + report revision tables; riser 'Export all systems'
  set + electrical 'Panel schedules' exports. **Wave 3 (the two big CAD lifts + the
  electrical-parity track) LANDED** (see the §15 row): the floor-plan UNDERLAY prints
  beneath every plan export (`PlanUnderlay` vector/raster model + `lib/data/plan_underlay.dart`,
  null ⇒ byte-identical); `report/plan_symbols.dart` component glyphs + `UP`/`DN` riser
  tags + flow chevrons in all three plan exporters; the riser sheet reached canvas
  parity (glyphs, capacity suffixes, KETERANGAN notes, detail callouts via
  `buildLiveRiserSheet`) + drainage/vent conventions (CO/VTR/tee, data-gated, Indonesian
  sheet titles); ELECTRICAL UNDO on the global timeline (`UndoDomain.electrical`,
  `syncMepEquipment` exempt, drag = one step); the panel-properties drawer
  (double-click; `setPanelTag`/`setPanelHeadroom`); electrical warnings fan into
  Design Issues with a Review→Electrical jump (`electrical_focus_store`); unsaved-work
  guards (`isProjectDirty` + Save/Discard/Cancel dialog on Open/Import/quit) and a
  status-bar busy pill + off-thread portable save (`gatherSheetAssetsAsync`).
  **Wave 4 (the submittal package) LANDED** (see the §15 row): the four flagship
  reports refactored onto a sealed `RptBlock` model (`report/report_blocks.dart`,
  Markdown proven byte-identical via characterization hashes) with a paginating
  A4 typesetter (`report/report_pdf.dart` — cover, `Page X of Y` footer, AFM-width
  text wrap, ruled tables split across pages, embedded `SldSheet` figures) wired as
  PDF exports (Projects screen + Review deliverables card; the MEP PDF embeds the
  riser + electrical single-lines); Bahasa Indonesia report BODIES
  (`report/report_strings.dart`, EN default byte-identical, threaded from the app
  locale); equipment-schedule CSV sibling + the BOM CSV split into clean
  `-bom.csv`/`-fittings.csv` with per-floor grouping (`buildBom(groupByFloor:)`) and
  the cut-plan stock/bars/waste columns joined per (service,DN); calibration/first-size
  status handoffs + the Review-hub 'Export deliverables' card. **Wave 5 (structural
  consolidation) LANDED** (see the §15 row) — paper sizes A3/A2/A1 on the plan PDFs,
  one-drag-one-undo + node/canvas context menus + Space-pan + select-all + double-click-opens
  + hover halo + metre-snapped major/minor grid, `SteppedValueField` type-in steppers +
  Rooms/Tanks master-detail + the Fire ResultCard, electrical way selection +
  `duplicatePanel` + the last EN-only workspace localized + one honest LOD tier + a live
  minimap, riser Edit-mode symbols + ONE shared `riserLayoutPositions` for canvas/export,
  true-width ducts + real dimension style + `CW-R1` plan tags, the power one-line on the
  SldSheet pipeline, quotation number formatting, and a contextual two-tap recovery banner.
  **All 5 waves are complete** — every actionable finding of the 78 is landed or explicitly
  dispositioned; the one open item is the A8 full plan-exporters-onto-SldSheet unification,
  deliberately deferred (waves 2-3 landed its content per-exporter with byte-level pins,
  making consolidation high-risk/low-yield) along with an app-side A3/A2/A1 paper picker.
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
  (`ui/canvas/segment_palette.dart` [its equipment groups scope to the active layer;
  within plumbing the **Drains** group [roof/floor drain, cleanout] gates to the GRAVITY
  drainage-family service — drainage/vent/rainwater — and the mirrored **Water outlets**
  group [`NodeComponent.waterOutlet`, a clean-water tap/faucet marker with a readable
  faucet+drop glyph] gates to the PRESSURIZED water service — cold/hot] + `drop_overlay.dart`
  + `edge_context_menu.dart`)
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
  Loads palette (`Draggable<LoadKind>`; one card per load kind, a sticky `1ph`|`3ph`
  segment [`palettePhaseProvider`] picks the phase of the phase-variable kinds), outlet-drag-to-feeder, minimap, zoom controls,
  Single-line / Power one-line tabs + canvas toolbar; additive `ElectricalPanel.x/y`
  (no math change). The app shell is now PanelMaker's **248-px left navigation rail**
  (`ui/shell/nav_rail.dart`), grouped in workflow order (2026-10-17): SETUP (Projects ·
  Building) · DESIGN (Layout/Riser/Electrical, still driven by `workspaceViewProvider`) ·
  ISSUE (Review w/ badge · Commercial) · pinned Preferences (collapsed rail = same order,
  no labels), replacing the top-bar view switch (`ShellSection`).
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
  a **Plumbing · Fire · HVAC · Electrical** layer switcher + visibility toggles (the eye/lock/funnel reveal on hover/focus or when non-default; the legend chip rests collapsed) (PLUMBING is ONE
  unified layer — cold/hot water + drainage/vent + rainwater drawn together on one canvas, the
  elements separated by their `ServiceType` for the riser/sizing/reports downstream;
  `disciplineOf` maps all five plumbing services → `DisciplineLayer.plumbing`). The active layer edits
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
  Releases have continued through the same workflow — the **current published build
  is `v1.23.0`** (two user-reported fixes: the declared PLN daya
  [`supplyCapacityVa`] now SIZES the service-entrance incomer + busbar instead of
  only labelling the supply head — with the judge-only
  `service-capacity-below-demand` limiter warning and the multi-root /
  null-capacity honesty gates — and the board schedule's R/S/T phase band rebuilt
  as three EQUAL ruled cells with centred heads/figures/totals;
  `pubspec.yaml` now `1.23.0+29`), atop
  `v1.22.0` (the two 2026-07-30/31 campaigns in one release: the MODULE-AUDIT
  fix — all 38 findings, incl. the by-construction PRV zones, the device-only
  ampacity-capped selectivity floor, per-circuit kA / containment-sourced conduit /
  real core counts on the schedule, reports on the combined warning surface, and the
  wave-D design inputs — plus the WORKFLOW-FRICTION campaign — all 4 waves, incl.
  Locate-as-navigation, the park-don't-delete MEP sync, the riser cross-surface
  contract, stable tags, the real drainage fall on issued drawings, one remembered
  export folder + the complete submittal set, and the sticky electrical canvas;
  atop the v1.21.0/v1.20.0 usability + K4-hardening
  baselines and the prior) — the earlier `v1.19.0` shipped (the honest LV service: no fabricated TRAFO/MVMDP/LVMDP source spine
  on an undeclared low-voltage service, the VA connection-capacity field, and the
  judge-only `feeder-below-fed-demand` warning found by the whole-building simulation;
  atop the v1.18.0 supply-node baseline [the W7 editable SUPPLY node with source kind
  PLN/genset/solar + declared connection capacity, the BATTERY + SOLAR PV source-spine
  nodes, and the genset `backs NN% of load` coverage label] and the v1.17.0 electrical
  panel-design-workflow baseline [the five-wave drop/auto-size/connect/balance campaign
  W0–W5, the W6 in-place value ladders in the electrical right-click menus
  (Breaker/Cable/Phase/Family + panel System, engine-sourced rungs, '(set)'/Auto
  override idiom, both hosts converged onto the shared menu widgets), and the standard
  desktop accelerators + F1 shortcuts sheet]; `pubspec.yaml` is the version source of
  truth; each release = bump → merge to the default branch (`main`) →
  `release.yml` `workflow_dispatch` with `publish=true`). The prior `v1.16.0` shipped
  palette/inspector polish (the Draw palette's Drains group gated to the gravity
  drainage service, the clean-water OUTLET node, the removal of the redundant inspector
  SHEET→floor control, and the move of DESIGN INPUTS to the Building setup page) atop
  the v1.15.0 basements + drafting-feel baseline. The prior `v1.14.0` shipped the
  three drafting-feel batches (the user-reported B10–B16 fixes incl. the auto-elbow,
  on-endpoint grip, riser circle-arrows, true-diameter zoom rendering, and the B17–B30
  CAD-muscle-memory set) atop the v1.13.0 all-7-waves campaign baseline. The prior `v1.12.0` shipped the unconnected-element design checks
  (loose pipe/duct ends, orphans, unfed panels, surfaced as locatable Review warnings)
  plus a golden-review readability batch, atop the v1.11.0 Apple-design-review baseline.
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
  **Electrical SLD export → professional drafter output landed** (the electrical analogue of the
  mechanical single-line drafter pass): the PDF + DXF single-line exports no longer draw anonymous
  name-only boxes — every panel is a real distribution-board single-line. New pure (Flutter-free,
  unit-tested) `report/electrical_sld_drawing.dart` `buildElectricalSld` → an `SldSheet` of sealed
  primitives (`SldLine`/`SldRect`/`SldLabel`) + a device legend + supply note, the ONE geometry both
  formats render (so PDF and DXF agree). Each panel: a header (name [tag] + `Incomer <breaker> ·
  system · V · bus · demand`), a header/body divider, a two-line **busbar** with the **incomer
  breaker** on the divider, and **one ROW per outgoing way** — breaker (`MCB/MCCB <curve><rating>A/
  <poles>P`), cable (`<family> <cores>×<csa>`), load name, phase, `Ib …A`, `-> <sub-panel>` for a
  feeder, `VD!` when over-limit — with feeders routed orthogonally down a right-hand channel to the
  sub-panel they supply (panels stacked root-first, indented by feeder depth). `electrical_pdf_export.dart`
  stamps a page-fixed **title block** (project · ELECTRICAL SINGLE-LINE DIAGRAM · demand kW/kVA · the
  `DrawingChrome` drawing-number/revision/`Sheet i of t`) + **device legend (KETERANGAN)** — a
  single-line is schematic, so the north-arrow/scale-bar chrome is dropped; `electrical_dxf_export.dart`
  renders the same primitives (`panels`/`feeders`/`frame` layers) + a model-space title block + legend
  (`powerOneLineToDxf` untouched). Shared `breakerLabel`/`cableLabel` format the notation. Engine-only;
  the app export wiring + signatures are unchanged (no `.mechx`/app-state change).
  **Zoomed-out building single-line landed** (the whole distribution hierarchy on one sheet, modelled
  on a real project DXF): pure `buildElectricalOverview(project, result)` in `electrical_sld_drawing.dart`
  → an `SldSheet` where every panel is a COMPACT node (name [tag] + incomer rating/poles + demand kW),
  laid out in a **top-down tree tiered by feeder depth** and wired parent→child with orthogonal
  feeders, carrying the **normal / essential colour split** of a real riser single-line (new `SldRole
  {normal, essential, source}` on every primitive; a panel is essential when it is on the genset-backed
  (emergency) supply — its explicit `ElectricalPanel.essential` flag — or its name marks it emergency,
  or its parent is — propagated down the emergency sub-tree. A single life-safety WAY on an otherwise-
  normal board does NOT make the whole board red (the emergency-supply flag is the cue, not one way)). The PDF + DXF exporters are now role-aware (PDF normal = the existing dark ink ⇒ the
  detail sheet is byte-identical, essential = red; DXF essential = ACI red 62/1) behind an `overview`
  flag, wired into the Export menu as **'Building single-line (overview)' → PDF / DXF**. The
  **overview + riser now render LIVE on the electrical canvas** via a reusable read-only
  `ui/electrical/sld_sheet_painter.dart` (`SldSheetView`/`SldSheetPainter`) — a `ViewportTransform`-
  driven surface that paints ANY pure-engine `SldSheet` (the SAME geometry the PDF/DXF exporters draw,
  one source of truth) with the shared drafting grid + the role colour split (normal→ink, essential→
  danger red, source→accent) and ASCII `fontFamily:'Roboto'` labels; `electrical_view.dart` `_Tab`
  grew **`overview` + `riser`** tabs (was `{singleLine, powerOneLine}`). The **PLN/MV/transformer/
  genset source chain is now prepended** (`_buildSourceSpine`, `sourceChain` flag): PLN MV STATION ->
  (PANEL UTAMA TEGANGAN MENENGAH, only for a `dualTransformer`/`sources` project) -> TRANSFORMER
  `<kVA>` -> PANEL UTAMA TEGANGAN RENDAH, with an optional GENSET UNIT (`selectGeneratorKva` over the
  project `sources.generator` backup VA) + CAPACITOR BANK on the LV bus feeding each root — kVA snaps
  to the genset ladder only, no invented physics (`// VERIFY`); default off ⇒ the overview export is
  byte-identical. A **floor-by-floor electrical riser** landed (`buildElectricalRiser(project, result,
  {building, mounting, sourceChain})`): panels placed on their building FLOOR by true §10 elevation
  (highest at the top), left-to-right per band, feeders as a vertical riser in a right-hand channel +
  horizontal branches, a left gutter with floor name + `FFL +12.50`; floor assignment =
  `panel.layoutPos.floorIndex` (clamped) → feeder-depth tier → clamp, degrading to pure `Tier n` when
  `BuildingLevels` is null/empty (never throws), fed the live mechanical `projectControllerProvider.
  building`; exported via **'Building riser' → PDF / DXF** (`exportElectricalRiserPdf`/`Dxf`, the app
  builds the sheet with live `BuildingLevels` and passes it to the prebuilt-`sheet` exporter param).
  The **per-panel detail single-line now follows the real Indonesian schedule conventions** (BRI
  `Diagram Panel`): `breakerScheduleLabel` rating-led notation (`MCB 16A 1ph`/`MCCB 40A 3ph`, ASCII
  `ph`; the curve-led `breakerLabel` stays for the incomer sub-line + legend), cable with the `mm2`
  unit + a separate-earth token (`NYY 3x6 mm2 + E6 mm2` from the way's PE CSA), per-way connected DAYA
  (`W`/`kW`), a `Cu bus <csa>mm2  Icw <kA>kA` header, CADANGAN (spare) ways as stubbed rows (from
  `spareWaysReserved`), and a TOTAL footer (diversified demand + line current) — 0-spare/withstand-off
  panels stay geometrically byte-identical. New goldens `09_electrical_overview.png` +
  `10_electrical_riser.png`. The schedule was then brought to the BRI `Diagram Panel`'s ALIGNED-TABLE
  form (column-header band GRUP | DEVICE | PENGHANTAR | DAYA | KETERANGAN | R | S | T at fixed columns,
  block width 920, a per-way `· PVC <n>mm` conduit token from the pure `_conduitMm`; the R/S/T
  phase band is THREE EQUAL ruled cells — `_phaseBandL 748` → the grid's right edge `_blockW-8`,
  split into `_phaseCellW` thirds with the verticals ON those cell edges — and its labels [heads,
  per-way figures, TOTAL footer] are CENTRED in them via build-time `_centredInCell` arithmetic
  [no renderer re-measures text, so canvas/PDF/DXF agree]; prose columns stay left-anchored per
  the BRI convention), and three further
  DXF-parity gaps (verified against the client's real EL1004 `Diagram Panel BRI` DXF) then closed in
  `electrical_sld_drawing.dart`: **(a) STARTER / CONTROL token** — the way's `ElectricalCircuit.starterType`
  (resolved by the same `circuitById` lookup that feeds `cableType`) is mapped to an ASCII token by the
  pure `_starterCode` (`dol`->`DOL`, `starDelta`->`star-delta` [NOT the unicode `Y-D`], `reversing`->`REV`,
  `softStarter`->`soft-start`, `vfd`->`VFD`, `ats`->`ATS`, `pump`->`pump`) and APPENDED to the DEVICE cell
  as `<breaker> · <token>`, shown ONLY when a way carries a real `starterType` (else bare — most final
  lighting/socket ways have none); **(b) DAYA in WATT** — the cell switched from `_watts()` (kW) to the
  pure, unit-tested `_wattsId(double w)` → integer watts with the Indonesian DOT thousands separator +
  ` WATT` (`190 WATT`, `1.100 WATT`, `4.400 WATT`, `52.871 WATT`; rounds to the nearest watt, from the
  solved UNDIVERSIFIED connected load `ElectricalCircuitResult.connectedWOrLoad` since Round 25 — the
  TOTAL footer stays the diversified demand), a feeder (loadW 0) staying `-`; **(c) circle V/A/Hz meters** —
  a new SEALED `SldCircle` primitive `{ cx, cy, r; weight; role }` replaces the boxed incomer-metering
  cluster on 3-phase boards with three small role-coloured CIRCLES (each a centred letter) + the kept `CT`
  note, handled EXHAUSTIVELY in all FOUR `SldPrim` switch sites (`electrical_sld_drawing.dart` overview/
  riser prim loops + bounds; `electrical_pdf_export.dart` 4-bezier kappa≈0.5523 circle; `electrical_dxf_export.dart`
  new `_Dxf.circle` → `0/CIRCLE`, `10`/`20` centre Y-negated, `40`/radius; `sld_sheet_painter.dart`
  `paintSldPrims` → `canvas.drawCircle`) — a new sealed subtype forcing every renderer to handle it
  (golden rule 5). All three are drawing-fidelity, `// VERIFY`-free; honesty-by-construction (starter only
  when real, DAYA from the real loadW). The per-panel DETAIL is the only path touched (overview/riser stay
  byte-identical bar the new `SldCircle` bounds/translate case). Goldens **05_electrical** +
  **11_electrical_schedule** regenerated (circle meters + WATT-dot DAYA on the MDP schedule); mechanical
  **04/07/09/10_single_line** BYTE-IDENTICAL.
  **The overview + riser then gained matching drafter rigor — feeder cable/breaker labels, kW/kVA
  compact nodes, and a riser per-floor branch fan-out** (`electrical_sld_drawing.dart`, engine-only, no
  new `SldPrim` so the PDF/DXF/canvas renderers are untouched; the per-panel DETAIL `buildElectricalSld`
  path stays BYTE-IDENTICAL): **(1)** every FEEDER run in BOTH builders now carries its real cable +
  breaker (e.g. `Cu 3x4 mm2 · MCB 25A 1ph` / `NYY 4x50 mm2 · MCCB 250A 3ph`) from the PARENT'S feeding
  circuit — shared `_feederLabelLookups(project, result, parentOf)` resolves per child-panel id the
  parent feeding `ElectricalCircuit` (by `feedsPanelId`, for the cable family) + its sized
  `ElectricalCircuitResult` (cable CSA + breaker), and `_feederConnLabel(...)` formats `cableLabel(...) +
  ' mm2 · ' + breakerScheduleLabel(...)`, returning **null when the feeding circuit or its sized result
  can't resolve** (omit the label, never fabricate); placed on the overview feeder's mid horizontal
  segment / the riser's horizontal branch into the panel, inheriting the feeder's normal/essential/source
  role colour. **(2)** the compact-node sub-line is now `<In>A <poles>P · <kW>kW / <kVA>kVA` via shared
  `_compactNodeSubLine(p)` (kVA = `demandW / _assumedPanelPf`, a file-level `_assumedPanelPf = 0.85`
  mirroring `compute.dart`'s building PF but inlined to keep the drawing file compute-free —
  representative `// VERIFY`, NOT an SNI/PUIL clause), in BOTH builders. **(3)** a riser-only per-floor
  branch fan-out: under each riser panel its NON-FEEDER outgoing LOAD ways hang as a compact column of
  short labelled stubs (`<name> <ratingA>A[ 3ph]`, name truncated to 14 chars) — the real riser
  convention (what each board distributes on its floor); feeder ways (collected once into
  `feederCircuitIds`) are excluded (drawn as a riser branch instead), capped at `kRiserFanMax = 4` with
  the remainder collapsing to a `+N more` summary row (never silently dropped). Band geometry adjusted
  (`_riserBandH` 130→150; the floor grid hairline drops below a reserved `_fanColH` fan column) so a
  dense board never overruns the next floor band. The normal/essential/source colour split + the source
  spine stay intact (feeder labels carry the feeder's role). Both builders feed the PDF/DXF exports AND
  the live Overview/Riser canvas tabs, so the change shows on the exports + canvas for free. Goldens
  **09 (Overview)** + **10 (Riser)** regenerated + verified; 05/08/11 + all other goldens BYTE-IDENTICAL.
  **Electrical single-line — LEFT-TO-RIGHT canvas + board-schedule LOD + editable source nodes landed**
  (`ui/electrical/electrical_canvas.dart` + `panel_geometry.dart` + `electrical_view.dart` +
  `store/electrical_store.dart`): the INTERACTIVE single-line canvas now flows LEFT-TO-RIGHT like a real
  CAD building single-line — `autoLayout` is transposed (depth = X, sub-panels step RIGHT by feeder
  depth; breadth = Y, siblings stacked; feeders route parent-right-edge → mid-X channel → child-left-edge)
  — with TWO clean zoom tiers: a summary card (< `kLodThreshold` 0.72) with its "N loads" merged node to
  the RIGHT, and at/above `kLodThreshold` (`scheduleDetail = detail`) the REAL engine board schedule
  (`buildElectricalPanelDetail`, the SAME geometry the PDF/DXF export draws — vertical bus on the left,
  one way ROW reading left-to-right per circuit, own header + TOTAL footer) painted read-only by
  `SldBoardSchedulePainter` (`sld_sheet_painter.dart`) into the card body, via a shared free fn
  `paintSldPrims(...)` factored out of `SldSheetPainter` (one prim-painting routine for
  overview/riser/in-card — golden rule 5). `panelFootprint(detail)` is the schedule height
  (`panelScheduleHeight`, grows with the way count). The detail tier keeps double-click/right-click
  editing via a local-y→schedule-row hit-test (`_PanelScheduleBody`). The way rows ARE the loads, so the
  hanging IEC load symbols + drop lines are dropped at detail (redundant with — and orthogonal to — the
  rows) and the card's own header chrome is dropped (the engine schedule draws its own header),
  so the deep view reads as the clean left-to-right CAD board schedule — no redundant loads below it, no
  duplicated panel-name header. Regression-covered by golden **11_electrical_schedule.png** (the canvas
  `focusPanelSchedule(panelId)` frames one panel past the threshold). **Sources are
  now first-class + editable:** (2026-10-17: the Sources + Service & Earthing editors are now ONE toolbar
  **Supply** button → `ElectricalSupplyInspector` [`showSupply`; disclosures Utility · Earthing · Backup &
  on-site · Advanced (collapsed)], also opened by the canvas supply-chain tap) a Sources editor (genset
  present/kVA[0=auto]/mode/transfer · capacitor kvar · transformer kVA · dual-transformer) wired through
  new store intents (`setGenerator`/`setGeneratorKva`/`setGeneratorMode`/`setGeneratorTransfer`/
  `setCapacitorBankKvar`/`setTransformerKva`/`setDualTransformer`) on the field-preserving `_withProject`
  (now carrying `sources`/`dualTransformer`/`capacitorBankKvar`/`transformerKva`); `_sourcesWith` rebuilds
  `ElectricalSources` preserving solar/battery/hybrid + collapses to null when emptied. The source SPINE
  now renders on the interactive single-line: when `buildElectricalSourceSpine(project, result)` is
  non-empty a read-only band (PLN→MV→TX→LV main + genset/capacitor, `_SourceSpinePainter` sharing the
  canvas zoom, ONE `_buildSourceSpine` geometry across overview/riser/export/canvas) sits above the root
  panel, replacing the bare `_GridSourceNode` PLN head; double-click → Sources editor. Empty spine (no
  sources AND no demand) keeps the PLN head. Goldens 05/08/09/10 shifted only by the new Sources toolbar
  button + the spine head replacing the PLN pill (no canvas-content regression). (The queued per-floor
  branch fan-out under each riser panel has since landed — see the overview/riser drafter-rigor
  paragraph above.)
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
  **Single-line (Riser SLD) → professional drafter output landed (incremental, toward `H-101`):**
  the Auto single-line is now a real Indonesian air-bersih riser drawing, not a wireframe. Nodes
  carry their schematic SYMBOL (`_paintNodes` reuses `paintComponentSymbol`; fixtures = a drop
  terminal) + an equipment/role LABEL, service-coloured. Piped runs read the industry tag
  **`SIZE-SERVICE-MATERIAL`** (`_pipeTag` + `_serviceCode` CW/HW/D/V/RW/SA/RA/EA/SP/FH +
  `_pipeMaterialCode` PPR/PVC/CI/HDPE/BS from `pipeProduct` or the service default), now with an
  Indonesian FUNCTION suffix (**GRAVITASI / BOOSTER / TRANSFER**) and a per-riser TAG (**CW-R1** …)
  from pure, unit-tested `ui/schematic/riser_tags.dart` (`riserFunctionFor`/`riserTags`/
  `riserServiceCode` — function appended ONLY when confidently derivable from endpoints + feed
  strategy, else nothing; every rule `// VERIFY`). A system-filter (All / per-service chips) divides
  the diagram per system or shows a combined view. **Inferred risers** (`_computeInferredRisers`,
  mutual-nearest per vertical stack) draw as dashed connectors when the `Infer risers` toggle is on
  and are **one-click committable** to a real sized riser edge (`NetworkController.connectRiser`,
  length = §10 elevation delta, one undo step). Drafter chrome: a toggleable **Legend (KETERANGAN)**
  box (bottom-left, on-diagram service codes) + a toggleable **title block** (bottom-right: project ·
  `SINGLE-LINE DIAGRAM` · `SHEET · <filter>` · date). All EN ⇒ goldens 04/09/10 shift only by the new
  draughting content. Engine untouched; no `.mechx` change.
  **The five remaining H101 (Diagram Sistem Air Bersih) elements then landed** (all on the Auto Riser
  SLD `_AutoSchematicPainter` / `_AutoElevation` in `schematic_view.dart`, plus a pure helper in
  `riser_tags.dart`): **(1) PUMP-SET PLANT DETAIL** — a compact top-right bordered callout
  (`_paintPlantDetail`) with a ROOF-TANK glyph + real capacity (`m3` from the roofTank node's
  `tankCapacityLitres`), a BOOSTER-PUMP glyph + real duty (`<kW>` from `pumpDutyProvider`'s
  `selectedMotor`), a connecting leg, and the GRAVITASI / TRANSFER / BOOSTER leg labels (chosen from
  the feed strategy + whether a ground tank exists) — drawn ONLY when the network actually has a
  roofTank / groundTank / pump / boosterSet (else omitted entirely) and only on the clean-water focus;
  **(2) VALVE-ASSEMBLY DETAIL CALLOUTS** — two bottom-centre bordered boxes (`_paintValveCallouts` +
  the shared `_detailBox` / `_drawDetailGlyphRow` helpers) — DETAIL WATER METER (GV · WM · GV · U) and
  DETAIL PRV SET (GV · STR · PRV · GV) — rows of schematic `paintComponentSymbol` valve glyphs joined
  by a run line, each with a tiny ASCII abbrev (the glyph is schematic, the abbrev names the real
  device); generic reference details (always available, width-guarded clear of the corner overlays);
  **(3) FITTING LEGEND** — `_AutoLegend` gained a FITTINGS subsection beneath the on-diagram service
  codes (CW · AAV · GV · CV · STR · PRV · WM · SF · CF · BV · FJ with full names), reference data, not
  data-gated; **(4) SYSTEM-NOTES (KETERANGAN) card** — a bottom-right floating-glass `_SystemNotes`
  card echoing ONLY real values: feed strategy (gravity downfeed vs upfeed / booster), each tank
  present with its real `m3`, occupancy class, and the PEAK design flow (`L/s` from `pumpDutyProvider`,
  upfeed-only — the engine has no daily-volume figure, so the demand line is OMITTED on downfeed rather
  than fabricating a `m3/day`); stacked above the title block (both bottom-right); **(5) PER-FLOOR
  BRANCH FAN-OUT** — under each floor band, a compact column of short labelled stubs for the FIXTURE
  nodes that floor distributes (`_paintFloorFanOut`), driven by the pure, unit-tested
  `floorFanOuts(net, {visibleNodeIds, labelOf, max:4})` → `FloorFanOut(floorIndex, labels, overflow)`
  (groups `NodeRole.fixture` nodes per floor, deterministic by x-then-id, honours the focus filter,
  caps at 4 with the overflow COUNTED and rendered as a `+N more` row — never silently dropped, never
  overrunning the band). All four detail/notes blocks are toolbar-toggleable via two new chips
  (**Details** / **Notes**, EN+ID `StringKey.schematicDetails`/`schematicNotes`, both default ON as
  the deliverable); every NEW on-canvas label is ASCII (`m3`, `L/s`, `·`), no `Ø`/`m³`/superscripts.
  Honest by construction: a detail is omitted when its data is absent (no roof tank ⇒ no pump-set
  block). EN ⇒ goldens 04/09/10 shift only by the new draughting content; the Edit-mode (07) +
  electrical (05/06/08/11/10_electrical) goldens stay BYTE-IDENTICAL. Engine untouched; no `.mechx`
  change. (Queued: the STP process-flow diagram; per-unit branch fan-out and bringing the
  **electrical** SLD/exports to the same drafter quality have since landed.)
  **Mechanical Riser SLD vector EXPORT landed (PDF + DXF); legend/title block moved to the export**:
  the mechanical riser single-line now exports as crisp vector via the discipline-neutral engine
  `SldSheet` pipeline (extracted to `report/sld_sheet.dart`, re-exported from `electrical_sld_drawing`
  ⇒ electrical byte-identical). New pure `report/mechanical_sld_drawing.dart` `buildMechanicalRiserSld`
  builds the riser sheet (floors by §10 elevation + FFL gutter, `SIZE-SERVICE-MATERIAL[-FUNCTION]` pipe
  tags + `CW-R1` riser ids, fixture markers, per-floor fan-out, the KETERANGAN fitting legend); the pure
  tag helpers moved INTO the engine (`report/riser_tags.dart`, one-line re-export shim left at the old
  app path). The electrical PDF/DXF exporters gained a `diagramTitle` param (default electrical ⇒
  byte-identical) + a neutral `report/sld_export.dart` `sldSheetToPdf`/`sldSheetToDxf` wrapper, so the
  mechanical side renders the same vector formats with a mechanical heading (`DIAGRAM SISTEM AIR BERSIH`
  / per-service). App wiring `lib/ui/schematic/schematic_export.dart` (`exportMechanicalRiserPdf`/`Dxf`)
  builds the sheet from the live providers for the current Auto-view focus + an honest supply note, saved
  via the file picker, behind a new **Export** toolbar button + `_RiserExportMenu`. The legend + title
  block are now DRAWING CHROME that ride the EXPORT — the live-canvas `_showLegend`/`_showTitleBlock`
  default OFF (previewable from the toolbar's **Show** popover, which since 2026-10-17 holds
  Details/Notes + an 'Export preview' Legend/Title block pair); Details/Notes stay ON. The Edit
  toolbar's riser service picker is discipline-scoped (Plumbing/Fire/HVAC segment → that
  discipline's service chips). Goldens 04/09/10 shift only
  by the decluttered working canvas + the Export button; electrical 05/06/08/11 BYTE-IDENTICAL. No
  `.mechx`/version change (export is build-time).
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
  **Electrical panel design workflow — drop/auto-size/connect/balance across both surfaces landed:** the panel WORKFLOW adds end-to-end panel creation from Layout + single-line canvases via five coordinated waves. **W0 engine (phasing, topology, templates)** — `balancePhases` prior-seeding + phase-stability reassign (defaults byte-identical); `ElectricalCircuit.copyWith` clear-flags for `feedsPanelId`/`breakerOverrideA`/`cableOverrideMm2`/`groupingCountOverride`/`phaseOverride`/`laying`; `panel_templates.dart` presets (lighting/power/mixed + 20%/2-way headroom); `resolveCircuitLengthDetailed` (manual vs geographic source honesty); `MepEquipmentLoad.loadPos`; `sanitizeFeederTopology`. **W1 store (operations + cell assignment)** — `connectFeeder` atomic RE-PARENT (default; `reparent:false` keeps refusal) + shared pure `feederRefusalReason`; `setCircuit` extended (breaker/cable/grouping/phase-pin/laying overrides + clear); `pinPanelPhases` w/ session 1.0 A stickiness cache; creation intents return ids; `kDefaultCircuitLength` 10 m; name de-dup; `addPanelAt(templateId)`/`applyPanelTemplate`/`addFedPanelAt` (fed+populated, one undo); delete/load hygiene via `sanitizeFeederTopology` (Wave-4 '' sentinel CLOSED); `syncMepEquipment` auto-feeds from single unfed root; `electricalResultProvider` phase-stability memoization. **W2+W3 UI (canvas drop creation + multi-surface edit)** — outlet connect-grip as full right-edge band w/ screen-constant hit (fixed the old Transform+OverflowBox pointer-dead zone via FittedBox); feeder drop-target tint (accept/refuse via `feederRefusalReason`); body-drop connects UNFED board to parent; sized-drop toasts ('Lighting 2 -> LP-1: MCB 10A · 1.5 mm2 · Vd 1.2%'); summary card adds busbar + n/m-placed + phase-imbalance badge; fed-badge re-sourced; **new micro LOD** <0.30 zoom (name + kW + proportional R/S/T bar; `PanelLod {micro,summary,schedule}`); circuit/panel inspector result blocks (Ib/cable/Vd%+cumulative/R-S-T/effective-length basis + phase-pin picker + set/Clear override fields); palette Capacitor bank + template panel cards; auto-straighten near-aligned feeder runs. **W4 layout/single-line sync (drop → place → riser)** — drop-on-marker creates PLACED way (no unplaced orphan); shared nearest-within-snap; `nextSubPanelOrdinal` at mint; selected-marker outlet grip draws feeder ON PLAN (geo length immediate); menus share Feed-from/Pin-phases/Un-place; tray lists UNPLACED ways + empty-stub remove. **W5 polish** — cross-view 'Show on layout'/'Show in single-line' actions; EN+ID i18n sweep (EN byte-identical). Gate: every wave clean analysis + engine `dart test` + app `flutter test`; goldens 05/06/08/10/11 re-captured + visually verified; engine **1377→1444** tests; app **~1106→1208+**. Out-of-scope residuals: R-S-T pole-order schedule grouping (circuit order kept), occupancy-keyed `PuilDiversityLibrary` wiring (model persisted, UI dark), root-selection convergence (3 extant), way-row dragging (store-only).
  **W6 — in-place value ladders in the electrical right-click menus (user-reported follow-on):** the SHARED
  `ElectricalCircuitMenu` is now stateful with four VALUE rows between Edit and Duplicate — `Breaker · MCB 16A` /
  `Cable · 2.5 mm2` / `Phase · S` / `Family · NYY` — each a one-tap LADDER PAGE (the panel menu's "Feed from…"
  paging idiom; `ElectricalMenu` gained additive `note`+`scrollable`, the mechanical size-ladder scroll idiom).
  Ladders come from the ENGINE tables (`PuilProfile.standardBreakerRatingsA` labelled MCB/MCCB via
  `breakerClassFor`; `standardSectionsMm2` with a "minimum — sizer may pick larger" note; the shared
  `kCableFamilies` const the inspector's picker also derives from), picks write the existing `setCircuit`
  override/clear fields (one undo step each), the EFFECTIVE value is row-marked (override, else the solved
  result figure) and '(set)' marks an active override. Honesty gates: value rows only when the host resolves
  the model row (`circuit`/`circuitResult`/`panelSystem` params; null result ⇒ 'auto', nothing fabricated);
  Phase only for a KNOWN 1ph way on a KNOWN 3ph board, never a feeder; spare ways breaker-only.
  `ElectricalPanelMenu` gained `System · 3ph 400 V` → a 1ph 220 V / 3ph 400 V page (`setPanelSystem` voltage
  snap), gated OFF the MEP board. HOST CONVERGENCE: `electrical_view.dart`'s drifted inline menu copies (incl.
  its own feed-chooser page) were replaced by the shared widgets; both hosts wire the new params, so the two
  surfaces can never offer different rows. Menus closed at rest ⇒ goldens byte-identical
  (`test/electrical_context_menu_edit_test.dart`, 6 tests).
  **W7 — editable SUPPLY node + BATTERY/SOLAR nodes + genset backup % (user-reported):** additive
  `ElectricalProject.supplyKind` (`SupplyKind {pln, generator, solar}`, default pln ⇒ byte-identical) +
  `supplyCapacityVa` (declared daya tersambung, null ⇒ not printed; since the 2026-07-31 service-capacity
  floor it ALSO sizes the root incomer — see the Sizing-engine invariant) re-label the source-spine HEAD via
  the shared `_supplyHeadLabel` in BOTH spine builders (tolerant JSON, `_withProject`-carried,
  `setSupplyKind`/`setSupplyCapacityVa`); a single TAP on the canvas supply chain (or bare PLN head) opens the
  Sources editor, which gained Supply (kind + capacity), Solar PV and Battery sections over new
  `setSolar`/`setBattery` intents (`_sourcesWith` replaces/clears any sub-source, collapses to null when
  emptied). New `_emitBattery` (IEC plate pairs) + `_emitPvArray` glyphs (pure prims, no new `SldPrim`
  subtype) hang BATTERY/SOLAR PV nodes off the LV bus below the genset/capacitor slots (coordinate-preserving
  cursor ⇒ absent sources byte-identical); the battery kWh is sized on the SAME `sizeBattery(demand × PF)`
  basis as `buildPowerOneLine` (zero demand ⇒ bare 'BATTERY'), solar prints installed kWp. The GENSET node
  prints `backs NN% of load` — sized/declared kVA vs solved demand kVA, capped at 100, omitted with no
  demand — in both builders (canvas + overview + riser + PDF/DXF). Engine +6 / app +1 tests; goldens
  byte-identical (golden fixture carries no sources).
  **Honest LV service on the source spine (user-reported) + a `feeder-below-fed-demand` check:** the
  MVMDP → TRAFO → LVMDP chain now draws ONLY for a DECLARED MV service (`_isMvService` = explicit
  `transformerKva` OR `dualTransformer`) in BOTH spine builders (the canvas horizontal chain + the
  overview/riser vertical one); an LV (TR) direct service — the default, incl. any project with only
  demand — draws the supply head alone (plain `PLN [capacity]`, never 'MV STATION'), with
  genset/capacitor/solar/battery on a stacked drop off the head, the earthing designation at the
  service entrance, and a short outgoing lead into the root board. Distributed sources no longer imply
  an MV station and no trafo kVA is fabricated from demand; declared-MV projects render
  byte-identical. The Sources editor's connection-capacity field is now **VA** (daya tersambung is
  quoted in VA; the old kVA field stored 33 MVA when 33000 was typed). `computeSystem` gained a
  JUDGE-ONLY `feeder-below-fed-demand` warning (never resizes): a feeder way sizes on the fed board's
  diversified demand W at a balanced pf while the fed board's incomer sizes on its WORST-PHASE
  current, so an imbalanced fed board could carry a feeder breaker below its own printed demand
  (25 A feeder vs a 27.1 A / 24.3%-imbalance board in the whole-building sim that found it) — surfaced
  on the parent's feeder way (locatable), fanning into Review via the generic `electrical:<code>`
  kind. Goldens 05/08/11 re-captured (the sample project is an LV service ⇒ head-only spine).
  **R/S/T phase colour-coding + a legibility-derived LOD threshold then landed (user-reported):**
  the board schedule was monotone, so `SldRole` gained `phaseR/phaseS/phaseT` — the R/S/T column
  headers, per-way line-current cells and TOTAL footer totals carry their phase role, and every
  renderer colours them (canvas `paintSldPrims` → the `kRailR/S/T` rails, which MOVED into
  `sld_sheet_painter.dart` as the ONE phase palette shared with the summary-card cells + micro
  bar; PDF → matching print inks with S as dark amber; DXF → ACI 1/2/5). A drawing legend, NOT
  the PUIL/IEC conductor colours — no wiring-colour claim. And `kLodThreshold` went 0.72 → 0.95,
  now derived from legibility (the 7.5-px schedule rows arrive at ≥ ~7 px on screen) instead of
  ported — below it the summary card keeps the glanceable stats; `kMicroThreshold` unchanged
  (it gates interactivity, not readability). Goldens 05/11 re-captured.
  **`USABILITY-REVIEW.md` (root) is the CURRENT usability plan of record** — an all-pages review
  (every golden read as an image, findings code-grounded): 17 findings in three waves — A honesty
  + electrical feel (the `0.0 m ×5` uncalibrated-length rows, the overpainting feeder labels at
  one outlet [`…3ph h`], heatmap basis captions, the bare 'BOM' heading), B label/overflow
  robustness (chip-row overflow, live riser label collisions, LOD hysteresis), C chrome polish.
  The phase-colour + LOD items above are its landed Wave 0. **ALL THREE WAVES HAVE SINCE LANDED**
  (2026-07-30, one 7-agent parallel batch — see the §15 row): staggered feeder labels (pure
  `feederLabelAnchors`, single-feeder byte-identical), the motion-gated LOD crossfade (visual-only,
  `panelLodFor` stays pure), the off-Layout zoom pill omitted, width-budgeted riser fan-out labels,
  the fading riser chip strip, a deterministic live-riser label collision pass that never drops a
  tag (seeded with gutter/fan-out/callout rects), honest `unmeasured ×N` BOM rows, basis captions
  on both pressure surfaces, the gated empty-state caption, `Electrical BOM` naming, the balanced
  Review stat row, grouped `×N` issue rows with per-sheet Locate links, export-group counts, and
  the Preferences SOFTWARE UPDATE section; B-1 was already compliant. Four deviations recorded in
  the review doc's status note.
  **The phase-imbalance warning then became actionable-only (user-reported):** a board with two
  3φ feeders and two EQUAL 1φ lighting ways was told to "Redistribute single-phase circuits" at
  22.3 % — impossible, since two equal ways cannot load three lines evenly and the ENGINE (not the
  engineer) already placed them as evenly as they go. `phase-imbalance` is now gated on the
  imbalance being genuinely REDUCIBLE against an achievable floor (see the Sizing-engine invariant),
  and when it does fire it names the real action ('Unpin the N ways pinned to a phase …') plus the
  figure that is achievable. Judge-only, no sizing change; goldens byte-identical (the sample
  project's boards sit at 12 %, under the limit).
  **Both recorded follow-ups HAVE SINCE LANDED (ultracode multi-agent batch):** (1) **riser
  feeder-label collision pass** — `buildElectricalRiser`'s feeder annotations now go through a
  private two-pass placer (`_RiserLabelPlacer`, the mech-riser B5 idiom: per-size char-advance
  collision boxes via the public `kElectricalRiserLabelCharW`, an escape ladder [clear branch
  span → a right-of-channel stacked annotation column], thin `SldLine` leaders back to the
  branch, never drops a label); an uncollided label keeps its exact legacy anchor ⇒ goldens
  byte-identical; sheet bounds widen only when displacement happened. (2) **service-size-derived
  device kA** — pure `estimatedServiceFaultLevelA(project)` in `electrical/fault.dart`: a declared
  `transformerKva` gives the transformer-impedance-limited LV fault (`Isc = S/(√3·400·0.04 pu)`,
  UNCLAMPED since Round 17 — above 50 kA the advanced study raises `service-fault-estimate-high`
  instead of lowering the figure, `// VERIFY`), a declared `supplyCapacityVa` gives conservative service-entrance
  rungs (≤16.5 kVA → 6 kA, ≤197 kVA → 10 kA, all `// VERIFY`) and — since Round 25 — ABOVE the PLN TR
  ceiling its own transformer fault `max(S/(√3·400·0.04), the study transformer's fault for the demand,
  16 kA)` (a declared 630 kVA ⇒ 22 733 A, never a flat 16 kA), nothing declared →
  null (caller keeps the flat 16 kA ⇒ untouched projects byte-identical). Wired as the middle
  tier of the Fold-1 fallback chain (explicit `originFaultLevelA` → estimate → 16 kA) in
  `electricalResultProvider`, the Service & Earthing field (shows the EFFECTIVE default), the
  EN+ID note, AND — the review-caught seam — `computeAdvancedStudy` now resolves its `faultStudy`
  origin through the SAME chain (new optional `originFaultLevel` param), so the schedule's device
  kA tokens can never diverge from the bus-withstand basis: a 5500 VA house prints `MCB 6A 1ph
  6kA` / `Icw 6.1kA` instead of 25 kA devices. `serviceFaultEstimateVerifyItems` carries the
  provenance debt (wiring it into the report honesty surfaces is the remaining follow-up).
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
  **(2026-06-30 promotion, per explicit user direction after a deep-research
  pass):** a batch of constants confirmed against the engineering texts was
  promoted to `sniVerbatim` — plumbing `maxFixtureStaticPressure` (SNI
  8153:2015), `maxSupplyVelocity` (SNI 03-7065-2005), the demand curve, runoff
  C, Legionella 55 °C; electrical `maxVoltageDropGeneral` (PUIL cl. 4.2.3.1) +
  `maxEarthResistance`; and the **SNI 03-6572-2001 Tabel 4.4.1** ACH rooms.
  Items that are genuinely IEC/NEC/general-practice (e.g. `continuousLoadFactor`
  125 %, `maxVoltageDropLighting` 3 %, drain velocity/gradient, non-table ACH)
  stay `notAnSniClause`/`secondarySource`. The interactive Review Advisory
  (`design_issues_store.addVerify`) now surfaces ONLY `secondarySource` debt;
  `notAnSniClause` (a confirmed design choice) is no longer nagged there but
  still prints in the calc report's transparency section.
  **(2026-07-01 follow-up pass, `docs/standards-references.md`):** the ACH
  figures outside SNI 03-6572-2001 Tabel 4.4.1 and the cooling-load
  area-density rule (`ventilation.dart`) were confirmed genuinely out of
  scope and reclassified `secondarySource` → `notAnSniClause`. The 5
  remaining electrical items in `puil.dart` (nominal 400/220/230 V, the KHA
  ampacity table, the IEC derating tables) got sharper citations (SNI IEC
  60038:2013 for the 400 V nominal; PUIL's own Tabel 41.1 for U0) and a spot
  check (1 KHA entry + 2 derating points, matched) but were **NOT** promoted:
  this session's network egress policy hard-blocked every external document
  host (policy-level 403 at the proxy gateway — confirmed via
  `$HTTPS_PROXY/__agentproxy/status`), so no primary PUIL/SPLN text could be
  read. A genuine open discrepancy was surfaced rather than guessed: sources
  conflict on whether the current Indonesian residential single-phase
  nominal is 220 V or 230 V. Completing promotion of those 5 needs either
  unblocked network egress or a locally-supplied PUIL 2011 / SPLN 1 text.
- App lifecycle: the root `ProviderContainer` and autosave `Timer` in `main`
  live for the whole process and are not explicitly disposed (fine for a
  single-window desktop app; revisit if multi-window).

## Sizing-engine invariants (don't regress)

- **Round 29 — per-system fire judges, one declared MV service, orderable earthing, legible drawings (2026-10-18)**: the sprinkler-vs-fire-pump judge (`sprinklerPumpCheckProvider`) compares each sprinkler-bearing fire system with ITS pump (`fireSystemBasesProvider` duty; the governing `firePumpDutyProvider` only for a sprinkler-only system with no pump drawn) — never another system's pump. The calc report's standpipe line is `reportStandpipeDesignProvider` (the governing hydrant basis' friction-inclusive `FireSystemBasis.standpipe`); `standpipeDesignProvider` stays friction-free for the sizer. A 1φ motor's control gear sizes on `motorFlc1ph` at U0 (`applyStarterTemplate(singlePhase:)`, the way's SOLVED phase). ONE declared-MV predicate: `isDeclaredMvService` / `declaredServiceTransformerKva` (explicit transformer, or a declared capacity above `plnLvServiceCeilingVa` snapped UP the transformer ladder) for the supply study, `serviceTransformer`, the drawings, the power one-line and the fault estimate. A verify item never claims a basis the study did not use (`faultStudyMotorVerifyItem` only when a motor infeed > 0 was passed). The TN main earthing conductor is an orderable make-up (one ladder conductor, else n parallel per-run PEs — `mainEarthingMakeup`, BOM qty n). Persisted settings text fields commit on blur / Enter (one settings undo step per edit). Run element tags read the building's ground-relative level (`floorLocatorToken`: `B<n>` / `GF` / `L<n>`; every artifact passes the building — no building ⇒ legacy `F<n>`). The mechanical riser never prints a tag FUSED into another without counting it (`SldSheet.overlapCount` → `planOverlapWarning` on the SLD PDF / DXF); paginated stubs are reserved before LANJUT labels; a duct tag clears its own outline (`placePlanLabel(ownHalfWidth:)`); MV side sources hang off a collector bus joined to the LV main; a beside-root riser spine's whole side stack sits above the supply row; a plan tag whose leader strikes a placed label is counted.
- **Round 28 — the circulator envelope to a fixed point, a linear classifier, valveless pump sets + recirc returns, fire pumps per system, persisted counters (2026-10-18)**: the r8 balance-against-pump scenario (a) is ITERATED — legs that run against their pump in a closed solve join the closed set and the closed reading is re-solved while it grows (bounded by the mover-leg count; the per-leg fallback is not iterated), so a hotel with a circulator on every return riser never sizes a supply pipe below the OPEN network (seeded property, `round28_engine_test.dart`). Classifier cost stays near-linear: `distFrom` / the return plan's `dist1` are (distance, id) priority-queue Dijkstras (the SAME settle order ⇒ identical maps), `distFrom` is memoised, `disconnectsDemand` is a memoised BFS, the node predicates are resolved once per component into sets, and `Network.nodeById` / `edgeById` use a lazily built, length-stamped id index (never re-introduce a per-relaxation linear scan; pinned: 30 risers x 10 floors with return valves < 5x the valveless drawing). A duty/standby set drawn WITHOUT check valves (coherent valveless mover legs with the same two leg ends and direction, discharge sets only) is the Round-13 parallel set (tree through the first leg by pump id, the rest mirrored, `parallelLegEdgeIdsOut`). On hot water, beside a root chain carrying a coherent mover pointing AWAY from the heater, every valve-free, mover-free, demand-free root chain is a plausible valveless recirc RETURN: scenario (a) closes it with a pseudo return valve at its root end (`returnChainKeysOut`), enveloped with the balanced reading (supply main curve(8) DN20; this closes the r7 probe-4 residual — the pump legs now carry curve(8)). A pump-free valveless ROOT chain whose far junction is reached from every other side only through coherent valveless movers pointing INTO it is a RETURN chain (closes r8 residual (i): the ambiguous heater discharge beside it is a FEED). Fire: every connected fire network is its own SYSTEM (`fireSystems`): `drawnStandpipeRiserCount` = the largest system's stack count (independent towers never add); each drawn fire pump is rated on its OWN system (`firePumpBasisByNodeProvider` → panel feed + schedule; sprinkler-only system ⇒ remote-area flow + sprinkler label); on a calibrated drawing the friction term is max(15 m allowance basis, Hazen–Williams C 120 of the SIZED index path from the duty pump — `fireIndexPathFrictionM`, sprinkler basis with the remote HEAD pressure); an unmeasured flowing pipe ⇒ the allowance alone (more information never lowers the rated head). `.mechx` carries additive `network.nextSeq` / `roomNextSeq` only when the counter runs ahead of the live ids; a load also clears every id still referenced (parked `mep-node-n<k>` ways, acknowledgement keys, terminals' `autoPlacedRoomId`) — a reload never re-mints a deleted id. Fixture library, commercial pricelist / markups, saved assemblies, equipment model/spec and document control edits are ONE `UndoDomain.settings` step each (equal values record nothing; load `set` never records). Floor heights decode into [0.5, 20] m (non-finite / non-positive ⇒ 3.5); an empty floor list loads `kDefaultProjectFloors`; `CustomFixture` units decode finite >= 0. `Network.nodeById` / `edgeById` read an Expando index keyed on the list INSTANCE + length: never replace an element in place (`nodes[i] = ...`) — build a new list (every store mutation already does), or the index returns the old node. Persisting `network.nextSeq` means add-then-undo of the newest node leaves the document dirty (an autosave recovery snapshot) although the drawing matches the save — the deliberate price of stable ids. Recorded residual: the residuals-2 return-chain envelope skips a ONE-edge root chain, so a hot-water return landing on the heater by a single pipe from a degree >= 3 junction is not enveloped.
- **Round 27 — feed vs return valves, vent chains, intake in series, net room area, per-system curves, R12-honest DXF (2026-10-18)**: cycle check valves follow the r3 BINDING rule (`_classifyLoopCheckValves`; hop / shortest-path draw-off heuristics failed review three times — topology alone cannot tell a mis-drawn return from a genuine second feed): the DRAWN direction is authoritative when unambiguous (one pipe into the valve node, one out); each valve is classified with ONLY ITSELF removed — root distance in the BEND-FREE hop metric (r8: `bendWeight`, a bare degree-2 node weighs nothing; r7: never calibrated metres or plan pixels) between its EFFECTIVE in- and out-neighbours (r8: the first non-bend node past any elbows): out-node strictly nearer ⇒ a RETURN (zero draw-off, the r4 cut + `returnPlan` on the remainder), otherwise (ties too) a FEED that is NEVER zeroed — a transparent pipe of the loop set, except a parallel duty/standby set onto one header (legs merging at ONE junction, or every leg with a mover), which keeps the Round-13 standby-leg rule; mixed sets zero exactly the returns. An AMBIGUOUSLY drawn valve follows the r5 conservative rule below (no longer the Round-15 topological orientation); a set of DRAWN returns that would cut a draw-off point off the source (self-contradictory, e.g. both duty/standby legs drawn header -> valve -> pump). A feed valve is one-way on every supply-path walk (`returnPlan`'s supply paths, its tree must reach each feed from its inlet; the return walk never enters a feed valve or its end nodes), and Hardy–Cross CLOSES a feed valve the balanced split would run against (zero flow, re-balanced while every draw-off stays fed). A HOT-WATER feed valve whose outlet the source still reaches with it and every return closed raises the judge-only info `check-valve-feeds-ring:<nodeId>` (EN+ID, locatable — 'if it is a recirculation return its arrow is drawn backwards'); a return drawn H -> CV -> RJ is sized AS DRAWN, never re-interpreted. A return CHAIN landing on the inline top fixture is return side; a landing from a tee keeps the ring split. `_uniformVentStacks` classifies runs as CHAINS through bare bend nodes; a VTR stub group TIED to no drainage node (no drainage node in it AND no vent run / chain from it to a drainage node) with >= 2 runs at its bottom is a header junction (never an offset) — an upper stack whose floor tie leaves its offset foot is still an offset (r2); a stack-top run to a bare non-riser node the air leaves through bounds the stack like a header; a run VTR is judged against its own stack top. `solveDuctStatic` ADDS the unit's intake path (sized flow arriving at the fan) to the supply index run. Room sizing / cooling / AC share / Auto-place use `RoomArea.netAreaM2` (footprint less the union of overlaps with STRICTLY smaller rooms; pass `rooms:`); a room's schedule row is dropped only when `roomServedByDrawnAir`; a clamped room trunk (`trunkOverCapacity`) is a `room-trunk-over-capacity:<id>` warning; the inspector face is `TerminalBank.faceMm`. The Hunter flush-VALVE branch applies per cold-water component holding a flush-valve node (`flushValveNodeIds` / `flushSystemForRoot`), never project-wide. DXFs declare AC1009: no group 370, no `$INSUNITS` / `$MEASUREMENT`; SLD DXF text height = PDF em x `kHelveticaCapHeightEm` (0.718); the SLD supply note wraps inside its title box; the layout DXF title block sits above the unplaced notes. **r4 (orchestrator sign-off, written into the rule):** (a) a FEED valve whose Hardy–Cross split would run against it is CLOSED (zero flow, re-balanced) — that is what a check valve does, so the seeded property asserts flow >= 0 in the drawn direction for every feed; (b) a set of drawn returns that would cut a draw-off point off the source falls back to the Round-15 topological orientation (drawn or ambiguous returns alike); (c) a valve CLOSED by the balance — or any feed valve left at zero flow — is treated EXACTLY like a classified RETURN for output: both legs at zero in its permitted direction, the pipes it isolates sized at ZERO flow (DN15 minimum, fixture units 0, `sizeZeroPockets`, walked from each side over unsized / zero pipes, never through another valve; inlet side oriented toward the valve, outlet side away) on calibrated AND uncalibrated drawings — never silently left out of the result (an exactly-zero balanced edge or a demand-free dead end used to drop the return pipework from the BOM / canvas / riser depending only on calibration) — and it never raises `check-valve-feeds-ring`. The same zero-pocket sizing applies behind every classified RETURN. (SUPERSEDED by r5 — `ambiguousInlet` is gone:) an AMBIGUOUSLY drawn valve was read with ONLY ITSELF removed (every other check valve a plain pipe, the rule-2 principle): strictly off every root -> draw-off path ⇒ the farther side is the inlet; else an adjacent mover; else a valve that only TIES a path (a return teed at the top fixture) reads the same farther-side way; only then the all-cut reading — cutting every valve let a heater DISCHARGE valve isolate the root and turn an ambiguous common return into a feed (hm 0.3237 vs curve(16) 0.6533 L/s). Residual inherent to the binding rule (recorded): a genuine second feed whose leg is LONGER (r8: in REAL nodes — tees / inline devices; bare elbows weigh nothing) than the alternative ring route to its entry junction reads as a RETURN and is zeroed (its leg sized at zero, never against the valve) — only the flow-against-valve half of the r2 hop residual is closed. **r5 (binding orchestrator decision for AMBIGUOUSLY drawn cycle check valves — both pipes into, or both out of, the valve node; four rounds of distance heuristics each failed review):** the intent cannot be recovered from topology or hop/metre distances, so the reading is CONSERVATIVE and structural: (1) a valve whose two leg ends (through bare degree-2 nodes / inline pumps, `legEnd`) are exactly those of another cycle valve is in a PARALLEL set onto one header (duty/standby, pump + bypass) — oriented by a DRAWN partner, else by the only leg end the root reaches with every cycle valve cut — and keeps the Round-13 standby-leg rule if it actually forms that set; (2) otherwise it is a CLOSED RETURN (zero draw-off, the r4 cut, its isolated pipes sized at zero DN15 / fu 0), so every main upstream carries the full peak, never under-sized; (3) unless closing it with the drawn returns cuts a draw-off point off the source — then a PLAIN PIPE (Hardy–Cross); valves that starve one only TOGETHER are reopened symmetrically (every valve whose reopening alone restores supply — a dual-feed ring through two ambiguous valves is two pipes), never by id order; (4) every ambiguous cycle valve raises the judge-only, locatable info `check-valve-ambiguous:<nodeId>` (EN+ID: direction ambiguous, how it was assumed — closed return / plain pipe / standby set — redraw its two pipes in the flow direction; `autoSizeNetwork(checkValveAmbiguousOut:)` -> `checkValveAmbiguousProvider`) and never `check-valve-feeds-ring`. A closed return's orientation is cosmetic; `returnPlan` walks from BOTH its sides, each start on its own, in a BEND-FREE metric (a bare degree-2 node weighs nothing — `bendWeight`), and a walk that lands on two points of ONE supply path (one downstream of the other on the shortest-path DAG) is a ring segment, not a return (extends nothing) — so for ambiguous valves the reading AND every pipe size are invariant to bare bends anywhere and the reading to calibration (seeded property). Behaviour change (intended): an ambiguous genuine second feed — even one that ties or shortens a draw-off path — now reads as a closed return (the first leg carries curve(total)); r4's tie branch read it as a return only without a valve on the first leg. `check-valve-feeds-ring` no longer names a correctly drawn discharge valve beside a backwards return: with several candidates, those on the source's shortest route to its nearest draw-off (heater / pump discharge) are dropped. Unambiguous valves keep the r3/r4 drawn-direction rule. **Residual (recorded, rule 2 — unambiguous valves):** rule 2 reads the bend-free hop metric since r8 (hops only since r7), so neither calibration nor bare elbows flip a reading (the r5-era calibrated flips — a 2-bend dual feed read RETURN at 4 m vs 3 m, a backwards top-of-riser return R3 -> CV -> S3 read return at 11 m vs 13 m — read exactly as uncalibrated; the 4-bend dual feed is a FEED as with 0 bends); only a genuine metric TIE broken by a REAL node (an inline device / tee / fixture added to one side) can still move a drawn valve's reading. **r6 (kept by r7):** a cycle check valve on a MOVER leg (a pump / booster set / supply fan between the valve and the next junction, through degree-2 nodes and inline devices) is NEVER zero-forced; a drawn valve pointing back at its own incoherently drawn pump is read as a feed and reported `drawnAgainstSupplyLeg` (its own Review title, EN+ID); parallel sets onto one header also form STRUCTURALLY (feed valves with the same two oriented leg ends), so a header also reached by a valve-free return keeps the Round-13 standby rule — the standby legs leave the Hardy–Cross loop set and mirror the duty leg (`mirrorStandbyLegs`, both paths); `supplyFan` is a mover. r6's choice of the source's discharge chain by the drawn PLAN route is GONE (a 30 px move of the return riser flipped it). **r7 (binding orchestrator decision — ORIENTATION PRECEDENCE, highest first):** (1) a DRAWN valve direction; (2) a MOVER on the valve's degree-2 leg drawn COHERENTLY (one pipe in, one out) orients the leg and every valve on it, ambiguous ones included, and is never overridden by root distance, metres, hops or chain choice — a coherent circulator drawn TOWARD the source on a root chain is a recirculation return (an ambiguous valve on it `closedReturn`, the supply main curve(8) = 0.4000 L/s DN20 as on 4e5e9d9, either pump position), every other mover leg a FEED; an incoherently drawn ("ambiguous") pump orients its leg away from the source — the root side of a root chain, else the end nearer the root in BEND-FREE hops with the leg removed, never metres; (3) STRUCTURAL root-chain cues only — a drawn valve pointing toward the root makes its chain a return (its ambiguous valves follow r5), one pointing away a discharge (its ambiguous valves feeds, `supplyLeg`); the only non-return chain out of the root is the discharge; (4) NO distances of any kind in classification (rule 2 reads hops; `nearestDrawOffVia` / plan pixels / metres deleted) — when two or more root chains stay plausible discharges with at least one UNDECIDED (only ambiguous valves: several such chains, or one beside a drawn-valve-only discharge — what a backwards return looks like), the sizer solves one scenario per undecided chain (it the discharge, the other undecided root valves closed; plus all closed beside a drawn-valve-only discharge; at most 4, else r5; a scenario whose closures starve a draw-off point is skipped; one survivor is read as is) and sizes EVERY edge of the component on the max |flow| over the surviving scenarios (direction and fixture units from that scenario), labelling those valves `CheckValveAmbiguity.envelope` (EN+ID 'Check valve direction unclear at the source — pipework sized for every plausible flow direction; draw the valve arrow to tighten'). A lone undecided chain beside only valveless / mover chains keeps r5 (closed unless that starves a draw-off point). MOVER LEGS ARE NEVER ZERO-FORCED OR REVERSED: a feed valve on a mover leg (off the root or between interior junctions) is exempt from the Hardy–Cross 'close a feed the balance runs against' path; when the solved flow runs against the leg's pump every leg edge stays open, sized on |flow| (mover duty = |flow|) oriented in the pump's direction (`_MoverLeg`, `orientMoverLegs`), and the valve is reported via `autoSizeNetwork(checkValveAgainstPumpOut:)` → the app labels it `balanceAgainstPump` on the same `check-valve-ambiguous:<id>` kind with its own EN+ID message ('Balance runs against the drawn pump'). The `check-valve-feeds-ring` trim reads plain hops (judge-only) and counts an envelope scenario's feed valve as a competitor that is never named, so the heater's own drawn discharge beside an ambiguous return is not named while a backwards return beside an ambiguous discharge is. `sizeZeroPockets` orients a zero-flow pipe the tree already holds (the first walk reaching it wins), never root-outward. Pinned drawing-invariantly (`round27_r7_check_valve_orientation_test.dart`): probe 1 (CVd + CV both ambiguous) => envelope, hm1 = curve(16) DN25 and each riser base curve(8) DN20 for return-riser offsets -20 / -10 / 0 / +20 px, a jogged main (M at y=60), calibrated or not, 2 or 3 risers, every edge == max(the two drawn readings); probe 5 (CVd ambiguous + H -> CV -> RJ) => envelope, discharge never zero, for every offset (r8: feeds-ring EMPTY — the winning reading of CV's pipes is the one where CV is the only feed); probes 3 / 4 and the drawn-back pump-leg valve as r6; the circulator-on-return (drawn or ambiguous CVr, both pump positions, calibrated or not); the reviewer's interior booster (T -> R0; R0 - R1 long; R0 - R2 - R3 short; R1 -> P -> CV -> R3) => leg flow > 0, direction R1 -> R3, reported, calibrated AND uncalibrated; a seeded property (pump legs off the root and interior, valved root chains) asserting every mover-leg valve passes flow (in its coherent pump's direction), every reading invariant to calibration, a jitter of every node's plan position and bare bends, and every size + zero-flow pocket invariant to a length-ratio-preserving redraw. Re-derived: the r4-regression hotel and the r5 'drawn discharge + ambiguous return' hotel are now the envelope (the supply keeps the open network, the return the feed reading — the mirror of probe 5, no distance may separate them); audit_r15's duty/standby flip trials keep the pumps' suction pipes drawn S -> P (a coherently backwards pump is honoured, not a drawing variant). **Residuals (recorded):** envelope sizing is conservative — it upsizes the alternate chain (a return sized as if it fed); probe 2 (an ambiguous valve on the real heater discharge beside a VALVELESS return) is topologically the r5 hotel with an ambiguous return, so it stays a closed return: the heater discharge and the supply main to the riser bases are DN15 until CVd is redrawn (named); a valveless duty/standby return (probe 4) still shares the heater outflow by Hardy–Cross, so each pump leg (duty, and the mirrored standby) is sized on 0.2215 L/s uncalibrated / 0.2402 L/s calibrated of curve(8) = 0.400 L/s — the valveless return carries the rest; whether the balance shuts a genuine (non-mover) feed valve, and every valveless ring split, follow real lengths by design (only the classification is drawing-free); rule 2 is bend-free (r8) — only a real node added to one side of a tie moves it; two ambiguous valves that starve a draw-off point only TOGETHER and sit on no root chain are still both reopened symmetrically. **r8 (binding orchestrator decision, builds on r7 — PRECEDENCE now: drawn valve > coherent mover INCLUDING a VALVELESS one > structural root-chain cue > envelope; a balance against a pump => envelope; rule 2 bend-free):** (1) BALANCE-AGAINST-PUMP ENVELOPE: a mover leg (valved OR valveless) whose balanced Hardy–Cross split runs against its coherently drawn pump is sized on the envelope of two scenarios — (a) the leg CLOSED (zero draw-off, the r4 closed-return treatment incl. `returnPlan` and `sizeZeroPockets`; a valved leg's valves become fixed returns, a valveless leg gets a pseudo return valve at its first pump: `_classifyLoopCheckValves(closedMoverLegs:)`, leg key = its sorted edge ids) and (b) the leg OPEN as balanced — every edge of the component on the larger |flow|; the leg itself carries (b)'s |flow| in the pump's direction (mover duty = that, never 0, never backwards through the pump). (a) is skipped when closing the leg starves a draw-off point (all against-legs closed together, else each alone). The tree path has no balance and keeps r7 (leg oriented + named). Pinned: the reviewer's header-return probe (H -> M -> S0..S3; S3 -> R3..R0 -> RJ -> CV -> Pr -> M, pump CV -> Pr -> M, CV drawn RJ -> CV or ambiguous, calibrated or not) => m = hm = curve(8) = 0.4000 L/s DN20 as on 4e5e9d9, the leg == the plain-ring flow in the pump direction, `CV` named; every edge == max(open network, plain ring). (2) VALVELESS MOVER LEGS ARE CLASSIFIER INPUTS: a pump / booster / supply fan drawn coherently (all movers on the chain agreeing) on a degree-2 chain with no check valve, on a cycle, is a `_MoverLeg` (`valveIds` empty, `pumpIds`); on a ROOT chain it is a structural cue — drawn toward the root the chain is a RETURN chain (not a candidate discharge, and never the path `check-valve-feeds-ring` judges a feed against), drawn away a discharge chain; an incoherently drawn valveless mover is a plain pipe. A valveless leg against the balance gets the decision-1 envelope and the judge-only, locatable info `mover-against-balance:<pumpNodeId>` (EN+ID 'Balance runs against the drawn pump'; `autoSizeNetwork(moverAgainstBalanceOut:)` -> `moverAgainstBalanceProvider`). Pinned: P-A (ambiguous CVd + valveless circulator RJ -> Pr -> H) => CVd `supplyLeg` (a feed), hm1 = curve(16) = 0.6533 L/s DN25, each riser main curve(8) DN20, the pump leg in its drawn direction, `Pr` named; P-L (drawn CVd + the same circulator) => hm1 curve(16) DN25, feeds-ring does NOT name CVd; a valveless circulator drawn AWAY from the heater is a discharge chain (an ambiguous CVd beside it keeps r5: closed). (3) RULE 2 IS BEND-FREE: the root distance is the `bendWeight` metric (a bare degree-2 node weighs nothing) between the valve's EFFECTIVE neighbours (`pastBends`: the first non-bend node past any elbows), so adding elbows to a drawn leg never flips FEED / RETURN — the dual feed T -> V1 -> J1 / T -> 4 bends -> V2 -> J2 reads both FEEDS with identical flows at 0 and 4 bends (== the plain-pipe ring); the seeded property compares every FLOW on the bends variant. (4) ENVELOPE HONESTY: a scenario's side outputs (`checkValveAgainstPumpOut`, `moverAgainstBalanceOut`, `checkValveFeedsRingOut`, `checkValveAmbiguousOut` labels, `loopUnbalanced`, `parallelLegEdgeIdsOut`) are reported only from scenarios that WIN at least one edge of the element they name — a valve: its two pipes; a leg advisory: an edge of that leg (the degree-2 chain through the node); an edge flag: that edge (a label no scenario wins keeps the first reading's, so an ambiguous valve is always named). Re-derived: probe 5's feeds-ring is now EMPTY — reading (B), where CV is the hotel's only feed, wins CV's pipes; CVd keeps its envelope advisory. **Residual (recorded, rule 2 — unambiguous valves, r8):** only a genuine metric TIE broken by a REAL node (a tee / an inline device / a fixture) on one side can move a drawn valve's reading; the r4 long-second-feed residual now needs a leg longer in real nodes (three tees each feeding a fixture: c2 / zc 0, m1 curve(8), x1 curve(12)) — the same leg made of bare elbows is a FEED split as plain pipes. **r8 review residuals (recorded, not regressions vs 4e5e9d9):** (i) the valveless-mover structural cue is ROOT-CHAIN only — an ambiguous heater discharge beside a valveless return whose coherent circulators sit on INTERIOR legs (R{k}_0 -> Pr{k} -> RJ, then a pump-free RJ -> H root chain) still reads the discharge as the r5 closed return (heater discharge + riser mains DN15, `mover-against-balance` raised on each pump), while the same pumps on the RJ -> H chain give curve(16) DN25 — candidate extension: a valveless root chain reached only through coherent movers pointing toward the root is a return chain; (ii) a circulator return landing ON the root is a zeroed return chain while the identical return landing on the first header gets the r8 envelope and prints the plain-ring share as its duty (the supply main is curve(8) either way); (iii) cosmetic: zero-flow pipes of two identical zeroed standby return legs can carry opposite `flowFromId` (the r4 first-walk-wins orientation), sizes unaffected.
- **Round 26 — one gravity-source rule, separate vent stacks, parallel recirc
  loops, honest riser canvas (2026-10-18)**: `gravityDownfeedDrawnProvider` =
  downfeed + a drawn supply network + a pickable source + a non-null
  `downfeedTankElevationProvider` — the ONE Round-23 rule (a roof tank, or a
  PLANT above the top-storey fixture; a bare top-floor main is never a tank),
  so an untyped top-storey 'Source / tank' is judged like a roof tank. A vent
  RUN joins two stack riser groups only as an OFFSET (one group's TOP to a
  different group's BOTTOM on one storey); any other run between groups is a
  HEADER that never merges them: it keeps its own load and bounds only the
  stack it DRAINS; the stack that RECEIVES it splits at the junction — risers
  above it (the shared stub to the VTR) keep their own combined load, the
  stack below keeps its OWN soil stack's size, whichever way the header is
  drawn (r2). Which end receives is read from the SOLVED vent tree (r3): the
  header's root-side endpoint receives, the other stack's air leaves through
  the header and it is drained — a dead stub above a mid-storey header (no
  VTR of its own) never makes a stack 'receiving'. A loop-CLOSING header
  (left out of the solved tree — a relief header below a roof header between
  the same stacks) neither receives nor drains: its closing-rule load is a
  conservative artifact, never subtracted from or bounding a stack (r4; it
  used to thin a 40-DFU stack to DN50). An open VTR (a vent leaf at a
  riser's upper end, or — r4 — a bare leaf reached by a RUN from a stack top
  on the component's top storey, joined by nothing else) is load-free — the
  second VTR of a headered pair never takes the 2-DFU leaf default — and a
  run VTR is the stack's roof termination: it counts in the uniform stack
  like a shared riser (its load less the header load entering the stack) and
  never prints below the stack, so a degree-1 run VTR off the stack top
  sizes the stack exactly as a VTR riser does. Recorded residuals (r4
  review, pre-existing, under-size direction): a roof header whose one VTR
  hangs from a BARE mid-header node (stack top -> HX -> other stack top,
  HX -> VTR) leaves the top-floor tie bypassing every riser, so the stack
  sizes one DN small; and the run-VTR rule keys on the COMPONENT's top
  storey, so a component mixing a riser VTR and a run VTR misses the run one
  (+1 DN on the other stack). A hotel return teed AT / BEYOND an inline top
  fixture keeps the right trunk but Hardy–Cross shares draw-off up its return
  risers, which can leave a second riser BASE one DN small. Pre-existing residual (r4): a vent component with NO VTR at all
  sizes both headered stacks on the combined load (over-size on an invalid
  design). RETURN check valves (r4, binding): when every cycle check valve
  of a pressurized component is a RETURN valve its two edges are ALWAYS out
  of the Hardy–Cross loop set and sized at zero draw-off, `flowFromId` in the
  physical return direction (up-node -> valve -> down-node) — the Round-12
  principle — whatever the return-side walk decides. The walk grows the
  return side ONLY from each valve's upstream node through draw-off-free,
  off-supply nodes over edges on no shortest root -> draw-off path; those
  edges are deferred with the valve when the walk meets no DRAW-OFF node and
  the remainder is a forest (hotel return trees teed at the riser top / a
  bare branch tee keep their tree cut). When the walk meets a draw-off node
  (a ring teed at a fixture or a bare tee between inline fixtures, a hotel
  return teed AT or BEYOND an inline top fixture) the return side is not
  grown and Hardy–Cross runs on the REMAINDER without the valve — never on
  the network including it (r3 routed ~40 % of the peak forward through the
  return valve and sized the heater feed one DN small). The walk heuristic
  CANNOT discriminate a return riser from a ring segment — a hotel return
  touching an inline top fixture and a ring whose tee-adjacent nodes are all
  bare (fixtures on stubs, the commonest Run-tool drawing) are topologically
  the same, and BOTH orientations of the ambiguity exist (the hotel then
  splits draw-off up its return risers; the all-stub ring collapses to the
  hop-count tree) — which is why the valve cut is unconditional: the heater
  feed carries curve(total UBAP) and every valve edge 0 in every case; only
  the ring-vs-return split of the ambiguous segment stays heuristic.
  Hot-water recirculation is PER COMPONENT
  (`hotWaterRecircSystemsProvider`; one way / schedule row / report line each,
  a drawn HW pump takes its own system's duty; ONE primary = the largest
  recirc flow ∝ circulated + assumed-return length, in the provider AND
  `hotWaterRecircLoop`); parallel drawn loops carry
  heat-loss SHARES (`supplyPathFlowShares`, shared trunks the sum, index loop
  by Σ s^1.852·L/D^4.871); the index run is Dijkstra (never hop order); with
  no return drawn AND no hot-water pump drawn, recirculation is assumed only
  above `kRecircMinDevelopedLengthM` (15 m, IPC 607.2, `// VERIFY`) — a drawn
  HW circulator is an explicit recirculation signal and is never silenced
  (r2) — and the
  assumed DN20 return + pump are taken off flagged `assumed`. The HWR leg is
  drawn only for an ASSUMED return (`hotWaterAssumedReturnProvider`), one per
  riser STACK, the HWR PUMP at the whole network's lowest HW riser node and
  never beside a drawn HW pump. A partial genset with NO essential board
  screens every motor (`gensetStartMotors` restricts only on an essential
  designation). The diversity library never overrides `demandFactorUserSet`
  or a 0 factor. The Ics test (`_icsShortfall`) runs on the incomer, every
  way and every feeder, once per device. Live riser canvas: arrows are
  `riserArrowPath` (apex at the tip) pointing along the SOLVED flow
  (`riserFlowGoesUp`); the band diagram sits in a frame (left gutter for the
  FFL / fan-out labels, right column for the plant detail + notes, bottom
  strip for the callouts); coincident nodes spread by the shared
  `coincidentSpreadDx`; node glyphs + labels and riser tags go through the
  collision list; the fan-out is grouped (`WC x2`) and the plant detail
  carries the ground tank.
- **Round 25 — legacy provenance, honest fault estimates, connected daya, no
  override reducers, uniform vent stacks, one drawn feed (2026-10-18)**: in a
  LEGACY file a demand factor 0 on a NON-life-safety MEP way is typed (pre-r23
  feeds minted 0 only on a life-safety standby) — kept, flagged, parked never
  dropped (`_isMintedDemandFactor`); a PARKED way (`kMepParkedNameSuffix`) is
  provenance-stamped like a derived one and stays legacy until re-adopted. Past
  the DXF primitive cap an INSERT grows the bounds by its block's memoised
  extent (4 transformed corners) — never re-walk a block body bounds-only. A
  declared LV capacity above the PLN TR ceiling estimates its OWN transformer
  fault (`S/(√3·400·0.04)`), never below the study transformer for the demand
  nor 16 kA: more information never lowers a safety quantity. The accessory
  takeoff and the schedule DAYA read the UNDIVERSIFIED
  `ElectricalCircuitResult.connectedW`; `loadW` stays the diversified demand. A
  gravity edge below a hand-OVERRIDDEN pipe is raised (or, if itself
  overridden, flagged `belowCodeMinimum`) — no reducer in the direction of flow
  (`_clampGravityDownstreamOfOverrides`). A vent offset run between two stack
  riser groups and the base run to the soil-stack foot are part of the vent
  stack (uniform size); a zero-seed vent tie stays an explicit 0 (no phantom
  leaf DFU); a fixture vented at its own node has a 0 trap arm. ONE drawn-feed
  predicate (`gravityDownfeedDrawnProvider`, a drawn gravity source — a roof
  tank, or a PLANT above the top fixture, Round 26) gates the
  inspector headline / rows, the report and the Review `downfeed-below-target`
  warning (→ the 'Supply pressure' compliance row); a meter-fed water network is
  the acknowledgeable `mains-fed:<service>` info, never `no-source`. An empty
  project carries a failing 'Design content' compliance row (n/a details, never
  PASS). Acknowledgements are ONE `UndoDomain.settings` step. Drawn tanks are
  scheduled (`EquipmentCategory.tank`). The fire-duty note names an MCCB / ACB
  by class (no curve letter) and a non-pump life-safety motor a 'motor way'.
- **Round 24 — migration, honest drawings, TT RCD topology, import
  integrity (2026-10-18)**: a `.mechx` MEP way without the `mepProvenance`
  key is LEGACY (`ElectricalCircuit.legacyProvenance`, decode-time only): the
  first sync keeps (and flags user-set) any cos phi / phases / load kind /
  demand factor that differs from the mint — never revert a legacy file's
  typed character. A sku-less BOM line consolidates on its `priceKey` too
  (an unmatched breaker's kA never merges away). Every printed incomer goes
  through `incomerOverRangeSuffix`. The plan DXF declares `$LTSCALE`
  (`dxfLtScaleFor(N)`, dash = the PDF's 6 pt on paper); a sized duct ≥ 1 mm
  wide on paper is drawn true-width double-line (`planDuctWidthM`); an
  annotation that can only overprint is COUNTED (`unresolvedCount` →
  `overlapCount`) and the sheet prints `planOverlapWarning` — never silent.
  An off-sheet electrical feeder is an `ElectricalPlanRiser` + an unplaced
  line, never dropped; electrical route figures use the shared plan placer.
  A TT feeder RCD takes the highest RCD type below it, steps `ttFeederRcdMa`
  per RCD-feeder level below (≥ 3 × IΔn), and is omitted (RCM) over a
  life-safety-only sub-tree. A TN main earthing conductor is
  `tnMainEarthingConductorMm2` (service PE × runs, uncapped); the 16..50
  clamp is the TT electrode conductor only. SPD distance is from the nearest
  upstream recommended SPD. A DXF coordinate that is not finite is absent;
  polyface / mesh POLYLINEs are skipped; a budget-truncated parse sets
  `DxfDrawing.truncated` (bounds complete) and the import says so. A DXF
  sheet maps world → content through `Sheet.dxfFrame` (painter, snap,
  underlay); a scale is transferred between sheets only via
  `transferCalibration` (DXF → DXF rescaled by the frames, mixed skipped);
  Replace-all keeps a surviving sheet-with-work on its old floor.
  Round 24 r2: a frame change is flagged ONCE per real change — the
  detector compares the live extent against `Sheet.dxfFrame` AND the
  acknowledged `Sheet.dxfLiveFrameAck` (recorded with the stale flag by
  `SheetsController.reportDxfFrameChanged`), so 'Scale confirmed' survives
  remounts and reopens; the Layout content cache keys on the whole sheet
  source (`layoutContentCacheKey`). A TT feeder's sub-tree RCD TYPE always
  propagates upstream (a life-safety feeder skips only the level count).
  A legacy MEP value equal to an old mint (`defaultMotorCosPhi`, a kind in
  `kMepMintedLoadKinds`) is machine-owned, never flagged typed.
  `DxfDrawing.truncated` only when an INSERT is actually refused (budget,
  array cap or depth). The plan DXF double-lines ducts only on a real
  plotted scale (`plotN != null`), like the PDF.
- **Round 25 follow-up — no vacuous pressure PASS, no phantom tank**: the
  compliance 'Supply pressure' row claims BOTH `downfeed-below-target` and
  `upfeed-below-target` (raised when `solvePressurized` reports
  `targetHeldByDesign` false and the critical delivery residual is below the
  target — a reducing PRV). `residualByNodeProvider` (heatmap / probe) and
  `downfeedOverPressureProvider` are empty on a downfeed setting with no roof
  tank drawn (`gravityDownfeedDrawnProvider`).
- **Every `BreakerClass` consumer is EXHAUSTIVE (Round 23 r2)**: an ACB is
  never sized, timed or labelled as an MCB — switch on the enum / `.code`,
  never `name == 'mccb' ? … : <mcb>`. ACB frame 330 mm (`acbFrameWidthMm`,
  >= the widest MCCB band), ACB pole loss 60 W, arc-flash clearing time
  `arcFlashClearingTimeS` MCB 0.05 / MCCB 0.2 / ACB 0.5 s (`// VERIFY`); a
  BOM line names a curve letter only when `hasTripCurve`. Typed electrical
  character is PROVENANCE: `setCircuit(cosPhi:/phases:/loadKind:)` sets
  `cosPhiUserSet` / `phasesUserSet` / `loadKindUserSet` (like
  `demandFactorUserSet`) and the MEP sync never re-derives a flagged field.
  The electrical layout DXF stamps the PDF twin's own snapped `1 : N`
  (`electricalPlanPlottedScaleDenominator` → `plottedScaleDenominator`).
- **Round 23 — held-by-design is falsifiable, MEP ways stay put, issued documents stay legible (2026-10-18)**: `solvePressurized` claims `targetHeldByDesign` only while no drawn PRV REDUCED the field below the target — a reducing PRV re-picks the least-residual delivery node as critical and the verdict turns falsifiable. `downfeedTankElevationProvider` is non-null only for a REAL gravity source on downfeed (roof tank / plant above the top fixture; nothing drawn ⇒ the declared roof datum); upfeed and booster-only downfeeds use the PRV-budget walk. An MEP-derived way never leaves the MEP board (`moveCircuit` refuses) and the sync never mints an id another board holds; a refresh re-derives phases / load kind / cos φ / an app-supplied name; a demand factor is the engineer's once `demandFactorUserSet` (provenance, never value inference); standby pumps (fire, supply on a mirrored leg, parallel HW recirc) carry the duty machine at df 0; electrical undo / redo / restore re-sync the MEP board and the duty-feed switch is undoable. `ElectricalSystemResult.order` is PRE-order (siblings in model order). The breaker ladder runs on to ACB frames (2000-4000 A, `// VERIFY`) and a saturated incomer always prints `OVER RANGE`. Report PDFs: WinAnsi fonts, wrapped cover runs, whole-word table columns, figures never below 5 pt (tiled), headings keep with their body. Electrical riser / overview PDFs paginate below 7 pt (floor ranges / sub-trees); the layout DXF is in world mm when calibrated; one-line skip lanes never share a stretch.
- **Round 22 — standpipe per riser, tank-fed top zone, inline devices on both
  solves (2026-10-18)**: `hydrantDesignFlow` is the multi-riser TOTAL and
  rides only the common supply; every hydrant riser / trunk carries
  `standpipeFlow(n)` for the n stacks in parallel downstream of it (one stack
  ⇒ 500 gpm). `drawnStandpipeRiserCount` counts PARALLEL stacks
  (`parallelStandpipeCount`: max components over any storey interval) — a
  jogged stack counts once. A bare VENT junction on the top storey reads the
  roof (VTR); drainage / rainwater keep the under-slab datum. A paginated riser
  prints each riser tag once (on its lower end's page) and draws a pass-through
  on every page it spans. Every FFL goes through `signedElevationText`. The
  downfeed TOP zone is fed by the tank head (`computeDownfeedZones(
  tankElevation:, maxFixtureStatic:)`, `DownfeedZoneStatic.viaPrv` false) —
  never budget it on a PRV setpoint; only zones below take PRV stations, and the
  zone table shows only when one is needed (or a zone is over). Drawn PRVs hold
  their setpoint on BOTH solves (`_applyInlineDevices`); a sized booster's head
  is applied by `solveDownfeed(moverHeads:)` — the app's
  `downfeedDeliveredProvider` feeds the heatmap / probe / over-pressure judge,
  `downfeedProvider` stays the unboosted sizing input. Hot water always takes
  the flush-TANK curve. MEP-derived ways' `loadPos` is never remapped by a
  floor edit (re-derived by `resyncMepEquipment`), derived ways / the MEP board
  refuse delete / merge, and the auto-wired MEP feeder id is
  `kMepEquipmentFeederId`.
- **Round 21 — nested rooms, fire pumps + pipe, family-true BOM, legible
  risers, a gravity datum (2026-10-18)**: the generating-room tag
  (`roomTerminalOwnerOf`) wins only outside a smaller same-kind room — a
  terminal a later-drawn nested room contains is that room's, so the outer
  room goes stale rather than silently doubling the air; Auto-place keeps the
  legacy grid and substitutes only a blocked cell by the nearest free cell of
  the first denser grid. `standardMotorKw` runs to 315 kW (IEC frames); a
  fire-pump way sizes on `max(nameplate / η, governing input)` and a clamp
  raises `fire-pump-motor-oversized`. The standpipe flow counts the DRAWN
  hydrant riser stacks (`drawnStandpipeRiserCount`, ≥ 1) off the throttled
  sizing network. Parallel fire pumps are duty / standby / jockey
  (`parallelFirePumpRoles`): standby ways carry demand factor 0, the jockey
  its own `fireJockeyDutyProvider` duty, one schedule row per drawn pump.
  Fire pipe sizes on `maxFireVelocity` (6 m/s, `// VERIFY`) with the code
  floors; domestic water keeps 2 m/s. A cable FAMILY never falls back to
  another family's SKU (unmatched ⇒ `elec:cable:<family>:<n>x<csa>`);
  enclosures price per W x H x D; `advancedBomLines` takes off control gear,
  genset + ATS, SPDs, rods and the BC conductor. A mechanical BOM line counts
  its `unmeasuredSegments` (any > 0 ⇒ flagged, never a measured total);
  drawn components are taken off (`buildComponentTakeoff`), an inline
  terminal sits on a tee, rect fittings key / print W x H. A riser PDF that
  prints below 7 pt paginates (`paginatedRiserSheets` /
  `buildMechanicalRiserSld(floorRange:)`, `LANJUT KE <floor>` stubs); the
  issued riser carries the HWR leg whenever the canvas does. A GRAVITY riser
  reads a bare stack junction under its floor's slab
  (`gravityRiserEndElevation`: ceiling of the floor below; on the lowest
  level the lowest SLAB — grade with no basement, the lowest basement slab
  when `groundIndex > 0`); pressurized risers keep `nodeElevation`. Every
  riser length — `edgeLength`, the Riser canvas label, the Riser summary
  Σ, the node inspector elevation — goes through ONE `riserEndElevation` /
  `riserElevationDelta` (canvas == BOM == export). A fire pipe's velocity
  verdict uses the SAME `maxFireVelocity` the sizer used (never the 2.0 m/s
  domestic cap); a fan group in the riser drawing is keyed by the shared
  header whichever way its runs are drawn; an ASSUMED jockey fire pump
  (≥ 3 identical pumps) raises the info `fire-jockey-assumed:<id>`.
- **Round 20 — generating-room tags, owner rooms, undiversified phase,
  drawn feed, verdict-backing figures (2026-10-18)**: an Auto-placed terminal
  carries `NetNode.autoPlacedRoomId`; ownership is `roomTerminalOwnerOf`
  (that tag while the terminal sits in the room, else
  `roomTerminalOwnerId`) for BOTH the Auto-place clean-up and the stale
  judge, and the outer room's grid never drops a terminal inside a nested
  room of the same kind. AC units / AHU / FCU belong to their SMALLEST
  containing room (`roomUnitOwnerId`, tie on id) in the feed, schedule and
  Rooms inspector — never the first room in list order. A drawn AHU / FCU is
  scheduled ONCE: its solved duct duty row, or — only when no unit the room
  owns has a solved duty — the room-air row for the unit
  `roomAirUnitDutiesProvider` names, which the panel also feeds
  (`NodeLoadSource.roomAir`). The report's HVAC trunk is never an AC-rooted
  system. A FINAL way's Auto phase reads its undiversified `c.loadW`
  (diversity never moves a machine across the 3φ threshold); the `cap` cell
  marker needs a capacitor way / capacitor-floored fed board. The calc
  report's feed line, booster head and PRV zones follow the DRAWN feed (a
  roof tank for 'downfeed'; else booster / direct mains, no head, no zones).
  ADS 3-dp figures round in the verdict's direction. Re-kinding a way
  re-derives `isLighting` unless the edit sets it. Riser leaders prefer a
  square exit over a run along a pipe (second-tier cost, never above a label
  collision). Schedule currents and every printed length use one fixed
  0.1 precision; board legends key only printed tokens.
- **Round 19 — recirc returns, one room per terminal, one essential set,
  BOM = schedule, tolerant decode (2026-10-18)**: a hot-water cycle is the
  drawn RETURN only when it passes through the source / a plant or carries a
  check valve — a stub-fed ring main keeps the heater feed + the mirrored DN20
  return (`hotWaterRecircLoop`). Each air terminal belongs to ONE room
  (`roomTerminalOwnerId`: smallest COMPATIBLE room — diffuser / return grille →
  conditioned, exhaust grille → extract-only — else smallest containing),
  shared by the `room-terminals-stale` judge and Auto-place's idempotence
  filter. Essential-by-name strips NEGATED words (NON / TIDAK / BUKAN +
  essential word) and is read by genset backing, the SLD colours AND the
  `life-safety-not-essential` judge. A rainwater downpipe raised to the bore of
  an UNSATURATED collector carrying its whole flow clears the table-top
  `overCapacity` (`// VERIFY notAnSniClause`). The BOM honours the schedule:
  RCDs only of at least the specified type (B > F > A > AC; untyped parts never
  satisfy a typed spec; S-type only for `RcdSpec.timeDelayed`), exact poles
  first; breaker poles follow the schedule (1φ feeder off a 3φ board = 2P);
  rating mismatch outranks curve; any class / rating / curve / pole departure
  sets `BomLine.deviceSubstituted` + a `(catalogue part: …)` note and keys
  apart on consolidation; lugs follow `grounding.cores` and each conductor's
  own section. A diversified board prints its DIVERSIFIED current beside its kW
  and labels the undiversified sizing current (`15.8A div (max ph 17.5A
  undiv)`; diversity 1 ⇒ unchanged); a capacitor way / bank-only feeder prints
  its run current marked `cap` and a bank's DAYA in kvar. The
  `cable-ampacity-inadequate` message prints the failed `max(In, 1.25 × Ib)`
  (`CableResult.izRequired`) and says `In > Iz` only when true. The `.mechx`
  decoders drop / clamp out-of-band numbers (calibration ≤ 0, negative roof
  area / airflow / tank / load, non-positive face / size override, room ACH /
  ceiling, commercial markups, solar DC:AC ≤ 0) into the bands the store
  setters enforce. The smart-input bar and the 1 : N scale type-in parse
  through `parseLocaleNumber` too.
- **Round 17 follow-up invariants**: a DRAWN hot-water return is part of the
  circulated pipework, so `hotWaterRecircLoop` takes the drawn cycle as THE
  loop (`returnLengthM` 0, `drawnLoopLengthM` = the cycle) — the mirrored DN20
  return is only for tree-only HW; never add it on top of a drawn loop. A
  gravity override smaller than the auto pick (the code minimum) sets
  `EdgeSizing.belowCodeMinimum` (→ `belowCodeMinimumEdgesProvider` → the
  `gravity-below-code-minimum` warning) — never let an override inherit the
  auto pick's clean flags. The DFU tables run to DN300 (IPC 710.1(2),
  `// VERIFY`); `overCapacity` only past the DN300 row. Roof / floor drains and
  cleanouts sit ON their surface in `nodeElevation` (roof drain on the top
  storey at the roof). No gravity invert / IL datum exists anywhere — the live
  draw chip states the datum-free fall only. Gravity RISERS get no velocity
  verdict and the inspector's drainage floor repeats `selfCleansingOk`. Every
  printed fire-pump head is the governing `fireRatedPointProvider` point. The
  inspector Ib is `runCurrentA` (the report's Ib). Essential-by-name is ONE
  `isEssentialByName` (EN + ID words) for genset backing AND the SLD colours.
  Every engineering number field parses through `parseLocaleNumber`
  (ID `.` groups thousands) and never re-commits an untouched display.
  A ghost node (its sheet's floor ≠ its floor) is re-homed onto the sheet
  mapped to its floor after every sheet-mapping change; a kept-span clone
  (paste with a riser, stamped assembly) puts each off-floor node on its
  floor's sheet.
- **Round 16 — movers in series, valves by topology, supply by one study**:
  a cycle check valve is oriented TOPOLOGICALLY first (root-reachable side with
  all cycle valves cut = inlet), the drawn direction only as the tie-break
  (SUPERSEDED by the Round 27 r3 binding rule — see the Round 27 row: the
  drawn direction is authoritative when unambiguous, each valve judged with
  only itself removed; the all-cut topological reading survives only as the
  last fallback for an ambiguous valve and for a self-contradictory set of
  returns, so one duty/standby leg drawn header -> valve -> pump is now a
  pinned, zeroed return);
  an air-unit plant's bare intake leaf bears no load and carries the unit's
  delivered airflow inward (`// VERIFY` 100 % OA); `riserFunctionFor` reads the
  SOLVED flow path when `flowFrom` is supplied (TRANSFER = mover with a tank
  downstream, GRAVITASI = roof tank with no mover between, never a tank inlet).
  App: `supplyMoverDutiesProvider` is THE per-mover pump duty map (series heads
  via `seriesMoverHeads`, transfer lift via `transferPumpHead`), read by the
  feed, schedule and riser; `pumpDutyProvider` is its primary (largest-flow
  non-transfer) entry. The HW recirc loop is circulated pipework only, head =
  index run at own bores + DN20 return. An air system's unit is chosen by role
  (fan → AHU, never a terminal unit). A packaged AC is fed its room-PK input.
  Genset rating covers max(S, P/0.8); battery on demand W; installed kvar
  enters the PF study; `determineSupply(declaredKva:)` / `serviceTransformer`
  are the one transformer source; an undeclared MV demand takes the study
  transformer's fault at the ONE 4 % impedance. A drawn PRV holds its setpoint
  in `solveDownfeed`, and downfeed delivery nodes are over-pressure judged.
- **Round 11 electrical rules (2026-10-18, seed suite
  `round11_electrical_test.dart`)**: (1) PVC ampacity RANKS BY METHOD like XLPE
  — conduit = IEC 60364-5-52 Table B.52.4 B1 (16 mm² = 68 A), wall = column C,
  air / tray = the Supreme method-E table; PVC B1 ≤ C ≤ E and PVC ≤ XLPE per
  method for every section (a property test) — never read the "in air" table for
  conduit again. (2) A `LoadKind.capacitor` way draws NO real power:
  `circuitConnectedW` returns 0 and `_balanceCurrentA` drops it from the phase
  balance / incomer current (the bank OFF is the worst case); its own device +
  conductor size on `kCapacitorSwitchingFactor` 1.43 × Ib (`// VERIFY`, IEC
  60831-1 1.3 × 1.1). (3) The FOLD-2 neutral steps the profile's copper
  FLAT-BAR ladder (`copperBusbarTable`), falling back to `ceil(target)` — never
  the cable ladder, never collapsing to the phase size while the factor is > 1.
  (4) TN ADS: the governing Zs limit is the more lenient of the overcurrent
  device and the way's RCD (`Zs·IΔn ≤ U0`, IEC 60364-4-41 411.4.5,
  `CircuitFaultResult.adsByRcd`), and the magnetic multiple follows the
  PERMITTED disconnection time — 5 s (`curveTripMultiple5s`, D = 10 × In) for a
  feeder or a final > 32 A, 0.4 s (`curveTripMultiple`) otherwise
  (`adsDisconnectionTimeS`, `// VERIFY`). (5) A VFD way passes `hasVfd` to
  `circuitRcd` (TT ⇒ Type B). (6) The genset motor-start dip screens only the
  motors the genset STARTS: the essential sub-tree (`gensetBackedPanelIds`)
  whenever the set backs a fraction or any board is essential
  (`gensetStartMotors`).
- **Source-delivered flow + one duty per air system (Round 11, `solve_store`)**:
  a fan / pump duty runs on the flow LEAVING its source node —
  `sourceDeliveredFlow` = Σ of the sized root-incident edge flows (water: the
  summed UBAP re-diversified ONCE through the demand curve on the sizer's
  `supplyFlushSystemProvider` branch, never below the largest branch; a single
  incident edge is verbatim ⇒ single-trunk layouts byte-identical). Never size a
  fan / pump on the single largest edge. Every connected component of an air
  service is its own system (`airSystemsFor`, sorted largest first) with its own
  duty (`supplyFanDutiesByRootProvider` / `exhaustFanDutiesByRootProvider`,
  keyed by root); `ductFanProvider` / `exhaustFanProvider` are the PRIMARY
  entries, the equipment schedule + the electrical feed consume every entry, and
  `airBalanceProvider` sums all systems.
- **Extract rooms (Round 11)**: a toilet / commercial kitchen
  (`isExtractRoomType`) is sized `extractOnly` — the ACH airflow is an EXHAUST
  bank (`RoomAirResult.return_`/`extract`) on a plain exhaust fan (duct + extract
  grille loss only, no supply bank, no AHU/FCU duty) and auto-places
  `exhaustGrille` nodes only. Its air is never supplied as conditioned air nor
  recirculated (`// VERIFY notAnSniClause`, in the ventilation verify list).
- **No non-finite value reaches the model (Round 11)**: every numeric field
  commits through `ElectricalNumInput.rejectionFor` (finite first, then each of
  `min` / `max` on its own) or rejects non-finite in the optional input; the
  store setters (Supply/source intents, `setCircuit` via `isValidCircuitEdit`)
  refuse NaN / Infinity / negative loads / non-positive lengths / cos phi
  outside (0, 1]; formatters (`isFormattableScale`, `parseMoneyInput`,
  `_fmt`/`_editValue`) never `round()`/`toInt()` a non-finite double. A NaN in
  state makes `jsonEncode` throw, i.e. an unsaveable project — Save's baseline
  encode is guarded too. The copilot decoder records malformed required fields
  (`AiCommand.invalidFields`) and `_validate` rejects them, off-sheet points and
  a floor ≠ the sheet's mapped floor; a no-op auto-place is a skip.
- **Sizing is ORDER-INDEPENDENT (round 7 property suite `audit_r7_*`)**: shuffling
  nodes/edges or renaming ids never changes a size, head or verdict. The root
  ladder is physical + id-tie-broken (plants never bear leaf demand; gravity at
  the lowest demand-free leaf, vent at the highest); looped-water BRIDGE edges
  size on their own far-side UBAP; heads/fan static take the max upstream
  friction over the SIZED flow direction (`oriented_paths.dart`); Hardy-Cross
  uses a min-resistance spanning tree + a simultaneous Newton loop solve.

- **A run's length includes its vertical leg (`network.dart` `runVerticalLeg` /
  `edgeLength`)**: a RUN between nodes at different CONNECTION elevations
  (`runConnectionElevation`: ceiling air terminals + sprinkler heads at the
  ceiling, plumbing fixtures at fixture height; gravity drainage/vent/rainwater
  runs carry no leg) is its calibrated horizontal span PLUS that elevation
  delta — pipe the installer buys and friction the water sees (the static lift
  stays a separate solve term, never double counted). The plan `CL` label
  (`runCentrelineLabels` = `planEdgeElevationLabels`) states the hanging height
  of the horizontal leg at the MAIN plus `drop N.NN m`, never the mean of the
  two ends; an uncalibrated run stays zero (never a vertical-only figure).
- **The PE is stated ONCE, inside the cable (`electrical_sld_drawing.dart`
  `cableRunLabel`)**: `grounding.cores` counts live + N + PE, the earthing model
  sizes that cable and the BOM procures it, so every schedule / feeder label
  prints that count with no separate `+ NYA/BC` earth token
  (`NYY 3x4 mm2`); parallel runs print `Nx(...)`. Round 19: callers pass the
  solved `peCsaMm2` / `neutralCsaMm2`, so a reduced PE / neutral prints the
  grouped make-up the BOM orders (`NYY 4x35+16 mm2`, `NYY 3x70+35 mm2`), never
  every core at the phase section.
- **Plan labels: one layout, gravity runs carry no CL**: the plan PDF and DXF
  lay out every grid/UP-DN/tie/run/riser/equipment annotation through ONE
  `layoutPlanAnnotations` (paper-mm units, the DXF takes the PDF's
  `planSheetPlot` scale) and place tags via `placePlanLabel` (beside its own
  run first, then a two-line split, then a capped leader); round sizes print `Ø`
  in PDFs / `%%c` in DXF; gravity (drainage/vent/rainwater) runs print size +
  length + `1:N` fall but never a `CL` (no sub-slab/invert model exists).
- **Every DXF string goes through `dxfText`** (drawing_chrome.dart): R12/AC1009
  with ASCII-only text (`·`→`-`, Ø→`%%c`, °→`%%d`), so AutoCAD never shows `Â·`.
  Compare PDF==DXF label parity THROUGH the encoder.
- **Fire pump: one governing duty**: `firePumpDutyProvider`'s `selectedMotor` is
  the NFPA 20 pick (it carries the 150 % overload point) and its
  `motorInputPower` is taken at that governing point; the electrical feed, the
  FP-01 schedule row and the Fire inspector headline all read it.

- **Plant elevation is role- AND component-aware (`network.dart` `nodeElevation`)**:
  an explicit `elevation` / `mountHeight` wins; otherwise pump / groundTank /
  boosterSet / AHU / supply+exhaust fan sit on their OWN floor surface, FCU and the
  AC units at their floor's ceiling, and only a roofTank at `roofElevation`; an
  UNTYPED plant ('Source / tank') sits on its own floor surface below the top
  storey and at the roof only on the top storey (Round 17 — an L0 upfeed source
  at the roof dropped the building height out of the pump head). Upfeed static lift therefore includes the building
  height (audit 2026-10 wd-1 — it was ~70 % low). Plan `CL` labels render this
  same elevation (`planSettingOutElevation`); only a roof-parked plant falls back
  to its floor ceiling so no label exceeds the storey. Both pressure solves pick
  the critical node from DELIVERY nodes (fixtures → open leaves → all) and every
  length consumer threads the project `MountingHeights` (printed == solved).
- **Round 17 invariants (protection, air intakes, riser drafting, fire basis)**:
  the MAXIMUM (Icu / withstand) prospective fault decays through feeder R at
  20 °C (`coldMaxFaultImpedance` = the 70 °C table × (β+20)/(β+70), IEC 60909-0)
  in BOTH `faultStudy` and the Fold-1 decay — the ADS earth-fault loop alone
  keeps 70 °C × `zsFaultTempFactor`; never feed the 70 °C table into an Icu
  decay. A safety quantity is never clamped DOWN: the service-size fault
  estimate is unclamped and flagged above `maxEstimatedServiceFaultKa`. The
  earth-electrode array is BS 7430 in-line (`η = 1/(1 + λ(n)·α)`, never a fixed
  η table). A FORCED genset is judged on kVA AND on kW = 0.8 × kVA
  (`genset-below-essential-power`). The air INTAKE walk passes through degree-2
  inline dampers to the bare leaf, and a bare leaf that is the intake of a
  demand-free terminal air unit never roots (the unit does). The riser FUNCTION
  suffix (GRAVITASI / BOOSTER / TRANSFER) is cold / hot water ONLY; every RUN
  sits on its own service lane (`riserEdgeLaneOffsets`, export + canvas); the
  feed note follows drawn equipment (`riserFeedNote`, never 'gravity downfeed'
  without a roof tank); pump-set captions are one per domestic mover
  (`plantMoverCaptions`, TRANSFER for a transfer pump). A downfeed PRV holds
  `defaultPrvSetpoint` (target + 30 kPa, `// VERIFY`) in the drawn-PRV solve,
  the zone sizing AND the zone table — one figure. Each calc-report fire
  section is gated on ITS drawn system, and the fire pump is rated on the
  governing DRAWN system (`fireRatedPointProvider`: sprinkler-only ⇒ the
  remote-area demand at lift + branch pressure + 15 m). The calc report lists
  every scheduled supply mover (`CalcReportData.supplyPumps`); the electrical
  report's Ib is the way's RUN current (`ElectricalCircuitResult.runCurrentA`).
- **Drain / vent code floors (Round 9, `drainage_sizing.dart` + `_sizeSanitaryEdge`)**: the vent table is UPC 703.2 (DN32 ≤ 1, DN40 ≤ 8, DN50 ≤ 24, DN65 ≤ 48, DN75 ≤ 84, DN100 ≤ 256, DN125 ≤ 600, DN150 ≤ 1380 DFU) and a vent is never below ½ the drain its load requires (`ventDiameterForDfu(servedDrainMm:)`); a drain carrying > 2 WCs on a run / > 6 on a riser floors at DN100 (`minDrainMmForWcCount`, the WC count accumulated down the tree), 1–2 at DN75; a drain downstream of a floor drain / shower / urinal floors at DN50 (`kMinTrapDrainMm`). All `// VERIFY notAnSniClause` in the checklist. The drainage advisories are per DN: min slope ≤ DN65 2 % / DN75–150 1 % / ≥ DN200 0.5 % (`minSelfCleansingSlopeFor`), and the length check is a TRAP-ARM walk (`trapArmRuns`, fixture → first vent/stack/root, summed over segments) against IPC 909.1 (`maxTrapArmLengthM`) — never one drawn segment against a flat limit. A zero-flow AIR edge is left unsized (`sizeNetwork`); the sizer records each tree edge's UBAP/DFU via `fixtureUnitsOut` (→ `edgeFixtureUnitsProvider`, the run schedule's basis column).
- **Floor-stack edits keep sheets with their work (Round 9, `project_store.dart`)**: a growing stack pins every sheet whose clamped floor would move (`_pinSheetFloors`); a shrinking `setFloors` drops the top floors exactly like `removeFloor` (work deleted, never clamped onto the new top) and callers confirm with `elementsAboveFloor`. A pasted riser keeps its floor span (clamped; a riser clamped onto one floor is dropped). A dragged / trimmed PLAIN run end never joins another service's run (E1). The MEP sync refresh re-derives `loadPos`, `lifeSafety` and a still-minted cable family (`_refreshedMepWay`); copies off the MEP board are user-owned (no `sourceEquipmentId`); moving an MEP-derived way off it is refused (`mepDerivedWayMoveLocked`) — feed the MEP board from the target panel instead.
- **Source-root ladder + parallel legs (`network_sizing.dart`, Round 14)**: on
  a pressurized/air service the root is a degree-1 ground tank, then an INLINE
  ground tank, then a degree-1 roof tank, then any other plant
  (`_supplyPlantRank`); an INLINE pump / booster / supply-or-exhaust fan never
  roots while another plant or a demand-free entry/outlet leaf exists (ties
  never fall to node ids for these cases; `airSystemsFor` still reports the
  drawn fan as the duty node). On drainage an inline ground tank beside a
  pump/booster is an EJECTOR PIT ⇒ pass-through. Equal-rank degree-1 peer
  sources mirror the root's outgoing flow onto their bridges, and every
  mirrored leg (standby + peer) is recorded in `parallelLegEdgeIdsOut` —
  `sourceDeliveredFlow(excludeEdgeIds:)` must skip them (one set flow, never
  curve(2 × UBAP)).
- **Terminals carry demand wherever they sit (`network_sizing.dart`)**: any
  fixture-role component (except cleanout / airVent / fireExtinguisher) with no
  explicit load takes the default terminal demand even when INLINE (degree 2);
  rainwater RUNS size by gravity Manning (`drain.sizeForFlow`, flagged when it
  saturates, self-cleansing judged) while rainwater RISERS keep the downpipe
  table; DFU-table overload sets `overCapacity`; above 3000 UBAP the demand curve
  extrapolates its last segment and flags `demandCurveExtrapolated`; a drain
  carrying a WC (built-in or `CustomFixture.isWaterCloset`) floors at DN75
  (`// VERIFY` UPC/IPC, `notAnSniClause`).
- **Tree accumulation is order-free; loops, check valves, vents (Round 12,
  `network_sizing.dart`)**: `accumulateFlows`/`accumulateFixtureUnits` run on
  the deterministic BFS `serviceSpanningTree` (links sorted by edge id) — never
  a recursive DFS whose drawing order decides the tree. A GRAVITY component is
  rooted only at a SINK plant (ground tank / component-less plant, or a
  DEGREE-1 pump/booster — an ejector pit IS the sink): an INLINE (degree ≥ 2)
  sump pump / booster / air unit on a drainage net is pass-through. A gravity
  loop's CLOSING edge is sized on the larger adjacent load and flagged
  `loopUnbalanced` (never left unsized). A CHECK VALVE is a directional cut: a
  looped pressurized component acyclic once its check-valve edges are cut
  sizes as a tree with those edges traversed last (a HW recirc return carries
  no draw-off; Hardy–Cross only for genuine rings). Every riser of a VENT
  STACK carries the stack's largest load (uniform, IPC 916.1, `// VERIFY`);
  rainwater downpipes are clamped ≥ the collector feeding them (N17 rule,
  `stackRaisedForBranch`); a cleanout / air vent / extinguisher carries no
  default load even as a LEAF.
- **One duty per drawn machine on every printed surface (Round 12)**: the
  riser equipment suffix reads `riserEquipmentDetailsProvider` (from
  `equipmentNodeDutiesProvider`, the map the panel feed uses) and prints
  `motorKwText` (2 dp below 1 kW); the fire pump everywhere is the engine's
  `firePumpDuty` (rated-point hydraulics, NFPA 20 motor); the genset on every
  drawing / G-01 is `sizeGenerator` (prime ×1.25); with root headroom the
  main earthing follows the incomer RATING; the Design Basis prints the
  EFFECTIVE fault level (`effectiveOriginFaultLevel`) with its provenance.
- **Electrical fault/sizing share one length + one derating basis**: Zs/ADS and
  the Fold-1 fault decay use the SOLVED run length (`solvedRunLengthM` — geo when
  placed), the same the sizing/Vd used; parallel runs are group-derated
  (`df·gf(g·n)/gf(g)`, grouping table to 20+ circuits — never saturate); a
  1-phase board's bus fault is the L-N `U0/|Zph+Zn|`; Zs includes the upstream
  feeders' PE return; single-phase A5 FLA uses U0 (230 V), never 400 V.

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
  **Round 15 refinements:** a TERMINAL air unit (FCU / AC cassette / split /
  ducted AC, `_isTerminalAirUnit`, supply rank 4) and any demand-bearing plant
  never root a supply component while a source exists — they rank below free
  entry leaves and inline movers (a stand-alone FCU still roots its own
  diffuser run) and are never parallel-source peers. A DRAINAGE / RAINWATER
  component with several riser-foot outfalls tied at the root's height
  (`_gravityOutfalls`, ordered by plan position) seeds a multi-root tree
  (`serviceSpanningTree(extraRootIds:)`): nearest-outfall split, no phantom
  outfall load, the divide edge a flagged closing edge. A pressurized component
  rooted at an inline GROUND TANK treats its mover-free, demand-free branch as
  the FILL line (no default load, oriented into the tank). A cycle CHECK VALVE
  whose two pipes are drawn ambiguously is oriented topologically (root-
  reachable side with every cycle valve cut, else the adjacent pump) — drawing
  direction is not geometry. RETURN / EXHAUST air record `flowFromId` in their
  physical direction (grilles → fan); `duct_static` flips it back for its
  fan-outward walk, and `sourceDeliveredFlow` counts only edges whose flow
  leaves (supply) / arrives at (extract) the source. The app's upfeed solve
  sources at the sizer's root when it is a plant (else the best `supplyPlantRank`
  plant, else the sizer's entry — never a fixture), and an INLINE booster's duty
  is sized on the flow THROUGH it (`supplyBoosterProvider`; head = the residual
  shortfall at the fixtures it serves with no pump in the system — the gravity
  solve on downfeed, the upfeed solve shifted to zero source head). A mover
  whose served set (beyond its inlet pipe) holds a storage TANK is a TRANSFER
  pump (GT -> TP -> RT downfeed), never a booster — no duty is fabricated.
  `pumpDutyProvider` is the one drawn pump's duty (trunk, or the booster);
  the KETERANGAN 'Peak design flow' reads the building trunk via
  `supplyPeakFlowProvider` (upfeed-only), never the booster's partial flow.
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
  anything, and it judges ONLY manually sized elements: duct edges **with a
  chosen `sizeOverride`** (an auto-sized duct is the sizing engine's own pick —
  re-judging it warned about the unavoidable round-up to the smallest standard
  size, an unactionable badge, so it is excluded entirely) and air terminals
  with a chosen `faceWidthMm`/`faceHeightMm` (via `faceVelocityFor`). A
  manually-sized return/exhaust duct is judged against the shared EXTRACT band
  (`checkExtractDuctVelocity`, 2–6 m/s), other air services against the supply
  band. Bands are plain constants (supply duct 3–7 m/s, extract duct 2–6,
  supply face 1.0–3.0, return/exhaust face 1.0–4.0) — general practice, NOT an
  SNI clause (`// VERIFY`). A non-positive velocity or a terminal with no chosen
  face is reported OK (nothing to warn about), so a project with no manual air
  sizing is byte-identical (no badges, goldens unchanged). A separate `airUnsizedProvider`
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
- **Phase imbalance is reported only when REDUCIBLE (`electrical/compute.dart`)**:
  the ENGINE assigns phases (`balancePhases` already spreads every unpinned
  single-phase way as evenly as it can), so `phase-imbalance` is raised only when a
  different assignment would actually help — over `kPhaseImbalanceWarnPercent`
  (15 %) AND saving more than `kPhaseImbalanceReducibleMarginPercent` (1.0 pp)
  against the achievable floor from pure `minimumPhaseSpreadA(currents)` (exact /
  exhaustive to `kPhaseExactSearchMaxWays` = 10 ways, symmetry-reduced; the
  balancer's own pin-free re-run above that). Three-phase ways are excluded from
  that floor (they load all three lines equally ⇒ they cannot change the spread)
  and PINS are released (unpinning is a real action, so a pin-forced imbalance IS
  reducible). Two equal 1φ ways can never load three lines evenly — that imbalance
  is inherent, and the engineer is never told to "redistribute" what no
  re-assignment can fix. The verdict rides `PhaseBalanceResult.imbalanceReducible`
  (additive, default false; also gates the `feeder-below-fed-demand` message's
  "rebalance" half). JUDGE-ONLY — the balance, incomer, busbar and demand current
  are untouched, and the percentage still prints on the schedule TOTAL footer, the
  inspector and both reports; only the unactionable WARNING (and, since it reads
  that warning, the canvas card's `imbalance NN%` badge) is dropped.
- **Feeder selectivity floor (`electrical/{sizing,compute}.dart`) — DEVICE-ONLY,
  AMPACITY-CAPPED** (redesigned by the MODULE-AUDIT E3/E4 wave; replaces the
  earlier cable-inflating floor): the feeder CABLE always sizes on the LOAD (a
  floor-free `loadBreaker` pick + the existing vd/minimum rules — copper is
  never inflated for discrimination), then the DEVICE floors to the first rung
  ≥ `selectivityRatio (1.6) ×` the fed board's incomer rating, CAPPED at the
  largest rung the load-sized cable's derated Iz protects (In ≤ Iz is
  inviolable; `selectBreaker`'s `maxRatingA` cap runs AFTER `minRatingA`).
  `computeSystem` stays two-pass (empty floors ⇒ the pass-1 object,
  byte-identical); `ElectricalSystemResult.feederFloorsApplied` records feeders
  that reached the FULL 1.6× target, and `faultStudy` suppresses
  `selectivity-partial` for exactly those (the engine's own deliberate
  trade-off); a CAP-LIMITED floor is not listed, so its residual
  non-/partial-selectivity is honestly reported. Overrides bypass the floor
  entirely. The 1.6× basis stays `// VERIFY notAnSniClause`. Related policies
  from the same wave: a final `socket` way sizes its own device+cable on the
  UNdiversified load (aggregation keeps the demand factor, `// VERIFY` uniform
  stop-kontak practice) — since Round 11 EVERY final (non-feeder) way does
  (one machine does not diversify against itself; motor / A5-FLA ways already
  derive Ib undiversified); a `lifeSafety` motor/pump way carries an INFO
  `fire-pump-protection` note; an irreducible over-threshold imbalance carries
  an INFO `phase-imbalance-inherent` note; a feeder's voltage base (Ib and
  Vd%) is the FED panel's.
- **One capacitor phase model (`electrical/compute.dart`, Round 14)**: a
  capacitor way's phase decision reads its kvar (`c.loadW`), never its zeroed
  demand W; a feeder to a capacitor board floors at that board's OWN solved
  `capacitorCurrentA` (bottom-up `computePanel` pre-pass, same balance
  assignment); the service cable + main earthing follow the root incomer
  whenever it exceeds the demand-selected device (headroom, capacitor floor…).
  The supply kVA is each root's diversified demand VA at the real per-circuit
  cos φ (`panelDemandVa`, ≥ W; 0.85 only as fallback). Metering CT / meter
  range size on `ElectricalPanelResult.meteringCurrent` = max(demand, busbar
  sizing current). A spine CAPACITOR BANK is drawn only for
  `capacitorBankKvar > 0`; an AC/FCU feed is `MepLoadSource.hvacUnit` →
  `LoadKind.hvac`. Board schedules always receive the per-device
  `breakerKaByCircuit` map beside the per-panel Icu map.
- **Service-capacity floor (`electrical/compute.dart`) — the declared daya SIZES
  the service entrance**: a declared `ElectricalProject.supplyCapacityVa` (daya
  tersambung) is converted to its line current (3φ `VA/(√3·V_LL)`, 1φ `VA/V` —
  PLN 33 kVA @ 400 V → 47.6 A → the 50 A rung, the matching PLN limiter) and
  floors the SINGLE root panel's incomer + busbar sizing current
  (`ComputePanelOptions.serviceMinCurrentA`, `max(headroom-uplifted demand,
  service current)`; the earthing PE derivation rides the governing floor).
  Rating the entrance board at the subscribed daya is Indonesian LV practice,
  `// VERIFY notAnSniClause`. Per-circuit sizing is untouched; SEVERAL
  utility-fed roots ⇒ no floor (the capacity split is unknown — never
  fabricate); demand above the capacity keeps the larger demand-based incomer
  and raises the judge-only `service-capacity-below-demand` warning (the
  utility limiter would trip under full demand). Null capacity (the default)
  ⇒ byte-identical. Seed suite: `electrical_service_capacity_test.dart`.
- **Capacitor ways floor their board + feeder (`electrical/compute.dart`, Round 13)**:
  a capacitor bank adds NO demand W and NO balance current (Round 11 — its
  leading current offsets the load, so for a mixed board bank-off governs), but
  a board's incomer + busbar floor at `panelCapacitorFloorA` — the worst-line
  sum of its own banks' rated current (Q/(√3·U) 3φ, Q/U0 1φ) × 1.43
  (`kCapacitorSwitchingFactor`) plus every fed board's figure — and the feeder
  supplying such a board floors its device + cable at the same current
  (`ComputePanelOptions.feederCapacitorFloorA`, bottom-up in `computeSystem`).
  No capacitor anywhere below ⇒ 0 ⇒ byte-identical.
- **Motor / FLA design current is diversified; final-way Vd is not (Round 13)**:
  a motor / A5-FLA way's `designCurrent` (balance, demand current, incomer) is
  FLC × `effectiveDemandFactor` — the same basis `circuitConnectedW` feeds
  upstream — while its own device + cable size on the undiversified FLC. Every
  FINAL way's printed / cumulative voltage drop is computed on its
  UNDIVERSIFIED running current (the current that flows when the machine runs);
  a feeder keeps its aggregated Ib.
- **Several utility roots: one governing service, every root an SPD origin
  (Round 13)**: supply system / voltage, the main cable and the main earthing +
  bonding conductors follow `governingRootPanel` (largest incomer rating, then
  worst-phase demand current, then lowest id) — never panel list order; every
  root (`originPanelIdsOf`) gets the origin SPD recommendation.
- **Genset backs the essential sub-tree (`electrical/genset_backup.dart`, Round
  13)**: the backup demand is `max(backupFraction × supply demandVa, the
  topmost essential boards' demand W × the supply VA/W)` — ONE helper
  (`gensetBackupDemandVa`) for the power one-line, both source-spine builders and
  the G-01 schedule row. A forced nameplate wins but below the essential demand
  raises the judge-only `genset-below-essential-demand` (`AdvancedStudy.warnings`
  → `electricalAllWarningsProvider`). The PFC bank (`power_factor.dart`) sizes on
  the DIVERSIFIED kW (library-aware demand factor × every upstream board's
  diversity), the same demand the supply summary reports.
- **Check valves cut by DIRECTION (`sizing/network_sizing.dart`, Round 13)**:
  only cycle check valves count, classified by their drawn in → out edge
  (`_classifyLoopCheckValves`): all RETURN valves ⇒ the Round-12 tree cut; all
  PARALLEL DISCHARGE valves (duty/standby legs onto a header) ⇒ the tree runs
  through the first leg and every standby leg carries the same full set flow;
  anything else ⇒ Hardy–Cross as if no valve were drawn. (Superseded for the
  classification by the Round 27 r3 binding rule — see the Round 27 row:
  drawn direction authoritative, each valve judged with only itself
  removed, returns zeroed, feeds transparent pipes.) A ground tank roots a
  pressurized component at ANY degree.
- **ONE electrical warning surface (`electricalAllWarningsProvider`)**: the
  fault study's warnings (`non-selective` / `selectivity-partial` /
  `breaking-capacity-inadequate` / `busbar-withstand-inadequate` /
  `tt-no-earth-fault-protection`) used to be computed and shown NOWHERE. Every
  consumer — the Review fan-in (§5b `electrical:<code>` kinds), the compliance
  roll-up, the electrical drawer count/list, the Layout electrical error dot —
  now reads the combined provider (core `electricalResultProvider.warnings`
  first, then `electricalAdvancedProvider.fault.warnings`, deduped on
  (code, panelId, circuitId) keeping the core occurrence). Never read either
  source's warnings directly in a UI/store consumer. Related honesty tiers:
  `harmonics-neutral-oversize` is INFO (Fold 2 already compensated — a sizing
  note, not a defect); a BLANK uncalibrated sheet is an info advisory (kind
  unchanged `sheet-uncalibrated:<id>`; edge-bearing stays critical), and the
  compliance calibration row, when passing, still counts blank uncalibrated
  sheets ('N blank uncalibrated (advisory)') instead of claiming all-calibrated.
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
  Round 15: the FEEDER and the boards upstream deliberately keep sizing on TODAY's
  demand; when a feeder breaker is below its fed board's future worst-phase current
  (`demandCurrent × diversity × multiplier`) the judge-only
  `feeder-below-fed-headroom` warning says the reservation cannot be drawn.
- **Per-board VA + capacitor current (Round 15, `electrical/compute.dart`)**:
  `ElectricalPanelResult.demandVa` is each board's own diversified VA (Σ leaf W ÷ its
  cos φ, feeders at their fed board's VA, × diversity, ≥ W; 0 on a bare `computePanel`
  result — read `demandVaOrEstimate`). The genset's essential demand sums it over the
  topmost backed boards and the overview/riser compact nodes print it, so a single-root
  sheet shows ONE kVA. A CAPACITOR way's current is always Q/(√3·U) / Q/U0 (cos φ forced
  to 1, also in `panelCapacitorFloorA`); a busbar SECTION carries a bank at its switching
  current (× 1.43) and a feeder to a capacitor board at least that board's floor;
  unpinned 1φ banks on a 3φ board are spread by switching current (largest-first, lowest
  line) after the load balance. The BOM matches each breaker at the fault study's
  SPECIFIED kA (`faultSpecifiedKa` → `incomerKaByPanelId` / `breakerKaByCircuitId`), and
  the schedule's CT token is `meterFor(meteringCurrent)` (one ladder + 0.5S, `kWh direct`
  ≤ 100 A). The fire-pump duty exists only when a fire service (sprinkler / hydrant
  edge) is drawn.
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
- **Audit round 8 invariants (don't regress)**: the most-remote standpipe riser
  is **500 gpm** (SNI 03-1745 / NFPA 14 — corrected from 550). The genset ladder
  NEVER saturates silently: `sizeGenerator` / `selectGeneratorUnits` return
  `n × 2500 kVA` past the top rung (`GeneratorResult.ratingKva` is then the
  PER-SET rating), and every printed surface goes through them — the SLD
  GENSET/TRANSFORMER nodes print `n x 2500 kVA` (coverage % on the paralleled
  total), the schedule G-01 row prints the per-set kVA with qty = n, and the power
  one-line screens the motor-start dip on the PARALLELED kVA; never print
  `selectGeneratorKva` alone. Inverters, capacitor banks, transformers and CTs
  flag saturation the same way. A solved MEP motor way sizes on
  `max(operating, nameplate)` input. The sprinkler-vs-fire-pump check is
  JUDGE-ONLY and its head is a LOWER BOUND (static lift + branch-base pressure,
  no friction). Electrical BOM: a single-core cable family (NYA/NYAF,
  `isSingleCoreCableFamily`) is bought per CONDUCTOR whatever part matched — it
  never takes a non-single-core part (unmatched ⇒ `elec:cable:<family>:1x<csa>`);
  multi-core cable prices on `SKU:nC`; every non-catalogue line carries an `elec:`
  key; a breaker short of its board's prospective kA is flagged
  `breakingCapacityShort` and consolidation keys it APART from an adequate line of
  the same SKU (the flag can never be merged away). `parseMoneyInput` validates
  thousands grouping on both the single- and mixed-separator paths.
- **Drawing honesty (Round 10)**: the plan PDF and DXF compose every edge
  label through ONE `composePlanEdgeLabels` (unsized runs included) and fit /
  extent over EVERY on-floor node; an unconnected glyph goes on the neutral
  `M-EQPM-NCON` DXF layer. Plan chrome (north arrow, legend, scale bar) is
  reserved space, never overprinted. The SLD PDF renderer prints the plot
  fit's label sizes exactly (no renderer floor — PDF == DXF); an issued detail
  SLD auto-paginates (`electricalSldDetailToPdf`) whenever one A3 sheet would
  print below `kMinPlotLabelPt`. Power one-line skip-tier edges ride a side
  lane, never through an intermediate box. Every user-typed geometric number
  (smart input, 1 : N, offset) must be FINITE; `setCalibration` /
  `placeRunPoint` / `offsetEdgeParallel` are the store backstops.
- **Persistence**: design settings (occupancy, feed, ducts, rainfall, fire
  hazard, theme) round-trip via `DesignSettings` in the `.mechx` file; autosave
  only writes recovery when the work differs from the last clean Save
  (`lastSavedSignatureProvider`), so a saved project leaves no phantom recovery.
  **Portable `.mechx`**: Save EMBEDS the source plans (`ProjectDocument.assets`
  = source path → base64 of gzip-compressed bytes, via `data/project_assets.dart`
  `gatherSheetAssets`; ~88 % smaller than raw base64 on a real DXF), so the file
  is self-contained across machines; Open `rehydrateAssets` (gunzips via the
  `1f 8b` magic, raw-base64 passthrough for older files) extracts
  them to `mechx_assets/` (systemTemp) and repoints the sheet paths so the
  path-based PDF/DXF renderers are unchanged. A DWG sheet embeds its CONVERTED
  DXF (portable without ODA). The autosave "clean baseline" signature stays the
  PATH-ONLY encode (autosave never embeds ⇒ recovery is lightweight, no phantom
  recovery). Empty `assets` ⇒ byte-identical (no version bump). Round 10: a
  re-Save falls back to the payload already embedded when a plan's source is
  gone (never silently drops it) and warns when nothing could be embedded;
  plan parse caches key on path + size/mtime (`FileStampedCache`); Open falls
  back to `<file>.bak` after an interrupted atomic save.
