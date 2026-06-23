import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

/// Seed tests for the electrical SI typed quantities (the "E" domain).
/// Expected values are hand-computed from the SI definitions and act as the
/// correctness anchor — the electrical engine builds on these, so they go
/// green first.
void main() {
  group('Current (A)', () {
    test('milliamperes → amperes: 30 mA RCD = 0.030 A', () {
      expect(Current.milliamperes(30).amperes, closeTo(0.030, 1e-12));
    });

    test('kiloamperes → amperes: 16 kA fault = 16000 A', () {
      expect(Current.kiloamperes(16).amperes, closeTo(16000.0, 1e-9));
    });

    test('base constructor stores amperes; getters invert', () {
      const i = Current(250.0); // a 250 A incomer
      expect(i.amperes, 250.0);
      expect(i.inKiloamperes, closeTo(0.25, 1e-12));
      expect(i.inMilliamperes, closeTo(250000.0, 1e-6));
    });

    test('round-trips through both engineering units', () {
      expect(
        Current.milliamperes(Current.kiloamperes(2.5).inMilliamperes).amperes,
        closeTo(2500.0, 1e-9),
      );
    });
  });

  group('Voltage (V)', () {
    test('kilovolts → volts: 20 kV MV supply = 20000 V', () {
      expect(Voltage.kilovolts(20).volts, closeTo(20000.0, 1e-9));
    });

    test('base constructor + getter: 400 V line = 0.4 kV', () {
      const v = Voltage(400.0);
      expect(v.volts, 400.0);
      expect(v.inKilovolts, closeTo(0.4, 1e-12));
    });
  });

  group('ApparentPower (VA) vs active Power (W)', () {
    test('kVA → VA: 200 kVA PLN ceiling = 200000 VA', () {
      expect(
        ApparentPower.kilovoltAmperes(200).voltAmperes,
        closeTo(200000.0, 1e-9),
      );
    });

    test('inKilovoltAmperes inverts', () {
      const s = ApparentPower(160000.0);
      expect(s.inKilovoltAmperes, closeTo(160.0, 1e-12));
    });

    test('active power reuses the existing Power (W) type', () {
      // S = 100 kVA at pf 0.85 → P = 85 kW. Computed by the engine, but the
      // two are distinct dimensions and must not be transposed.
      final s = ApparentPower.kilovoltAmperes(100);
      final p = Power.kiloWatts(s.inKilovoltAmperes * 0.85);
      expect(p.inKiloWatts, closeTo(85.0, 1e-9));
    });
  });

  group('ReactivePower (var)', () {
    test('kilovar → var: 50 kvar bank step = 50000 var', () {
      expect(ReactivePower.kilovar(50).voltAmperesReactive,
          closeTo(50000.0, 1e-9));
    });

    test('inKilovar inverts', () {
      const q = ReactivePower(25000.0);
      expect(q.inKilovar, closeTo(25.0, 1e-12));
    });
  });

  group('Resistance (Ω)', () {
    test('milliohms → ohms: a 35 mΩ loop = 0.035 Ω', () {
      expect(Resistance.milliohms(35).ohms, closeTo(0.035, 1e-12));
    });

    test('inMilliohms inverts', () {
      const r = Resistance(0.8); // Zs ≈ 0.8 Ω
      expect(r.inMilliohms, closeTo(800.0, 1e-9));
    });
  });

  group('Energy (J)', () {
    test('kWh → J: 1 kWh = 3.6 MJ', () {
      expect(Energy.kilowattHours(1).joules, closeTo(3.6e6, 1.0));
    });

    test('inKilowattHours inverts: 7.2 MJ = 2 kWh', () {
      const e = Energy(7.2e6);
      expect(e.inKilowattHours, closeTo(2.0, 1e-12));
    });
  });
}
