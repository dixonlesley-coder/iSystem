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

**Deliberate expected findings:** 3 × `drainage-length` (each unit's KS0 trap arm), 12 × `drainage-laid-steeper`, 3 × `drainage-cleanout`, 4 × `non-selective` (the three unit feeders and the auto-wired MEP feeder on `PP Ruko`: the 1.6 × discrimination floor over the fed incomer is capped by the feeder cable's Iz — see Backlog f), 5 `// VERIFY` advisories. Expected absent: `unfed-panel`, `unconnected-orphan`, `service-capacity-below-demand`, `downfeed-below-target`.

**Fixed by its review (2026-11-13).**
- **F1:** units B and C were solved as upfeed "extra supply components" from their ground tanks (no gravity field, RT at −146 kPa, booster sized 36.998 m). Every roof-tank component of a downfeed project is now its own downfeed system (`extraDownfeedTanksProvider`); B = C = A.
- **F2:** the meter stub WM → GT sized DN15 at 0 L/s. A root tank's mains feed now carries what the tank delivers (DN20).
- **F3:** the stack vent was sized on the top junction's 5 DFU (DN40). It now carries the stack base's 17 DFU (DN50).
- **F4:** a cassette AC in a room was flagged `unconnected-orphan`. Cassette and split-wall units need no pipe or duct and are exempt.

### Backlog (outside scope, not fixed)

- **(a) Several separately metered service entrances.** One project with several unfed service boards is not modelled consistently: the service study treats every unfed board as a root (`originPanelIdsOf`, the multi-root daya judge), while the Review flags all but the first as `unfed-panel` (`electricalConnectivityDefects`). This is why the fixture now uses one service board.
- **(b) Too few / too small AC units.** There is no Review warning when the AC units installed in a room are fewer or smaller than its cooling load (`selectAc` `exceedsRange`). One cassette in this room would need 44 400 BTU/h from a 27 000 BTU/h top unit, silently.
- **(c) Fill line sized on peak demand.** The fill line and the transfer pump are sized on the distribution's diversified peak flow, not on a tank fill rate.
- **(d) Water meter at ceiling level.** A water meter node (role main) sits at its floor's ceiling, which adds a vertical leg to the meter stub.
- **(e) Transfer pump label.** The transfer pump's electrical source reads "supply pump" (`_sourceFor` maps every pump to `supplyPump`).
- **(f) Feeder discrimination.** Every feeder way on `PP Ruko` (and the auto-wired MEP feeder) raises `non-selective`: the feeder breaker is already at the largest rung its auto-sized cable protects. The fixture was not tuned to hide it.
- **(g) Break tanks of extra roof tanks.** An extra roof-tank component's intermediate break tanks are not split into their own zone groups (F1 records this).
- **(h) Orphan exemption ignores the room.** The cassette / split-wall orphan exemption does not check room containment: the engine judge holds no rooms (F4).


## 3. Office (kantor 4 lantai)

**What it is.**
- **Building:** four storeys of 4.0 m ("Lantai 1..4", index 0..3), one sheet per floor at 0.02 m/px.
- **Cold water:** water meter → ground tank GT → UPFEED pump P1 → riser. On every floor a public toilet core: two flush-valve WCs, a urinal (`urinalFlushTank`; no flush-valve urinal type exists) and two lavatories. Occupancy is public.
- **Drainage / vent / rainwater:** every fixture drains to a 4-storey soil stack and a 10 m building drain; one stack vent; two 150 m² roof drains, a downpipe and a collector.
- **Fire (separate network):** fire tank FT → fire pump FP. FP feeds a Class I hydrant riser with one `hydrantBox` per floor, and a sprinkler riser with six heads in a line on Lantai 4. Light hazard, K 80.
- **HVAC (Lantai 2):** one 10 × 15 m office room (Room tool, seeded 3.7 m ceiling, 6 ACH). A ducted FCU feeds four supply diffusers in a line, each stamped with ¼ of the room airflow and a 450 × 300 face; a return grille (600 × 600) carries the whole airflow.
- **Electrical:** one 3-phase 400 V service board `LVMDP` on a declared 164 000 VA PLN connection, feeding four 3-phase floor sub-boards `PP-L1..L4` (lighting, sockets, three 1-phase AC ways each). P1, FP and FCU1 are not added by hand: the MEP sync mints the "MEP Equipment" board and its feeder.

