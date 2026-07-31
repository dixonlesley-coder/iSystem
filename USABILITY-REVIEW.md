# USABILITY-REVIEW.md — all-pages usability review (2026-07-30)

A fresh usability pass over **every page** of iSystem v1.19.0+, run at the
product owner's direction alongside two user-reported fixes that landed the
same day (recorded as Wave 0 below). Method: every committed golden was
**read as an image** (goldens 01–15 + the Building/Preferences design
captures), the two user screenshots that prompted the session were analysed,
and each finding was grounded in the owning code before it was recorded —
no finding below is speculative.

Severity: **high** = misleads or blocks the working engineer · **medium** =
slows or confuses · **low** = polish. Status: `LANDED` / `open`.

> **2026-07-30 — ALL THREE WAVES LANDED** (a 7-agent parallel batch; see the
> §15 decisions-log row). Every finding below is `LANDED` with four noted
> deviations: **E-2** shipped as a reduced-motion-gated crossfade (the switcher
> existed but ran ungated; hysteresis was rejected — it would have made the
> LOD geometry stateful), **E-3** shipped as *omit the pill off-Layout* (the
> honest half of the either/or), **B-1** was found already compliant (a prior
> pass had given `_GlyphButton` a 40-px hit target), and **V-2**'s grouping
> deliberately covers every duplicate-prone kind class (loose ends, unsized
> ducts…), not just the sheet-calibration example. Gate: engine 1497 / app
> 1286 / analyze clean; goldens 01–15 + design captures re-captured and
> visually verified.

---

## Wave 0 — landed with this review (the session's user reports)

