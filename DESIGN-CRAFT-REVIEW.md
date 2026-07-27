# Design-craft review — all pages (2026-07-27)

A design-skills pass over every page of iSystem v1.20.0, run AFTER the four prior campaigns
(UX-workflow 83, CAD-output 78, Apple-design 8 themes, workflow-goldens 109) all landed. Those
campaigns fixed honesty, workflow, and deliverable fidelity; this one targets the layer none of
them systematized: **micro-interaction feel, a motion system with an accessibility gate,
numeric-display craft, and per-page layout rhythm** — the "unseen details [that] compound"
(Kowalski) and Apple's craft principle, translated from their web idiom into this repo's
Flutter + MechXTheme terms.

Inputs: all 16 committed goldens, fresh captures of the two pages the golden suite has NEVER
covered (Building, Preferences — `test/design_captures_test.dart`, a temporary sim-tagged
harness), and a code inventory of the token/motion/widget layer.

## Method — the skill principles, translated to this repo

1. **Frequency gate before any motion** (Kowalski / find-animation-opportunities): an action
   used 100+ times/day gets NO animation (command palette, tool switching, zoom, drag tracking
   — all stay instant); tens/day gets near-imperceptible motion only; occasional surfaces
   (section disclosure, status pills, drawers) get standard `MechXMotion` treatment; the
   delight budget exists only on rare moments (first-run, success). Named purpose required —
   feedback / state / spatial / preventing-a-jarring-change. "Looks cool" is a rejection.
