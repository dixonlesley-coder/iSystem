// Fix round 6 (T9, 2026-11-20) — an MEP-synced way the engineer has not
// measured runs the sync's 10 m allowance (`kDefaultCircuitLength`) PLUS the
// vertical distance from its board's floor (`ElectricalPanel.floorIndex`) to
// the machine's floor (`BuildingLevels.riserLength`, the slab datum) — the
// tower's Lantai 15 relay pumps fed from the Lantai 1 MEP board printed
// "10.0 m". An entered length always wins.
//
// Every reference board stands on its floor (`setReferenceBoardFloors`; the
// MEP board on Lantai 1, index 0). The moved ways, L = 10 + z(machine floor):
//   shophouse (4.0 m storeys) boosters P-02/04/06 on Lantai 3:  10 + 8.0 = 18
//   office (4.0 m) FCU-02 on Lantai 2:                         10 + 4.0 = 14
//   apartment (3.5 m) booster P-02 on Lantai 12:              10 + 38.5 = 48.5
//             split ACs AC-01/02 on Lantai 6:                 10 + 17.5 = 27.5
//   tower (4.0 m) booster P-05 + WH-01 on Lantai 30:          10 + 116 = 126
//             relay pumps P-03 / P-09 / jockey P-04, Lantai 15: 10 + 56 = 66
//             AHU-02 + exhaust fan F-02 on Lantai 16:           10 + 60 = 70
// Voltage drop (sizing.dart `voltageDrop`): dV = k Ib L (R cos + X sin) with
// k = 2 (1-phase, U 231 V) or sqrt 3 (3-phase, U 400 V), R the PUIL copper
// table at 70 C (2.5 mm2 8.87, 4 mm2 5.52, 6 mm2 3.69, 120 mm2 0.184 ohm/km),
// X 0.08 ohm/km; limit 5 % (cumulative with the feeder). Worked:
//   WH-01 (2 kW, cos 1, 1-phase, Ib 8.658 A): on 2.5 mm2 2 x 0.126 x 8.658 x
//     8.87 = 19.35 V = 8.38 %; on 4 mm2 12.04 V = 5.21 % (+ feeder 0.48 % >
//     5 %); on 6 mm2 2 x 0.126 x 8.658 x 3.69 = 8.051 V = 3.49 % -> 6 mm2
//     (was 2.5 mm2 at 10 m: 0.66 %).
//   P-03 (Ib 249.1 A, 120 mm2, unchanged cable): VD scales with L, 0.21 %
//     at 10 m -> 1.41 % at 66 m.
//   P-05 (Ib 2.1 A, 126 m): 2.5 mm2 fails the cumulative limit / grows to
//     4 mm2 (0.54 %).
// The device on P-05, P-04 and AHU-02 / F-02 is now an MCB 6 A (was the
// MCCB 16 A frame): the long run's loop impedance is disconnected by the
// smaller device. The judge-only `enclosure-temp-rise-exceeded` now also
// flags the MEP board (36.4 K > 35 K in the smaller MCB enclosure).
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx_engine/electrical/panel_results.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart' show Length;

import 'reference_drawing_loader.dart';

typedef _Way = (String name, double lengthM, double csa, double cbA);

const Map<String, List<_Way>> _moved = {
  'shophouse': [
    ('Booster set P-02', 18, 2.5, 6),
    ('Booster set P-04', 18, 2.5, 6),
    ('Booster set P-06', 18, 2.5, 6),
  ],
  'office': [('FCU FCU-02', 14, 2.5, 6)],
  'apartment': [
    ('Booster set P-02', 48.5, 2.5, 6),
    ('Split wall AC AC-01', 27.5, 2.5, 6),
    ('Split wall AC AC-02', 27.5, 2.5, 6),
  ],
  'tower': [
    ('Booster set P-05', 126, 4, 6),
    ('Water heater WH-01', 126, 6, 16),
    ('Pump P-03', 66, 120, 250),
    ('Pump P-09', 66, 120, 250),
    ('Pump P-04', 66, 2.5, 6),
    ('AHU AHU-02', 70, 2.5, 6),
    ('Exhaust fan F-02', 70, 2.5, 6),
  ],
};

