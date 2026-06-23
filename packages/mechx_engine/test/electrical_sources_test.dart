import 'package:mechx_engine/electrical/power_oneline.dart';
import 'package:mechx_engine/electrical/sources.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

/// Seed tests for the electrical energy-sources domain + power one-line.
/// Expected values are hand-derived from first principles (see the arithmetic
/// comments) — the tests are the spec.
void main() {
  group('sizeGenerator', () {
    test('150 kVA backup → next ladder rung 150 kVA (standby, exact)', () {
      // backup 150 kVA, standby (no headroom) → required 150 → ladder rung 150.
      final g = sizeGenerator(ApparentPower.kilovoltAmperes(150));
      expect(g.ratingKva.inKilovoltAmperes, 150);
      expect(g.backupKva.inKilovoltAmperes, 150);
      expect(g.mode, GeneratorMode.standby);
      expect(g.transfer, GeneratorTransfer.ats);
    });

    test('120 kVA backup → ladder snaps up to 125 kVA', () {
      // 120 kVA is between rungs 100 and 125 → smallest ≥ 120 is 125.
      final g = sizeGenerator(ApparentPower.kilovoltAmperes(120));
      expect(g.ratingKva.inKilovoltAmperes, 125);
    });

    test('prime duty adds 25% headroom before the ladder', () {
      // 100 kVA backup, prime → required 100·1.25 = 125 → rung 125.
      final g = sizeGenerator(ApparentPower.kilovoltAmperes(100),
          mode: GeneratorMode.prime);
      expect(g.ratingKva.inKilovoltAmperes, 125);
    });

    test('fuel + day-tank: 150 kVA → 30 l/h, 240 L (round up to 10 L)', () {
      // loadKw = 150·0.8 = 120 kW; fuel = 120·0.25 = 30 l/h.
      // tank = ceil(30·8 / 10)·10 = ceil(24)·10 = 240 L; runtime 8 h.
      final g = sizeGenerator(ApparentPower.kilovoltAmperes(150));
      expect(g.fuelLph, 30);
      expect(g.dayTankL, 240);
      expect(g.runtimeHours, 8);
    });

    test('a forced kVA is honoured verbatim (no ladder snap)', () {
      // 120 kVA backup but the user forces a 200 kVA unit.
      final g = sizeGenerator(
        ApparentPower.kilovoltAmperes(120),
        forcedKva: ApparentPower.kilovoltAmperes(200),
      );
      expect(g.ratingKva.inKilovoltAmperes, 200);
      expect(g.backupKva.inKilovoltAmperes, 120);
    });
  });

  group('assessGensetStart (motor-start voltage dip)', () {
    test('one 30 kW DOL motor on a 150 kVA genset is acceptable', () {
      // running kVA = 30/0.8 = 37.5; DOL ×6 → startKva = 225.
      // z = 225·0.15 = 33.75; dip = 100·33.75/(150+33.75)
      //   = 100·33.75/183.75 = 18.367... → 18.37%. ≤ 25% → acceptable.
      final r = assessGensetStart(
        ApparentPower.kilovoltAmperes(150),
        motors: const [GensetMotor(name: 'P-1', shaftPower: Power(30000))],
      );
      expect(r.startingKva.inKilovoltAmperes, closeTo(225, 1e-6));
      expect(r.estimatedDipPct, closeTo(18.37, 0.01));
      expect(r.acceptable, isTrue);
    });

    test('the same motor on a 65 kVA genset exceeds the 25% limit', () {
      // z = 33.75; dip = 100·33.75/(65+33.75) = 3375/98.75 = 34.18%. > 25%.
      // recommendedMin = z·(100−25)/25 = 33.75·3 = 101.25 kVA.
      final r = assessGensetStart(
        ApparentPower.kilovoltAmperes(65),
        motors: const [GensetMotor(name: 'P-1', shaftPower: Power(30000))],
      );
      expect(r.estimatedDipPct, closeTo(34.18, 0.01));
      expect(r.acceptable, isFalse);
      expect(r.recommendedMinGensetKva.inKilovoltAmperes, closeTo(101.25, 0.01));
    });

    test('no motors → trivially acceptable, zero dip', () {
      final r = assessGensetStart(ApparentPower.kilovoltAmperes(100));
      expect(r.acceptable, isTrue);
      expect(r.estimatedDipPct, 0);
      expect(r.startingKva.inKilovoltAmperes, 0);
    });

    test('the LARGEST starting motor limits (star-delta vs DOL)', () {
      // 30 kW DOL: startKva = 37.5·6 = 225.
      // 45 kW star-delta (×2): startKva = (45/0.8)·2 = 56.25·2 = 112.5.
      // The 30 kW DOL motor wins (225 > 112.5) — reduced-inrush starter helps.
      final r = assessGensetStart(
        ApparentPower.kilovoltAmperes(200),
        motors: const [
          GensetMotor(name: 'DOL-30', shaftPower: Power(30000)),
          GensetMotor(
              name: 'SD-45', shaftPower: Power(45000), starterType: 'STAR_DELTA'),
        ],
      );
      expect(r.limitingMotorName, 'DOL-30');
      expect(r.startingKva.inKilovoltAmperes, closeTo(225, 1e-6));
    });
  });

  group('sizeSolar', () {
    test('20 × 550 Wp → 11 kWp array; inverter, strings hand-derived', () {
      // arrayKwp = 20·550/1000 = 11 kWp.
      // inverter target = 11/1.2 = 9.166… kW → smallest rung ≥ that = 10 kW.
      // string size: maxByMppt = floor(850/41.7) = 20;
      //   maxByVoltage = floor(1000/(49.5·1.15)) = floor(1000/56.925) = 17;
      //   minByMppt = ceil(200/41.7) = ceil(4.796) = 5;
      //   stringSize = max(5, min(20,17,20)) = 17.
      //   strings = ceil(20/17) = 2.
      // dailyKwh = 11·4.8·0.8 = 42.24 → 42.2 (1 dp).
      final s = sizeSolar(panelWp: 550, panels: 20);
      expect(s.arrayKwp.inKiloWatts, closeTo(11, 1e-9));
      expect(s.inverterKw.inKiloWatts, 10);
      expect(s.stringSize, 17);
      expect(s.strings, 2);
      expect(s.dailyKwh.inKilowattHours, closeTo(42.2, 1e-9));
      expect(s.panelCount, 20);
    });

    test('larger DC/AC ratio shrinks the inverter', () {
      // 30·550 = 16.5 kWp; ratio 1.5 → 11 kW → rung 15 kW (rungs …10,15…).
      final s = sizeSolar(panelWp: 550, panels: 30, dcAcRatio: 1.5);
      expect(s.arrayKwp.inKiloWatts, closeTo(16.5, 1e-9));
      expect(s.inverterKw.inKiloWatts, 15);
    });
  });

  group('sizeBattery', () {
    test('10 kW for 4 h, LiFePO4 → required kWh + module count', () {
      // required = 10·4 / (0.9·0.95) = 40 / 0.855 = 46.78… kWh → 46.8 (1 dp).
      // modules = ceil(46.78.../5.12) = ceil(9.137) = 10 → installed 51.2 kWh.
      // usable = 51.2·0.9 = 46.08 kWh.
      // inverter: load 10 kW → smallest rung ≥ 10 = 10 kW.
      final b = sizeBattery(Power.kiloWatts(10), autonomyHours: 4);
      expect(b.requiredKwh.inKilowattHours, closeTo(46.8, 1e-9));
      expect(b.moduleCount, 10);
      expect(b.installedKwh.inKilowattHours, closeTo(51.2, 1e-9));
      expect(b.usableKwh.inKilowattHours, closeTo(46.08, 1e-9));
      expect(b.inverterKw.inKiloWatts, 10);
      expect(b.chemistry, BatteryChemistry.lifepo4);
    });

    test('lead-acid DoD 0.5 roughly doubles the energy vs LiFePO4', () {
      // required = 5·2 / (0.5·0.95) = 10 / 0.475 = 21.05… kWh.
      final b = sizeBattery(Power.kiloWatts(5),
          autonomyHours: 2, chemistry: BatteryChemistry.leadAcid);
      expect(b.requiredKwh.inKilowattHours, closeTo(21.1, 1e-9));
    });
  });

  group('buildPowerOneLine', () {
    test('PV + battery → ONE hybrid inverter, anti-island interlock', () {
      const sources = ElectricalSources(
        solar: SolarSource(panels: 20),
        battery: BatterySource(autonomyHours: 4),
      );
      final ol = buildPowerOneLine(sources,
          demand: ApparentPower.kilovoltAmperes(50));

      // Buses: the main LV bus only (no genset → no essential bus).
      expect(ol.nodeOfKind(PowerNodeKind.bus)?.id, 'bus');
      expect(ol.hasEssentialBus, isFalse);
      // Hybrid topology: a single hybrid inverter, no per-source inverters.
      expect(ol.nodeOfKind(PowerNodeKind.hybridInverter), isNotNull);
      expect(ol.nodeOfKind(PowerNodeKind.pvInverter), isNull);
      expect(ol.nodeOfKind(PowerNodeKind.batteryInverter), isNull);
      expect(ol.nodeOfKind(PowerNodeKind.pv), isNotNull);
      expect(ol.nodeOfKind(PowerNodeKind.battery), isNotNull);
      // Anti-islanding interlock is present.
      expect(ol.interlocks.any((i) => i.id == 'il-hybrid'), isTrue);
    });

    test('genset (full backup) → ATS + mains↔genset mutual-exclusion', () {
      const sources = ElectricalSources(generator: GeneratorSource());
      final ol = buildPowerOneLine(sources,
          demand: ApparentPower.kilovoltAmperes(150));

      expect(ol.nodeOfKind(PowerNodeKind.generator), isNotNull);
      final ats = ol.nodeOfKind(PowerNodeKind.ats);
      expect(ats?.label, 'ATS');
      // Full backup (fraction 1.0) → no essential bus split.
      expect(ol.hasEssentialBus, isFalse);
      // Two mains↔genset interlocks (mechanical + electrical), both exclusion.
      final il = ol.interlocks
          .where((i) => i.aId == 'utility' && i.bId == 'gen')
          .toList();
      expect(il.length, 2);
      expect(
        il.every((i) => i.relation == PowerInterlockRelation.mutualExclusion),
        isTrue,
      );
    });

    test('partial-backup genset + battery → essential + critical (UPS) buses', () {
      const sources = ElectricalSources(
        generator: GeneratorSource(backupFraction: 0.5),
        battery: BatterySource(autonomyHours: 2),
      );
      final ol = buildPowerOneLine(sources,
          demand: ApparentPower.kilovoltAmperes(200));

      // Not hybrid (no PV) → separate battery inverter; essential split applies.
      expect(ol.hasEssentialBus, isTrue);
      expect(ol.hasCriticalBus, isTrue);
      expect(ol.nodeOfKind(PowerNodeKind.batteryInverter), isNotNull);
      // The UPS bus rides the battery — a sequence interlock to the critical bus.
      expect(
        ol.interlocks.any(
            (i) => i.id == 'il-batt' && i.relation == PowerInterlockRelation.sequence),
        isTrue,
      );
    });

    test('an over-limit motor-start dip is tagged on the generator node', () {
      // A small genset with a big DOL motor: the dip exceeds 25% and is flagged.
      const sources = ElectricalSources(generator: GeneratorSource());
      final ol = buildPowerOneLine(
        sources,
        demand: ApparentPower.kilovoltAmperes(40),
        motors: const [GensetMotor(shaftPower: Power(30000))],
      );
      final gen = ol.nodeOfKind(PowerNodeKind.generator);
      // demand 40 kVA → 40 kVA backup → ladder rung 40 kVA; 30 kW DOL dips far
      // beyond 25%, so the node carries an "over" tag.
      expect(gen?.sub, contains('over'));
    });

    test('manual transfer genset → COS node + manual interlock note', () {
      const sources = ElectricalSources(
        generator: GeneratorSource(transfer: GeneratorTransfer.manual),
      );
      final ol = buildPowerOneLine(sources,
          demand: ApparentPower.kilovoltAmperes(100));
      expect(ol.nodeOfKind(PowerNodeKind.ats)?.label, 'COS');
      expect(
        ol.interlocks.any((i) => i.note.contains('break-before-make')),
        isTrue,
      );
    });

    test('no sources → just the utility feeding the bus', () {
      const sources = ElectricalSources();
      final ol = buildPowerOneLine(sources,
          demand: ApparentPower.kilovoltAmperes(40));
      expect(ol.nodeOfKind(PowerNodeKind.generator), isNull);
      expect(ol.nodeOfKind(PowerNodeKind.pv), isNull);
      expect(ol.nodeOfKind(PowerNodeKind.battery), isNull);
      expect(ol.interlocks, isEmpty);
      // The utility feeds the main bus directly (a 'mains' edge).
      expect(
        ol.edges.any((e) => e.from == 'utility' && e.to == 'bus'),
        isTrue,
      );
    });
  });
}
