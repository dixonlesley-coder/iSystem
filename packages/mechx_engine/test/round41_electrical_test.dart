// Round 41 (2026-10-18) — electrical judges, control gear, BOM honesty.
//
// Each group pins one confirmed finding with a first-principles derivation;
// where a counterexample generalises it is a seeded property.
import 'dart:math' as math;

import 'package:mechx_engine/electrical/advanced_bom.dart';
import 'package:mechx_engine/electrical/advanced_study.dart';
import 'package:mechx_engine/electrical/bom.dart';
import 'package:mechx_engine/electrical/catalog.dart';
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/containment.dart' show conduitFillSingle;
import 'package:mechx_engine/electrical/control/contactor.dart';
import 'package:mechx_engine/electrical/control/motor_flc.dart';
import 'package:mechx_engine/electrical/control/starter.dart';
import 'package:mechx_engine/electrical/costing.dart';
import 'package:mechx_engine/electrical/headroom.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/panel_results.dart';
import 'package:mechx_engine/electrical/power_factor.dart';
import 'package:mechx_engine/electrical/results.dart';
import 'package:mechx_engine/report/electrical_sld_drawing.dart';
import 'package:mechx_engine/report/equipment_schedule.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

const _p = PuilProfile();

ElectricalCircuit _heater(String id, double w, {String? name}) =>
    ElectricalCircuit(
      id: id,
      name: name ?? id,
      loadKind: LoadKind.heating,
      loadW: w,
      cosPhi: 1.0,
      phases: 3,
      length: const Length(10),
    );

ElectricalCircuitResult _way(
        ElectricalSystemResult s, String panel, String c) =>
    s.panels[panel]!.circuits.firstWhere((r) => r.circuitId == c);

double _flcA(double kva) => kva * 1000 / (math.sqrt(3) * 400);

Iterable<String> _flcWarn(AdvancedStudy a) => a.warnings
    .where((w) => w.code == 'root-incomer-exceeds-transformer-flc')
    .map((w) => w.panelId ?? '');

