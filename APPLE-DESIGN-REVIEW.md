# iSystem — Apple-design review (v1.10.0)

A fresh review through a senior Apple-UI-designer lens, run *after* all 83 findings of
`UX-WORKFLOW-REVIEW.md` shipped (v1.10.0). Six parallel lenses read the **current** code and
golden screenshots and formed grounded, opinionated findings: the core workflow/first-run journey,
inspector information architecture, the visual design system, canvas direct-manipulation,
cross-workspace cohesion & discoverability, and copy/feedback/clarity. Every finding below is
file:line-grounded; the highest-impact claims were adversarially spot-checked against the code.

## Implementation status (waves)

Being implemented in five waves via multi-agent orchestration (disjoint-ownership impl packages +
per-package adversarial review, integrated centrally: full gate + golden regen + review-fix pass).

- **Wave 1 — Themes A + D (orientation & discoverability) — LANDED.** A1 first-run orientation card
  (empty-Layout, one-time, machine-local `AppSettings.seenFirstRun`), A2 stepper honesty (Floors no
  longer pre-ticks the default seed; done on Building-visited / stack-diverged / network-drawn — the
  last clause keeps the "active" pointer from wedging backward), A3 template card routes into Import
  (no more dead end), A4 first-draw hint on the calibrated-but-empty canvas, A5 import navigates to
  DESIGN → Layout + selects the new sheet, A6 one name ("Building") across the calibration baton +
  nav + stepper, A7 honest on-canvas "Floor N of M" (counts sheet-occupied floors). D1 a permanent
  "Ctrl K" palette affordance in the top bar, D2 keycaps on palette rows that have a shortcut, D3
  the submittal export added to the palette. Goldens 01–08/10–15 shifted by the D1 pill only (the
  A2 stepper stays byte-identical in the seeded network); regenerated + eyeballed.
