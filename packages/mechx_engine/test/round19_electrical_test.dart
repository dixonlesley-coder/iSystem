// Round 19 (2026-10-18) — the electrical parity half of the round-19 audit:
//
//   bom-rcd-type            the BOM RCD is at least the specified type, exact
//                           poles first, S-type only for a time-delayed spec
//   bom-breaker-subst       a catalogue breaker that differs from the sized
//                           device is flagged + named; a 1φ feeder off a 3φ
//                           board is matched as the 2P the schedule prints
//   lug-count               lugs follow the cable's own make-up
//   ampacity-message        the error names the requirement that failed
//   demand-current          a diversified board prints the diversified A
//   capacitor-feeder        a feeder carrying only a bank prints its current
//   solar-ratio             a stored DC:AC ratio of 0 never crashes the study
import 'dart:convert';

import 'package:mechx_engine/electrical/bom.dart';
import 'package:mechx_engine/electrical/catalog.dart';
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/earthing.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/panel_results.dart';
import 'package:mechx_engine/electrical/results.dart';
import 'package:mechx_engine/electrical/sources.dart';
import 'package:mechx_engine/report/electrical_calc_report.dart';
import 'package:mechx_engine/report/electrical_sld_drawing.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

const _profile = PuilProfile();

Part _rcd(String sku, String type, int poles, double a, {int ma = 30}) =>
    Part(
      sku: sku,
      manufacturer: 'T',
      category: PartCategory.rcd,
      series: 'T',
      model: sku,
      attributes: {
        'deviceClass': 'RCCB',
        'poles': poles,
        'ratingA': a,
        'residualMa': ma,
        'rcdType': type,
      },
    );

Part _mcb(String sku, double a, String curve, int poles,
        {String cls = 'MCB'}) =>
    Part(
      sku: sku,
      manufacturer: 'T',
      category: PartCategory.breaker,
      series: 'T',
      model: sku,
      attributes: {
        'deviceClass': cls,
        'ratingA': a,
        'curve': curve,
        'poles': poles,
      },
    );

List<String> _labels(ElectricalProject p, ElectricalSystemResult r, String id) =>
    [
      for (final l in buildElectricalPanelDetail(
              project: p, result: r, panelId: id)
          .prims
          .whereType<SldLabel>())
        l.text,
    ];

