# MEP PDF Sizing Tool — Build Plan (authoritative spec)

> **Status:** living document. This is the source of truth. If a decision
> changes, update this file *in the same commit* as the code change.
>
> **Provenance note:** This plan was reconstructed from the project kickoff
> brief (the original 6 hand-off files were not available, so the build plan and
> the drafted engine/standards/test files were authored from scratch — see
> [§15 Decisions log](#15-decisions-log)). SNI values are draft placeholders
> tagged `// VERIFY` until transcribed from official SNI PDFs.

---

## 1. Overview & goal

An **offline, native Windows desktop application** for MEP (mechanical /
electrical / plumbing) design. An engineer:

1. loads **PDF floor plans**,
2. **calibrates each sheet's scale** and sets **per-floor heights**,
3. **drags duct / pipe elements** onto the plans,

and the app then automatically:

- **sizes** ducts, pipes, pumps and fire systems to **Indonesian SNI** standards,
- **solves the network** (node pressures / flows),
- **auto-draws schematic riser diagrams**,
- shows a **live pressure heatmap**, and
- outputs a **Bill of Materials (BOM)**,

all with **no internet connection**.

## 2. Product scope

Services covered, in MVP build order (see [§13](#13-open-decisions--chosen-defaults)):
ducts (HVAC) · clean/cold water · wastewater + vent → then rainwater, recycle,
pumps → then fire protection (sprinkler / hydrant / fire pump).

## 3. Stack — decided, not re-litigated

| Concern | Choice |
|---|---|
| Framework / target | **Flutter, Windows desktop**, compiled native (develop on any OS, ship Windows) |
| Calc engine | **Pure-Dart**, **zero Flutter imports**, in package `mechx_engine` |
| PDF rendering | `pdfrx` (PDFium) |
| Persistence | `drift` (SQLite) + versioned project files |
| State | Riverpod with undo/redo |
| Tests | `package:test` (engine), `flutter_test` (UI) |

**Explicitly NOT used:** web stack, Electron, WinUI, default Material/Fluent
theme, cloud, login, telemetry, browser storage.

## 4. Polish bar (acceptance criteria — not aspiration)

A screen is not "done" until it meets all of these:

- **Instant launch + viewport restore** — no spinner.
- **60/120 fps pan/zoom**, zero dropped frames on drag.
- **Direct manipulation** with snap feedback.
- **Native input** — scroll/pinch zoom, middle-drag pan, full keyboard shortcuts.
- **Async calc off the UI thread** — *no* modal "calculating…".
- **8pt grid, one type scale, light/dark.**
- **Motion that orients** — nothing decorative.

## 5. Module map / architecture

```
MechX/                              (Flutter app, package: mechx)
├─ lib/
│  ├─ main.dart                     app entry (P0 shell)
│  ├─ ui/                           screens, canvas, design system   (P0+)
│  ├─ data/                         drift schema, project file IO     (P0+)
│  └─ store/                        Riverpod providers, undo/redo      (P0+)
├─ test/                            widget / integration tests
├─ packages/
│  └─ mechx_engine/                 PURE-DART engine (no Flutter)
│     ├─ lib/
│     │  ├─ units.dart              SI typed quantities
│     │  ├─ hydraulics.dart         hydraulic-formula kernel
│     │  ├─ pressure_field.dart     heatmap scalar-field kernel
│     │  ├─ sizing/                 SNI sizing paths (ducts/water/...)  (P3+)
│     │  └─ standards/
│     │     └─ sni.dart             pluggable SNI standards data
│     └─ test/
│        ├─ hydraulics_test.dart    seed correctness anchors
│        └─ pressure_field_test.dart
└─ MEP-PDF-Sizing-Tool-Build-Plan.md (this file)
```

**Why a separate engine package** (deviation from a literal `lib/engine/`): the
guardrails demand a *pure-Dart* engine that runs under `dart test` with
`package:test` and >90% coverage. `dart test` cannot run inside a Flutter
package (the Flutter SDK dependency breaks pure-Dart resolution), so the engine
lives in its own pure package the app consumes by path. Fully reversible; see
[§15](#15-decisions-log).

## 6. Domain model & units

- **One internal unit system: SI.** Convert only at the UI boundary.
- **Typed quantities, never bare numbers across modules** (`units.dart`):
  `Length`, `Diameter`, `Area`, `Velocity`, `FlowRate`, `Pressure`, `Head`,
  `Power`, `Roughness` — zero-cost Dart 3 `extension type`s over `double`.
- Construct from engineering units via static helpers (`Diameter.mm`,
  `FlowRate.litersPerSecond`, `Pressure.kiloPascals`…); read via `inXxx` getters.

## 7. The three sizing code paths (kept separate — §12)

A shared "size a pipe" function silently breaks drainage and fire. The engine
exposes the *primitives* separately and the sizing layer composes the correct
path per service:

| Path | Method | Kernel entry points |
|---|---|---|
| **Pressurized** (supply, fire feed) | demand → velocity → friction | `reynolds`, `frictionFactor*`, `headLossDarcy`, `headLossHazenWilliams` |
| **Gravity** (drainage) | Manning partial-full + stack capacity | `manningVelocity`, `manningFlowFull` |
| **Fire** | density/area + standpipe residual | (P5) builds on pressurized + dedicated residual checks |

**Supply pump-head sizing** (`sizing/supply_design.dart`, pressurized path):
`H_pump = H_static + H_friction + H_residual`, where `H_static` is the
floor-elevation rise to the critical fixture (§10), `H_friction` the critical-path
loss, and `H_residual` the **design target residual pressure** at the fixture.
That target is an **engineer-set design choice (NOT an SNI value)**: recommended
**2.25 bar** within a **2.0–2.5 bar** comfort band — deliberately above the SNI
minimums (~0.49–0.98 bar) and below the practical max (~3.92 bar) / mandatory
pressure-relief threshold (4.9 bar), so fixtures perform well without forcing a
PRV/zone on lower floors.

## 8. Standards as pluggable data + the VERIFY list

- `standards/sni.dart` implements `StandardsProfile`; the engine depends on the
  **interface**, never the concrete numbers — standards are swappable data.
- Every value is wrapped in `StandardValue<T>` carrying
  `{value, unit, citation, verified, sourceUrl, note}`. `verified == true` means
  the figure was found in the **SNI text itself** and corroborated; `false`
  means a placeholder OR a real figure sourced only from **secondary literature**
  (clause not yet confirmed against the official PDF). The UI/output must show
  every `verified == false` value as **UNVERIFIED**. `SniProfile.verifyChecklist`
  returns the outstanding items, most-critical first.

**Seeding status (SNI 8153:2015, researched 2026-06 from the archive.org full
text + Indonesian engineering literature):**

| Value | Figure | `verified` | Basis |
|---|---|---|---|
| Min pressure at fixture outlet | 0.50 kgf/cm² (49.03 kPa) | ✅ | verbatim SNI text |
| Min pressure at flush valve | 1 kgf/cm² (98.07 kPa) | ✅ | verbatim SNI text |
| Mandatory pressure-relief threshold | >5 kgf/cm² (490.33 kPa) | ✅ | verbatim SNI text |
| Demand method (UBAP + Hunter curve) | — | ✅ | confirmed prescribed method |
| Max fixture pressure (zoning target) | ~4 kgf/cm² (392.27 kPa) | ⚠️ | secondary design guidance |
| Max supply velocity | 2.0 m/s | ⚠️ | secondary consensus |
| Demand-curve point **values** (Gambar 1) | two branches | ⚠️ | chart read-offs (UPC-2012 lineage) |
| UBAP fixture-unit table (Tabel 3) | per fixture/occupancy | ⚠️ | secondary sources |
| Drain velocity cap | 3.0 m/s | ⚠️ | not an SNI clause (slope+UBAP based) |

> The two ⚠️ items called out in [§13.4](#13-open-decisions--chosen-defaults)
> (max fixture pressure, demand curve) are now seeded with **real, sourced**
> figures but remain flagged until confirmed against the official SNI PDF.
> NB: **SNI 8153:2025** now supersedes the 2015 edition.

## 9. One solve feeds everything (no parallel calculations — §12)

The **schematic diagram** and the **pressure heatmap** are *generated renders of
the solved network*, never independent calculations that could disagree with the
sizing numbers. A single node-pressure/flow solve feeds: sizing, pump duty, the
auto diagram, and the heatmap. `pressure_field.dart` only *interpolates* already
solved node values into a grid — it computes no physics.

## 10. Geometry & length — single source of truth

- **Horizontal length = pixels × calibrated scale** (per sheet).
- **Vertical (riser) length = floor-elevation delta** (per-floor heights).
- **Never** measure riser length from a PDF. Geometry + floor elevations are the
  authoritative source for every length the engine consumes.

## 11. Persistence & versioning

- **Versioned project file format + DB schema from day one** (`drift`/SQLite).
- Project files carry a schema/version header; migrations are explicit.
- Viewport / last-open state persisted for instant restore (§4).

## 12. Architecture guardrails (non-negotiable)

1. Engine is **pure** (no Flutter imports), **>90% test coverage**, seeded with
   SNI/textbook worked examples.
2. **One unit system internally (SI)**; convert only at the UI boundary; typed
   quantities, never bare numbers between modules.
3. **Geometry + floor elevations are the single source of truth for length**
   ([§10](#10-geometry--length--single-source-of-truth)).
4. **Gravity, pressurized, and fire are SEPARATE sizing code paths**
   ([§7](#7-the-three-sizing-code-paths-kept-separate--12)).
5. **Diagram + heatmap are generated renders of the one solve**
   ([§9](#9-one-solve-feeds-everything-no-parallel-calculations--12)).
6. **Standards are pluggable data**; `// VERIFY` values are flagged as
   unverified in UI/output ([§8](#8-standards-as-pluggable-data--the-verify-list)).
7. **Versioned project file format + DB schema from day one.**

## 13. Open decisions & chosen defaults

1. **MVP service order:** ducts + clean water + wastewater (+vent) first;
   rainwater/recycle/pumps in P4; fire in P5.
2. **Source architecture template:** ground water tank → transfer pump → roof
   tank → gravity downfeed + top-zone booster.
3. **Heatmap default:** residual-pressure metric, per-zone colour scaling;
   fill-ratio (not pressure) for gravity drainage.
4. **VERIFY priority:** pull SNI 8153 **max-fixture-pressure** (zoning trigger)
   and the **demand-curve** table to the top of the verify list — flag to the
   user, do not guess.

## 14. Phase plan

| Phase | Scope | Gate |
|---|---|---|
| **Step 1** ✅ | Scaffold + pure engine + seed tests green | *all seed tests pass* |
| **P0 Shell** 🟡 | Custom design system, multi-sheet nav, pannable/zoomable canvas (✅ done & tested); **pdfrx PDF render** (⬜ next, behind the `sheetContentBuilderProvider` seam) | review stop |
| **P1** ✅ | Project details + per-floor heights + scale calibration. Pure geometry (calibration + elevations), editable project/floor state + inspector UI, pdfrx PDF import + render (2.4.4, "Open PDF…" → sheet-per-page), and the on-canvas mark-a-known-distance calibrate tool. All logic tested (95 total). | — |
| **P2** ✅ | Drawing (incl. risers). Pure network model (nodes/edges/services/lengths), drawing controller (run polylines w/ snapping, risers, undo/redo/clear), canvas network render + rubber-band overlay, and the inspector draw palette (tool/service/undo). 109 tests. | — |
| **P3** ✅ | SNI sizing engine. Three independent §7 paths (duct/water/drainage, parallel agents), a network dispatcher with **branching flow accumulation** + `autoSizeNetwork`, **grille/diffuser face-velocity sizing** (noise-driven), and a live on-canvas sizing display (DN/Ø labels) with an inspector toggle. Engine 145 tests, app 45. | — |
| **P4** ✅ | Node-pressure solver (the §12 keystone), pump duty, downfeed zoning, BOM aggregator, pressure heatmap (generated render of the solve), auto schematic riser diagram. Live inspector results. | **MVP = P0–P4 ✅** |
| **P5** ✅ | Fire protection — sprinkler density/area sizing, standpipe/hydrant flow + fire-pump duty; inspector fire panel. SNI 03-3989-2000 (sprinkler) + SNI 03-1745-2000 (standpipe) values seeded from web research; `// VERIFY` retained on engineering assumptions only. | — |

Commit per logical unit; keep tests passing continuously. **Pause at each phase
boundary for review.**

## 15. Decisions log

| Date | Decision | Rationale |
|---|---|---|
| 2026-06-22 | Authored build plan + engine/standards/test files **from scratch** | The original 6 hand-off files were not provided; user approved authoring drafts. SNI numbers are placeholders. |
| 2026-06-22 | Package name **`mechx`** (app) / **`mechx_engine`** (engine) | User choice; matches repo. |
| 2026-06-22 | Engine lives in **pure-Dart package `packages/mechx_engine`**, not literal `lib/engine/` | Required to satisfy "pure-Dart engine + `dart test` + `package:test` + >90% coverage" (Flutter packages can't run `dart test`). Reversible. |
| 2026-06-22 | Internal quantities are Dart 3 `extension type`s | Zero-cost typed-quantity guardrail (§12.2). |
| 2026-06-22 | Toolchain installed in CI/dev container: **Flutter 3.44.2 / Dart 3.12.2** | Linux dev/test only; Windows `.exe` build happens on the engineer's machine. |
| 2026-06-22 | **Seeded SNI 8153:2015 supply values** from web research (pressures, velocities, demand method/curve, UBAP table) | `verified` flags reflect verbatim-text vs secondary provenance; `StandardValue` gained `sourceUrl`/`note`; `verified==true` only for literal SNI text. |
| 2026-06-22 | **Design target residual pressure = 2.25 bar** (band 2.0–2.5), seeds `sizing/supply_design.dart` + `computeRequiredPumpHead` | Engineer-set design choice (not SNI); sits between SNI min and the PRV/relief ceiling; drives pump-head sizing. |
| 2026-06-22 | **P0 uses `WidgetsApp`, not `MaterialApp`** | Honours §4 "no default Material theme"; MechX owns its visual language via `MechXTheme`. |
| 2026-06-22 | **Canvas: pure `ViewportTransform` + controlled `CanvasView`** | Polish-critical math is headless-testable; gestures = wheel zoom-to-cursor, **left-click & middle-drag pan**, trackpad pinch, keyboard (Ctrl±/0, F, arrows). Per-sheet viewport restore via the store. |
| 2026-06-22 | **P1 length source-of-truth as pure engine geometry** (`geometry/scale_calibration.dart`, `geometry/building.dart`) | §10/§12.3: horizontal length = px × calibration; vertical riser = floor-elevation delta. Editable via `project_store`; never measured from a PDF. |
| 2026-06-22 | **Calibrate tool = testable controller + canvas overlay** | `calibration_store` is a pure state machine (idle→pick→pick→distance); the overlay maps taps to sheet/world coords via the live `ViewportTransform` and writes `ScaleCalibration` to the project. Two-point flow widget-tested. |
| 2026-06-22 | **Versioned project file `.mechx`** (`data/project_document.dart`) | JSON with a `version` header from day one (§12.7); round-trips name, floors, per-sheet calibrations, sheets, network. Open/Save/Import wired into the top bar. |
| 2026-06-22 | **Seeded SNI fire values** from web research — sprinkler density/area (SNI 03-3989-2000: Ringan 2.25 mm/min @84 m², Sedang 5 @72/144, head coverage 20/12/9 m²) and standpipe flow/residual (SNI 03-1745-2000: 550+250 gpm ≤1250 cap, 6.9/4.5 bar Class I/II, 100 mm min riser) | Flips fire constants from placeholders to cited values; `// VERIFY` retained only on engineering assumptions (Berat density mid-range, friction allowance, pump efficiency) and occupancy→class mapping. |
| 2026-06-22 | **Role-aware node elevations + roof-tank downfeed** (`MountingHeights`, `NodeRole`, `nodeElevation`, `solveDownfeed`) | Engineer feedback: horizontal mains sit at the ceiling and a drop connects to the plant. Vertical length now = true-elevation deltas (ceiling mains, fixture height, plant datum), fixing material length + static lift; downfeed solve added for the roof-tank strategy. |
| 2026-06-22 | **MEP correctness audit pass** (3 parallel engineer-mind auditors → gated fixes) | Laminar friction (f=64/Re) + domain guards in hydraulics; TRUE partial-full drainage hydraulics; water sized from accumulated UBAP→Hunter (diversified, not summed peak flows); `_pickSource` picks the plant/lowest node not an arbitrary leaf; cross-curve demand test. Engine formulas confirmed correct; fixes were edge-cases + app integration. |
| 2026-06-22 | **iOS-grade polish pass** (heatmap legend, consistent schematic elevation labels, one-tap calibrate nudge) | Ease-of-use priority: residual-pressure legend makes the heatmap readable; uniform `+0.0/+4.0/+7.5 m` labels; an uncalibrated sheet surfaces a tappable "set scale" hint where runs otherwise measure zero. |
| 2026-06-22 | **Editing + selection** (select tool, `selection_store`, canvas hit-test overlay, inspector edit panel) | Tap a node/edge to select; edit its role (Junction/Fixture/Source-tank), fixture type, or edge service; delete with prune; all undoable. Role-distinct node glyphs (square=plant, ring=fixture, dot=junction) + selection highlight. |
| 2026-06-22 | **Feed strategy + occupancy** (upfeed pump vs roof-tank downfeed; residual field unified for the heatmap; SNI occupancy classes) | Covers the common installs: residential/office/assembly occupancy drives fixture-unit loads; upfeed picks the lowest node/plant as source, downfeed the highest/tank and reports gravity-OK or required booster head. |
| 2026-06-22 | **Per-fixture demand** (NetNode carries a `PlumbingFixture`; sizing accumulates per-node UBAP → Hunter, valve curve auto-selected) | Assigning real fixture types refines supply sizing beyond the flat default; flush-valve presence switches the demand branch. Persisted in the project file. |
| 2026-06-22 | **HVAC / ducting brought to plumbing depth** | New `fan.dart` (fan duty: air power Q·Δp, shaft, motor) + `duct_static.dart` (fan total static = index-run friction × fittings + terminal loss); rectangular duct sizing (`sizeRectangularByVelocity`, standard sides, equiv-diameter friction) + round velocity/equal-friction methods; `NetNode.airflow` diffuser demand accumulated down the duct tree; `EdgeSizing` carries W×H; HVAC inspector section (shape/method toggles + fan readouts), rectangular canvas labels, per-diffuser airflow editor. Persisted. |
| 2026-06-22 | **Per-zone PRV downfeed + return/exhaust air** | `downfeedZoneStatics` models the PRV setpoint per zone (top residual → bottom static, within-limit); `zonesProvider` now bounds zones by (max-fixture − target-residual) so PRV-fed zones stay under the SNI ceiling; Network panel shows worst-zone static + OK/over. Added `returnAir` + `exhaust` air services (regime/styling/palette); fan total static sums supply + return index runs; HVAC panel shows supply/return air balance. |
| 2026-06-22 | **Schema migration + tolerant load** (reviewer C3) | Unknown enum names fall back instead of throwing; newer file versions rejected with a clear message (migration hook left); `ProjectDocumentException` surfaces malformed files in a dismissible shell banner instead of a silent catch. |
| 2026-06-22 | **Sanitary DFU sizing + fittings BOM** (reviewer #5) | Drainage & vents now sized by accumulated Drainage Fixture Units via code capacity tables (branch vs stack vs vent), not Manning flow — `drainageFixtureUnit` + `drainDiameterForDfu`/`ventDiameterForDfu`, accumulated per fixture. `buildFittings` infers elbows/tees/crosses/reducers from node topology + size changes; BOM panel shows a fittings estimate and the CSV export now includes a fittings section. All `// VERIFY` vs SNI 8153. |

## 16. Testing strategy

- **Engine:** `package:test`, run with `dart test` in `packages/mechx_engine`.
  Seed suites hand-compute expected values from first principles and are the
  correctness anchor. Target **>90% coverage** (`dart test --coverage`).
- **UI:** `flutter_test` widget/integration tests; golden tests for the design
  system once it exists (P0).
- **Continuous green:** no phase advances on red.
