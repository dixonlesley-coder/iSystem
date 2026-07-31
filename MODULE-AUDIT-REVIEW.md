# MODULE-AUDIT-REVIEW — the whole-product correctness & honesty audit (2026-07-30)

> **STATUS (2026-07-30, same day): ALL FOUR WAVES LANDED** in two ultracode
> batches (wave 1 engine-only: G1 zoning/pressure, G2 sizing flags, G3
> fire/operating-point, G5 drawings; wave 2: G4 selectivity redesign, G6 app
> honesty + wave-D wiring, G7 reports/CSV/undo/autosave) — see the two §15
> rows. Every finding below is fixed or explicitly dispositioned. The E3/E4
> decision landed as **device-only, ampacity-capped**: feeder copper sizes on
> the load, the device floors toward 1.6× but never past the conductor's Iz,
> a fully-floored pair's `selectivity-partial` is suppressed
> (`feederFloorsApplied`), and a capped residual is REPORTED — which un-hid
> real findings the old floor was masking (the W-SIM fixture now honestly
> shows 6 non-selective + 2 cumulative-Vd + 1 feeder-below-fed-demand, all
> warning-tier). Recorded residuals: E7's inherent-imbalance note is noisy on
> 1-way boards (gate on way count if it reads badly); the schedule's FALLBACK
> conduit ladder still assumes 5 cores (conservative); M17's non-converged
> wiring is proven at the balance level only; `_kInkHalfThickness`/overview
> ladder pitches are drafting heuristics (`// VERIFY`); the detailed cooling
> basis models internal gains + ventilation only and its verify checklist is
> not yet fanned into Review; M12's operating-point module is FIXED but still
> unwired (the remaining wave-D product call); `SelectivityResult` lacks an
> `upstreamPanelId` (tests use a local lookup).

The plan of record for the next correctness campaign. Produced by a four-workstream
parallel audit run AFTER the warning-label fixes landed (selectivity floor, ONE
electrical warning surface, judge-layer honesty tiers — see the §15 rows):

- **W-MECH** — a read-only review of every mechanical engine module (19 findings,
  most confirmed with standalone `dart run` probes against `package:mechx_engine`).
- **W-RPT** — a read-only review of reports / exports / persistence (6 findings).
- **W-PDF** — the 16-artifact export harness run + byte checks + rasterized-sheet
  eyeballing (3 defects + 2 cosmetic; core healthy: 0 `?` glyphs, exact PDF↔DXF
  feeder-token parity, title blocks on all but 3 sheets).
- **W-SIM** — a complete 3-storey / 7-board / 38-way electrical design driven
  through the public engine API and interrogated as a reviewing engineer
  (committed as `packages/mechx_engine/test/whole_building_electrical_design_test.dart`,
  52 tests; the engine carried it with ZERO error/warning findings; 8 findings,
  each pinned by a `documented findings` test).

Findings carry their workstream id. Severity: **high** = wrong/unactionable output
reaching the user or deliverable · **medium** = silent gap or contradiction ·
**low** = polish/naming. Status: `open` unless marked.

---

## Theme 1 — Sizing verdicts that are wrong or unactionable (the class-1 disease)

- **M1 · high · CONFIRMED** — `network/zoning.dart` `computeDownfeedZones` budgets
  zones on FLOOR-SURFACE deltas but `downfeedZoneStatics` measures ceiling-main →
  fixture, adding `h_top − 1.4 m` unbudgeted: any building with >3.4 m floors gets
  auto-generated zones the engine's own static check rejects (12×4.0 m ⇒ 2 of 3
  zones at 407.5 vs 392.3 kPa), with no zone-count lever anywhere. Fix: budget the
  zoner against the same ceiling→fixture span (subtract the mounting offset).
- **M6 · high · CONFIRMED** — `sizing/duct_sizing.dart:308` rectangular
  `overCapacity` compares the IDEAL sides, so a compliant duct (achieved 4.56 m/s
  ≤ 5.0) still gets the red plan triangle + Review warning. Fix: flag from the
  achieved velocity.
