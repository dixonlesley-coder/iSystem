/// Round 30 electrical seed suite (2026-10-18):
///   * regression-dual-tx-declared-capacity-doubled — a declared PLN
///     connection capacity is the TOTAL connection: a dual service splits it
///     across its two sections, and above the ladder top it is n × 2500 kVA.
///   * costing-2-3 — SPD BOM lines carry their 3+N / 1+N connection.
///   * report-parity-2-2..5 — the electrical calc report: undiversified
///     connected load per board, verification tiers, fixed 0.1 precision,
///     localized severity / phase / genset tokens.
library;

import 'dart:math' as math;

import 'package:mechx_engine/electrical/advanced_study.dart';
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/fault.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/panel_results.dart';
import 'package:mechx_engine/electrical/power_oneline.dart';
import 'package:mechx_engine/electrical/supply_design.dart';
import 'package:mechx_engine/report/electrical_calc_report.dart';
import 'package:mechx_engine/report/report_strings.dart';
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
      // Loading: Round 37 r2 — this project has ONE service-entrance board,
      // which sits on one section (coupler normally open), so that section
      // carries the WHOLE demand (the incomer floor's and the
      // service-capacity judge's basis too): 500 × 0.8 = 400 kVA against the
      // 800 kVA demand ⇒ flagged. (Several roots keep demand / 2.)
      final whole = sys.supply.demandVa.inKilovoltAmperes;
      expect(whole, closeTo(800, 0.1));
      expect(adv.supply.declaredBelowDemand, isTrue);
      expect(adv.supply.declaredBelowDemand, 500 * 0.8 < whole - 1e-9);
      // Fault: one section's unit (coupler N.O.), never 2 × 1000 kVA:
      // 500e3 / (√3 · 400 · 0.04) = 18 042.2 A, floored at the study unit
      // and 16 kA.
      final isc = estimatedServiceFaultLevelA(pr,
              demand: sys.supply.demandVa)!
          .amperes;
      expect(isc, lessThan(1000000 / (math.sqrt(3) * 400 * 0.04)));
    });

    test('above the ladder top: 3 465 kVA single service ⇒ 2 units on the '
        'smallest covering rung, 2 × 2000 kVA (never one non-standard 3465 '
        'kVA unit; Round 45: never 2 × 2500 either)', () {
      // n = ceil(3465 / 2500) = 2; share 1732.5 kVA ⇒ the 2000 kVA rung.
      final pr = _project(capVa: 3465000, loadW: 2000000);
      final d = declaredServiceTransformer(pr)!;
      expect(d.kva.inKilovoltAmperes, 2000);
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
          // Round 45 — n = the fewest top-rung units per section, then the
          // smallest rung covering the per-unit share.
          final n = d.units ~/ sections;
          final top = transformerKvaLadder.last;
          expect((n - 1) * top, lessThan(cap / 1000 / sections),
              reason: '$cap');
          for (final k in transformerKvaLadder.where((k) => k < kva)) {
            expect(k * n, lessThan(cap / 1000 / sections), reason: '$cap');
          }
        }
      }
    });
  });

  group('SPD lines carry their connection', () {
    test('3φ MDP feeding a 1φ LP: two SPD lines, 3+N and 1+N, never merged',
        () {
      const pr = ElectricalProject(
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

  group('electrical calc report parity', () {
    // MDP (diversity 0.7) feeding LP-1 (diversity 0.7).
    const pr = ElectricalProject(
      id: 'pr',
      name: 'Report',
      panels: [
        ElectricalPanel(
          id: 'MDP',
          name: 'MDP',
          system: ElectricalSystem.threePhase,
          voltage: const Voltage(400),
          diversityFactor: 0.7,
          circuits: [
            ElectricalCircuit(
                id: 'h',
                name: 'Heater',
                loadKind: LoadKind.heating,
                loadW: 20000,
                phases: 3,
                length: const Length(10)),
            const ElectricalCircuit(
                id: 'f',
                name: 'LP feed',
                feedsPanelId: 'LP',
                length: Length(20)),
          ],
        ),
        ElectricalPanel(
          id: 'LP',
          name: 'LP-1',
          system: ElectricalSystem.threePhase,
          voltage: const Voltage(400),
          diversityFactor: 0.7,
          circuits: [
            ElectricalCircuit(
                id: 'l',
                name: 'Lights',
                loadKind: LoadKind.lighting,
                loadW: 6050,
                length: const Length(15)),
            ElectricalCircuit(
                id: 's',
                name: 'Sockets',
                loadKind: LoadKind.socket,
                loadW: 5000,
                length: const Length(15)),
          ],
        ),
      ],
    );
    final sys = computeSystem(p, pr);
    ElectricalCalcReportData data({List<String> verify = const []}) =>
        ElectricalCalcReportData(
          projectName: 'R',
          date: '2026-10-18',
          standardsName: p.name,
          standardsRevision: p.revision,
          project: pr,
          result: sys,
          verifyItems: verify,
          verifyChecklist: p.verifyChecklist,
        );
    String w(double v) =>
        v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);

    test('the root board prints the SAME undiversified connected load as the '
        'design basis (sub-board diversity never leaks into connected)', () {
      final md = buildElectricalCalcReport(data());
      // Supply connected = Σ undiversified leaves (the feeder excluded).
      final supplyW = sys.supply.connectedW;
      final undiv = [
        for (final pp in sys.panels.values)
          for (final c in pp.circuits)
            if (c.circuitId != 'f') c.connectedWOrLoad,
      ].fold<double>(0, (a, x) => a + x);
      expect(supplyW, closeTo(undiv, 1e-6));
      // The engine's MDP connectedW counts the feeder at LP-1's DIVERSIFIED
      // demand — below the undiversified total.
      final mdpW = sys.panels['MDP']!.connectedW;
      expect(mdpW, lessThan(supplyW - 1));
      expect(md, contains('connected ${w(supplyW)} W'));
      expect(md, isNot(contains('connected ${w(mdpW)} W')));
    });

    test('every checklist value prints with its tier; U0 prints once; ID '
        'carries the English-note lead', () {
      final md = buildElectricalCalcReport(
          data(verify: const [faultStudyU0VerifyItem, 'other item']));
      expect(md, contains('other item'));
      expect(md, isNot(contains(faultStudyU0VerifyItem)));
      for (final v in p.verifyChecklist) {
        expect(md, contains('**${v.citation}**'), reason: v.citation);
      }
      expect(
          md, contains(const ReportStrings.en()(RptStringKey.statusNotSni)));
      final id = buildElectricalCalcReport(
          data(verify: const ['other item']), const ReportStrings.id());
      expect(id, contains('(catatan dalam bahasa Inggris) other item'));
    });

    test('currents and percentages at one fixed 0.1 precision', () {
      final md = buildElectricalCalcReport(data());
      final bal = RegExp(
          r'L1 (\S+) A · L2 (\S+) A · L3 (\S+) A \(imbalance (\S+) %\)');
      final ms = bal.allMatches(md).toList();
      expect(ms, isNotEmpty);
      for (final m in ms) {
        for (var g = 1; g <= 4; g++) {
          expect(m.group(g), matches(RegExp(r'^\d+\.\d$')),
              reason: m.group(0));
        }
      }
    });

    test('ID: severity tags, the 3-phase cell and the genset mode localize',
        () {
      ElectricalCalcReportData d(WarningSeverity sev) =>
          ElectricalCalcReportData(
            projectName: 'R',
            date: '2026-10-18',
            standardsName: p.name,
            standardsRevision: p.revision,
            project: pr,
            result: sys,
            powerOneLine: const PowerOneLine(nodes: [
              PowerNode(
                  id: 'gen',
                  kind: PowerNodeKind.generator,
                  label: 'Generator',
                  sub: '82 kVA Standby'),
            ], edges: [], interlocks: []),
            allWarnings: [
              ElectricalWarning(code: 'x', message: 'm', severity: sev),
            ],
          );
      final id = buildElectricalCalcReport(
          d(WarningSeverity.warning), const ReportStrings.id());
      expect(id, contains('82 kVA Siaga'));
      expect(id, isNot(contains('82 kVA Standby')));
      expect(id, contains('| 3 fasa |'));
      expect(id, isNot(contains('| 3ph |')));
      expect(id, contains('_PERINGATAN_'));
      final en = buildElectricalCalcReport(d(WarningSeverity.error));
      expect(en, contains('_ERROR_'));
      expect(en, contains('| 3ph |'));
      expect(en, contains('82 kVA Standby'));
    });
  });
}
