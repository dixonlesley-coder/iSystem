
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/earthing.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/panel_results.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

/// A4 panel/system orchestrator tests. Expected values are hand-derived from the
/// formulas + the PUIL/Supreme tables in `PuilProfile`, so they anchor the port.
void main() {
  const p = PuilProfile();

  // On a 3φ 400 V board single-phase circuits run at the phase voltage:
  //   Vph = round(400/√3) = round(230.94) = 231 V (used in the derivations below).

  ElectricalCircuitResult byId(ElectricalPanelResult r, String id) =>
      r.circuits.firstWhere((c) => c.circuitId == id);

  group('(a) one 3φ panel, mixed circuits', () {
    // LP-1: 3φ 400 V, ambient 30 °C, conduit (B1) → derating 1.0.
    //   c1 Lighting 1800 W, cosφ 0.9, 1φ  (< 5500 W ⇒ single-phase)
    //   c2 Sockets  3000 W, cosφ 0.9, 1φ
    //   c3 Motor    7.5 kW, cosφ 0.85, 3φ (motorKw ≥ 3 kW ⇒ three-phase)
    const panel = ElectricalPanel(
      id: 'LP1',
      name: 'LP-1',
      tag: 'LP-1',
      system: ElectricalSystem.threePhase,
      voltage: const Voltage(400),
      ambientTempC: 30,
      circuits: const [
        ElectricalCircuit(
          id: 'c1',
          name: 'Lighting',
          loadKind: LoadKind.lighting,
          isLighting: true,
          loadW: 1800,
          cosPhi: 0.9,
          length: Length(20),
        ),
        ElectricalCircuit(
          id: 'c2',
          name: 'Sockets',
          loadKind: LoadKind.socket,
          loadW: 3000,
          cosPhi: 0.9,
          length: Length(20),
        ),
        ElectricalCircuit(
          id: 'c3',
          name: 'Motor',
          loadKind: LoadKind.motor,
          motorKw: 7.5,
          cosPhi: 0.85,
          length: Length(30),
        ),
      ],
    );
    final r = computePanel(p, panel);

    test('per-circuit design current Ib', () {
      // Lighting: 1800 / (231·0.9) = 8.658 → 8.7 A
      expect(byId(r, 'c1').designCurrent.amperes, closeTo(8.7, 1e-9));
      expect(byId(r, 'c1').threePhase, isFalse);
      // Sockets: 3000 / (231·0.9) = 14.43 → 14.4 A
      expect(byId(r, 'c2').designCurrent.amperes, closeTo(14.4, 1e-9));
      // Motor (P=7.5 kW approximation): 7500 / (√3·400·0.85) = 12.736 → 12.7 A
      expect(byId(r, 'c3').designCurrent.amperes, closeTo(12.7, 1e-9));
      expect(byId(r, 'c3').threePhase, isTrue);
    });

    test('breaker rating = smallest standard ≥ Ib', () {
      expect(byId(r, 'c1').breaker.ratingA.amperes, 10); // ≥ 8.7
      expect(byId(r, 'c2').breaker.ratingA.amperes, 16); // ≥ 14.4
      expect(byId(r, 'c3').breaker.ratingA.amperes, 16); // ≥ 12.7
    });

    test('cable section = final-circuit minimum (ampacity not binding)', () {
      // Lighting final minimum 1.5 mm² (KHA 18 A ≥ max(In 10, 1.25·8.66=10.8)).
      expect(byId(r, 'c1').cable.csaMm2, 1.5);
      // Socket final minimum 2.5 mm² (KHA 25 A ≥ max(In 16, 1.25·14.43=18.0)).
      expect(byId(r, 'c2').cable.csaMm2, 2.5);
      // Motor 3φ final minimum 2.5 mm² (KHA 25 A ≥ max(16, 1.25·12.74=15.9)).
      expect(byId(r, 'c3').cable.csaMm2, 2.5);
    });

    test('cores follow neutral need (1φ = L+N+PE, 3φ motor = 3L+PE)', () {
      expect(byId(r, 'c1').grounding.cores, 3); // L+N+PE
      expect(byId(r, 'c1').grounding.cableSpec, 'NYM 3×1.5 mm²');
      expect(byId(r, 'c2').grounding.cores, 3);
      // 3φ motor: needsNeutral=false, motorLike=true ⇒ no neutral, 4-core.
      expect(byId(r, 'c3').grounding.cores, 4); // 3L+PE
      expect(byId(r, 'c3').grounding.cableSpec, 'NYY 4×2.5 mm²');
    });

    test('per-circuit RCD policy (TN-C-S)', () {
      // Socket ⇒ 30 mA additional protection; lighting/motor ⇒ none on TN-C-S.
      expect(byId(r, 'c2').rcd.required, isTrue);
      expect(byId(r, 'c2').rcd.ratingMa, 30);
      expect(byId(r, 'c1').rcd.required, isFalse);
      expect(byId(r, 'c3').rcd.required, isFalse);
    });

    test('voltage drop within limit (auto-upsize holds it)', () {
      expect(byId(r, 'c1').voltageDrop.withinLimit, isTrue); // 3 % lighting
      expect(byId(r, 'c2').voltageDrop.withinLimit, isTrue); // 5 % general
      expect(byId(r, 'c3').voltageDrop.withinLimit, isTrue);
    });

    test('connected / demand W', () {
      // Connected = 1800 + 3000 + (7.5·1000) = 12 300 W; diversity 1 ⇒ demand =.
      expect(r.connectedW, 12300);
      expect(r.demandW, 12300);
    });

    test('balanced phases + worst-phase demand current', () {
      // 3φ motor loads every line at 12.7 A. Single-phase sorted desc:
      //   sockets 14.4 → least-loaded line (all equal) → L1: L1 = 12.7+14.4 = 27.1
      //   lighting 8.7 → least loaded (L2 or L3 = 12.7) → L2: L2 = 12.7+8.7 = 21.4
      //   L3 = 12.7. Local search finds no smaller spread.
      expect(r.phaseBalance.l1, closeTo(27.1, 1e-9));
      expect(r.phaseBalance.l2, closeTo(21.4, 1e-9));
      expect(r.phaseBalance.l3, closeTo(12.7, 1e-9));
      // Worst phase = 27.1 A drives the incomer + main bus.
      expect(r.demandCurrent.amperes, closeTo(27.1, 1e-9));
      // imbalance = (27.1-12.7)/avg(20.4) ·100 = 14.4/20.4·100 = 70.6 % > 15 %.
      expect(r.imbalancePercent, closeTo(70.6, 0.2));
      expect(r.warnings.map((w) => w.code), contains('phase-imbalance'));
    });

    test('incomer breaker ≥ worst-phase demand, 4-pole on 3φ', () {
      expect(r.incomer.breaker.ratingA.amperes, 32); // smallest ≥ 27.1
      expect(r.incomer.poles, 4);
    });

    test('main busbar floored to incomer rating; N + PE bars', () {
      // Demand 27.1 A, but the bus is rated for the incomer In = 32 A. The
      // smallest bar with ampacity ≥ 32 A is the 24 mm² / 110 A bar.
      expect(r.busbar.csaMm2, 24);
      expect(r.busbar.ampacityA.amperes, 110);
      // Neutral full size = phase bar; PE = 16 mm² for 16 < S ≤ 35.
      expect(r.neutralPeBars.neutralCsaMm2, 24);
      expect(r.neutralPeBars.peCsaMm2, 16);
    });

    test('one busbar section carries all 3 ways at the worst-phase current', () {
      expect(r.busbarSections.length, 1);
      expect(r.busbarSections.first.ways, 3);
      expect(r.busbarSections.first.sectionCurrent.amperes, closeTo(27.1, 1e-9));
    });
  });

  group('(b) two-panel feeder tree — diversified demand + cumulative Vd', () {
    // SP: 3φ, ONE 3φ heater 10 kW cosφ 1.0, diversity 0.8.
    //   demand = 10 000 · 0.8 = 8 000 W.
    // MDP feeds SP through feeder f1 (40 m). The feeder's load = SP's demand.
    const sp = ElectricalPanel(
      id: 'SP',
      name: 'Sub',
      system: ElectricalSystem.threePhase,
      voltage: const Voltage(400),
      diversityFactor: 0.8,
      sourceType: PanelSource.feeder,
      fedByCircuitId: 'f1',
      circuits: const [
        ElectricalCircuit(
          id: 's1',
          name: 'Heater',
          loadKind: LoadKind.heating,
          loadW: 10000,
          cosPhi: 1.0,
          phases: 3,
          length: Length(15),
        ),
      ],
    );
    const mdp = ElectricalPanel(
      id: 'MDP',
      name: 'Main',
      system: ElectricalSystem.threePhase,
      voltage: const Voltage(400),
      circuits: const [
        ElectricalCircuit(
          id: 'f1',
          name: 'Feeder to SP',
          loadKind: LoadKind.feeder,
          cosPhi: 0.85,
          length: Length(40),
          feedsPanelId: 'SP',
        ),
      ],
    );
    const project = ElectricalProject(
      id: 'pr',
      name: 'Building',
      panels: [mdp, sp],
      earthingSystem: EarthingSystem.tnCs,
    );
    final r = computeSystem(p, project);

    test('root-first order, no warnings', () {
      expect(r.order, ['MDP', 'SP']);
      expect(r.warnings, isEmpty);
    });

    test('feeder carries the child panel\'s diversified demand (not raw 10 kW)',
        () {
      final feeder = byId(r.panels['MDP']!, 'f1');
      // Ib = 8000 / (√3·400·0.85) = 13.583 → 13.6 A  (NOT 10 000-based 16.98).
      expect(feeder.designCurrent.amperes, closeTo(13.6, 1e-9));
      expect(feeder.threePhase, isTrue);
      // Feeder cable floored to the 3φ trunk minimum 4 mm².
      expect(feeder.cable.csaMm2, 4);
      expect(feeder.breaker.ratingA.amperes, 16); // ≥ 13.6
    });

    test('SP demand + heater current', () {
      final spR = r.panels['SP']!;
      expect(spR.connectedW, 10000);
      expect(spR.demandW, 8000);
      // Heater 3φ: 10000 / (√3·400·1.0) = 14.434 → 14.4 A.
      expect(byId(spR, 's1').designCurrent.amperes, closeTo(14.4, 1e-9));
    });

    test('cumulative voltage drop accumulates down the tree', () {
      final feeder = byId(r.panels['MDP']!, 'f1');
      final heater = byId(r.panels['SP']!, 's1');
      // Feeder is a root-panel way ⇒ cumulative = its own drop.
      expect(feeder.cumulativeDropPercent, closeTo(feeder.voltageDrop.dropPercent, 1e-9));
      // Heater cumulative = upstream feeder drop + heater's own segment drop.
      final expected = (feeder.voltageDrop.dropPercent + heater.voltageDrop.dropPercent);
      expect(heater.cumulativeDropPercent, closeTo(expected, 0.01));
      // And it is strictly larger than the heater's own segment alone.
      expect(heater.cumulativeDropPercent, greaterThan(heater.voltageDrop.dropPercent));
    });

    test('system totals + supply summary (no daya table invented)', () {
      expect(r.totalDemandW, 8000);
      expect(r.supply.connectedW, 10000); // leaf load only
      expect(r.supply.demandW, 8000);
      // VA = demandW / assumed building PF 0.85 = 9411.8 → 9412 VA.
      expect(r.supply.demandVa.voltAmperes, closeTo(9412, 1));
      expect(r.supply.system, ElectricalSystem.threePhase);
    });

    test('earthing system designed from the main incomer PE', () {
      expect(r.earthing.system, EarthingSystem.tnCs);
      expect(r.earthing.requiresRcd, isFalse); // TN-C-S
    });
  });

  group('(c) feeder cycle detection', () {
    // A ↔ B feed each other → a cycle with no valid root.
    const a = ElectricalPanel(
      id: 'A',
      name: 'A',
      system: ElectricalSystem.threePhase,
      circuits: const [
        ElectricalCircuit(
          id: 'a1',
          name: 'A→B',
          loadKind: LoadKind.feeder,
          feedsPanelId: 'B',
          length: Length(10),
        ),
      ],
    );
    const b = ElectricalPanel(
      id: 'B',
      name: 'B',
      system: ElectricalSystem.threePhase,
      circuits: const [
        ElectricalCircuit(
          id: 'b1',
          name: 'B→A',
          loadKind: LoadKind.feeder,
          feedsPanelId: 'A',
          length: Length(10),
        ),
      ],
    );
    final r = computeSystem(p, const ElectricalProject(panels: [a, b]));

    test('cycle is flagged (not crashed)', () {
      expect(r.warnings.map((w) => w.code), contains('feeder-cycle'));
      // Both panels still get a result so renderers iterate uniformly.
      expect(r.panels.containsKey('A'), isTrue);
      expect(r.panels.containsKey('B'), isTrue);
    });
  });

  group('phase + busbar units', () {
    test('1φ panel sums every circuit on L1', () {
      const panel = ElectricalPanel(
        id: 'P',
        name: 'P',
        system: ElectricalSystem.singlePhase,
        voltage: const Voltage(220),
        circuits: const [
          ElectricalCircuit(
              id: 'x', name: 'A', loadW: 2200, cosPhi: 0.9, length: Length(10)),
          ElectricalCircuit(
              id: 'y', name: 'B', loadW: 1100, cosPhi: 1.0, length: Length(10)),
        ],
      );
      final r = computePanel(p, panel);
      // Ix = 2200/(220·0.9)=11.11→11.1; Iy = 1100/(220·1)=5.0.
      // 1φ panel: L1 = 11.1 + 5.0 = 16.1, L2=L3=0, imbalance 0.
      expect(r.phaseBalance.l1, closeTo(16.1, 1e-9));
      expect(r.phaseBalance.l2, 0);
      expect(r.imbalancePercent, 0);
      expect(r.incomer.poles, 2); // 1φ = L+N
      for (final c in r.circuits) {
        expect(c.phase, PhaseAssignment.l1);
      }
    });

    test('busbar splits at the way-count cap (maxWaysPerBusbar)', () {
      // maxWaysPerBusbar = 12. 13 tiny single-phase ways → 2 sections (12 + 1).
      final circuits = [
        for (var i = 0; i < 13; i++)
          ElectricalCircuit(
            id: 'w$i',
            name: 'W$i',
            loadKind: LoadKind.lighting,
            isLighting: true,
            loadW: 200,
            cosPhi: 0.9,
            length: const Length(5),
          ),
      ];
      final r = computePanel(
        p,
        ElectricalPanel(
          id: 'PB',
          name: 'PB',
          system: ElectricalSystem.threePhase,
          circuits: circuits,
        ),
      );
      expect(r.busbarSections.length, 2);
      expect(r.busbarSections[0].ways, 12);
      expect(r.busbarSections[1].ways, 1);
    });
  });
}
