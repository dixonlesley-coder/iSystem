import 'package:mechx_engine/electrical/containment.dart';
import 'package:mechx_engine/electrical/earthing.dart'
    show GroundingResult, RcdSpec, RcdType;
import 'package:mechx_engine/electrical/enclosure.dart';
import 'package:mechx_engine/electrical/load_kind.dart' show LoadKind;
import 'package:mechx_engine/electrical/model.dart' show ElectricalSystem;
import 'package:mechx_engine/electrical/panel_results.dart';
import 'package:mechx_engine/electrical/results.dart';
import 'package:mechx_engine/standards/puil.dart' show BreakerClass, BreakerCurve;
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

/// Seed tests for A8c containment + enclosure (a post-processing pass over a
/// computed [ElectricalPanelResult]). Expected values are hand-derived from
/// first principles in the inline arithmetic comments.

// --- Minimal fixture builders (the post-processing pass reads only a few
// fields, so the rest are filled with inert placeholders). ---

ElectricalCircuitResult _circuit({
  required String id,
  required double csaMm2,
  required int cores,
  bool threePhase = false,
  bool rcd = false,
  LoadKind loadKind = LoadKind.general,
}) =>
    ElectricalCircuitResult(
      circuitId: id,
      name: id,
      loadKind: loadKind,
      designCurrent: const Current(10),
      threePhase: threePhase,
      phase: threePhase ? PhaseAssignment.threePhase : PhaseAssignment.l1,
      breaker: const BreakerResult(
        ratingA: Current(16),
        deviceClass: BreakerClass.mcb,
        curve: BreakerCurve.c,
      ),
      cable: CableResult(
        csaMm2: csaMm2,
        baseKha: const Current(0),
        deratedIz: const Current(0),
        deratingFactor: 1,
        vdDriven: false,
        appliedRule: '',
      ),
      voltageDrop: const VoltageDropResult(
        dropV: 0,
        dropPercent: 0,
        limitPercent: 5,
        withinLimit: true,
      ),
      cumulativeDropPercent: 0,
      grounding: GroundingResult(
        peCsaMm2: csaMm2,
        neutralCsaMm2: csaMm2,
        cores: cores,
        cableSpec: '',
        cableType: 'NYY',
      ),
      rcd: RcdSpec(
        required: rcd,
        ratingMa: rcd ? 30 : 0,
        reason: '',
        type: rcd ? RcdType.a : null,
      ),
    );

ElectricalPanelResult _panel({
  required List<ElectricalCircuitResult> circuits,
  int incomerPoles = 4,
}) {
  const inertBusbar = BusbarResult(
    widthMm: 0,
    thicknessMm: 0,
    csaMm2: 0,
    ampacityA: Current(0),
    totalCurrentA: Current(0),
  );
  return ElectricalPanelResult(
    panelId: 'P1',
    name: 'Panel 1',
    system: ElectricalSystem.threePhase,
    circuits: circuits,
    incomer: IncomerResult(
      breaker: const BreakerResult(
        ratingA: Current(63),
        deviceClass: BreakerClass.mcb,
        curve: BreakerCurve.c,
      ),
      poles: incomerPoles,
    ),
    busbar: inertBusbar,
    busbarSections: const [],
    neutralPeBars:
        const NeutralPeBars(neutralCsaMm2: 0, neutralAmpacityA: Current(0), peCsaMm2: 0),
    connectedW: 0,
    demandW: 0,
    demandCurrent: const Current(0),
    phaseBalance:
        const PhaseBalanceResult(l1: 0, l2: 0, l3: 0, imbalancePercent: 0),
    warnings: const [],
  );
}

