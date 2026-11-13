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

**Drawing review (2026-11-13)**: every issued sheet is numbered (front matter G-001..G-003, equipment schedule M-601 with a drawing title block, panel schedules E-601 in the package), riser / plan tags are placed legally or KEYED into a KETERANGAN PIPA / PIPE KEY table (D5), paginated sets issue paginated DXF twins with the PDF's strings (D6), and the zero-length export guard ignores calibrated 0 px splices (D7); see §15 and `docs/REFERENCE-BUILDINGS.md` "Drawing review".

**Reference buildings (2026-11-13)**: fixed fixtures replace open-ended audits — `packages/mechx_engine/test/reference/` (house, shophouse row, office, apartment and tower done), pinned to hand-derived values in `reference_house_test.dart` / `reference_shophouse_test.dart` / `reference_office_test.dart` (engine) + `test/reference_house_app_test.dart` / `test/reference_shophouse_app_test.dart` / `test/reference_office_app_test.dart` (app); the shophouse review made every roof-tank component its own downfeed (`extraDownfeedTanksProvider`), sized a root tank's meter feed, sized a stack vent on the stack base and exempted cassette / split AC units from the orphan check; the office review stopped the NFPA 20 discharge raise at a two-outlet pump's junction, hung the upfeed zone table from the solved field (`upfeedZoneDatumProvider`) and made the MEP sync specify its life-safety feeder FRC; the tower review (T1–T4) ended the NFPA 20 discharge raise at the header, enlarged a combined system's sprinkler feed main until the sprinkler stops setting the pump head (`sizing/sprinkler_feed_main.dart`, `sprinklerFeedEnlargedProvider`), grew auto-sized feeders for their own ADS and downstream cumulative drop (`cableRaisedForDownstreamVd`), and made the ADS growth hold on the genset too; see `docs/REFERENCE-BUILDINGS.md` and the drawing review `docs/DRAFTING-CHECKLIST.md`.

**Drawing review R1/R2 (2026-11-13)**: a plan that would still stamp "label bertumpuk" boxes its dense clusters (`report/plan_detail.dart` `planDetailClusterRects`, `planSheetDetails`) with a dashed DETAIL boundary + bubble (`DETAIL A - LIHAT M-5nn`) and the submittal package issues an enlarged DETAIL sheet per such plan (`report/plan_detail_sheet.dart`, `M-5nn`, 1:10/20/25/50 via `planDetailPack`, PDF + DXF through the plan exporters, listed on the Daftar Gambar); riser columns are re-spaced over the band (`riserColumnRespace`) and the riser paginator sheds the lowest page's extras to a continuation sheet rather than print below 7 pt.

**Drawing review fix round F1-F7 (2026-11-13)**: electrical layout tags placed in-frame and stacked clear (`ElectricalPlanNodeTag`, counted in the overlap stamp), legend rows only for drawn kinds (`electricalPlanLegendRows`); legibility stamp only below the PRINTED 7 pt (`sldPrintsBelowMinPt`); pipe-key table margin (`kPlanKeyTableMarginFactor`); detail-sheet legend narrowed to its windows (`planDetailLegendChrome`); ONE source arrangement (`serviceArrangementOf`) for the E-301 spine and the E-501 power one-line (MV main + rated TX + capacitor bank); pre-check FAILs a stamped sheet / a touched key table.

**Fire / mechanical-judge backlog (2026-11-13, A-1..A-5)**: the sprinkler-vs-pump judge requires the rating basis' sprinkler point (`FireSystemBasis.sprinklerPointHeadM`); the fire-water reserve (`sizing/fire_water_reserve.dart`, `fireTankReservesProvider`: rated flow x `// VERIFY` duration) is judged on every fire ground tank (`fire-tank-undersized` / `fire-tank-capacity-unset`); the pump churn sets the fire pipe pressure class (`firePressureClassFor`: standard / PN16 / PN25, `firePressureClassesProvider`, `BomLine.pressureClass`) and `fire-system-over-pressure` warns only above 350 psi (zone split); hose valves above 175 psi static are designated pressure-regulating (`prvHoseValvesProvider`, info `standpipe-prv-hose-valves`, take-off `ComponentLine.variant`, riser tag 'PRV 690 kPa'); `room-cooling-undersized` (`roomCoolingCheck`) warns when a room's AC units give less than its load; a branch discharge run off a several-outlet fire pump stores its own flow (backlog A-5). See the §15 rows.

**HVAC backlog F-1..F-4 (2026-11-13)**: the room-air estimate reads the drawn duct's product roughness (`defaultDuctRoughnessForService` / `effectiveDuctRoughnessFor`, F-1); ONE face-velocity limit per terminal kind and application (`terminalFaceVelocityMax`) for the room's banks and the checker (F-2: office return 3.0 m/s; tower redrawn with 5 return grilles, the office's single grille is a deliberate `terminal-velocity` finding); ONE headline air-unit duty per room (`store/room_air_store.dart` `roomAirHeadlineProvider`: the drawn system's duty, else the estimate labelled "estimate (no ducts drawn)", F-3); `air-duct-unsized` only for a duct with no size at all (F-4).

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
  (2) update this file's **Feature state** section and, as needed,
  `docs/PROJECT-HISTORY.md` (known gaps) / `docs/ENGINE-INVARIANTS.md` (a new
  invariant row). Treat the doc update as part of the feature,
  in the same commit — a feature is not done until its history is recorded.

## Known gaps / history

Campaign history, release notes, and open residuals live in
`docs/PROJECT-HISTORY.md` (moved out of this file to keep every agent's context
small). Current published build: see `pubspec.yaml`. The convergence-audit
programme (rounds 1-80, merged to `main` as PR #56) is recorded round by round in
the §15 decisions log and in `docs/ENGINE-INVARIANTS.md`.

## Sizing-engine invariants (don't regress)

The full rule set (~240 KB, one row per audit round) lives in
`docs/ENGINE-INVARIANTS.md`. **Before editing anything under
`packages/mechx_engine/lib/` or the stores that call it, grep that file for the
functions / providers / warning codes you touch and read those rows.** A few
rules apply everywhere:

- Sizing is order-independent: shuffling nodes/edges or renaming ids never
  changes a size, head or verdict (seeded property suites `audit_r7_*` and later).
- A safety quantity is never clamped DOWN to look compliant; a judge never
  condemns the engine's own pick; never fabricate a value — omit or flag it.
- Judge-only checks never resize; every warning is a typed, locatable
  `DesignIssue` and flows through ONE surface (`designIssuesProvider`,
  `electricalAllWarningsProvider` for electrical).
- Every printed surface (canvas, PDF, DXF, report, BOM, schedule) reads the SAME
  solved figure — never a parallel re-derivation.
- Never replace a `Network` node/edge list element in place (id index is keyed on
  the list instance + length).
- Unverified standards values stay `// VERIFY` and surface in reports.
