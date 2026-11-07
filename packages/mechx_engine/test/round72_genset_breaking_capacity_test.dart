// Round 72 (elec-convergence-24-genset-max-fault-never-judged-for-breaking-
// capacity) — a standby genset is a MAXIMUM-fault source too: every device
// on a genset-backed board must break the larger of the utility and the
// on-genset prospective fault.
//
// Probe: undeclared MV with transformerUnits 4 (the study picks 630 kVA
// units, one per section behind N.O. couplers), TN-S, a 2 x 2000 kVA
// standby set backing every board (all essential), four MDP sections each
// feeding a 250 kW UPS board and a 90 kW CRAH board, plus a 75 kW fire pump
// board.
//
// First principles:
//   utility origin (one 630 kVA unit, 4 % Z): 630e3 / (sqrt3 x 400 x 0.04)
//     = 22.73 kA at each MDP;
//   genset (gensetPlantVa = 2 x 2000 kVA = 4.0e6 VA, Xd'' 0.12):
//     4.0e6 / (sqrt3 x 400) / 0.12 = 48.11 kA at each MDP.
// The utility study specifies 36 kA incomers; before the fix those 36 kA
// devices were issued (schedule / BOM) with no warning although 48.11 kA
// flows on genset supply. Now the issued study specifies every backed
// device on max(utility, genset), so the incomer kA >= 48.11 and no
// `breaking-capacity-inadequate-on-genset` fires for engine-picked devices.
library;

import 'dart:math' as math;

import 'package:mechx_engine/electrical/advanced_study.dart';
import 'package:mechx_engine/electrical/bom.dart' show faultSpecifiedKa;
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/earthing.dart';
import 'package:mechx_engine/electrical/fault.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/panel_results.dart';
import 'package:mechx_engine/electrical/sources.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

const _profile = PuilProfile();

ElectricalProject _dc(
    {GeneratorSource? gen =
        const GeneratorSource(kva: ApparentPower(2000e3), units: 2),
    bool allEssential = true,
    int sections = 4,
    double upsKw = 250,
    double crahKw = 90}) {
  return ElectricalProject(
    id: 'dc',
    name: 'Data centre',
    earthingSystem: EarthingSystem.tnS,
    transformerUnits: sections,
    sources: gen == null ? null : ElectricalSources(generator: gen),
    panels: [
      for (var i = 0; i < sections; i++) ...[
        ElectricalPanel(
            id: 'MDP$i',
            name: 'MDP $i',
            voltage: const Voltage(400),
            essential: allEssential,
            circuits: [
              ElectricalCircuit(
                  id: 'fu$i',
                  name: 'UPS $i feeder',
                  loadKind: LoadKind.feeder,
                  length: const Length(15),
                  feedsPanelId: 'UPS$i'),
              ElectricalCircuit(
                  id: 'fc$i',
                  name: 'CRAH $i feeder',
                  loadKind: LoadKind.feeder,
                  length: const Length(25),
                  feedsPanelId: 'CRAH$i'),
            ]),
        ElectricalPanel(
            id: 'UPS$i',
            name: 'UPS $i',
            voltage: const Voltage(400),
            essential: allEssential,
            circuits: [
              ElectricalCircuit(
                  id: 'u$i',
                  name: 'IT load $i',
                  loadKind: LoadKind.heating,
                  loadW: upsKw * 1000,
                  phases: 3,
                  length: const Length(10)),
            ]),
        ElectricalPanel(
            id: 'CRAH$i',
            name: 'CRAH $i',
            voltage: const Voltage(400),
            essential: allEssential,
            circuits: [
              ElectricalCircuit(
                  id: 'c$i',
                  name: 'CRAH $i',
                  loadKind: LoadKind.heating,
                  loadW: crahKw * 1000,
                  phases: 3,
                  length: const Length(10)),
            ]),
      ],
      ElectricalPanel(
          id: 'FIRE',
          name: 'FIRE',
          voltage: const Voltage(400),
          essential: allEssential,
          circuits: const [
            ElectricalCircuit(
                id: 'fp',
                name: 'Fire pump',
                loadKind: LoadKind.pump,
                motorKw: 75,
                phases: 3,
                lifeSafety: true,
                length: Length(20)),
          ]),
    ],
  );
}

double _iscKa(double va) => va / (math.sqrt(3) * 400) / 0.12 / 1000;

