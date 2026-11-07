// Round 68 (2026-10-18) — elec-convergence-20-battery-hybrid-inverter-sized-
// on-kw-not-kva: the battery / hybrid inverter is selected on the APPARENT
// power it must deliver, max(demand W, demand VA) — the genset's max(S, P/0.8)
// basis — never the real power alone.
//
// First principles (the probe house, 1ph 230 V, 7700 VA PLN):
//   lighting 500 W @ 0.9 + socket 1500 W @ 0.9 + 2 x AC 1500 W @ 0.75
//   P = 500 + 1500 + 3000 = 5000 W
//   S = 500/0.9 + 1500/0.9 + 3000/0.75 = 555.6 + 1666.7 + 4000 = 6222 VA
//   I = 6222 / 230 = 27.1 A.
// A 5 kW (= 5 kVA at unity PF) inverter delivers 5000 / 230 = 21.7 A — 124 %
// overloaded; the 6.22 kVA need selects the next rung of the kInverterKw
// ladder (8 kW). The battery ENERGY stays on the real power (5 kW x 4 h).
import 'package:mechx_engine/electrical/advanced_study.dart';
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/power_oneline.dart';
import 'package:mechx_engine/electrical/sources.dart';
import 'package:mechx_engine/report/equipment_schedule.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

const _p = PuilProfile();

ElectricalCircuit _way(String id, LoadKind k, double w, double pf) =>
    ElectricalCircuit(
        id: id,
        name: id,
        loadKind: k,
        loadW: w,
        cosPhi: pf,
        phases: 1,
        demandFactor: 1.0,
        cosPhiUserSet: true);

ElectricalProject _house() => ElectricalProject(
      id: 'h',
      name: 'House',
      supplyCapacityVa: const ApparentPower(7700),
      sources: const ElectricalSources(
          solar: SolarSource(panels: 10),
          battery: BatterySource(autonomyHours: 4)),
      panels: [
        ElectricalPanel(
            id: 'DB',
            name: 'DB',
            system: ElectricalSystem.singlePhase,
            voltage: const Voltage(230),
            circuits: [
              _way('L', LoadKind.lighting, 500, 0.9),
              _way('S', LoadKind.socket, 1500, 0.9),
              _way('AC1', LoadKind.hvac, 1500, 0.75),
              _way('AC2', LoadKind.hvac, 1500, 0.75),
            ]),
      ],
    );

void main() {
  test('sizeBattery: the inverter covers max(kW, kVA)', () {
    final kw = sizeBattery(const Power(5000), autonomyHours: 4);
    expect(kw.inverterKw.inKiloWatts, 5, reason: 'kW basis alone');
    final kva = sizeBattery(const Power(5000),
        autonomyHours: 4, apparentLoad: const ApparentPower(6222));
    // 6.222 kVA > the 5 kW rung => the next rung that covers it.
    final rung =
        kInverterKw.firstWhere((k) => k * 1000 >= 6222 - 1e-9).toDouble();
    expect(kva.inverterKw.inKiloWatts, rung);
    expect(rung, 8);
    // Energy is the REAL power: identical bank either way.
    expect(kva.installedKwh.inKilowattHours, kw.installedKwh.inKilowattHours);
    // A VA below the W (a leading / unity load) never shrinks it.
    expect(
        sizeBattery(const Power(5000),
                autonomyHours: 4, apparentLoad: const ApparentPower(4000))
            .inverterKw
            .inKiloWatts,
        5);
  });

  test('the AC-heavy house buys, draws and schedules the 8 kW inverter', () {
    final pr = _house();
    final sys = computeSystem(_p, pr);
    expect(sys.supply.demandW, closeTo(5000, 1));
    expect(sys.supply.demandVa.voltAmperes, closeTo(6222, 2));
    final ds = sizeDistributedSources(pr.sources!,
        demand: sys.supply.demandVa, demandPower: Power(sys.supply.demandW));
    final inv = distributedSourceInverters(ds).single;
    expect(inv.kind, 'hybrid');
    expect(inv.unitKw.inKiloWatts, 8);
    // The inverter's rated current covers the board's 27.1 A.
    expect(inv.unitKw.watts * inv.units / 230,
        greaterThanOrEqualTo(sys.supply.demandVa.voltAmperes / 230));
    final adv = computeAdvancedStudy(_p, pr, sys);
    final line = adv.bom.lines
        .singleWhere((l) => l.description.startsWith('Hybrid inverter'));
    expect(line.description, contains('8 kW'));
    final hinv = adv.powerOneLine!.nodes.singleWhere((n) => n.id == 'hinv');
    expect(hinv.sub, inverterRatingLabel(inv.unitKw, inv.units));
    final rows = buildEquipmentScheduleRows(EquipmentScheduleData(
        projectName: 'H',
        date: '2026-10-18',
        electrical: sys,
        electricalProject: pr));
    expect(rows.singleWhere((r) => r.tag == 'INV-01').duty, contains('8'));
  });
}