**Files.**
- Fixture: `packages/mechx_engine/test/reference/office.dart` (`buildOffice()`, `kOfficeRooms`, `officeRoomAir()`).
- Engine pins: `packages/mechx_engine/test/reference_office_test.dart`. This covers the flush-valve cold-water sizing, Hazen–Williams friction, the upfeed field, drainage / vent / rainwater, the fire design and index friction, the room air, and the floor sub-boards and their feeders.
- App pins: `test/reference_office_app_test.dart`. This covers the P1 duty and SNI floors, the zone table, the fire-pump rating / duty / jockey, the FCU fan static, the MEP board and feeder, LVMDP, and the Review findings.
- Regression tests for its review fixes: `packages/mechx_engine/test/reference_office_regression_test.dart` (O1) and `test/reference_office_regression_test.dart` (O2, O4).
- Run either reference test with `REF_DUMP=1` to print every solved figure.

**Deliberate expected findings.**
- `life-safety-not-essential`: there is no genset in this building.
- 5 × `non-selective`: the four floor feeders and the MEP feeder.
- `fire-system-over-pressure:FP`: churn 1353.3 kPa > 1210.
- `standpipe-outlet-over-pressure:FP:0-3`: every hose valve's static is above 1207 kPa.
- `fire-pump-protection` info.
- The NFPA 20 standby-pump recommendation.
- `enclosure-temp-rise-exceeded` on LVMDP: the 250 A incomer on the 164 kVA service floor.
- 12 × `drainage-laid-steeper` and `drainage-cleanout` at D0.
- `air-duct-unsized` info: no duct size is hand-chosen.
- 5 `// VERIFY` advisories.

**Expected absent:** `service-capacity-below-demand`, `life-safety-feeder-cable`, `air-terminal-unsized`, `unfed-panel`, any `pressure-zone`.

**Fixed by its review (2026-11-13).**
- **O1:** the NFPA 20 discharge raise ran past FP's own junction onto the sprinkler branch: S0→S1 was DN125 at 31.545 L/s, then DN32 above it. The raise now stops at a two-outlet pump's junction: the sprinkler riser is DN32 at 4.714 L/s throughout.
- **O2:** on upfeed the zone table used the legacy 255 kPa budget walk and prescribed two PRV zones. It now hangs from the solved upfeed field (`upfeedZoneDatumProvider`): one zone, no PRV.
- **O4:** the auto-wired MEP feeder carrying the fire pump was NYY, and the app flagged its own feeder. The sync now specifies it FRC (and reverts only an FRC it set).
- **O3 (not fixed — deliberate):** the sprinkler-vs-pump judge requires lift + branch-base head only (25.56 m), while the rating basis' sprinkler point includes the sized index friction (58.211 m after O1). `docs/ENGINE-INVARIANTS.md` (audit round 8) records the judge head as a deliberate LOWER BOUND (static lift + branch-base pressure, no friction), so it was left.

### Backlog (outside scope, not fixed)

- **(a) Duct friction basis.** The room-air equipment estimate uses galvanised duct roughness (0.09 mm), while the drawn network uses the PU product (0.03 mm): 109.13 Pa vs 121.25 Pa for one FCU.
- **(b) Fire tank volume.** No fire-water tank volume is computed anywhere.
- **(c) Urinal type.** There is no flush-valve urinal type.
- **(d) Mains pressure.** Mains pressure at the meter is not modelled: the delivered upfeed field reads GT 0 kPa and WM negative.
- **(e) Churn over-pressure.** The Class I 690 kPa residual drives a churn over-pressure in a 4-storey building, with no pressure-restricting device modelled.
- **(f) Two judge heads (O3).** The sprinkler-vs-pump judge and the rating basis give two heads for one requirement (the deliberate audit-round-8 lower bound).
- **(g) Branch run prints the pump's flow (O1).** The branch run FP→S0 keeps the pump's rated 31.545 L/s on DN125 (the Round-62 stored-flow rule), not the sprinkler system's 4.714 L/s.
- **(h) Auto-FRC record not saved (O4).** The "FRC set by the sync" record is not persisted: after reopening a project, an auto-FRC feeder whose fire pump is later removed stays FRC.

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
- App pins: `test/reference_apartment_app_test.dart` (BEFORE / AFTER the PRV).
- Regression tests (A1, A2): `test/reference_apartment_regression_test.dart`.