- **M7 · high · CONFIRMED** — `air_warnings_store.dart` terminal branch judges
  ENGINE-stamped faces (`autoPlaceRoomTerminals`) against the 1.0 m/s minimum at
  the smallest catalogue face (150×150 ⇒ 0.69 m/s "too low", no smaller face
  exists). The exact disease the duct branch was fixed for. Fix: skip when the
  face equals the smallest catalogue entry (or is engine-placed).
- **M8 · medium · CONFIRMED** — `fire_sprinkler_hydraulic.dart` remote-head
  verdict ALWAYS fails at light hazard (2.25 L/min/m² split ⇒ 0.223 bar < 0.5)
  and its only lever (`firePerHeadKFactorProvider`) has no UI. Fix: re-derive the
  demand at `Q = K√P_min` (report the uplifted demand) or expose K and phrase the
  verdict as an action.
- **M9 · high · ANALYTIC** — `pressure_solve.dart` upfeed `requiredPumpHead` is
  defined as the max, so `residual ≥ target` BY CONSTRUCTION: the heatmap/probe
  PASS can never say LOW on upfeed. The 'all sheets calibrated' pattern on the
  pressure trust surface. Fix: judge against something falsifiable (available
  pump head / largest frame) and label the always-satisfied case "target held by
  design", not PASS.
- **M19 · low** — `fire_pump_rating.dart` `'Oversized pump curve'` verdict
  actually means the 75 kW STANDARD MOTOR ladder saturated. Rename honestly.

## Theme 2 — Computed but consumed nowhere (the class-2 disease)

- **M10 · high · CONFIRMED** — `network_store.dart` `autoPlaceRoomTerminals`
  places ONE return grille carrying `airflowEach` when the engine sized N (400 m²
  hall: 4 sized, 1 placed ⇒ 75 % under-return into the solve + BOM). Fix: loop
  `return_.count` like the supply branch.
- **M2 · high · CONFIRMED** — `sizeByEqualFriction` (round + rect) never consults
  `maxDuctVelocity`: equal-friction projects ship 8–10 m/s ducts, `overCapacity`
  false, and the auto-size gate keeps the velocity checker silent. Fix: step up
  until friction AND velocity caps hold.
- **M3 · medium** — storm downpipe `overCapacity` (catchment beyond DN200) is
  dropped by `autoSizeNetwork`; **M4 · medium** — water-supply `overVelocity`
  likewise, and `waterVelocityChecksProvider` never fans into Review (an
  `sniVerbatim` 2.0 m/s violation ships silently). Fix: thread both onto
  `EdgeSizing` + fan the water checks into `designIssuesProvider`.
- **M5 · medium · CONFIRMED** — drainage self-cleansing (v ≥ 0.6 m/s) is never
  applied on the DFU path while the shown drain band (max 3.0 m/s) is
  mathematically unreachable (table max 1.12 m/s): DN40/DN50 branches run at
  0.46–0.54 m/s labelled OK. Fix: check self-cleansing on the DFU path; gravity
  band `min: 0.6`.
- **M11 · medium** — `selectMotor` clamps at 75 kW with no flag on
  `PumpDuty`/`FanDuty` (a 90 kW duty prints a 75 kW motor everywhere). Fix: the
  `oversized` boolean `FirePumpRatingResult` already carries.
- **M16 · low** — `EdgeSizing.stackRaisedForBranch` has zero consumers (its doc
  promises a per-edge note). **M17 · low** — Hardy-Cross non-convergence is
  unobservable (`iterations` unread; practical exposure low, 3–5 iterations on
  probes). **M18 · low** — `applySizeOverride` drops `overCapacity`/
  `stackRaisedForBranch` and zeroes a drainage override's velocity.

## Theme 3 — The issued electrical deliverable (W-SIM + W-PDF)