2. **Numbers that update wear tabular figures** (make-interfaces-feel-better #9): any value
   that changes while visible (readouts, totals, steppers, zoom %, stat tiles) must not cause
   layout shift. Roboto carries `tnum`; the gap is adoption, not the font.
3. **Reduced motion is a first-class input** (Apple HIG): Flutter surfaces the OS setting as
   `MediaQuery.disableAnimations`; every duration the app animates with must resolve through
   one helper that collapses to zero when set. Today NOTHING checks it.
4. **Hit areas ≥ 40 px in dense desktop UI** (make-interfaces-feel-better #16): small glyph
   buttons (level-delete ×, stepper −/+) must extend their tappable region, not their glyph.
5. **Tables read by the dataviz rules**: right-aligned numeric columns under right-aligned
   headers, status colours reserved for status, recessive rules, no dev-speak in captions.
6. **One control idiom per pattern** (Apple familiarity): the same kind of setting is operated
   by the same kind of control everywhere.

Deliberately REJECTED after the frequency gate (recorded so the next session doesn't re-litigate):
command-palette open/close (keyboard, 100+/day), canvas tool/service switching (100+/day),
zoom controls, drag/marquee tracking (live 1:1 — never animated, per MechXMotion's own doc),
palette-card hover beyond the existing `hoverLift` token, stagger on hub cards (information
the engineer is scanning, not a marketing page).

## Findings

### Cross-cutting (Wave 1)

- **C1 — no reduced-motion gate.** Add `MechXMotion.resolve(BuildContext, Duration)` →
  `Duration.zero` when `MediaQuery.disableAnimationsOf(context)`; adopt it in the shared
  animated widgets (disclosure chevron, collapsible inspector, button/segment fades, status
  pill). Purpose: accessibility; behavior unchanged for everyone else.
- **C2 — tabular-figure helper.** `MechXTypography.tabular(TextStyle)` →
  `copyWith(fontFeatures: [FontFeature.tabularFigures()])`. Adopted per page in Wave 2.
- **C3 — DisclosureSection bodies snap.** The chevron animates (`AnimatedRotation`) but the
  body appears/disappears instantly — a jarring reflow of the whole inspector column. Wrap the
  body in `AnimatedSize` (`MechXMotion.fast` / `standard`, via C1). Purpose:
  preventing-a-jarring-change; tens/day tier ⇒ fast and subtle. At-rest frames byte-identical.
- **C4 — status pill appears/disappears with no bridge.** The save/open/import confirmation in
  the status bar pops in and out. Give it a fade+2px-rise enter (`appear`) and softer fade exit
  (`dismiss`), through C1. Occasional tier.

### Layout page (goldens 01/02/03)

- **L1 — inspector values truncate with ellipsis mid-data:** `15 DN · Cold water r… 0.0 m ×5`,
  `1 · worst 319 …` (PRV row). A value the engineer needs is cut while label padding survives.
  Fix: let the VALUE win the row — labels shrink/wrap first; BOM rows drop the redundant
  service prefix when space is short (`15 DN riser · 3.5 m ×1`).
- **L2 — Results/BOM numbers proportional:** kPa/m/count readouts recompute live with the
  solve; adopt C2 on the value column so rows don't wobble as digits change.

### Riser page (goldens 04/07)

- **R1 — the inspector column is ~60 % dead space** (BUILDING + FEED STRATEGY only). Add a
  data-gated read-only "System" summary card fed from existing providers: services present on
  the diagram, riser count + tags (`CW-R1 …`), total riser length (Σ §10 elevation deltas).
  Nothing new computed — a projection of the solve, honest by construction.
- **R2 — floor gutter labels + Notes card are near-invisible** (9–10 px grey on near-black).
  Lift the floor name to `label`/`textSecondary`; Notes card body to `caption`/`textSecondary`.
  (The tall empty floor bands are CORRECT — true-elevation §10 proportionality — do not
  compress them.)

### Electrical page (goldens 05/06/08/–11)

- **E1 — initial framing cuts content:** first open shows MDP top-left and LP-1 running under
  the inspector edge; the fit control exists but the first frame doesn't use it. Fit-to-content
  once on first non-empty layout (same routine as the `fit` button; no animation — framing,
  not motion). Golden 05 re-captures accordingly.
- **E2 — schedule/summary numeric cells adopt C2** where they update live (demand totals,
  imbalance %, n/m placed).

### Review hub (goldens 12/15)

- **V1 — stat-tile grid rhythm:** a 2-tile row at one width then a 3-tile row at another reads
  as two unrelated groups. One consistent tile grid (equal widths, one gutter, wrapping);
  tile VALUES adopt C2 (they change with the solve).

### Commercial hub (golden 13)

- **M1 — dev-speak survived here:** "27 line(s) from the sized electrical model …
  13 line(s) have no catalogue match." / "{n} line(s) are unpriced …" — the exact form
  `plural.dart` was built to kill, in `app_strings.dart` (EN + ID templates). Fix the
  templates to natural singular/plural via the existing parameterized-template mechanism.
- **M2 — numeric columns:** Qty cells adopt C2; the Qty header right-aligns over its
  right-aligned values (dataviz table rule).

### Building page (no golden until now)

- **B1 — the add-level control reads as a math expression:** `− 1 + levels @ − 3.5 m + [Add on
  top] [Add basement]` crammed in one pill. Give the two steppers visible field labels
  ("Levels", "Height") and comfortable gaps; same behavior.
- **B2 — level-delete × and stepper −/+ hit areas are glyph-sized.** Extend to ≥ 40 px
  tappable (visual size unchanged).
- **B3 — height/elevation values adopt C2** (stepper values change in place).

### Preferences page (no golden until now; weakest page)

- **P1 — three idioms for one pattern:** Appearance = a button naming the ACTION ("Switch to
  Light"), Language = a button naming the OTHER value ("Bahasa Indonesia"), AI provider = one
  filled pill beside two bare text links. Converge all three onto the canonical `MechXSegment`
  radio idiom showing all options with the current one selected (Dark/Light · English/Bahasa
  Indonesia · Anthropic/OpenAI/GLM). Familiarity + agency: see every option, click the one you
  want.
- **P2 — page rhythm:** rows float in a void with no grouping. Group into two labelled
  sections (Appearance & Language; AI copilot) using the existing `MechXSectionLabel` idiom;
  the inert "Software update" row styles as a muted informational footnote of the first group.

## Execution — ultracode waves (disjoint file ownership)

- **W1 foundation (opus):** `design_tokens.dart` (C1+C2), `disclosure_header.dart` (C3),
  `app_shell.dart` (C4 + C1 adoption). Everything Wave 2 consumes; API frozen below.
- **W2 pages (parallel after W1):**
  - A (sonnet) `project_panel.dart` — L1, L2, C1-adopt in its animated bits.
  - B (sonnet) `schematic_view.dart` — R1, R2.
  - C (sonnet) `electrical_canvas.dart` + `electrical_view.dart` — E1, E2.
  - D (sonnet) `review_hub.dart`, `commercial_hub.dart`, `app_strings.dart`,
    `issues_card.dart` (if V1 touches it) — V1, M1, M2.
  - E (opus) `preferences_screen.dart`, `building_screen.dart` — P1, P2, B1–B3.
- **W3 verify (haiku, after W2):** regenerate goldens 01–15 + the design captures, run the
  full gate, report which goldens shifted and why; fable reviews the images + diff and lands.

Frozen contracts (Wave 2 may rely on, must not redefine):
`MechXMotion.resolve(BuildContext context, Duration base) → Duration` and
`MechXTypography.tabular(TextStyle base) → TextStyle`, both static, in
`lib/ui/theme/design_tokens.dart`.

Golden policy: agents run `flutter analyze` + their targeted tests only; golden regeneration
happens ONCE in W3 (concurrent `--update-goldens` runs corrupt each other). Guardrails hold
throughout: custom design system only, opaque content / glass chrome split, ASCII + Roboto on
canvas, EN default byte-identical for i18n edits, `.mechx` untouched.

## Status — LANDED (2026-07-27)

All findings above shipped (C1–C4, L1–L2, R1–R2, E1–E2, V1, M1–M2, B1–B3, P1–P2). Orchestrator
review caught and fixed three seams the wave split could not: (1) `RiserSystemSummary` (R1) was
built in `schematic_view.dart` but its mount point `_RiserInspectorColumn` lives in
`app_shell.dart` (Wave-1's file) — mounted by the reviewer; (2) `calibration_test` tapped the
Calibrate button mid-C3-ease after seeding — the test now settles first; (3) the golden harness
captured 01 mid-Draw-default-collapse (the easing box pushed the sections below out of the
clipped column) — the harness settles 200 ms past the seed before capture 01, and the
`single_line_symbols_test` goldens (09/10, outside `screenshots_test.dart`) are regenerated
alongside. Known accepted rough edge: the disabled level-delete `×` absorbs pointer events
across its 40 px hit box (visually dimmed; `deferToChild` when disabled is a possible refinement).
Gate: engine 1471 / app 1230 / analyze clean; goldens 01–05, 07–10, 12, 13, 15 + the three
design captures regenerated and visually verified.
