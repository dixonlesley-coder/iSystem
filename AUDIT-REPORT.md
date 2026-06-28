# iSystem Codebase Audit — Apple-designer + Senior-MEP-engineer lens

_Multi-agent audit: 70 subagents, 56 raw findings, 50 verified after adversarial filtering._

## Executive summary

iSystem is an unusually disciplined codebase — a genuinely pure-Dart engine, an honest // VERIFY provenance surface, a coherent custom design system, and impressive M+E+P breadth. But two classes of defect should block a permit-grade release. First, the calc engine has a hard-crash / data-loss path: air-duct sizing THROWS ArgumentError (not an over-flag) when a trunk exceeds the largest standard size, aborting the ENTIRE network solve — every pipe, drain, and panel goes unsized — for a scenario (a large central AHU trunk in a high-rise) that is routine in Indonesia. Second, two silent-undersize/under-protection paths exist on the electrical side: a cable that cannot reach the required ampacity is returned with NO warning so the breaker no longer protects the conductor (In > Iz, an IEC 60364-4-43 / PUIL coordination violation), and TT feeders fall through both the RCD net and the ADS net with no earth-fault protection modelled. Layered on top are correctness-of-deliverable gaps an MEP engineer staking a permit would not tolerate: runs drawn on an uncalibrated sheet silently size to zero length, a disconnected/unfed branch sizes and reports as if supplied, opening a plumbing-only project injects a fictitious sample switchboard into the BOM/schedule/report, and all six exports write files with zero success/failure feedback. From the Apple-designer lens the app is polished but has trust-eroding state bugs: the status bar permanently reads "Uncalibrated" even on calibrated sheets, the standards-provenance dot is permanently lit, the Review hub still ships "coming together" placeholder prose with no on-screen pass/fail sign-off, and the theme toggle's label contradicts its action. The engine math is largely sound and conservatively flagged; the risk concentrates in robustness, missing validation/warnings, and feedback — exactly the seams where a wrong-but-plausible deliverable leaves the building.

## Top priorities (ordered by leverage)

### #1 · [CRITICAL] Air-duct sizing throws ArgumentError and aborts the WHOLE network solve on an oversize trunk
- **Category:** MEP sizing correctness / robustness
- **Location:** `packages/mechx_engine/lib/sizing/duct_sizing.dart:164-171, 211-216 (called unguarded at network_sizing.dart:234-242 and room_air.dart:244,250)`
- **Why it matters:** There is no try/catch anywhere in the engine, so a single supply-air trunk exceeding 1000 mm round (a big AHU room, or a low equal-friction target at high flow — routine in a high-rise) throws straight out of autoSizeNetwork/sizeRoomAir and leaves the ENTIRE network unsized: every pipe, drain, and panel. Every other regime (water overVelocity, drainage DN300 clamp, storm overCapacity) returns an over-flag; even this file's own rectangular sizer CLAMPS (orElse: ...sidesMm.last). This is a hard crash + total data-loss path.
- **Fix:** Make sizeByVelocity and sizeByEqualFriction clamp to the largest standard size and return an over-capacity flag (mirror WaterSupplySizingResult.overVelocity / RainwaterSizingResult.overCapacity); surface it as a per-edge design issue. Never throw out of a whole-network solve for one oversize edge.

### #2 · [CRITICAL] Cable that can't reach required ampacity returns silently — breaker no longer protects it (In > Iz)
- **Category:** Electrical safety / PUIL coordination
- **Location:** `packages/mechx_engine/lib/electrical/sizing.dart:311-324; compute.dart (no warning, cf. only incomer-exceeds-range at :834)`
- **Why it matters:** When even 4 parallel runs of the largest section can't meet Iz, sizeCable returns the largest section with deratedIz BELOW the breaker In and appliedRule='exceeds-range', but _computeCircuit emits NO warning for this case and CableResult has no adequacy flag. The engineer gets a plausible 4x300mm2 schedule with an overcurrent device that does not protect the conductor against overload (IEC 60364-4-43 / PUIL cl. 2.2.8.3 In<=Iz violated) and zero indication.
- **Fix:** Add bool adequate/ampacityReached to CableResult; have _computeCircuit emit a WarningSeverity.error 'cable-ampacity-inadequate' when deratedIz < breakerRating. Mirror the over-flag the water/duct paths get.

