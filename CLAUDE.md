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
  a **Plumbing · Fire · HVAC · Electrical** layer switcher + visibility toggles (PLUMBING is ONE
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
  is `v1.13.0`** (the ENTIRE WORKFLOW-GOLDENS-REVIEW campaign — all 7 waves — atop the
  v1.12.0 baseline; `pubspec.yaml` is the version source of truth, `1.13.0+19`; each
  release = bump → merge to the default branch → `release.yml` `workflow_dispatch` with
  `publish=true`). The prior `v1.12.0` shipped the unconnected-element design checks
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
  block width 920, a per-way `· PVC <n>mm` conduit token from the pure `_conduitMm`), and three further
  DXF-parity gaps (verified against the client's real EL1004 `Diagram Panel BRI` DXF) then closed in
  `electrical_sld_drawing.dart`: **(a) STARTER / CONTROL token** — the way's `ElectricalCircuit.starterType`
  (resolved by the same `circuitById` lookup that feeds `cableType`) is mapped to an ASCII token by the
  pure `_starterCode` (`dol`->`DOL`, `starDelta`->`star-delta` [NOT the unicode `Y-D`], `reversing`->`REV`,
  `softStarter`->`soft-start`, `vfd`->`VFD`, `ats`->`ATS`, `pump`->`pump`) and APPENDED to the DEVICE cell
  as `<breaker> · <token>`, shown ONLY when a way carries a real `starterType` (else bare — most final
  lighting/socket ways have none); **(b) DAYA in WATT** — the cell switched from `_watts()` (kW) to the
  pure, unit-tested `_wattsId(double w)` → integer watts with the Indonesian DOT thousands separator +
  ` WATT` (`190 WATT`, `1.100 WATT`, `4.400 WATT`, `52.871 WATT`; rounds to the nearest watt, from the
  solved `ElectricalCircuitResult.loadW`), a feeder (loadW 0) staying `-`; **(c) circle V/A/Hz meters** —
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
  now first-class + editable:** a **Sources** toolbar button opens a `_SourcesEditor` drawer (genset
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
  default OFF (the toolbar chips still preview them); Details/Notes stay ON. Goldens 04/09/10 shift only
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
  **Portable `.mechx`**: Save EMBEDS the source plans (`ProjectDocument.assets`
  = source path → base64 of gzip-compressed bytes, via `data/project_assets.dart`
  `gatherSheetAssets`; ~88 % smaller than raw base64 on a real DXF), so the file
  is self-contained across machines; Open `rehydrateAssets` (gunzips via the
  `1f 8b` magic, raw-base64 passthrough for older files) extracts
  them to `mechx_assets/` (systemTemp) and repoints the sheet paths so the
  path-based PDF/DXF renderers are unchanged. A DWG sheet embeds its CONVERTED
  DXF (portable without ODA). The autosave "clean baseline" signature stays the
  PATH-ONLY encode (autosave never embeds ⇒ recovery is lightweight, no phantom
  recovery). Empty `assets` ⇒ byte-identical (no version bump).
