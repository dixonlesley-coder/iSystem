// Round 73 (genset busbar withstand) — FOLD 1 sizes every genset-backed
// board's busbar on max(utility prospective fault, the on-genset fault at
// that bus), so the engine's own pick withstands BOTH supplies and the
// Round-72 `busbar-withstand-inadequate-on-genset` ERROR fires only for a
// bar that was not sized on the genset fault (the rule of the utility
// `busbar-withstand-inadequate`).
//
// First principles (IEC 61439-1 adiabatic, the engine's 80 A/mm² 1-second
// copper density, `// VERIFY`):
//   Icw(csa, t) = 80 · csa / 1000 / √t  (kA)
//   csa_min(I, t) = I · √t / 80          (mm², I in A)
// The reviewer's case — the app's default 16 kA / 0.1 s utility chain and a
// 2000 kVA full-backup standby set (Xd'' 0.12, `// VERIFY`):
//   I_genset = 2.0e6 / (√3 · 400) / 0.12 = 24 056 A = 24.06 kA at the MDP
//   csa_min = 24 056 · √0.1 / 80 = 95.09 mm² ⇒ the 100 mm² (20 x 5) rung,
//   Icw = 80 · 100 / 1000 / √0.1 = 25.30 kA >= 24.06 kA; the 75 mm² rung the
//   utility pick lands on gives 18.97 kA < 24.06 kA (the Round-72 ERROR).
library;

import 'dart:math' as math;

import 'package:mechx_engine/electrical/advanced_study.dart';
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
const _utility = Current(16000); // the app's default Fold-1 origin
const _code = 'busbar-withstand-inadequate-on-genset';

/// MDP feeding a FIRE board (37 kW life-safety pump) and an LP board.
ElectricalProject _project({
  GeneratorSource? gen,
  bool fireEssential = false,
  bool allEssential = false,
}) =>
    ElectricalProject(
      id: 'r73',
      name: 'Round 73',
      earthingSystem: EarthingSystem.tnS,
      sources: gen == null ? null : ElectricalSources(generator: gen),
      panels: [
        ElectricalPanel(
            id: 'MDP',
            name: 'MDP',
            voltage: const Voltage(400),
            essential: allEssential,
            circuits: const [
              ElectricalCircuit(
                  id: 'f-fire',
                  name: 'FIRE feeder',
                  loadKind: LoadKind.feeder,
                  length: Length(5),
                  feedsPanelId: 'FIRE'),
              ElectricalCircuit(
                  id: 'f-lp',
                  name: 'LP feeder',
                  loadKind: LoadKind.feeder,
                  length: Length(20),
                  feedsPanelId: 'LP'),
            ]),
        ElectricalPanel(
            id: 'FIRE',
            name: 'FIRE',
            voltage: const Voltage(400),
            essential: fireEssential || allEssential,
            circuits: const [
              ElectricalCircuit(
                  id: 'fp',
                  name: 'Fire pump',
                  loadKind: LoadKind.pump,
                  motorKw: 37,
                  phases: 3,
                  lifeSafety: true,
                  length: Length(15)),
            ]),
        ElectricalPanel(
            id: 'LP',
            name: 'LP',
            voltage: const Voltage(400),
            essential: allEssential,
            circuits: const [
              ElectricalCircuit(
                  id: 'lp1',
                  name: 'Process heat',
                  loadKind: LoadKind.heating,
                  loadW: 20000,
                  phases: 3,
                  length: Length(10)),
            ]),
      ],
    );

double _gensetIscA(double va) => va / (math.sqrt(3) * 400) / 0.12;
double _icwKa(double csa, double t) => 80 * csa / 1000 / math.sqrt(t);
double _csaMin(double faultA, double t) => faultA * math.sqrt(t) / 80;

/// The first standard rung >= both the utility-only pick (ampacity + the
/// utility withstand) and the genset withstand floor — the table's ampacity
/// rises with its CSA, so this is the bar sized on max(utility, genset).
double _expectedCsa(double utilityPickCsa, double gFaultKa, double t) {
  final floor = _csaMin(gFaultKa * 1000, t);
  for (final b in _profile.copperBusbarTable) {
    if (b.csaMm2 + 1e-9 >= utilityPickCsa && b.csaMm2 + 1e-9 >= floor) {
      return b.csaMm2;
    }
  }
  return math.max(utilityPickCsa, floor.ceilToDouble());
}