**Deliberate expected findings** (final state: PLN 197 000 VA, genset 300 kVA, PRV drawn):
- `fire-system-over-pressure:FP`: churn 1.4 x 127.054 = 177.876 m = 1745 kPa > 1210.
- `standpipe-outlet-over-pressure:FP:0-11`: every hose valve's static at churn is above 1207 kPa.
- 2 x `non-selective`: Feeder PP-E (200 A vs the 200 A PP-E incomer) and Feeder to MEP (200 A vs 160 A), both capped at Iz 222 of 70 mm² FRC.
- `enclosure-temp-rise-exceeded` on PP-E (36 K > 35 K).
- Infos: `combined-fire-sprinkler-governs:FP` (the sprinkler sets the head, the standpipe the flow), `downfeed-below-target` (the gravity floors are under the 225 kPa target but above the SNI 49 kPa), `cable-raised-for-ads` (the lift, 10 mm²), 3 x `fire-pump-protection`, 72 x `drainage-laid-steeper`, 2 x `drainage-cleanout`, 12 x `phase-imbalance-inherent`, 5 `// VERIFY`.
- Before the PRV is drawn: 8 x `downfeed-over-pressure` (Lantai 1, 401.229 kPa static).

**Expected absent:** any critical or error, `ads-disconnection-on-genset`, `life-safety-*`, `service-capacity-below-demand`, `pressure-zone`, `downfeed-over-pressure` (after the PRV), `unfed-panel`.

**Fixed by its review (2026-11-13).**
- **A2:** `combined-fire-sprinkler-governs` was keyed on `pumpIds.first`, the jockey FJ. It is now keyed on the duty pump FP.
- **A1:** the combined pump was rated on the sprinkler point, 4.714 L/s @ 127.054 m (11 kW), a pump that cannot deliver the 31.545 L/s hydrant flow its pipes are sized for. It is now rated at the larger flow and the larger head, 31.545 L/s @ 127.054 m (75 kW; jockey 0.3155 L/s). The reviewer overruled the Round 37 "larger head at its own flow" rule (marked superseded in `docs/ENGINE-INVARIANTS.md`).

### Backlog (outside scope, not fixed)

- **(a) Jockey flow basis:** resolved by A1 (both 0.3155 L/s).
- **(b) Two alternator reactances.** The motor-start dip and the genset start floor use Xd'' 0.15 pu (`kGensetSubtransientReactancePu`), while the genset ADS fault uses 0.12 pu (`kAlternatorXdPu`), for the same set.
- **(c) Hose outlet height.** A hydrant box sits at the 1.1 m fixture height (39.6 m on Lantai 12), which sets its pipe leg, while the standpipe lift uses the 1.2 m outlet height (39.7 m).
- **(d) Sprinkler head height.** A head node sits at the 1.1 m fixture height, while its run is measured as a ceiling run (no leg) and the lift is taken at the ceiling.
- **(e) Two booster heads.** The gravity solve asks for a 22.230 m booster (KSb11). The Review's `downfeed-below-target` recommends a +15.3 m booster for Lantai 10 (KSb9), which the drawn side-branch booster cannot serve.
- **(f) No step-load / fire-tank rules.** There is no genset step-load check beyond the largest-motor dip, and no fire-water reserve rule (FT 60 000 L is a brief value).
- **(g) PRV on a riser.** There is no store intent that places a component on a riser (`addComponentNode` skips risers). The fixture splices a PRV node with a 0 m run.
- **(h) Fill line sized on peak demand** (shophouse c) — here 180 UBAP at 4.393 L/s.
- **(i) Genset rating ignores ADS on the alternator fault.** The recommended genset rating (`sizeGenerator`: running kVA, motor-start floor) does not consider automatic disconnection on the alternator's own fault level. Before A1 the app's recommended 50 kVA set (alternator fault 0.6 kA) failed `ads-disconnection-on-genset` on three ways (lift Zs 0.573, FP and FPS 0.558 > 0.437 Ω). Only A1's 75 kW fire pump, which raised the start floor to 300 kVA, cleared it.