void main() {
  test('first principles: 22.73 kA utility vs 48.11 kA genset', () {
    expect(630e3 / (math.sqrt(3) * 400 * 0.04) / 1000, closeTo(22.73, 0.01));
    expect(_iscKa(4.0e6), closeTo(48.11, 0.01));
    expect(onSiteSourceFaultA(SupplyKind.generator, 4.0e6) / 1000,
        closeTo(48.11, 0.01));
  });

  test('every backed incomer is specified >= its on-genset fault', () {
    final p = _dc();
    final sys = computeSystem(_profile, p);
    final st = computeAdvancedStudy(_profile, p, sys);
    final g = faultStudy(sys, p, _profile,
        originFaultLevel: Current(_iscKa(4.0e6) * 1000));
    for (var i = 0; i < 4; i++) {
      final id = 'MDP$i';
      // The genset governs the MDP bus (48.11 > 22.73 kA).
      expect(g.panels[id]!.prospectiveFaultkA, closeTo(48.11, 0.02));
      expect(st.fault.panels[id]!.prospectiveFaultkA,
          g.panels[id]!.prospectiveFaultkA);
      expect(st.fault.panels[id]!.incomerKa, greaterThanOrEqualTo(48.11),
          reason: '$id incomer specified on the genset fault');
      expect(st.fault.panels[id]!.incomerAdequate, isTrue);
    }
    // Every way of every backed board is specified for both supplies.
    for (final e in st.fault.circuits.entries) {
      final gk = g.circuits[e.key]!.faultkA;
      expect(e.value.faultkA, greaterThanOrEqualTo(gk - 1e-9), reason: e.key);
      if (e.value.breakerAdequate) {
        expect(e.value.breakerKa + 1e-9, greaterThanOrEqualTo(gk),
            reason: '${e.key} specified for the genset fault');
      }
    }
    // The issued maps (schedule / BOM) carry the genset figure.
    final ka = faultSpecifiedKa(st.fault);
    expect(ka.incomers['MDP0'], greaterThanOrEqualTo(48.11));
    expect(st.bom.lines, isNotEmpty);
    // Engine-picked devices never raise the on-genset breaking error.
    expect(
        st.fault.warnings
            .where((w) => w.code == 'breaking-capacity-inadequate-on-genset'),
        isEmpty);
    expect(st.verifyItems, contains(gensetMaxFaultVerifyItem));
  });

  test('a device the ladder cannot reach is flagged on the genset', () {
    final p = _dc();
    final sys = computeSystem(_profile, p);
    final g = faultStudy(sys, p, _profile,
        originFaultLevel: Current(_iscKa(4.0e6) * 1000));
    final u =
        faultStudy(sys, p, _profile, originFaultLevel: const Current(22730));
    // A synthetic issued device: the genset study reports the MDP0 incomer
    // inadequate (e.g. an override short of 48 kA) — merged it is re-coded.
    final gBad = FaultStudyResult(
      originFaultkA: g.originFaultkA,
      panels: {
        ...g.panels,
        'MDP0': PanelFaultResult(
            panelId: 'MDP0',
            prospectiveFaultkA: g.panels['MDP0']!.prospectiveFaultkA,
            incomerAdequate: false,
            incomerKa: 36),
      },
      circuits: g.circuits,
      selectivity: g.selectivity,
      warnings: [
        ...g.warnings,
        const ElectricalWarning(
            code: 'breaking-capacity-inadequate',
            severity: WarningSeverity.error,
            message: 'MDP 0: incomer 36 kA below 48.11 kA',
            panelId: 'MDP0'),
      ],
      verifyItems: g.verifyItems,
    );
    final m = mergeGensetFaultStudy(
        utility: u,
        genset: gBad,
        sys: sys,
        backed: {for (final x in p.panels) x.id},
        gensetVa: 4.0e6,
        gensetIscA: _iscKa(4.0e6) * 1000);
    final w = m.warnings
        .where((w) => w.code == 'breaking-capacity-inadequate-on-genset')
        .toList();
    expect(w.single.panelId, 'MDP0');
    expect(w.single.severity, WarningSeverity.error);
    expect(w.single.message, contains('standby genset'));
    expect(m.panels['MDP0']!.incomerKa, 36);
  });

  test(
      'busbar Icw below the on-genset fault is judged (Round 73: only a bar '
      'not sized on it)', () {
    final p = _dc();
    // Round 73 — FOLD 1 now sizes every backed bus on max(utility, genset):
    // the engine's own pick withstands the 48.11 kA genset fault at 1 s.
    final sys = computeSystem(_profile, p,
        originFaultLevel: const Current(22730), busbarClearingTimeS: 1.0);
    final st = computeAdvancedStudy(_profile, p, sys,
        originFaultLevel: const Current(22730));
    expect(
        st.fault.warnings
            .where((w) => w.code == 'busbar-withstand-inadequate-on-genset'),
        isEmpty);
    for (final pid in sys.order) {
      final w = sys.panels[pid]!.busbar.withstand!;
      expect(w.adequate, isTrue, reason: pid);
      expect(w.faultKa,
          greaterThanOrEqualTo(st.fault.panels[pid]!.prospectiveFaultkA - 1e-9),
          reason: '$pid sized on the governing fault');
    }
    // The judge itself still stands: bars sized on the UTILITY fault only
    // (the same project without its genset ⇒ identical cables) are named.
    final utilityOnly = computeSystem(_profile, _dc(gen: null),
        originFaultLevel: const Current(22730), busbarClearingTimeS: 1.0);
    final g = faultStudy(utilityOnly, p, _profile,
        originFaultLevel: Current(_iscKa(4.0e6) * 1000));
    final u = faultStudy(utilityOnly, p, _profile,
        originFaultLevel: const Current(22730));
    final m = mergeGensetFaultStudy(
        utility: u,
        genset: g,
        sys: utilityOnly,
        backed: {for (final x in p.panels) x.id},
        gensetVa: 4.0e6,
        gensetIscA: _iscKa(4.0e6) * 1000);
    final bad = [
      for (final w in m.warnings)
        if (w.code == 'busbar-withstand-inadequate-on-genset') w.panelId,
    ];
    expect(bad, isNotEmpty, reason: 'MDP buses sized on 22.73 kA at 1 s');
    for (final pid in utilityOnly.order) {
      final w = utilityOnly.panels[pid]!.busbar.withstand!;
      final gk = m.panels[pid]!.prospectiveFaultkA;
      if (w.icwKa + 1e-6 < gk) expect(bad, contains(pid));
    }
  });

  test('no genset: the study is byte-identical (the utility study)', () {
    final p = _dc(gen: null);
    final sys = computeSystem(_profile, p);
    final st = computeAdvancedStudy(_profile, p, sys);
    expect(st.verifyItems, isNot(contains(gensetMaxFaultVerifyItem)));
    for (final e in st.fault.panels.entries) {
      expect(e.value.prospectiveFaultkA, lessThan(30));
    }
  });

  test(
      'seeded: every backed incomer and way is specified >= its on-genset '
      'prospective fault; an unbacked board keeps the utility figures', () {
    final rng = math.Random(72);
    for (var trial = 0; trial < 8; trial++) {
      final sections = 2 + rng.nextInt(3);
      final setKva = [500.0, 1000.0, 1500.0, 2000.0][rng.nextInt(4)];
      final units = 1 + rng.nextInt(2);
      final allEssential = rng.nextBool();
      final fraction = allEssential ? null : 0.5;
      final p = _dc(
          sections: sections,
          gen: GeneratorSource(
              kva: ApparentPower(setKva * 1000),
              units: units,
              backupFraction: fraction),
          allEssential: allEssential,
          upsKw: 100 + rng.nextInt(200).toDouble(),
          crahKw: 30 + rng.nextInt(80).toDouble());
      final sys = computeSystem(_profile, p);
      final st = computeAdvancedStudy(_profile, p, sys);
      final basis = gensetFaultBasis(p, sys)!;
      final g =
          faultStudy(sys, p, _profile, originFaultLevel: Current(basis.iscA));
      final utility = faultStudy(sys, p, _profile,
          originFaultLevel: Current(st.fault.originFaultkA * 1000));
      for (final id in sys.order) {
        final issued = st.fault.panels[id]!;
        if (basis.backed.contains(id)) {
          final need = math.max(g.panels[id]!.prospectiveFaultkA,
              utility.panels[id]!.prospectiveFaultkA);
          expect(issued.prospectiveFaultkA, closeTo(need, 1e-9),
              reason: 'trial $trial $id');
          if (issued.incomerAdequate) {
            expect(issued.incomerKa + 1e-9, greaterThanOrEqualTo(need));
          }
        } else {
          expect(issued.prospectiveFaultkA,
              utility.panels[id]!.prospectiveFaultkA);
          expect(issued.incomerKa, utility.panels[id]!.incomerKa);
        }
      }
      expect(
          st.fault.warnings
              .where((w) => w.code == 'breaking-capacity-inadequate-on-genset'),
          isEmpty,
          reason: 'trial $trial: engine-picked devices cover both supplies');
    }
  });
}