### #3 · [HIGH] TT feeders get NO earth-fault protection — fall through both the RCD net and the ADS net
- **Category:** Electrical safety / earthing
- **Location:** `packages/mechx_engine/lib/electrical/earthing.dart:270-277; fault.dart:594-611 (Zs/ADS gated on isTn only)`
- **Why it matters:** circuitRcd requires an RCD only for TT && isFinalCircuit, so a TT sub-main (isFeeder => isFinalCircuit=false) gets required:false; meanwhile the fault study deliberately skips Zs/ADS for TT because it assumes the RCD handles it. The net: a TT feeder's cable earth fault is checked by NEITHER an RCD NOR ADS, unprotected and unwarned. PUIL/IEC 60364 require a (time-delayed/S-type) RCD on TT distribution circuits too.
- **Fix:** On TT, require a time-delayed/S-type RCD on feeders as well (or compute the TT earth-loop adequacy); at minimum emit a warning that a TT feeder has no modelled earth-fault protection.

### #4 · [HIGH] Horizontal runs on an uncalibrated sheet silently size to zero length — optimistic, exportable, wrong
- **Category:** MEP correctness / missing validation
- **Location:** `packages/mechx_engine/lib/network/network.dart:617-619; lib/ui/canvas/drawing_overlay.dart:60-70; design_issues_store.dart:156-166`
- **Why it matters:** Drawing is fully enabled before calibration; edgeLength returns Length(0) for an uncalibrated run, so the solve computes zero friction and the BOM records zero pipe — an optimistic pump duty, clean heatmap and understated take-off that LOOK valid. The only feedback is a soft per-sheet warning that also fires on a blank imported sheet and never escalates or blocks export. Calibration is the §10 single source of truth for all length.
- **Fix:** Escalate the uncalibrated-sheet issue to critical/blocking when that sheet actually carries drawn edges, and gate calc-report/BOM/PDF export behind a confirm-or-cancel banner when any sized edge resolves to zero geometric length. Optionally disable the Draw-run tool until calibrated.

### #5 · [HIGH] No connectivity / unfed-network validation — a sourceless or disconnected branch sizes and reports as if fed
- **Category:** MEP correctness / missing validation
- **Location:** `lib/store/design_issues_store.dart (no check); packages/mechx_engine/lib/sizing/network_sizing.dart pickRoot fallback`
- **Why it matters:** autoSizeNetwork roots each component at a source if present, else heuristically on a leaf/junction — so a plumbing group with no plant, or one accidentally disconnected from the riser, still gets rooted, sized, and produces a pump duty + heatmap with no indication it isn't connected to a supply. designIssuesProvider checks velocity, unsized air, calibration and standards, but nothing for 'component has no source' or 'disconnected island'. The electrical canvas already flags 'not connected'; the mechanical side lacks parity (Revit/AutoCAD MEP both flag unfed systems).
- **Fix:** Add a designIssuesProvider check that flags any pressurized/air component lacking a plant/source and any node-island disconnected from its service's rooted tree, as a locatable issue the engineer can jump to before export.

### #6 · [HIGH] Opening a plumbing-only project injects the SAMPLE electrical switchboard into BOM / schedule / reports
- **Category:** Deliverable integrity / data leak
- **Location:** `lib/data/autosave.dart:151-152; lib/store/electrical_store.dart (default build seeds sampleElectricalProject)`
- **Why it matters:** applyDocument falls back to sampleElectricalProject() when a .mechx has no electrical sub-model (v1 file or plumbing-only). A purely mechanical project silently acquires a fictitious panel/circuit set that flows into the electrical BOM, equipment schedule, unified MEP report and the Review 'Panels sized' count. An engineer issuing a plumbing-only package can unknowingly ship a sample switchboard and its costed quotation, with no 'sample data' banner. The same sample also seeds first-run with no clean 'New empty project'.
- **Fix:** Default to an EMPTY ElectricalProject when a file carries no electrical model; gate the sample behind an explicit 'Load sample electrical' action; add a 'New empty project' command. At minimum tag sample-origin data and flag/exclude it in BOM, schedule and reports.