- **E1 · high · CONFIRMED** — the board schedule's kA token is per-PANEL
  (`breakerIcuKaByPanelId` = the incomer's frame ladder), so an MCCB-incomer
  board stamps `MCB 40A 3ph 16kA` — a rating no MCB is built to (MCB ladder
  6/10/15/25) — on every outgoing way; a mixed MCB/MCCB board cannot be right.
  Fix: per-CIRCUIT kA (`fault.circuits[id].breakerKa` already exists).
- **E2 · high · CONFIRMED** — three contradicting containment bases for one run:
  the schedule's `_conduitMm` CSA ladder (`PVC 40mm`), the containment study's
  OD/fill result (32 mm; 63 mm at 72.2 % fill for a 150 mm² feeder the schedule
  calls `tray`), and the ampacity method (`conduit`). The Wave-7 PDF-vs-DXF
  disease one layer up. Fix: one containment source feeding both.
- **E3 · high · JUDGEMENT** — the 1.6× selectivity floor drags the CABLE with the
  device (Iz ≥ In): PP-1 at 42.9 A gets a 160 A MCCB on 5×150 mm²; a 5 kW 1φ
  board gets 80 A on 3×50 mm². Real practice discriminates with MCCB settings,
  not conductor copper. Fix directions (to be decided together with E4): floor
  the DEVICE but cap it at the load-sized cable's `maxRatingA`; or floor against
  the child's demand rather than its rounded-up + headroom-uplifted incomer.
- **E4 · medium · CONFIRMED** — the floor targets exactly `selectivityRatio`, and
  `classifySelectivity` calls [1.6, 2.5) "partial": every floored feeder lands in
  the partial band by construction (6/6 `selectivity-partial` advisories on a
  clean design). Fix: either target `totalSelectivityRatio` (worsens E3) or
  suppress the partial advisory for engine-floored pairs (it is the engine's own
  best trade-off, not a finding).
- **E6 · medium** — a `lifeSafety` fire pump gets ordinary thermal-magnetic
  overload protection (32 A curve D like any motor); NFPA 20 / Indonesian
  practice wants protection that will NOT trip on overload during a fire.
  `lifeSafety` currently only suppresses the RCD + selects FRC. Fix: a fire-pump
  protection rule in the sizing path (`// VERIFY` its basis).
- **E7 · low** — a 37.9 % INHERENT phase imbalance (two equal 1φ heaters) is now
  correctly warning-free but appears only on the schedule footer. Fix shape: an
  info-level "inherent imbalance NN % — consider a third leg / 3φ load" note.
- **E5 · low · JUDGEMENT** — `demandFactor` shrinks the FINAL circuit's own
  device (2.8 kW × 0.7 sockets on a 10 A MCB beside a 3.0 kW neighbour on 16 A);
  defensible IEC Ib, but panel builders will query it. Consider excluding final
  socket ways from own-device diversity (practice: uniform 16 A / 2.5 mm²).
- **E8 · low** — (a) 1φ feeder Vd computed at the parent's 231 V while the fed
  220 V board's ways use 220 (mixed bases in the cumulative chain); (b) `1ph`
  where `2P` is conventional for that feeder token; (c) `_conduitMm` is not
  fill-checked (5×70 mm² ⇒ 50 mm is physically impossible); (d)
  `service-capacity-inadequate` reads like a supply check but is the Ics check.
- **X1 · medium · CONFIRMED** — mech riser SLD plant-cluster label collisions
  ("Ground tank · 5.0 m3" struck through by the run + booster tags overlapping);
  the live canvas got its collision pass, `mechanical_sld_drawing.dart` didn't.
- **X2 · medium · CONFIRMED** — `buildElectricalOverview` feeder labels at a bus
  split overprint (the riser builder's collision pass was never mirrored).
- **X3 · low · CONFIRMED** — `elec-overview/riser/layout` PDFs omit `SHEET i of N`
  (harness's `elecChromeFor` sets no `sheetIndex`/`sheetTotal`; audit the app
  export call sites for the same omission).
- **X4/X5 · low** — plan label crowding at one junction; mixed comma/period
  decimals in the calc report's Indonesian sentences.

## Theme 4 — Reports, CSV, persistence (W-RPT)

- **R1 · high · CONFIRMED** — the electrical calc report + unified MEP report
  feed `ElectricalCalcReportData` from `electricalResultProvider` (core-only):
  the ISSUED deliverable omits every fault-study warning (incl. error-severity
  breaking-capacity) that Review/compliance show — the surfacing fix, one layer
  deeper. Fix: both call sites read `electricalAllWarningsProvider`.
- **R2 · high · CONFIRMED** — the app's only BOM CSV export (`bomCsvWithCutPlan`)
  omits `material` and the I5 `*` manual-override column; the engine's `bomToCsv`
  (which has both) is never called by the app. A cutting crew cannot tell PPR
  from PVC on the takeoff. Fix: merge the columns (or delegate + append cut-plan
  columns).
- **R3 · medium · CONFIRMED** — domain undo stacks cap at 200, the global
  timeline at 1000: past 200 same-domain edits, Undo pops the timeline, pretends
  success, reverts nothing (phantom entries; Redo also no-ops). Fix: align the
  caps (or detect the no-op and drop the stale tag).
- **R4 · medium · CONFIRMED** — `_autosaveTick`'s `writeRecovery` is un-awaited,
  defeating the documented `tickInFlight` overlap guard (two slow ticks can race
  the same `.tmp`/`.bak` siblings, exceptions swallowed). Fix: `await` it.
- **R5 · medium · tracked residual** — `serviceFaultEstimateVerifyItems` still
  never reaches `AdvancedStudy.verifyItems`/the printed Unverified section while
  the estimate drives printed kA tokens. Fix: append conditionally when the
  estimate resolved.
- **R6 · low** — `DesignSettings.coolingLoadMethod` / `multiZoneDiversityFactor`
  / `multiZoneExhaustStrategy` round-trip in `.mechx` but are set/read by
  NOTHING; `cooling_load_detailed.dart` (434 lines) + `multiZoneAirSystem` +
  `operating_point.dart` (**M12**: dead, `stable` vacuous, NPSH basis physically
  wrong — 15 % of TOTAL head) are unreachable from the app. Decide: wire them
  (each is a real feature) or drop the dead settings so `.mechx` doesn't imply
  capability that isn't there. **M13/M14** belong here too: the Legionella check
  (60 − 5 = 55 exactly, `< 55` never true) and the min-slope advisory (all six
  call sites pass the const 0.01) are dark until ΔT/flow-temp/slope become real
  design inputs.

## Verified healthy (the coverage record)

Hydraulics formulas hand-checked (Darcy, H-W SI, Manning, partial-full factor);
Hardy-Cross loop construction + continuity verified numerically; rooting/
accumulation (incl. the once-curved looped UBAP) sound; per-edge material folds
pure; `connectivity.dart` called out as the model module (honest skips, real
actions); fire standpipe/sprinkler tables match cited SNI; `.mechx` round-trip
exhaustive (every model field paired, tolerant); API-key migration correct;
atomic-write recovery mechanics correct; zero-length export guard covers all
export paths; `value`+`unit` rule held everywhere but one guarded fallback;
0 `?` glyphs and exact PDF↔DXF feeder parity across the 16-artifact set; the
engine carried a complete realistic building with zero error/warning findings.

## Suggested sequencing

1. **Wave A — wrong verdicts + lost sizing flags** (M1, M2, M6, M7, M9, M10,
   M3+M4+M5, M11): the user-facing lies and silent undersizings.
2. **Wave B — the issued electrical deliverable** (E1, E2, R1, R2, E3+E4
   [one decision], E6, X1, X2, X3, R5): what a panel builder / foreman receives.
3. **Wave C — platform integrity** (R3, R4, M16, M17, M18, E5, E7, E8, M8, M19,
   X4, X5).
4. **Wave D — dead-feature policy** (R6+M12+M13+M14+M15): wire or remove, per
   product owner's call.
