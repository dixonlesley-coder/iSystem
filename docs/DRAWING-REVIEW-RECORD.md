# Drawing review record — reference buildings

- **Date:** 2026-11-13
- **Checklist:** `docs/DRAFTING-CHECKLIST.md` (25 items, A–G)
- **Sets reviewed:** house (Rumah Contoh, 13 pages), shophouse (Ruko Contoh, 26), office (Kantor Contoh, 33),
  apartment (Apartemen Contoh, 81), tower (Menara Contoh 30, 185) — 338 pages, PDF rasterised at 150 dpi.
- **Scope:** the visual items 4, 8, 9, 10, 11, 12, 13, 14, 17, 18, 19, 20, 21, 22, plus a sanity look at
  1 / 5 / 6 / 7. Items 1, 2, 3, 5, 6 (overlap stamp), 7, 23, 24, 25 are covered by the scripted pre-check
  (`<building>/precheck.md`, zero failures). Item 15 is N-A (no grid defined) and item 16 is N-A (no underlay)
  in all five fixtures.

## Method

1. All 59 contact sheets were viewed (house 3, shophouse 5, office 6, apartment 14, tower 31).
2. 19 of them were viewed a second time with written notes: house 01-02, shophouse 01-04, office 01-06,
   apartment 01, 02, 05, 06, 07, 10, 11. Tower 10-31 were noted on the first pass.
3. Full-resolution pages opened (18) plus three full-resolution crops:
   - house: `riser-sld-p1`, `electrical-riser-p1`
   - shophouse: `plan-1-Lantai 1-p1`, `plan-2-Lantai 2-p1`
   - office: `plan-1-Lantai 1-p1`, `elec-plan-1-Lantai 1-p1` (+ crop of the right border), `electrical-riser-p1`
   - apartment: `riser-sld-p1`, `riser-sld-p6`, `plan-12-Lantai 12-detail-p1`, `electrical-riser-p3` (+ crop),
     `electrical-power-one-line-p1`
   - tower: `plan-30-Lantai 30-p1`, `plan-29-Lantai 29-detail-p1`, `riser-sld-p13`, `elec-plan-1-Lantai 1-p1`
     (+ crop of the pump labels), `electrical-riser-p3`, `electrical-power-one-line-p1`
4. Plan-vs-riser spot checks (items 14 / 18), two or more elements per building where both were legible.

### Limits of this review (read before relying on a PASS)

- The brief asked for one full-resolution page per sheet type per building. That was **not** reached: electrical
  SLD, building single-line, panel schedule, equipment schedule and drawing list were judged from contact-sheet
  thumbnails only in every building, and the house / shophouse / office detail and schedule sheets likewise.
  Thumbnails are large enough to read these tabular sheets, but small-text defects could be missed.
- These contact sheets were seen once, on the first pass, and no per-sheet notes were kept: apartment 03, 04
  (plans / details Lantai 5-10), 08, 09 (panel SLD pages 4-15), 12-14 (panel schedules); tower 01-09 (front
  matter, plans and details Lantai 1-17). Their verdicts below are carried from the same sheet type reviewed with
  notes in the same building, not from an individual mark-up. A second look at those sheets is still owed.
- Shophouse M-101 and M-103 item 6 is judged from the thumbnail; only M-102 was confirmed at full resolution.
- Item 21 was checked for column alignment and populated R/S/T columns; totals were not re-added by hand.
- House plan-vs-riser sizes could not be read off the riser thumbnail, so item 18 for the house rests on tags only.

## Results

Legend: P = PASS, F = FAIL, - = N-A. Column "other" records a failure on a non-visual item (4-digit sanity look).

### house — Rumah Contoh (PLN 1-phase only)

| Sheet type | 4 | 8 | 9 | 10 | 11 | 12 | 13 | 14 | 17 | 18 | 19 | 20 | 21 | 22 | other |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Front matter G-001..G-003 | P | - | P | P | - | - | - | - | - | - | - | - | P | - | |
| Mechanical plan M-101, M-102 | P | P | P | P | P | P | P | P | - | P | - | - | - | - | |
| Detail M-501 | P | P | F | P | P | P | P | P | - | - | - | - | - | - | |
| Mechanical riser M-201 | P | P | P | P | P | P | - | P | P | P | - | - | - | - | |
| Electrical SLD E-201 | P | - | P | P | P | - | - | - | - | - | P | P | P | - | |
| Building single-line E-301 | P | - | P | P | P | - | - | - | - | - | P | P | - | P | |
| Electrical riser E-401 | P | - | P | P | P | - | - | - | P | P | P | P | - | P | |
| Equipment schedule M-601 | P | - | - | - | - | - | - | P | - | P | - | - | P | - | |
| Panel schedule E-601 | P | - | P | P | P | - | - | - | - | - | P | - | P | - | |

### shophouse — Ruko Contoh (PLN 3-phase, main board to three unit boards + MEP board)

| Sheet type | 4 | 8 | 9 | 10 | 11 | 12 | 13 | 14 | 17 | 18 | 19 | 20 | 21 | 22 | other |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Front matter G-001..G-003 | P | - | P | P | - | - | - | - | - | - | - | - | P | - | |
| Mechanical plan M-101..M-103 | P | P | P | P | P | P | P | P | - | P | - | - | - | - | item 6 F |
| Electrical layout E-101, E-102 | P | - | F | P | - | - | P | P | - | - | - | - | - | - | |
| Mechanical riser M-201 (2 pp) | P | P | P | P | P | P | - | P | P | P | - | - | - | - | |
| Electrical SLD E-201 (5 pp) | P | - | P | P | P | - | - | - | - | - | P | P | P | - | |
| Building single-line E-301 | P | - | P | P | P | - | - | - | - | - | P | P | - | P | |
| Electrical riser E-401 (2 pp) | P | - | P | P | P | - | - | - | P | P | P | P | - | P | |
| Equipment schedule M-601 (3 pp) | P | - | - | - | - | - | - | P | - | P | - | - | P | - | |
| Panel schedule E-601 (5 pp) | P | - | P | P | P | - | - | - | - | - | P | - | P | - | |

### office — Kantor Contoh (PLN 3-phase 164 kVA, no genset)

| Sheet type | 4 | 8 | 9 | 10 | 11 | 12 | 13 | 14 | 17 | 18 | 19 | 20 | 21 | 22 | other |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Front matter G-001..G-003 | P | - | P | P | - | - | - | - | - | - | - | - | P | - | |
| Mechanical plan M-101..M-104 | P | P | P | P | P | P | P | P | - | P | - | - | - | - | |
| Detail M-501..M-504 | P | P | F | P | P | P | P | P | - | - | - | - | - | - | |
| Electrical layout E-101 | F | - | F | P | - | - | P | P | - | - | - | - | - | - | |
| Electrical layout E-102 | P | - | F | P | - | - | P | P | - | - | - | - | - | - | |
| Mechanical riser M-201 (3 pp) | P | P | P | P | P | P | - | P | P | P | - | - | - | - | |
| Electrical SLD E-201 (6 pp) | P | - | P | P | P | - | - | - | - | - | P | P | P | - | |
| Building single-line E-301 | P | - | P | P | P | - | - | - | - | - | P | P | - | P | |
| Electrical riser E-401 (2 pp) | P | - | P | P | P | - | - | - | P | P | P | P | - | P | item 5 F (p1) |
| Equipment schedule M-601 (2 pp) | P | - | - | - | - | - | - | P | - | P | - | - | P | - | |
| Panel schedule E-601 (6 pp) | P | - | P | P | P | - | - | - | - | - | P | - | P | - | |

### apartment — Apartemen Contoh (PLN 197 kVA + 300 kVA standby genset, essential board)

| Sheet type | 4 | 8 | 9 | 10 | 11 | 12 | 13 | 14 | 17 | 18 | 19 | 20 | 21 | 22 | other |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Front matter G-001..G-003 (4 pp) | P | - | P | P | - | - | - | - | - | - | - | - | P | - | |
| Mechanical plan M-101..M-112 | P | P | P | P | P | P | P | P | - | P | - | - | - | - | |
| Detail M-501..M-512 | P | P | F | P | P | P | P | P | - | - | - | - | - | - | |
| Electrical layout E-101..E-103 | P | - | F | P | - | - | P | P | - | - | - | - | - | - | |
| Mechanical riser M-201 (8 pp) | P | P | P | P | P | P | - | P | P | P | - | - | - | - | |
| Electrical SLD E-201 (15 pp) | P | - | P | P | P | - | - | - | - | - | P | P | P | - | |
| Building single-line E-301 (4 pp) | P | - | P | P | P | - | - | - | - | - | P | P | - | P | |
| Electrical riser E-401 (4 pp) | P | - | P | P | P | - | - | - | P | P | P | P | - | P | |
| Power one-line E-501 | P | - | P | P | P | - | - | - | - | - | - | P | - | P | |
| Equipment schedule M-601 (3 pp) | P | - | - | - | - | - | - | P | - | P | - | - | P | - | |
| Panel schedule E-601 (15 pp) | P | - | P | P | P | - | - | - | - | - | P | - | P | - | |

### tower — Menara Contoh 30 (MV 20 kV, 1600 kVA transformer, 800 kVA genset, 250 kvar capacitor bank)

| Sheet type | 4 | 8 | 9 | 10 | 11 | 12 | 13 | 14 | 17 | 18 | 19 | 20 | 21 | 22 | other |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Front matter G-001..G-003 (6 pp) | P | - | P | P | - | - | - | - | - | - | - | - | P | - | |
| Mechanical plan M-101..M-130 | P | P | P | P | P | P | P | P | - | P | - | - | - | - | |
| Detail M-501..M-538 | P | P | F | P | P | P | P | P | - | - | - | - | - | - | |
| Electrical layout E-101 | P | - | F | P | - | - | P | P | - | - | - | - | - | - | item 6 F |
| Electrical layout E-102, E-103 | P | - | F | P | - | - | P | P | - | - | - | - | - | - | |
| Mechanical riser M-201 (14 pp) | P | P | P | P | P | P | - | P | P | P | - | - | - | - | |
| Electrical SLD E-201 (34 pp) | P | - | P | P | P | - | - | - | - | - | P | P | P | - | |
| Building single-line E-301 (17 pp) | P | - | P | P | P | - | - | - | - | - | P | P | - | P | |
| Electrical riser E-401 (4 pp) | P | - | P | P | P | - | - | - | P | P | P | P | - | P | |
| Power one-line E-501 | P | - | P | P | P | - | - | - | - | - | - | P | - | F | |
| Equipment schedule M-601 (4 pp) | P | - | - | - | - | - | - | P | - | P | - | - | P | - | |
| Panel schedule E-601 (34 pp) | P | - | P | P | P | - | - | - | - | - | P | - | P | - | |

Spot checks for items 14 / 18 (plan tag and size against riser tag and size), all agreeing:
shophouse RW-R1 DN125 / 125-RW-PVC, CW-R1 DN20 / 20-CW-PPR-TRANSFER; office CW-R1 DN50-DN40-DN32 by floor /
50-, 40-, 32-CW-PPR-BOOSTER, RW-R1 DN150 / 150-RW-PVC, FH-R1 DN100 / 100-FH-BS; apartment CW-R1 DN65 /
65-CW-PPR-TRANSFER, FH-R1 DN100 / 100-FH-BS, RW-R1 DN200 / 200-RW-PVC, SP-R1 DN40 / 40-SP-BS; tower CW-R1
DN100 / 100-CW-PPR-TRANSFER, FH-R1 DN100 / 100-FH-BS, RW-R1 DN200 / 200-RW-PVC, SP-R1 DN40 / 40-SP-BS.

## FAIL list

PNG paths are relative to
`/tmp/claude-0/-home-user-iSystem/4777c01d-c7ee-56ae-bfa5-90847b3f68b2/scratchpad/drawings/`.

| # | Building | Sheet (file, page) | Item | What is wrong | PNG |
|---|---|---|---|---|---|
| F1 | office | `elec-plan-1-Lantai 1.pdf` p1 (E-101) | 4 | Load label "Pump P-01 / MCCB 125A" runs across the right sheet border; the last characters print outside the frame. | `office/png/Kantor Contoh-elec-plan-1-Lantai 1-p1.png` |
| F2 | tower | `elec-plan-1-Lantai 1.pdf` p1 (E-101) | 6 | Labels "Pump P-02 / MCCB 40A" and "Pump P-01 / MCCB 40A" overprint each other and the P-01 symbol; P-02's text is not readable. | `tower/png/Menara Contoh 30-elec-plan-1-Lantai 1-p1.png` |
| F3 | office | `electrical-riser.pdf` p1 (E-401) | 5 | The issued sheet carries the red stamp "PERHATIAN: label tercetak 7.0 pt (< 7 pt) ... use a larger sheet or split". A warning stamp on an issued sheet is a mark-up; the wording also contradicts itself (7.0 pt is not below 7 pt). The scripted pre-check passed item 5 on this sheet. | `office/png/Kantor Contoh-electrical-riser-p1.png` |
| F4 | shophouse | `plan-2-Lantai 2.pdf` p1 (M-102); same pattern on `plan-1-Lantai 1.pdf` p1 (M-101) and `plan-3-Lantai 3.pdf` p1 (M-103), thumbnail only | 6 | The pipe-key table is placed against the third unit: the RW-R3 riser marker "DN / UP" touches the table's KEY column and the rotated "D-L1 · DN40 / 1.5 m - 1:50" label runs into the table title. | `shophouse/png/Ruko Contoh-plan-2-Lantai 2-p1.png` |
| F5 | shophouse, office, apartment, tower | every electrical layout plan: shophouse E-101, E-102; office E-101, E-102; apartment E-101..E-103; tower E-101..E-103 | 9 | Legend lists "Panel" and "Kabel" but no panel and no cable is drawn on any of these sheets (all panels are listed as "belum ditempatkan"). The legend does not match the sheet. | e.g. `tower/png/Menara Contoh 30-elec-plan-1-Lantai 1-p1.png` |
| F6 | house, office, apartment, tower | every mechanical detail sheet (M-5nn) | 9 | The detail sheet repeats the parent plan's legend, so it lists services and symbols not drawn inside the detail window (house M-501: Rainwater; apartment M-512: Rainwater, Sprinkler, Hydrant, Roof drain, Sprinkler head, Hydrant box; tower M-532: Rainwater, Sprinkler, Hydrant, Hydrant box). | e.g. `apartment/png/Apartemen Contoh-plan-12-Lantai 12-detail-p1.png` |
| F7 | tower | `electrical-power-one-line.pdf` p1 (E-501) | 22 | The declared 250 kvar capacitor bank is absent, and the MV 20 kV side and the 1600 kVA transformer appear only as the caption "MV via TX 1600 kVA" beside a utility symbol. E-301 p1 shows the full arrangement, so the two sheets disagree. | `tower/png/Menara Contoh 30-electrical-power-one-line-p1.png` |

F5 and F6 are one defect each repeated across a sheet type; F6 is the mildest (a checker who accepts a common
legend per floor would let it pass, but the checklist says "exactly").

## Observations (not failures)

1. Electrical risers place boards on the wrong storey because the fixtures have no placed panels: apartment E-401
   draws PP-Lt1..PP-Lt12 as one "TIPIKAL x12" box on Lantai 2, leaving p1 (Lantai 12) and p2 (Lantai 11-6) with
   floor labels and nothing else; tower E-401 draws PP-Lt1..PP-Lt30 on Lantai 2; office E-401 draws PP-L1..PP-L4
   on Lantai 2. Floors are in true order, but two apartment pages are empty.
2. Mechanical risers are crowded at plant level and readable only through the key table: tower `riser-sld` p13
   (Lantai 1, key bubbles 15-28 around the fire pumps, some touching) and p1 (Lantai 30), apartment `riser-sld`
   p1 and p6, shophouse `riser-sld` p2. Nothing is hidden, but parallel services sit very close.
3. Plan tags carry a level index one below the sheet's floor name (tower Lantai 30 plan prints "SP-L29",
   "RW-L29"; Lantai 24 prints "CW-L23"; shophouse and apartment the same, with "GF" on Lantai 1). It is
   consistent, but a reader will take "L29" to mean Lantai 29.
4. Tower building single-line E-301 spends pages 2-16 on one LVMDP box and two boards each (15 near-empty A3
   pages); a tabulated typical would carry the same content on one or two sheets.
5. Equipment schedules print "capacity not set" as the duty of every tank in house, shophouse and office (item 18
   asks for tag and duty); it is a missing fixture input, honestly flagged. Shophouse `equipment-schedule` p3 holds
   only the two orphan words "catalogue model." from the footnote.
6. Phase imbalance printed on shophouse boards is high (PP Ruko 32.7 %, MEP 98.3 %) and tower PP-Lt10 is rated
   6 kA where its 29 sister boards are 10 kA. Both are engineering content, outside this checklist.
7. Apartment E-301 p1 ties the genset to the incoming line with no transfer switch drawn, while E-501 shows the
   ATS; tower E-101 lists 33 unplaced panels and "245 beban belum ditempatkan" in a block that fills the left
   third of the sheet.
8. Tower `plan-30-Lantai 30` p1: the leader of "SP-L29 · DN32 / 3.0 m - CL +3.70" passes through its own text;
   apartment M-512 detail B: the "CW-L11 · DN15 - 4.1 m" label sits on its own pipe. Both remain legible.

## Fix round (2026-11-13)

