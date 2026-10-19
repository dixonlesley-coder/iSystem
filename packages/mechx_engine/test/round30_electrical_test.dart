/// Round 30 electrical seed suite (2026-10-18):
///   * regression-dual-tx-declared-capacity-doubled — a declared PLN
///     connection capacity is the TOTAL connection: a dual service splits it
///     across its two sections, and above the ladder top it is n × 2500 kVA.
library;

import 'dart:math' as math;

import 'package:mechx_engine/electrical/advanced_study.dart';
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/fault.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/supply_design.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

const p = PuilProfile();

ElectricalProject _project({
  double? capVa,
  bool dual = false,
  double loadW = 680000,
  ApparentPower? tx,
}) =>
    ElectricalProject(
      id: 'pr',
      name: 'Hotel',
      dualTransformer: dual,
      transformerKva: tx,
      supplyCapacityVa: capVa == null ? null : ApparentPower(capVa),
      panels: [
        ElectricalPanel(
          id: 'MDP',
          name: 'MDP',
          system: ElectricalSystem.threePhase,
          voltage: const Voltage(400),
          circuits: [
            ElectricalCircuit(
              id: 'l',
              name: 'Load',
              loadKind: LoadKind.lighting,
              loadW: loadW,
              cosPhi: 0.85,
              phases: 3,
              length: const Length(10),
            ),
          ],
        ),
      ],
    );