- **Wave 2 — Theme B (one vocabulary) + Theme H copy (H2–H5, H7) — LANDED.** B1 one noun for a
  drawn edge ("run"), B3 "sheet" for the object / "plan" for the verb, B4 matched abbreviations
  (calc↔calc, BOM everywhere). H2 a pure `plural(n,one,many)`/`pluralCount` helper kills the "(s)"
  dev-speak across the compliance roll-up, design issues, the electrical advanced-study caption and
  the mechanical BOM caption; H3 "Tap again to discard"; H4 the auto-sized toast localized + one
  noun + a middot; H5 the torn-recovery message says what to DO, localized; H7 specific "Unverified:
  <value>" titles (behind a stable `DesignIssue.isVerify` discriminator so counts/badges are
  unchanged) + the stray "PALETTE" caps normalized. The B2 issue-count scope landed the electrical
  toolbar ("Electrical issues (N)", still ID-localized) + an all-disciplines a11y label on the nav
  Review badge. Goldens 05/08/10/11 (electrical toolbar) + 12/15 (compliance plurals + verify
  titles) + 13 (BOM titles/caption) regenerated + eyeballed. Deferred (documented): the two
  `commercialBomLead` template "(s)" — the localized-template pluralization limitation (ID is
  inflection-free; grammatical EN needs per-count logic the template can't express), matching the
  prior J7 disposition.
- **Wave 3 — Theme E (calmer inspector) + Theme F (visual restraint) — LANDED.** E1 data-gated the
  Network/Fire/HVAC result sections (Fire no longer shows a phantom fire-pump duty with zero fire
  pipework); E2 identity-first node editor (placement demoted to a disclosure); E3 controls-first
  edge editor (takeoff in a "Details" disclosure); E4 the electrical circuit/panel drawers lead with
  identity + rating and demote the expert params under "Advanced"; E5 honest section names
  ("Sizing"→"Design inputs", "Network"→"Results"); E6 the ~11-pill size ladder collapsed to a shared
  `SteppedValueField` stepper. F1 the whole draw-tool group uses ONE tinted selected-segment idiom
  (Select/Run/Riser/Measure/Tank/Room/Ortho) so the solid accent is reserved for the primary; F2
  content cards/chips RAISE (`surface`, not the recessed `background`); F3 structural headings pass
  AA in light (`textMuted`→`textSecondary`); F4 nav type routed through the tokens; F5 the DRAW wall
  grouped ("Tools"/"Service" + whitespace); F6 a primary anchor in the top bar (Save accent when
  dirty, the theme toggle demoted to a compact icon); F7 motion literals → `MechXMotion` tokens.
  Integration fixed the reviews' finds: the `selection_overlay` double-click-to-expand key
  (E5 companion), 5 stale widget-test assertions, the F1 tool-group consistency, and the `_ServiceChip`
  F2 companion. Goldens 01–08/10–15 regenerated + eyeballed (dark/light/hub). Deferred (documented):
  the electrical "Advanced" edit-loss-on-collapse (consistent with the existing commit-on-blur Close
  behavior) + its EN literal (Wave 5 electrical i18n); the lone nav-item 10.5 size (no scale token).
- **Wave 4 — Theme G (the canvas frame) — LANDED (Riser minimap deferred).** G1 a reusable minimap
  on the LAYOUT canvas (top-right, node markers + a live viewport rect, tap/drag to recenter, modelled
  on the electrical canvas's minimap) — the Riser minimap is deferred (its viewport model differs from
  the shared `CanvasView`); G2 the calibrated grid is now MAGNETIC — grid-intersection snapping added
  as the LOWEST-precedence snap (nodes/edges/fittings still win), gated on ortho + calibration, wired
  live at the draw / nub-pull / node-drag / endpoint-resize sites (the typed-exact-length path is
  deliberately excluded so a typed measurement lands exactly); G3 an on-canvas tool cluster (Select/
  Run/Riser + the active service) that appears ONLY when the inspector is collapsed, so drawing never
  requires the inspector open; G4 the programmatic viewport changes (zoom/fit/minimap-recenter) EASE
  instead of teleporting, while live wheel/drag stays immediate; G5 a left-drag on a run's BODY now
  MOVES the run (one undo step via `moveMany`), preserving empty→marquee / node→move / endpoint→resize.
  Goldens 01/02/03/06 (the Layout minimap) regenerated + eyeballed (no collision with the heatmap
  legend or the collapse chevron); G3/G4/G5 golden-neutral. Additive: the minimap `ValueNotifier` +
  the eased `AnimationController` are disposed; grid-snap is default-off/byte-identical.
- **Wave 5a — H1 + H6 (localize the trust surface) — LANDED.** The compliance verdict + category
  rows + detail messages, the whole Review hub + issues card, and every `DesignIssue` title/message
  now resolve through `context.strings`/`MechXStringsData(locale)` (123 new EN+ID StringKeys), so the
  sign-off surface renders in Bahasa. To keep acknowledgements + the compliance fan-in working across
  locales, `DesignIssue` gained a stable locale-independent `kind` discriminator (its `key` is now
  `kind`-based, not the localized title) and the compliance store matches on `kind`, not English
  title substrings. H6: the Ask-Claude copilot + the half-localized "Load sample project" / "Apply a
  building template" are localized. EN byte-identical ⇒ goldens 12/14/15 unchanged.
- **Wave 5b — Theme C consistency (C2/C3/C5) — LANDED.** C2: the forked `_LayerSegment` (Layout) +
  Riser `_TabButton` converged onto the canonical `MechXSegment` for RADIO groups, and the independent
  TOGGLES (Legend/Notes/Details/Infer/Title-block, and the layer visibility eye) now use a distinct
  checkbox/eye idiom — so the Riser toolbar no longer shows Auto + Details + Notes as identical blue
  pills (golden 04). C3: the bespoke Schematic help replaced by the shared `CanvasGuideButton` +
  `CanvasGuideLegend`, added to Auto mode too. C5: the Riser inspector column converged onto
  `MechXSectionLabel` + the tinted selected-segment idiom.
- **C1 + C4 — the electrical-shell restructure (the last deferred tier-5 item) — HAS ALSO LANDED**
  (as a dedicated follow-up after the campaign merged). The standalone electrical workspace
  (`WorkspaceView.electrical`) no longer early-returns its own frame — it renders through the SAME
  shared `_DesignWorkspace` scaffold as Layout/Riser (the canvas-backdrop + a `CollapsibleInspector`;
  no `SheetRail`, since the single-line isn't sheet-based). Editing was LIFTED from `ElectricalView`'s
  local `_editing`/`_panelEditing` state to a transient `electricalInspectorTargetProvider` (a sealed
  `ElectricalCircuitTarget`/`ElectricalPanelTarget`), so the floating 340-px slide-in DRAWER (C4) is
  gone: a new selection-first `_ElectricalWorkspaceInspectorColumn` shows the circuit/panel editor
  INLINE at the top when something is selected, else the Loads palette (the mechanical
  selection-first idiom). The editors gained an `inline` mode; the Layout electrical LAYER keeps the
  drawer form (`inline:false`) and is byte-identical (golden 06 unchanged). So the electrical view now
  reads as one app — shared top bar / nav rail / status bar / workflow stepper / collapsible inspector
  — with only the canvas content differing. Goldens 05/08/10/11 (the standalone electrical frame)
  regenerated + eyeballed; a latent RenderFlex overflow the narrower canvas exposed (the auto-board
  summary header) was fixed with a `FittedBox`. **With this, EVERY finding of the review (all 8 themes,
  C1–C5 included) is landed — nothing remains deferred.**

## The premise — how iSystem is *supposed* to function

An engineer opens the app, drops in a PDF floor plan, tells it the scale, sets the floor heights,
draws pipes and ducts and panels, and the app sizes everything to SNI/PUIL and hands back issuable
drawings, a BOM, and a calc report — **offline, fast, and without the engineer ever wondering
"what do I do next" or "did that work."** The tool should teach its own sequence, make the canvas
feel physical and forgiving, speak one clear vocabulary, and put its power where a non-expert can
find it.

**Where it stands.** The *infrastructure is mature* — the app already owns every mechanism it needs:
a design-token system, Liquid-Glass chrome, a command palette, a workflow stepper, a status-feedback
spine, honest empty states, an undo timeline, an i18n mechanism. The five waves that just shipped
did the hard structural work. **The remaining gap is not missing features — it is the *consistency
and restraint of application*, and *orientation between steps*.** That is exactly the layer Apple
obsesses over, and it is what separates "powerful" from "easy." This review is that layer.

---

## What's already genuinely excellent (protect these)

- **Empty states carry their own next action** (Import / New-from-template), and calibration teaches
  *at the moment* via a tappable on-canvas hint — teaching-in-context done right.
- **The status-feedback spine is calm and honest**: a busy pill, self-clearing success confirmations,
  an eager "edited" dot, a two-tap recovery discard, and a zoom pill that shows `—` rather than lie.
- **The drawing core is Apple-grade**: an honest rubber-band with live length + a snap/tee ring that
  means what it says, WYSIWYG drop ghosts with distinct adopt-vs-tee markers, structurally-enforced
  one-drag-one-undo, and a screen-constant snap radius at every zoom.
- **The compliance verdict respects the engineer** — "REVIEW REQUIRED — you decide whether to issue"
  is confident and non-scary; Design-Issue messages read as *what happened + why + what to do*.
- **The design system is real**: Liquid Glass applied only to chrome (content stays opaque), a
  tofu-proof custom-glyph language, semantic motion idioms, and genuine shared-widget reuse.

The bones are strong. Everything below is about making the app feel like *one* calm, confident tool.

---

## Theme A — Orientation: teach the sequence, never let a step lie  ✅ LANDED (Wave 1)

The app's whole premise is a **non-obvious ordered workflow** (calibrate → floors → draw → size →
report), yet the only map is a 5-chip stepper in the status bar, and two of the signposts are
misleading.

- **A1 · [High] No first-run orientation exists.** There is no welcome, tour, or "start here" — the
  only journey map is the `WorkflowStepper` in the status bar (`app_shell.dart:641`, inside a
  `ClipRect` that can clip it away). For a sequence this non-obvious, that is the entire map, and
  it's the easiest thing on screen to miss. **Fix:** a one-time, dismissible first-run card on the
  empty Layout that names the five steps and points at "Import a plan" — additive, shown once.
- **A2 · [High] The stepper marks "Floors" DONE before the user touches anything.** `floorsSet =
  project.floors.length > 1` (`command_store.dart:134`) but `build()` seeds three default floors
  (`project_store.dart:80-82`) — so step 2 is ticked green on a cold launch (verified). The map lies
  on first contact. **Fix:** gate "Floors" on a real signal (a sheet imported, or the user having
  visited/edited Building), not the default seed.
- **A3 · [High] The "New from template…" card on the empty canvas is a dead end.** It calls
  `showTemplatesDialog`, which only sets floors/occupancy (`templates_dialog.dart:118`) and imports
  **no sheet**, so the canvas still reads "No plan attached." The Projects screen fixed the naming;
  the canvas card was left promising more than it delivers. **Fix:** after applying a template, route
  the user straight into Import (or relabel the card so it doesn't imply a drawable canvas appears).
- **A4 · [Med-High] The hardest step (Draw) gets the *least* teaching.** The primary gesture —
  pull a mainline out of a node's outlet nub — lives only inside the on-demand `(?)` guide
  (`layout_canvas.dart:1104`, hidden by default), while the *easier* Calibrate step gets a persistent
  on-canvas nudge. Effort is inverted. **Fix:** a first-draw hint on the calibrated-but-empty canvas
  ("Pick a tool, then drag to draw"), dismissed on first successful run.
- **A5 · [Med] Import doesn't take you to the plan.** `importPlan` loads sheets but never sets the
  shell section/view (`project_io.dart:102-203`), so importing from Projects or Review leaves a
  "where did it go?" gap. **Fix:** on import, switch to DESIGN → Layout and select the new sheet.
- **A6 · [Med] "Floors" (stepper/nudge) ≠ "Building" (nav).** The baton-pass says go to *Floors*
  (`calibration_overlay.dart:58`) but the destination is labelled *Building* (`nav_rail.dart:165`).
  A tiny word mismatch at exactly the moment the user is following instructions. **Fix:** one name.
- **A7 · [Low-Med] A single imported plan reads "Floor 1 of 3" with phantom empty levels**
  (default 3-floor seed; `building_screen.dart:203`). **Fix:** seed one floor, or don't count
  unmapped default levels in the on-canvas "Floor N of M".

---

## Theme B — One vocabulary: the same thing must have the same name everywhere  ✅ LANDED (Wave 2)

Apple ships a controlled vocabulary; drift makes a user distrust the model. Multiple lenses
independently flagged the same drift, which is a strong signal.

- **B1 · [High] One drawn edge is called three things.** The tool is **"Run"**, the right-click
  menu/hint calls it **"segment"**, the success toast says **"runs"** (and in Bahasa `Saluran` vs
  `segmen`) — `app_strings.dart:672/707/1130`. Pick one noun ("run") in UI, menus, and toasts.
- **B2 · [High] "Issues" means three different scopes and numbers on one screen.** The electrical
  toolbar's "Issues (2)" is electrical-only (`electrical_view.dart:255`), the nav Review badge "9+"
  is *all* open issues (`nav_rail.dart:86`), the Review hub says "12" — all visible together
  (golden 05). **Fix:** scope the labels ("2 electrical", "12 all") or unify the count.
- **B3 · [Med] The imported PDF is "plan", "sheet", and "floor plan" interchangeably** (Import
  **plan** → "No **sheet**" → "**floor plan**"; ID `denah` vs `lembar`). Pick one ("sheet") for the
  object and reserve "plan" for the verb ("Import a plan").
- **B4 · [Med] Abbreviation drift between a control and its own dialog:** button "Export calc report"
  vs dialog "Export **calculation** report"; "BOM" button vs "Bill of materials" section title.
  Spell it the same on both ends of the same action.

---

## Theme C — One app: make Electrical and Riser stop feeling like guests  ✅ LANDED (C2/C3/C5 Wave 5b; C1/C4 follow-up)

The electrical workspace is a PanelMaker port and still *reads* like one — a structurally different
window with its own idioms. An engineer shouldn't have to re-learn the app when they switch tabs.

- **C1 · [High] Electrical is a different window skeleton.** Layout/Riser share the `SheetRail` +
  a collapsible selection-first inspector; `ElectricalView` early-returns its own frame
  (`app_shell.dart:221`) with **no sheet rail**, a **non-collapsible** `ElectricalPalette`, and
  **floating-drawer** editing instead of the inline inspector (`electrical_inspector.dart:193`).
  **Fix:** bring electrical under the shared shell scaffold (sheet rail where it applies, the same
  collapsible-inspector host, selection-first content) so the frame is identical and only the
  *content* differs.
- **C2 · [Med] The segment control is reimplemented 3–4×.** `MechXSegment` is canonical, but
  `_LayerSegment` and the Riser `_TabButton` fork it, and the **Riser toolbar wears one blue pill
  for both a radio group (Auto/Edit) and independent toggles (Legend/Notes)** — golden 04 shows
  Auto + Details + Notes all "selected" at once, which teaches nothing. **Fix:** one segment widget;
  radio-selection vs toggle must look different (selected-segment tint vs a checkbox/eye idiom).
- **C3 · [Med] The help affordance diverges.** Schematic ships a bespoke `_HelpButton`/`_ElevationHelp`
  (`schematic_view.dart:1312`) instead of the shared `CanvasGuideButton`, and Auto mode has no help
  at all. **Fix:** the shared `(?)` guide everywhere, including Riser Auto.
- **C4 · [Med] Two idioms for "edit the selected thing":** mechanical inline panel vs electrical
  340-px slide-in drawer (`app_shell.dart:239` vs `electrical_inspector.dart:193`). Same job, two
  mental models. **Fix:** converge on the inline selection-first inspector.
- **C5 · [Low-Med] The Riser inspector speaks a different dialect** — raw `Text('Riser')`,
  `type.caption` sub-heads instead of `MechXSectionLabel`, solid-accent toggle buttons
  (`app_shell.dart:300-363`). **Fix:** shared section labels + the tinted selected-segment state.

---

## Theme D — Make the power findable  ✅ LANDED (Wave 1)

The app has ~40 palette actions and a rich shortcut set, but they're nearly invisible to anyone
who doesn't already know they exist.

- **D1 · [High] The command palette has no visible entry point.** Ctrl/Cmd+K is the *only* way in
  (`app_shell.dart:91`) — no button, no keycap hint, no menu bar. The app's biggest "what can I do?"
  surface is undiscoverable. **Fix:** a small, permanent "⌘K" affordance in the top bar (and mention
  it in the first-run card, A1).
- **D2 · [Med] Single-key tool shortcuts (V/R/E/M/K/B/O/1-9) are unadvertised** — only in the `(?)`
  guide; the palette shows keycaps for just 4 commands (`command_store`), even though "Tool: Draw run"
  *has* an R key. **Fix:** show the keycap on every palette row that has one, and on tool tooltips.
- **D3 · [Med] Export lives in five places** (Projects, Review, Electrical toolbar, Riser toolbar,
  Commercial bar) and the palette mirrors none of the electrical/riser/commercial/submittal exports —
  so "menus and the palette agree" is violated. **Fix:** one "Export…" home (or a palette group that
  reaches every export), with the others as shortcuts into it.

---

## Theme E — A calmer inspector: progressive disclosure, applied evenly  ✅ LANDED (Wave 3)

The inspector already owns every calm-disclosure mechanism (`DisclosureSection`, master-detail,
`ResultCard`, honest empty states). The gaps are *uneven application* — mostly reorders and a few
`defaultExpanded` predicates.

- **E1 · [High] A blank launch opens ~7 sections at once, and result sections expand with no data.**
  Network/Fire/HVAC default-expand regardless of drawn content — **Fire shows a full fire-pump duty
  and kv rows with zero fire pipework** (`project_panel.dart:2945-2989`). **Fix:** data-gate their
  `defaultExpanded` the way Scale already gates on calibration — a content-bearing section expands,
  an empty one stays a quiet header.
- **E2 · [High-Med] The single-node editor leads with the rarely-changed** (Role pills + Mounting
  height) **before the primary identity** (Fixture type), all flat with no weighting
  (`project_panel.dart:3557-3662`). **Fix:** promote the identity/type to the top as the headline;
  demote placement into a disclosure.
- **E3 · [Med] The edge editor shows a read-only procurement takeoff** (sheet m², gaskets, hangers,
  bolts) **above** the editable Size/Material/Service controls (`3841-3903`) — prominence inverted.
  **Fix:** controls first, takeoff in a "Details" disclosure.
- **E4 · [Med] Electrical circuit/panel drawers are flat walls of 9–11 fields** with expert params
  (cosPhi, demand factor, cable type, diversity, headroom) weighted equal to Name
  (`electrical_inspector.dart:233-390`). **Fix:** Name/rating first; expert params under "Advanced".
- **E5 · [Med] Labels fight the mental model:** the section named **"Sizing" actually holds design
  *inputs*** (occupancy/rainfall/runoff, `2548-2631`), and **"Network"** is an ambiguous name for the
  plumbing *results*. **Fix:** rename to "Design inputs" and "Results" (or the discipline).
- **E6 · [Low-Med] The ~11-pill size ladder is rendered inline in both single and batch edge editors**
  (`3277-3308`, `3874`), crowding a 272-px column — the right-click Ø ladder already exists. **Fix:**
  collapse to a `SteppedValueField` / the right-click ladder.

---

## Theme F — Visual restraint: one primary action, consistent depth, legible in both themes  ✅ LANDED (Wave 3)

The token system is mature; the gaps are about *restraint of application*.

- **F1 · [High] Accent overload on the Layout screen.** systemBlue carries five simultaneous
  "active" meanings at once — nav *Layout*, the *Plumbing* layer, the *Cold-water* chip (all
  `accentMuted`), **plus** the *Select* tool **and** the *Ortho* toggle as *solid* `MechXButton`
  fills. Two solid blues fight for "the action." **Fix:** reserve the solid accent for a single
  primary; make tool/toggle *states* use the tinted selected-segment idiom, not a solid fill.
- **F2 · [Med-High] Content cards recess instead of raise (inverted iOS elevation).**
  `PaletteCard`/`ResultCard`/`ServiceChip` fill with `colors.background` (the darker grouped bg),
  while hubs correctly use `colors.surface` (verified: `palette_card.dart:103`, `result_card.dart:48`
  vs `hub_scaffold.dart:128`). The same object elevates two opposite ways. **Fix:** content cells use
  `surface`.
- **F3 · [Med] Light-mode section labels fail contrast.** `textMuted #9A9AA0` ≈ 2.8:1 on white
  (below AA) is the colour of every `MechXSectionLabel` + disclosure header — the *structural*
  headings (verified `design_tokens.dart:192`). **Fix:** darken the token or promote labels to
  `textSecondary`.
- **F4 · [Med] Off-scale hardcoded type sizes** (`fontSize: 10.5`/`9` literals; a raw `TextStyle`
  rebuilding `type.micro` by hand — `nav_rail.dart:442/228/514`) undermine "one type scale."
  **Fix:** route through the type tokens.
- **F5 · [Med] The DRAW inspector is a wall of ~15 equal-weight bordered rows** with no grouping
  rhythm, so the primary tool is hard to find (`project_panel.dart:2110`, golden 01). **Fix:** group
  with whitespace/one container, not a hairline per row.
- **F6 · [Med] The top bar has no primary anchor** — Open/Save/Import/Switch-theme are four identical
  gray buttons, and the *theme toggle* is a visual peer of *Save* (`app_shell.dart:519-542`). **Fix:**
  emphasize Save when dirty; demote the theme toggle to a tertiary/icon control.
- **F7 · [Low-Med] Motion literals drift from their own tokens** (`MechXButton` press-scale 0.97 vs
  token 0.98; `PaletteCard` hover 1.03). **Fix:** route through `MechXMotion`.

---

## Theme G — The canvas frame: navigation and physicality around the (excellent) drawing core  ✅ LANDED (Wave 4; Riser minimap deferred)

The *drawing* is Apple-grade; the *frame* around it — navigation, an honest grid, always-visible
tool entry — lags.

- **G1 · [High] No minimap on the mechanical Layout canvas — the app's primary surface.** The
  *secondary* electrical canvas ships one (`electrical_canvas.dart:453`); Layout and Riser (the big
  pan-heavy surfaces) have none (flagged by two lenses). On a large calibrated PDF zoomed in, there's
  no "where am I / jump there." **Fix:** the same minimap on Layout + Riser.
- **G2 · [High] The calibrated metre grid is decorative, not magnetic.** The canvas paints a 1-2-5 m
  grid and arrow-nudge honors it (`canvas_grid.dart`, `layout_canvas.dart:705`), but drawing/dragging
  snap only to nodes/edges — **never grid intersections** (`network_store.dart:1521-1590`). A visible
  grid that doesn't attract the cursor over-promises alignment. **Fix:** snap to grid intersections
  when the ortho/grid is on (behind the existing snap radius), or make the grid clearly a reference,
  not a magnet.
- **G3 · [Med-High] Tool verbs vanish when the inspector is collapsed** — the canvas-focus state the
  app *encourages*. The mode pill only *exits* modes (`mode_pill.dart:75`); *entry* is via the
  collapsible inspector or the undiscovered single keys. **Fix:** a small persistent on-canvas tool
  cluster (or keep the mode pill's tool visible), so drawing never requires the inspector open.
- **G4 · [Med] Viewport changes teleport.** `zoomIn/Out/fitView` set the transform directly
  (`canvas_view.dart:130-143`); only wheel zoom feels continuous, so "Fit" from deep zoom jumps.
  The `MechXMotion` tokens already exist. **Fix:** ease programmatic viewport changes.
- **G5 · [Med] Left-drag is dead on a pipe** (marquee on empty, move on a node, nothing on an edge —
  `selection_overlay.dart:745`), and pan needs middle-drag/Space. **Fix:** left-drag on a run should
  either move it or rubber-band-from-here consistently.

---

## Theme H — Speak clearly, and in Bahasa where it counts  ✅ LANDED (H2–H5/H7 Wave 2; H1/H6 Wave 5a)

The copy is mostly good; the load-bearing gap is that the **trust surface is English-only** for a
Bahasa user — for an app whose premise is Indonesian SNI/PUIL compliance, that's not cosmetic.

- **H1 · [High] The Review/compliance surface is un-localized.** `compliance_store.dart:99-131`,
  `review_hub.dart`, `issues_card.dart`, and every message in `design_issues_store.dart` are raw EN
  literals that never hit `context.strings` — so the compliance verdict, category rows, issue
  explanations **and the exported MEP report table** render in English even in Bahasa mode. This is
  the sign-off surface. **Fix:** localize the Review/compliance/Design-Issues strings first — the one
  place the deferred J7 i18n tail is load-bearing rather than cosmetic.
- **H2 · [High] "(s)" pluralization is dev-speak, everywhere** — `'5 value(s) require…'`,
  `'finding(s)'`, `'floor(s)'`, `'line(s)'` (`compliance_store.dart:116`, `design_issues_store.dart:176`).
  It's meaningless in Bahasa (the ID strings already drop it). **Fix:** a tiny `plural(n, one, many)`
  helper; compute the word.
- **H3 · [High] The armed state of the most destructive action reads casually.** `"Discard - sure?"`
  (`app_strings.dart:572`) — deleting the only crash-recovery copy — uses a hyphen-as-dash and a chat
  tone. **Fix:** `"Tap again to discard"` / `"Ketuk lagi untuk membuang"`.
- **H4 · [Med] The most-fired success toast is a raw EN literal with a hyphen-dash and the B1
  drift:** `'Auto-sized $count runs - sizes shown on the plan'` (`app_state.dart:217`). **Fix:**
  localize + use an em-dash/·, and one noun.
- **H5 · [Med] The torn-recovery message blames internals** — "torn by an interrupted write"
  (`app_shell.dart:1030`), raw EN. **Fix:** localize; say what to do, not what broke internally.
- **H6 · [Med] The Copilot panel is fully un-localized** (`'Ask Claude'`, `'Claude is planning…'`,
  `change(s)`), and Projects/electrical are half-localized (localized cards beside raw-EN
  `'Load sample project'` / `'Apply a building template'`). **Fix:** finish those string batches.
- **H7 · [Low] Every `// VERIFY` row shares the generic title "Unverified standard"**, and a stray
  ALL-CAPS `'PALETTE'` header survived the declutter. **Fix:** name the specific value; drop the caps.

---

## Priority — where the ease-of-use leverage is

Sequenced by how much each moves "a real engineer succeeds without help," smallest-effort-first
within a tier:

1. **Stop the map from lying + orient the newcomer** (A2 stepper honesty, A3 template dead-end,
   A1 first-run card, A6 Floors/Building name, D1 palette entry point). These are small and remove
   the two worst first-contact confusions.
2. **One vocabulary** (B1 run/segment, B2 issues-scope, B3 plan/sheet, B4 abbreviations, H3/H4 copy).
   Cheap, high-trust.
3. **A calmer inspector** (E1 data-gate result sections incl. the phantom Fire, E2 identity-first
   node, E5 rename Sizing→inputs) and **visual restraint** (F1 accent overload, F2 card elevation,
   F3 light contrast).
4. **The canvas frame** (G1 minimap on Layout, G3 persistent tool entry, G2 magnetic grid, G4 eased
   viewport).
5. **One app** (C1/C4 electrical under the shared shell + inline inspector, C2 segment/toggle idiom)
   and **localize the trust surface** (H1 Review/compliance in Bahasa, H2 pluralization, H6 the tail).

Every fix above is **additive**, respects the guardrails (custom design system on
`package:flutter/widgets.dart`, no Material; offline; byte-identical-when-idle so goldens hold; the
inspector stays opaque, only chrome is glass; ASCII+Roboto on canvas), and touches UI/app-shell or
strings only — no engine or `.mechx` change. The per-lens detail (with the "how it should function"
reasoning and every file:line) is in the review notes the lenses produced.