void main() {
  for (final key in ['house', 'shophouse', 'office', 'apartment', 'tower']) {
    testWidgets('$key: MEP ways run the allowance + the vertical', (t) async {
      final spec = kRefDrawingSpecs.firstWhere((s) => s.key == key);
      final c = ProviderContainer();
      addTearDown(c.dispose);
      await t.runAsync(() => loadRefDrawingSpec(c, spec));
      await t.pumpWidget(UncontrolledProviderScope(
          container: c,
          child: const Directionality(
              textDirection: TextDirection.ltr, child: SizedBox.shrink())));
      await t.pump();
      final r = c.read(electricalResultProvider);
      final mep = r.panels.values.firstWhere((p) => p.name == 'MEP Equipment',
          orElse: () => r.panels.values.first);
      final ways = {for (final w in mep.circuits) w.name: w};
      const profile = PuilProfile();
      for (final (name, l, csa, cb) in _moved[key] ?? const <_Way>[]) {
        final w = ways[name]!;
        expect(w.lengthM, closeTo(l, 1e-9), reason: name);
        expect(w.cable.csaMm2, csa, reason: name);
        expect(w.breaker.ratingA.amperes, cb, reason: name);
        // dV% from the sizing primitive's own formula.
        final cos = _cos(c, mep.panelId, name);
        final sin = math.sqrt(math.max(0, 1 - cos * cos));
        final k = w.threePhase ? math.sqrt(3) : 2.0;
        final u = w.threePhase ? 400.0 : 400 / math.sqrt(3);
        var ib = w.designCurrentExactA ?? w.designCurrent.amperes;
        // A standby way (df 0, Ib 0) is sized and dropped on its duty
        // twin's current (P-09 on P-03's 249.1 A).
        if (ib <= 0 && name == 'Pump P-09') {
          ib = ways['Pump P-03']!.designCurrentExactA ??
              ways['Pump P-03']!.designCurrent.amperes;
        }
        final runs = w.cable.runsPerPhase ?? 1;
        final r70 = profile.conductorResistanceOhmPerKm(csa) / 1000;
        final dv = k * ib * l * (r70 * cos + 0.00008 * sin) / runs;
        expect(w.voltageDrop.dropPercent, closeTo(dv / u * 100, 0.006),
            reason: name);
      }
      // Every other MEP way keeps the 10 m allowance (same floor as the
      // board, or no machine floor).
      for (final w in mep.circuits) {
        if ((_moved[key] ?? const <_Way>[]).any((m) => m.$1 == w.name)) {
          continue;
        }
        if (mep.name != 'MEP Equipment') break;
        expect(w.lengthM, closeTo(10, 1e-9), reason: w.name);
      }
    });
  }

  testWidgets('an entered length always wins', (t) async {
    final spec = kRefDrawingSpecs.firstWhere((s) => s.key == 'tower');
    final c = ProviderContainer();
    addTearDown(c.dispose);
    await t.runAsync(() => loadRefDrawingSpec(c, spec));
    await t.pump();
    final store = c.read(electricalProjectProvider.notifier);
    final mep = c
        .read(electricalProjectProvider)
        .panels
        .firstWhere((p) => p.name == 'MEP Equipment');
    final way = mep.circuits.firstWhere((w) => w.name == 'Pump P-04');
    store.setCircuit(mep.id, way.id, length: const Length(10));
    final r = c.read(electricalResultProvider).panels[mep.id]!;
    expect(r.circuits.firstWhere((w) => w.name == 'Pump P-04').lengthM,
        closeTo(10, 1e-9));
  });
}

double _cos(ProviderContainer c, String panelId, String name) => c
    .read(electricalProjectProvider)
    .panels
    .firstWhere((p) => p.id == panelId)
    .circuits
    .firstWhere((w) => w.name == name)
    .cosPhi;

// ignore: unused_element
ElectricalCircuitResult? _unused;