void main() {
  group('declared capacity on a dual-transformer service', () {
    test('1 000 kVA daya, dual, 800 kVA demand ⇒ 2 × 500 kVA (one section '
        'carries half the connection), never 2 × 1000', () {
      final pr = _project(capVa: 1000000, dual: true);
      // Per section: 1000 kVA / 2 = 500 kVA ⇒ the 500 kVA rung.
      final d = declaredServiceTransformer(pr)!;
      expect(d.kva.inKilovoltAmperes, 500);
      expect(d.units, 2);
      final sys = computeSystem(p, pr);
      final t = serviceTransformer(pr, sys.supply.demandVa)!;
      expect(t.kva, 500);
      expect(t.units, 2);
      expect(powerOneLineUtilitySub(pr, sys.supply.demandVa),
          'MV via TX 2 x 500 kVA');
      final adv = computeAdvancedStudy(p, pr, sys);
      expect(adv.supply.transformerKva, 500);
      expect(adv.supply.units, 2);
      // Loading: each unit carries ~half the demand. 500 × 0.8 = 400 kVA
      // against demand / 2 — compare on the SAME per-unit basis.
      final half = sys.supply.demandVa.inKilovoltAmperes / 2;
      expect(adv.supply.declaredBelowDemand, 500 * 0.8 < half - 1e-9);
      // Fault: one section's unit (coupler N.O.), never 2 × 1000 kVA:
      // 500e3 / (√3 · 400 · 0.04) = 18 042.2 A, floored at the study unit
      // and 16 kA.
      final isc = estimatedServiceFaultLevelA(pr,
              demand: sys.supply.demandVa)!
          .amperes;
      expect(isc, lessThan(1000000 / (math.sqrt(3) * 400 * 0.04)));
    });

    test('above the ladder top: 3 465 kVA single service ⇒ 2 × 2500 kVA '
        '(never one non-standard 3465 kVA unit)', () {
      final pr = _project(capVa: 3465000, loadW: 2000000);
      final d = declaredServiceTransformer(pr)!;
      expect(d.kva.inKilovoltAmperes, 2500);
      expect(d.units, 2);
    });

    test('an explicit transformerKva stays per-unit (byte-identical)', () {
      final pr = _project(
          dual: true, tx: ApparentPower.kilovoltAmperes(630));
      final d = declaredServiceTransformer(pr)!;
      expect(d.kva.inKilovoltAmperes, 630);
      expect(d.units, 2);
      expect(declaredServiceTransformer(
              _project(tx: ApparentPower.kilovoltAmperes(630)))!
          .units, 1);
    });

    test('property: kVA × units covers the daya, every unit is a ladder '
        'rating, a dual service has an even count, and no smaller rung '
        'covers one section (seeded)', () {
      final rnd = math.Random(30);
      for (var i = 0; i < 120; i++) {
        final cap = plnLvServiceCeilingVa + 1 + rnd.nextDouble() * 9e6;
        final dual = rnd.nextBool();
        final d = declaredServiceTransformer(_project(capVa: cap, dual: dual))!;
        final kva = d.kva.inKilovoltAmperes;
        expect(transformerKvaLadder, contains(kva), reason: '$cap');
        expect(kva * d.units, greaterThanOrEqualTo(cap / 1000 - 1e-6),
            reason: '$cap dual=$dual');
        if (dual) expect(d.units.isEven, isTrue, reason: '$cap');
        final sections = dual ? 2 : 1;
        if (d.units == sections) {
          for (final k in transformerKvaLadder.where((k) => k < kva)) {
            expect(k, lessThan(cap / 1000 / sections), reason: '$cap');
          }
        } else {
          expect(kva, transformerKvaLadder.last);
          // n - 1 top units per section would not cover it.
          expect((d.units ~/ sections - 1) * kva,
              lessThan(cap / 1000 / sections), reason: '$cap');
        }
      }
    });
  });

  group('SPD lines carry their connection', () {
    test('3φ MDP feeding a 1φ LP: two SPD lines, 3+N and 1+N, never merged',
        () {
      final pr = ElectricalProject(
        id: 'pr',
        name: 'SPD',
        panels: [
          ElectricalPanel(
            id: 'MDP',
            name: 'MDP',
            system: ElectricalSystem.threePhase,
            voltage: const Voltage(400),
            circuits: [
              ElectricalCircuit(
                  id: 'm',
                  name: 'Motor',
                  loadKind: LoadKind.motor,
                  loadW: 15000,
                  motorKw: 11,
                  phases: 3,
                  cosPhi: 0.85,
                  length: const Length(20)),
              // A 40 m feeder: past the secondary-SPD distance, so LP-1
              // recommends its own device.
              const ElectricalCircuit(
                  id: 'f',
                  name: 'LP feed',
                  feedsPanelId: 'LP',
                  length: Length(40)),
            ],
          ),
          ElectricalPanel(
            id: 'LP',
            name: 'LP-1',
            system: ElectricalSystem.singlePhase,
            voltage: const Voltage(230),
            circuits: [
              ElectricalCircuit(
                  id: 'l',
                  name: 'Lights',
                  loadKind: LoadKind.lighting,
                  loadW: 2000,
                  length: const Length(15)),
            ],
          ),
        ],
      );
      final sys = computeSystem(p, pr);
      final adv = computeAdvancedStudy(p, pr, sys);
      final spd = [
        for (final l in adv.bom.lines)
          if ((l.priceKey ?? '').startsWith('elec:spd:')) l,
      ];
      final recommended = adv.spd.values.where((r) => r.recommended).length;
      expect(spd.fold<double>(0, (a, l) => a + l.qty), recommended);
      for (final l in spd) {
        final k = l.priceKey!;
        expect(k.endsWith(':3+n') || k.endsWith(':1+n') ||
            k.endsWith(':3+1') || k.endsWith(':1+1'), isTrue, reason: k);
        // The description names the same connection the key carries.
        final conn = k.split(':').last.toUpperCase();
        expect(l.description, contains(conn), reason: k);
      }
      // Both boards recommend a type-2 device at the same Uc (the merge the
      // finding found); the keys now differ by the connection.
      expect(adv.spd['MDP']!.recommended, isTrue);
      expect(adv.spd['LP']!.recommended, isTrue);
      expect(spd.map((l) => l.priceKey).toSet().length, 2);
      expect(spd.any((l) => l.priceKey!.endsWith(':3+n')), isTrue);
      expect(spd.any((l) => l.priceKey!.endsWith(':1+n')), isTrue);
    });
  });
}
