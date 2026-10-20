// Round 45 (2026-10-18) — the UPS input carried to the genset, one
// covering-units transformer rule for a declared capacity, cascade back-up
// only behind a current-limiting MCCB, the MCCB magnetic release in ADS, an
// honest TIPIKAL key, and a riser that paginates bands of parent boards (and
// survives an empty storey band).
//
// Each group pins one confirmed finding with a first-principles derivation;
// where a counterexample generalises it is a seeded property.
import 'dart:math' as math;

import 'package:mechx_engine/electrical/bom.dart';
import 'package:mechx_engine/electrical/catalog.dart' show PartCategory;
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/fault.dart';
import 'package:mechx_engine/electrical/genset_backup.dart';
import 'package:mechx_engine/electrical/geo_length.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/panel_results.dart';
import 'package:mechx_engine/electrical/sources.dart';
import 'package:mechx_engine/electrical/supply_design.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/report/drawing_chrome.dart' show kMinPlotLabelPt;
import 'package:mechx_engine/report/electrical_pagination.dart';
import 'package:mechx_engine/report/electrical_pdf_export.dart'
    show sldSinglePageMinLabelPt;
import 'package:mechx_engine/report/electrical_sld_drawing.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

const _p = PuilProfile();
const _sqrt3 = 1.7320508075688772;

ElectricalCircuitResult _way(ElectricalSystemResult s, String id,
        [String panel = 'MDP']) =>
    s.panels[panel]!.circuits.firstWhere((r) => r.circuitId == id);