### #7 · [HIGH] All six exports write files with zero success/failure feedback and no completeness guard
- **Category:** Deliverable integrity / UX
- **Location:** `lib/ui/inspector/project_panel.dart:103-116 (and :164,209,327,352,382); projects_screen.dart:64-91`
- **Why it matters:** Every export (calc report, MEP report, equipment schedule, DXF, PDF, annotated plan PDF) writes and returns with no try/catch, no status pill, no error banner — despite the app already using statusMessageProvider/showStatus + loadErrorProvider for Save/Open/Import. If File.writeAsString throws (locked path, permissions, full disk) the future rejects silently and the engineer believes a permit deliverable was produced when it was not. No guard for empty/unsized/uncalibrated state either.
- **Fix:** Wrap each export in try/catch; on success call showStatus('Exported <name>') (reuse the pill), on failure surface loadErrorProvider. Warn (not silently write) when the network is empty/unsized.

### #8 · [MEDIUM] Status bar permanently reads 'Uncalibrated' even on a fully calibrated sheet
- **Category:** UX clarity / trust
- **Location:** `lib/ui/app_shell.dart:451-462`
- **Why it matters:** The persistent status bar unconditionally renders StringKey.shellUncalibrated whenever a sheet exists, never reading project.calibrationFor(sheet.id). Calibration is the source of truth for all length-derived sizing, so the one always-visible status about it is permanently wrong — actively eroding trust in every other status the bar shows. The Layout canvas, sheet rail and inspector all compute this correctly; only the status bar hardcodes the negative.
- **Fix:** Read projectControllerProvider.calibrationFor(sheet.id) in _StatusBar and swap label/dot to a 'Calibrated · 1:N' success state when non-null, reusing the sheet-rail _CalibrationGlyph cue.

### #9 · [MEDIUM] Review hub ships 'coming together' placeholder prose with no on-screen pass/fail sign-off
- **Category:** UX clarity / confidence
- **Location:** `lib/ui/review/review_hub.dart:43-44; ComplianceSummary built only at project_panel.dart:122-159`
- **Why it matters:** The one screen named 'Review' — where a senior engineer signs off before issue — admits it is a partial shell and shows only counts + IssuesCard. The actual ComplianceSummary pass/fail roll-up is already computed but exists ONLY inside the exported Markdown report, so the engineer's go/no-go verdict appears only AFTER generating the deliverable, not before. Contradicts the team's own declutter campaign that removed placeholder prose elsewhere.
- **Fix:** Render the already-computed ComplianceSummary pass/fail roll-up on the Review hub plus a pre-issue completeness checklist (every sheet calibrated, floor-mapped, network has a source, sized), and remove the placeholder prose.

### #10 · [MEDIUM] Rectangular ducts silently ignore the equal-friction method and are always velocity-sized
- **Category:** MEP method fidelity / report honesty
- **Location:** `packages/mechx_engine/lib/sizing/network_sizing.dart:217-233; room_air.dart:236-243`
- **Why it matters:** sizeEdge branches on ductShape FIRST: rectangular unconditionally calls sizeRectangularByVelocity regardless of ctx.ductMethod, and there is no rectangular equal-friction sizer. An engineer who picks rectangular + equal-friction gets velocity-sized ducts with no warning, and the calc report implies a method that was not applied.
- **Fix:** Add a rectangular equal-friction path (derive the equivalent-diameter target and round each side), or at minimum surface a warning that equal-friction is not applied to rectangular ducts.