void main() {
  group('cableOuterDiameterMm', () {
    test('35 mm² × 4 cores ≈ 23.8 mm', () {
      // conductor_d = 2·√(35/π) = 2·3.33778 = 6.67556
      // insulation  = 0.7 + 0.05·√35 = 0.7 + 0.295804 = 0.995804
      // core_d      = 6.67556 + 2·0.995804 = 8.66717
      // layup(4)    = 2.42 ; sheath = 1.0 + 0.05·8.66717 = 1.433359
      // od = 8.66717·2.42 + 2·1.433359 = 20.97455 + 2.866717 = 23.84127 → 23.8
      expect(cableOuterDiameterMm(35, 4), 23.8);
    });

    test('2.5 mm² × 3 cores ≈ 9.6 mm', () {
      // conductor_d = 2·√(2.5/π) = 2·0.892062 = 1.784124
      // insulation  = 0.7 + 0.05·√2.5 = 0.7 + 0.079057 = 0.779057
      // core_d      = 1.784124 + 2·0.779057 = 3.342238
      // layup(3)    = 2.16 ; sheath = 1.0 + 0.05·3.342238 = 1.167112
      // od = 3.342238·2.16 + 2·1.167112 = 7.219234 + 2.334224 = 9.553458 → 9.6
      expect(cableOuterDiameterMm(2.5, 3), 9.6);
    });

    test('zero CSA → 0', () {
      expect(cableOuterDiameterMm(0, 4), 0);
    });
  });

  group('sizeConduit', () {
    test('35 mm² × 4 cores (OD 23.8) → 40 mm conduit at 45.2% fill', () {
      // cableArea = (π/4)·23.8² = 444.881 mm²
      // 16: bore 122.7, limit 65.0 — no ; 20: 224.3/118.9 — no
      // 25: 359.7/190.6 — no ; 32: 607.0/321.7 — no
      // 40: bore (π/4)·35.4² = 984.2, limit 521.6 ≥ 444.881 — YES
      // fill = 444.881 / 984.2 · 100 = 45.2 %
      final s = sizeConduit(35, 4);
      expect(s.cableOdMm, 23.8);
      expect(s.conduitSizeMm, 40);
      expect(s.fillPct, 45.2);
    });

    test('2.5 mm² × 3 cores (OD 9.6) → 20 mm conduit at 32.3% fill', () {
      // cableArea = (π/4)·9.6² = 72.382 mm²
      // 16: bore 122.7, limit 65.0 < 72.382 — no
      // 20: bore (π/4)·16.9² = 224.3, limit 118.9 ≥ 72.382 — YES
      // fill = 72.382 / 224.3 · 100 = 32.3 %
      final s = sizeConduit(2.5, 3);
      expect(s.conduitSizeMm, 20);
      expect(s.fillPct, 32.3);
    });
  });

  group('sizeCableTray', () {
    test('three cables → 50 mm tray at 84.0% fill', () {
      // ODs: 2.5/3 = 9.6, 4/3 = 10.7, 16/4 = 17.9
      // reqWidth = (9.6 + 10.7 + 17.9)·1.1 = 38.2·1.1 = 42.02
      // first standard width ≥ 42.02 = 50 ; fill = 42.02/50·100 = 84.0 %
      final panel = _panel(circuits: [
        _circuit(id: 'c1', csaMm2: 2.5, cores: 3),
        _circuit(id: 'c2', csaMm2: 4, cores: 3),
        _circuit(id: 'c3', csaMm2: 16, cores: 4, threePhase: true),
      ]);
      final t = sizeCableTray(panel);
      expect(t.cableCount, 3);
      expect(t.widthMm, 50);
      expect(t.fillPct, 84.0);
    });

    test('spare way (csa 0) is excluded from the tray', () {
      final panel = _panel(circuits: [
        _circuit(id: 'c1', csaMm2: 2.5, cores: 3),
        _circuit(id: 'sp', csaMm2: 0, cores: 0, loadKind: LoadKind.spare),
      ]);
      final t = sizeCableTray(panel);
      expect(t.cableCount, 1);
    });
  });

  group('containmentFor', () {
    test('one conduit per real cable; spare gets none', () {
      final panel = _panel(circuits: [
        _circuit(id: 'c1', csaMm2: 2.5, cores: 3),
        _circuit(id: 'c2', csaMm2: 16, cores: 4, threePhase: true),
        _circuit(id: 'sp', csaMm2: 0, cores: 0, loadKind: LoadKind.spare),
      ]);
      final r = containmentFor(panel);
      expect(r.panelId, 'P1');
      expect(r.conduits.map((c) => c.circuitId), ['c1', 'c2']);
      expect(r.conduits.first.conduit.conduitSizeMm, 20);
      expect(r.tray.cableCount, 2);
      expect(r.verifyItems, isNotEmpty);
    });
  });

  group('estimatePanelModules', () {
    test('3ph incomer + 20 1ph ways + 3 RCD ways = 30 modules', () {
      // incomer poles 4 + 20·(1 pole) + 3·(2 RCD modules) = 4 + 20 + 6 = 30
      final circuits = [
        for (var i = 0; i < 20; i++)
          _circuit(id: 'c$i', csaMm2: 2.5, cores: 3, rcd: i < 3),
      ];
      final panel = _panel(circuits: circuits, incomerPoles: 4);
      expect(estimatePanelModules(panel), 30);
    });
  });

  group('estimateEnclosure', () {
    test('30 modules + 250 W → 750×500×200, 1.5 mm, forced, over-temp', () {
      // modules = 30 → rows = ceil(30/24) = 2
      // width  = roundUp(24·18 + 2·150, 50) = roundUp(732, 50) = 750
      // height = roundUp(2·150 + 200, 50) = roundUp(500, 50) = 500
      // depth  = 200 (wall) ; largest 750 → sheet (≤1000) = 1.5
      // A_eff = (0.75·0.50) + 2·(0.75·0.20) + 2·(0.50·0.20)
      //       = 0.375 + 0.300 + 0.200 = 0.875 m²
      // rise = 250 / (5.5·0.875) = 250 / 4.8125 = 51.9 K  > 35 → not within
      // 250 W → forced (≥200, <500)
      final circuits = [
        for (var i = 0; i < 20; i++)
          _circuit(id: 'c$i', csaMm2: 2.5, cores: 3, rcd: i < 3),
      ];
      final panel = _panel(circuits: circuits, incomerPoles: 4);
      final e = estimateEnclosure(panel, heat: const Power(250));
      expect(e.modules, 30);
      expect(e.rows, 2);
      expect(e.widthMm, 750);
      expect(e.heightMm, 500);
      expect(e.depthMm, 200);
      expect(e.sheetMm, 1.5);
      expect(e.ventilation, Ventilation.forced);
      expect(e.tempRiseK, 51.9);
      expect(e.withinTempLimit, isFalse);
      expect(e.ip, 'IP41');
      expect(e.verifyItems, isNotEmpty);
    });

    test('small panel + low heat → 750×350×200, natural, within temp', () {
      // 1ph incomer poles 2 + 4 1ph ways = 6 modules → rows 1
      // width 750 ; height = roundUp(1·150+200, 50) = roundUp(350,50) = 350
      // A_eff = 0.75·0.35 + 2·(0.75·0.20) + 2·(0.35·0.20)
      //       = 0.2625 + 0.300 + 0.140 = 0.7025 m²
      // rise = 30 / (5.5·0.7025) = 30 / 3.86375 = 7.8 K ≤ 35 → within
      // 30 W → natural (<50)
      final circuits = [
        for (var i = 0; i < 4; i++) _circuit(id: 'c$i', csaMm2: 2.5, cores: 3),
      ];
      final panel = _panel(circuits: circuits, incomerPoles: 2);
      final e = estimateEnclosure(panel, heat: const Power(30));
      expect(e.modules, 6);
      expect(e.rows, 1);
      expect(e.widthMm, 750);
      expect(e.heightMm, 350);
      expect(e.depthMm, 200);
      expect(e.ventilation, Ventilation.natural);
      expect(e.tempRiseK, 7.8);
      expect(e.withinTempLimit, isTrue);
    });

    test('hasFloorGear deepens the enclosure to 400 mm', () {
      final panel = _panel(circuits: [
        _circuit(id: 'c1', csaMm2: 2.5, cores: 3),
      ], incomerPoles: 4);
      final e = estimateEnclosure(panel, hasFloorGear: true);
      expect(e.depthMm, 400);
    });

    test('zero heat → natural ventilation, 0 K rise, within limit', () {
      final panel = _panel(circuits: [
        _circuit(id: 'c1', csaMm2: 2.5, cores: 3),
      ]);
      final e = estimateEnclosure(panel);
      expect(e.ventilation, Ventilation.natural);
      expect(e.tempRiseK, 0);
      expect(e.withinTempLimit, isTrue);
    });
  });
}
