# Reference buildings

Five fixed buildings replace open-ended audits. Each is a pure-Dart fixture
under `packages/mechx_engine/test/reference/`. Each is run through the real
engine and through the real app providers. Every figure a reviewer derived by
hand from the rule tables is pinned as an assertion, with its arithmetic in a
comment: the tests are the spec.

Shared value class: `packages/mechx_engine/test/reference/reference_building.dart`
(`ReferenceBuilding`, `ReferenceSheet`).

## 1. House (rumah tinggal 2 lantai)

**What it is.**
- **Building:** two storeys of 3.5 m ("Lantai 1" index 0, "Lantai 2" index 1). One sheet per floor, both calibrated at 0.02 m/px.
- **Cold water:** a roof tank (RT) feeds 8 fixtures by gravity: WC, lavatory and shower on each floor, plus a kitchen sink and a hose bibb on Lantai 1. Occupancy is private.
- **Drainage:** every fixture except the hose bibb drains to a soil stack D1 → D0, which runs to an outfall.
- **Vent:** one stack vent, D1 → VTR.
- **Rainwater:** one roof drain (60 m²) feeds a leader, a downpipe and a collector.
- **Electrical:** one single-phase 220 V board, "Panel Rumah". It has 9 ways (lighting, sockets, 2 AC units, a water heater, a 0.25 kW pump) on a declared 4400 VA PLN connection with TN-C-S earthing.
- **Not included:** hot water, fire, HVAC ducts and rooms.

**Files.**
- Fixture: `packages/mechx_engine/test/reference/house.dart` (`buildHouse()`).
- Engine pins: `packages/mechx_engine/test/reference_house_test.dart`. This covers sizing, the downfeed solve, drainage, vent and rainwater, and electrical per way, panel and supply.
- App pins: `test/reference_house_app_test.dart`. This covers the downfeed verdict, the Review issues list, compliance rows, BOM metres and electrical warnings.
- Run either test with `REF_DUMP=1` to print every solved figure.

**Geometry note.** A fixture is both 1.0 / 1.5 / 2.0 m from its cold-water tee and 1.5 m from the drainage junction. To make that work, those fixtures sit where the two circles intersect, so not every run is axis-aligned. Every run length is still exact. The soil stack D1 sits 0.5 m off D0 on plan; riser lengths are elevation deltas, so this changes no number.

**Deliberate expected findings** (the house is meant to raise these):
- **Needs a booster.** The roof tank alone leaves every fixture below the SNI 49 kPa faucet floor. The critical node is WC1 at 14.74 kPa, and a booster of about +21.43 m is needed. This raises the Review WARNING `downfeed-below-target`. No pump is drawn, so no pump duty is derived.
- **Demand above the declared daya.** The diversified demand is 32.5 A (7.1 kVA), above the 4400 VA (20 A) connection. This raises `service-capacity-below-demand`; the recommended daya is 7700 VA, single-phase.
- **KS0 trap arm.** The DN40 kitchen-sink trap arm is 2.0 m, above the 1.8 m limit. This raises the advisory `drainage-length`.
- Also expected: 5 × `drainage-laid-steeper` (the DN40 / DN50 runs are laid at 1:50 against the 1:100 project fall), 1 × `drainage-cleanout` at the stack base D0, and 5 `// VERIFY` advisories.

**Fixed by its review (2026-11-13).**
- **M1:** the stack vent D1 → VTR measured 0 m. It now measures 3.8 m (`gravityRiserEndElevation`, see `docs/ENGINE-INVARIANTS.md`).
- **Shophouse F3 (2026-11-13):** the stack vent was sized on the top junction's 7 DFU (DN40). A stack vent vents the whole stack, so it now carries the 16 DFU at the stack base and sizes DN50; the vent BOM row is DN50.
- **M2:** the supply note of this all-single-phase service quoted the 3-phase "worst-phase basis (22.5 kVA)". It now states the demand, the LV limit and the 1-phase daya.

### Backlog (outside scope, not fixed)

_(empty)_

## 2. Shophouse row (ruko 3 lantai, 3 units)