void main() {
  // ── 1. the FLC judge never condemns the engine's own rung ──────────────
  group('regression-incomer-above-tx-flc-fires-on-engine-own-rung', () {
    test('630 kVA declared daya: the floored 1000 A incomer is not flagged',
        () {
      // Service floor: 630 000 / (sqrt(3) x 400) = 909.3 A -> the 1000 A
      // rung. The declared daya above the LV ceiling is a 630 kVA TM
      // service; its FLC is the same 909.3 A, whose own rung is 1000 A.
      final project = ElectricalProject(
        id: 'p',
        name: 'P',
        supplyCapacityVa: const ApparentPower(630000),
        panels: [
          ElectricalPanel(
              id: 'MDP', name: 'MDP', circuits: [_heater('h', 240000)]),
        ],
      );
      final sys = computeSystem(_p, project);
      final adv = computeAdvancedStudy(_p, project, sys);
      expect(_flcA(630), closeTo(909.3, 0.1));
      expect(sys.panels['MDP']!.incomer.breaker.ratingA.amperes, 1000);
      expect(incomerRungForFlcA(_p, _flcA(630)), 1000);
      expect(_flcWarn(adv), isEmpty);
    });

    test('a 1250 A incomer on a 630 kVA unit IS flagged', () {
      // 450 kW x 1.6 (60 % spare) = 720 kVA -> 1039 A -> the 1250 A rung,
      // above the 1000 A rung of the 909 A FLC.
      final project = ElectricalProject(
        id: 'p',
        name: 'P',
        transformerKva: const ApparentPower(630000),
        panels: [
          ElectricalPanel(
            id: 'MDP',
            name: 'MDP',
            headroom: const HeadroomSpec(sparePercentage: 60),
            circuits: [_heater('h', 450000)],
          ),
        ],
      );
      final sys = computeSystem(_p, project);
      final adv = computeAdvancedStudy(_p, project, sys);
      expect(sys.panels['MDP']!.incomer.breaker.ratingA.amperes, 1250);
      expect(_flcWarn(adv), ['MDP']);
    });

    test('dual 2 x 630 kVA, single root: judged on ONE section', () {
      // 700 kW -> 1010 A -> 1250 A incomer; one section's FLC 909 A (rung
      // 1000 A) -> flagged. The pre-Round-41 basis (2 units, 1818 A) let it
      // pass while `transformer-below-demand` judged the same board on ONE
      // section.
      final project = ElectricalProject(
        id: 'p',
        name: 'P',
        dualTransformer: true,
        transformerKva: const ApparentPower(630000),
        panels: [
          ElectricalPanel(
              id: 'MDP', name: 'MDP', circuits: [_heater('h', 700000)]),
        ],
      );
      final sys = computeSystem(_p, project);
      final adv = computeAdvancedStudy(_p, project, sys);
      expect(sys.panels['MDP']!.incomer.breaker.ratingA.amperes, 1250);
      expect(_flcWarn(adv), ['MDP']);
    });

    test('seeded property: a declared unit carrying <= its nameplate never '
        'flags its own root incomer', () {
      const ladder = [160.0, 250, 400, 630, 800, 1000, 1250, 1600, 2000];
      final rng = math.Random(41);
      for (var t = 0; t < 60; t++) {
        final kva = ladder[rng.nextInt(ladder.length)];
        final frac = 0.1 + 0.9 * rng.nextDouble();
        final project = ElectricalProject(
          id: 'p',
          name: 'P',
          transformerKva: ApparentPower(kva * 1000),
          panels: [
            ElectricalPanel(
                id: 'MDP',
                name: 'MDP',
                circuits: [_heater('h', kva * 1000 * frac)]),
          ],
        );
        final sys = computeSystem(_p, project);
        final adv = computeAdvancedStudy(_p, project, sys);
        // demand <= nameplate => Ib <= FLC => the incomer rung <= the FLC's.
        expect(_flcWarn(adv), isEmpty, reason: '$kva kVA at $frac');
      }
    });
  });

  // ── 2. a spare never carries a machine's load ───────────────────────────
  group('regression-rekind-bypasses-mep-machine-lock (engine)', () {
    test('a spare way with a leftover FLA and W adds 0 W and 0 A', () {
      ElectricalProject withWay(ElectricalCircuit c) => ElectricalProject(
            id: 'p',
            name: 'P',
            panels: [
              ElectricalPanel(id: 'MDP', name: 'MDP', circuits: [
                _heater('h', 5000),
                c,
              ]),
            ],
          );
      const ghost = ElectricalCircuit(
        id: 's',
        name: 'Ex pump',
        loadKind: LoadKind.spare,
        loadW: 17045.5,
        flaOverrideA: Current(30.5),
        phases: 3,
        length: Length(10),
      );
      const plain = ElectricalCircuit(
        id: 's',
        name: 'Ex pump',
        loadKind: LoadKind.spare,
        phases: 3,
        length: Length(10),
      );
      expect(circuitConnectedW(ghost), 0);
      expect(circuitUndiversifiedW(ghost), 0);
      final a = computeSystem(_p, withWay(ghost));
      final b = computeSystem(_p, withWay(plain));
      expect(_way(a, 'MDP', 's').designCurrent.amperes, 0);
      expect(_way(a, 'MDP', 's').breaker.ratingA.amperes,
          _way(b, 'MDP', 's').breaker.ratingA.amperes);
      expect(a.panels['MDP']!.demandW, b.panels['MDP']!.demandW);
      expect(a.supply.demandW, closeTo(5000, 1e-6));
    });
  });

  // ── 3. fire-duty starters never trip on overload ────────────────────────
  group('electrical-sim-6-fire-pump-control-assembly-buys-tripping-overload',
      () {
    test('applyStarterTemplate(fireDuty) swaps every overload for an alarm',
        () {
      for (final st in StarterType.values) {
        final a = applyStarterTemplate(
            circuitId: 'fp', starterType: st, motorKw: 90, fireDuty: true);
        final ol = a.devices
            .where((d) => d.category == DeviceCategory.overloadRelay)
            .toList();
        for (final d in ol) {
          expect(d.tripDisabled, isTrue, reason: '$st');
          expect(d.role, 'overload-alarm');
          expect(d.rating, isNot(contains('class')));
          expect(d.rating, contains('no trip'));
        }
        // Without fire duty every overload trips (byte-identical rating).
        final n = applyStarterTemplate(
            circuitId: 'fp', starterType: st, motorKw: 90);
        expect(
            n.devices
                .where((d) => d.category == DeviceCategory.overloadRelay)
                .every((d) => !d.tripDisabled),
            isTrue);
        expect(ol.length,
            n.devices.where((d) => d.category == DeviceCategory.overloadRelay).length);
      }
    });

    test('a life-safety pump way: no class-10 line in the BOM', () {
      const project = ElectricalProject(
        id: 'p',
        name: 'P',
        panels: [
          ElectricalPanel(id: 'LS', name: 'LS', circuits: [
            const ElectricalCircuit(
              id: 'fp',
              name: 'Fire pump',
              loadKind: LoadKind.pump,
              motorKw: 90,
              lifeSafety: true,
              starterType: StarterType.starDelta,
              cableType: 'FRC',
              phases: 3,
              length: Length(20),
            ),
            const ElectricalCircuit(
              id: 'cw',
              name: 'Chiller pump',
              loadKind: LoadKind.pump,
              motorKw: 30,
              starterType: StarterType.starDelta,
              phases: 3,
              length: Length(20),
            ),
          ]),
        ],
      );
      final sys = computeSystem(_p, project);
      final adv = computeAdvancedStudy(_p, project, sys);
      final fp = adv.controlAssemblies['fp']!;
      expect(
          fp.devices.any((d) =>
              d.category == DeviceCategory.overloadRelay && !d.tripDisabled),
          isFalse);
      final fpLines =
          adv.bom.lines.where((l) => l.description.contains('Fire pump'));
      expect(fpLines.any((l) => l.description.contains('class 10')), isFalse);
      expect(
          adv.bom.lines.any((l) =>
              l.description.startsWith('overload-alarm alarm only, no trip')),
          isTrue);
      // The non-fire pump keeps its tripping class-10 overload.
      expect(
          adv.bom.lines.any((l) =>
              l.description.startsWith('overload set') &&
              l.description.contains('class 10')),
          isTrue);
    });
  });

  // ── 4. star-delta contactors on winding current ─────────────────────────
  group('electrical-sim-6-star-delta-contactors-sized-at-full-flc', () {
    test('150 kW: main/delta on FLC x 0.58, star on FLC / 3', () {
      final flc = motorFlc(150).amperes;
      final a = applyStarterTemplate(
          circuitId: 'ch', starterType: StarterType.starDelta, motorKw: 150);
      ControlDevice dev(String role) =>
          a.devices.firstWhere((d) => d.role == role);
      for (final r in const ['main-contactor', 'delta-contactor']) {
        // target = FLC x 0.58 (the delta-leg overload's own basis).
        expect(dev(r).targetRatingA!.amperes,
            closeTo((flc * starDeltaWindingFactor * 10).round() / 10, 1e-9));
        expect(dev(r).rating, startsWith('185 A AC-3'));
      }
      expect(dev('star-contactor').targetRatingA!.amperes,
          closeTo((flc / 3 * 10).round() / 10, 1e-9));
      expect(dev('star-contactor').rating, startsWith('95 A AC-3'));
      // The overload stays at FLC x 0.58 in the delta leg.
      expect(dev('overload').rating, contains('delta leg'));
    });

    test('seeded property: main/delta frame >= 0.58 FLC, star >= FLC / 3, '
        'and never larger than the DOL frame', () {
      final rng = math.Random(4141);
      for (var t = 0; t < 80; t++) {
        final kw = 5.5 + rng.nextDouble() * 150;
        final flc = motorFlc(kw).amperes;
        final a = applyStarterTemplate(
            circuitId: 'x', starterType: StarterType.starDelta, motorKw: kw);
        final dol = selectContactor(Current(flc)).ac3A;
        for (final d in a.devices
            .where((d) => d.category == DeviceCategory.contactor)) {
          final frame = double.parse(d.rating!.split(' ').first);
          final need = d.role == 'star-contactor'
              ? flc / 3
              : flc * starDeltaWindingFactor;
          expect(frame + 1e-9, greaterThanOrEqualTo(need), reason: '$kw');
          expect(frame, lessThanOrEqualTo(dol), reason: '$kw');
        }
      }
    });
  });

  // ── 5. star-delta motor leads ───────────────────────────────────────────
  group('electrical-sim-6-star-delta-motor-has-one-cable-not-six-leads', () {
    const project = ElectricalProject(
      id: 'p',
      name: 'P',
      panels: [
        ElectricalPanel(id: 'MDP', name: 'MDP', circuits: [
          const ElectricalCircuit(
            id: 'ch',
            name: 'Chiller',
            loadKind: LoadKind.motor,
            motorKw: 150,
            starterType: StarterType.starDelta,
            cableType: 'NYY',
            phases: 3,
            length: Length(55),
          ),
          const ElectricalCircuit(
            id: 'd',
            name: 'DOL pump',
            loadKind: LoadKind.pump,
            motorKw: 15,
            starterType: StarterType.dol,
            phases: 3,
            length: Length(30),
          ),
        ]),
      ],
    );
    final sys = computeSystem(_p, project);
    final ch = _way(sys, 'MDP', 'ch');

    test('one lead cable sized on Ib / sqrt3, smaller than the supply', () {
      final leads = ch.motorLeads!;
      // The lead carries the winding current: Iz >= 1.25 x Ib/sqrt3.
      final leadIb = ch.runCurrentA.amperes / math.sqrt(3);
      expect(leads.deratedIz.amperes * (leads.runsPerPhase ?? 1),
          greaterThanOrEqualTo(_p.continuousLoadFactor.value * leadIb - 0.5));
      expect(leads.csaMm2, lessThan(ch.cable.csaMm2));
      expect(_way(sys, 'MDP', 'd').motorLeads, isNull);
    });

    test('BOM takes off 2 x run length of the lead cable', () {
      final bom = buildBom(sys);
      final lead = bom.lines
          .where((l) =>
              l.category == PartCategory.cable &&
              l.description.contains('motor leads'))
          .toList();
      expect(lead, hasLength(1));
      expect(lead.single.qty, 2 * 55);
      expect(lead.single.runs, 2);
      // Re-derived Round 42 — the starter sits in the board: the supply
      // cable is the INTERNAL breaker -> starter link, taken off at
      // kStarDeltaInternalWiringM (2 m), never a second 55 m field run.
      final cables = bom.lines
          .where((l) =>
              l.category == PartCategory.cable &&
              !l.description.contains('motor leads'))
          .toList();
      // The chiller's supply (internal) + the DOL pump's 30 m field run.
      expect(cables, hasLength(2));
      final supply =
          cables.where((l) => l.description.contains('internal')).toList();
      expect(supply, hasLength(1));
      expect(supply.single.qty, kStarDeltaInternalWiringM);
      expect(cables.where((l) => l.qty == 55), isEmpty);
    });

    test('the schedule PENGHANTAR prints the leads token', () {
      final sheet = buildElectricalSld(project: project, result: sys);
      final texts = sheet.prims.whereType<SldLabel>().map((l) => l.text);
      expect(texts.any((t) => t.contains('leads 2x(NYY')), isTrue);
    });
  });

  // ── 6. a part that declares no kA is never bought at a specified kA ─────
  group('elec-report-bom-2-undeclared-ka-part-bought-at-specified-ka', () {
    test('seeded property over the catalogue: a null-kA breaker is never '
        'matched when a kA is specified', () {
      final parts = fullCatalog();
      final nullKa = parts
          .where((p) =>
              p.category == PartCategory.breaker &&
              p.ratingA != null &&
              p.breakingKa == null)
          .toList();
      expect(nullKa, isNotEmpty);
      final rng = math.Random(41);
      for (var t = 0; t < 40; t++) {
        final part = nullKa[rng.nextInt(nullKa.length)];
        final cls = part.deviceClass == 'MCCB'
            ? BreakerClass.mccb
            : BreakerClass.mcb;
        final b = BreakerResult(
          ratingA: Current(part.ratingA!),
          deviceClass: cls,
          curve: BreakerCurve.c,
        );
        final ka = 1.0 + rng.nextInt(80);
        final sku = matchBreakerSku(b, parts,
            poles: part.poles ?? 3, minBreakingKa: ka);
        if (sku != null) {
          final got = parts.firstWhere((p) => p.sku == sku);
          expect(got.breakingKa, isNotNull, reason: sku);
          expect(got.breakingKa! + 1e-9, greaterThanOrEqualTo(ka));
        }
      }
    });

    test('no kA specified: an undeclared part still matches (unchanged)', () {
      final parts = [
        const Part(
          sku: 'X-400',
          manufacturer: 'T',
          category: PartCategory.breaker,
          series: 'T',
          model: 'MCCB 400A',
          attributes: {'ratingA': 400, 'poles': 3, 'deviceClass': 'MCCB'},
        ),
      ];
      const b = BreakerResult(
          ratingA: Current(400),
          deviceClass: BreakerClass.mccb,
          curve: BreakerCurve.c);
      expect(matchBreakerSku(b, parts, poles: 3), 'X-400');
      expect(matchBreakerSku(b, parts, poles: 3, minBreakingKa: 70), isNull);
    });
  });

  // ── 7. containment + metering + bonding are taken off ───────────────────
  group('elec-report-bom-2-containment-metering-never-taken-off', () {
    final project = ElectricalProject(
      id: 'p',
      name: 'P',
      panels: [
        ElectricalPanel(id: 'MDP', name: 'MDP', circuits: [
          _heater('a', 4000),
          _heater('b', 4000),
          _heater('big', 120000),
        ]),
      ],
    );
    final sys = computeSystem(_p, project);
    final adv = computeAdvancedStudy(_p, project, sys);

    test('conduit / tray metres equal the schedule routes x run length', () {
      final cont = adv.containment['MDP']!;
      final conduit = <int, double>{};
      var tray = 0.0;
      for (final c in sys.panels['MDP']!.circuits) {
        final spec = cont.conduits.firstWhere((x) => x.circuitId == c.circuitId);
        if (spec.conduit.fillPct <= conduitFillSingle * 100) {
          final mm = spec.conduit.conduitSizeMm.round();
          conduit[mm] = (conduit[mm] ?? 0) +
              c.lengthM * ((c.cable.runsPerPhase ?? 1) > 1 ? c.cable.runsPerPhase! : 1);
        } else {
          tray += c.lengthM;
        }
      }
      for (final e in conduit.entries) {
        final line = adv.bom.lines.firstWhere(
            (l) => l.priceKey == 'elec:containment:conduit:${e.key}');
        expect(line.qty, closeTo(e.value, 1e-9));
      }
      if (tray > 0) {
        final line = adv.bom.lines.firstWhere(
            (l) => l.priceKey?.startsWith('elec:containment:tray:') ?? false);
        expect(line.qty, closeTo(tray, 1e-9));
      }
      expect(conduit.isNotEmpty || tray > 0, isTrue);
    });

    test('a 3-phase board: V / A / Hz meters, a kWh meter and its CTs', () {
      final m = adv.metering['MDP']!;
      for (final k in ['voltmeter', 'ammeter', 'frequency']) {
        expect(adv.bom.lines.where((l) => l.priceKey == 'elec:meter:$k'),
            hasLength(1));
      }
      expect(adv.bom.lines.where((l) =>
          l.priceKey?.startsWith('elec:meter:kwh:') ?? false), hasLength(1));
      final ct = adv.bom.lines
          .where((l) => l.priceKey?.startsWith('elec:ct:') ?? false)
          .toList();
      if (m.ctRatio != null) {
        expect(ct.single.qty, 3);
        expect(ct.single.description, contains(m.ctRatio!));
      } else {
        expect(ct, isEmpty);
      }
    });

    test('the main bonding conductor the report prints is taken off', () {
      final csa = sys.earthing.mainBondingConductorMm2;
      expect(
          adv.bom.lines.where((l) =>
              l.priceKey == 'elec:earthing:bonding:${csa == csa.roundToDouble() ? csa.toInt() : csa}'),
          hasLength(1));
    });

    test('a single-phase board carries no metering lines', () {
      final lines = meteringBomLines(
        const ElectricalProject(id: 'p', name: 'P', panels: [
          ElectricalPanel(
              id: 'LP',
              name: 'LP',
              system: ElectricalSystem.singlePhase,
              circuits: []),
        ]),
        {'LP': adv.metering['MDP']!},
      );
      expect(lines, isEmpty);
    });
  });

  // ── 8. reduced make-up cables price apart ───────────────────────────────
  group('elec-report-bom-2-reduced-makeup-cable-priced-as-full-section', () {
    test('a reduced cable keys apart from the full-section cable and falls '
        'back to the legacy key', () {
      final project = ElectricalProject(
        id: 'p',
        name: 'P',
        panels: [
          const ElectricalPanel(id: 'MDP', name: 'MDP', circuits: [
            ElectricalCircuit(
              id: 'f',
              name: 'Feeder',
              loadKind: LoadKind.feeder,
              feedsPanelId: 'SB',
              phases: 3,
              length: Length(30),
            ),
          ]),
          ElectricalPanel(
            id: 'SB',
            name: 'SB',
            sourceType: PanelSource.feeder,
            fedByCircuitId: 'f',
            circuits: [_heater('h', 200000)],
          ),
        ],
      );
      final sys = computeSystem(_p, project);
      final bom = buildBom(sys);
      final reduced = bom.lines
          .where((l) =>
              l.category == PartCategory.cable && l.legacyPriceKey != null)
          .toList();
      expect(reduced, isNotEmpty);
      for (final l in reduced) {
        expect(l.priceKey, contains('+'));
        expect(l.priceKey, isNot(l.legacyPriceKey));
        // The legacy `:nC` / `<n>x<csa>` key still prices it.
        final est = estimateCost(Bom([l]), {l.legacyPriceKey!: 100});
        expect(est.unmatchedCount, 0);
        // A fresh key wins over the legacy one.
        final est2 =
            estimateCost(Bom([l]), {l.legacyPriceKey!: 100, l.priceKey!: 90});
        expect(est2.lines.single.unitPrice, 90);
      }
      // Full-section cables keep the legacy key (byte-identical).
      for (final l in bom.lines.where((l) =>
          l.category == PartCategory.cable && l.legacyPriceKey == null)) {
        expect(l.priceKey!.contains('+'), isFalse);
      }
    });
  });

  // ── 9. the recommended APFC bank is scheduled and drawn ─────────────────
  group('elec-report-bom-2-apfc-bank-bought-not-scheduled', () {
    final project = ElectricalProject(
      id: 'p',
      name: 'P',
      transformerKva: const ApparentPower(400000),
      panels: [
        ElectricalPanel(id: 'MDP', name: 'MDP', circuits: [
          for (var i = 0; i < 6; i++)
            ElectricalCircuit(
              id: 'm$i',
              name: 'Motor $i',
              loadKind: LoadKind.motor,
              motorKw: 22,
              cosPhi: 0.72,
              phases: 3,
              length: const Length(20),
            ),
        ]),
      ],
    );
    final sys = computeSystem(_p, project);
    final adv = computeAdvancedStudy(_p, project, sys);

    test('BOM, schedule and spine agree on the recommended kvar', () {
      final pf = adv.powerFactor;
      expect(pf.needed, isTrue);
      final rec = capacitorBanksToProcure(project, pf)
          .where((b) => b.recommended)
          .single;
      final k = rec.kvar == rec.kvar.roundToDouble()
          ? rec.kvar.toInt().toString()
          : rec.kvar.toString();
      final bomLine = adv.bom.lines
          .firstWhere((l) => l.description.contains('APFC, recommended'));
      expect(bomLine.description, contains('$k kvar'));
      expect(bomLine.qty, rec.units);

      final rows = buildEquipmentScheduleRows(EquipmentScheduleData(
        projectName: 'P',
        date: '2026-10-18',
        electrical: sys,
        electricalProject: project,
        powerFactor: pf,
      ));
      final cb = rows
          .where((r) => r.category == EquipmentCategory.capacitorBank)
          .single;
      expect(cb.service, contains('recommended'));
      expect(cb.duty, startsWith('$k kvar APFC'));
      expect(cb.qty, rec.units);

      final spine = buildElectricalSourceSpine(project: project, result: sys);
      final texts =
          spine.prims.whereType<SldLabel>().map((l) => l.text).toList();
      expect(texts, contains('APFC (RECOMMENDED)'));
      expect(texts.any((t) => t.contains('$k kvar')), isTrue);
    });

    test('no correction needed: no recommended bank anywhere', () {
      final ok = ElectricalProject(
        id: 'p',
        name: 'P',
        transformerKva: const ApparentPower(400000),
        panels: [
          ElectricalPanel(
              id: 'MDP', name: 'MDP', circuits: [_heater('h', 100000)]),
        ],
      );
      final s = computeSystem(_p, ok);
      final a = computeAdvancedStudy(_p, ok, s);
      expect(a.powerFactor.needed, isFalse);
      expect(capacitorBanksToProcure(ok, a.powerFactor), isEmpty);
      final spine = buildElectricalSourceSpine(project: ok, result: s);
      expect(
          spine.prims
              .whereType<SldLabel>()
              .any((l) => l.text.contains('APFC') || l.text.contains('CAP')),
          isFalse);
    });
  });

  // ── 10. a ' — ' in a way name never corrupts a BOM line ─────────────────
  group('elec-report-bom-2-way-name-dash-corrupts-bom-lines', () {
    test('identical ways consolidate whatever their names contain', () {
      ElectricalCircuit light(String id, String name) => ElectricalCircuit(
            id: id,
            name: name,
            loadKind: LoadKind.lighting,
            loadW: 800,
            phases: 1,
            length: const Length(20),
          );
      final project = ElectricalProject(
        id: 'p',
        name: 'P',
        panels: [
          ElectricalPanel(id: 'LP', name: 'LP', circuits: [
            light('a', 'Lighting — zone 1'),
            light('b', 'Lighting'),
          ]),
        ],
      );
      final bom = buildBom(computeSystem(_p, project));
      final cables =
          bom.lines.where((l) => l.category == PartCategory.cable).toList();
      expect(cables, hasLength(1));
      expect(cables.single.qty, 40);
      expect(cables.single.description, isNot(contains('Lighting')));
      expect(
          bom.lines.where((l) => l.description.startsWith('Light point')),
          hasLength(1));
      expect(bom.lines.any((l) => l.description.contains('zone')), isFalse);
    });

    test('splitBomLocation splits only the exact location suffix', () {
      final s = splitBomLocation('MCB 16A curve C — Lighting — zone 1',
          'Lighting — zone 1');
      expect(s.base, 'MCB 16A curve C');
      expect(s.suffix, ' — Lighting — zone 1');
    });
  });

  // ── 11. control devices key on their role ───────────────────────────────
  group('elec-report-bom-2-control-device-price-key-collision', () {
    test('start / stop push-buttons and a VFD pot price apart; legacy key '
        'still prices', () {
      const project = ElectricalProject(
        id: 'p',
        name: 'P',
        panels: [
          ElectricalPanel(id: 'MDP', name: 'MDP', circuits: [
            const ElectricalCircuit(
                id: 'v',
                name: 'Fan',
                loadKind: LoadKind.motor,
                motorKw: 11,
                starterType: StarterType.vfd,
                phases: 3,
                length: Length(10)),
          ]),
        ],
      );
      final sys = computeSystem(_p, project);
      final adv = computeAdvancedStudy(_p, project, sys);
      final lines = advancedBomLines(
          project: project, sys: sys, controlAssemblies: adv.controlAssemblies);
      final pilots = lines
          .where((l) =>
              l.priceKey?.startsWith('elec:control:pilotDevice') ?? false)
          .toList();
      final keys = pilots.map((l) => l.priceKey).toSet();
      expect(keys, containsAll(<String>[
        'elec:control:pilotDevice:speed-pot',
        'elec:control:pilotDevice:start-pb',
        'elec:control:pilotDevice:stop-pb',
      ]));
      for (final l in pilots) {
        expect(l.legacyPriceKey, 'elec:control:pilotDevice:');
        expect(estimateCost(Bom([l]), {l.legacyPriceKey!: 5}).unmatchedCount,
            0);
      }
    });
  });
}

