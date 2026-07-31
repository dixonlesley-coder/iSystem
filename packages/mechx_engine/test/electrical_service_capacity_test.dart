import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/panel_results.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

/// SERVICE-CAPACITY FLOOR — a declared connection capacity (daya tersambung,
/// [ElectricalProject.supplyCapacityVa]) rates the single root panel's incomer
/// + busbar at the capacity's line current, so changing the PLN daya re-sizes
/// the service-entrance incomer even when today's demand is small. Expected
/// values are hand-derived (3φ: VA / (√3·V_LL); 1φ: VA / V) against the
/// PuilProfile breaker ladder.
void main() {
  const p = PuilProfile();

  // A small 3φ 400 V root board: one 1200 W lighting way.
  //   Vph = round(400/√3) = 231 V; Ib = 1200/(231·0.9) = 5.77 → 5.8 A.
  //   Worst-phase demand = 5.8 A → demand-based incomer rung 6 A.
  ElectricalProject smallProject({ApparentPower? capacity}) =>
      ElectricalProject(
        id: 'prj',
        supplyCapacityVa: capacity,
        panels: const [
          ElectricalPanel(
            id: 'mdp',
            name: 'MDP',
            system: ElectricalSystem.threePhase,
            voltage: Voltage(400),
            circuits: [
              ElectricalCircuit(
                id: 'c1',
                name: 'Lighting',
                loadKind: LoadKind.lighting,
                isLighting: true,
                loadW: 1200,
                cosPhi: 0.9,
                length: Length(10),
              ),
            ],
          ),
        ],
      );

  test('no declared capacity ⇒ the incomer sizes on demand (byte-identical)',
      () {
    final sys = computeSystem(p, smallProject());
    final mdp = sys.panels['mdp']!;
    // Demand 5.8 A → first feeder rung ≥ 5.8 = 6 A.
    expect(mdp.demandCurrent.amperes, closeTo(5.8, 1e-9));
    expect(mdp.incomer.breaker.ratingA.amperes, 6);
    expect(
        sys.warnings.where((w) => w.code == 'service-capacity-below-demand'),
        isEmpty);
  });

  test('PLN 33 kVA 3φ floors the root incomer at the 50 A rung', () {
    final sys = computeSystem(
        p, smallProject(capacity: ApparentPower.kilovoltAmperes(33)));
    final mdp = sys.panels['mdp']!;
    // Service current = 33000 / (√3·400) = 47.63 A → rung 50 A — the matching
    // PLN 33 kVA limiter (33000 / (3·220) = 50 A). Demand stays 5.8 A.
    expect(mdp.demandCurrent.amperes, closeTo(5.8, 1e-9));
    expect(mdp.incomer.breaker.ratingA.amperes, 50);
    expect(mdp.incomer.poles, 4);
    // The bus is rated for the incoming device, so it rides the floor too.
    expect(mdp.busbar.ampacityA, greaterThanOrEqualTo(50));
    // Per-circuit sizing untouched: the lighting way keeps its own rung.
    expect(mdp.circuits.single.breaker.ratingA.amperes, 6);
    // Capacity comfortably above demand ⇒ no limiter warning.
    expect(
        sys.warnings.where((w) => w.code == 'service-capacity-below-demand'),
        isEmpty);
  });

  test('raising the declared daya raises the incomer (the user-visible knob)',
      () {
    double incomerAt(double kva) => computeSystem(p,
            smallProject(capacity: ApparentPower.kilovoltAmperes(kva)))
        .panels['mdp']!
        .incomer
        .breaker
        .ratingA
        .amperes;
    // 23 kVA → 23000/692.8 = 33.2 → 35? Ladder has 32 then 40 ⇒ 40 A.
    // (PLN's 23 kVA limiter is 35 A on the 3·220 basis; 40 A is the first
    // available ladder rung above the 400 V line current — conservative.)
    expect(incomerAt(23), 40);
    expect(incomerAt(33), 50); // 47.63 A → 50
    expect(incomerAt(66), 100); // 95.26 A → 100
    expect(incomerAt(197), 315); // 284.35 A → 315 (MCCB)
  });

  test('1φ 220 V: PLN 5500 VA floors the incomer at the 25 A limiter rung', () {
    final sys = computeSystem(
      p,
      const ElectricalProject(
        id: 'prj1',
        supplyCapacityVa: ApparentPower(5500),
        panels: const [
          ElectricalPanel(
            id: 'lp',
            name: 'LP',
            system: ElectricalSystem.singlePhase,
            voltage: Voltage(220),
            circuits: [
              ElectricalCircuit(
                id: 'c1',
                name: 'Lighting',
                loadKind: LoadKind.lighting,
                isLighting: true,
                loadW: 500,
                cosPhi: 0.9,
                length: Length(10),
              ),
            ],
          ),
        ],
      ),
    );
    final lp = sys.panels['lp']!;
    // Service current = 5500 / 220 = 25 A → rung 25 A (the PLN 5500 VA MCB).
    expect(lp.incomer.breaker.ratingA.amperes, 25);
    expect(lp.incomer.poles, 2);
  });

  test('capacity below demand ⇒ demand still sizes; the limiter warning fires',
      () {
    final sys = computeSystem(
      p,
      const ElectricalProject(
        id: 'prj2',
        // 2200 VA @ 220 V = 10 A — well below the board's demand.
        supplyCapacityVa: ApparentPower(2200),
        panels: [
          ElectricalPanel(
            id: 'lp',
            name: 'LP',
            system: ElectricalSystem.singlePhase,
            voltage: Voltage(220),
            circuits: [
              ElectricalCircuit(
                id: 'c1',
                name: 'Heater',
                loadKind: LoadKind.heating,
                loadW: 8800,
                cosPhi: 1,
                length: Length(10),
              ),
            ],
          ),
        ],
      ),
    );
    final lp = sys.panels['lp']!;
    // Demand: 8800 / 220 = 40 A > the 10 A service current ⇒ the incomer sizes
    // on demand exactly as before (rung ≥ 40 = 40 A) — the floor never shrinks.
    expect(lp.demandCurrent.amperes, closeTo(40, 1e-9));
    expect(lp.incomer.breaker.ratingA.amperes, 40);
    final w = sys.warnings
        .where((x) => x.code == 'service-capacity-below-demand')
        .toList();
    expect(w, hasLength(1));
    expect(w.single.severity, WarningSeverity.warning);
    expect(w.single.panelId, 'lp');
    // The panel's own warning list carries it too (locatable surface).
    expect(
        lp.warnings.where((x) => x.code == 'service-capacity-below-demand'),
        hasLength(1));
  });

  test('several utility-fed roots ⇒ no floor (the split is unknown)', () {
    ElectricalPanel root(String id) => ElectricalPanel(
          id: id,
          name: id.toUpperCase(),
          system: ElectricalSystem.threePhase,
          voltage: const Voltage(400),
          circuits: const [
            ElectricalCircuit(
              id: 'c1',
              name: 'Lighting',
              loadKind: LoadKind.lighting,
              isLighting: true,
              loadW: 1200,
              cosPhi: 0.9,
              length: Length(10),
            ),
          ],
        );
    final sys = computeSystem(
      p,
      ElectricalProject(
        id: 'prj3',
        supplyCapacityVa: ApparentPower.kilovoltAmperes(33),
        panels: [root('a'), root('b')],
      ),
    );
    // Both stay demand-sized — nothing fabricated about how the declared
    // capacity divides between two service boards.
    expect(sys.panels['a']!.incomer.breaker.ratingA.amperes, 6);
    expect(sys.panels['b']!.incomer.breaker.ratingA.amperes, 6);
  });

  test('the earthing PE derivation rides the governing service floor', () {
    final without = computeSystem(p, smallProject());
    final with197 = computeSystem(
        p, smallProject(capacity: ApparentPower.kilovoltAmperes(197)));
    // A 284 A service entrance needs at least the PE of the 5.8 A one —
    // monotone, never smaller.
    expect(with197.earthing.mainEarthingConductorMm2,
        greaterThanOrEqualTo(without.earthing.mainEarthingConductorMm2));
  });
}
