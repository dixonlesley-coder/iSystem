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
