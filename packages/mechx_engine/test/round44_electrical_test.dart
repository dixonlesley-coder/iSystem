// Round 44 (2026-10-18) — the electrical takeoff, protection and source
// sizing fixes: star-delta lead lugs, the cascade-kept MCB, the tray / air
// route, paralleled sets on the smallest covering rung, the withstand-floored
// harmonic neutral, busbar sections under their own devices, UPS-backed
// boards, battery / inverter / PV takeoff, and the width-bound riser band.
//
// Each group pins one confirmed finding with a first-principles derivation;
// where a counterexample generalises it is a seeded property.
import 'dart:math' as math;

import 'package:mechx_engine/electrical/advanced_bom.dart';
import 'package:mechx_engine/electrical/bom.dart';
import 'package:mechx_engine/electrical/advanced_study.dart';
import 'package:mechx_engine/electrical/busbar.dart';
import 'package:mechx_engine/electrical/catalog.dart' show PartCategory;
import 'package:mechx_engine/electrical/containment.dart';
import 'package:mechx_engine/electrical/fault.dart';
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/control/starter.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/panel_results.dart';
import 'package:mechx_engine/electrical/results.dart';
import 'package:mechx_engine/electrical/sources.dart';
import 'package:mechx_engine/electrical/supply_design.dart';
import 'package:mechx_engine/report/electrical_sld_drawing.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

const _p = PuilProfile();
const _origin = Current(16000);

ElectricalProject _board(List<ElectricalCircuit> circuits,
        {CableInstallMethod? installMethod}) =>
    ElectricalProject(id: 'p', name: 'P', panels: [
      ElectricalPanel(
          id: 'MDP',
          name: 'MDP',
          system: ElectricalSystem.threePhase,
          voltage: const Voltage(400),
          installMethod: installMethod ?? CableInstallMethod.conduit,
          circuits: circuits),
    ]);

ElectricalCircuit _motor(String id, double kw, double lengthM,
        {StarterType starter = StarterType.starDelta}) =>
    ElectricalCircuit(
      id: id,
      name: id,
      loadKind: LoadKind.motor,
      motorKw: kw,
      cosPhi: 0.85,
      phases: 3,
      starterType: starter,
      cableType: 'NYY',
      length: Length(lengthM),
    );

ElectricalCircuitResult _way(ElectricalSystemResult s, String id,
        [String panel = 'MDP']) =>
    s.panels[panel]!.circuits.firstWhere((r) => r.circuitId == id);

double _lugQty(Bom bom, {String? contains}) => bom.lines
    .where((l) =>
        l.description.startsWith('Cable lug') &&
        (contains == null || l.description.contains(contains)))
    .fold<double>(0, (s, l) => s + l.qty);