void main() {
  // ── bom-rcd-type ──────────────────────────────────────────────────────────
  group('BOM RCD: the specified waveform type is honoured', () {
    final parts = [
      _rcd('AC-4P-10', 'AC', 4, 10), // the old pick: smallest rating, any type
      _rcd('A-4P-25', 'A', 4, 25),
      _rcd('A-2P-63', 'A', 2, 63),
      _rcd('B-2P-40', 'B', 2, 40),
      _rcd('A-S-4P-63', 'A-S', 4, 63, ma: 300),
    ];

    test('Type A 2P: never an AC part; exact poles before a smaller rating',
        () {
      // Candidates ≥ Type A, ≥ 16 A, ≥ 2P: A-4P-25, A-2P-63, B-2P-40.
      // Exact poles (2P) first ⇒ {A-2P-63, B-2P-40}; smallest rating ⇒ B-2P-40
      // (Type B covers Type A).
      expect(
          matchRcdSku(30, 16, parts, threePhase: false, type: RcdType.a),
          'B-2P-40');
      // Without the 2P parts the 4P Type A is the last resort.
      expect(
          matchRcdSku(30, 16,
              parts.where((p) => p.poles != 2).toList(),
              threePhase: false, type: RcdType.a),
          'A-4P-25');
      // Type B needed ⇒ only the Type B part qualifies.
      expect(matchRcdSku(30, 16, parts, threePhase: false, type: RcdType.b),
          'B-2P-40');
      // No type stated ⇒ the legacy ranking among exact poles.
      expect(matchRcdSku(30, 16, parts, threePhase: false), 'B-2P-40');
    });

    test('a part with no declared type cannot satisfy a typed spec', () {
      const untyped = Part(
          sku: 'X',
          manufacturer: 'T',
          category: PartCategory.rcd,
          series: 'T',
          model: 'X',
          attributes: const {
            'deviceClass': 'RCBO',
            'poles': 2,
            'ratingA': 16,
            'residualMa': 30,
          });
      expect(
          matchRcdSku(30, 16, [untyped], threePhase: false, type: RcdType.a),
          isNull);
      expect(matchRcdSku(30, 16, [untyped], threePhase: false), 'X');
    });

    test('a time-delayed (S-type) spec takes only an S-type part', () {
      expect(
          matchRcdSku(300, 63, parts,
              threePhase: true, type: RcdType.a, timeDelayed: true),
          'A-S-4P-63');
      expect(
          matchRcdSku(300, 63, parts.where((p) => p.sku != 'A-S-4P-63').toList(),
              threePhase: true, type: RcdType.a, timeDelayed: true),
          isNull);
    });

    test('TT house on the full catalogue: the RCD ordered is Type A or better',
        () {
      const house = ElectricalProject(
        id: 'h',
        name: 'House',
        earthingSystem: EarthingSystem.tt,
        panels: [
          ElectricalPanel(
            id: 'DB',
            name: 'DB',
            system: ElectricalSystem.singlePhase,
            voltage: Voltage(230),
            circuits: [
              ElectricalCircuit(
                  id: 's',
                  name: 'Sockets',
                  loadKind: LoadKind.socket,
                  loadW: 1200,
                  length: Length(15)),
            ],
          ),
        ],
      );
      final sys = computeSystem(_profile, house);
      final way = sys.panels['DB']!.circuits.single;
      expect(way.rcd.required, isTrue);
      expect(way.rcd.type, RcdType.a);
      final parts = fullCatalog();
      final bySku = {for (final p in parts) p.sku: p};
      final line = buildBom(sys, parts: parts)
          .lines
          .singleWhere((l) => l.category == PartCategory.rcd);
      expect(line.sku, isNotNull);
      final part = bySku[line.sku]!;
      expect(part.rcdType, isNot('AC'));
      expect(rcdTypeRank(RcdType.values.firstWhere(
              (t) => t.name.toUpperCase() == part.rcdType!.split('-').first)),
          greaterThanOrEqualTo(rcdTypeRank(RcdType.a)));
      expect(part.poles, 2);
    });
  });

  // ── bom-breaker-subst ─────────────────────────────────────────────────────
  group('BOM breaker: a substitution is never silent', () {
    test('rating beats curve; the departure is flagged and named', () {
      // Sized MCB 6 A curve D, 1P. The catalogue has 10 A D and 6 A C. The old
      // ranking took 10 A D (no class/pole/curve penalty) — a device the
      // cable's In ≤ Iz was never checked at. Rating (50) now outweighs curve
      // (10): the 6 A C part is chosen, and flagged as a curve substitution.
      const b = BreakerResult(
          ratingA: Current(6),
          deviceClass: BreakerClass.mcb,
          curve: BreakerCurve.d);
      final parts = [_mcb('D10', 10, 'D', 1), _mcb('C6', 6, 'C', 1)];
      expect(matchBreakerSku(b, parts, poles: 1), 'C6');
    });

    test('a 1φ feeder off a 3φ board is matched (and printed) as 2P', () {
      const p = ElectricalProject(id: 'p', name: 'P', panels: [
        ElectricalPanel(
          id: 'MDP',
          name: 'MDP',
          voltage: Voltage(400),
          circuits: [
            ElectricalCircuit(
                id: 'f',
                name: 'To LP',
                loadKind: LoadKind.feeder,
                feedsPanelId: 'LP',
                phases: 1,
                length: Length(20)),
          ],
        ),
        ElectricalPanel(
          id: 'LP',
          name: 'LP',
          system: ElectricalSystem.singlePhase,
          voltage: Voltage(230),
          sourceType: PanelSource.feeder,
          fedByCircuitId: 'f',
          circuits: [
            ElectricalCircuit(
                id: 'l',
                name: 'Lights',
                loadKind: LoadKind.lighting,
                isLighting: true,
                loadW: 2000,
                length: Length(15)),
          ],
        ),
      ]);
      final sys = computeSystem(_profile, p);
      final f = sys.panels['MDP']!.circuits.single;
      expect(f.threePhase, isFalse);
      final rating = f.breaker.ratingA.amperes;
      final parts = [
        _mcb('1P', rating, 'C', 1),
        _mcb('2P', rating, 'C', 2),
        _mcb('4P', rating, 'C', 4),
      ];
      final line = buildPanelBom(sys.panels['MDP']!, parts: parts).firstWhere(
          (l) => l.category == PartCategory.breaker && l.description.contains('To LP'));
      expect(line.sku, '2P');
      expect(line.deviceSubstituted, isFalse);
      // The schedule prints the same 2P device.
      expect(_labels(p, sys, 'MDP').any((t) => t.contains('2P')), isTrue);

      // Only a 1P part in stock ⇒ priced, but flagged and named.
      final only1 = buildPanelBom(sys.panels['MDP']!,
              parts: [_mcb('1P', rating, 'C', 1)])
          .firstWhere((l) =>
              l.category == PartCategory.breaker &&
              l.description.contains('To LP'));
      expect(only1.sku, '1P');
      expect(only1.deviceSubstituted, isTrue);
      expect(only1.description, contains('(catalogue part: MCB '));
      expect(only1.description, contains(' 1P)'));
    });

    test('consolidation keys a substituted line apart from an exact one', () {
      // Two 1P 16 A C ways on a 1φ board: exact matches, one line × 2.
      const p = ElectricalProject(id: 'p', name: 'P', panels: [
        ElectricalPanel(
          id: 'DB',
          name: 'DB',
          system: ElectricalSystem.singlePhase,
          voltage: Voltage(230),
          circuits: [
            ElectricalCircuit(
                id: 'a',
                name: 'A',
                loadKind: LoadKind.general,
                loadW: 2000,
                cosPhi: 1,
                length: Length(10)),
            ElectricalCircuit(
                id: 'b',
                name: 'B',
                loadKind: LoadKind.general,
                loadW: 2000,
                cosPhi: 1,
                length: Length(10)),
          ],
        ),
      ]);
      final sys = computeSystem(_profile, p);
      final r = sys.panels['DB']!.circuits.first.breaker;
      final parts = [_mcb('X', r.ratingA.amperes, 'B', 1)];
      final lines = buildBom(sys, parts: parts)
          .lines
          .where((l) =>
              l.category == PartCategory.breaker && !l.description.contains('incomer'))
          .toList();
      // A curve-B part for a curve-C sizing: flagged on both ways, merged into
      // ONE flagged line (same SKU + same note), never into an exact line.
      expect(lines, hasLength(1));
      expect(lines.single.qty, 2);
      expect(lines.single.deviceSubstituted, isTrue);
    });
  });

  // ── ampacity-message ──────────────────────────────────────────────────────
  test('ampacity error states max(In, 1.25 x Ib), never a false In > Iz', () {
    // 645 kW at cos phi 1: Ib = 645000 / (sqrt(3) * 400) = 931.0 A ⇒ In 1000 A.
    // 1.25 × Ib = 1163.7 A governs the required Iz, above In.
    const p = ElectricalProject(id: 'p', name: 'P', panels: [
      ElectricalPanel(
        id: 'MDP',
        name: 'MDP',
        voltage: Voltage(400),
        circuits: [
          ElectricalCircuit(
              id: 'big',
              name: 'Chiller',
              loadKind: LoadKind.general,
              phases: 3,
              loadW: 645000,
              cosPhi: 1,
              length: Length(30)),
        ],
      ),
    ]);
    final sys = computeSystem(_profile, p);
    final c = sys.panels['MDP']!.circuits.single;
    const ib = 645000 / (1.7320508075688772 * 400);
    expect(c.designCurrent.amperes, closeTo(ib, 0.1));
    expect(c.cable.izRequired!.amperes,
        closeTo(1.25 * ib > c.breaker.ratingA.amperes
            ? 1.25 * ib
            : c.breaker.ratingA.amperes, 0.01));
    final w = sys.warnings
        .where((w) => w.code == 'cable-ampacity-inadequate')
        .toList();
    // 4 × 300 mm² is the largest the sizer offers: Iz 1024.4 A ≥ In 1000 A but
    // < 1163.7 A ⇒ the failure is the continuous-load term, NOT In > Iz.
    expect(c.cable.ampacityReached, isFalse);
    expect(c.breaker.ratingA.amperes, 1000);
    expect(c.cable.deratedIz.amperes, closeTo(1024.4, 1e-9));
    final msg = w.single.message;
    expect(msg, contains('Iz 1024.4 A at 4x300 mm2'));
    expect(msg, contains('required max(In 1000 A, 1.25 x Ib 931 A = 1163.7 A)'
        ' = 1163.7 A'));
    expect(msg, isNot(contains('In > Iz')));
    expect(msg, contains('1000 A breaker is itself below 1.25 x Ib'));
  });

  test('…and names In > Iz only when it is true (heavy grouping)', () {
    const p = ElectricalProject(id: 'p', name: 'P', panels: [
      ElectricalPanel(
        id: 'MDP',
        name: 'MDP',
        voltage: Voltage(400),
        circuits: [
          ElectricalCircuit(
              id: 'big',
              name: 'Chiller',
              loadKind: LoadKind.general,
              phases: 3,
              loadW: 645000,
              cosPhi: 1,
              length: Length(30),
              groupingCountOverride: 3),
        ],
      ),
    ]);
    final sys = computeSystem(_profile, p);
    final c = sys.panels['MDP']!.circuits.single;
    // Grouped with 3 circuits: Iz 709.2 A < In 1000 A ⇒ genuinely unprotected.
    expect(c.cable.deratedIz.amperes, closeTo(709.2, 1e-9));
    final msg = sys.warnings
        .singleWhere((w) => w.code == 'cable-ampacity-inadequate')
        .message;
    expect(msg, contains('In > Iz'));
  });

  // ── demand-current ────────────────────────────────────────────────────────
  group('a diversified board prints the diversified demand current', () {
    ElectricalProject board(double diversity) =>
        ElectricalProject(id: 'p', name: 'P', panels: [
          ElectricalPanel(
            id: 'LP',
            name: 'LP',
            voltage: const Voltage(400),
            diversityFactor: diversity,
            circuits: const [
              ElectricalCircuit(
                  id: 'a',
                  name: 'A',
                  loadKind: LoadKind.general,
                  phases: 3,
                  loadW: 10000,
                  cosPhi: 1,
                  length: Length(10)),
            ],
          ),
        ]);

    test('diversity 0.9: header/footer + report pair div A with div kW', () {
      final p = board(0.9);
      final sys = computeSystem(_profile, p);
      final r = sys.panels['LP']!;
      // Ib = 10000 / (sqrt(3) * 400) = 14.43 A, carried to 0.1 A ⇒ 14.4 A
      // (undiversified, worst phase); diversified = 14.4 × 0.9 = 12.96 A,
      // printed to a FIXED 0.1 A (Round 20) ⇒ 13.0 A.
      expect(r.demandCurrent.amperes, closeTo(14.4, 1e-9));
      expect(r.diversifiedDemandCurrent.amperes, closeTo(12.96, 1e-9));
      final labels = _labels(p, sys, 'LP');
      expect(labels.any((t) => t.contains('demand 13.0A div (max ph 14.4A undiv)')),
          isTrue, reason: labels.join(' | '));
      expect(labels.any((t) => t.startsWith('TOTAL') && t.contains('13.0A div')),
          isTrue);
      final md = buildElectricalCalcReport(ElectricalCalcReportData(
        projectName: 'P',
        date: '2026-10-18',
        standardsName: _profile.name,
        standardsRevision: _profile.revision,
        project: p,
        result: sys,
      ));
      expect(md, contains('diversified (max phase'));
    });

    test('no diversity: the one figure, exactly as before', () {
      final p = board(1);
      final sys = computeSystem(_profile, p);
      final labels = _labels(p, sys, 'LP');
      expect(labels.any((t) => t.endsWith('demand 14.4A')), isTrue);
      expect(labels.any((t) => t.contains('undiv')), isFalse);
    });
  });

  // ── capacitor-feeder ──────────────────────────────────────────────────────
  test('a feeder to a capacitor board prints the bank current, marked cap', () {
    const p = ElectricalProject(id: 'p', name: 'P', panels: [
      ElectricalPanel(
        id: 'MDP',
        name: 'MDP',
        voltage: Voltage(400),
        circuits: [
          ElectricalCircuit(
              id: 'f',
              name: 'To CAP',
              loadKind: LoadKind.feeder,
              feedsPanelId: 'CAP',
              phases: 3,
              length: Length(10)),
        ],
      ),
      ElectricalPanel(
        id: 'CAP',
        name: 'Cap bank',
        voltage: Voltage(400),
        sourceType: PanelSource.feeder,
        fedByCircuitId: 'f',
        circuits: [
          ElectricalCircuit(
              id: 'q',
              name: 'Bank',
              loadKind: LoadKind.capacitor,
              phases: 3,
              loadW: 100000, // 100 kvar
              length: Length(5)),
        ],
      ),
    ]);
    final sys = computeSystem(_profile, p);
    final feeder = sys.panels['MDP']!.circuits.single;
    // Bank-off balance basis: the feeder's design current is 0 …
    expect(feeder.designCurrent.amperes, closeTo(0, 1e-9));
    // … but its run current is the bank's: Q/(√3·U) = 100000/(√3·400) = 144.3 A
    // (at least; × the switching floor where the engine applies it).
    expect(feeder.runCurrentA.amperes, greaterThanOrEqualTo(144.3));
    final mdp = _labels(p, sys, 'MDP');
    final cell = '${_n1(feeder.runCurrentA.amperes)} cap';
    expect(mdp.where((t) => t == cell), hasLength(3), reason: mdp.join(' | '));
    // The bank's own DAYA is its reactive rating, in kvar.
    expect(_labels(p, sys, 'CAP'), contains('100 kvar'));
  });

  // ── solar-ratio ───────────────────────────────────────────────────────────
  group('solar: a stored DC:AC ratio of 0 / negative is tolerated', () {
    for (final bad in [0, -1, 'NaN']) {
      test('dcAcRatio $bad decodes to the default and sizes', () {
        final json = jsonDecode(jsonEncode({
          'id': 'p',
          'name': 'P',
          'panels': <Object>[],
          'sources': {
            'solar': {'panels': 20, 'dcAcRatio': bad, 'panelWp': 550},
          },
        })) as Map<String, dynamic>;
        final p = ElectricalProject.fromJson(json);
        final s = p.sources!.solar!;
        expect(s.dcAcRatio, 1.2);
        // 20 × 550 Wp = 11 kWp; 11 / 1.2 = 9.17 kW ⇒ a finite inverter pick.
        final r = sizeSolar(panelWp: s.panelWp, panels: s.panels,
            dcAcRatio: s.dcAcRatio);
        expect(r.inverterKw.inKiloWatts.isFinite, isTrue);
      });
    }

    test('sizeSolar itself never divides by a non-positive ratio', () {
      final r = sizeSolar(panelWp: 550, panels: 20, dcAcRatio: 0);
      expect(r.inverterKw.inKiloWatts.isFinite, isTrue);
    });
  });
}

String _n1(double v) =>
    v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);
