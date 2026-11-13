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