### #11 · [MEDIUM] Looped water-supply mains lose Hunter diversification — per-node curve flows are summed, over-sizing the ring
- **Category:** MEP sizing efficiency
- **Location:** `packages/mechx_engine/lib/sizing/network_sizing.dart:483-503`
- **Why it matters:** For a looped pressurized water component, each node's raw UBAP is run through the Hunter curve individually then summed as independent nodal demands, so the source carries the SUM of per-fixture curve flows. The whole point of UBAP+Hunter (and the tree path at :577-589) is to curve the SUMMED units once. A ring serving many fixtures is over-sized ~1.5x+. Non-conservative only in cost/efficiency (over-size, never under-supply), and only when fixture-bearing nodes sit on the loop itself.
- **Fix:** For looped water supply, accumulate fixture UNITS to the loop boundary, apply the Hunter curve once to the total, then split that single diversified flow with Hardy-Cross — do not curve-convert each node independently.

### #12 · [LOW] Calibration distance field defaults to '1.0' and commits with no plausibility check
- **Category:** MEP correctness / UX guardrail
- **Location:** `lib/ui/canvas/calibration_overlay.dart:27-40`
- **Why it matters:** The known-distance field is pre-seeded with '1.0' and _commit accepts any value > 0 with no sanity check against the marked pixel span and no resulting-scale preview. A slipped 'Set scale' calibrates the sheet to ~1 m across that span, silently corrupting every length/friction/pump/BOM figure. Requires deliberate two-point marking so an engineer often catches the absurd lengths, but the footgun is real.
- **Fix:** Use an empty placeholder (not a committable default) and after entry show the implied scale and full-sheet extent (e.g. 'sheet ≈ 38.4 × 24.1 m') so an order-of-magnitude error is caught before commit; optionally warn on an out-of-band metres-per-pixel.

## Findings by theme

### MEP sizing correctness & robustness

#### [CRITICAL] Air-duct sizing throws and aborts the entire solve on oversize flow
- **Location:** `packages/mechx_engine/lib/sizing/duct_sizing.dart:164-171, 211-216; network_sizing.dart:234-242; room_air.dart:244,250`
- **Detail:** sizeByVelocity and sizeByEqualFriction throw ArgumentError when the required round duct exceeds the largest standard size (1000 mm) or the equal-friction target is unreachable. With no try/catch anywhere in the engine, this propagates out of autoSizeNetwork/sizeRoomAir and leaves the entire network (every pipe, drain, panel) unsized. Every other regime returns an over-flag, and this file's own rectangular sizer clamps instead of throwing — a self-inconsistency.
- **Fix:** Clamp to the largest size and return an overVelocity/overFriction flag; surface as a per-edge design issue.

#### [MEDIUM] Rectangular ducts silently ignore the equal-friction method
- **Location:** `packages/mechx_engine/lib/sizing/network_sizing.dart:217-233; room_air.dart:236-243`
- **Detail:** Shape is branched on first; rectangular always uses sizeRectangularByVelocity regardless of ctx.ductMethod, and no rectangular equal-friction sizer exists. The chosen design method is silently overridden and the report implies equal-friction that was never applied.
- **Fix:** Add a rectangular equal-friction path or warn that equal-friction is not applied to rectangular ducts.

#### [MEDIUM] Looped water mains lose Hunter diversification (per-node curve flows summed)
- **Location:** `packages/mechx_engine/lib/sizing/network_sizing.dart:483-503 (vs tree path :577-589)`
- **Detail:** In the looped pressurized branch each node's raw UBAP is curve-converted individually then summed as independent nodal demands, so the source carries the sum of per-fixture curve flows instead of the curve of the summed units — over-sizing rings ~1.5x+. Bounded: cost-direction only, and only when fixtures sit directly on the loop.
- **Fix:** Accumulate units to the loop boundary, apply the curve once, split the single diversified flow with Hardy-Cross.

