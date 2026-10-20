// Round 38 (2026-10-18) — feeder neutral through parallel runs, history-free
// feeder / alternator lines, the APFC line in the BOM, fault-aware device
// class, honest Icw / RCD-S / Ics / ADS wording, re-derived MEP FLC, ONE LV
// ceiling, a 1φ root on a 3φ-only daya, the minimum capacitor step, feeder
// R/S/T cells, the plan's essential set, a target-less feeder, a 1φ
// sub-board's phase column, and an outgoing way above its incomer.
//
// Every expected figure is derived from first principles in the comments.
import 'dart:convert';
import 'dart:math' as math;

import 'package:mechx_engine/electrical/advanced_study.dart';
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/earthing.dart';
import 'package:mechx_engine/electrical/fault.dart';
import 'package:mechx_engine/electrical/genset_backup.dart';
import 'package:mechx_engine/electrical/geo_length.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/panel_results.dart';
import 'package:mechx_engine/electrical/power_factor.dart';
import 'package:mechx_engine/electrical/results.dart';
import 'package:mechx_engine/electrical/sources.dart';
import 'package:mechx_engine/electrical/supply_design.dart';
import 'package:mechx_engine/report/electrical_plan_export.dart';
import 'package:mechx_engine/report/electrical_sld_drawing.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

const _p = PuilProfile();

// A cos φ 1 single-phase way of 231·A W draws A on a 400 V board.
ElectricalCircuit _amps(String id, double a, {PhaseLine? pin}) =>
    ElectricalCircuit(
      id: id,
      name: id,
      loadKind: LoadKind.heating,
      loadW: 231 * a,
      cosPhi: 1,
      phases: 1,
      phaseOverride: pin,
      length: const Length(20),
    );

ElectricalProject _upsProject(int n, {double? override}) =>
    ElectricalProject(panels: [
      ElectricalPanel(id: 'mdp', name: 'MDP', circuits: [
        ElectricalCircuit(
            id: 'f',
            name: 'Feeder UPS',
            loadKind: LoadKind.feeder,
            feedsPanelId: 'ups',
            cableType: 'NYY',
            cableOverrideMm2: override,
            length: const Length(30)),
      ]),
      ElectricalPanel(id: 'ups', name: 'UPS', circuits: [
        for (var i = 0; i < n; i++)
          ElectricalCircuit(
            id: 'u$i',
            name: 'UPS $i',
            loadKind: LoadKind.ups,
            loadW: 3000,
            cosPhi: 0.9,
            phases: 1,
            length: const Length(10),
          ),
      ]),
    ]);

Iterable<String> _labels(SldSheet sheet) => [
      for (final p in sheet.prims)
        if (p is SldLabel) p.text,
    ];