void main() {
  // ── star-delta motor-lead lugs ───────────────────────────────────────────
  group('elec-report-bom-3-star-delta-lead-lugs-missing', () {
    test('160 kW star-delta, 80 m: every lead conductor is lugged at both '
        'ends on every lead run', () {
      final sys = computeSystem(_p, _board([_motor('big', 160, 80)]),
          originFaultLevel: _origin);
      final w = _way(sys, 'big');
      final leads = w.motorLeads!;
      final leadRuns =
          2 * ((leads.runsPerPhase ?? 1) > 1 ? leads.runsPerPhase! : 1);
      final pe = w.motorLeadsPeCsaMm2 ?? leads.csaMm2;
      // Per lead cable: 3 phase cores + 1 PE; × 2 ends × lead runs.
      var expected = 0.0;
      for (final sz in [leads.csaMm2, leads.csaMm2, leads.csaMm2, pe]) {
        if (sz >= 10) expected += 2 * leadRuns;
      }
      expect(expected, greaterThan(0));
      final bom = buildBom(sys);
      expect(_lugQty(bom, contains: 'motor leads'), expected);
      // Hand count of the reported case: leads 2 × (3×185 + 150) ⇒
      // 3 × 2 × 2 = 12 lugs at 185 mm² + 1 × 2 × 2 = 4 at 150 mm².
      if (leads.csaMm2 == 185 && pe == 150 && leadRuns == 2) {
        expect(expected, 16);
      }
    });

    test('a DOL way buys no motor-lead lugs (byte-identical)', () {
      final sys = computeSystem(
          _p, _board([_motor('dol', 30, 40, starter: StarterType.dol)]),
          originFaultLevel: _origin);
      expect(_way(sys, 'dol').motorLeads, isNull);
      expect(_lugQty(buildBom(sys), contains: 'motor leads'), 0);
    });
  });

  // ── paralleled sets on the smallest covering rung ─────────────────────────
  group('electrical-sim-9-paralleled-units-take-top-rung', () {
    test('2970 kVA ⇒ 2 × 1500 genset and 2 × 1600 transformer', () {
      // n = ceil(2970 / 2500) = 2; per-unit share 1485 ⇒ the 1500 genset
      // rung / the 1600 transformer rung — never 2 × 2500.
      final g = sizeGenerator(ApparentPower.kilovoltAmperes(2970));
      expect(g.units, 2);
      expect(g.ratingKva.inKilovoltAmperes, 1500);
      final s = determineSupply(ApparentPower.kilovoltAmperes(2970 * 0.8));
      // 2376 kVA demand / 0.8 loading = 2970 kVA required.
      expect(s.units, 2);
      expect(s.transformerKva, 1600);
    });

    test('seeded property: fewest units, then the smallest covering rung', () {
      final rnd = math.Random(44);
      for (var i = 0; i < 400; i++) {
        final req = 2500.0 + rnd.nextDouble() * 12000;
        final g = selectGeneratorUnits(ApparentPower.kilovoltAmperes(req));
        final n = (req / 2500).ceil();
        final unit = g.unitKva.inKilovoltAmperes;
        expect(g.units, n, reason: '$req');
        expect(unit * n, greaterThanOrEqualTo(req - 1e-9), reason: '$req');
        // Minimal: the rung below would not cover the per-unit share.
        final idx = kGeneratorKva.indexOf(unit);
        if (idx > 0) {
          expect(kGeneratorKva[idx - 1] * n, lessThan(req), reason: '$req');
        }
        final inv = selectInverterUnits(Power.kiloWatts(req / 10));
        final ni = (req / 10 / 250).ceil();
        expect(inv.units, ni == 0 ? 1 : ni);
        expect(inv.unitKw.inKiloWatts * inv.units,
            greaterThanOrEqualTo(req / 10 - 1e-9));
      }
    });

    ElectricalProject withGen(GeneratorSource gen) => ElectricalProject(
          id: 'p',
          name: 'P',
          panels: _board([
            const ElectricalCircuit(
                id: 'h',
                name: 'h',
                loadKind: LoadKind.heating,
                loadW: 60000,
                phases: 3,
                length: Length(10)),
          ]).panels,
          sources: ElectricalSources(generator: gen),
        );

    test('a forced 2 × 2000 kVA plant: genset qty 2, ATS on 4000 kVA + a '
        'synchronising panel; round-trips in .mechx', () {
      final pr = withGen(GeneratorSource(
          kva: ApparentPower.kilovoltAmperes(2000), units: 2));
      final sys = computeSystem(_p, pr);
      final lines = advancedBomLines(project: pr, sys: sys);
      final gen = lines
          .singleWhere((l) => l.priceKey?.contains(':genset:') ?? false);
      expect(gen.qty, 2);
      expect(gen.description, contains('2000 kVA'));
      final ats = lines.singleWhere((l) => l.description.contains('ATS'));
      expect(ats.description, contains('4000 kVA'));
      expect(
          lines.where((l) => l.description.contains('synchronising panel')),
          hasLength(1));
      final back = ElectricalProject.fromJson(pr.toJson());
      expect(back.sources!.generator!.units, 2);
      expect(back.sources!.generator!.totalKva!.inKilovoltAmperes, 4000);
    });

    test('one forced set: no synchronising panel, units omitted from JSON', () {
      final pr = withGen(
          GeneratorSource(kva: ApparentPower.kilovoltAmperes(100)));
      final lines =
          advancedBomLines(project: pr, sys: computeSystem(_p, pr));
      expect(lines.where((l) => l.description.contains('synchronising')),
          isEmpty);
      final ats = lines.singleWhere((l) => l.description.contains('ATS'));
      expect(ats.description, contains('for 100 kVA genset'));
      final json = pr.toJson()['sources'] as Map<String, dynamic>;
      expect((json['generator'] as Map).containsKey('units'), isFalse);
    });
  });

  // ── harmonic neutral bar on the CURRENT, not a withstand-floored CSA ──────
  group('electrical-sim-9-neutral-bar-double-counts-withstand', () {
    ElectricalProject ups() => _board([
          for (var i = 1; i <= 6; i++)
            ElectricalCircuit(
                id: 'u$i',
                name: 'PDU $i',
                loadKind: LoadKind.ups,
                loadW: 8000,
                cosPhi: 0.9,
                phases: 1,
                length: const Length(15)),
        ]);
    double ampBar(double needA) => _p.copperBusbarTable
        .firstWhere((b) => b.ampacityA.amperes >= needA)
        .csaMm2;

    test('no fault: the neutral is the bar carrying 1.73 × the sizing '
        'current', () {
      final pr = computeSystem(_p, ups()).panels['MDP']!;
      final n = pr.neutralPeBars;
      expect(n.neutralOversizeFactor, 1.73);
      final need = 1.73 * pr.busbar.totalCurrentA.amperes;
      final expected = ampBar(need) > pr.busbar.csaMm2
          ? ampBar(need)
          : pr.busbar.csaMm2;
      expect(n.neutralCsaMm2, expected);
      // The reported case: 6 × 8 kW on 3 lines ⇒ 2 ways per line ⇒
      // 16 000 / (230 × 0.9) = 77.3 A worst phase; 1.73 × 77.3 = 133.7 A.
      expect(n.oversized, isTrue);
    });

    test('17.84 kA @ 0.1 s: a withstand-governed phase bar is the neutral, '
        'never phase CSA × 1.73', () {
      final sys = computeSystem(_p, ups(),
          originFaultLevel: const Current(17840), busbarClearingTimeS: 0.1);
      final pr = sys.panels['MDP']!;
      // Withstand floor: Icw = density × S / √t ≥ 17.84 kA.
      final floor = minCsaForWithstand(_p, 17.84, durationS: 0.1);
      expect(pr.busbar.csaMm2, greaterThanOrEqualTo(floor));
      final need = 1.73 * pr.busbar.totalCurrentA.amperes;
      final expected = ampBar(need) > pr.busbar.csaMm2
          ? ampBar(need)
          : pr.busbar.csaMm2;
      expect(pr.neutralPeBars.neutralCsaMm2, expected);
      expect(pr.neutralPeBars.neutralCsaMm2,
          lessThan(pr.busbar.csaMm2 * 1.73 - 1e-9));
      // The factor still reaches upstream (it is the load's property).
      expect(pr.neutralPeBars.neutralOversizeFactor, 1.73);
    });

    test('seeded property: neutral ≥ phase bar and ≥ the factor-current bar, '
        'and the smallest such', () {
      final rnd = math.Random(4401);
      for (var i = 0; i < 200; i++) {
        final phase = _p.copperBusbarTable[
                rnd.nextInt(_p.copperBusbarTable.length)]
            .csaMm2;
        final iA = 5 + rnd.nextDouble() * 900;
        final f = 1 + rnd.nextDouble();
        final n = sizeNeutralPeBars(phase, const Current(100),
            profile: _p,
            neutralOversizeFactor: f,
            triplenFraction: 0.5,
            phaseSizingCurrentA: iA);
        expect(n.neutralCsaMm2, greaterThanOrEqualTo(phase));
        final need = f * iA;
        final top = _p.copperBusbarTable.last;
        if (top.ampacityA.amperes >= need) {
          final a = ampBar(need);
          expect(n.neutralCsaMm2, a > phase ? a : phase);
        }
      }
    });
  });

  // ── busbar sections carry their own outgoing devices ──────────────────────
  group('electrical-sim-9-busbar-section-below-outgoing-device', () {
    ElectricalCircuit heater(String id, double kw) => ElectricalCircuit(
        id: id,
        name: id,
        loadKind: LoadKind.heating,
        loadW: kw * 1000,
        cosPhi: 0.9,
        phases: 3,
        length: const Length(20));

    void expectSectionsCarryDevices(ElectricalPanelResult pr) {
      final rating = {
        for (final c in pr.circuits) c.circuitId: c.breaker.ratingA.amperes,
      };
      for (final s in pr.busbarSections) {
        final maxIn = s.circuitIds
            .map((id) => rating[id] ?? 0)
            .fold<double>(0, (m, v) => v > m ? v : m);
        expect(s.busbar.ampacityA.amperes, greaterThanOrEqualTo(maxIn - 1e-9),
            reason: 'section ${s.index}');
      }
    }

    test('1100 kW (ACB) + 300 kW (MCCB): the big way\'s section carries its '
        'device rating', () {
      // Ib = 1 100 000 / (√3 × 400 × 0.9) = 1764.1 A ⇒ a 2000 A device; the
      // over-current split puts it alone in a section, which must be rated
      // ≥ 2000 A (it was sized on 1764 A by density).
      final sys = computeSystem(
          _p, _board([heater('big', 1100), heater('mid', 300)]));
      final pr = sys.panels['MDP']!;
      final big = _way(sys, 'big');
      expect(big.runCurrentA.amperes, closeTo(1764.1, 0.5));
      expect(pr.busbarSections.length, greaterThan(1));
      final sec = pr.busbarSections.firstWhere((s) => s.circuitIds.contains('big'));
      expect(sec.busbar.ampacityA.amperes,
          greaterThanOrEqualTo(big.breaker.ratingA.amperes));
      expectSectionsCarryDevices(pr);
    });

    test('seeded property: every section ampacity ≥ its largest device', () {
      final rnd = math.Random(4402);
      for (var t = 0; t < 40; t++) {
        final n = 1 + rnd.nextInt(16);
        final ways = [
          for (var i = 0; i < n; i++)
            heater('w$i', 2 + rnd.nextDouble() * (rnd.nextBool() ? 40 : 900)),
        ];
        expectSectionsCarryDevices(computeSystem(_p, _board(ways)).panels['MDP']!);
      }
    });
  });

  // ── the issued route follows the sizing method ────────────────────────────
  group('electrical-sim-9-tray-sized-cable-issued-in-conduit', () {
    ElectricalProject board(CableInstallMethod m) => _board([
          const ElectricalCircuit(
              id: 'w',
              name: 'Load',
              loadKind: LoadKind.general,
              loadW: 79000,
              cosPhi: 0.9,
              phases: 3,
              cableType: 'NYY',
              length: Length(30)),
        ], installMethod: m);
    List<String> rowLabels(ElectricalProject pr, ElectricalSystemResult sys,
            AdvancedStudy adv) =>
        [
          for (final p in buildElectricalPanelDetail(
                  project: pr,
                  result: sys,
                  panelId: 'MDP',
                  containmentByCircuitId: containmentByCircuitIdOf(adv))
              .prims)
            if (p is SldLabel) p.text,
        ];

    test('79 kW on a TRAY board: issued on tray, no conduit bought', () {
      // Ib = 79 000 / (√3 × 400 × 0.9) = 126.7 A ⇒ In 160 A; the cable is
      // sized on method E (tray), whose Iz the same cable would not reach in
      // conduit (B1) — so the issued route must be the tray.
      final pr = board(CableInstallMethod.tray);
      final sys = computeSystem(_p, pr);
      final w = _way(sys, 'w');
      expect(w.runCurrentA.amperes, closeTo(126.7, 0.1));
      final adv = computeAdvancedStudy(_p, pr, sys);
      final cc = adv.containment['MDP']!.conduits.single;
      expect(cc.conduit.route, ContainmentRoute.tray);
      expect(cc.conduit.issuesConduit, isFalse);
      final labels = rowLabels(pr, sys, adv);
      expect(labels.any((t) => t.contains('PVC')), isFalse);
      expect(labels.any((t) => t.contains(' · tray')), isTrue);
      final bom = containmentBomLines(sys, adv.containment);
      expect(bom.where((l) => l.description.contains('conduit')), isEmpty);
      final tray = bom.singleWhere((l) => l.description.contains('tray'));
      expect(tray.qty, 30);
      // The engine-only schedule (no study map) agrees.
      final bare = [
        for (final p in buildElectricalPanelDetail(
                project: pr, result: sys, panelId: 'MDP')
            .prims)
          if (p is SldLabel) p.text,
      ];
      expect(bare.any((t) => t.contains('PVC')), isFalse);
    });

    test('a CONDUIT board twin keeps its conduit (byte-identical route)', () {
      final pr = board(CableInstallMethod.conduit);
      final sys = computeSystem(_p, pr);
      final adv = computeAdvancedStudy(_p, pr, sys);
      final cc = adv.containment['MDP']!.conduits.single;
      expect(cc.conduit.route, ContainmentRoute.conduit);
      expect(rowLabels(pr, sys, adv).any((t) => t.contains(' · PVC ')), isTrue);
      expect(
          containmentBomLines(sys, adv.containment)
              .where((l) => l.description.startsWith('PVC conduit')),
          hasLength(1));
    });

    test('a WALL (clipped direct) board: clipped token, no containment', () {
      final pr = board(CableInstallMethod.wall);
      final sys = computeSystem(_p, pr);
      final adv = computeAdvancedStudy(_p, pr, sys);
      expect(rowLabels(pr, sys, adv).any((t) => t.contains(' · clipped')),
          isTrue);
      expect(containmentBomLines(sys, adv.containment), isEmpty);
    });
  });

  // ── an engine-kept cascade MCB is not a breaking-capacity ERROR ───────────
  group('regression-kept-cascade-mcb-raises-breaking-capacity-error', () {
    const ka38 = Current(38000);
    ElectricalProject jockey({Current? override}) => _board([
          ElectricalCircuit(
            id: 'jp',
            name: 'JP',
            loadKind: LoadKind.pump,
            motorKw: 3,
            cosPhi: 0.85,
            phases: 3,
            lifeSafety: true,
            starterType: StarterType.dol,
            cableType: 'FRC',
            breakerOverrideA: override,
            length: const Length(40),
          ),
        ]);

    test('Round-43 jockey (3 kW DOL, FRC, 40 m, 38 kA bus): no error, one '
        'cascade warning naming the incomer and the back-up kA', () {
      final pr = jockey();
      final sys = computeSystem(_p, pr, originFaultLevel: ka38);
      final w = _way(sys, 'jp');
      expect(w.breaker.deviceClass, BreakerClass.mcb);
      expect(w.breaker.overridden, isFalse);
      // 38 kA > the MCB ladder top (25 kA) ⇒ kept MCB on back-up.
      expect(sys.warnings.map((x) => x.code),
          contains('mcb-backup-protection-required'));
      final fs = faultStudy(sys, pr, _p, originFaultLevel: ka38);
      final mine = fs.warnings.where((x) => x.circuitId == 'jp').toList();
      expect(mine.where((x) => x.severity == WarningSeverity.error), isEmpty);
      final cw = mine
          .where((x) => x.code == 'cascade-combination-unverified')
          .single;
      expect(cw.severity, WarningSeverity.warning);
      final inc = sys.panels['MDP']!.incomer.breaker;
      expect(cw.message,
          contains('${inc.ratingA.amperes.round()} A ${inc.deviceClass.code}'));
      // The BOM names the cascade instead of flagging the device short.
      final bom = buildBom(sys,
          requiredIcuKaByPanelId: faultSpecifiedKa(fs).bus,
          breakerKaByCircuitId: faultSpecifiedKa(fs).breakers);
      final line = bom.lines.firstWhere((l) =>
          l.category == PartCategory.breaker &&
          l.description.startsWith('MCB ${w.breaker.ratingA.amperes.round()}A'));
      expect(line.breakingCapacityShort, isFalse);
      expect(line.description, contains('cascade'));
    });

    test('an OVERRIDDEN sub-kA MCB still errors', () {
      final pr = jockey(override: const Current(10));
      final sys = computeSystem(_p, pr, originFaultLevel: ka38);
      final w = _way(sys, 'jp');
      expect(w.breaker.overridden, isTrue);
      expect(w.breaker.deviceClass, BreakerClass.mcb);
      final fs = faultStudy(sys, pr, _p, originFaultLevel: ka38);
      expect(
          fs.warnings.where((x) =>
              x.circuitId == 'jp' &&
              x.code == 'breaking-capacity-inadequate' &&
              x.severity == WarningSeverity.error),
          hasLength(1));
    });
  });

  // ── a UPS-backed board's feeder carries the UPS input ─────────────────────
  group('electrical-sim-9-ups-backed-board-sizes-no-ups', () {
    ElectricalProject tree(bool ups) => ElectricalProject(
          id: 'p',
          name: 'P',
          panels: [
            const ElectricalPanel(
                id: 'LV',
                name: 'LV',
                system: ElectricalSystem.threePhase,
                voltage: Voltage(400),
                circuits: [
                  ElectricalCircuit(
                      id: 'f',
                      name: 'to CR',
                      loadKind: LoadKind.feeder,
                      feedsPanelId: 'CR',
                      length: Length(20)),
                ]),
            ElectricalPanel(
                id: 'CR',
                name: 'CR',
                system: ElectricalSystem.threePhase,
                voltage: const Voltage(400),
                upsBacked: ups,
                circuits: [
                  for (var i = 0; i < 6; i++)
                    ElectricalCircuit(
                        id: 'c$i',
                        name: 'IT $i',
                        loadKind: LoadKind.general,
                        loadW: 15000,
                        cosPhi: 0.9,
                        phases: 3,
                        length: const Length(10)),
                ]),
          ],
        );

    test('6 × 15 kW: the feeder Ib rises by ÷0.94 × 1.10 and an info says no '
        'UPS is sized', () {
      final off = computeSystem(_p, tree(false));
      final on = computeSystem(_p, tree(true));
      final ibOff = _way(off, 'f', 'LV').runCurrentA.amperes;
      final ibOn = _way(on, 'f', 'LV').runCurrentA.amperes;
      // 90 kW / (√3 × 400 × 0.9) = 144.3 A ⇒ × 1.10 / 0.94 = 168.9 A.
      expect(ibOff, closeTo(90000 / (1.7320508 * 400 * 0.9), 0.2));
      expect(ibOn, closeTo(ibOff * 1.10 / 0.94, 0.3));
      expect(_way(on, 'f', 'LV').breaker.ratingA.amperes,
          greaterThan(_way(off, 'f', 'LV').breaker.ratingA.amperes - 1e-9));
      expect(on.warnings.where((w) => w.code == 'ups-not-sized'),
          hasLength(1));
      expect(off.warnings.where((w) => w.code == 'ups-not-sized'), isEmpty);
      // The UPS-backed board's OWN schedule is the output side (unchanged).
      expect(on.panels['CR']!.demandW, off.panels['CR']!.demandW);
    });
  });
}
