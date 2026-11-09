# iSystem — known gaps, campaigns and release history

Moved out of `CLAUDE.md` (2026-11-09) so agents do not load it on every turn. Read the part you need; `CLAUDE.md` keeps the guardrails and conventions.


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