| # | Page | Sev | Finding | Status |
|---|---|---|---|---|
| W0-1 | Electrical | high | The board schedule was **monotone** — R/S/T phase loading was invisible as *phase* information. Landed: `SldRole.phaseR/S/T` in the engine sheet model; the R/S/T column headers, per-way line-current cells and TOTAL footer totals carry their phase role, and all four renderers colour them (canvas → the `kRailR/S/T` rails, PDF → matching print inks, DXF → ACI 1/2/5) — one palette across micro bar, summary cells, schedule, PDF and DXF. `electrical_sld_phase_roles_test.dart` pins it. | LANDED |
| W0-2 | Electrical | high | The schedule LOD appeared at **0.72×** zoom where its 7.5-px row text renders at ~5.4 px — detail you cannot read, the worst of both tiers (the user's screenshot). Landed: `kLodThreshold` 0.72 → **0.95** (rows arrive ≥ ~7.1 px); the summary card carries the glanceable stats below it. Micro boundary unchanged (it gates interactivity, not readability). | LANDED |

---

## Layout (goldens 01 / 02 / 03 / 06)

| # | Sev | Finding | Ground |
|---|---|---|---|
| L-1 | high | **Uncalibrated runs print `0.0 m ×5`** in the Results/BOM summary rows. A length that *cannot be measured* reads as a measured zero — the same dishonesty class W1 purged. Show `— (uncalibrated)` per row and annotate the BOM total when any sheet is uncalibrated. | golden 01 right panel; `project_panel.dart` results rows |
| L-2 | medium | **Heatmap legend vs verdict tension**: the legend reads `Low 27 kPa · High 52 kPa · Min 225 kPa` (whole field below target ⇒ all red) while the Results card beside it says `319 kPa OK` — different bases (fixture residual vs zone static) with no caption saying so. An engineer glancing sees ALL-RED + OK and trusts neither. Add a one-line basis caption to each ("residual at fixtures" / "zone static at PRV"). | golden 03 |
| L-3 | medium | **Empty-state caption collides with drawn content**: "No plan attached · 1684 × 1190 px · Import a PDF or DXF floor plan…" stays mounted under drawn runs, and the drop glyph overlaps its own caption. Hide the caption once the sheet has network content (keep the corner import affordance). | goldens 01/06 |
| L-4 | low | The service-legend chip's ~8-px rows are below comfortable reading size and sit over canvas content when panned. Collapse to an icon that expands on hover/tap. | goldens 01/03 |

## Riser (goldens 04 / 07 / 09 / 10_single_line)

| # | Sev | Finding | Ground |
|---|---|---|---|
| R-1 | medium | **Edit-mode service-chip row overflows** at 1440 px — the Sprinkler chip truncates mid-label with no scroll affordance before the `Riser` tool chip. Make the chip strip horizontally scrollable with an edge fade, or wrap to two rows. | golden 07 toolbar |
| R-2 | medium | **Live-canvas label collisions**: the riser tag (`15-CW-PPR-GRAVITASI`) collides with the floor band label / fixture stub labels at the left edge. The export side already has the two-pass collision placer (mech riser B5 idiom; electrical riser follow-up) — the *live* Auto-riser painter needs the same pass. | golden 04, `schematic_view.dart` `_AutoSchematicPainter` |
| R-3 | low | The PUMP-SET DETAIL callout occludes a supply-air run label at the top right. Reserve the callout corner in the label placer (the riser corner-reservation idiom from W1). | golden 09 |
| R-4 | low | The Riser inspector column starts ~200 px down — dead space above `RISER`. Top-align the section stack like the Layout inspector. | goldens 04/07 |

## Electrical (goldens 05 / 08 / 10 / 11 + user screenshots)

| # | Sev | Finding | Ground |
|---|---|---|---|
| E-1 | medium | **Feeder connection labels overpaint each other**: two feeders leaving one outlet exit at the *same* y, and both labels paint at `start.dy − 7` with the `minLeftX` clamp pushing them onto the same baseline — near-identical texts overprint into `…MCB 16A 3ph h` (the stray tail of the label underneath; both user screenshots show it). Stagger per-feeder (index → y offset) or place each label on the feeder's own horizontal segment near the child, as the engine riser does. | `electrical_canvas.dart:1574-1581` |
| E-2 | medium | **LOD popping**: the summary ↔ schedule switch at `kLodThreshold` is a hard flip while zooming; near the boundary the card visibly pops between two very different footprints. Add a small hysteresis band (enter at 0.95, leave below ~0.88) or a `MechXMotion`-gated crossfade. | `panelLodFor`, user zoom path |
| E-3 | low | The top-bar zoom pill reads `—` on the Electrical/Riser views while the canvas has its own zoom state — an empty readout beside `Ctrl K` looks broken. Feed it the active canvas's scale (the electrical canvas already exposes `currentScale`) or hide it off-Layout. | goldens 05/08 top bar |
| E-4 | low | Sub-panel fan-out stubs truncate names at 14 chars (`Lighting —… 10A`, `Power… 16A`) even when horizontal room remains. Truncate to the *available band width* rather than a fixed count. | golden 10 |

## Review (goldens 12 / 15)

| # | Sev | Finding | Ground |
|---|---|---|---|
| V-1 | low | The stat-tile grid wraps to a lone tile (`12 % Offcut waste`) on the second row — visually unbalanced at 1440 px. Let the grid pack 5-up or size tiles to fill the row. | golden 12 |
| V-2 | low | Two near-identical "Sheet not calibrated" warnings print full sentences each; the Quick-fix chip above already batches them. Collapse duplicates to one row with a `×2` count + both Locate links. | golden 12 |

## Commercial (golden 13)

| # | Sev | Finding | Ground |
|---|---|---|---|
| C-1 | medium | Section naming: "**Mechanical BOM**" is followed by a bare "**BOM**" for the electrical one. Rename to "Electrical BOM" (EN+ID keys exist for the workspace). | golden 13 headings |

## Projects (golden 14)

| # | Sev | Finding | Ground |
|---|---|---|---|
| P-1 | low | The DRAWINGS / REPORTS / DATA disclosure rows carry only chevrons — no count captions (`5 drawings`…), so the ranked export surface hides its inventory until opened. Add per-row counts. | golden 14 |

## Building / Preferences (design captures)

| # | Sev | Finding | Ground |
|---|---|---|---|
| B-1 | low | The per-level delete `×` is a small hit target next to the elevation caption, on the page whose add control was deliberately brought to ≥40-px targets. Give delete the same target size (and keep destructive spacing from the height stepper). | building_dark.png |
| PR-1 | low | "Software update — Auto-update runs in the installed app." floats between cards as an orphan caption. House it in a card or under a section label like every other row. | preferences_dark.png |

---

## Plan — three waves

**Wave A — honesty + the electrical feel remainder (high/medium, small diffs):**
L-1 (`0.0 m` → unmeasured), E-1 (feeder-label stagger), L-2 (heatmap basis
captions), C-1 (Electrical BOM heading). Each is localized to one widget/file;
L-1 and E-1 first — they mislead.

**Wave B — canvas label + overflow robustness:** R-1 (chip-row scroll),
R-2 (live riser label collision pass — port the existing export placer),
R-3 (callout corner reservation), L-3 (empty-state caption gating),
E-2 (LOD hysteresis/crossfade, `MechXMotion`-gated).

**Wave C — chrome polish:** E-3 (zoom pill), E-4 (band-width truncation),
R-4 (inspector top-align), V-1/V-2, P-1, B-1, PR-1.

Gate per wave, as always: `flutter analyze` clean + engine `dart test` + app
`flutter test`; goldens re-captured only where the wave intentionally shifts
them, each re-capture visually verified.
