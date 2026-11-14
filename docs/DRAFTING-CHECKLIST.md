# Drafting checklist — reference-building drawing review

Fixed acceptance checklist for step 3 of the release goal. Each exported sheet
of each reference building is rasterised and marked PASS / FAIL per item. A
sheet passes when every applicable item passes. Only failed sheets are
re-reviewed after a fix. Items are deliberately observable on paper — no
judgement about engineering content (the fixtures cover that).

## A. Sheet frame and identity (every sheet)
1. Title block present, inside the frame, nothing clipped: project name,
   drawing title, drawing number, revision, date, scale (or NTS), sheet i of n.
2. Drawing number is unique within the set and matches the drawing list.
3. Drawn / checked / approved sign-off cells present.
4. No text outside the sheet border; no element cut by the border.

## B. Legibility (every sheet)
5. Smallest printed text is at least 7 pt at the issued paper size (1.8 mm).
6. No two labels overprint each other; no label overprints a symbol or a line
   it does not belong to (a counted overlap warning on the sheet is a FAIL).
7. No garbled glyphs (`?`, tofu boxes, mojibake); units and symbols print
   correctly (Ø, ·, m2/m3 notation consistent).
8. Leaders are short, do not cross each other, and end on their element.

## C. Line work and symbols
9. Each service has a distinct, consistent line style / colour, and the legend
   on the sheet lists exactly the services and symbols drawn on that sheet.
10. Symbols are standard and consistent between plan, riser and legend
    (valves, pumps, tanks, fixtures, breakers, meters).
11. Lines meet cleanly at junctions: no gaps, no stubs overshooting, parallel
    services do not sit on top of each other.
12. Flow direction / fall is shown where it matters (gravity runs, risers,
    pump discharge); riser up/down markers match between adjacent floors.

## D. Plans
13. Scale stated and a graphic scale bar present and correct; north arrow.
14. Every run carries size (and length or level where the convention needs
    it); every piece of equipment carries its tag.
15. Gridlines / setting-out ties present when the project defines them.
16. Underlay (architectural background) prints lighter than the services.

## E. Riser / schematic diagrams
17. Floors in true order with level names and FFL elevations; every riser
    tagged once and continuous across page breaks (continuation marks match).
18. Every plant item shows its tag and duty; the diagram agrees with the
    plan (same sizes, same tags, same counts).

## F. Electrical single-line, schedules, layout
19. Every board shows name, incomer rating/poles/kA, busbar, and demand;
    every outgoing way shows device, cable, load and phase.
20. Feeders are labelled with cable and device and are traceable source to
    board without crossing a board box.
21. Schedule columns align, totals add up to the rows shown, phase columns
    R/S/T are populated consistently.
22. Source arrangement (PLN, transformer, genset, earthing) matches the
    project inputs; nothing invented that the project did not declare.

## G. Set consistency
23. Drawing list (Daftar Gambar) lists every sheet issued, in order, with
    matching numbers and titles.
24. A figure printed on two documents is the same on both (pipe size on plan
    vs riser vs BOM; breaker on schedule vs single-line vs report).
25. PDF and DXF of the same sheet show the same content.
