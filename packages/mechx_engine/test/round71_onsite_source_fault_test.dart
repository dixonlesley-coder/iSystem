// Round 71 (elec-convergence-23) — an ON-SITE source's fault on a small
// single-phase installation.
//
// A 1-phase 220 V TN-C-S kiosk (PLN 3500 VA): 600 W lighting, 1200 W
// sockets and a small DOL pump on 2.5 mm2 over 20 m.
//
// (1) Standby genset (an untyped `GeneratorSource`): the installed set is
//     the 10 kVA ladder rung on every surface. The genset ADS judge rated it
//     as a 3-phase 400 V alternator — 10000 / (sqrt3 x 400) / 0.12 = 120.3 A
//     — so the pump's earth-fault loop failed the curve-D limit and an
//     `ads-disconnection-on-genset` ERROR blocked sign-off. The same set is
//     SIZED on the single-phase board basis, so its fault is the 1-phase
//     alternator's: 10000 / 220 / 0.12 = 378.8 A.
// (2) A genset as the PRIMARY supply with no capacity declared: the fault was
//     rated on the bare demand (~2.6 kVA) on the 3-phase basis (~31 A) — the
//     lighting way failed ADS — while the power one-line prints the INSTALLED
//     10 kVA set. The procured set's alternator governs: 378.8 A again.
library;

import 'dart:math' as math;

import 'package:mechx_engine/electrical/advanced_study.dart';
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/control/starter.dart' show StarterType;
import 'package:mechx_engine/electrical/earthing.dart';
import 'package:mechx_engine/electrical/fault.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/sources.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

const _profile = PuilProfile();

ElectricalProject _kiosk(
        {SupplyKind kind = SupplyKind.pln, double pumpKw = 0.75}) =>
    ElectricalProject(
      id: 'k',
      name: 'Kiosk',
      earthingSystem: EarthingSystem.tnCs,
      supplyKind: kind,
      supplyCapacityVa:
          kind == SupplyKind.pln ? const ApparentPower(3500) : null,
      sources: const ElectricalSources(generator: GeneratorSource()),
      panels: [
        ElectricalPanel(
            id: 'DB',
            name: 'DB',
            system: ElectricalSystem.singlePhase,
            voltage: const Voltage(220),
            circuits: [
              const ElectricalCircuit(
                  id: 'lt',
                  name: 'Lighting',
                  loadKind: LoadKind.lighting,
                  loadW: 600,
                  length: Length(15)),
              const ElectricalCircuit(
                  id: 'so',
                  name: 'Sockets',
                  loadKind: LoadKind.socket,
                  loadW: 1200,
                  length: Length(15)),
              ElectricalCircuit(
                  id: 'pu',
                  name: 'Pump P-01',
                  loadKind: LoadKind.pump,
                  motorKw: pumpKw,
                  phases: 1,
                  starterType: StarterType.dol,
                  length: const Length(20)),
            ]),
      ],
    );

void main() {
  test('onSiteSourceFaultA: a 1-phase source is rated on S / U0', () {
    // 10000 / 220 / 0.12 = 378.79 A; the 3-phase basis 120.28 A.
    expect(
        onSiteSourceFaultA(SupplyKind.generator, 10000, singlePhaseU0: 220),
        closeTo(10000 / 220 / 0.12, 1e-9));
    expect(onSiteSourceFaultA(SupplyKind.generator, 10000),
        closeTo(10000 / (math.sqrt(3) * 400) / 0.12, 1e-9));
    // Inverter: 1.5 x S / U0.
    expect(onSiteSourceFaultA(SupplyKind.solar, 10000, singlePhaseU0: 220),
        closeTo(1.5 * 10000 / 220, 1e-9));
    // The PLN transformer path keeps its 3-phase basis.
    expect(onSiteSourceFaultA(SupplyKind.pln, 10000, singlePhaseU0: 220),
        closeTo(10000 / (math.sqrt(3) * 400) / 0.04, 1e-9));
  });

  for (final kw in [0.75, 1.5]) {
    test('(1) standby set, $kw kW pump: no false genset ADS error', () {
      final p = _kiosk(pumpKw: kw);
      final sys = computeSystem(_profile, p);
      final plant = gensetPlantVa(p, sys)!;
      expect(plant, 10000);
      // The old 3-phase 400 V basis (120.3 A) fails the pump's loop; the
      // single-phase alternator's 378.8 A passes it.
      bool? adsAt(double a) => faultStudy(sys, p, _profile,
              originFaultLevel: Current(a))
          .circuits['pu']
          ?.adsOk;
      expect(adsAt(onSiteSourceFaultA(SupplyKind.generator, plant)), isFalse);
      expect(
          adsAt(onSiteSourceFaultA(SupplyKind.generator, plant,
              singlePhaseU0: 220)),
          isNot(isFalse));
      final st = computeAdvancedStudy(_profile, p, sys);
      expect(
          st.warnings.where((w) => w.code == 'ads-disconnection-on-genset'),
          isEmpty);
      expect(st.gensetAdsFailedCircuitIds, isEmpty);
    });

    test('(2) primary genset, $kw kW pump: the printed 10 kVA set governs',
        () {
      final p = _kiosk(kind: SupplyKind.generator, pumpKw: kw);
      final sys = computeSystem(_profile, p);
      expect(onSitePrimaryPlantVa(p, sys), 10000);
      // The old basis — the bare demand on the 3-phase 400 V basis — fails
      // the pump way's loop.
      final oldA = onSiteSourceFaultA(
          SupplyKind.generator, sys.supply.demandVa.voltAmperes);
      expect(oldA, lessThan(60));
      expect(
          faultStudy(sys, p, _profile, originFaultLevel: Current(oldA))
              .circuits['pu']
              ?.adsOk,
          isFalse);
      // The engine's ONE estimate: 10000 / 220 / 0.12 = 378.8 A.
      expect(serviceFaultEstimateFor(p, sys)!.amperes,
          closeTo(10000 / 220 / 0.12, 0.05));
      final st = computeAdvancedStudy(_profile, p, sys);
      expect(st.warnings.where((w) => w.code == 'ads-disconnection'), isEmpty);
      // The one-line prints the same installed set.
      expect(st.powerOneLine, isNotNull);
    });
  }
}