Every FAIL above was fixed in the engine (tests in
`packages/mechx_engine/test/drawing_review_fix_round_test.dart`, §15 row "Drawing review fix
round F1-F7"). PNG paths are relative to the same `drawings/` root.

| # | What changed | Re-check |
|---|---|---|
| F1 | `layoutElectricalPlanAnnotations` places every node tag block inside the drawing frame (sheet frame above the title-block band, clear of the north arrow, legend and corner notes): a tag that would cross the right edge flips left; the BELUM DITEMPATKAN list wraps into columns above the title-block band. | `office/png/Kantor Contoh-elec-plan-1-Lantai 1-p1.png` |
| F2 | Co-located load tags are tried right, left, then stacked a block height down / up (leadered back), clear of every symbol and earlier tag; a tag with no clear slot is counted in the sheet's stamped overlap warning, so the pre-check's item 6 now covers the electrical layout family. | `tower/png/Menara Contoh 30-elec-plan-1-Lantai 1-p1.png` |
| F3 | `sldPrintsBelowMinPt`: the legibility stamp fires only when the size it prints (one decimal) is strictly below 7 pt; the pre-check FAILs item 5 on any sheet carrying the stamp. | `office/png/Kantor Contoh-electrical-riser-p1.png` |
| F4 | `placePlanKeyTable` keeps one text height of clear paper from every mark, marker text, label and run; the pre-check FAILs item 6 when drawing text comes within half a text height of a pipe-key table. | `shophouse/png/Ruko Contoh-plan-2-Lantai 2-p1.png` (also plan-1, plan-3) |
| F5 | `electricalPlanLegendRows`: the layout legend (PDF + DXF) lists only Panel / Beban / Kabel rows the sheet draws. | `tower/png/Menara Contoh 30-elec-plan-1-Lantai 1-p1.png` |
| F6 | `planDetailLegendChrome`: a detail sheet's legend keeps only the services of its clipped runs and the symbols of its visible nodes. | `apartment/png/Apartemen Contoh-plan-12-Lantai 12-detail-p1.png` |
| F7 | `serviceArrangementOf` is the one declared source arrangement: E-301's spine and E-501's power one-line both draw the MV supply + MV main, TRANSFORMER 1600 kVA, the LV bus and the 250 kvar capacitor bank from it (E-501: PLN head `MV supply + MV main` -> transformer -> bus, the bank beside the bus; generator + ATS as before). | `tower/png/Menara Contoh 30-electrical-power-one-line-p1.png` |

Observations 1, 3, 4 and 2 are recorded in the Backlog of `docs/REFERENCE-BUILDINGS.md`
("Drawing review").

## Re-check of the failed sheets (2026-11-13, reviewer)

Only the sheets that failed were re-checked, at full resolution, after the fix round and a full regeneration of the five sets (scripted pre-check: zero FAIL lines on all five buildings).

| Fail | Sheet re-checked | Item | Result | What the sheet now shows |
|---|---|---|---|---|
| F1 | office `elec-plan-1-Lantai 1` p1 (E-101) | 4 | PASS | "Pump P-01 / MCCB 125A" sits left of its symbol, wholly inside the frame |
| F2 | tower `elec-plan-1-Lantai 1` p1 (E-101) | 6 | PASS | P-01 and P-02 tags are separate, P-02 on a short leader; nothing overprints |
| F3 | office `electrical-riser` p1 (E-401) | 5 | PASS | no "below 7 pt" stamp on the 7.0 pt sheet |
| F4 | shophouse `plan-2-Lantai 2` p1 (M-102) | 6 | PASS | pipe key table sits clear below the drawing; no marker or label touches it |
| F5 | tower / office E-101 | 9 | PASS | legend lists only "Beban / titik", the one kind drawn |
| F6 | apartment `plan-12-Lantai 12-detail` p1 (M-512) | 9 | PASS | legend lists cold water, drainage, vent and booster set only |
| F7 | tower `electrical-power-one-line` p1 (E-501) | 22 | PASS | MV supply, 1600 kVA transformer, LV bus, 250 kvar capacitor bank, 800 kVA genset and ATS are drawn |

Observations carried to the backlog (not failures): the office E-101 tag ends flush against its own symbol; the detail-sheet abbreviation notes still name fixtures outside the window; E-401 p1 is a floor-label-only page.

Result: every checklist item passes on the sheets reviewed. Coverage limits of the first review (thumbnail-only sheet types, verdicts carried by sheet type on some apartment and tower montages) are stated in the header above and still apply.

## Completion pass (2026-11-13)

Second reviewer pass over the sets regenerated after the fix round, to close the coverage gaps stated in the
header: every contact sheet viewed with a written note per sheet, every sheet type opened at full resolution in
every building, every issued page given its own row. PNG paths are relative to the same `drawings/` root.

### What was viewed

- **Contact sheets (all 59):** house 01-03, shophouse 01-05, office 01-06, apartment 01-14, tower 01-31.
- **Full-resolution pages (51) and crops (3):**
  - house (9): `plan-1-Lantai 1` p1 (+ crop), `plan-1-Lantai 1-detail` p1, `riser-sld` p1, `electrical-sld` p1,
    `electrical-overview-sld` p1, `electrical-riser` p1, `panel-schedules` p1, `equipment-schedule` p2,
    `00-cover-sheets` p2; crop of `plan-2-Lantai 2` p1.
  - shophouse (8): `plan-1-Lantai 1` p1, `riser-sld` p2, `electrical-sld` p1, `electrical-overview-sld` p1,
    `electrical-riser` p1, `panel-schedules` p5, `equipment-schedule` p2, `00-cover-sheets` p2. No detail sheet
    is issued for the shophouse.
  - office (9): `plan-2-Lantai 2` p1, `plan-3-Lantai 3-detail` p1, `riser-sld` p3, `electrical-sld` p1,
    `electrical-overview-sld` p1, `electrical-riser` p2, `panel-schedules` p2, `equipment-schedule` p2,
    `00-cover-sheets` p2.
  - apartment (13): `plan-1-Lantai 1` p1, `plan-11-Lantai 11-detail` p1, `riser-sld` p1 and p6 (+ crop),
    `electrical-sld` p1, p3, p4, `electrical-overview-sld` p1, `electrical-riser` p3,
    `electrical-power-one-line` p1, `panel-schedules` p3, `equipment-schedule` p2, `00-cover-sheets` p3.
  - tower (12): `plan-16-Lantai 16` p1, `plan-30-Lantai 30-detail-2` p1, `riser-sld` p13, `electrical-sld` p1,
    p4, p14, `electrical-overview-sld` p1, `electrical-riser` p3, `electrical-power-one-line` p1,
    `panel-schedules` p3, `equipment-schedule` p2, `00-cover-sheets` p5.
- **Text extraction (pdftotext) used alongside the images:** every row and total of every panel-schedule page
  (65 pages) and of the matching electrical SLD page; the drawing list of each set against `INDEX.md`; riser and
  plan tags for the spot checks in house and shophouse.

### Drawing list (G-002) against INDEX.md

Row by row, number and title, in issue order: house 12 of 12, shophouse 14 of 14, office 19 of 19, apartment
37 of 37, tower 81 of 81 rows match; row numbering is 1..n without gaps and the cover's sheet count equals the
list length in all five sets. Item 23 PASS (tower G-002 p5, rows 73-81, also read at full resolution).

### Spot checks

- Items 14 / 18, plan against riser (size and tag): house CW-R1 DN20 / 20-CW-PPR-GRAVITASI, RW-R1 DN100 /
  100-RW-PVC; shophouse RW-R1 DN125 / 125-RW-PVC, CW-R1 DN20 / 20-CW-PPR-TRANSFER; office CW-R1 DN50 /
  50-CW-PPR-BOOSTER, RW-R1 DN150 / 150-RW-PVC (also FH-R1 DN100 / 100-FH-BS, SP-R1 DN32 / 32-SP-BS); apartment
  CW-R1 DN65 / 65-CW-PPR-TRANSFER, FH-R1 DN100 / 100-FH-BS (also RW-R1 DN200, SP-R1 DN40); tower CW-R1 DN100 /
  100-CW-PPR-TRANSFER, RW-R1 DN200 / 200-RW-PVC (also SP-R1 DN40 / 40-SP-BS, FH-R1 DN100 / 100-FH-BS). All agree.
- Item 24, incomer on panel schedule against electrical SLD (also E-301 and M-601): house Panel Rumah MCB
  C40A/2P 6kA; shophouse PP Ruko MCB C50A/4P 10kA; office LVMDP MCCB 250A/4P 16kA; apartment LVMDP MCCB 315A/4P
  16kA; tower LVMDP MCCB 1600A/4P 100kA. The incomer line of every one of the 65 schedule pages is
  character-identical to the same page of the electrical SLD.
- Item 22: house E-301 PLN 4.4 kVA, one 1-phase board; shophouse PLN 33 kVA, PP Ruko feeding Ruko A / B / C and
  MEP; office PLN 164 kVA, no genset drawn; apartment PLN 197 kVA + GENSET 300 kVA standby + PP-E essential,
  ATS on E-501; tower PLN MV station, MV main, TRANSFORMER 1600 kVA, GENSET 800 kVA, CAPACITOR BANK 250 kvar on
  both E-301 p1 and E-501. All match the inputs; nothing undeclared is drawn.

### Per-page verdicts

Legend: P = PASS, F = FAIL, - = N-A. Items 15 and 16 are N-A on every page (no grid, no underlay). Item 10 was
judged per set (symbols consistent between plan, riser and legend): PASS in all five.

#### house

| file | page | dwg no | 4 | 8 | 9 | 11 | 12 | 13 | 14 | 17 | 18 | 19 | 20 | 21 | 22 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `00-cover-sheets.pdf` | 1 | G-001 | P | - | - | - | - | - | - | - | - | - | - | - | - |
| `00-cover-sheets.pdf` | 2 | G-002 | P | - | - | - | - | - | - | - | - | - | - | P | - |
| `00-cover-sheets.pdf` | 3 | G-003 | P | - | P | - | - | - | - | - | - | - | - | - | - |
| `plan-1-Lantai 1.pdf` | 1 | M-101 | P | P | P | P | P | P | P | - | P | - | - | - | - |
| `plan-1-Lantai 1-detail.pdf` | 1 | M-501 | P | P | P | P | P | P | P | - | - | - | - | - | - |
| `plan-2-Lantai 2.pdf` | 1 | M-102 | P | P | P | P | P | P | P | - | P | - | - | - | - |
| `riser-sld.pdf` | 1 | M-201 | P | P | P | P | P | - | P | P | P | - | - | - | - |
| `electrical-sld.pdf` | 1 | E-201 | P | - | P | P | - | - | - | - | - | P | P | F | - |
| `electrical-overview-sld.pdf` | 1 | E-301 | P | - | P | P | - | - | - | - | - | P | P | - | P |
| `electrical-riser.pdf` | 1 | E-401 | P | - | P | P | - | - | - | P | P | P | P | - | P |
| `equipment-schedule.pdf` | 1 | M-601 | P | - | - | - | - | - | - | - | - | - | - | - | - |
| `equipment-schedule.pdf` | 2 | M-601 | P | - | - | - | - | - | P | - | P | - | - | P | - |
| `panel-schedules.pdf` | 1 | E-601 | P | - | P | P | - | - | - | - | - | P | - | F | - |

#### shophouse

| file | page | dwg no | 4 | 8 | 9 | 11 | 12 | 13 | 14 | 17 | 18 | 19 | 20 | 21 | 22 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `00-cover-sheets.pdf` | 1 | G-001 | P | - | - | - | - | - | - | - | - | - | - | - | - |
| `00-cover-sheets.pdf` | 2 | G-002 | P | - | - | - | - | - | - | - | - | - | - | P | - |
| `00-cover-sheets.pdf` | 3 | G-003 | P | - | P | - | - | - | - | - | - | - | - | - | - |
| `plan-1-Lantai 1.pdf` | 1 | M-101 | P | P | P | P | P | P | P | - | P | - | - | - | - |
| `plan-2-Lantai 2.pdf` | 1 | M-102 | P | P | P | P | P | P | P | - | P | - | - | - | - |
| `plan-3-Lantai 3.pdf` | 1 | M-103 | P | P | P | P | P | P | P | - | P | - | - | - | - |
| `elec-plan-1-Lantai 1.pdf` | 1 | E-101 | P | - | P | - | - | P | P | - | - | - | - | - | - |
| `elec-plan-3-Lantai 3.pdf` | 1 | E-102 | P | - | P | - | - | P | P | - | - | - | - | - | - |
| `riser-sld.pdf` | 1 | M-201 | P | P | P | P | P | - | P | P | P | - | - | - | - |
| `riser-sld.pdf` | 2 | M-201 | P | P | P | P | P | - | P | P | P | - | - | - | - |
| `electrical-sld.pdf` | 1 | E-201 | P | - | P | P | - | - | - | - | - | P | P | P | - |
| `electrical-sld.pdf` | 2 | E-201 | P | - | P | P | - | - | - | - | - | P | P | F | - |
| `electrical-sld.pdf` | 3 | E-201 | P | - | P | P | - | - | - | - | - | P | P | F | - |
| `electrical-sld.pdf` | 4 | E-201 | P | - | P | P | - | - | - | - | - | P | P | F | - |
| `electrical-sld.pdf` | 5 | E-201 | P | - | P | P | - | - | - | - | - | P | P | P | - |
| `electrical-overview-sld.pdf` | 1 | E-301 | P | - | P | P | - | - | - | - | - | P | P | - | P |
| `electrical-riser.pdf` | 1 | E-401 | P | - | P | P | - | - | - | P | P | P | P | - | - |
| `electrical-riser.pdf` | 2 | E-401 | P | - | P | P | - | - | - | P | P | P | P | - | P |
| `equipment-schedule.pdf` | 1 | M-601 | P | - | - | - | - | - | - | - | - | - | - | - | - |
| `equipment-schedule.pdf` | 2 | M-601 | P | - | - | - | - | - | P | - | P | - | - | P | - |
| `equipment-schedule.pdf` | 3 | M-601 | P | - | - | - | - | - | - | - | - | - | - | - | - |
| `panel-schedules.pdf` | 1 | E-601 | P | - | P | P | - | - | - | - | - | P | - | P | - |
| `panel-schedules.pdf` | 2 | E-601 | P | - | P | P | - | - | - | - | - | P | - | F | - |
| `panel-schedules.pdf` | 3 | E-601 | P | - | P | P | - | - | - | - | - | P | - | F | - |
| `panel-schedules.pdf` | 4 | E-601 | P | - | P | P | - | - | - | - | - | P | - | F | - |
| `panel-schedules.pdf` | 5 | E-601 | P | - | P | P | - | - | - | - | - | P | - | P | - |

#### office

| file | page | dwg no | 4 | 8 | 9 | 11 | 12 | 13 | 14 | 17 | 18 | 19 | 20 | 21 | 22 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `00-cover-sheets.pdf` | 1 | G-001 | P | - | - | - | - | - | - | - | - | - | - | - | - |
| `00-cover-sheets.pdf` | 2 | G-002 | P | - | - | - | - | - | - | - | - | - | - | P | - |
| `00-cover-sheets.pdf` | 3 | G-003 | P | - | P | - | - | - | - | - | - | - | - | - | - |
| `plan-1-Lantai 1.pdf` | 1 | M-101 | P | P | P | P | P | P | P | - | P | - | - | - | - |
| `plan-1-Lantai 1-detail.pdf` | 1 | M-501 | P | P | P | P | P | P | P | - | - | - | - | - | - |
| `plan-2-Lantai 2.pdf` | 1 | M-102 | P | P | P | P | P | P | P | - | P | - | - | - | - |
| `plan-2-Lantai 2-detail.pdf` | 1 | M-502 | P | P | P | P | P | P | P | - | - | - | - | - | - |
| `plan-3-Lantai 3.pdf` | 1 | M-103 | P | P | P | P | P | P | P | - | P | - | - | - | - |
| `plan-3-Lantai 3-detail.pdf` | 1 | M-503 | P | P | P | P | P | P | P | - | - | - | - | - | - |
| `plan-4-Lantai 4.pdf` | 1 | M-104 | P | P | P | P | P | P | P | - | P | - | - | - | - |
| `plan-4-Lantai 4-detail.pdf` | 1 | M-504 | P | P | P | P | P | P | P | - | - | - | - | - | - |
| `elec-plan-1-Lantai 1.pdf` | 1 | E-101 | P | - | P | - | - | P | P | - | - | - | - | - | - |
| `elec-plan-2-Lantai 2.pdf` | 1 | E-102 | P | - | P | - | - | P | P | - | - | - | - | - | - |
| `riser-sld.pdf` | 1 | M-201 | P | P | P | P | P | - | P | P | P | - | - | - | - |
| `riser-sld.pdf` | 2 | M-201 | P | P | P | P | P | - | P | P | P | - | - | - | - |
| `riser-sld.pdf` | 3 | M-201 | P | P | P | P | P | - | P | P | P | - | - | - | - |
| `electrical-sld.pdf` | 1 | E-201 | P | - | P | P | - | - | - | - | - | P | P | P | - |
| `electrical-sld.pdf` | 2 | E-201 | P | - | P | P | - | - | - | - | - | P | P | F | - |
| `electrical-sld.pdf` | 3 | E-201 | P | - | P | P | - | - | - | - | - | P | P | F | - |
| `electrical-sld.pdf` | 4 | E-201 | P | - | P | P | - | - | - | - | - | P | P | F | - |
| `electrical-sld.pdf` | 5 | E-201 | P | - | P | P | - | - | - | - | - | P | P | F | - |
| `electrical-sld.pdf` | 6 | E-201 | P | - | P | P | - | - | - | - | - | P | P | P | - |
| `electrical-overview-sld.pdf` | 1 | E-301 | P | - | P | P | - | - | - | - | - | P | P | - | P |
| `electrical-riser.pdf` | 1 | E-401 | P | - | P | P | - | - | - | P | P | P | P | - | - |
| `electrical-riser.pdf` | 2 | E-401 | P | - | P | P | - | - | - | P | P | P | P | - | - |
| `electrical-riser.pdf` | 3 | E-401 | P | - | P | P | - | - | - | P | P | P | P | - | P |
| `equipment-schedule.pdf` | 1 | M-601 | P | - | - | - | - | - | - | - | - | - | - | - | - |
| `equipment-schedule.pdf` | 2 | M-601 | P | - | - | - | - | - | P | - | P | - | - | P | - |
| `panel-schedules.pdf` | 1 | E-601 | P | - | P | P | - | - | - | - | - | P | - | P | - |
| `panel-schedules.pdf` | 2 | E-601 | P | - | P | P | - | - | - | - | - | P | - | F | - |
| `panel-schedules.pdf` | 3 | E-601 | P | - | P | P | - | - | - | - | - | P | - | F | - |
| `panel-schedules.pdf` | 4 | E-601 | P | - | P | P | - | - | - | - | - | P | - | F | - |
| `panel-schedules.pdf` | 5 | E-601 | P | - | P | P | - | - | - | - | - | P | - | F | - |
| `panel-schedules.pdf` | 6 | E-601 | P | - | P | P | - | - | - | - | - | P | - | P | - |

#### apartment

| file | page | dwg no | 4 | 8 | 9 | 11 | 12 | 13 | 14 | 17 | 18 | 19 | 20 | 21 | 22 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `00-cover-sheets.pdf` | 1 | G-001 | P | - | - | - | - | - | - | - | - | - | - | - | - |
| `00-cover-sheets.pdf` | 2 | G-002 | P | - | - | - | - | - | - | - | - | - | - | P | - |
| `00-cover-sheets.pdf` | 3 | G-002 | P | - | - | - | - | - | - | - | - | - | - | P | - |
| `00-cover-sheets.pdf` | 4 | G-003 | P | - | P | - | - | - | - | - | - | - | - | - | - |
| `plan-1-Lantai 1.pdf` | 1 | M-101 | P | P | P | P | P | P | P | - | P | - | - | - | - |
| `plan-1-Lantai 1-detail.pdf` | 1 | M-501 | P | P | P | P | P | P | P | - | - | - | - | - | - |
| `plan-2-Lantai 2.pdf` | 1 | M-102 | P | P | P | P | P | P | P | - | P | - | - | - | - |
| `plan-2-Lantai 2-detail.pdf` | 1 | M-502 | P | P | P | P | P | P | P | - | - | - | - | - | - |
| `plan-3-Lantai 3.pdf` | 1 | M-103 | P | P | P | P | P | P | P | - | P | - | - | - | - |
| `plan-3-Lantai 3-detail.pdf` | 1 | M-503 | P | P | P | P | P | P | P | - | - | - | - | - | - |
| `plan-4-Lantai 4.pdf` | 1 | M-104 | P | P | P | P | P | P | P | - | P | - | - | - | - |
| `plan-4-Lantai 4-detail.pdf` | 1 | M-504 | P | P | P | P | P | P | P | - | - | - | - | - | - |
| `plan-5-Lantai 5.pdf` | 1 | M-105 | P | P | P | P | P | P | P | - | P | - | - | - | - |
| `plan-5-Lantai 5-detail.pdf` | 1 | M-505 | P | P | P | P | P | P | P | - | - | - | - | - | - |
| `plan-6-Lantai 6.pdf` | 1 | M-106 | P | P | P | P | P | P | P | - | P | - | - | - | - |
| `plan-6-Lantai 6-detail.pdf` | 1 | M-506 | P | P | P | P | P | P | P | - | - | - | - | - | - |
| `plan-7-Lantai 7.pdf` | 1 | M-107 | P | P | P | P | P | P | P | - | P | - | - | - | - |
| `plan-7-Lantai 7-detail.pdf` | 1 | M-507 | P | P | P | P | P | P | P | - | - | - | - | - | - |
| `plan-8-Lantai 8.pdf` | 1 | M-108 | P | P | P | P | P | P | P | - | P | - | - | - | - |
| `plan-8-Lantai 8-detail.pdf` | 1 | M-508 | P | P | P | P | P | P | P | - | - | - | - | - | - |
| `plan-9-Lantai 9.pdf` | 1 | M-109 | P | P | P | P | P | P | P | - | P | - | - | - | - |
| `plan-9-Lantai 9-detail.pdf` | 1 | M-509 | P | P | P | P | P | P | P | - | - | - | - | - | - |
| `plan-10-Lantai 10.pdf` | 1 | M-110 | P | P | P | P | P | P | P | - | P | - | - | - | - |
| `plan-10-Lantai 10-detail.pdf` | 1 | M-510 | P | P | P | P | P | P | P | - | - | - | - | - | - |
| `plan-11-Lantai 11.pdf` | 1 | M-111 | P | P | P | P | P | P | P | - | P | - | - | - | - |
| `plan-11-Lantai 11-detail.pdf` | 1 | M-511 | P | P | P | P | P | P | P | - | - | - | - | - | - |
| `plan-12-Lantai 12.pdf` | 1 | M-112 | P | P | P | P | P | P | P | - | P | - | - | - | - |
| `plan-12-Lantai 12-detail.pdf` | 1 | M-512 | P | P | P | P | P | P | P | - | - | - | - | - | - |
| `elec-plan-1-Lantai 1.pdf` | 1 | E-101 | P | - | P | - | - | P | P | - | - | - | - | - | - |
| `elec-plan-6-Lantai 6.pdf` | 1 | E-102 | P | - | P | - | - | P | P | - | - | - | - | - | - |
| `elec-plan-12-Lantai 12.pdf` | 1 | E-103 | P | - | P | - | - | P | P | - | - | - | - | - | - |
| `riser-sld.pdf` | 1 | M-201 | P | P | P | P | P | - | P | P | P | - | - | - | - |
| `riser-sld.pdf` | 2 | M-201 | P | P | P | P | P | - | P | P | P | - | - | - | - |
| `riser-sld.pdf` | 3 | M-201 | P | P | P | P | P | - | P | P | P | - | - | - | - |
| `riser-sld.pdf` | 4 | M-201 | P | P | P | P | P | - | P | P | P | - | - | - | - |
| `riser-sld.pdf` | 5 | M-201 | P | P | P | P | P | - | P | P | P | - | - | - | - |
| `riser-sld.pdf` | 6 | M-201 | P | P | P | P | P | - | P | P | P | - | - | - | - |
| `riser-sld.pdf` | 7 | M-201 | P | P | P | P | P | - | P | P | P | - | - | - | - |
| `riser-sld.pdf` | 8 | M-201 | P | P | P | P | P | - | P | P | P | - | - | - | - |
| `electrical-sld.pdf` | 1 | E-201 | P | - | P | P | - | - | - | - | - | P | P | P | - |
| `electrical-sld.pdf` | 2 | E-201 | P | - | P | P | - | - | - | - | - | P | P | P | - |
| `electrical-sld.pdf` | 3 | E-201 | P | - | P | P | - | - | - | - | - | P | P | F | - |
| `electrical-sld.pdf` | 4 | E-201 | P | - | P | P | - | - | - | - | - | P | P | F | - |
| `electrical-sld.pdf` | 5 | E-201 | P | - | P | P | - | - | - | - | - | P | P | F | - |
| `electrical-sld.pdf` | 6 | E-201 | P | - | P | P | - | - | - | - | - | P | P | F | - |
| `electrical-sld.pdf` | 7 | E-201 | P | - | P | P | - | - | - | - | - | P | P | F | - |
| `electrical-sld.pdf` | 8 | E-201 | P | - | P | P | - | - | - | - | - | P | P | F | - |
| `electrical-sld.pdf` | 9 | E-201 | P | - | P | P | - | - | - | - | - | P | P | F | - |
| `electrical-sld.pdf` | 10 | E-201 | P | - | P | P | - | - | - | - | - | P | P | F | - |
| `electrical-sld.pdf` | 11 | E-201 | P | - | P | P | - | - | - | - | - | P | P | F | - |
| `electrical-sld.pdf` | 12 | E-201 | P | - | P | P | - | - | - | - | - | P | P | F | - |
| `electrical-sld.pdf` | 13 | E-201 | P | - | P | P | - | - | - | - | - | P | P | F | - |
| `electrical-sld.pdf` | 14 | E-201 | P | - | P | P | - | - | - | - | - | P | P | F | - |
| `electrical-sld.pdf` | 15 | E-201 | P | - | P | P | - | - | - | - | - | P | P | F | - |
| `electrical-overview-sld.pdf` | 1 | E-301 | P | - | P | P | - | - | - | - | - | P | P | - | P |
| `electrical-overview-sld.pdf` | 2 | E-301 | P | - | P | P | - | - | - | - | - | P | P | - | - |
| `electrical-overview-sld.pdf` | 3 | E-301 | P | - | P | P | - | - | - | - | - | P | P | - | - |
| `electrical-overview-sld.pdf` | 4 | E-301 | P | - | P | P | - | - | - | - | - | P | P | - | - |
| `electrical-riser.pdf` | 1 | E-401 | P | - | P | - | - | - | - | P | - | - | - | - | - |
| `electrical-riser.pdf` | 2 | E-401 | P | - | P | - | - | - | - | P | - | - | - | - | - |
| `electrical-riser.pdf` | 3 | E-401 | P | - | P | P | - | - | - | P | P | P | P | - | - |
| `electrical-riser.pdf` | 4 | E-401 | P | - | P | P | - | - | - | P | P | P | P | - | P |
| `electrical-power-one-line.pdf` | 1 | E-501 | P | - | P | P | - | - | - | - | - | - | P | - | P |
| `equipment-schedule.pdf` | 1 | M-601 | P | - | - | - | - | - | - | - | - | - | - | - | - |
| `equipment-schedule.pdf` | 2 | M-601 | P | - | - | - | - | - | P | - | P | - | - | P | - |
| `equipment-schedule.pdf` | 3 | M-601 | P | - | - | - | - | - | P | - | P | - | - | P | - |
| `panel-schedules.pdf` | 1 | E-601 | P | - | P | P | - | - | - | - | - | P | - | P | - |
| `panel-schedules.pdf` | 2 | E-601 | P | - | P | P | - | - | - | - | - | P | - | P | - |
| `panel-schedules.pdf` | 3 | E-601 | P | - | P | P | - | - | - | - | - | P | - | F | - |
| `panel-schedules.pdf` | 4 | E-601 | P | - | P | P | - | - | - | - | - | P | - | F | - |
| `panel-schedules.pdf` | 5 | E-601 | P | - | P | P | - | - | - | - | - | P | - | F | - |
| `panel-schedules.pdf` | 6 | E-601 | P | - | P | P | - | - | - | - | - | P | - | F | - |
| `panel-schedules.pdf` | 7 | E-601 | P | - | P | P | - | - | - | - | - | P | - | F | - |
| `panel-schedules.pdf` | 8 | E-601 | P | - | P | P | - | - | - | - | - | P | - | F | - |
| `panel-schedules.pdf` | 9 | E-601 | P | - | P | P | - | - | - | - | - | P | - | F | - |
| `panel-schedules.pdf` | 10 | E-601 | P | - | P | P | - | - | - | - | - | P | - | F | - |
| `panel-schedules.pdf` | 11 | E-601 | P | - | P | P | - | - | - | - | - | P | - | F | - |
| `panel-schedules.pdf` | 12 | E-601 | P | - | P | P | - | - | - | - | - | P | - | F | - |
| `panel-schedules.pdf` | 13 | E-601 | P | - | P | P | - | - | - | - | - | P | - | F | - |
| `panel-schedules.pdf` | 14 | E-601 | P | - | P | P | - | - | - | - | - | P | - | F | - |
| `panel-schedules.pdf` | 15 | E-601 | P | - | P | P | - | - | - | - | - | P | - | F | - |

#### tower

| file | page | dwg no | 4 | 8 | 9 | 11 | 12 | 13 | 14 | 17 | 18 | 19 | 20 | 21 | 22 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `00-cover-sheets.pdf` | 1 | G-001 | P | - | - | - | - | - | - | - | - | - | - | - | - |
| `00-cover-sheets.pdf` | 2 | G-002 | P | - | - | - | - | - | - | - | - | - | - | P | - |
| `00-cover-sheets.pdf` | 3 | G-002 | P | - | - | - | - | - | - | - | - | - | - | P | - |
| `00-cover-sheets.pdf` | 4 | G-002 | P | - | - | - | - | - | - | - | - | - | - | P | - |
| `00-cover-sheets.pdf` | 5 | G-002 | P | - | - | - | - | - | - | - | - | - | - | P | - |
| `00-cover-sheets.pdf` | 6 | G-003 | P | - | P | - | - | - | - | - | - | - | - | - | - |
| `plan-1-Lantai 1.pdf` | 1 | M-101 | P | P | P | P | P | P | P | - | P | - | - | - | - |
| `plan-1-Lantai 1-detail.pdf` | 1 | M-501 | P | P | P | P | P | P | P | - | - | - | - | - | - |
| `plan-2-Lantai 2.pdf` | 1 | M-102 | P | P | P | P | P | P | P | - | P | - | - | - | - |
| `plan-2-Lantai 2-detail.pdf` | 1 | M-502 | P | P | P | P | P | P | P | - | - | - | - | - | - |
| `plan-3-Lantai 3.pdf` | 1 | M-103 | P | P | P | P | P | P | P | - | P | - | - | - | - |
| `plan-3-Lantai 3-detail.pdf` | 1 | M-503 | P | P | P | P | P | P | P | - | - | - | - | - | - |
| `plan-4-Lantai 4.pdf` | 1 | M-104 | P | P | P | P | P | P | P | - | P | - | - | - | - |
| `plan-4-Lantai 4-detail.pdf` | 1 | M-504 | P | P | P | P | P | P | P | - | - | - | - | - | - |
| `plan-5-Lantai 5.pdf` | 1 | M-105 | P | P | P | P | P | P | P | - | P | - | - | - | - |
| `plan-5-Lantai 5-detail.pdf` | 1 | M-505 | P | P | P | P | P | P | P | - | - | - | - | - | - |
| `plan-6-Lantai 6.pdf` | 1 | M-106 | P | P | P | P | P | P | P | - | P | - | - | - | - |
| `plan-6-Lantai 6-detail.pdf` | 1 | M-506 | P | P | P | P | P | P | P | - | - | - | - | - | - |
| `plan-7-Lantai 7.pdf` | 1 | M-107 | P | P | P | P | P | P | P | - | P | - | - | - | - |
| `plan-7-Lantai 7-detail.pdf` | 1 | M-507 | P | P | P | P | P | P | P | - | - | - | - | - | - |
| `plan-8-Lantai 8.pdf` | 1 | M-108 | P | P | P | P | P | P | P | - | P | - | - | - | - |
| `plan-8-Lantai 8-detail.pdf` | 1 | M-508 | P | P | P | P | P | P | P | - | - | - | - | - | - |
| `plan-9-Lantai 9.pdf` | 1 | M-109 | P | P | P | P | P | P | P | - | P | - | - | - | - |
| `plan-9-Lantai 9-detail.pdf` | 1 | M-509 | P | P | P | P | P | P | P | - | - | - | - | - | - |
| `plan-10-Lantai 10.pdf` | 1 | M-110 | P | P | P | P | P | P | P | - | P | - | - | - | - |
| `plan-10-Lantai 10-detail.pdf` | 1 | M-510 | P | P | P | P | P | P | P | - | - | - | - | - | - |
| `plan-11-Lantai 11.pdf` | 1 | M-111 | P | P | P | P | P | P | P | - | P | - | - | - | - |
| `plan-11-Lantai 11-detail.pdf` | 1 | M-511 | P | P | P | P | P | P | P | - | - | - | - | - | - |
| `plan-12-Lantai 12.pdf` | 1 | M-112 | P | P | P | P | P | P | P | - | P | - | - | - | - |
| `plan-12-Lantai 12-detail.pdf` | 1 | M-512 | P | P | P | P | P | P | P | - | - | - | - | - | - |
| `plan-13-Lantai 13.pdf` | 1 | M-113 | P | P | P | P | P | P | P | - | P | - | - | - | - |
| `plan-13-Lantai 13-detail.pdf` | 1 | M-513 | P | P | P | P | P | P | P | - | - | - | - | - | - |
| `plan-14-Lantai 14.pdf` | 1 | M-114 | P | P | P | P | P | P | P | - | P | - | - | - | - |
| `plan-14-Lantai 14-detail.pdf` | 1 | M-514 | P | P | P | P | P | P | P | - | - | - | - | - | - |
| `plan-15-Lantai 15.pdf` | 1 | M-115 | P | P | P | P | P | P | P | - | P | - | - | - | - |
| `plan-15-Lantai 15-detail.pdf` | 1 | M-515 | P | P | P | P | P | P | P | - | - | - | - | - | - |
| `plan-16-Lantai 16.pdf` | 1 | M-116 | P | P | P | P | P | P | P | - | P | - | - | - | - |
| `plan-16-Lantai 16-detail.pdf` | 1 | M-516 | P | P | P | P | P | P | P | - | - | - | - | - | - |
| `plan-16-Lantai 16-detail-2.pdf` | 1 | M-517 | P | P | P | P | P | P | P | - | - | - | - | - | - |
| `plan-16-Lantai 16-detail-3.pdf` | 1 | M-518 | P | P | P | P | P | P | P | - | - | - | - | - | - |
| `plan-16-Lantai 16-detail-4.pdf` | 1 | M-519 | P | P | P | P | P | P | P | - | - | - | - | - | - |
| `plan-17-Lantai 17.pdf` | 1 | M-117 | P | P | P | P | P | P | P | - | P | - | - | - | - |
| `plan-17-Lantai 17-detail.pdf` | 1 | M-520 | P | P | P | P | P | P | P | - | - | - | - | - | - |
| `plan-18-Lantai 18.pdf` | 1 | M-118 | P | P | P | P | P | P | P | - | P | - | - | - | - |
| `plan-18-Lantai 18-detail.pdf` | 1 | M-521 | P | P | P | P | P | P | P | - | - | - | - | - | - |
| `plan-19-Lantai 19.pdf` | 1 | M-119 | P | P | P | P | P | P | P | - | P | - | - | - | - |
| `plan-19-Lantai 19-detail.pdf` | 1 | M-522 | P | P | P | P | P | P | P | - | - | - | - | - | - |
| `plan-20-Lantai 20.pdf` | 1 | M-120 | P | P | P | P | P | P | P | - | P | - | - | - | - |
| `plan-20-Lantai 20-detail.pdf` | 1 | M-523 | P | P | P | P | P | P | P | - | - | - | - | - | - |
| `plan-21-Lantai 21.pdf` | 1 | M-121 | P | P | P | P | P | P | P | - | P | - | - | - | - |
| `plan-21-Lantai 21-detail.pdf` | 1 | M-524 | P | P | P | P | P | P | P | - | - | - | - | - | - |
| `plan-22-Lantai 22.pdf` | 1 | M-122 | P | P | P | P | P | P | P | - | P | - | - | - | - |
| `plan-22-Lantai 22-detail.pdf` | 1 | M-525 | P | P | P | P | P | P | P | - | - | - | - | - | - |
| `plan-23-Lantai 23.pdf` | 1 | M-123 | P | P | P | P | P | P | P | - | P | - | - | - | - |
| `plan-23-Lantai 23-detail.pdf` | 1 | M-526 | P | P | P | P | P | P | P | - | - | - | - | - | - |
| `plan-24-Lantai 24.pdf` | 1 | M-124 | P | P | P | P | P | P | P | - | P | - | - | - | - |
| `plan-24-Lantai 24-detail.pdf` | 1 | M-527 | P | P | P | P | P | P | P | - | - | - | - | - | - |
| `plan-25-Lantai 25.pdf` | 1 | M-125 | P | P | P | P | P | P | P | - | P | - | - | - | - |
| `plan-25-Lantai 25-detail.pdf` | 1 | M-528 | P | P | P | P | P | P | P | - | - | - | - | - | - |
| `plan-26-Lantai 26.pdf` | 1 | M-126 | P | P | P | P | P | P | P | - | P | - | - | - | - |
| `plan-26-Lantai 26-detail.pdf` | 1 | M-529 | P | P | P | P | P | P | P | - | - | - | - | - | - |
| `plan-27-Lantai 27.pdf` | 1 | M-127 | P | P | P | P | P | P | P | - | P | - | - | - | - |
| `plan-27-Lantai 27-detail.pdf` | 1 | M-530 | P | P | P | P | P | P | P | - | - | - | - | - | - |
| `plan-28-Lantai 28.pdf` | 1 | M-128 | P | P | P | P | P | P | P | - | P | - | - | - | - |
| `plan-28-Lantai 28-detail.pdf` | 1 | M-531 | P | P | P | P | P | P | P | - | - | - | - | - | - |
| `plan-29-Lantai 29.pdf` | 1 | M-129 | P | P | P | P | P | P | P | - | P | - | - | - | - |
| `plan-29-Lantai 29-detail.pdf` | 1 | M-532 | P | P | P | P | P | P | P | - | - | - | - | - | - |
| `plan-30-Lantai 30.pdf` | 1 | M-130 | P | P | P | P | P | P | P | - | P | - | - | - | - |
| `plan-30-Lantai 30-detail.pdf` | 1 | M-533 | P | P | P | P | P | P | P | - | - | - | - | - | - |
| `plan-30-Lantai 30-detail-2.pdf` | 1 | M-534 | P | P | P | P | P | P | P | - | - | - | - | - | - |
| `plan-30-Lantai 30-detail-3.pdf` | 1 | M-535 | P | P | P | P | P | P | P | - | - | - | - | - | - |
| `plan-30-Lantai 30-detail-4.pdf` | 1 | M-536 | P | P | P | P | P | P | P | - | - | - | - | - | - |
| `plan-30-Lantai 30-detail-5.pdf` | 1 | M-537 | P | P | P | P | P | P | P | - | - | - | - | - | - |
| `plan-30-Lantai 30-detail-6.pdf` | 1 | M-538 | P | P | P | P | P | P | P | - | - | - | - | - | - |
| `elec-plan-1-Lantai 1.pdf` | 1 | E-101 | P | P | P | - | - | P | P | - | - | - | - | - | - |
| `elec-plan-16-Lantai 16.pdf` | 1 | E-102 | P | - | P | - | - | P | P | - | - | - | - | - | - |
| `elec-plan-30-Lantai 30.pdf` | 1 | E-103 | P | - | P | - | - | P | P | - | - | - | - | - | - |
| `riser-sld.pdf` | 1 | M-201 | P | P | P | P | P | - | P | P | P | - | - | - | - |
| `riser-sld.pdf` | 2 | M-201 | P | P | P | P | P | - | P | P | P | - | - | - | - |
| `riser-sld.pdf` | 3 | M-201 | P | P | P | P | P | - | P | P | P | - | - | - | - |
| `riser-sld.pdf` | 4 | M-201 | P | P | P | P | P | - | P | P | P | - | - | - | - |
| `riser-sld.pdf` | 5 | M-201 | P | P | P | P | P | - | P | P | P | - | - | - | - |
| `riser-sld.pdf` | 6 | M-201 | P | P | P | P | P | - | P | P | P | - | - | - | - |
| `riser-sld.pdf` | 7 | M-201 | P | P | P | P | P | - | P | P | P | - | - | - | - |
| `riser-sld.pdf` | 8 | M-201 | P | P | P | P | P | - | P | P | P | - | - | - | - |
| `riser-sld.pdf` | 9 | M-201 | P | P | P | P | P | - | P | P | P | - | - | - | - |
| `riser-sld.pdf` | 10 | M-201 | P | P | P | P | P | - | P | P | P | - | - | - | - |
| `riser-sld.pdf` | 11 | M-201 | P | P | P | P | P | - | P | P | P | - | - | - | - |
| `riser-sld.pdf` | 12 | M-201 | P | P | P | P | P | - | P | P | P | - | - | - | - |
| `riser-sld.pdf` | 13 | M-201 | P | P | P | P | P | - | P | P | P | - | - | - | - |
| `riser-sld.pdf` | 14 | M-201 | P | - | P | P | - | - | P | - | P | - | - | - | - |
| `electrical-sld.pdf` | 1 | E-201 | P | - | P | P | - | - | - | - | - | P | P | P | - |
| `electrical-sld.pdf` | 2 | E-201 | P | - | P | P | - | - | - | - | - | P | P | P | - |
| `electrical-sld.pdf` | 3 | E-201 | P | - | P | P | - | - | - | - | - | P | P | P | - |
| `electrical-sld.pdf` | 4 | E-201 | P | - | P | P | - | - | - | - | - | P | P | F | - |
| `electrical-sld.pdf` | 5 | E-201 | P | - | P | P | - | - | - | - | - | P | P | F | - |
| `electrical-sld.pdf` | 6 | E-201 | P | - | P | P | - | - | - | - | - | P | P | F | - |
| `electrical-sld.pdf` | 7 | E-201 | P | - | P | P | - | - | - | - | - | P | P | F | - |
| `electrical-sld.pdf` | 8 | E-201 | P | - | P | P | - | - | - | - | - | P | P | F | - |
| `electrical-sld.pdf` | 9 | E-201 | P | - | P | P | - | - | - | - | - | P | P | F | - |
| `electrical-sld.pdf` | 10 | E-201 | P | - | P | P | - | - | - | - | - | P | P | F | - |
| `electrical-sld.pdf` | 11 | E-201 | P | - | P | P | - | - | - | - | - | P | P | F | - |
| `electrical-sld.pdf` | 12 | E-201 | P | - | P | P | - | - | - | - | - | P | P | F | - |
| `electrical-sld.pdf` | 13 | E-201 | P | - | P | P | - | - | - | - | - | P | P | F | - |
| `electrical-sld.pdf` | 14 | E-201 | P | - | P | P | - | - | - | - | - | P | P | F | - |
| `electrical-sld.pdf` | 15 | E-201 | P | - | P | P | - | - | - | - | - | P | P | F | - |
| `electrical-sld.pdf` | 16 | E-201 | P | - | P | P | - | - | - | - | - | P | P | F | - |
| `electrical-sld.pdf` | 17 | E-201 | P | - | P | P | - | - | - | - | - | P | P | F | - |
| `electrical-sld.pdf` | 18 | E-201 | P | - | P | P | - | - | - | - | - | P | P | F | - |
| `electrical-sld.pdf` | 19 | E-201 | P | - | P | P | - | - | - | - | - | P | P | F | - |
| `electrical-sld.pdf` | 20 | E-201 | P | - | P | P | - | - | - | - | - | P | P | F | - |
| `electrical-sld.pdf` | 21 | E-201 | P | - | P | P | - | - | - | - | - | P | P | F | - |
| `electrical-sld.pdf` | 22 | E-201 | P | - | P | P | - | - | - | - | - | P | P | F | - |
| `electrical-sld.pdf` | 23 | E-201 | P | - | P | P | - | - | - | - | - | P | P | F | - |
| `electrical-sld.pdf` | 24 | E-201 | P | - | P | P | - | - | - | - | - | P | P | F | - |
| `electrical-sld.pdf` | 25 | E-201 | P | - | P | P | - | - | - | - | - | P | P | F | - |
| `electrical-sld.pdf` | 26 | E-201 | P | - | P | P | - | - | - | - | - | P | P | F | - |
| `electrical-sld.pdf` | 27 | E-201 | P | - | P | P | - | - | - | - | - | P | P | F | - |
| `electrical-sld.pdf` | 28 | E-201 | P | - | P | P | - | - | - | - | - | P | P | F | - |
| `electrical-sld.pdf` | 29 | E-201 | P | - | P | P | - | - | - | - | - | P | P | F | - |
| `electrical-sld.pdf` | 30 | E-201 | P | - | P | P | - | - | - | - | - | P | P | F | - |
| `electrical-sld.pdf` | 31 | E-201 | P | - | P | P | - | - | - | - | - | P | P | F | - |
| `electrical-sld.pdf` | 32 | E-201 | P | - | P | P | - | - | - | - | - | P | P | F | - |
| `electrical-sld.pdf` | 33 | E-201 | P | - | P | P | - | - | - | - | - | P | P | F | - |
| `electrical-sld.pdf` | 34 | E-201 | P | - | P | P | - | - | - | - | - | P | P | F | - |
| `electrical-overview-sld.pdf` | 1 | E-301 | P | - | P | P | - | - | - | - | - | P | P | - | P |
| `electrical-overview-sld.pdf` | 2 | E-301 | P | - | P | P | - | - | - | - | - | P | P | - | - |
| `electrical-overview-sld.pdf` | 3 | E-301 | P | - | P | P | - | - | - | - | - | P | P | - | - |
| `electrical-overview-sld.pdf` | 4 | E-301 | P | - | P | P | - | - | - | - | - | P | P | - | - |
| `electrical-overview-sld.pdf` | 5 | E-301 | P | - | P | P | - | - | - | - | - | P | P | - | - |
| `electrical-overview-sld.pdf` | 6 | E-301 | P | - | P | P | - | - | - | - | - | P | P | - | - |
| `electrical-overview-sld.pdf` | 7 | E-301 | P | - | P | P | - | - | - | - | - | P | P | - | - |
| `electrical-overview-sld.pdf` | 8 | E-301 | P | - | P | P | - | - | - | - | - | P | P | - | - |
| `electrical-overview-sld.pdf` | 9 | E-301 | P | - | P | P | - | - | - | - | - | P | P | - | - |
| `electrical-overview-sld.pdf` | 10 | E-301 | P | - | P | P | - | - | - | - | - | P | P | - | - |
| `electrical-overview-sld.pdf` | 11 | E-301 | P | - | P | P | - | - | - | - | - | P | P | - | - |
| `electrical-overview-sld.pdf` | 12 | E-301 | P | - | P | P | - | - | - | - | - | P | P | - | - |
| `electrical-overview-sld.pdf` | 13 | E-301 | P | - | P | P | - | - | - | - | - | P | P | - | - |
| `electrical-overview-sld.pdf` | 14 | E-301 | P | - | P | P | - | - | - | - | - | P | P | - | - |
| `electrical-overview-sld.pdf` | 15 | E-301 | P | - | P | P | - | - | - | - | - | P | P | - | - |
| `electrical-overview-sld.pdf` | 16 | E-301 | P | - | P | P | - | - | - | - | - | P | P | - | - |
| `electrical-overview-sld.pdf` | 17 | E-301 | P | - | P | P | - | - | - | - | - | P | P | - | - |
| `electrical-riser.pdf` | 1 | E-401 | P | - | P | P | - | - | - | P | P | P | P | - | - |
| `electrical-riser.pdf` | 2 | E-401 | P | - | P | P | - | - | - | P | P | P | P | - | - |
| `electrical-riser.pdf` | 3 | E-401 | P | - | P | P | - | - | - | P | P | P | P | - | - |
| `electrical-riser.pdf` | 4 | E-401 | P | - | P | P | - | - | - | P | P | P | P | - | P |
| `electrical-power-one-line.pdf` | 1 | E-501 | P | - | P | P | - | - | - | - | - | - | P | - | P |
| `equipment-schedule.pdf` | 1 | M-601 | P | - | - | - | - | - | - | - | - | - | - | - | - |
| `equipment-schedule.pdf` | 2 | M-601 | P | - | - | - | - | - | P | - | P | - | - | P | - |
| `equipment-schedule.pdf` | 3 | M-601 | P | - | - | - | - | - | P | - | P | - | - | P | - |
| `equipment-schedule.pdf` | 4 | M-601 | P | - | - | - | - | - | P | - | P | - | - | P | - |
| `panel-schedules.pdf` | 1 | E-601 | P | - | P | P | - | - | - | - | - | P | - | P | - |
| `panel-schedules.pdf` | 2 | E-601 | P | - | P | P | - | - | - | - | - | P | - | P | - |
| `panel-schedules.pdf` | 3 | E-601 | P | - | P | P | - | - | - | - | - | P | - | P | - |
| `panel-schedules.pdf` | 4 | E-601 | P | - | P | P | - | - | - | - | - | P | - | F | - |
| `panel-schedules.pdf` | 5 | E-601 | P | - | P | P | - | - | - | - | - | P | - | F | - |
| `panel-schedules.pdf` | 6 | E-601 | P | - | P | P | - | - | - | - | - | P | - | F | - |
| `panel-schedules.pdf` | 7 | E-601 | P | - | P | P | - | - | - | - | - | P | - | F | - |
| `panel-schedules.pdf` | 8 | E-601 | P | - | P | P | - | - | - | - | - | P | - | F | - |
| `panel-schedules.pdf` | 9 | E-601 | P | - | P | P | - | - | - | - | - | P | - | F | - |
| `panel-schedules.pdf` | 10 | E-601 | P | - | P | P | - | - | - | - | - | P | - | F | - |
| `panel-schedules.pdf` | 11 | E-601 | P | - | P | P | - | - | - | - | - | P | - | F | - |
| `panel-schedules.pdf` | 12 | E-601 | P | - | P | P | - | - | - | - | - | P | - | F | - |
| `panel-schedules.pdf` | 13 | E-601 | P | - | P | P | - | - | - | - | - | P | - | F | - |
| `panel-schedules.pdf` | 14 | E-601 | P | - | P | P | - | - | - | - | - | P | - | F | - |
| `panel-schedules.pdf` | 15 | E-601 | P | - | P | P | - | - | - | - | - | P | - | F | - |
| `panel-schedules.pdf` | 16 | E-601 | P | - | P | P | - | - | - | - | - | P | - | F | - |
| `panel-schedules.pdf` | 17 | E-601 | P | - | P | P | - | - | - | - | - | P | - | F | - |
| `panel-schedules.pdf` | 18 | E-601 | P | - | P | P | - | - | - | - | - | P | - | F | - |
| `panel-schedules.pdf` | 19 | E-601 | P | - | P | P | - | - | - | - | - | P | - | F | - |
| `panel-schedules.pdf` | 20 | E-601 | P | - | P | P | - | - | - | - | - | P | - | F | - |
| `panel-schedules.pdf` | 21 | E-601 | P | - | P | P | - | - | - | - | - | P | - | F | - |
| `panel-schedules.pdf` | 22 | E-601 | P | - | P | P | - | - | - | - | - | P | - | F | - |
| `panel-schedules.pdf` | 23 | E-601 | P | - | P | P | - | - | - | - | - | P | - | F | - |
| `panel-schedules.pdf` | 24 | E-601 | P | - | P | P | - | - | - | - | - | P | - | F | - |
| `panel-schedules.pdf` | 25 | E-601 | P | - | P | P | - | - | - | - | - | P | - | F | - |
| `panel-schedules.pdf` | 26 | E-601 | P | - | P | P | - | - | - | - | - | P | - | F | - |
| `panel-schedules.pdf` | 27 | E-601 | P | - | P | P | - | - | - | - | - | P | - | F | - |
| `panel-schedules.pdf` | 28 | E-601 | P | - | P | P | - | - | - | - | - | P | - | F | - |
| `panel-schedules.pdf` | 29 | E-601 | P | - | P | P | - | - | - | - | - | P | - | F | - |
| `panel-schedules.pdf` | 30 | E-601 | P | - | P | P | - | - | - | - | - | P | - | F | - |
| `panel-schedules.pdf` | 31 | E-601 | P | - | P | P | - | - | - | - | - | P | - | F | - |
| `panel-schedules.pdf` | 32 | E-601 | P | - | P | P | - | - | - | - | - | P | - | F | - |
| `panel-schedules.pdf` | 33 | E-601 | P | - | P | P | - | - | - | - | - | P | - | F | - |
| `panel-schedules.pdf` | 34 | E-601 | P | - | P | P | - | - | - | - | - | P | - | F | - |

### Panel-schedule arithmetic (item 21)

Columns align on every page. Phase currents R / S / T: the rows add up to the printed total on all 65 pages
within 0.2 A (rows are rounded to 0.1 A). The DAYA column against the printed "TOTAL kW":

| Page | Board | Sum of DAYA rows | Printed TOTAL | Phase check | Result |
|---|---|---|---|---|---|
| house E-601 p1 | Panel Rumah | 300+250+1200+800+2000+750+750+1500+284 = 7 834 W | 6.5 kW | 1.5+1.3+4.2+2.8+7.1+3.6+3.6+6.8+1.5 = 32.4 vs 32.5 A | kW differs |
| shophouse p1 | PP Ruko | 3 x 4 680 + 7 156 = 21 196 W | 21.2 kW | R 24.2+16.1 = 40.3; T 24.2+4.2 = 28.4 | agrees |
| shophouse p2-p4 | Panel Ruko A / B / C | 3 x 200 + 3 x 1 000 + 2 x 1 100 = 5 800 W | 4.7 kW | 3 x 1.0 + 3 x 3.5 + 2 x 5.3 = 24.1 vs 24.2 A | kW differs |
| shophouse p5 | MEP Equipment | 7 156 W | 7.2 kW | 16.1 / 16.1 / 4.2 | agrees |
| office p1 | LVMDP | 128 167 W | 128.2 kW | 216.2 / 216.2 / 212.6 | agrees |
| office p2-p5 | PP-L1..PP-L4 | 18 900 W | 16.1 kW | 5.8+6.7+16.0 = 28.5; 6.7+16.0 = 22.7 vs 22.8 A | kW differs |
| office p6 | MEP Equipment | 63 966 W | 64.0 kW | 108.0 vs 107.9 A | agrees |
| apartment p1 | LVMDP | 160 608 W | 160.6 kW | 269.4 / 269.4 / 268.8 | agrees |
| apartment p2 | PP-E | 102 768 W | 102.8 kW | 174.6 / 174.6 / 174.0 | agrees |
| apartment p3 | MEP Equipment | 173 000 W | 89.7 kW | 153.5 vs 153.4 A | kW differs (173 000 - 83 333 standby P-04 = 89 667) |
| apartment p4-p15 | PP-Lt1..PP-Lt12 | 5 900 W | 4.8 kW | 1.9+5.1 = 7.0; 4.1+4.1 = 8.2 vs 8.3; 1.9+5.1+1.4 = 8.4 | kW differs |
| tower p1 + p2 | LVMDP (W1-W16, W17-W31) | 302 847 + 30 x 18 750 = 865 347 W | 865.3 kW (on p2, for both pages) | 520.5 + 30 x 30.9 = 1 447.5 vs 1 448.1 A | agrees |
| tower p3 | PP-E | 3 x 17 045 + 2 000 + 249 711 = 302 846 W | 302.8 kW | 3 x 28.9 + 9.6 + 424.0 = 520.3 vs 520.5 A | agrees |
| tower p4 | MEP Equipment | 411+20 556+20 556+1 222+222 222+222 222+2 444+2 444+411 = 492 488 W | 249.7 kW | 0.7+34.9+2.1+377.4+4.2+4.2+0.7 = 424.2 vs 424.0 A | kW differs (minus standby P-02 20 556 and P-05 222 222 = 249 710) |
| tower p5-p34 | PP-Lt1..PP-Lt30 | 3 x 1 500 + 3 x 2 500 + 2 x 5 000 = 22 000 W | 18.8 kW | 7.2+8.4+7.6+7.6 = 30.8 vs 30.9 A | kW differs |

### FAIL list (completion pass)

| # | Building | Sheet (file, page) | Item | What is wrong | PNG |
|---|---|---|---|---|---|
| F8 | house, shophouse, office, apartment, tower | `panel-schedules.pdf` (E-601) house p1; shophouse p2-p4; office p2-p5; apartment p3-p15; tower p4-p34 - and the same table on the same pages of `electrical-sld.pdf` (E-201) | 21 | The printed "TOTAL n kW" does not equal the sum of the DAYA rows shown on the page (house 7.8 kW of rows against 6.5; tower PP-Lt 22.0 against 18.8; tower MEP 492.5 against 249.7). The rows are connected load and the total is diversified demand with standby ways excluded, but neither is labelled: no "demand" / "terpasang" wording on the total, no demand-factor column, and the standby rows (0.0 A) are not marked standby. The ampere columns do add up. | e.g. `tower/png/Menara Contoh 30-panel-schedules-p4.png`, `house/png/Rumah Contoh-panel-schedules-p1.png` |

One defect, repeated on 52 schedule pages and the 52 matching SLD pages. Every other item passes on every page.

### Observations (completion pass, not failures)

1. Apartment `riser-sld` p6 (Lantai 1): the drain line and the rainwater box run through the note "KE SALURAN
   PEMBUANGAN"; it stays readable. Tower p13 prints the same note clear.
2. "20 kV" is not printed on tower E-301 or E-501; the supply is named "PLN MV STATION" / "MV supply + MV main".
3. House E-301 and E-401 print a 7.1 kVA demand beside a PLN 4.4 kVA connection with no flag on the sheet (the
   electrical report carries the warning).
4. Tower E-401 shows Lantai 3, 2 and 1 only, with thirty floor boards drawn as typical groups on Lantai 2; five
   feeder leaders fan out of one bundle at the right edge of p3 (inside the frame, legible). Apartment E-401 p1
   and p2 remain floor-label-only pages; office E-401 places all four floor boards on Lantai 2.
5. Tower E-301 p2-p16 carry one LVMDP box and two boards each; office E-301 staggers the PP-L3 / PP-L4 feeder
   labels one under the other, apartment and tower E-301 p1 likewise for PP-E / PP-Lt1.
6. Tower M-516..M-518 are three detail sheets of one duct run and are nearly empty; tower `riser-sld` p13 is
   crowded at the fire pumps (key bubbles 15-28) and is read through the key table.
7. Equipment schedules: tanks print "capacity not set" in house, shophouse and office; shophouse M-601 p3 holds
   only the end of the footnote. Tower PP-Lt10 is 6 kA where its sister boards are 10 kA (engineering content).
8. Apartment E-301 p1 tees the genset onto the incomer without a transfer switch; E-501 draws the ATS.

## Fix round 2 (2026-11-13)

F8 (item 21, "totals add up to the rows shown") on the E-201 single-line and the E-601 panel
schedules. One shared sheet builder (`buildElectricalSld`), so the PDF, the DXF twin and the
canvas changed together. No figure was recalculated.

What changed:

- The TOTAL line now prints two labelled figures. `TERPASANG / CONNECTED n WATT` is the sum of
  the DAYA cells printed above it, to the watt. `KEBUTUHAN / DEMAND n kW / A` is the existing
  solved diversified demand. A diversified board adds `(div f)`. The undiversified worst-phase
  current now appears only on the incomer sub-line.
- Each row's KETERANGAN marks a way the solve carries at demand factor 0 as `(STANDBY)`. It prints
  any other factor below 1 as `DF 0.7`. The legend keys `TERPASANG / KEBUTUHAN` as "connected = sum
  of the DAYA rows; demand = DAYA x DF x board div, standby ways excluded". It also keys `DF` and
  `STANDBY`, each only when printed.
- A multi-page board prints its total on the last page, and that total says what it covers: tower
  LVMDP p2 `TOTAL (W1-W31, LEMBAR / SHEETS 1-2)`.
- `tool/ref_drawings_precheck.py` item 21 runs on every `electrical-sld` / `panel-schedules` page.
  Each CONNECTED total must equal the rows since the previous total within 1 W, across pages. A
  cover note must match those rows' ways and sheets. A TOTAL with no label FAILs. Result: PASS on
  all five buildings.

Examples (verbatim, pdftotext):

- House E-601 p1: `TOTAL TERPASANG / CONNECTED 7.834 WATT · KEBUTUHAN / DEMAND 6.5kW / 32.5A`.
  Rows carry `Stop kontak Lt1 DF 0.7` and `AC kamar 1 DF 0.9`.
- Office E-601 p2 (PP-L1): `TOTAL TERPASANG / CONNECTED 18.900 WATT · KEBUTUHAN / DEMAND 16.1kW / 28.5A · imbalance 21.7%`.
- Apartment E-601 p3 (MEP): `TOTAL TERPASANG / CONNECTED 173.000 WATT · KEBUTUHAN / DEMAND 89.7kW / 153.4A · imbalance 2.3%`.
  W4 reads `Pump P-04 · no-OL trip (fire) (STANDBY)`.
- Tower E-601 p2 (LVMDP): `TOTAL (W1-W31, LEMBAR / SHEETS 1-2) TERPASANG / CONNECTED 865.347 WATT · KEBUTUHAN / DEMAND 865.3kW / 1448.1A · imbalance 0.7%`.

PNGs to re-check (the TOTAL line must stay left of the R/S/T totals, and the KETERANGAN markers
must stay inside their column):

- `house/png/Rumah Contoh-panel-schedules-p1.png`
- `office/png/Kantor Contoh-panel-schedules-p2.png`
- `apartment/png/Apartemen Contoh-panel-schedules-p3.png`
- `tower/png/Menara Contoh 30-panel-schedules-p2.png`
- The same pages of `electrical-sld`.

Follow-up after the re-check: the new `TERPASANG / KEBUTUHAN` legend row ran out through the right
border of the LEGEND box on E-201 / E-601. This was the case on house p1 and apartment p3, for example.
The cause was the SLD-family legend printing each entry on one line in a fixed-width box. The fix:

- Every SLD-family legend now wraps a long entry, whatever the entry. That covers the E-201 / E-601
  schedules, the overview, the riser and power one-line sheets, and the mechanical riser sets.
  `sldLegendEntryLines` / `sldLegendLineCount` in `drawing_chrome.dart` break the entry at words to
  30 em (`kSldLegendWrapEm`). Continuation lines hang after the `KEY  -  ` lead.
- The PDF box (`_sldPageContent`) and the reserved bottom strip (`_sldTitleStripH`) grow one row per
  printed line. The strip therefore keeps the legend clear of the title block and of the supply caption
  above it, and the rows still print at 7.5 pt.
- The DXF legend uses the same wrap. Its box is as wide as 30 em at the written cap height, and it
  grows the same way.
- Pre-check item 4 (scripted part) now FAILs any text run that starts inside a LEGEND / LEGENDA box
  and ends outside it. It caught the two pages above on the earlier export.
- Test: `packages/mechx_engine/test/sld_legend_wrap_test.dart`.

## Re-check of F8 (2026-11-13, reviewer)

Re-checked at full resolution after fix round 2 and a full regeneration (scripted pre-check: zero FAIL lines on all five buildings, item 21 and the legend-in-box check active).

| Sheet re-checked | Item | Result | Evidence |
|---|---|---|---|
| house `panel-schedules` p1 (E-601) | 21 | PASS | rows 300 + 250 + 1200 + 800 + 2000 + 750 + 750 + 1500 + 284 = 7 834 W = "TERPASANG / CONNECTED 7.834 WATT"; demand 6.5 kW / 32.5 A labelled; DF 0.7 / 0.9 shown in the rows |
| apartment `panel-schedules` p3 (E-601, MEP board) | 21 | PASS | rows 3 333 + 411 + 83 333 + 83 333 + 1 222 + 684 + 684 = 173 000 W = connected; demand 89.7 kW; standby fire pump marked "(STANDBY)" with 0.0 A |
| tower `panel-schedules` p2 (E-601, LVMDP) | 21 | PASS | "TOTAL (W1-W31, LEMBAR / SHEETS 1-2)" connected 865 347 W = 30 x 18 750 + 302 847; demand 865.3 kW / 1448.1 A |
| house and tower legends (same pages) | 4 | PASS | the long TERPASANG / KEBUTUHAN entry wraps inside the LEGEND box; nothing crosses the box or the frame |

Result: the checklist passes on every page of the five sets — per-page verdicts in the completion pass above, F1–F8 fixed and re-checked.

## Second full review after the backlog streams (2026-11-13)

Reviewer pass over the REGENERATED sets (root
`/tmp/claude-0/-home-user-iSystem/4777c01d-c7ee-56ae-bfa5-90847b3f68b2/scratchpad/drawings-i/`; PNG paths below are
relative to it): house 13 pages, shophouse 27, office 32, apartment 71, tower 152 — 295 pages. Checklist
`docs/DRAFTING-CHECKLIST.md`. Items 15 and 16 are N-A (no grid, no underlay). Items 1, 2, 3, 5, 7, 23, 25 rest on
the scripted pre-check (zero FAIL) plus a sanity look; item 10 was judged with item 9 and has no failure.

### What was viewed

- **All 52 contact sheets**, one building at a time, with per-page notes: house 01-03, shophouse 01-05,
  office 01-06, apartment 01-12, tower 01-26.
- **Full-resolution pages (150 dpi A3)**:
  - house: `00-cover-sheets` p1, p2, p3; `plan-1-Lantai 1` p1; `plan-2-Lantai 2` p1; `plan-1-Lantai 1-detail` p1;
    `riser-sld` p1 (+ crop); `electrical-sld` p1; `electrical-overview-sld` p1; `electrical-riser` p1;
    `equipment-schedule` p2; `panel-schedules` p1.
  - shophouse: `00-cover-sheets` p3; `plan-1-Lantai 1` p1 (+ crop); `plan-2-Lantai 2` p1; `plan-3-Lantai 3` p1
    (+ crop); `elec-plan-1-Lantai 1` p1; `riser-sld` p1, p2, p3 (+ crops; p2 is the PLANT page);
    `electrical-sld` p1; `electrical-overview-sld` p1; `electrical-riser` p1; `equipment-schedule` p2;
    `panel-schedules` p5.
  - office: `00-cover-sheets` p3; `plan-1-Lantai 1` p1; `plan-2-Lantai 2` p1; `plan-2-Lantai 2-detail` p1;
    `riser-sld` p3 (PLANT row, + 2 crops); `elec-plan-1-Lantai 1` p1; `electrical-sld` p1;
    `electrical-overview-sld` p1; `electrical-riser` p1.
  - apartment: `00-cover-sheets` p4; `plan-12-Lantai 12` p1 (+ crop); `plan-3-Lantai 3-detail` p1 (TIPIKAL);
    `riser-sld` p6 (PLANT); `elec-plan-1-Lantai 1` p1; `electrical-sld` p1, p3; `electrical-overview-sld` p1
    (typical-board feeder table); `electrical-riser` p1, p3, p4; `electrical-power-one-line` p1.
  - tower: `00-cover-sheets` p2; `plan-16-Lantai 16` p1 (+ crop); `plan-7-Lantai 7-detail` p1 (TIPIKAL);
    `riser-sld` p13 (PLANT); `elec-plan-1-Lantai 1` p1; `electrical-sld` p1, p4; `electrical-overview-sld` p1
    (typical-board feeder table); `electrical-riser` p8; `electrical-power-one-line` p1 (+ crop);
    `panel-schedules` p2.
- **Text extraction** (`pdftotext -layout`) of every `electrical-sld`, `panel-schedules`, `00-cover-sheets`,
  `electrical-overview-sld`, `electrical-riser`, plan and detail PDF for the arithmetic and cross-checks below.

### Limits (read before relying on a PASS)

- The brief asked for one full-resolution page of each sheet type in every building. Not reached for: office
  `equipment-schedule` and `panel-schedules`; apartment cover, drawing list, `equipment-schedule`,
  `panel-schedules`, and E-201 p2 (two of the three requested E-201 pages were opened); tower cover, notes page,
  a non-typical detail sheet, `equipment-schedule`, and E-201 p2-3 / E-301 p2-7 (one page each beyond the
  LVMDP / MEP boards). These were judged from the contact sheet (readable for tabular sheets) and from the
  extracted text; a small-text overprint on them could be missed.
- The crop of shophouse `plan-1-Lantai 1` was viewed but no defect note was kept; M-101 is recorded PASS on that
  basis. Item 6 on the dense plans not opened at full size (apartment M-101..M-111, tower plans other than
  M-116) rests on the pre-check stamp test and the thumbnail.

### Arithmetic and cross-checks

1. **Panel totals (item 21) — all 61 board pages, both E-601 and E-201**, DAYA rows summed by script and
   compared with the printed TERPASANG / CONNECTED figure; every page agrees. Samples:
   house Panel Rumah 300+250+1200+800+2000+750+750+1500+284 = 7 834 W = printed 7.834; shophouse PP Ruko
   21 196 = 21.196 and MEP 7 156 = 7.156; office LVMDP 128 167 = 128.167 and MEP 63 966 = 63.966; apartment LVMDP
   102 768 + 12 x 4 820 = 160 608 = 160.608 and MEP 173 000 = 173.000 (one STANDBY way at 0.0 A); tower LVMDP
   sheet 1 586 097 + sheet 2 281 250 = 867 347 = "TOTAL (W1-W31, LEMBAR / SHEETS 1-2) 867.347", PP-E 304 846,
   MEP 494 488 (two STANDBY ways), PP-Lt boards 22 000 each.
2. **Incomer line E-601 vs E-201 (item 24)** — identical string on every one of the 61 board pages (e.g. house
   "MCB C40A/2P 6kA ... demand 32.5A"; apartment LVMDP "MCCB 315A/4P 16kA ... demand 269.4A"; tower LVMDP
   "MCCB 1600A/4P 100kA ... demand 1448.1A").
3. **Drawing list vs INDEX.md (item 23)** — same numbers, titles and order in all five sets: 12 / 14 / 19 / 32 /
   55 rows.
4. **Tower E-301 typical-board feeder tables vs LVMDP ways** — all 23 table rows equal the E-201 and E-601 way
   (cable, device, length). Samples: PP-Lt3 NYY 5x16 / MCCB 63A / 23.0 m; PP-Lt17 NYY 5x16 / MCCB 63A / 79.0 m;
   PP-Lt27 NYY 4x25+16 / MCCB 63A / 119.0 m; single board PP-Lt30 NYY 4x35+16 / 131.0 m. Apartment table: 12 of
   12 rows equal (PP-Lt3 NYY 5x4 / MCB 16A / 17.0 m).
5. **Plan vs riser (items 14 / 18)** — office CW-R1 DN50 4.0 m = 50-CW-PPR-BOOSTER 4.0 m, FH-L1 DN125 6.7 m =
   125-FH-BS 6.7 m, RW-R1 DN150 = 150-RW-PVC, D-R1 DN100 = 100-D-PVC; tower RW-L1 DN300 6.0 m = 300-RW-PVC 6.0 m,
   CW-R1 DN100 4.0 m = 100-CW-PPR-TRANSFER, D-R1 DN150 = 150-D-PVC; apartment CW-R3 DN50 and CW-R1 DN65 on M-112
   = riser tags, plant tags TK-01 20 m3 / P-01 3.0 kW / P-03, P-04 75.0 kW = M-601; shophouse and house riser
   tags and sizes read against the plans on the crops, agreeing. Level codes: every plan of every building prints
   `L<n>` equal to its floor number (script over all 51 mechanical plans).
6. **TIPIKAL detail sheets vs the plans that point to them** — tower M-502 "Lantai 2..5": bubbles on M-102..M-105
   all read LIHAT M-502; tower M-504 "Lantai 7..15, 17..19": M-107..M-115 and M-117..M-119 all read M-504, M-116
   reads M-505 / M-506; tower M-508 "Lantai 21..27": M-121..M-127; apartment M-503 "Lantai 3..7": M-103..M-107;
   apartment M-505 "Lantai 9..10": M-109, M-110. All match. Drain stack sizes on the typical sheets (tower D-R1
   DN150 / DN125 / DN100, apartment DN100 / DN75) agree with the riser for those floor ranges.
7. **Source arrangement (item 22)** — house E-301 prints "DEMAND 7.1 kVA > DECLARED 4.4 kVA - RAISE THE
   SUBSCRIBED DAYA" on a PLN 1-phase supply; shophouse PLN 33 kVA to PP Ruko with three unit boards + MEP; office
   PLN 164 kVA, no genset, MEP board carrying the fire pump; apartment PLN 197 kVA + genset 300 kVA, PP-E carrying
   lifts + MEP, ATS on E-501; tower MV 20 kV, MV panel "MV CB + relay, CT 60/5 A", transformer 1600 kVA, genset
   800 kVA, capacitor bank 250 kvar, PP-E — on E-301 p1, E-401 p8 and E-501. All match the inputs; the earlier
   F7 is fixed.

### Per-page verdicts (second review)

Legend: P = PASS, F = FAIL, - = N-A. "other" records a failure on an item without its own column.

#### house (second review)

| file | page | dwg no. | 4 | 8 | 9 | 11 | 12 | 13 | 14 | 17 | 18 | 19 | 20 | 21 | 22 | other |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 00-cover-sheets.pdf | 1 | G-001 | P | - | - | - | - | - | - | - | - | - | - | - | - |  |
| 00-cover-sheets.pdf | 2 | G-002 | P | - | - | - | - | - | - | - | - | - | - | P | - |  |
| 00-cover-sheets.pdf | 3 | G-003 | P | - | P | - | - | - | - | - | - | - | - | - | - |  |
| plan-1-Lantai 1.pdf | 1 | M-101 | P | P | P | P | P | P | P | - | P | - | - | - | - |  |
| plan-1-Lantai 1-detail.pdf | 1 | M-501 | P | P | P | P | P | P | P | - | - | - | - | - | - |  |
| plan-2-Lantai 2.pdf | 1 | M-102 | P | P | P | P | P | P | P | - | P | - | - | - | - |  |
| riser-sld.pdf | 1 | M-201 | P | P | P | P | P | - | P | P | P | - | - | - | - |  |
| electrical-sld.pdf | 1 | E-201 | P | - | P | P | - | - | - | - | - | P | P | P | - |  |
| electrical-overview-sld.pdf | 1 | E-301 | P | - | F | P | - | - | - | - | - | P | P | - | P |  |
| electrical-riser.pdf | 1 | E-401 | P | - | F | P | - | - | - | P | P | P | P | - | P |  |
| equipment-schedule.pdf | 1 | M-601 | P | - | - | - | - | - | - | - | - | - | - | - | - |  |
| equipment-schedule.pdf | 2 | M-601 | P | - | - | - | - | - | P | - | P | - | - | P | - |  |
| panel-schedules.pdf | 1 | E-601 | P | - | P | P | - | - | - | - | - | P | - | P | - |  |

#### shophouse (second review)

| file | page | dwg no. | 4 | 8 | 9 | 11 | 12 | 13 | 14 | 17 | 18 | 19 | 20 | 21 | 22 | other |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 00-cover-sheets.pdf | 1 | G-001 | P | - | - | - | - | - | - | - | - | - | - | - | - |  |
| 00-cover-sheets.pdf | 2 | G-002 | P | - | - | - | - | - | - | - | - | - | - | P | - |  |
| 00-cover-sheets.pdf | 3 | G-003 | P | - | P | - | - | - | - | - | - | - | - | - | - |  |
| plan-1-Lantai 1.pdf | 1 | M-101 | P | P | P | P | P | P | P | - | P | - | - | - | - |  |
| plan-2-Lantai 2.pdf | 1 | M-102 | P | P | P | P | P | P | P | - | P | - | - | - | - |  |
| plan-3-Lantai 3.pdf | 1 | M-103 | P | P | P | P | P | P | P | - | P | - | - | - | - | item 6 F |
| elec-plan-1-Lantai 1.pdf | 1 | E-101 | P | - | P | - | - | P | P | - | - | - | - | - | - |  |
| elec-plan-3-Lantai 3.pdf | 1 | E-102 | P | - | P | - | - | P | P | - | - | - | - | - | - |  |
| riser-sld.pdf | 1 | M-201 | P | P | P | P | P | - | P | P | P | - | - | - | - |  |
| riser-sld.pdf | 2 | M-201 | P | P | P | P | P | - | P | P | P | - | - | - | - |  |
| riser-sld.pdf | 3 | M-201 | P | P | P | P | P | - | P | P | P | - | - | - | - |  |
| riser-sld.pdf | 4 | M-201 | P | P | P | P | P | - | P | P | P | - | - | - | - |  |
| electrical-sld.pdf | 1 | E-201 | P | - | P | P | - | - | - | - | - | P | P | P | - |  |
| electrical-sld.pdf | 2 | E-201 | P | - | P | P | - | - | - | - | - | P | P | P | - |  |
| electrical-sld.pdf | 3 | E-201 | P | - | P | P | - | - | - | - | - | P | P | P | - |  |
| electrical-sld.pdf | 4 | E-201 | P | - | P | P | - | - | - | - | - | P | P | P | - |  |
| electrical-sld.pdf | 5 | E-201 | P | - | P | P | - | - | - | - | - | P | P | P | - |  |
| electrical-overview-sld.pdf | 1 | E-301 | P | - | P | P | - | - | - | - | - | P | P | - | P |  |
| electrical-riser.pdf | 1 | E-401 | P | - | P | P | - | - | - | P | P | P | P | - | P |  |
| equipment-schedule.pdf | 1 | M-601 | P | - | - | - | - | - | - | - | - | - | - | - | - |  |
| equipment-schedule.pdf | 2 | M-601 | P | - | - | - | - | - | P | - | P | - | - | P | - |  |
| equipment-schedule.pdf | 3 | M-601 | P | - | - | - | - | - | P | - | P | - | - | P | - |  |
| panel-schedules.pdf | 1 | E-601 | P | - | P | P | - | - | - | - | - | P | - | P | - |  |
| panel-schedules.pdf | 2 | E-601 | P | - | P | P | - | - | - | - | - | P | - | P | - |  |
| panel-schedules.pdf | 3 | E-601 | P | - | P | P | - | - | - | - | - | P | - | P | - |  |
| panel-schedules.pdf | 4 | E-601 | P | - | P | P | - | - | - | - | - | P | - | P | - |  |
| panel-schedules.pdf | 5 | E-601 | P | - | P | P | - | - | - | - | - | P | - | P | - |  |

#### office (second review)

| file | page | dwg no. | 4 | 8 | 9 | 11 | 12 | 13 | 14 | 17 | 18 | 19 | 20 | 21 | 22 | other |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 00-cover-sheets.pdf | 1 | G-001 | P | - | - | - | - | - | - | - | - | - | - | - | - |  |
| 00-cover-sheets.pdf | 2 | G-002 | P | - | - | - | - | - | - | - | - | - | - | P | - |  |
| 00-cover-sheets.pdf | 3 | G-003 | P | - | P | - | - | - | - | - | - | - | - | - | - |  |
| plan-1-Lantai 1.pdf | 1 | M-101 | P | P | P | P | P | P | P | - | P | - | - | - | - |  |
| plan-1-Lantai 1-detail.pdf | 1 | M-501 | P | P | P | P | P | P | P | - | - | - | - | - | - |  |
| plan-2-Lantai 2.pdf | 1 | M-102 | P | P | P | P | P | P | P | - | P | - | - | - | - |  |
| plan-2-Lantai 2-detail.pdf | 1 | M-502 | P | P | P | P | P | P | P | - | - | - | - | - | - |  |
| plan-3-Lantai 3.pdf | 1 | M-103 | P | P | P | P | P | P | P | - | P | - | - | - | - |  |
| plan-3-Lantai 3-detail.pdf | 1 | M-503 | P | P | P | P | P | P | P | - | - | - | - | - | - |  |
| plan-4-Lantai 4.pdf | 1 | M-104 | P | P | P | P | P | P | P | - | P | - | - | - | - |  |
| plan-4-Lantai 4-detail.pdf | 1 | M-504 | P | P | P | P | P | P | P | - | - | - | - | - | - |  |
| elec-plan-1-Lantai 1.pdf | 1 | E-101 | P | - | P | - | - | P | P | - | - | - | - | - | - |  |
| elec-plan-2-Lantai 2.pdf | 1 | E-102 | P | - | P | - | - | P | P | - | - | - | - | - | - |  |
| riser-sld.pdf | 1 | M-201 | P | P | P | P | P | - | P | P | P | - | - | - | - |  |
| riser-sld.pdf | 2 | M-201 | P | P | P | P | P | - | P | P | P | - | - | - | - |  |
| riser-sld.pdf | 3 | M-201 | P | P | P | P | P | - | P | P | P | - | - | - | - |  |
| electrical-sld.pdf | 1 | E-201 | P | - | P | P | - | - | - | - | - | P | P | P | - |  |
| electrical-sld.pdf | 2 | E-201 | P | - | P | P | - | - | - | - | - | P | P | P | - |  |
| electrical-sld.pdf | 3 | E-201 | P | - | P | P | - | - | - | - | - | P | P | P | - |  |
| electrical-sld.pdf | 4 | E-201 | P | - | P | P | - | - | - | - | - | P | P | P | - |  |
| electrical-sld.pdf | 5 | E-201 | P | - | P | P | - | - | - | - | - | P | P | P | - |  |
| electrical-sld.pdf | 6 | E-201 | P | - | P | P | - | - | - | - | - | P | P | P | - |  |
| electrical-overview-sld.pdf | 1 | E-301 | P | - | P | P | - | - | - | - | - | P | P | - | P |  |
| electrical-riser.pdf | 1 | E-401 | P | - | P | P | - | - | - | P | P | P | P | - | P |  |
| equipment-schedule.pdf | 1 | M-601 | P | - | - | - | - | - | - | - | - | - | - | - | - |  |
| equipment-schedule.pdf | 2 | M-601 | P | - | - | - | - | - | P | - | P | - | - | P | - |  |
| panel-schedules.pdf | 1 | E-601 | P | - | P | P | - | - | - | - | - | P | - | P | - |  |
| panel-schedules.pdf | 2 | E-601 | P | - | P | P | - | - | - | - | - | P | - | P | - |  |
| panel-schedules.pdf | 3 | E-601 | P | - | P | P | - | - | - | - | - | P | - | P | - |  |
| panel-schedules.pdf | 4 | E-601 | P | - | P | P | - | - | - | - | - | P | - | P | - |  |
| panel-schedules.pdf | 5 | E-601 | P | - | P | P | - | - | - | - | - | P | - | P | - |  |
| panel-schedules.pdf | 6 | E-601 | P | - | P | P | - | - | - | - | - | P | - | P | - |  |

#### apartment (second review)

| file | page | dwg no. | 4 | 8 | 9 | 11 | 12 | 13 | 14 | 17 | 18 | 19 | 20 | 21 | 22 | other |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 00-cover-sheets.pdf | 1 | G-001 | P | - | - | - | - | - | - | - | - | - | - | - | - |  |
| 00-cover-sheets.pdf | 2 | G-002 | P | - | - | - | - | - | - | - | - | - | - | P | - |  |
| 00-cover-sheets.pdf | 3 | G-002 | P | - | - | - | - | - | - | - | - | - | - | P | - |  |
| 00-cover-sheets.pdf | 4 | G-003 | P | - | P | - | - | - | - | - | - | - | - | - | - |  |
| plan-1-Lantai 1.pdf | 1 | M-101 | P | P | P | P | P | P | P | - | P | - | - | - | - |  |
| plan-1-Lantai 1-detail.pdf | 1 | M-501 | P | P | P | P | P | P | P | - | - | - | - | - | - |  |
| plan-2-Lantai 2.pdf | 1 | M-102 | P | P | P | P | P | P | P | - | P | - | - | - | - |  |
| plan-2-Lantai 2-detail.pdf | 1 | M-502 | P | P | P | P | P | P | P | - | - | - | - | - | - |  |
| plan-3-Lantai 3.pdf | 1 | M-103 | P | P | P | P | P | P | P | - | P | - | - | - | - |  |
| plan-3-Lantai 3-detail.pdf | 1 | M-503 | P | P | P | P | P | P | P | - | - | - | - | - | - |  |
| plan-4-Lantai 4.pdf | 1 | M-104 | P | P | P | P | P | P | P | - | P | - | - | - | - |  |
| plan-5-Lantai 5.pdf | 1 | M-105 | P | P | P | P | P | P | P | - | P | - | - | - | - |  |
| plan-6-Lantai 6.pdf | 1 | M-106 | P | P | P | P | P | P | P | - | P | - | - | - | - |  |
| plan-7-Lantai 7.pdf | 1 | M-107 | P | P | P | P | P | P | P | - | P | - | - | - | - |  |
| plan-8-Lantai 8.pdf | 1 | M-108 | P | P | P | P | P | P | P | - | P | - | - | - | - |  |
| plan-8-Lantai 8-detail.pdf | 1 | M-504 | P | P | P | P | P | P | P | - | - | - | - | - | - |  |
| plan-9-Lantai 9.pdf | 1 | M-109 | P | P | P | P | P | P | P | - | P | - | - | - | - |  |
| plan-9-Lantai 9-detail.pdf | 1 | M-505 | P | P | P | P | P | P | P | - | - | - | - | - | - |  |
| plan-10-Lantai 10.pdf | 1 | M-110 | P | P | P | P | P | P | P | - | P | - | - | - | - |  |
| plan-11-Lantai 11.pdf | 1 | M-111 | P | P | P | P | P | P | P | - | P | - | - | - | - |  |
| plan-11-Lantai 11-detail.pdf | 1 | M-506 | P | P | P | P | P | P | P | - | - | - | - | - | - |  |
| plan-12-Lantai 12.pdf | 1 | M-112 | P | P | P | P | P | P | P | - | P | - | - | - | - |  |
| plan-12-Lantai 12-detail.pdf | 1 | M-507 | P | P | P | P | P | P | P | - | - | - | - | - | - |  |
| elec-plan-1-Lantai 1.pdf | 1 | E-101 | P | - | P | - | - | P | P | - | - | - | - | - | - |  |
| elec-plan-6-Lantai 6.pdf | 1 | E-102 | P | - | P | - | - | P | P | - | - | - | - | - | - |  |
| elec-plan-12-Lantai 12.pdf | 1 | E-103 | P | - | P | - | - | P | P | - | - | - | - | - | - |  |
| riser-sld.pdf | 1 | M-201 | P | P | P | P | P | - | P | P | P | - | - | - | - |  |
| riser-sld.pdf | 2 | M-201 | P | P | P | P | P | - | P | P | P | - | - | - | - |  |
| riser-sld.pdf | 3 | M-201 | P | P | P | P | P | - | P | P | P | - | - | - | - |  |
| riser-sld.pdf | 4 | M-201 | P | P | P | P | P | - | P | P | P | - | - | - | - |  |
| riser-sld.pdf | 5 | M-201 | P | P | P | P | P | - | P | P | P | - | - | - | - |  |
| riser-sld.pdf | 6 | M-201 | P | P | P | P | P | - | P | P | P | - | - | - | - |  |
| electrical-sld.pdf | 1 | E-201 | P | - | P | P | - | - | - | - | - | P | P | P | - |  |
| electrical-sld.pdf | 2 | E-201 | P | - | P | P | - | - | - | - | - | P | P | P | - |  |
| electrical-sld.pdf | 3 | E-201 | P | - | P | P | - | - | - | - | - | P | P | P | - |  |
| electrical-sld.pdf | 4 | E-201 | P | - | P | P | - | - | - | - | - | P | P | P | - |  |
| electrical-sld.pdf | 5 | E-201 | P | - | P | P | - | - | - | - | - | P | P | P | - |  |
| electrical-sld.pdf | 6 | E-201 | P | - | P | P | - | - | - | - | - | P | P | P | - |  |
| electrical-sld.pdf | 7 | E-201 | P | - | P | P | - | - | - | - | - | P | P | P | - |  |
| electrical-sld.pdf | 8 | E-201 | P | - | P | P | - | - | - | - | - | P | P | P | - |  |
| electrical-sld.pdf | 9 | E-201 | P | - | P | P | - | - | - | - | - | P | P | P | - |  |
| electrical-sld.pdf | 10 | E-201 | P | - | P | P | - | - | - | - | - | P | P | P | - |  |
| electrical-sld.pdf | 11 | E-201 | P | - | P | P | - | - | - | - | - | P | P | P | - |  |
| electrical-sld.pdf | 12 | E-201 | P | - | P | P | - | - | - | - | - | P | P | P | - |  |
| electrical-sld.pdf | 13 | E-201 | P | - | P | P | - | - | - | - | - | P | P | P | - |  |
| electrical-sld.pdf | 14 | E-201 | P | - | P | P | - | - | - | - | - | P | P | P | - |  |
| electrical-sld.pdf | 15 | E-201 | P | - | P | P | - | - | - | - | - | P | P | P | - |  |
| electrical-overview-sld.pdf | 1 | E-301 | P | - | P | P | - | - | - | - | - | P | P | - | P |  |
| electrical-riser.pdf | 1 | E-401 | P | - | P | P | - | - | - | P | P | P | P | - | - |  |
| electrical-riser.pdf | 2 | E-401 | P | - | P | P | - | - | - | P | P | P | P | - | - |  |
| electrical-riser.pdf | 3 | E-401 | P | - | P | P | - | - | - | P | P | P | F | - | - |  |
| electrical-riser.pdf | 4 | E-401 | P | - | P | P | - | - | - | P | P | P | P | - | P |  |
| electrical-power-one-line.pdf | 1 | E-501 | P | - | P | P | - | - | - | - | - | - | P | - | P |  |
| equipment-schedule.pdf | 1 | M-601 | P | - | - | - | - | - | - | - | - | - | - | - | - |  |
| equipment-schedule.pdf | 2 | M-601 | P | - | - | - | - | - | P | - | P | - | - | P | - |  |
| equipment-schedule.pdf | 3 | M-601 | P | - | - | - | - | - | P | - | P | - | - | P | - |  |
| panel-schedules.pdf | 1 | E-601 | P | - | P | P | - | - | - | - | - | P | - | P | - |  |
| panel-schedules.pdf | 2 | E-601 | P | - | P | P | - | - | - | - | - | P | - | P | - |  |
| panel-schedules.pdf | 3 | E-601 | P | - | P | P | - | - | - | - | - | P | - | P | - |  |
| panel-schedules.pdf | 4 | E-601 | P | - | P | P | - | - | - | - | - | P | - | P | - |  |
| panel-schedules.pdf | 5 | E-601 | P | - | P | P | - | - | - | - | - | P | - | P | - |  |
| panel-schedules.pdf | 6 | E-601 | P | - | P | P | - | - | - | - | - | P | - | P | - |  |
| panel-schedules.pdf | 7 | E-601 | P | - | P | P | - | - | - | - | - | P | - | P | - |  |
| panel-schedules.pdf | 8 | E-601 | P | - | P | P | - | - | - | - | - | P | - | P | - |  |
| panel-schedules.pdf | 9 | E-601 | P | - | P | P | - | - | - | - | - | P | - | P | - |  |
| panel-schedules.pdf | 10 | E-601 | P | - | P | P | - | - | - | - | - | P | - | P | - |  |
| panel-schedules.pdf | 11 | E-601 | P | - | P | P | - | - | - | - | - | P | - | P | - |  |
| panel-schedules.pdf | 12 | E-601 | P | - | P | P | - | - | - | - | - | P | - | P | - |  |
| panel-schedules.pdf | 13 | E-601 | P | - | P | P | - | - | - | - | - | P | - | P | - |  |
| panel-schedules.pdf | 14 | E-601 | P | - | P | P | - | - | - | - | - | P | - | P | - |  |
| panel-schedules.pdf | 15 | E-601 | P | - | P | P | - | - | - | - | - | P | - | P | - |  |

#### tower (second review)

| file | page | dwg no. | 4 | 8 | 9 | 11 | 12 | 13 | 14 | 17 | 18 | 19 | 20 | 21 | 22 | other |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 00-cover-sheets.pdf | 1 | G-001 | P | - | - | - | - | - | - | - | - | - | - | - | - |  |
| 00-cover-sheets.pdf | 2 | G-002 | P | - | - | - | - | - | - | - | - | - | - | P | - |  |
| 00-cover-sheets.pdf | 3 | G-002 | P | - | - | - | - | - | - | - | - | - | - | P | - |  |
| 00-cover-sheets.pdf | 4 | G-002 | P | - | - | - | - | - | - | - | - | - | - | P | - |  |
| 00-cover-sheets.pdf | 5 | G-003 | P | - | P | - | - | - | - | - | - | - | - | - | - |  |
| plan-1-Lantai 1.pdf | 1 | M-101 | P | P | P | P | P | P | P | - | P | - | - | - | - |  |
| plan-1-Lantai 1-detail.pdf | 1 | M-501 | P | P | P | P | P | P | P | - | - | - | - | - | - |  |
| plan-2-Lantai 2.pdf | 1 | M-102 | P | P | P | P | P | P | P | - | P | - | - | - | - |  |
| plan-2-Lantai 2-detail.pdf | 1 | M-502 | P | P | P | P | P | P | P | - | - | - | - | - | - |  |
| plan-3-Lantai 3.pdf | 1 | M-103 | P | P | P | P | P | P | P | - | P | - | - | - | - |  |
| plan-4-Lantai 4.pdf | 1 | M-104 | P | P | P | P | P | P | P | - | P | - | - | - | - |  |
| plan-5-Lantai 5.pdf | 1 | M-105 | P | P | P | P | P | P | P | - | P | - | - | - | - |  |
| plan-6-Lantai 6.pdf | 1 | M-106 | P | P | P | P | P | P | P | - | P | - | - | - | - |  |
| plan-6-Lantai 6-detail.pdf | 1 | M-503 | P | P | P | P | P | P | P | - | - | - | - | - | - |  |
| plan-7-Lantai 7.pdf | 1 | M-107 | P | P | P | P | P | P | P | - | P | - | - | - | - |  |
| plan-7-Lantai 7-detail.pdf | 1 | M-504 | P | P | P | P | P | P | P | - | - | - | - | - | - |  |
| plan-8-Lantai 8.pdf | 1 | M-108 | P | P | P | P | P | P | P | - | P | - | - | - | - |  |
| plan-9-Lantai 9.pdf | 1 | M-109 | P | P | P | P | P | P | P | - | P | - | - | - | - |  |
| plan-10-Lantai 10.pdf | 1 | M-110 | P | P | P | P | P | P | P | - | P | - | - | - | - |  |
| plan-11-Lantai 11.pdf | 1 | M-111 | P | P | P | P | P | P | P | - | P | - | - | - | - |  |
| plan-12-Lantai 12.pdf | 1 | M-112 | P | P | P | P | P | P | P | - | P | - | - | - | - |  |
| plan-13-Lantai 13.pdf | 1 | M-113 | P | P | P | P | P | P | P | - | P | - | - | - | - |  |
| plan-14-Lantai 14.pdf | 1 | M-114 | P | P | P | P | P | P | P | - | P | - | - | - | - |  |
| plan-15-Lantai 15.pdf | 1 | M-115 | P | P | P | P | P | P | P | - | P | - | - | - | - |  |
| plan-16-Lantai 16.pdf | 1 | M-116 | P | P | P | P | P | P | P | - | P | - | - | - | - | item 6 F |
| plan-16-Lantai 16-detail.pdf | 1 | M-505 | P | P | P | P | P | P | P | - | - | - | - | - | - |  |
| plan-16-Lantai 16-detail-2.pdf | 1 | M-506 | P | P | P | P | P | P | P | - | - | - | - | - | - |  |
| plan-17-Lantai 17.pdf | 1 | M-117 | P | P | P | P | P | P | P | - | P | - | - | - | - |  |
| plan-18-Lantai 18.pdf | 1 | M-118 | P | P | P | P | P | P | P | - | P | - | - | - | - |  |
| plan-19-Lantai 19.pdf | 1 | M-119 | P | P | P | P | P | P | P | - | P | - | - | - | - |  |
| plan-20-Lantai 20.pdf | 1 | M-120 | P | P | P | P | P | P | P | - | P | - | - | - | - |  |
| plan-20-Lantai 20-detail.pdf | 1 | M-507 | P | P | P | P | P | P | P | - | - | - | - | - | - |  |
| plan-21-Lantai 21.pdf | 1 | M-121 | P | P | P | P | P | P | P | - | P | - | - | - | - |  |
| plan-21-Lantai 21-detail.pdf | 1 | M-508 | P | P | P | P | P | P | P | - | - | - | - | - | - |  |
| plan-22-Lantai 22.pdf | 1 | M-122 | P | P | P | P | P | P | P | - | P | - | - | - | - |  |
| plan-23-Lantai 23.pdf | 1 | M-123 | P | P | P | P | P | P | P | - | P | - | - | - | - |  |
| plan-24-Lantai 24.pdf | 1 | M-124 | P | P | P | P | P | P | P | - | P | - | - | - | - |  |
| plan-25-Lantai 25.pdf | 1 | M-125 | P | P | P | P | P | P | P | - | P | - | - | - | - |  |
| plan-26-Lantai 26.pdf | 1 | M-126 | P | P | P | P | P | P | P | - | P | - | - | - | - |  |
| plan-27-Lantai 27.pdf | 1 | M-127 | P | P | P | P | P | P | P | - | P | - | - | - | - |  |
| plan-28-Lantai 28.pdf | 1 | M-128 | P | P | P | P | P | P | P | - | P | - | - | - | - |  |
| plan-28-Lantai 28-detail.pdf | 1 | M-509 | P | P | P | P | P | P | P | - | - | - | - | - | - |  |
| plan-29-Lantai 29.pdf | 1 | M-129 | P | P | P | P | P | P | P | - | P | - | - | - | - |  |
| plan-29-Lantai 29-detail.pdf | 1 | M-510 | P | P | P | P | P | P | P | - | - | - | - | - | - |  |
| plan-30-Lantai 30.pdf | 1 | M-130 | P | P | P | P | P | P | P | - | P | - | - | - | - |  |
| plan-30-Lantai 30-detail.pdf | 1 | M-511 | P | P | P | P | P | P | P | - | - | - | - | - | - |  |
| plan-30-Lantai 30-detail-2.pdf | 1 | M-512 | P | P | P | P | P | P | P | - | - | - | - | - | - |  |
| elec-plan-1-Lantai 1.pdf | 1 | E-101 | P | - | P | - | - | P | P | - | - | - | - | - | - |  |
| elec-plan-16-Lantai 16.pdf | 1 | E-102 | P | - | P | - | - | P | P | - | - | - | - | - | - |  |
| elec-plan-30-Lantai 30.pdf | 1 | E-103 | P | - | P | - | - | P | P | - | - | - | - | - | - |  |
| riser-sld.pdf | 1 | M-201 | P | P | P | P | P | - | P | P | P | - | - | - | - |  |
| riser-sld.pdf | 2 | M-201 | P | P | P | P | P | - | P | P | P | - | - | - | - |  |
| riser-sld.pdf | 3 | M-201 | P | P | P | P | P | - | P | P | P | - | - | - | - |  |
| riser-sld.pdf | 4 | M-201 | P | P | P | P | P | - | P | P | P | - | - | - | - |  |
| riser-sld.pdf | 5 | M-201 | P | P | P | P | P | - | P | P | P | - | - | - | - |  |
| riser-sld.pdf | 6 | M-201 | P | P | P | P | P | - | P | P | P | - | - | - | - |  |
| riser-sld.pdf | 7 | M-201 | P | P | P | P | P | - | P | P | P | - | - | - | - |  |
| riser-sld.pdf | 8 | M-201 | P | P | P | P | P | - | P | P | P | - | - | - | - |  |
| riser-sld.pdf | 9 | M-201 | P | P | P | P | P | - | P | P | P | - | - | - | - |  |
| riser-sld.pdf | 10 | M-201 | P | P | P | P | P | - | P | P | P | - | - | - | - |  |
| riser-sld.pdf | 11 | M-201 | P | P | P | P | P | - | P | P | P | - | - | - | - |  |
| riser-sld.pdf | 12 | M-201 | P | P | P | P | P | - | P | P | P | - | - | - | - |  |
| riser-sld.pdf | 13 | M-201 | P | P | P | P | P | - | P | P | P | - | - | - | - |  |
| riser-sld.pdf | 14 | M-201 | P | P | P | P | P | - | P | P | P | - | - | - | - |  |
| electrical-sld.pdf | 1 | E-201 | P | - | P | P | - | - | - | - | - | P | P | P | - |  |
| electrical-sld.pdf | 2 | E-201 | P | - | P | P | - | - | - | - | - | P | P | P | - |  |
| electrical-sld.pdf | 3 | E-201 | P | - | P | P | - | - | - | - | - | P | P | P | - |  |
| electrical-sld.pdf | 4 | E-201 | P | - | P | P | - | - | - | - | - | P | P | P | - |  |
| electrical-sld.pdf | 5 | E-201 | P | - | P | P | - | - | - | - | - | P | P | P | - |  |
| electrical-sld.pdf | 6 | E-201 | P | - | P | P | - | - | - | - | - | P | P | P | - |  |
| electrical-sld.pdf | 7 | E-201 | P | - | P | P | - | - | - | - | - | P | P | P | - |  |
| electrical-sld.pdf | 8 | E-201 | P | - | P | P | - | - | - | - | - | P | P | P | - |  |
| electrical-sld.pdf | 9 | E-201 | P | - | P | P | - | - | - | - | - | P | P | P | - |  |
| electrical-sld.pdf | 10 | E-201 | P | - | P | P | - | - | - | - | - | P | P | P | - |  |
| electrical-sld.pdf | 11 | E-201 | P | - | P | P | - | - | - | - | - | P | P | P | - |  |
| electrical-sld.pdf | 12 | E-201 | P | - | P | P | - | - | - | - | - | P | P | P | - |  |
| electrical-sld.pdf | 13 | E-201 | P | - | P | P | - | - | - | - | - | P | P | P | - |  |
| electrical-sld.pdf | 14 | E-201 | P | - | P | P | - | - | - | - | - | P | P | P | - |  |
| electrical-sld.pdf | 15 | E-201 | P | - | P | P | - | - | - | - | - | P | P | P | - |  |
| electrical-sld.pdf | 16 | E-201 | P | - | P | P | - | - | - | - | - | P | P | P | - |  |
| electrical-sld.pdf | 17 | E-201 | P | - | P | P | - | - | - | - | - | P | P | P | - |  |
| electrical-sld.pdf | 18 | E-201 | P | - | P | P | - | - | - | - | - | P | P | P | - |  |
| electrical-sld.pdf | 19 | E-201 | P | - | P | P | - | - | - | - | - | P | P | P | - |  |
| electrical-sld.pdf | 20 | E-201 | P | - | P | P | - | - | - | - | - | P | P | P | - |  |
| electrical-sld.pdf | 21 | E-201 | P | - | P | P | - | - | - | - | - | P | P | P | - |  |
| electrical-sld.pdf | 22 | E-201 | P | - | P | P | - | - | - | - | - | P | P | P | - |  |
| electrical-sld.pdf | 23 | E-201 | P | - | P | P | - | - | - | - | - | P | P | P | - |  |
| electrical-sld.pdf | 24 | E-201 | P | - | P | P | - | - | - | - | - | P | P | P | - |  |
| electrical-sld.pdf | 25 | E-201 | P | - | P | P | - | - | - | - | - | P | P | P | - |  |
| electrical-sld.pdf | 26 | E-201 | P | - | P | P | - | - | - | - | - | P | P | P | - |  |
| electrical-sld.pdf | 27 | E-201 | P | - | P | P | - | - | - | - | - | P | P | P | - |  |
| electrical-sld.pdf | 28 | E-201 | P | - | P | P | - | - | - | - | - | P | P | P | - |  |
| electrical-sld.pdf | 29 | E-201 | P | - | P | P | - | - | - | - | - | P | P | P | - |  |
| electrical-sld.pdf | 30 | E-201 | P | - | P | P | - | - | - | - | - | P | P | P | - |  |
| electrical-sld.pdf | 31 | E-201 | P | - | P | P | - | - | - | - | - | P | P | P | - |  |
| electrical-sld.pdf | 32 | E-201 | P | - | P | P | - | - | - | - | - | P | P | P | - |  |
| electrical-sld.pdf | 33 | E-201 | P | - | P | P | - | - | - | - | - | P | P | P | - |  |
| electrical-sld.pdf | 34 | E-201 | P | - | P | P | - | - | - | - | - | P | P | P | - |  |
| electrical-overview-sld.pdf | 1 | E-301 | P | - | P | P | - | - | - | - | - | P | P | - | P |  |
| electrical-overview-sld.pdf | 2 | E-301 | P | - | P | P | - | - | - | - | - | P | P | - | - |  |
| electrical-overview-sld.pdf | 3 | E-301 | P | - | P | P | - | - | - | - | - | P | P | - | - |  |
| electrical-overview-sld.pdf | 4 | E-301 | P | - | P | P | - | - | - | - | - | P | P | - | - |  |
| electrical-overview-sld.pdf | 5 | E-301 | P | - | P | P | - | - | - | - | - | P | P | - | - |  |
| electrical-overview-sld.pdf | 6 | E-301 | P | - | P | P | - | - | - | - | - | P | P | - | - |  |
| electrical-overview-sld.pdf | 7 | E-301 | P | - | P | P | - | - | - | - | - | P | P | - | - |  |
| electrical-riser.pdf | 1 | E-401 | P | - | P | P | - | - | - | P | P | P | P | - | - |  |
| electrical-riser.pdf | 2 | E-401 | P | - | P | P | - | - | - | P | P | P | P | - | - |  |
| electrical-riser.pdf | 3 | E-401 | P | - | P | P | - | - | - | P | P | P | P | - | - |  |
| electrical-riser.pdf | 4 | E-401 | P | - | P | P | - | - | - | P | P | P | P | - | - |  |
| electrical-riser.pdf | 5 | E-401 | P | - | P | P | - | - | - | P | P | P | P | - | - |  |
| electrical-riser.pdf | 6 | E-401 | P | - | P | P | - | - | - | P | P | P | P | - | - |  |
| electrical-riser.pdf | 7 | E-401 | P | - | P | P | - | - | - | P | P | P | F | - | - |  |
| electrical-riser.pdf | 8 | E-401 | P | - | P | P | - | - | - | P | P | P | P | - | P |  |
| electrical-power-one-line.pdf | 1 | E-501 | P | - | P | P | - | - | - | - | - | - | P | - | P | items 6, 24 F |
| equipment-schedule.pdf | 1 | M-601 | P | - | - | - | - | - | - | - | - | - | - | - | - |  |
| equipment-schedule.pdf | 2 | M-601 | P | - | - | - | - | - | P | - | P | - | - | P | - |  |
| equipment-schedule.pdf | 3 | M-601 | P | - | - | - | - | - | P | - | P | - | - | P | - |  |
| equipment-schedule.pdf | 4 | M-601 | P | - | - | - | - | - | P | - | P | - | - | P | - |  |
| panel-schedules.pdf | 1 | E-601 | P | - | P | P | - | - | - | - | - | P | - | P | - |  |
| panel-schedules.pdf | 2 | E-601 | P | - | P | P | - | - | - | - | - | P | - | P | - |  |
| panel-schedules.pdf | 3 | E-601 | P | - | P | P | - | - | - | - | - | P | - | P | - |  |
| panel-schedules.pdf | 4 | E-601 | P | - | P | P | - | - | - | - | - | P | - | P | - |  |
| panel-schedules.pdf | 5 | E-601 | P | - | P | P | - | - | - | - | - | P | - | P | - |  |
| panel-schedules.pdf | 6 | E-601 | P | - | P | P | - | - | - | - | - | P | - | P | - |  |
| panel-schedules.pdf | 7 | E-601 | P | - | P | P | - | - | - | - | - | P | - | P | - |  |
| panel-schedules.pdf | 8 | E-601 | P | - | P | P | - | - | - | - | - | P | - | P | - |  |
| panel-schedules.pdf | 9 | E-601 | P | - | P | P | - | - | - | - | - | P | - | P | - |  |
| panel-schedules.pdf | 10 | E-601 | P | - | P | P | - | - | - | - | - | P | - | P | - |  |
| panel-schedules.pdf | 11 | E-601 | P | - | P | P | - | - | - | - | - | P | - | P | - |  |
| panel-schedules.pdf | 12 | E-601 | P | - | P | P | - | - | - | - | - | P | - | P | - |  |
| panel-schedules.pdf | 13 | E-601 | P | - | P | P | - | - | - | - | - | P | - | P | - |  |
| panel-schedules.pdf | 14 | E-601 | P | - | P | P | - | - | - | - | - | P | - | P | - |  |
| panel-schedules.pdf | 15 | E-601 | P | - | P | P | - | - | - | - | - | P | - | P | - |  |
| panel-schedules.pdf | 16 | E-601 | P | - | P | P | - | - | - | - | - | P | - | P | - |  |
| panel-schedules.pdf | 17 | E-601 | P | - | P | P | - | - | - | - | - | P | - | P | - |  |
| panel-schedules.pdf | 18 | E-601 | P | - | P | P | - | - | - | - | - | P | - | P | - |  |
| panel-schedules.pdf | 19 | E-601 | P | - | P | P | - | - | - | - | - | P | - | P | - |  |
| panel-schedules.pdf | 20 | E-601 | P | - | P | P | - | - | - | - | - | P | - | P | - |  |
| panel-schedules.pdf | 21 | E-601 | P | - | P | P | - | - | - | - | - | P | - | P | - |  |
| panel-schedules.pdf | 22 | E-601 | P | - | P | P | - | - | - | - | - | P | - | P | - |  |
| panel-schedules.pdf | 23 | E-601 | P | - | P | P | - | - | - | - | - | P | - | P | - |  |
| panel-schedules.pdf | 24 | E-601 | P | - | P | P | - | - | - | - | - | P | - | P | - |  |
| panel-schedules.pdf | 25 | E-601 | P | - | P | P | - | - | - | - | - | P | - | P | - |  |
| panel-schedules.pdf | 26 | E-601 | P | - | P | P | - | - | - | - | - | P | - | P | - |  |
| panel-schedules.pdf | 27 | E-601 | P | - | P | P | - | - | - | - | - | P | - | P | - |  |
| panel-schedules.pdf | 28 | E-601 | P | - | P | P | - | - | - | - | - | P | - | P | - |  |
| panel-schedules.pdf | 29 | E-601 | P | - | P | P | - | - | - | - | - | P | - | P | - |  |
| panel-schedules.pdf | 30 | E-601 | P | - | P | P | - | - | - | - | - | P | - | P | - |  |
| panel-schedules.pdf | 31 | E-601 | P | - | P | P | - | - | - | - | - | P | - | P | - |  |
| panel-schedules.pdf | 32 | E-601 | P | - | P | P | - | - | - | - | - | P | - | P | - |  |
| panel-schedules.pdf | 33 | E-601 | P | - | P | P | - | - | - | - | - | P | - | P | - |  |
| panel-schedules.pdf | 34 | E-601 | P | - | P | P | - | - | - | - | - | P | - | P | - |  |

### FAIL list (second review)

| # | Building | File + page | Item | What is wrong | PNG |
|---|---|---|---|---|---|
| S1 | tower | `electrical-power-one-line.pdf` p1 (E-501) | 6 | The source caption "MV supply 20 kV + MV main (MV CB + relay, CT 60/5 A)" runs into the Generator "G" symbol; its closing bracket touches the circle. | `tower/png/Menara Contoh 30-electrical-power-one-line-p1.png` |
| S2 | tower | `electrical-power-one-line.pdf` p1 (E-501) | 24 | Essential bus is printed 360.6 kVA; the same board PP-E is 358.2 kVA on E-301 p1 / p7 and E-401 p7 (304.8 kW). Two figures for one bus. (Apartment: 121 kVA vs 120.9 kVA, rounding only.) | same |
| S3 | house | `electrical-overview-sld.pdf` p1 (E-301) and `electrical-riser.pdf` p1 (E-401) | 9 | Legend lists "Essential - Essential / emergency supply" but the house has no essential board or genset; nothing of that kind is drawn (the only red item is the demand-over-declared warning). | `house/png/Rumah Contoh-electrical-overview-sld-p1.png` |
| S4 | apartment, tower | apartment `electrical-riser.pdf` p3; tower `electrical-riser.pdf` p7 (E-401) | 20 | The LVMDP to PP-E feeder is not labelled anywhere on the riser (apartment FRC 4x70+35 / MCCB 200A / 20.0 m; tower 2x(FRC 4x185+95) / MCCB 630A / 20.0 m on E-201 / E-301). The page shows only "DARI (lembar lain): LVMDP > PP-E"; every other feeder on the riser carries cable, device and length. | `apartment/png/Apartemen Contoh-electrical-riser-p3.png`, `tower/png/Menara Contoh 30-electrical-riser-p7.png` |
| S5 | tower | `plan-16-Lantai 16.pdf` p1 (M-116) | 6 | Key bubble 4 sits on the rotated label "EA-L16 300x200 / 4.7 m - CL +3.70 drop 1.70 m" (covers "1.70"), and a key bubble 2 sits on "SA-L16 600x350 / 3.0 m - CL +3.70". The pre-check passed item 6 on this sheet. | `tower/png/Menara Contoh 30-plan-16-Lantai 16-p1.png` |
| S6 | shophouse | `plan-3-Lantai 3.pdf` p1 (M-103) | 6 | Key bubbles 11 and 15 overprint the "WC" fixture labels of the units (the C is hidden). The pre-check passed item 6 on this sheet. | `shophouse/png/Ruko Contoh-plan-3-Lantai 3-p1.png` |

Earlier failures F1-F8 were all looked for again and are fixed (office E-101 label inside the frame; tower E-101
pump labels separated with a leader; no warning stamp on any sheet; shophouse pipe-key table clear of the third
unit; electrical layout legends list only "Beban / titik"; detail-sheet legends list only what the window shows;
tower E-501 carries the MV side, transformer and capacitor bank; totals labelled connected / demand).

### Observations (second review, not failures)

1. TIPIKAL detail sheets (apartment M-503, M-505; tower M-502, M-504, M-508) print the first floor's level code
   and FFL on every tag ("CW-L7", "Lantai 7 FFL +24.00") although the sheet is issued for a floor range. A note
   "tags shown for Lantai n; typical for the listed floors" would stop a reader taking L7 literally.
2. PLANT pages / rows (shophouse p2, office p3, apartment p6, tower p13) show tag and motor kW for each pump;
   flow and head are only on M-601. Several short-run labels float between the cold-water and hydrant headers
   without a leader (tower "150-FH-BS - 3.0 m", "25-FH-BS - 3.0 m", "100-CW-PPR - 1.0 m"), three or four
   "LANJUTAN DARI Lantai 1" marks are stacked without the riser tag beside each, and the "BRANCHES" fixture list
   is repeated on the plant page where no branch is drawn. Tower `riser-sld` p14 is a sheet of detail blocks only.
3. Tower E-301: pages 3, 4 and 6 hold LVMDP and two single boards each (PP-Lt18/19, PP-Lt20/21, PP-Lt29/30)
   although PP-Lt18..21 share one cable size and could join a typical node; three near-empty A3 pages remain
   (down from fifteen).
4. Apartment E-301 p1 still tees the 300 kVA genset onto the incomer above LVMDP with no transfer switch drawn;
   E-501 shows the ATS. Tower E-301 / E-401 likewise show the genset on the LV main panel without the ATS.
5. Dense plans keep bubbles that touch each other or sit on their own pipe: shophouse M-102 (bubbles 10/11 and
   15/16), apartment M-112 (bubble 3 struck through by its own cold-water run, bubbles 6/8 touching). Legible.
6. G-003 lists only FRC under KABEL / CABLES although NYY and NYM are used throughout (each E-201 page explains
   them in its own legend).
7. House, shophouse and office M-601 still print "- (*) capacity not set" as the duty of every tank; honest, but
   item 18 asks for a duty. Apartment and tower tanks carry volumes.
8. Electrical layout plans still list every panel as "belum ditempatkan" (tower: 33 panels + 245 loads) and sit at
   different scales within one set (apartment 1:100 / 1:20; tower 1:100 / 1:20).
9. Shophouse boards still print 32.7 % and 98.3 % phase imbalance; tower PP-Lt1 15 kA, PP-Lt2..5 10 kA, the rest
   6 kA. Engineering content, outside this checklist.
10. Apartment M-503 detail B: the DN15 cold-water branch and the DN75 drain branch to the WC are drawn on the same
    line (fixture geometry); both are labelled.

Result of the second review: 295 pages recorded; 6 FAIL lines on 8 pages (S1-S6); everything else PASS or N-A.

## Fix round 3 (2026-11-13)

S1-S6 of the second full review and its observations 1, 2, 3 + 4 (O1-O3), fixed in the shared pure
layer (one `SldSheet` / one plan layout per sheet, so the PDF and the DXF changed together), each with
a test in `packages/mechx_engine/test/drawing_fix_round3_test.dart` and a scripted check in
`tool/ref_drawings_precheck.py`. No sizing figure was recalculated.

| # | Root cause | Fix | Pre-check | PNG to re-check |
|---|---|---|---|---|
| S1 | E-501 printed a symbol node's sub-label on one line, whatever its width: the 50-character MV caption ran into the next column's genset. | `wrapPowerOneLineCaption` (real Helvetica widths) wraps a symbol caption to the clear width up to the next column (`_polSymCaptionW`) and a board's sub-label left of its centre drop (`_polBoxSubW`), breaking first at ` · `; the edge-label obstacles grow by the extra lines. | item 6 "power one-line captions clear of symbols and of each other": no caption run within 0.3 pt of a symbol circle it is not inside, nor overlapping another run. | `tower/png/Menara Contoh 30-electrical-power-one-line-p1.png` |
| S2 | The 'Essential bus' printed the genset SIZING basis (`gensetBackupDemandVa`: worst phase / largest machine, 360.6 kVA) where E-301 / E-401 print the essential board's solved demand (358.2 kVA). | `buildPowerOneLine(essentialDemand:)` from `essentialDemandVa`: the bus prints `demand 358.2 kVA` (the E-301 figure) and, when the basis differs, `genset basis 360.6 kVA` beside it, by name. | item 24 "E-501 essential bus = the essential board on E-301" (the red board-rating line on E-301 p1). | same |
| S3 | `_anyEssentialPrim` counted any essential-ink primitive, and the house's red 'DEMAND > DECLARED' note is a label in that ink. | The legend keys 'Essential' only for essential LINEWORK (a board box, feeder, bus); one rule for E-301 / E-401 (E-201 keys its essential boards by its own flag). | item 9 "SLD legend Essential only with essential linework drawn" on every E-301 / E-401 / E-501 page (red strokes required). | `house/png/Rumah Contoh-electrical-overview-sld-p1.png`, `house/png/Rumah Contoh-electrical-riser-p1.png` |
| S4 | A board whose same-storey feeder is cut to another sheet drew only 'DARI (lembar lain): LVMDP > PP-E'; the parent's sheet names the board only, so that feeder carried its tag nowhere. | The DARI mark prints the feeder's `_feederConnLabel` (cable · device · length, the label every drawn leg prints) under the board name, wrapped at its ` · ` in the gutter (cable on its own line). | item 20 "every riser feeder labelled": every DARI block is followed by a tag, and the set prints at least one tag per fed board. | `apartment/png/Apartemen Contoh-electrical-riser-p3.png`, `tower/png/Menara Contoh 30-electrical-riser-p7.png` (the PP-E page) |
| S5, S6 | The obstacle set was complete; the measurements were not. The placer estimated every text as chars x 0.55 em (a 'WC' is 1.67 em, not 1.1), and a key circle tested a box 15 % inside its drawn radius, so a key could sit on the C of a WC code or tangent to the descenders under a duct tag's 'drop 1.70 m'. | Plan tags, key numbers, UP/DN marks, tie figures and the key table are measured in Helvetica (`helveticaTextWidth`); a key circle keeps its full radius + 0.2 text heights (`kPlanKeyCircleClearFactor`) from every placed label / glyph box (a key without such a slot is counted, so the sheet stamps or the cluster becomes a detail). The riser key placer does the same against tags and registers its circle with that gap. A detail bubble whose corners are all taken (tower M-130, where the measured captions now meet) steps out along its corner's diagonal on a leader before the sheet counts an overprint. A latent detail-sheet bug surfaced on the apartment: a cut stub in detail A took the real id of the drain-stack node detail B owns, so the D-R / V-R tags printed nowhere; stubs now take their own ids. | item 6 "key circles clear of every text": every numbered key circle on plans, details and riser sheets is at least 0.3 pt from the printed glyph (advance x 0.12 em below .. 0.72 em above the baseline, rotated text included) of any other text. It FAILs both reviewed sheets on the `drawings-i` set. | `tower/png/Menara Contoh 30-plan-16-Lantai 16-p1.png`, `shophouse/png/Ruko Contoh-plan-3-Lantai 3-p1.png` |
| O1 | A TIPIKAL detail sheet is the canonical floor's sheet issued for a range, printed with that floor's tags and CL datum. | `planTypicalTag` prints `CW-Ln` on a typical detail sheet (riser tags unchanged) and `planTypicalDetailNotes` replaces the single-floor CL datum with `TIPIKAL: n = lantai yang tercantum / typical: n = each listed floor; CL above each floor's own FFL`. | item 14 "TIPIKAL detail sheets": no `-L<n>` tag, no `FFL +x` figure, the note present. | `tower/png/Menara Contoh 30-plan-7-Lantai 7-detail-p1.png` |
| O2 | The riser read the per-node motor only (`equipmentNodeDutiesProvider`). | `equipmentNodePumpDutiesProvider` keeps the solved `PumpDuty` beside each node's motor (the duty the schedule prints); the issued sheet's `issuedRiserEquipmentDetailsProvider` prints a pump `Q 10.8 L/s · H 122.1 m · 18.5 kW` (schedule rounding) and a tank without capacity `-` (the canvas and the BOM keep the motor-only map, so no golden moved). A run tag wider than its run is leadered to it; each LANJUTAN DARI mark names its pipe in brackets. PRV set pressures stay on the hose-valve PRVs only (a drawn PRV component carries no set pressure in the model, so none is printed). | item 18 "PLANT pages": pumps Q · H · kW, tanks a capacity, LANJUTAN DARI marks name a pipe. | `tower/png/Menara Contoh 30-riser-sld-p17.png` |
| O3 | E-301 / E-401 hung the genset on the LV bus with no transfer switch; E-301 chunk pages were cut into equal counts of entries, leaving pages of two single boards. | `serviceArrangementOf(...).transfer` (ATS / COS and the topmost essential board(s)) is the one source: E-301 / E-401 draw the switch box on the genset tie / drop, the mode line reads `Standby - ATS ke PP-E`, the legend keys ATS; E-501's ATS node takes the same label. Chunk pages are filled first-fit in board order while they print at 7 pt. | items 22 / 23: E-301 p1 draws the switch E-501 draws; no chunk page but the last holds under half the boards of the fullest spine-free page (the spine page is width-bound and filled first-fit). | `tower/png/Menara Contoh 30-electrical-overview-sld-p1.png` and its last page |

Two further defects surfaced while regenerating and were fixed in the same pass: a detail-sheet
cut stub took the real id of the apartment's drain-stack nodes, so their D-R / V-R tags printed on no
sheet (stubs now take their own ids), and the apartment M-501 detail's scale-bar figure ran out of the
sheet frame (`planDetailScaleBarLength(maxLenMm:)`: a bar too wide for its frame takes a shorter round
length; caption and figure measured in Helvetica).

Result on the regenerated set (`drawings-s`, scratchpad): the scripted pre-check prints zero FAIL lines
on all five buildings with every new check active (PASS lines: house 118, shophouse 195, office 264,
apartment 578, tower 1288). Drawing-PDF pages: house 14, shophouse 26, office 32, apartment 72, tower
160 (tower E-301 7 -> 4 pages; the tower riser grew to 18 pages as its key circles keep their clear
gap and its plant labels carry Q · H). E-501: tower `demand 358.2 kVA · genset basis 360.6 kVA` =
PP-E on E-301; apartment `demand 120.9 kVA · genset basis 121 kVA` = PP-E. PNG paths for the re-check
(relative to `drawings-s/`): `tower/png/Menara Contoh 30-electrical-power-one-line-p1.png`,
`house/png/Rumah Contoh-electrical-overview-sld-p1.png`, `apartment/png/Apartemen Contoh-electrical-riser-p3.png`,
`tower/png/Menara Contoh 30-electrical-riser-p7.png`, `tower/png/Menara Contoh 30-plan-16-Lantai 16-p1.png`,
`shophouse/png/Ruko Contoh-plan-3-Lantai 3-p1.png`, `tower/png/Menara Contoh 30-plan-7-Lantai 7-detail-p1.png`,
`tower/png/Menara Contoh 30-riser-sld-p17.png` (PLANT), `tower/png/Menara Contoh 30-electrical-overview-sld-p1.png`
and `-p4.png` (last).