#### [POLISH] Drainage sizeForFlow docstring claims linear fill-ratio capacity while code uses true partial-full
- **Location:** `packages/mechx_engine/lib/sizing/drainage_sizing.dart:186-195`
- **Detail:** The docstring states Q_usable = Q_full × fillRatio, but the code correctly uses partialFullCapacityFactor (≈0.912 at r=0.75), matching the library header. Doc-only; agrees at the default r=0.5, but misleads a reviewer hand-deriving sizes at other fill ratios.
- **Fix:** Update the docstring to reference partialFullCapacityFactor (the true partial-full discharge ratio).

### Electrical correctness & safety

#### [CRITICAL] Cable that can't reach required ampacity returns with no warning (In > Iz)
- **Location:** `packages/mechx_engine/lib/electrical/sizing.dart:311-324; compute.dart _computeCircuit (no ampacity warning)`
- **Detail:** When 4 parallel runs of the largest section still fall short of Iz, sizeCable returns the largest section with deratedIz below the breaker In and appliedRule='exceeds-range', but no warning is emitted and CableResult has no adequacy flag. The breaker no longer protects the conductor (IEC 60364-4-43 / PUIL cl. 2.2.8.3) and nothing downstream can detect it.
- **Fix:** Add an adequacy flag to CableResult and emit a WarningSeverity.error 'cable-ampacity-inadequate' when deratedIz < breakerRating.

#### [HIGH] TT feeders get no earth-fault protection (RCD only on final circuits, ADS skipped for TT)
- **Location:** `packages/mechx_engine/lib/electrical/earthing.dart:270-277; fault.dart:594-611`
- **Detail:** circuitRcd requires an RCD only for TT && isFinalCircuit; a TT feeder (isFeeder) gets required:false, and the fault study skips Zs/ADS for TT assuming the RCD covers it. A TT sub-main earth fault is therefore checked by neither net, unprotected and unwarned.
- **Fix:** Require a time-delayed/S-type RCD on TT feeders (or compute TT earth-loop adequacy); at minimum warn.