void main() {
  group('feeder NEUTRAL sized through parallel runs, never claimed carried',
      () {
    // Each UPS way: 3000 / (231 × 0.9) = 14.43 A (carried at 0.1 A = 14.4).
    // n ways spread evenly ⇒ worst phase = ceil(n/3) × 14.4; every way is 1φ
    // non-linear ⇒ FOLD-2 factor 1.73 ⇒ neutral = 1.73 × worst phase.
    test('N = 48: 16 × 14.4 = 230.4 A ⇒ 398.6 A neutral ⇒ Iz ≥ 463.5 A — two '
        'parallel runs, info only', () {
      final sys = computeSystem(_p, _upsProject(48));
      final f = sys.panels['mdp']!.circuits.single;
      const neutralA = 1.73 * 230.4;
      expect(neutralA, closeTo(398.6, 0.05));
      // The largest single section (300 mm², Iz 394 A × 0.86 = 338.8 A) is
      // short, so the ladder steps into parallel runs.
      expect(f.cable.runsPerPhase, greaterThanOrEqualTo(2));
      expect(f.cable.deratedIz.amperes * kFourLoadedConductorFactor,
          greaterThanOrEqualTo(neutralA - 0.1));
      final codes = sys.warnings
          .where((w) => w.circuitId == 'f')
          .map((w) => w.code)
          .toList();
      expect(codes, contains('harmonics-neutral-oversize'));
      expect(codes, isNot(contains('feeder-neutral-overloaded')));
    });

    test('N = 60: 20 × 14.4 = 288 A ⇒ 498.2 A neutral ⇒ Iz ≥ 579.4 A — '
        'upsized (it used to stay at 1×300 with NO message)', () {
      final sys = computeSystem(_p, _upsProject(60));
      final f = sys.panels['mdp']!.circuits.single;
      const neutralA = 1.73 * 288.0;
      expect(f.cable.deratedIz.amperes * kFourLoadedConductorFactor,
          greaterThanOrEqualTo(neutralA - 0.1));
      expect(
          sys.warnings.where((w) =>
              w.circuitId == 'f' && w.code == 'harmonics-neutral-oversize'),
          hasLength(1));
    });

    test('a hand cable override is still CHECKED: 1×300 at N = 48 carries '
        'only 338.8 A of the 398.6 A neutral ⇒ an ERROR, no info', () {
      final sys = computeSystem(_p, _upsProject(48, override: 300));
      final f = sys.panels['mdp']!.circuits.single;
      expect(f.cable.deratedIz.amperes * kFourLoadedConductorFactor,
          lessThan(398.6));
      final ws = sys.warnings.where((w) => w.circuitId == 'f');
      final err = ws.singleWhere((w) => w.code == 'feeder-neutral-overloaded');
      expect(err.severity, WarningSeverity.error);
      expect(ws.where((w) => w.code == 'harmonics-neutral-oversize'), isEmpty);
    });

    test('seeded property: any UPS board ⇒ the neutral is carried, or an '
        'error says it is not — never a silent overload', () {
      final rng = math.Random(38);
      for (var trial = 0; trial < 25; trial++) {
        final n = 3 + rng.nextInt(78);
        final sys = computeSystem(_p, _upsProject(n));
        final f = sys.panels['mdp']!.circuits.single;
        final worst = sys.panels['ups']!.diversifiedDemandCurrent.amperes;
        final factor =
            sys.panels['ups']!.neutralPeBars.neutralOversizeFactor;
        final neutralA = factor * worst;
        final carried = f.cable.deratedIz.amperes * kFourLoadedConductorFactor >=
            neutralA - 1e-6;
        final error = sys.warnings.any(
            (w) => w.circuitId == 'f' && w.code == 'feeder-neutral-overloaded');
        expect(carried || error, isTrue, reason: 'n=$n');
        expect(carried && error, isFalse, reason: 'n=$n');
      }
    });
  });

  group('feeder + alternator lines read the PERSISTED labels (r3)', () {
    // Child DB (3φ): 1φ ways 31.9 / 0.8 / 24.9 / 30.4 A. Engine optimum
    // {31.9} / {30.4} / {24.9 + 0.8} = 31.9 / 30.4 / 25.7. The document's
    // persisted assignment A=L3, B=L1, C=L2, D=L1 (what the live store wrote)
    // at the 1.0 A threshold keeps 31.2 / 24.9 / 31.9 — the same 31.9 A
    // worst (the Round-37 wrapper) — and, since Round 39 r3, that labelled
    // set is what the board prints AND what every parent / genset reads.
    const labels = {
      'A': PhaseLine.l3,
      'B': PhaseLine.l1,
      'C': PhaseLine.l2,
      'D': PhaseLine.l1,
    };
    ElectricalPanel db({String id = 'DB', bool labelled = true}) =>
        ElectricalPanel(id: id, name: id, circuits: [
          for (final w in [
            _amps('A', 31.9),
            _amps('B', 0.8),
            _amps('C', 24.9),
            _amps('D', 30.4),
          ])
            labelled ? w.copyWith(assignedPhase: labels[w.id]) : w,
        ]);
    ElectricalProject reopen(ElectricalProject p) => ElectricalProject.fromJson(
        jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>);

    test('MDP = 3φ feeder + one 15 A 1φ way: the MDP sums the DB\'s '
        'LABELLED lines (31.2 / 24.9 + 15 / 31.9 = 39.9 A worst), live == '
        'reopened', () {
      final project = ElectricalProject(panels: [
        ElectricalPanel(id: 'MDP', name: 'MDP', circuits: [
          const ElectricalCircuit(
              id: 'f',
              name: 'Feeder DB',
              loadKind: LoadKind.feeder,
              feedsPanelId: 'DB',
              length: Length(10)),
          _amps('x', 15.0),
        ]),
        db(),
      ]);
      final live = computeSystem(_p, project, phaseReassignThresholdA: 1.0);
      final reopened =
          computeSystem(_p, reopen(project), phaseReassignThresholdA: 1.0);
      final dbLive = live.panels['DB']!.phaseBalance;
      expect(dbLive.l1, closeTo(31.2, 1e-6));
      expect(dbLive.l2, closeTo(24.9, 1e-6));
      expect(dbLive.l3, closeTo(31.9, 1e-6));
      // The feeder row prints exactly the DB schedule's lines.
      final row = live.panels['MDP']!.circuits
          .firstWhere((c) => c.circuitId == 'f')
          .lineCurrentsA!;
      expect(row, [
        closeTo(dbLive.l1, 1e-6),
        closeTo(dbLive.l2, 1e-6),
        closeTo(dbLive.l3, 1e-6),
      ]);
      // x (15 A) goes on the lightest labelled line (L2): 24.9 + 15 = 39.9.
      final mdp = live.panels['MDP']!.phaseBalance;
      expect(math.max(mdp.l1, math.max(mdp.l2, mdp.l3)), closeTo(39.9, 1e-6));
      for (final id in ['MDP', 'DB']) {
        final a = live.panels[id]!, b = reopened.panels[id]!;
        expect(b.incomer.breaker.ratingA.amperes,
            a.incomer.breaker.ratingA.amperes,
            reason: id);
        expect(b.phaseBalance.l1, a.phaseBalance.l1, reason: id);
        expect(b.phaseBalance.l2, a.phaseBalance.l2, reason: id);
        expect(b.phaseBalance.l3, a.phaseBalance.l3, reason: id);
      }
      expect(live.panels['MDP']!.incomer.breaker.ratingA.amperes,
          greaterThanOrEqualTo(39.9));
      // Without a persisted assignment the engine optimum governs:
      // 31.9 / 30.4 / 25.7 + 15 = 40.7 A worst -> 50 A.
      final bare = computeSystem(
          _p,
          ElectricalProject(panels: [
            project.panels.first,
            db(labelled: false),
          ]),
          phaseReassignThresholdA: 1.0);
      final m = bare.panels['MDP']!;
      expect(
          math.max(m.phaseBalance.l1,
              math.max(m.phaseBalance.l2, m.phaseBalance.l3)),
          closeTo(40.7, 1e-6));
      expect(m.incomer.breaker.ratingA.amperes, 50);
    });

    test('genset per-phase basis: two roots (the labelled DB + a 10 A way '
        'pinned to L3) ⇒ L3 = 31.9 + 10 = 41.9 A ⇒ √3·400·41.9 VA, live == '
        'reopened', () {
      final project = ElectricalProject(
        sources: const ElectricalSources(
            generator: GeneratorSource(backupFraction: 1.0)),
        panels: [
          db(),
          ElectricalPanel(
              id: 'B', name: 'B', circuits: [_amps('y', 10, pin: PhaseLine.l3)]),
        ],
      );
      final live = computeSystem(_p, project, phaseReassignThresholdA: 1.0);
      final back = reopen(project);
      final reopened = computeSystem(_p, back, phaseReassignThresholdA: 1.0);
      final a = gensetPhaseDemandVa(project, live);
      expect(a, closeTo(gensetPhaseDemandVa(back, reopened), 1e-6));
      expect(a, closeTo(math.sqrt(3) * 400 * 41.9, 1.0));
    });

    test('seeded property: random child boards / persisted labels ⇒ every '
        'incomer, the feeder row and the genset basis are identical live and '
        'reopened, and the feeder row is the DB schedule', () {
      final rng = math.Random(380);
      for (var trial = 0; trial < 60; trial++) {
        final n = 2 + rng.nextInt(7);
        final ways = [
          for (var i = 0; i < n; i++)
            _amps('w$i', (1 + rng.nextInt(400)) / 10.0).copyWith(
                assignedPhase: PhaseLine.values[rng.nextInt(3)]),
        ];
        final project = ElectricalProject(
          sources: const ElectricalSources(
              generator: GeneratorSource(backupFraction: 1.0)),
          panels: [
            ElectricalPanel(id: 'MDP', name: 'MDP', circuits: [
              const ElectricalCircuit(
                  id: 'f',
                  name: 'Feeder DB',
                  loadKind: LoadKind.feeder,
                  feedsPanelId: 'DB',
                  length: Length(10)),
              _amps('x', (1 + rng.nextInt(300)) / 10.0),
            ]),
            ElectricalPanel(id: 'DB', name: 'DB', circuits: ways),
          ],
        );
        final live = computeSystem(_p, project, phaseReassignThresholdA: 1.0);
        final back = reopen(project);
        final reopened = computeSystem(_p, back, phaseReassignThresholdA: 1.0);
        for (final id in ['MDP', 'DB']) {
          expect(live.panels[id]!.incomer.breaker.ratingA.amperes,
              reopened.panels[id]!.incomer.breaker.ratingA.amperes,
              reason: 'trial $trial $id');
        }
        expect(gensetPhaseDemandVa(project, live),
            closeTo(gensetPhaseDemandVa(back, reopened), 1e-6),
            reason: 'trial $trial');
        final dbb = live.panels['DB']!.phaseBalance;
        final row = live.panels['MDP']!.circuits
            .firstWhere((c) => c.circuitId == 'f')
            .lineCurrentsA;
        if (row != null) {
          expect(row[0], closeTo(dbb.l1, 1e-6), reason: 'trial $trial');
          expect(row[1], closeTo(dbb.l2, 1e-6), reason: 'trial $trial');
          expect(row[2], closeTo(dbb.l3, 1e-6), reason: 'trial $trial');
        }
      }
    });
  });

  test('the recommended APFC bank is bought beside an installed one: '
      '100 kW @ pf 0.6 (133.3 kvar) − 55 kvar ⇒ pf 0.787 ⇒ a further bank', () {
    final project = ElectricalProject(panels: [
      ElectricalPanel(id: 'mdp', name: 'MDP', circuits: [
        for (var i = 0; i < 4; i++)
          ElectricalCircuit(
              id: 'g$i',
              name: 'Load $i',
              loadKind: LoadKind.general,
              loadW: 25000,
              cosPhi: 0.6,
              phases: 3,
              length: const Length(10)),
        const ElectricalCircuit(
            id: 'cap',
            name: 'Capacitor',
            loadKind: LoadKind.capacitor,
            loadW: 55000,
            phases: 3,
            length: Length(5)),
      ]),
    ]);
    final sys = computeSystem(_p, project);
    final study = computeAdvancedStudy(_p, project, sys);
    final pf = study.powerFactor;
    // 25 kW × tan(acos 0.6) = 33.33 kvar each ⇒ 133.3 kvar of demand.
    expect(pf.totalKvar, closeTo(133.3, 0.1));
    expect(pf.needed, isTrue);
    expect(pf.bankKvar, greaterThan(0));
    final descs = study.bom.lines.map((l) => l.description).toList();
    expect(descs.where((d) => d.startsWith('Capacitor bank 55 kvar')),
        hasLength(1));
    expect(descs.where((d) => d.contains('APFC, recommended')), hasLength(1));
  });

  group('the device CLASS follows the bus fault', () {
    ElectricalProject hotel({double? txKva}) => ElectricalProject(
          transformerKva: txKva == null
              ? null
              : ApparentPower.kilovoltAmperes(txKva),
          panels: [
            ElectricalPanel(id: 'mdp', name: 'LVMDP', circuits: [
              const ElectricalCircuit(
                  id: 'lt',
                  name: 'Lighting',
                  loadKind: LoadKind.lighting,
                  loadW: 2000,
                  length: Length(20)),
              for (var i = 0; i < 8; i++)
                ElectricalCircuit(
                    id: 'h$i',
                    name: 'Heater $i',
                    loadKind: LoadKind.heating,
                    loadW: 60000,
                    cosPhi: 1,
                    phases: 3,
                    length: const Length(10)),
            ]),
          ],
        );

    test('1000 kVA ⇒ 1e6 / (√3·400·0.04) = 36.08 kA > the 25 kA MCB ladder: '
        'the 16 A way is an MCCB and no Icu error remains', () {
      final project = hotel(txKva: 1000);
      final origin = estimatedServiceFaultLevelA(project)!;
      expect(origin.amperes, closeTo(36084.4, 1));
      final sys = computeSystem(_p, project, originFaultLevel: origin);
      final lt = sys.panels['mdp']!.circuits
          .singleWhere((c) => c.circuitId == 'lt');
      expect(lt.breaker.ratingA.amperes, 16);
      expect(lt.breaker.deviceClass, BreakerClass.mccb);
      final fs = faultStudy(sys, project, _p, originFaultLevel: origin);
      expect(
          fs.warnings.where((w) =>
              w.code == 'breaking-capacity-inadequate' && w.circuitId == 'lt'),
          isEmpty);
    });

    test('a 16 kA bus keeps the MCB (byte-identical)', () {
      final sys = computeSystem(_p, hotel(),
          originFaultLevel: const Current(16000));
      final lt = sys.panels['mdp']!.circuits
          .singleWhere((c) => c.circuitId == 'lt');
      expect(lt.breaker.deviceClass, BreakerClass.mcb);
    });

    test('faultAwareBreakerClass: exactly 25 kA stays an MCB, above it an '
        'MCCB of the same rating', () {
      const b = BreakerResult(
          ratingA: Current(16),
          deviceClass: BreakerClass.mcb,
          curve: BreakerCurve.c);
      expect(faultAwareBreakerClass(b, const Current(25000)).deviceClass,
          BreakerClass.mcb);
      final up = faultAwareBreakerClass(b, const Current(25001));
      expect(up.deviceClass, BreakerClass.mccb);
      expect(up.ratingA.amperes, 16);
      expect(faultAwareBreakerClass(b, null).deviceClass, BreakerClass.mcb);
    });

    test('an Icu-short feeder carries the error alone — no contradictory '
        '"100 % Ics" advice (2500 kVA ⇒ 90.2 kA > the 70 kA MCCB top)', () {
      final project = ElectricalProject(
        transformerKva: ApparentPower.kilovoltAmperes(2500),
        panels: [
          const ElectricalPanel(id: 'mdp', name: 'MDP', circuits: [
            ElectricalCircuit(
                id: 'f',
                name: 'F-LP1',
                loadKind: LoadKind.feeder,
                feedsPanelId: 'lp',
                length: Length(5)),
          ]),
          const ElectricalPanel(id: 'lp', name: 'LP-1', circuits: [
            ElectricalCircuit(
                id: 'l',
                name: 'Lamp',
                loadKind: LoadKind.lighting,
                loadW: 500,
                length: Length(10)),
          ]),
        ],
      );
      final origin = estimatedServiceFaultLevelA(project)!;
      expect(origin.amperes / 1000, closeTo(90.2, 0.1));
      final sys = computeSystem(_p, project, originFaultLevel: origin);
      final fs = faultStudy(sys, project, _p, originFaultLevel: origin);
      final ws = fs.warnings.where((w) => w.circuitId == 'f').toList();
      expect(ws.where((w) => w.code == 'breaking-capacity-inadequate'),
          hasLength(1));
      expect(ws.where((w) => w.code == 'service-capacity-inadequate'), isEmpty);
    });
  });

  test('the schedule prints the Icw basis: at 0.1 s the 1/√0.1 = 3.16× figure '
      'carries "/0.1s"; at 1 s it is the bare conventional Icw', () {
    final project = ElectricalProject(panels: [
      ElectricalPanel(id: 'mdp', name: 'MDP', circuits: [
        for (var i = 0; i < 3; i++)
          ElectricalCircuit(
              id: 'h$i',
              name: 'H$i',
              loadKind: LoadKind.heating,
              loadW: 20000,
              cosPhi: 1,
              phases: 3,
              length: const Length(10)),
      ]),
    ]);
    String header(double t) {
      final sys = computeSystem(_p, project,
          originFaultLevel: const Current(16000), busbarClearingTimeS: t);
      final sheet = buildElectricalPanelDetail(
          project: project, result: sys, panelId: 'mdp');
      return _labels(sheet).singleWhere((l) => l.startsWith('Incomer '));
    }

    expect(header(0.1), matches(RegExp(r'Icw [0-9.]+kA/0\.1s')));
    final at1 = header(1.0);
    expect(at1, contains('Icw '));
    expect(at1, isNot(contains('kA/')));
  });

  test('a TT feeder RCD prints its time-delayed S marker (the BOM orders S)',
      () {
    const project = ElectricalProject(
      earthingSystem: EarthingSystem.tt,
      panels: [
        ElectricalPanel(id: 'mdp', name: 'MDP', circuits: [
          ElectricalCircuit(
              id: 'f',
              name: 'F-SDP',
              loadKind: LoadKind.feeder,
              feedsPanelId: 'sdp',
              length: Length(20)),
        ]),
        ElectricalPanel(id: 'sdp', name: 'SDP-1', circuits: [
          ElectricalCircuit(
              id: 's',
              name: 'Sockets',
              loadKind: LoadKind.socket,
              loadW: 2000,
              length: Length(15)),
        ]),
      ],
    );
    final sys = computeSystem(_p, project);
    final f = sys.panels['mdp']!.circuits.single;
    expect(f.rcd.required, isTrue);
    expect(f.rcd.timeDelayed, isTrue);
    final sheet =
        buildElectricalPanelDetail(project: project, result: sys, panelId: 'mdp');
    expect(_labels(sheet).any((l) => RegExp(r'RCD 300mA \w+ S$').hasMatch(l)),
        isTrue);
    expect(sheet.legend.any((e) => e.code == 'S'), isTrue);
  });

  group('a typed phase / cos φ re-derives the minted MEP FLC', () {
    // 3 kW shaft pump, input 3333 W, minted 3φ @ 0.85: 3333 / (√3·400·0.85)
    // = 5.66 A.
    ElectricalPanel board(
            {int phases = 3,
            double cosPhi = 0.85,
            bool phasesSet = false,
            bool cosSet = false}) =>
        ElectricalPanel(id: 'mep', name: 'MEP', circuits: [
          ElectricalCircuit(
            id: 'mep-p1',
            name: 'Pump',
            loadKind: LoadKind.pump,
            loadW: 3333,
            motorKw: 3,
            cosPhi: cosPhi,
            phases: phases,
            phasesUserSet: phasesSet,
            cosPhiUserSet: cosSet,
            sourceEquipmentId: 'p1',
            flaOverrideA: const Current(5.66),
            length: const Length(10),
          ),
        ]);

    test('untouched ⇒ the mint verbatim: 5.7 A, 6 A', () {
      final c = computePanel(_p, board()).circuits.single;
      expect(c.designCurrent.amperes, closeTo(5.7, 1e-9));
      expect(c.breaker.ratingA.amperes, 6);
    });

    test('typed 1φ ⇒ 3333 / (231·0.85) = 16.97 A ⇒ 20 A (never 6 A)', () {
      final c = computePanel(_p, board(phases: 1, phasesSet: true))
          .circuits
          .single;
      expect(c.threePhase, isFalse);
      expect(c.designCurrent.amperes, closeTo(17.0, 1e-9));
      expect(c.breaker.ratingA.amperes, 20);
    });

    test('typed cos φ 0.7 ⇒ 3333 / (√3·400·0.7) = 6.87 A ⇒ 10 A', () {
      final c = computePanel(_p, board(cosPhi: 0.7, cosSet: true))
          .circuits
          .single;
      expect(c.designCurrent.amperes, closeTo(6.9, 1e-9));
      expect(c.breaker.ratingA.amperes, 10);
    });
  });

  group('ONE LV ceiling', () {
    test('property: declaring the recommended daya never makes the service '
        'MV, and LV/MV agrees with whether an LV daya exists', () {
      for (var va = 1000.0; va <= 260000; va += 1500) {
        final d =
            recommendedDaya(ApparentPower(va), ElectricalSystem.threePhase);
        final level = determineSupply(ApparentPower(va)).lvOrMv;
        expect(level == SupplyLevel.lv, d != null, reason: 'va=$va');
        if (d == null) continue;
        expect(d.va, lessThanOrEqualTo(plnLvServiceCeilingVa));
        final declared = ElectricalProject(supplyCapacityVa: ApparentPower(d.va));
        expect(isDeclaredMvService(declared), isFalse, reason: 'va=$va');
      }
    });

    test('198 kVA (9 × 22 kW) is MV with no LV daya, consistently', () {
      expect(recommendedDaya(
              ApparentPower.kilovoltAmperes(198), ElectricalSystem.threePhase),
          isNull);
      expect(determineSupply(ApparentPower.kilovoltAmperes(198)).lvOrMv,
          SupplyLevel.mv);
    });
  });

  group('a 1φ root board on a 3φ-only daya', () {
    // 5 × 3 kW heaters on a 1φ 230 V root: 15 000 / 230 = 65.2 A.
    ElectricalProject house({double? daya}) => ElectricalProject(
          supplyCapacityVa: daya == null ? null : ApparentPower(daya),
          panels: [
            ElectricalPanel(
              id: 'r',
              name: 'Root',
              system: ElectricalSystem.singlePhase,
              voltage: const Voltage(230),
              circuits: [
                for (var i = 0; i < 5; i++)
                  ElectricalCircuit(
                      id: 'h$i',
                      name: 'H$i',
                      loadKind: LoadKind.heating,
                      loadW: 3000,
                      cosPhi: 1,
                      phases: 1,
                      length: const Length(10)),
              ],
            ),
          ],
        );

    test('16.5 kVA 3φ limits 16 500 / (√3·400) = 23.8 A per phase: the 65.2 A '
        'one-phase board trips it — both warnings raised', () {
      final sys = computeSystem(_p, house(daya: 16500));
      final codes = sys.warnings.map((w) => w.code).toList();
      expect(codes, contains('service-single-phase-root-on-three-phase-daya'));
      expect(codes, contains('service-capacity-below-demand'));
    });

    test('the recommendation sizes on the same 3φ per-phase basis: '
        '√3·400·65.2 = 45.2 kVA ⇒ 53 kVA, and declaring it passes the judge',
        () {
      final undeclared = house();
      final sys = computeSystem(_p, undeclared);
      final study = computeAdvancedStudy(_p, undeclared, sys);
      expect(study.recommendedDayaVa, 53000);
      expect(study.recommendedDayaThreePhase, isTrue);
      final declared = computeSystem(_p, house(daya: 53000));
      expect(
          declared.warnings
              .where((w) => w.code == 'service-capacity-below-demand'),
          isEmpty);
    });

    test('a 1φ ladder step keeps the board basis (no new warning)', () {
      final sys = computeSystem(_p, house(daya: 13900));
      expect(
          sys.warnings.where((w) =>
              w.code == 'service-single-phase-root-on-three-phase-daya'),
          isEmpty);
    });
  });

  test('PFC: 6.016 kW @ pf 0.91 has 2.74 kvar of demand — below the 5 kvar '
      'smallest step, so no bank and no false "would raise it" claim', () {
    const project = ElectricalProject(panels: [
      ElectricalPanel(
        id: 'h',
        name: 'House',
        system: ElectricalSystem.singlePhase,
        voltage: Voltage(230),
        circuits: [
          ElectricalCircuit(
              id: 'g',
              name: 'Load',
              loadKind: LoadKind.general,
              loadW: 6016,
              cosPhi: 0.91,
              length: Length(10)),
        ],
      ),
    ]);
    final sys = computeSystem(_p, project);
    final pf = powerFactorCorrection(sys, project);
    // 6.016 × tan(acos 0.91) = 6.016 × 0.4556 = 2.74 kvar.
    expect(pf.totalKvar, closeTo(2.7, 0.05));
    expect(pf.bankKvar, 0);
    expect(pf.note, isNot(contains('would raise')));
    expect(pf.note, contains('smallest standard capacitor step'));
  });

  test('a 3φ feeder prints its fed board\'s REAL lines: two 7 kW heaters ⇒ '
      '30.3 / 30.3 / 0.0, matching the TOTAL footer', () {
    final project = ElectricalProject(panels: [
      const ElectricalPanel(id: 'mdp', name: 'MDP', circuits: [
        ElectricalCircuit(
            id: 'f',
            name: 'F-DB',
            loadKind: LoadKind.feeder,
            feedsPanelId: 'db',
            length: Length(10)),
      ]),
      ElectricalPanel(id: 'db', name: 'DB', circuits: [
        for (var i = 0; i < 2; i++)
          ElectricalCircuit(
              id: 'h$i',
              name: 'H$i',
              loadKind: LoadKind.heating,
              loadW: 7000,
              cosPhi: 1,
              phases: 1,
              length: const Length(10)),
      ]),
    ]);
    final sys = computeSystem(_p, project);
    final f = sys.panels['mdp']!.circuits.single;
    // 7000 / 231 = 30.3 A each, on two lines.
    expect(f.lineCurrentsA!..sort(), [0.0, 30.3, 30.3]);
    final sheet =
        buildElectricalPanelDetail(project: project, result: sys, panelId: 'mdp');
    final phaseTexts = [
      for (final p in sheet.prims)
        if (p is SldLabel &&
            (p.role == SldRole.phaseR ||
                p.role == SldRole.phaseS ||
                p.role == SldRole.phaseT) &&
            RegExp(r'^[0-9.]+$').hasMatch(p.text))
          p.text,
    ];
    // Row (3) + TOTAL (3): 30.3 × 4, 0.0 × 2 — never 30.3 × 5.
    expect(phaseTexts.where((t) => t == '30.3'), hasLength(4));
    expect(phaseTexts.where((t) => t == '0.0'), hasLength(2));
    // And the MDP incomer (32 A on 30.3 A) sits below the floored feeder:
    // an outgoing device above its own incomer is now reported.
    final inv = sys.warnings.where(
        (w) => w.code == 'outgoing-exceeds-incomer' && w.circuitId == 'f');
    expect(inv, hasLength(1));
    // Floored by the engine (no override) => info, not a blocker.
    expect(inv.single.severity, WarningSeverity.info);
  });

  test('an OVERRIDE-caused outgoing-above-incomer stays a warning', () {
    const project = ElectricalProject(panels: [
      ElectricalPanel(id: 'db', name: 'DB', system: ElectricalSystem.singlePhase, circuits: [
        ElectricalCircuit(id: 'a', name: 'Socket', loadKind: LoadKind.socket, loadW: 1000, length: Length(10)),
        ElectricalCircuit(id: 'b', name: 'Big', loadKind: LoadKind.socket, loadW: 500, length: Length(10), breakerOverrideA: Current(63)),
      ]),
    ]);
    final sys = computeSystem(_p, project);
    final inv = sys.warnings.where(
        (w) => w.code == 'outgoing-exceeds-incomer' && w.circuitId == 'b');
    expect(inv, hasLength(1));
    expect(inv.single.severity, WarningSeverity.warning);
  });

  test('the electrical layout plan colours the SAME essential set as the '
      'single-lines: named DARURAT and its child', () {
    LayoutPos at(double x) =>
        LayoutPos(sheetId: 's', floorIndex: 0, x: x, y: 100);
    final project = ElectricalProject(panels: [
      ElectricalPanel(id: 'mdp', name: 'MDP', layoutPos: at(10), circuits: [
        const ElectricalCircuit(
            id: 'f1',
            name: 'F-EP',
            loadKind: LoadKind.feeder,
            feedsPanelId: 'ep',
            length: Length(10)),
      ]),
      ElectricalPanel(
          id: 'ep',
          name: 'PANEL DARURAT',
          layoutPos: at(100),
          circuits: [
            const ElectricalCircuit(
                id: 'f2',
                name: 'F-SUB',
                loadKind: LoadKind.feeder,
                feedsPanelId: 'ep1',
                length: Length(10)),
          ]),
      ElectricalPanel(id: 'ep1', name: 'SUB 1', layoutPos: at(200), circuits: [
        ElectricalCircuit(
            id: 'lamp',
            name: 'Lamp',
            loadKind: LoadKind.lighting,
            loadW: 200,
            loadPos: at(260),
            length: const Length(5)),
      ]),
    ]);
    final sys = computeSystem(_p, project);
    for (final result in [sys, null]) {
      final plan = buildElectricalPlanData(
          project: project, result: result, sheetId: 's', floorIndex: 0);
      bool essOf(String tag) =>
          plan.nodes.singleWhere((n) => n.tag == tag).essential;
      expect(essOf('MDP'), isFalse);
      expect(essOf('PANEL DARURAT'), isTrue);
      expect(essOf('SUB 1'), isTrue);
      expect(essOf('Lamp'), isTrue);
    }
    expect(essentialPanelIds(project, sys), {'ep', 'ep1'});
  });

  test('a feeder-kind way with no target is reported, never silently '
      'scheduled', () {
    final r = computePanel(
        _p,
        const ElectricalPanel(id: 'p', name: 'P', circuits: [
          ElectricalCircuit(
              id: 'x',
              name: 'Feeder to LP-1',
              loadKind: LoadKind.feeder,
              length: Length(22)),
        ]));
    expect(r.warnings.where((w) => w.code == 'feeder-without-target'),
        hasLength(1));
  });

  test('a 1φ sub-board\'s schedule prints its loads under its FEEDER\'s phase',
      () {
    final project = ElectricalProject(panels: [
      const ElectricalPanel(id: 'mdp', name: 'MDP', circuits: [
        ElectricalCircuit(
            id: 'h',
            name: 'Heater',
            loadKind: LoadKind.heating,
            loadW: 9000,
            cosPhi: 1,
            phases: 1,
            phaseOverride: PhaseLine.l1,
            length: Length(10)),
        ElectricalCircuit(
            id: 'f',
            name: 'F-LP',
            loadKind: LoadKind.feeder,
            feedsPanelId: 'lp',
            phases: 1,
            length: Length(10)),
      ]),
      ElectricalPanel(
        id: 'lp',
        name: 'LP-1',
        system: ElectricalSystem.singlePhase,
        voltage: const Voltage(230),
        circuits: [
          for (var i = 0; i < 3; i++)
            ElectricalCircuit(
                id: 'l$i',
                name: 'Lamp $i',
                loadKind: LoadKind.lighting,
                loadW: 1500,
                length: const Length(10)),
        ],
      ),
    ]);
    final sys = computeSystem(_p, project);
    final feederPhase = sys.panels['mdp']!.circuits
        .singleWhere((c) => c.circuitId == 'f')
        .phase;
    // The 9 kW heater is pinned to L1, so the balancer puts the feeder on L2.
    expect(feederPhase, isNot(PhaseAssignment.l1));
    final expected =
        feederPhase == PhaseAssignment.l2 ? SldRole.phaseS : SldRole.phaseT;
    final sheet =
        buildElectricalPanelDetail(project: project, result: sys, panelId: 'lp');
    final roles = [
      for (final p in sheet.prims)
        if (p is SldLabel &&
            RegExp(r'^[0-9.]+$').hasMatch(p.text) &&
            (p.role == SldRole.phaseR ||
                p.role == SldRole.phaseS ||
                p.role == SldRole.phaseT))
          p.role,
    ];
    expect(roles, isNotEmpty);
    expect(roles.every((r) => r == expected), isTrue);
  });
}