({ElectricalSystemResult sys, AdvancedStudy st}) _solve(
    ElectricalProject p, double t) {
  final sys = computeSystem(_profile, p,
      originFaultLevel: _utility, busbarClearingTimeS: t);
  final st = computeAdvancedStudy(_profile, p, sys, originFaultLevel: _utility);
  return (sys: sys, st: st);
}

void main() {
  test('first principles: 2000 kVA genset 24.06 kA; 75 mm2 18.97 kA, '
      '100 mm2 25.30 kA at 0.1 s', () {
    expect(_gensetIscA(2.0e6) / 1000, closeTo(24.06, 0.005));
    expect(onSiteSourceFaultA(SupplyKind.generator, 2.0e6),
        closeTo(_gensetIscA(2.0e6), 1e-6));
    expect(_csaMin(_gensetIscA(2.0e6), 0.1), closeTo(95.09, 0.01));
    expect(_icwKa(75, 0.1), closeTo(18.97, 0.005));
    expect(_icwKa(100, 0.1), closeTo(25.30, 0.005));
  });

  test(
      '2000 kVA full-backup set on the default 16 kA / 0.1 s chain: no '
      'genset withstand ERROR; MDP / FIRE bars are the first rungs '
      'withstanding the genset fault', () {
    const t = 0.1;
    final p = _project(
        gen: const GeneratorSource(
            kva: ApparentPower(2000e3), backupFraction: 1.0));
    final r = _solve(p, t);
    final utilityOnly = _solve(_project(), t).sys;
    expect(r.st.fault.warnings.where((w) => w.code == _code), isEmpty);
    expect(r.sys.warnings.where((w) => w.code == 'busbar-withstand-inadequate'),
        isEmpty);
    final basis = gensetFaultBasis(p, r.sys)!;
    expect(basis.iscA, closeTo(_gensetIscA(2.0e6), 1e-6));
    final g = faultStudy(r.sys, p, _profile,
        originFaultLevel: Current(basis.iscA));
    // MDP: the root takes the full genset fault, 24.06 kA.
    expect(g.panels['MDP']!.prospectiveFaultkA, closeTo(24.06, 0.005));
    for (final id in ['MDP', 'FIRE']) {
      final gKa = g.panels[id]!.prospectiveFaultkA;
      final bar = r.sys.panels[id]!.busbar;
      final uBar = utilityOnly.panels[id]!.busbar;
      expect(gKa, greaterThan(uBar.withstand!.faultKa), reason: id);
      // Before the fix the utility pick failed the genset fault.
      expect(uBar.withstand!.icwKa, lessThan(gKa), reason: id);
      expect(bar.csaMm2, _expectedCsa(uBar.csaMm2, gKa, t), reason: id);
      expect(bar.withstand!.icwKa, closeTo(_icwKa(bar.csaMm2, t), 0.005));
      expect(bar.withstand!.icwKa, greaterThanOrEqualTo(gKa), reason: id);
      expect(bar.withstand!.faultKa, gKa, reason: '$id sized on genset');
      expect(bar.withstand!.adequate, isTrue);
      // The previous standard rung does NOT withstand it (first rung).
      final rungs = _profile.copperBusbarTable;
      final i = rungs.indexWhere((b) => b.csaMm2 == bar.csaMm2);
      if (i > 0 && rungs[i - 1].csaMm2 + 1e-9 >= uBar.csaMm2) {
        expect(_icwKa(rungs[i - 1].csaMm2, t), lessThan(gKa), reason: id);
      }
      for (final s in r.sys.panels[id]!.busbarSections) {
        expect(s.busbar.withstand!.icwKa + 1e-6, greaterThanOrEqualTo(gKa));
      }
    }
    // The reviewer's MDP: 75 mm2 (18.97 kA) -> 100 mm2 (25.30 kA).
    expect(utilityOnly.panels['MDP']!.busbar.csaMm2, 75);
    expect(r.sys.panels['MDP']!.busbar.csaMm2, 100);
    // Device class / kA rules keep the utility fault: every way's breaker
    // equals the utility-only solve's (only the bar moved).
    for (final id in r.sys.order) {
      final a = r.sys.panels[id]!;
      final b = utilityOnly.panels[id]!;
      expect(a.incomer.breaker.ratingA, b.incomer.breaker.ratingA);
      for (var k = 0; k < a.circuits.length; k++) {
        expect(a.circuits[k].breaker.ratingA, b.circuits[k].breaker.ratingA);
        expect(a.circuits[k].breaker.deviceClass,
            b.circuits[k].breaker.deviceClass);
        expect(a.circuits[k].cable.csaMm2, b.circuits[k].cable.csaMm2);
      }
    }
  });

  test('the judge still names a bar NOT sized on the genset fault', () {
    const t = 0.1;
    final p = _project(
        gen: const GeneratorSource(
            kva: ApparentPower(2000e3), backupFraction: 1.0));
    // Same cables, bars sized on the utility fault only.
    final stale = _solve(_project(), t).sys;
    final iscA = _gensetIscA(2.0e6);
    final m = mergeGensetFaultStudy(
        utility: faultStudy(stale, p, _profile, originFaultLevel: _utility),
        genset: faultStudy(stale, p, _profile,
            originFaultLevel: Current(iscA)),
        sys: stale,
        backed: {for (final x in p.panels) x.id},
        gensetVa: 2.0e6,
        gensetIscA: iscA);
    final named = {
      for (final w in m.warnings)
        if (w.code == _code) w.panelId,
    };
    expect(named, containsAll(['MDP', 'FIRE']));
    for (final w in m.warnings.where((w) => w.code == _code)) {
      expect(w.severity, WarningSeverity.error);
    }
  });

  test(
      'beyond the largest standard bar the genset fault grows the bar '
      'exactly as the utility path does (parallel top bars + a warning, '
      'never silent)',
      () {
    // 4 x 2500 kVA at 1 s: 10e6/(√3·400)/0.12 = 120.28 kA ⇒ 1503.5 mm2,
    // above the 1000 mm2 table top.
    const t = 1.0;
    final p = _project(
        gen: const GeneratorSource(
            kva: ApparentPower(2500e3), units: 4, backupFraction: 1.0));
    final r = _solve(p, t);
    final gKa = faultStudy(r.sys, p, _profile,
            originFaultLevel: Current(_gensetIscA(10e6)))
        .panels['MDP']!
        .prospectiveFaultkA;
    expect(gKa, closeTo(120.28, 0.01));
    final bar = r.sys.panels['MDP']!.busbar;
    // Round 74 — past the 1000 mm2 (100 x 10) table top the bar is n
    // PARALLEL top bars: n = ceil(1503.5 / 1000) = 2 ⇒ 2000 mm2.
    expect(bar.widthMm, 100, reason: 'top-rung bars');
    expect(bar.thicknessMm, 10);
    expect(bar.parallelBars, (_csaMin(gKa * 1000, t) / 1000).ceil());
    expect(bar.csaMm2, bar.parallelBars * 1000);
    expect(
        r.sys.panels['MDP']!.warnings
            .where((w) => w.code == 'busbar-beyond-standard-table'),
        isNotEmpty,
        reason: 'the parallel-bar set is surfaced');
    // Identical to a utility-only solve at that fault level.
    final asUtility = computeSystem(_profile, _project(),
            originFaultLevel: Current(gKa * 1000), busbarClearingTimeS: t)
        .panels['MDP']!
        .busbar;
    expect(bar.csaMm2, asUtility.csaMm2);
    expect(bar.withstand!.icwKa, asUtility.withstand!.icwKa);
    expect(r.st.fault.warnings.where((w) => w.code == _code), isEmpty);
  });

  test('no genset / an unbacked board: byte-identical bars and warnings', () {
    for (final t in [0.1, 1.0]) {
      // The same designation without a genset.
      final none = _solve(_project(fireEssential: true), t);
      // Partial backup: only the FIRE sub-tree is genset-backed.
      final part = _solve(
          _project(
              gen: const GeneratorSource(
                  kva: ApparentPower(2000e3), backupFraction: 0.5),
              fireEssential: true),
          t);
      final basis = gensetFaultBasis(
          _project(
              gen: const GeneratorSource(
                  kva: ApparentPower(2000e3), backupFraction: 0.5),
              fireEssential: true),
          part.sys)!;
      expect(basis.backed, {'FIRE'});
      for (final id in ['MDP', 'LP']) {
        final a = part.sys.panels[id]!;
        final b = none.sys.panels[id]!;
        expect(a.busbar.csaMm2, b.busbar.csaMm2, reason: '$id t=$t');
        expect(a.busbar.withstand!.faultKa, b.busbar.withstand!.faultKa);
        expect(a.busbar.withstand!.icwKa, b.busbar.withstand!.icwKa);
        expect(a.busbar.sizingReason, b.busbar.sizingReason);
        expect([for (final s in a.busbarSections) s.busbar.csaMm2],
            [for (final s in b.busbarSections) s.busbar.csaMm2]);
      }
      // Without FOLD 1 nothing moves either.
      final noFold = computeSystem(_profile,
          _project(gen: const GeneratorSource(kva: ApparentPower(2000e3))));
      final noFoldNone = computeSystem(_profile, _project());
      for (final id in noFold.order) {
        expect(noFold.panels[id]!.busbar.csaMm2,
            noFoldNone.panels[id]!.busbar.csaMm2);
        expect(noFold.panels[id]!.busbar.withstand, isNull);
      }
      expect([for (final w in part.sys.warnings) '${w.code}|${w.message}'],
          [for (final w in none.sys.warnings) '${w.code}|${w.message}']);
    }
  });

  test(
      'seeded: genset size x units x backup fraction x essential designation '
      '— no genset withstand ERROR whenever a standard rung suffices; every '
      'backed bar withstands both supplies', () {
    final rng = math.Random(73);
    const fractions = <double?>[null, 0.5, 1.0];
    const sizes = [250.0, 500.0, 1000.0, 1500.0, 2000.0, 2500.0];
    final topCsa = _profile.copperBusbarTable.last.csaMm2;
    var governed = 0;
    for (var trial = 0; trial < 24; trial++) {
      final kva = sizes[rng.nextInt(sizes.length)];
      final units = 1 + rng.nextInt(2);
      final fraction = fractions[rng.nextInt(fractions.length)];
      final designation = rng.nextInt(3); // 0 none, 1 FIRE, 2 all
      final t = rng.nextBool() ? 0.1 : 1.0;
      final p = _project(
          gen: GeneratorSource(
              kva: ApparentPower(kva * 1000),
              units: units,
              backupFraction: fraction),
          fireEssential: designation == 1,
          allEssential: designation == 2);
      final r = _solve(p, t);
      final none = _solve(
              _project(
                  fireEssential: designation == 1,
                  allEssential: designation == 2),
              t)
          .sys;
      final basis = gensetFaultBasis(p, r.sys)!;
      final g = faultStudy(r.sys, p, _profile,
          originFaultLevel: Current(basis.iscA));
      final why = 'trial $trial: $units x $kva kVA f=$fraction '
          'ess=$designation t=$t';
      for (final id in r.sys.order) {
        final bar = r.sys.panels[id]!.busbar;
        final uBar = none.panels[id]!.busbar;
        final gKa = g.panels[id]!.prospectiveFaultkA;
        final backed = basis.backed.contains(id);
        if (!backed || gKa <= uBar.withstand!.faultKa + 1e-9) {
          // Unbacked / utility-governed: byte-identical to no genset.
          expect(bar.csaMm2, uBar.csaMm2, reason: '$why $id');
          expect(bar.withstand!.faultKa, uBar.withstand!.faultKa);
          continue;
        }
        governed++;
        expect(bar.csaMm2, _expectedCsa(uBar.csaMm2, gKa, t),
            reason: '$why $id');
        expect(bar.withstand!.icwKa + 1e-6, greaterThanOrEqualTo(gKa),
            reason: '$why $id');
        for (final s in r.sys.panels[id]!.busbarSections) {
          expect(s.busbar.withstand!.icwKa + 1e-6, greaterThanOrEqualTo(gKa),
              reason: '$why $id section');
        }
        // A standard rung suffices ⇒ never the ERROR for this board.
        if (_csaMin(gKa * 1000, t) <= topCsa) {
          expect(
              r.st.fault.warnings
                  .where((w) => w.code == _code && w.panelId == id),
              isEmpty,
              reason: '$why $id');
        }
      }
      expect(r.st.fault.warnings.where((w) => w.code == _code), isEmpty,
          reason: why);
    }
    expect(governed, greaterThan(0), reason: 'the property is non-vacuous');
  });
}