#### [MEDIUM] Motor circuits sized from shaft kW, not motor FLC — breaker/cable can be undersized vs nameplate
- **Location:** `packages/mechx_engine/lib/electrical/compute.dart:577-584`
- **Detail:** For a hand-entered motor with no flaOverrideA, Ib = P/(sqrt3·V·cosphi) from shaft kW with no efficiency divisor (TODO 'motor FLC table (A8)'). True FLA is ~11-18% higher (÷ eta 0.85-0.9), so the breaker (In>=Ib) and 1.25·Ib cable rule sit on an understated current. The A5 mechanical feed supplies flaOverrideA correctly, so only hand-entered motors take the undersized path.
- **Fix:** Divide shaft kW by an assumed motor efficiency (// VERIFY) before computing FLA, or interpolate a motor FLC table.

#### [MEDIUM] Busbar withstand verdict uses 0.1 s clearing time but bars are rated on the 1 s Icw basis, unchecked against the actual device
- **Location:** `packages/mechx_engine/lib/electrical/busbar.dart:50-54; lib/store/electrical_store.dart:103,121`
- **Detail:** icwKa = density·csa/1000 / sqrt(t) with the live t=0.1 s inflates apparent withstand 3.16x vs the declared 1 s Icw, so the 'adequate' verdict can pass bars that would fail at their rated Icw. Nothing verifies the upstream device actually clears in <=0.1 s (a selective time-delayed incomer does not), and the report prints a bare OK with no surfaced clearing-time caveat. The model carries no incomer trip-class field to couple this to.
- **Fix:** Size on the declared 1 s Icw, or derive the clearing time from the upstream device's instantaneous-trip status and warn when it is time-delayed; surface the assumed clearing time next to the verdict.

#### [POLISH] Zs loop fault-temperature factor base is documented in words but not derived
- **Location:** `packages/mechx_engine/lib/electrical/fault.dart:606-611`
- **Detail:** The 1.28 factor lifts R toward the PVC fault limit but is applied on top of an already-70C resistance table; the net Zs is conservative (safe, over-strict on ADS) and 1.28 is actually consistent with a 70C->~160C base, so this is a documentation/clarity nit on an already // VERIFY-tagged value.
- **Fix:** Document/verify the temperature base of the 1.28 factor so the ADS reject threshold is defensible in a permit review.

### Missing validation & deliverable integrity

#### [HIGH] Runs drawn on an uncalibrated sheet silently size to zero length
- **Location:** `packages/mechx_engine/lib/network/network.dart:617-619; lib/ui/canvas/drawing_overlay.dart:60-70; design_issues_store.dart:156-166`
- **Detail:** Drawing is enabled pre-calibration; edgeLength returns Length(0), so friction, pump duty, heatmap and BOM all read optimistically and the report looks valid. The only feedback is a soft per-sheet warning that also fires on blank sheets and never blocks export.
- **Fix:** Escalate to critical/blocking when an uncalibrated sheet carries drawn edges; confirm-or-cancel before export when any sized edge is zero-length.

#### [HIGH] No connectivity / unfed-network validation
- **Location:** `lib/store/design_issues_store.dart (no check); network_sizing.dart pickRoot fallback`
- **Detail:** A sourceless or accidentally-disconnected plumbing component still gets rooted heuristically, sized, and produces a pump duty + heatmap with no warning. designIssuesProvider has no 'no source'/'disconnected island' check, despite the electrical canvas flagging 'not connected'.
- **Fix:** Flag (warning/critical) any pressurized/air component with no plant/source and any node-island disconnected from its service tree, as a locatable issue.

#### [HIGH] Opening a plumbing-only project injects the sample electrical switchboard
- **Location:** `lib/data/autosave.dart:151-152; lib/store/electrical_store.dart (sampleElectricalProject)`
- **Detail:** applyDocument falls back to sampleElectricalProject() when a file has no electrical model, so a mechanical-only project silently acquires a fictitious panel/circuit set that flows into BOM, equipment schedule, unified report and 'Panels sized' count, with no sample-data banner. Same sample also seeds first-run; there is no 'New empty project'.
- **Fix:** Default to an empty ElectricalProject; gate the sample behind an explicit action; add a clean 'New empty project'; tag/exclude sample-origin data from deliverables.

#### [HIGH] Exports give zero success/failure feedback and no completeness guard
- **Location:** `lib/ui/inspector/project_panel.dart:103-116, 164, 209, 327, 352, 382; projects_screen.dart:64-91`
- **Detail:** All six export actions write and return with no try/catch, no status pill, no error banner — despite Save/Open/Import already using statusMessageProvider/showStatus + loadErrorProvider. A silent File write failure leaves the engineer believing a permit deliverable was produced. No guard for empty/unsized/uncalibrated state.
- **Fix:** Wrap in try/catch; showStatus on success, loadErrorProvider on failure; warn rather than silently write on an empty/unsized network.

#### [MEDIUM] Sheet->floor mapping defaults to import order and is silently outside undo
- **Location:** `lib/store/sheets_store.dart:39-41,84-87; building_screen.dart:84-90`
- **Detail:** floorFor defaults to rail/import position, so PDFs imported out of building order take the wrong §10 elevation delta with no warning. setSheetFloor mutates state with no snapshot, so re-assigning a floor (which changes computed riser lengths) cannot be undone, unlike floor height/calibration. Mitigated by a visible Building-screen picker.
- **Fix:** Route floor assignment through the undo timeline and warn when an unmapped/default mapping is relied on for a multi-floor building.

#### [LOW] Calibration distance defaults to '1.0' and commits with no plausibility check
- **Location:** `lib/ui/canvas/calibration_overlay.dart:27-40`
- **Detail:** The field is pre-seeded '1.0' and _commit accepts any value > 0 with no sanity check vs the pixel span and no resulting-scale preview, so a slipped Set-scale yields a ~1:1 wrong scale that corrupts every downstream length. Requires deliberate marking, so often caught, but a real footgun.
- **Fix:** Empty placeholder + post-entry implied scale and full-sheet extent preview; optional out-of-band metres-per-pixel warning.

### UX clarity, states & Apple polish

#### [MEDIUM] Status bar permanently reads 'Uncalibrated' even on calibrated sheets
- **Location:** `lib/ui/app_shell.dart:451-462`
- **Detail:** _StatusBar unconditionally renders shellUncalibrated whenever a sheet exists, never reading calibrationFor(sheet.id) — the one always-visible status about the §10 source of truth is permanently wrong, while the sheet rail, Layout canvas and inspector all compute it correctly.
- **Fix:** Read calibrationFor(sheet.id) and swap to a 'Calibrated · 1:N' success state, reusing the _CalibrationGlyph cue.

#### [MEDIUM] Review hub ships placeholder prose with no on-screen pass/fail sign-off
- **Location:** `lib/ui/review/review_hub.dart:43-44; ComplianceSummary at project_panel.dart:122-159`
- **Detail:** The 'Review' screen admits it is a partial shell and shows only counts + IssuesCard; the already-computed ComplianceSummary pass/fail roll-up lives only in the exported Markdown, so the go/no-go verdict appears after, not before, generating the deliverable. Contradicts the team's own declutter passes.
- **Fix:** Render the ComplianceSummary roll-up + a pre-issue completeness checklist on the hub; drop the placeholder prose.

#### [LOW] Theme toggle label names the current mode, not the action
- **Location:** `lib/ui/app_shell.dart:399-405`
- **Detail:** The button reads 'Dark' while in dark mode but toggles to light — label and action disagree, with no icon/switch/segmented cue. Low stakes (instantly reversible, globally visible) but an Apple-grade control would state the action or use a sun/moon segment.
- **Fix:** Label it as the action ('Switch to Light') or replace with a MechXSegment sun/moon control.

#### [POLISH] Standards-provenance warning dot is permanently lit regardless of state
- **Location:** `lib/ui/app_shell.dart:488-503`
- **Detail:** The bottom-right group always renders an orange warning dot beside a fixed provenance caption, never reading designIssuesProvider/verifyChecklist counts. A never-changing warning reads as decoration and competes with genuine contextual warnings. (Defensible as an always-true 'draft SNI' caution, so a taste call.)
- **Fix:** Tie the dot to a live unverified-value count, or demote it to a quiet non-warning provenance label.

#### [LOW] Collapsed nav rail leaves destinations unlabeled with no tooltip fallback
- **Location:** `lib/ui/shell/nav_rail.dart:368-369, 392-395`
- **Detail:** In the 52px collapsed rail, destinations render as bare custom glyphs with no caption and no hover tooltip (acknowledged in-code: Tooltip needs Material). Defaults to expanded and is a user-initiated collapse, so a recall gap rather than a discovery wall — but still no text affordance for icon-only nav.
- **Fix:** Build a lightweight MechXTheme hover popover (reuse the existing canvas_guide_popover overlay) to label collapsed rail items.

#### [POLISH] AC 'PK requirement' and the selection ladder use inconsistent BTU/h-per-PK
- **Location:** `packages/mechx_engine/lib/sizing/cooling_load.dart:28,71-80,123; project_panel.dart:1145-1154`
- **Detail:** CoolingLoad.pk = BTU/h ÷ 9000 (strict) while selectAc walks a non-linear market ladder, so the raw 'PK requirement' and the recommended-unit PK shown on adjacent inspector lines can disagree (e.g. 13000 BTU/h shows 1.4 PK required vs 2.0 PK each). Documented convention, annotation-only, no calc impact.
- **Fix:** Derive the displayed PK from the same ladder, or clearly separate 'raw load PK' from 'recommended unit PK'.

#### [POLISH] Electrical canvas uses a bespoke toast while the rest of the app uses the status pill
- **Location:** `lib/ui/electrical/electrical_canvas.dart:287,317-331`
- **Detail:** Rejected feeder connections surface via a one-off _Toast overlay that exists nowhere else; the app already has a shared statusMessageProvider pill. A divergent feedback primitive in work that was explicitly converged toward one interaction language.
- **Fix:** Route rejected operations and completed actions through the shared statusMessageProvider pill on both canvases.