void main() {
  // ── the genset carries a UPS-backed essential board's UPS INPUT ───────────
  group('regression-ups-input-not-carried-to-genset', () {
    ElectricalProject tree(
            {required bool ups,
            bool essentialParent = false,
            ApparentPower? forced}) =>
        ElectricalProject(
          id: 'p',
          name: 'P',
          sources: ElectricalSources(
              generator: GeneratorSource(kva: forced, backupFraction: 0.1)),
          panels: [
            ElectricalPanel(
                id: 'LV',
                name: 'LV',
                system: ElectricalSystem.threePhase,
                voltage: const Voltage(400),
                circuits: [
                  const ElectricalCircuit(
                      id: 'g',
                      name: 'General',
                      loadKind: LoadKind.general,
                      loadW: 20000,
                      cosPhi: 0.9,
                      phases: 3,
                      length: Length(10)),
                  ElectricalCircuit(
                      id: 'f',
                      name: essentialParent ? 'to ESS' : 'to CR',
                      loadKind: LoadKind.feeder,
                      feedsPanelId: essentialParent ? 'ESS' : 'CR',
                      length: const Length(20)),
                ]),
            if (essentialParent)
              const ElectricalPanel(
                  id: 'ESS',
                  name: 'ESS',
                  essential: true,
                  system: ElectricalSystem.threePhase,
                  voltage: Voltage(400),
                  circuits: [
                    ElectricalCircuit(
                        id: 'fcr',
                        name: 'to CR',
                        loadKind: LoadKind.feeder,
                        feedsPanelId: 'CR',
                        length: Length(10)),
                  ]),
            ElectricalPanel(
                id: 'CR',
                name: 'CR',
                essential: !essentialParent,
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

    test(
        '6 × 15 kW essential UPS board: the genset backs 90 kW × 1.10 / 0.94 '
        '= 105.3 kW ⇒ 150 kVA (125 kVA without the UPS)', () {
      final off = tree(ups: false);
      final on = tree(ups: true);
      final sOff = computeSystem(_p, off);
      final sOn = computeSystem(_p, on);
      // The board's OWN (output) demand is unchanged by the UPS flag.
      expect(sOn.panels['CR']!.demandW, sOff.panels['CR']!.demandW);
      expect(sOff.panels['CR']!.demandW, closeTo(90000, 1));
      // Genset basis: 90 000 W × 1.10 / 0.94 = 105 319 W; VA = 100 000 ×
      // 1.170 = 117 021 VA.
      expect(essentialDemandW(off, sOff), closeTo(90000, 1));
      expect(essentialDemandW(on, sOn), closeTo(90000 * 1.10 / 0.94, 1));
      expect(essentialDemandVa(on, sOn), closeTo(100000 * 1.10 / 0.94, 2));
      expect(
          gensetBackupDemandW(on, sOn).watts, closeTo(90000 * 1.10 / 0.94, 1));
      GeneratorResult size(ElectricalProject pr, ElectricalSystemResult s) =>
          sizeGenerator(gensetBackupDemandVa(pr, s),
              backupPower: gensetBackupDemandW(pr, s));
      // 90 kW / 0.8 = 112.5 ⇒ 125 kVA; 105.3 kW / 0.8 = 131.6 ⇒ 150 kVA.
      expect(size(off, sOff).ratingKva.inKilovoltAmperes, 125);
      expect(size(on, sOn).ratingKva.inKilovoltAmperes, 150);
      // The UPS board on the alternator lines is a BALANCED rectifier draw:
      // its uplifted VA over √3 · 400 per line.
      expect(alternatorLineDemandVa(on, sOn, ['CR']),
          closeTo(essentialDemandVa(on, sOn), 1));
    });

    test(
        'a forced 125 kVA set (100 kW) is judged against the UPS input: '
        'genset-below-essential-power fires', () {
      final pr = tree(ups: true, forced: ApparentPower.kilovoltAmperes(125));
      final s = computeSystem(_p, pr);
      final codes = gensetBackupWarnings(pr, s).map((w) => w.code);
      expect(codes, contains('genset-below-essential-power'));
      final off = tree(ups: false, forced: ApparentPower.kilovoltAmperes(125));
      expect(
          gensetBackupWarnings(off, computeSystem(_p, off)).map((w) => w.code),
          isNot(contains('genset-below-essential-power')));
    });

    test(
        'nested: an essential (non-UPS) parent already carries its UPS '
        'child\'s uplift through its feeder — never applied twice', () {
      final pr = tree(ups: true, essentialParent: true);
      final s = computeSystem(_p, pr);
      // ESS demand = the feeder load = CR demand × 1.170 (diversity 1).
      expect(s.panels['ESS']!.demandW, closeTo(90000 * 1.10 / 0.94, 1));
      expect(essentialDemandW(pr, s), closeTo(s.panels['ESS']!.demandW, 1e-6));
    });
  });

  // ── a declared capacity above the ladder: n units on the covering rung ────
  group('regression-declared-capacity-transformer-top-rung', () {
    ElectricalProject declared(double va, {bool dual = false}) =>
        ElectricalProject(
          id: 'p',
          name: 'P',
          supplyCapacityVa: ApparentPower(va),
          dualTransformer: dual,
          panels: const [
            ElectricalPanel(id: 'MDP', name: 'MDP', circuits: [
              ElectricalCircuit(
                  id: 'g',
                  name: 'g',
                  loadKind: LoadKind.general,
                  loadW: 100000,
                  cosPhi: 0.9,
                  phases: 3,
                  length: Length(10)),
            ]),
          ],
        );

    test(
        '3 000 kVA declared ⇒ 2 × 1600 kVA (the study\'s own rule) and a '
        '3.2 MVA transformer fault of ~115.5 kA, never 2 × 2500 / 180 kA', () {
      final pr = declared(3000000);
      final d = declaredServiceTransformer(pr)!;
      expect(d.kva.inKilovoltAmperes, 1600);
      expect(d.units, 2);
      // The supply study's covering rule gives the same pick.
      expect(coveringTransformerUnits(3000), (kva: 1600.0, units: 2));
      final isc = estimatedServiceFaultLevelA(pr,
              demand: ApparentPower.kilovoltAmperes(100))!
          .amperes;
      // 3.2e6 / (√3 · 400 · 0.04) = 115 470 A.
      expect(isc, closeTo(3200000 / (_sqrt3 * 400 * 0.04), 2));
    });

    test(
        'a dual 3 MVA service: 1500 kVA per section ⇒ 2 × 1600 '
        '(unchanged); sub-ladder declarations unchanged', () {
      final d = declaredServiceTransformer(declared(3000000, dual: true))!;
      expect(d.kva.inKilovoltAmperes, 1600);
      expect(d.units, 2);
      final small = declaredServiceTransformer(declared(600000))!;
      expect(small.kva.inKilovoltAmperes, 630);
      expect(small.units, 1);
    });

    test(
        'seeded property: the declared pick == the study\'s covering rule '
        'per section', () {
      final rnd = math.Random(45);
      for (var i = 0; i < 200; i++) {
        final cap = plnLvServiceCeilingVa + 1 + rnd.nextDouble() * 12e6;
        final dual = rnd.nextBool();
        final d = declaredServiceTransformer(declared(cap, dual: dual))!;
        final sections = dual ? 2 : 1;
        final u =
            coveringTransformerUnits(cap / 1000 / sections, tolerance: 1e-9);
        expect(d.kva.inKilovoltAmperes, u.kva, reason: '$cap $dual');
        expect(d.units, u.units * sections, reason: '$cap $dual');
        expect(d.kva.inKilovoltAmperes * d.units,
            greaterThanOrEqualTo(cap / 1000 - 1e-6));
      }
    });
  });

  // ── cascade back-up only behind a current-limiting, adequate MCCB ─────────
  group('regression-cascade-accepts-acb-backup', () {
    ElectricalProject acbBoard() =>
        ElectricalProject(id: 'p', name: 'P', panels: [
          ElectricalPanel(
              id: 'MDP',
              name: 'MDP',
              system: ElectricalSystem.threePhase,
              voltage: const Voltage(400),
              circuits: [
                const ElectricalCircuit(
                    id: 'big',
                    name: 'Chiller plant',
                    loadKind: LoadKind.general,
                    loadW: 1100000,
                    cosPhi: 0.9,
                    phases: 3,
                    length: Length(10)),
                for (var i = 0; i < 3; i++)
                  ElectricalCircuit(
                      id: 'l$i',
                      name: 'Lighting $i',
                      loadKind: LoadKind.lighting,
                      isLighting: true,
                      loadW: 300,
                      cosPhi: 0.9,
                      phases: 1,
                      groupingCountOverride: 20,
                      length: const Length(10)),
              ]),
        ]);
    const ka50 = Current(50000);

    test(
        'a kept 6 A MCB behind a 2000 A ACB at 50 kA: breaking-capacity '
        'ERROR (an ACB is not current-limiting), and the BOM flags it short',
        () {
      final pr = acbBoard();
      final sys = computeSystem(_p, pr, originFaultLevel: ka50);
      expect(sys.panels['MDP']!.incomer.breaker.deviceClass, BreakerClass.acb);
      final w = _way(sys, 'l0');
      expect(w.breaker.deviceClass, BreakerClass.mcb);
      expect(w.breaker.overridden, isFalse);
      final fs = faultStudy(sys, pr, _p, originFaultLevel: ka50);
      final mine = fs.warnings.where((x) => x.circuitId == 'l0').toList();
      expect(mine.where((x) => x.code == 'cascade-combination-unverified'),
          isEmpty);
      final err = mine
          .where((x) =>
              x.code == 'breaking-capacity-inadequate' &&
              x.severity == WarningSeverity.error)
          .single;
      expect(err.message, contains('current-limiting MCCB upstream'));
      // The BOM reads the SAME predicate: no cascade note, flagged short.
      final ka = faultSpecifiedKa(fs);
      final bom = buildBom(sys,
          requiredIcuKaByPanelId: ka.bus,
          incomerKaByPanelId: ka.incomers,
          breakerKaByCircuitId: ka.breakers);
      final line = bom.lines.firstWhere((l) =>
          l.category == PartCategory.breaker &&
          l.description
              .startsWith('MCB ${w.breaker.ratingA.amperes.round()}A'));
      expect(line.description, isNot(contains('cascade')));
      expect(line.breakingCapacityShort, isTrue);
    });

    test(
        'the predicate: only an MCCB incomer whose own kA covers the fault '
        'backs up a kept MCB', () {
      bool ok(BreakerClass inc, double incKa, {double bus = 50}) =>
          cascadeBackupAvailable(
              wayClass: BreakerClass.mcb,
              wayOverridden: false,
              busFaultKa: bus,
              incomerClass: inc,
              incomerKa: incKa);
      expect(ok(BreakerClass.mccb, 50), isTrue);
      expect(ok(BreakerClass.mccb, 36), isFalse); // inadequate incomer
      expect(ok(BreakerClass.acb, 65), isFalse); // not current-limiting
      expect(ok(BreakerClass.mccb, 50, bus: 20), isFalse); // MCB ladder covers
      expect(
          cascadeBackupAvailable(
              wayClass: BreakerClass.mcb,
              wayOverridden: true,
              busFaultKa: 50,
              incomerClass: BreakerClass.mccb,
              incomerKa: 50),
          isFalse);
    });
  });

  // ── a raised MCCB is ADS-judged at its magnetic release (~10 × In) ────────
  group('electrical-sim-10-mccb-raised-from-b-curve-ads-judged-at-5x', () {
    ElectricalProject lighting(double lengthM) =>
        ElectricalProject(id: 'p', name: 'P', panels: [
          ElectricalPanel(
              id: 'MDP',
              name: 'MDPE',
              system: ElectricalSystem.threePhase,
              voltage: const Voltage(400),
              circuits: [
                ElectricalCircuit(
                    id: 'el',
                    name: 'Emergency lighting',
                    loadKind: LoadKind.lighting,
                    isLighting: true,
                    loadW: 8000,
                    cosPhi: 0.9,
                    phases: 3,
                    length: Length(lengthM)),
              ]),
        ]);
    const ka = Current(35710);

    test(
        '8 kW lighting at 35.7 kA: issued as an MCCB, judged at 10 × In '
        '(zsMax = 0.95 · 230 / (10 · In)), never the B-curve 5 ×', () {
      final pr = lighting(60);
      final sys = computeSystem(_p, pr, originFaultLevel: ka);
      final w = _way(sys, 'el');
      expect(w.breaker.deviceClass, BreakerClass.mccb);
      final fs = faultStudy(sys, pr, _p, originFaultLevel: ka);
      final c = fs.circuits['el']!;
      final inA = w.breaker.ratingA.amperes;
      expect(c.zsMaxOhm, closeTo(0.95 * 230 / (10 * inA), 1e-3));
      // The verdict follows: ADS OK exactly when Zs ≤ that limit.
      expect(c.adsOk, c.zsOhm! <= c.zsMaxOhm! + 1e-9);
      final adsErr = fs.warnings
          .where((x) => x.circuitId == 'el' && x.code == 'ads-disconnection');
      expect(adsErr.isNotEmpty, !c.adsOk!);
    });

    test(
        'seeded property: every non-MCB way is judged at <= 0.95 · U0 / '
        '(10 · In)', () {
      final rnd = math.Random(4510);
      for (var i = 0; i < 20; i++) {
        final pr = lighting(10 + rnd.nextDouble() * 90);
        final sys = computeSystem(_p, pr, originFaultLevel: ka);
        final fs = faultStudy(sys, pr, _p, originFaultLevel: ka);
        for (final pr2 in sys.panels.values) {
          for (final w in pr2.circuits) {
            if (w.breaker.deviceClass == BreakerClass.mcb) continue;
            final c = fs.circuits[w.circuitId]!;
            if (c.zsMaxOhm == null) continue;
            expect(
                c.zsMaxOhm!,
                lessThanOrEqualTo(
                    0.95 * 230 / (10 * w.breaker.ratingA.amperes) + 1e-3));
          }
        }
      }
    });
  });

  // ── TIPIKAL: one printed figure per node, length-free spec ────────────────
  group('regression-tipikal-collapses-different-demand', () {
    ElectricalProject units(int n,
            {double Function(int i)? wayW, double Function(int i)? lengthM}) =>
        ElectricalProject(id: 'a', name: 'A', panels: [
          ElectricalPanel(id: 'MDP', name: 'DB-L1', circuits: [
            for (var i = 1; i <= n; i++)
              ElectricalCircuit(
                  id: 'f$i',
                  name: 'Unit $i',
                  loadKind: LoadKind.feeder,
                  feedsPanelId: 'U$i',
                  length: Length(lengthM?.call(i) ?? 20)),
          ]),
          for (var i = 1; i <= n; i++)
            ElectricalPanel(
              id: 'U$i',
              name: 'PHB UNIT ${100 + i}',
              system: ElectricalSystem.singlePhase,
              voltage: const Voltage(220),
              sourceType: PanelSource.feeder,
              fedByCircuitId: 'f$i',
              circuits: [
                for (var k = 0; k < 4; k++)
                  ElectricalCircuit(
                      id: 'u$i-$k',
                      name: 'Way $k',
                      loadKind: k.isEven ? LoadKind.socket : LoadKind.lighting,
                      loadW: wayW?.call(i) ?? 900,
                      cosPhi: 0.9,
                      phases: 1,
                      length: const Length(8)),
              ],
            ),
        ]);

    test(
        '16 boards, unit 116 at 950 W per way: 116 is NOT folded into the '
        '3.6 kW typical node', () {
      final pr = units(16, wayW: (i) => i == 16 ? 950 : 900);
      final r = computeSystem(_p, pr);
      expect(r.panels['U1']!.demandW, isNot(r.panels['U16']!.demandW));
      final groups = electricalRiserTypicalGroups(pr, r, null);
      expect(groups.values.single, hasLength(15));
      expect(groups.values.single, isNot(contains('U16')));
      // Every member of a group prints the same demand (the node's figure).
      for (final g in groups.values) {
        final kw = {for (final id in g) r.panels[id]!.demandW};
        expect(kw, hasLength(1));
      }
    });

    test(
        'identical boards at DIFFERENT feeder lengths collapse; the typical '
        'feeder prints the members\' length range', () {
      final pr = units(16, lengthM: (i) => 9.0 + i);
      final r = computeSystem(_p, pr);
      final groups = electricalRiserTypicalGroups(pr, r, null);
      expect(groups.values.single, hasLength(16));
      expect(electricalRiserTypicalFeederLength(pr, r, groups.values.single),
          '10.0..25.0 m');
      final pages = paginatedElectricalRiserSheets(project: pr, result: r);
      final labels = [
        for (final p in pages)
          for (final x in p.prims)
            if (x is SldLabel) x.text,
      ];
      expect(labels, contains('PHB UNIT 101..116 (TIPIKAL x16)'));
      expect(labels.any((t) => t.endsWith('10.0..25.0 m')), isTrue);
      for (final p in pages) {
        expect(sldSinglePageMinLabelPt(p),
            greaterThanOrEqualTo(kMinPlotLabelPt - 1e-9));
      }
    });
  });

  // ── riser pages: parent bands split, per-chunk ancestors, empty bands ─────
  group('elec-props-11-riser-parent-band-never-paginates', () {
    // MDP -> n sub-mains S_i -> one unit board U_i each (tier mode).
    ElectricalProject threeTier(int n) =>
        ElectricalProject(id: 'p', name: 'P', panels: [
          ElectricalPanel(id: 'MDP', name: 'MDP', circuits: [
            for (var i = 0; i < n; i++)
              ElectricalCircuit(
                  id: 'fs$i',
                  name: 'S$i',
                  loadKind: LoadKind.feeder,
                  feedsPanelId: 'S$i',
                  length: Length(30.0 + i)),
          ]),
          for (var i = 0; i < n; i++)
            ElectricalPanel(id: 'S$i', name: 'SDP-$i', circuits: [
              ElectricalCircuit(
                  id: 'fu$i',
                  name: 'U$i',
                  loadKind: LoadKind.feeder,
                  feedsPanelId: 'U$i',
                  length: Length(10.0 + i)),
              ElectricalCircuit(
                  id: 'gs$i',
                  name: 'G',
                  loadKind: LoadKind.general,
                  loadW: 1000.0 + 1000 * (i % 40),
                  cosPhi: 0.9,
                  phases: 3,
                  length: const Length(10)),
            ]),
          for (var i = 0; i < n; i++)
            ElectricalPanel(id: 'U$i', name: 'UNIT-$i', circuits: [
              ElectricalCircuit(
                  id: 'gu$i',
                  name: 'G',
                  loadKind: LoadKind.general,
                  loadW: 1000.0 + 997 * (i % 40),
                  cosPhi: 0.9,
                  phases: 3,
                  length: const Length(10)),
            ]),
        ]);

    void expectLegibleOnce(List<SldSheet> pages, Iterable<String> names,
        {bool allowParentRepeat = false}) {
      final drawn = <String, int>{};
      for (final p in pages) {
        expect(sldSinglePageMinLabelPt(p),
            greaterThanOrEqualTo(kMinPlotLabelPt - 1e-9));
        expect(p.belowMinLabelPt, isNull);
        for (final x in p.prims) {
          if (x is SldLabel && x.size == 10 && x.bold) {
            drawn[x.text] = (drawn[x.text] ?? 0) + 1;
          }
        }
      }
      for (final n in names) {
        expect(drawn[n], 1, reason: '$n drawn ${drawn[n]} times');
      }
    }

    for (final n in [6, 12, 20, 40]) {
      test(
          '$n sub-mains (tier mode): every riser page >= 7 pt and every '
          'board drawn exactly once', () {
        final pr = threeTier(n);
        final r = computeSystem(_p, pr);
        final pages = paginatedElectricalRiserSheets(project: pr, result: r);
        expectLegibleOnce(pages, [
          'MDP',
          for (var i = 0; i < n; i++) ...['SDP-$i', 'UNIT-$i'],
        ]);
      });
    }

    test(
        'the same tree PLACED (MDP GF, sub-mains L1, units L2) with an '
        'EMPTY roof band: no throw, every page >= 7 pt, each board once', () {
      const n = 12;
      LayoutPos at(int f) => LayoutPos(sheetId: 's', floorIndex: f, x: 0, y: 0);
      final base = threeTier(n);
      final pr = ElectricalProject(id: 'p', name: 'P', panels: [
        for (final p in base.panels)
          p.copyWith(
              layoutPos:
                  at(p.id == 'MDP' ? 0 : (p.id.startsWith('S') ? 1 : 2))),
      ]);
      const building = BuildingLevels([
        Floor('GF', Length(4)),
        Floor('L1', Length(3.5)),
        Floor('L2', Length(3.5)),
        Floor('ROOF', Length(3)),
      ]);
      final r = computeSystem(_p, pr);
      final pages = paginatedElectricalRiserSheets(
          project: pr, result: r, building: building);
      expectLegibleOnce(pages, [
        'MDP',
        for (var i = 0; i < n; i++) ...['SDP-$i', 'UNIT-$i'],
      ]);
    });
  });

  group('electrical-sim-10-riser-export-crash-empty-band', () {
    test(
        'a page with its spine root hidden builds (no null check) and draws '
        'no spine', () {
      const pr = ElectricalProject(id: 'p', name: 'P', panels: [
        ElectricalPanel(id: 'MDP', name: 'MDP', circuits: [
          ElectricalCircuit(
              id: 'f1',
              name: 'DB1',
              loadKind: LoadKind.feeder,
              feedsPanelId: 'DB1',
              length: Length(20)),
        ]),
        ElectricalPanel(id: 'DB1', name: 'DB1', circuits: [
          ElectricalCircuit(
              id: 'g',
              name: 'g',
              loadKind: LoadKind.general,
              loadW: 5000,
              cosPhi: 0.9,
              phases: 3,
              length: Length(10)),
        ]),
      ]);
      final r = computeSystem(_p, pr);
      // Tier mode: MDP on the top band. With 3 levels and MDP on GF, the
      // spine sits BESIDE the root; hide the root (another column page).
      const building = BuildingLevels([
        Floor('GF', Length(4)),
        Floor('L1', Length(3.5)),
        Floor('ROOF', Length(3)),
      ]);
      final pr2 = ElectricalProject(id: 'p', name: 'P', panels: [
        for (final p in pr.panels)
          p.copyWith(
              layoutPos: LayoutPos(
                  sheetId: 's', floorIndex: p.id == 'MDP' ? 0 : 1, x: 0, y: 0)),
      ]);
      final sheet = buildElectricalRiser(
          project: pr2,
          result: r,
          building: building,
          sourceChain: true,
          hidePanelIds: {'MDP'});
      expect(
          sheet.prims.whereType<SldLabel>().any((l) => l.text.contains('PLN')),
          isFalse);
      expect(sheet.prims.whereType<SldLabel>().map((l) => l.text),
          contains('DB1'));
    });
  });
}