**What it is.**
- **Building:** three storeys of 4.0 m ("Lantai 1/2/3", index 0/1/2), one sheet per floor at 0.02 m/px. Three identical units A / B / C, built once and replicated at a 6.0 m (300 px) x-offset with an `_A/_B/_C` id suffix.
- **Cold water (per unit):** water meter → ground tank → transfer pump → riser → roof tank (the fill line); roof tank → booster set → down-riser to a WC + lavatory on every floor and a kitchen sink on Lantai 1. Roof-tank downfeed, private occupancy.
- **Drainage / vent / rainwater (per unit):** every fixture drains to a 3-storey soil stack and an 8 m building drain; one stack vent from the top junction; one 80 m² roof drain, leader, downpipe and collector.
- **Room:** one retail room in unit A (5 × 12 m, `RoomType.retail`, the Room tool's seeded 3.7 m ceiling) with two cassette ACs.
- **Electrical:** one 3-phase 400 V service board `PP Ruko` on a declared 33 000 VA PLN connection, feeding the single-phase sub-boards `Panel Ruko A/B/C` (8 ways each) on L1 / L2 / L3. The pumps, booster sets and ACs are not added by hand: the app's MEP sync mints the "MEP Equipment" board and wires it to `PP Ruko`.

**Files.**
- Fixture: `packages/mechx_engine/test/reference/shophouse.dart` (`buildShophouse()`, `kShophouseRooms`; a room is an app annotation, so it is plain data drawn by the app test through `roomAreasProvider`).
- Engine pins: `packages/mechx_engine/test/reference_shophouse_test.dart` (cold-water sizing per edge, Hazen–Williams friction, per-unit gravity field, drainage / vent / rainwater, room cooling, sub-board ways).
- App pins: `test/reference_shophouse_app_test.dart` (delivered field, zones, transfer pump / booster duties, AC fed loads, Review findings).
- Regression tests for its review fixes: `packages/mechx_engine/test/reference_shophouse_regression_test.dart` (F2, F3) and `test/reference_shophouse_regression_test.dart` (F1, F4).
- Run either reference test with `REF_DUMP=1` to print every solved figure.

**Deliberate expected findings:** 3 × `drainage-length` (each unit's KS0 trap arm), 12 × `drainage-laid-steeper`, 3 × `drainage-cleanout`, 5 `// VERIFY` advisories. Expected absent: `non-selective` (B-1: the unit feeders grow to 10 mm² / 40 A and the MEP feeder to 5 × 6 / 32 A for the 1.6 × floor), `unfed-panel`, `unconnected-orphan`, `service-capacity-below-demand`, `downfeed-below-target`.

**Fixed by its review (2026-11-13).**
- **F1:** units B and C were solved as upfeed "extra supply components" from their ground tanks (no gravity field, RT at −146 kPa, booster sized 36.998 m). Every roof-tank component of a downfeed project is now its own downfeed system (`extraDownfeedTanksProvider`); B = C = A.
- **F2:** the meter stub WM → GT sized DN15 at 0 L/s. A root tank's mains feed now carries what the tank delivers (DN20).
- **F3:** the stack vent was sized on the top junction's 5 DFU (DN40). It now carries the stack base's 17 DFU (DN50).
- **F4:** a cassette AC in a room was flagged `unconnected-orphan`. Cassette and split-wall units need no pipe or duct and are exempt (inside a drawn room, backlog D-6).

### Backlog (outside scope, not fixed)

- **(c) Fill line sized on peak demand.** The fill line and the transfer pump are sized on the distribution's diversified peak flow, not on a tank fill rate.
- **(g) Break tanks of extra roof tanks.** An extra roof-tank component's intermediate break tanks are not split into their own zone groups (F1 records this).

### Backlog closed (2026-11-13)

- **(a) Several separately metered service entrances — backlog E-1.** A board carries an explicit, persisted `serviceEntrance` flag (Panel inspector: "Service entrance (own utility meter)", offered on an un-fed board, writes true / false). `true` = a root for the study AND the judge; `false` = no root (`unfed-panel`, load on no service); unset (old files) = the pre-E-1 behaviour (the study counts it, the judge flags every un-fed board after the first). The original three-meter row (three 1-phase 220 V unit boards, declared 23 100 VA): all true → no `unfed-panel`, per-line basis sqrt3 x 400 x 24.2 = 16 766 VA each, daya 23 000 VA 3-phase, 33.3 A >= 24.2 A → no `service-capacity-below-demand`; A true + B, C false → B and C `unfed-panel`, the study covers A alone: max(5 329.4, 24.2 x 220 = 5 324) = 5 329 VA → 5 500 VA 1-phase; all unset → the study counts all three (23 000 VA 3-phase), B and C warn (`backlog_e1_service_entrance_test.dart`). The fixture keeps its one service board; no pin moved.
- **(b) Too few / too small AC units — backlog A-4.** The Review warns `room-cooling-undersized:<room>` when the AC units a room owns give less than its cooling load: here 2 x 2.5 PK = 48 000 >= 44 400 BTU/h (no finding); one cassette would warn (44 400 > 27 000, needs 2 x 3 PK).
- **(e) Transfer pump label — closed by B-4.** TP_A/B/C are minted `MepLoadSource.transferPump` ('Transfer pump' / 'Pompa transfer'), no figure changed.
- **(f) Feeder discrimination — closed by B-1 (bounded).** An auto-sized feeder cable grows by at most two section sizes (and never past the upstream incomer) so its device reaches 1.6 × the fed incomer: unit feeders 6 mm² / 32 A → 10 mm² (Iz 50) / 40 A, one size (VD 0.65 / 0.86 / 1.08 %); MEP feeder 5 × 4 / 25 A → 5 × 6 / 32 A, one size. No `non-selective` is left.
- **(d) Water meter at ceiling level — backlog D-3.** A water meter now sits at its floor + 0.5 m (`kWaterMeterHeightM`): the stub WM → GT measures 3.0 + 0.5 = 3.5 m (was 6.7 with the 3.7 m ceiling leg); flow 0.56389 L/s and DN20 unchanged.
- **(h) Orphan exemption ignores the room — backlog D-6.** The cassette / split-wall exemption now applies only to a unit inside a drawn room (the app passes `roomUnitOwnerId`'s units to the engine judge): unit A's cassettes stay exempt; a split unit on Lantai 2 (no room) or the cassettes with the room not drawn raise `unconnected-orphan`.


## 3. Office (kantor 4 lantai)

**What it is.**
- **Building:** four storeys of 4.0 m ("Lantai 1..4", index 0..3), one sheet per floor at 0.02 m/px.
- **Cold water:** water meter → ground tank GT → UPFEED pump P1 → riser. On every floor a public toilet core: two flush-valve WCs, a urinal (`urinalFlushTank`; a flush-valve `urinalFlushValve` exists since backlog D-5, the fixture keeps the tank type) and two lavatories. Occupancy is public.
- **Drainage / vent / rainwater:** every fixture drains to a 4-storey soil stack and a 10 m building drain; one stack vent; two 150 m² roof drains, a downpipe and a collector.
- **Fire (separate network):** fire tank FT → fire pump FP. FP feeds a Class I hydrant riser with one `hydrantBox` per floor, and a sprinkler riser with six heads in a line on Lantai 4. Light hazard, K 80.
- **HVAC (Lantai 2):** one 10 × 15 m office room (Room tool, seeded 3.7 m ceiling, 6 ACH). A ducted FCU feeds four supply diffusers in a line, each stamped with ¼ of the room airflow and a 450 × 300 face; two return grilles RG2 → RG1 (600 × 600, 3.0 m apart) carry half the airflow each (backlog L-2).
- **Electrical:** one 3-phase 400 V service board `LVMDP` on a declared 164 000 VA PLN connection, feeding four 3-phase floor sub-boards `PP-L1..L4` (lighting, sockets, three 1-phase AC ways each). P1, FP and FCU1 are not added by hand: the MEP sync mints the "MEP Equipment" board and its feeder.

**Files.**
- Fixture: `packages/mechx_engine/test/reference/office.dart` (`buildOffice()`, `kOfficeRooms`, `officeRoomAir()`).
- Engine pins: `packages/mechx_engine/test/reference_office_test.dart`. This covers the flush-valve cold-water sizing, Hazen–Williams friction, the upfeed field, drainage / vent / rainwater, the fire design and index friction, the room air, and the floor sub-boards and their feeders.
- App pins: `test/reference_office_app_test.dart`. This covers the P1 duty and SNI floors, the zone table, the fire-pump rating / duty / jockey, the FCU fan static, the MEP board and feeder, LVMDP, and the Review findings.
- Regression tests for its review fixes: `packages/mechx_engine/test/reference_office_regression_test.dart` (O1) and `test/reference_office_regression_test.dart` (O2, O4).
- Run either reference test with `REF_DUMP=1` to print every solved figure.

**Deliberate expected findings.**
- `life-safety-not-essential`: there is no genset in this building.
- `standpipe-prv-hose-valves:FP:0-3` info: every hose valve's static is above 1207 kPa (1341.5..1223.8), so each is designated a pressure-regulating hose valve set to 690 kPa (backlog A-3). The churn 1353.3 kPa sets the PN16 class of the pipework downstream of FP; no `fire-system-over-pressure` (since A-3 it warns only above 2413 kPa).
- `fire-pump-protection` info.
- `fire-tank-capacity-unset:FT` info: the fire-water reserve 31.5451 L/s x 1800 s = 56 781 L (backlog A-2).
- The NFPA 20 standby-pump recommendation.
- 12 × `drainage-laid-steeper` and `drainage-cleanout` at D0.
- 5 `// VERIFY` advisories.

**Expected absent:** `service-capacity-below-demand`, `life-safety-feeder-cable`, `air-terminal-unsized`, `terminal-velocity` (backlog L-2: two return grilles drawn), `air-duct-unsized` (backlog F-4), `unfed-panel`, any `pressure-zone`, `non-selective` (B-1: floor feeders 5 × 16 / 63 A, MEP feeder FRC 70 / 200 A), `enclosure-temp-rise-exceeded` (B-1: the LVMDP estimate falls to 26.1 K).

**Fixed by its review (2026-11-13).**
- **O1:** the NFPA 20 discharge raise ran past FP's own junction onto the sprinkler branch: S0→S1 was DN125 at 31.545 L/s, then DN32 above it. The raise now stops at a two-outlet pump's junction: the sprinkler riser is DN32 at 4.714 L/s throughout (and since backlog A-5 FP→S0 itself carries 4.714 L/s on its DN125).
- **O2:** on upfeed the zone table used the legacy 255 kPa budget walk and prescribed two PRV zones. It now hangs from the solved upfeed field (`upfeedZoneDatumProvider`): one zone, no PRV.
- **O4:** the auto-wired MEP feeder carrying the fire pump was NYY, and the app flagged its own feeder. The sync now specifies it FRC (and reverts only an FRC it set).
- **O3 (closed by backlog A-1):** the sprinkler-vs-pump judge required lift + branch-base head only (25.56 m), while the rating basis' sprinkler point includes the sized index friction (58.211 m after O1). The judge now reads the rating basis' sprinkler point.

### Backlog (outside scope, not fixed)

- **(d) Mains pressure.** Mains pressure at the meter is not modelled: the delivered upfeed field reads GT 0 kPa and WM negative.

### Backlog closed (2026-11-13)

- **(h) Auto-FRC record not saved (O4) — backlog E-2.** The record is now the persisted circuit field `cableTypeAuto` (written only when true): the MEP feeder the sync made FRC saves as `cableType: FRC, cableTypeAuto: true`; reopened in a fresh app and with FP removed, the sync clears it (FRC → none), while a hand-set FRC (no record) stays. No figure changed (`reference_office_regression_test.dart` O4 group).
- **`air-duct-unsized` on auto-sized ducts — backlog F-4.** The info now means a duct with NO size (neither auto nor chosen); the five auto-sized ducts are the engine's own valid picks: 5 → 0.
- **Equipment duty — backlog F-3.** FCU1 roots the drawn system, so the Rooms inspector's one headline is the drawn duty 121.25 Pa (the 108.70 Pa room estimate is not printed beside it); a room estimate is printed only with the label "estimate (no ducts drawn)".
- **Return bank — backlog F-2.** The office return limit is min(3.0, 4.0) = 3.0 m/s for both the room sizing and the checker: the room's bank is ceil(0.925 / (0.36 x 0.8 x 3.0)) = ceil(1.07) = 2 grilles, and the drawn single 600 x 600 grille carrying 925 L/s (3.212 m/s, passed by the old 4.0 band) is now flagged `terminal-velocity` (kept as drawn — see backlog (i)).
- **(a) Duct friction basis — backlog F-1.** The room-air equipment estimate now reads the same PU (0.03 mm) roughness the drawn supply duct reads (`defaultDuctRoughnessForService`): Ø500 at 0.925 m³/s, 0.46829 → 0.44620 Pa/m, so the FCU estimate is 50 + 0.44620 x 15 x 1.3 + 30 + 20 = 108.70 Pa (was 109.13). It remains an estimate (15 m assumed run); the drawn-duct fan duty is 121.25 Pa.
- **(i) One return grille drawn — backlog L-2.** The fixture draws the room's two-grille bank RG2 → RG1 → FCU1 (600 x 600, 462.5 L/s each = 1.606 m/s <= 3.0: no `terminal-velocity`). Return chain RG2→RG1 3.0 m DN355 (0.6651 Pa/m), RG1→FCU1 2.0 m DN500 (0.4462 Pa/m): return 31.16 → 33.75 Pa, FCU static 121.25 → 123.84 Pa (40.085 + 33.754 + 50; the 122.97 Pa noted earlier read the wrong friction on DN355), air 114.55 W, 0.37 kW and MEP way 411.1 W unchanged. The whole-building riser (M-201) that then left one `WC` key unslotted now takes the S2/S3 band / pitch escalation (pages of at most 4 storeys): it places every tag clear.
- **(c) Urinal type — backlog D-5.** `urinalFlushValve` exists (UBAP 5 / 5 / 6, DFU 4, a flush-valve node: valve curve, 98.067 kPa floor, `// VERIFY`). The office keeps `urinalFlushTank` as specified, so no office figure moves.
- **(g) Branch run prints the pump's flow (O1) — backlog A-5.** FP→S0 keeps DN125 but carries the sprinkler's own 4.714 L/s (v 0.384 m/s): sprinkler index friction 37.414 → 36.947 m, sprinkler point 58.211 → 57.744 m; the pump stays on the standpipe point 98.536 m.
- **(e) Churn over-pressure — backlog A-3.** The churn 1.4 x 98.536 x 9.81 = 1353.3 kPa now sets the PN16 class of the fire pipework downstream of FP (printed on the fire results and BOM fire lines), and the four hose valves (1341.5..1223.8 kPa static) are designated pressure-regulating hose valves set to 690 kPa (info, take-off, riser tag): no warning.
- **(b) Fire tank volume — backlog A-2.** The fire-water reserve is computed (`fireTankReservesProvider`: rated flow x duration): 31.5451 L/s x 1800 s = 56 781 L. FT has no capacity, so the Review raises the info `fire-tank-capacity-unset:FT` stating it; a capacity below it would warn `fire-tank-undersized:FT`.
- **(f) Two judge heads (O3) — backlog A-1.** The sprinkler-vs-pump judge now requires the rating basis' sprinkler point (`FireSystemBasis.sprinklerPointHeadM`): 15.7 + 50/9.81 + 37.414 = 58.211 m vs the pump's 98.536 m, not short (the old lower bound read 25.560 m); 57.744 m after A-5.
- **Feeder discrimination (5 x `non-selective`) — closed by B-1 (bounded).** Floor feeders 5 x 6 / 32 A → 5 x 16 (Iz 68) / 63 A, two sizes (VD 0.15 / 0.21 / 0.28 / 0.34 %), 63 A under LVMDP's 250 A incomer; MEP feeder FRC 35 / 125 A → FRC 70 (Iz 222) / 200 A, two sizes, under 250 A.

## 4. Apartment (rumah susun 12 lantai)

**What it is.**
- **Building:** twelve storeys of 3.5 m ("Lantai 1..12", index 0..11), one sheet per floor at 0.02 m/px. The typical floor (two units, each a WC, lavatory, shower and kitchen sink) is built once and replicated.
- **Cold water:** water meter → ground tank → transfer pump → fill riser → roof tank (roof-tank downfeed, private occupancy). The top main splits into a booster set on a SIDE branch feeding floors 11-10, and a gravity riser feeding floors 9..0. A PRV station on the gravity riser feeds Lantai 1, where the app's zone table prescribes it.
- **Drainage / vent / rainwater:** two 12-storey soil stacks, a junction and an outfall; one stack vent per stack; two 200 m² roof drains and one downpipe.
- **Fire:** fire tank → duty, standby and jockey pumps in parallel (the jockey on hand-picked DN25 legs) → a Class I hydrant riser with a box per floor, and a sprinkler riser with six heads on Lantai 12.
- **HVAC:** two bedrooms on Lantai 6, one split-wall AC each.
- **Electrical:** LVMDP (PLN, declared at the app-recommended daya, plus a standby genset at the app-recommended rating). It feeds the essential board PP-E (lift, emergency lighting, and the MEP board re-fed onto it) and twelve floor boards.

**Files.**
- Fixture: `packages/mechx_engine/test/reference/apartment.dart` (`buildApartment()`, `buildApartmentNetwork(prvFloor:)`, `kApartmentRooms`).
- Engine pins: `packages/mechx_engine/test/reference_apartment_test.dart`.
- App pins: `test/reference_apartment_app_test.dart` (BEFORE / AFTER the PRV; AFTER draws the PRV with `insertComponentOnRiser`, backlog D-4).
- Regression tests (A1, A2): `test/reference_apartment_regression_test.dart`.

**Deliberate expected findings** (final state: PLN 197 000 VA, genset 300 kVA, PRV drawn):
- `standpipe-prv-hose-valves:FP:0-11` info: every hose valve's static at churn is above 1207 kPa (1705.5..1327.8), so each is designated a pressure-regulating hose valve (backlog A-3). The churn 1.4 x 125.036 = 175.051 m = 1717.2 kPa sets PN25; no `fire-system-over-pressure` since A-3 (it was raised against 1210 kPa before).
- 2 x `non-selective` (as at 3f4e78c; bounded B-1 refuses both and the message names a selective device): Feeder PP-E (200 A on FRC 4 x 70 + 35 vs the 200 A PP-E incomer — its 400 A rung would sit above LVMDP's 315 A incomer and need 185 mm², four sizes up) and Feeder to MEP (200 A vs 160 A — its 315 A rung would sit above PP-E's own 200 A incomer).
- `enclosure-temp-rise-exceeded` on PP-E (36 K > 35 K).
- Infos: `downfeed-below-target` (the gravity floors are under the 225 kPa target but above the SNI 49 kPa), `cable-raised-for-ads` (the lift, 10 mm²), 3 x `fire-pump-protection`, 72 x `drainage-laid-steeper`, 2 x `drainage-cleanout`, 12 x `phase-imbalance-inherent`, 5 `// VERIFY`.
- Before the PRV is drawn: 8 x `downfeed-over-pressure` (Lantai 1, 401.229 kPa static).

**Expected absent:** any critical or error, `combined-fire-sprinkler-governs` (since tower T2), `ads-disconnection-on-genset`, `life-safety-*`, `service-capacity-below-demand`, `pressure-zone`, `downfeed-over-pressure` (after the PRV), `unfed-panel`, `fire-tank-*` (FT 60 000 L >= 56 781 L).

**Fixed by its review (2026-11-13).**
- **A2:** `combined-fire-sprinkler-governs` was keyed on `pumpIds.first`, the jockey FJ. It is now keyed on the duty pump FP.
- **A1:** the combined pump was rated on the sprinkler point, 4.714 L/s @ 127.054 m (11 kW), a pump that cannot deliver the 31.545 L/s hydrant flow its pipes are sized for. It is now rated at the larger flow and the larger head, 31.545 L/s @ 127.054 m (75 kW; jockey 0.3155 L/s). The reviewer overruled the Round 37 "larger head at its own flow" rule (marked superseded in `docs/ENGINE-INVARIANTS.md`).

### Backlog (outside scope, not fixed)

- **(a) Jockey flow basis:** resolved by A1 (both 0.3155 L/s).
- **(h) Fill line sized on peak demand** (shophouse c) — here 180 UBAP at 4.393 L/s.

### Backlog closed (2026-11-13)

- **(f) No step-load rule — backlog E-4.** On ATS transfer the set picks up what it backs (`gensetBackupDemandW`: PP-E's lift, emergency lighting and MEP board, backup fraction 0) in ONE step: 102 768 W = 102.8 kW, judged against the allowable first step `kGensetFirstStepFraction` (0.6, `// VERIFY` ISO 8528-5 class G2) x 300 kVA x 0.8 = 0.6 x 240 = 144 kW → OK (no `genset-step-load-staged` info). Printed in the calc report's genset section; the rating is never changed. (The fire-water reserve half was closed by backlog A-2.)
- **(i) Genset rating ignores ADS on the alternator fault — closed by B-3.** An unforced set's recommendation is now the smallest ladder rating, above the running and motor-start floors, at which no auto-sized backed way fails `ads-disconnection-on-genset` after the T4 growth (governing reason `disconnection`). The final apartment set (typed 300 kVA) already holds, so no pin moved.
- **(b) Two alternator reactances — closed by B-5.** They are two different reactances of one machine and are now named as a pair in `sources.dart`: the fault level reads the sub-transient X''d 0.12 pu, the motor-start dip and start floor the transient X'd 0.15 pu (no figure changed).
- **Feeder discrimination — B-1 (bounded).** Nothing grows here: both feeders' floor rungs sit above their own boards' incomers, so the two `non-selective` stay (now naming a selective, time-delayed / category B device); no `outgoing-exceeds-incomer`.
- **(c) Hose outlet height — backlog D-1.** A hydrant box now sits at its floor + 1.2 m (`kHoseOutletHeightM`, 39.7 m on Lantai 12), the height the standpipe lift and the outlet pressures use: each box leg drops 3.2 − 1.2 = 2.0 m from the ceiling main (was 2.1), hydrant index friction 7.852 → 7.847 m (below the 15 m allowance, the pump stays 31.545 L/s @ 125.036 m).
- **(d) Sprinkler head height — backlog D-2.** A head node now sits at its floor's ceiling plane (41.7 m on Lantai 12, was 39.6 m), the datum of its run (no leg) and of the sprinkler lift: displayed elevation, static and BOM agree; no figure moves.
- **(e) Two booster heads — backlog D-7.** The drawn booster BS keeps its 22.230 m duty (floors 10-11); the Review's `downfeed-below-target` now reads 'Lantai 6 to Lantai 10 are fed by gravity and are NOT served by the drawn booster (BS): a separate booster of about +15.3 m for these floors is recommended' (EN + ID), so the +15.3 m no longer reads as a second duty for BS. No number changes.
- **(g) PRV on a riser — backlog D-4.** `insertComponentOnRiser` places an inline component on a riser at a chosen floor (two riser segments, one undo step; edge inspector 'Insert on riser'). The app tests now draw the Lantai 1 PRV with it: every zone, pressure, duty, BOM line and finding equals the spliced fixture (fingerprint test). The tower keeps its spliced fixture: drawn on the riser, its seven stations drop the splice's three 0.000 m cold-water run BOM lines (DN40 / 65 / 80), all else equal.


## 5. Tower (gedung kantor 30 lantai)

**What it is.**
- **Building:** thirty storeys of 4.0 m ("Lantai 1..30", index 0..29), one sheet per floor at 0.02 m/px. The typical floor (a public toilet core: two flush-valve WCs, a urinal, two lavatories) is built once and replicated.
- **Cold water:** water meter → 60 000 L ground tank → transfer pump TP with a mirrored parallel standby TPS (1.5 + 1.5 m legs) → fill riser → 30 000 L roof tank (roof-tank downfeed, public occupancy). The top main splits into a booster set feeding floors 29..27 and a gravity riser feeding floors 26..0, with seven PRV stations in series (above floors 19, 16, 13, 10, 7, 4, 1, as the zone table prescribes).
- **Hot water (floors 27..29):** an untyped plant heater WH fed from BR29, a hot riser to both lavatories per floor, and the recirculation the app ASSUMES (no return drawn).
- **Drainage / vent / rainwater:** one 30-storey stack, one stack vent, four 200 m² roof drains.
- **Fire:** a 120 000 L fire tank → duty / standby / jockey pumps → header FH → two Class I hydrant risers (60 boxes) and a sprinkler riser with six heads on the top floor.
- **HVAC (index 15):** an AHU office room (rectangular equal-friction ducts, eight diffusers, five return grilles — backlog F-2) and an exhausted toilet.
- **Electrical:** MV service on a declared 1600 kVA transformer, standby genset (app-recommended), 250 kvar capacitor bank, LVMDP, essential PP-E (three 15 kW lifts, emergency lighting, the MEP board re-fed onto it) and thirty floor boards. The "Feed solved MEP duties" opt-in is on (the undrawn HW recirc pump is a solved duty).

**Files.**
- Fixture: `packages/mechx_engine/test/reference/tower.dart` (`buildTower()`, `buildTowerNetwork(prvFloors:)`, `buildTowerElectrical(...)`, `kTowerRooms`).
- Smoke + dump: `packages/mechx_engine/test/reference_tower_test.dart`, `test/reference_tower_app_test.dart` (BEFORE / AFTER the PRVs; `REF_DUMP=1`).
- Regressions (T1–T4): `packages/mechx_engine/test/reference_tower_regression_test.dart`.
- Hand-value pins (pass 3): the engine groups in `reference_tower_test.dart` (flush-valve cold water, gravity field, PRVs, hot water, drainage, vent, rainwater) and the app group in `reference_tower_app_test.dart` (zones and PRVs, movers, recirculation, fire, air, floor boards, PP-E / MEP / LVMDP, transformer, genset, capacitor bank, Review findings).

**Deliberate expected findings** (final state: 1600 kVA transformer, 800 kVA genset, 250 kvar bank, seven PRVs drawn):
- 2 x `non-selective` (bounded B-1 refusals, naming a selective device): Feeder PP-E (2 x 185 mm² FRC parallel: no single-run step reaches its 1250 A floor rung) and Feeder to MEP (its 800 A rung would sit above PP-E's own 630 A incomer). B-1 cured PP-Lt1 / PP-Lt2 (5 x 10 / 50 A → 5 x 16 / 63 A, one size).
- 2 x `enclosure-temp-rise-exceeded` (LVMDP, PP-E), `service-cable-ampacity-inadequate` (the 1600 A service), `service-fault-estimate-high` (57.7 kA from the 1600 kVA / 4 % transformer).
- `fire-system-over-pressure:FP` (churn 1.4 x 210.681 = 294.954 m = 2893.5 kPa > 2413: since backlog A-3 worded as zone-split guidance; 210.686 m before backlog D-1 shortened each box leg by 0.1 m) and the info `standpipe-prv-hose-valves:FP:0-29` (every hose valve, 2882..1744 kPa static > 1207, designated pressure-regulating).
- Infos: 6 x `cable-raised-for-ads` (feeders PP-Lt28..30 — their 63 A loop needs 35 mm², three sizes above the load-sized 10 mm², past the selectivity bound — and Lift 1..3), 3 x `fire-pump-protection`, `busbar-beyond-standard-table` (LVMDP), `downfeed-below-target` (WCb26, 134.370 kPa: above the 98.067 flush-valve floor, under the 225 target), 90 x `drainage-laid-steeper`, `drainage-cleanout`, 5 `// VERIFY`.
- Before the PRVs are drawn: 100 x `downfeed-over-pressure` (floors 0..19).

**Expected absent:** any critical or error, `air-duct-unsized` / `air-terminal-unsized` / `terminal-velocity` (backlog F-2 / F-4), `cumulative-voltage-drop-exceeded`, `ads-disconnection*`, `combined-fire-sprinkler-governs`, `downfeed-over-pressure` (after the PRVs), `pressure-zone`, `life-safety-*`, `unfed-panel`, `fire-tank-*` (FT 120 000 L >= 85 172 L).

**Fixed by its review (2026-11-13).**
- **T1:** the NFPA 20 discharge raise ran past the header: FH→Ha0, FH→Hb0 and FH→S0 each printed the pump's 47.3176 L/s on DN150, and the sprinkler riser was DN150 for one storey. Past a header only an outflow carrying the full rated flow is discharge pipe: the standpipe trunks are DN100 at 31.5451 L/s and the sprinkler feed keeps its own size.
- **T2:** the velocity-sized DN32 sprinkler riser (178.7 m friction) set the combined pump at 303.5 m / 250 kW. A combined system's sprinkler feed main is now enlarged step by step (cap: the standpipe riser) until the sprinkler point is no higher than the standpipe head: DN40, pump 47.3176 L/s @ 210.686 m, 200 kW. The apartment's pump goes back to 31.545 L/s @ 125.036 m (still 75 kW).
- **T3:** auto-sized feeders were condemned by the app's own judges (`cumulative-voltage-drop-exceeded` ×78, `ads-disconnection` ×3). An auto-sized feeder cable now grows for its own ADS and for its board's cumulative drop.
- **T4:** the ADS cable growth judged the mains only (lifts `ads-disconnection-on-genset` ×3 in pass 1, Zs 0.344 > 0.341 Ω). On a genset-backed path the growth now judges both sources.

### Backlog (outside scope, not fixed)

- **(a) No water-heater component.** A heater is an untyped plant node; no provider sizes its capacity (kW, storage, recovery), and it is not an electrical load.
- **(b) Recirculation pump way only with the duty-feed opt-in.** The solved HW recirculation pump (no pump drawn) becomes an MEP way only after "Feed solved MEP duties" is switched on.
- **(e) No standpipe zoning (partly closed by backlog A-3).** The 60 hose outlets are now designated pressure-regulating hose valves and the warning says to split the single zone (2893.6 kPa > 2413), but the app still cannot model the zones themselves (a zone pump / express riser).

### Backlog closed (2026-11-13)

- **(c) Heater cold feed on the valve curve — backlog G-1.** The demand-curve branch is chosen per PIPE (flush valve downstream ⇒ valve curve, else tank curve). The heater's cold make-up 4.5 UBAP now reads 0.2250 L/s DN15 (v 1.273; was 0.3975 L/s DN20), the same draw as its hot side; every lavatory branch 1 UBAP 0.0883 → 0.0500 L/s (boosted floors' 0.75 cold share 0.0375), the urinal 2 UBAP 0.1767 → 0.1000 L/s (all DN15). Every pipe still serving a WC keeps its valve flow: booster 21.526 m, WCb26 134.370 kPa unchanged. The office's urinal / lavatory branches move the same way (UR residual +3.052 kPa, LAVa +0.619, LAVb +0.770; required head 38.539 m unchanged).
- **`air-duct-unsized` on auto-sized ducts — backlog F-4.** The info now means a duct with NO size (neither auto nor chosen): 14 → 0 (all ducts are auto-sized within their limits).
- **Genset step load — backlog E-4.** PP-E (three lifts, emergency lighting, the MEP board with FP) is picked up in one step on transfer: 302 847 W = 302.8 kW vs 0.6 x 800 kVA x 0.8 = 0.6 x 640 = 384 kW → OK, no `genset-step-load-staged`.
- **(d) No MV-side device sizing — backlog E-3.** The printed transformer's MV feeder is now rated (`mvTransformerProtection`, `serviceMvProtection`): I = 1 600 000 / (sqrt3 x 20 000) = 46.19 A; 1600 kVA is above the named 20 kV transformer-fuse table (`kMvTransformerFuseTable20kV`, `// VERIFY`: 50 kVA 6.3 A .. 1250 kVA 80 A, ~2.2 x In to ride the ~12 x In inrush — IEC 60282-1 / IEC 62271-105 selection practice), so the feeder is an MV circuit breaker with relay on the next IEC 61869-2 CT >= 1.25 x 46.19 = 57.74 A → CT 60/5 A. Printed beside the MV main on E-301 and E-501 ('MV CB + relay, CT 60/5 A') and in the calc report's supply summary. No LV figure changed.
- **(g) AHU static, two figures — backlog F-3.** The Rooms inspector, the equipment schedule and the calc report print ONE duty per room (`roomAirHeadlineProvider`): AHU1 roots the drawn supply / return system, so the Kantor headline is the drawn-duct duty 327.68 Pa (2.2 kW); the room estimate (15 m assumed run, 303.93 Pa since F-1) is no longer printed beside it, and is labelled "estimate (no ducts drawn)" only for a room no drawn system serves. The toilet's headline is EF1's drawn 38.67 Pa.
- **(f) Room return-bank face velocity — backlog F-2.** One limit per terminal kind and application (`terminalFaceVelocityMax`) for both the room sizing and the checker: office return min(3.0, 4.0) = 3.0 m/s governs. ceil(3.7 / (0.36 x 0.8 x 3.0)) = 5 return grilles; the fixture now draws RG1..RG5 (740 L/s each, 600 x 600, 2.569 m/s), return chain 500x350 / 700x450 / 900x600 / 1000x700 / 1200x700, return static 35.06 → 36.29 Pa, AHU 326.44 → 327.68 Pa (2.2 kW). The toilet's exhaust grilles (retail, 3.5 m/s) are 300 x 150 (3.426 m/s).
- **(i) Downstream-VD raise always enlarged the feeder — closed by B-2.** The cure now takes the least copper on the way's chain: the lighting ways of the upper floors go 1.5 → 2.5 mm² (Lampu C 4 mm² on Lt20 / 21) and the floor feeders end at the size their 63 A floor device needs (16 mm² on Lt1..21, 25 on Lt22..27, 35 on Lt28..30 — the ADS hold of the 63 A device; PP-Lt30 95 → 35 mm²). Lighting raised: Lampu A Lt18..21 and Lt28..30, B Lt12..30, C Lt6..30 (4 mm² on Lt20 / 21). Copper: see the table below; no `cumulative-voltage-drop-exceeded`.
- **(h) `non-selective` on auto-sized feeders — closed by B-1 (bounded)** where a two-size single-run step under the upstream incomer reaches: PP-Lt1 / PP-Lt2 grow to 5 x 16 / 63 A (VD 0.25 / 0.32 %). PP-E (parallel runs) and the MEP feeder (above PP-E's own incomer) keep the warning, which now names a selective device.

## Electrical backlog copper (2026-11-13)

Σ mm² × m × loaded cores (phase + neutral, × parallel runs; star-delta leads
2 × 3 cores) over every AUTO-sized cable of the final app solve
(`test/reference_copper.dart`, printed by each reference app test under
`REF_DUMP=1`), at 3f4e78c and after backlog B-1 (bounded) + B-2:

| Building | 3f4e78c | after B-1 + B-2 | Change | Why |
|---|---|---|---|---|
| House | 546 | 546 | 0 | one board, no feeder, no cumulative failure |
| Shophouse | 3 038 | 3 598 | +560 (+18 %) | unit feeders 6 → 10 mm² (×3), MEP feeder 4 → 6 mm² |
| Office | 7 579 | 11 539 | +3 960 (+52 %) | floor feeders 6 → 16 mm² (×4), MEP feeder FRC 35 → 70 mm² |
| Apartment | 26 011 | 26 011 | 0 | both feeder floors refused (above their own boards' incomers) |
| Tower | 580 794 | 287 745 | −293 049 (−50 %) | B-2: cumulative drops cured on the lighting ways, not the 30 floor feeders |

## Drawing review (2026-11-13)

The five drawing sets were exported (`test/reference_drawing_set_export_test.dart`,
`REF_EXPORT=1`) and checked against `docs/DRAFTING-CHECKLIST.md` with
`tool/ref_drawings_precheck.py` plus a visual pass on the PNGs. Fixes D1-D7 are in
the §15 log; this is the per-sheet-type result (all five buildings).

| Sheet type | Before | After |
|---|---|---|
| Front matter (cover / Daftar Gambar / notes + legend) | FAIL 1, 23 (no DWG NO); tower list printed at 6.8 pt | PASS — G-001..G-003, listed first; a long register continues on extra G-002 pages |
| Mechanical plan (M-1xx) | FAIL 6, 8, 11 (fan of rotated labels, long crossing leaders, "N label bertumpuk" on 51 sheets); FAIL 25 (`-` for `·`, scale row) | PASS 6 on every plan of the five buildings (R1): dense groups are boxed with a dashed DETAIL boundary + `DETAIL A - LIHAT M-5nn` bubble and labelled on the detail sheet; PASS 25 |
| Mechanical detail (M-5xx, R1/S1) | — (new) | 55 sheets (house 1, office 4, apartment 12, tower 38): 1:20 / 1:25 / 1:50 (one tower L16 piece 1:100), own scale text + bar per detail, AS SHOWN, listed; PASS 1/2/3/5/23/25; PASS 6 on every detail sheet (S1: tower L16 over 4 sheets, L30 over 6, split pieces joined by MATCH LINEs) |
| Mechanical riser SLD (M-201) | FAIL 5 (5.2-6.1 pt), 6, 8 on every building; FAIL 25 | PASS 5 everywhere (R2: exact 7 pt floor); PASS 25; item 6 PASS on house, shophouse, office, tower and every typical page (S2: crowded floors alone on a page, taller lone-floor band, key rows; S3: wider fan-out / lane pitch on a lone floor that still overprints - shophouse ground cured, its riser now 2 pages); apartment ground floor cured by S4 (its fixture columns split over two pages, Lantai 1 - BAGIAN 1/2 and 2/2: 4 -> 1 -> 0) - item 6 PASS on all five buildings |
| Electrical SLD (E-201) | PASS visual; FAIL 25 (DXF one sheet "1 of 1") | PASS (paginated DXF twin) |
| Building single-line (E-301) | PASS visual; FAIL 25 | PASS |
| Electrical riser (E-401) | PASS visual; FAIL 25 (DXF whole sheet: FFL / feeder strings) | PASS |
| Power one-line (E-501) | FAIL 25 (PROJECT / TITLE) | PASS |
| Equipment schedule | FAIL 1, 3, 23 (no title block, no number, not listed) | PASS — M-601, drawing title block on every page, listed |
| Panel schedules | FAIL 2 (reused E-201 + SLD title); apartment / tower refused (zero-length guard) | PASS — E-601 `JADWAL PANEL / PANEL SCHEDULES`, issued in the package and listed; all five export |

Fix round F1-F7 (reviewer's FAIL list, `docs/DRAWING-REVIEW-RECORD.md`): electrical
layout plans (E-10n) place every load / panel tag inside the frame, clear of the title
block and of each other (co-located loads stack, leadered; an unplaceable tag is
counted in the stamped overlap warning) and list only the legend rows they draw
(F1, F2, F5); the legibility stamp fires only below the printed 7 pt (F3); the pipe-key
table keeps one text height of clear paper (F4); a detail sheet keys only its windows'
services and symbols (F6); the power one-line draws the declared MV supply + MV main,
rated transformer and capacitor bank from the same arrangement E-301 draws (F7). The
pre-check now FAILs a stamped legibility warning (item 5) and a pipe-key table touched
by drawing text (item 6).

Fix round 2 (F8, checklist item 21): the E-201 / E-601 board table's TOTAL line prints
`TERPASANG / CONNECTED` (the sum of the DAYA rows, to the watt) beside `KEBUTUHAN /
DEMAND` (the solved diversified figure); standby ways print `(STANDBY)` and any other
demand factor below 1 prints `DF 0.7`, keyed in the legend, so the demand is reproducible
from the rows; a multi-page board's total names its ways + sheets (tower LVMDP: `TOTAL
(W1-W31, LEMBAR / SHEETS 1-2)`). Pre-check item 21 sums the rows each total covers and
PASSes on every E-201 / E-601 page of the five buildings (house 7 834 W, office PP-L1
18 900 W, apartment MEP 173 000 W, tower LVMDP 865 347 W).

### Backlog (not cured in this pass)
- Standalone (single-plan) plan export (`exportAnnotatedPlanPdf`) issues no
  detail sheet; it keeps the honest overlap stamp. Only the submittal package
  issues detail sheets.
- Standalone (non-package) riser / electrical DXF exports still write one sheet;
  only the submittal package issues the paginated DXF twins.

### Backlog closed (2026-11-13)
- L-1 Plan PDF and DXF from one placement: tower `plan-16-Lantai 16` stamped
  '1 label bertumpuk' in the DXF only (item 25). The DXF now lays its tags out in
  the PDF's page frame and maps them to model mm (`PlanPageFrame`,
  `mapPlanAnnotations`): the sheet stamps on neither.
- L-2 Short riser pages escalate too: a riser page of at most 4 storeys (the office's
  whole-building M-201) whose keys still overprint takes the S2/S3 band / pitch
  escalation lone-floor pages already had; the office then draws its two return
  grilles with every tag clear.
- C-1 Level code in tags matches the floor's own name: `floorLocatorToken` reads
  'Lantai N' ⇒ `LN`, 'Basement N' ⇒ `BN`, 'Dasar' / 'Ground' ⇒ `GF`, 'Atap' / 'Roof'
  ⇒ `RF` (index rule for any other name); tower Lantai 30 prints `SP-L30`, Lantai 1
  plans `CW-L1`. Pre-check item 14 checks every `plan-N-Lantai N` sheet.
- C-2 Electrical riser boards on their own floors: a board carries an optional
  `floorIndex` (Panel inspector 'Riser floor'); the fixtures put PP-Lt N / PP-L N on
  Lantai N and the main / essential / MEP boards on Lantai 1. The riser issues only the
  storeys between its lowest and highest board, listing any storey left off in the edge
  band's gutter ('TANPA PANEL, DI ATAS: ...') - no label-only page.
- C-3 Building single-line density: identical sibling leaf boards (same incomer and
  ways) ride one `<first>..<last> (TIPIKAL xN)` node with a per-board feeder table; a wide
  flat tier packs into a grid of rows. Tower E-301 now issues on one page (was 17).
- C-4 Plant-level riser pages: the drainage terminus note takes its own clear slot (pipes
  and tags avoid it), and a lone-floor page that still prints key circles is re-drawn at
  a taller band while it stays width-bound, keeping the fewest keys.
- C-5 Small truths: the tower's MV supply prints '20 kV' on E-301 / E-401 / E-501; the
  house E-301 / E-401 print 'DEMAND 7.1 kVA > DECLARED 4.4 kVA - RAISE THE SUBSCRIBED
  DAYA' beside the supply; tanks without capacity print '- (*)' with one footnote and no
  orphan footnote page; detail sheets key only their own fixture codes; electrical layout
  tags keep a clear gap from their symbol.
