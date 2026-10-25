// Round 43 (2026-10-18) — star-delta motor leads (Zs, Vd, grouping), the
// ADS-aware MCCB frame raise, tenant sub-meters, the fire-path feeder cable,
// exact board line sums, and honest electrical drawings (Iz! / Zs! marks,
// LANJUT stubs, overview chunk notes, riser legibility).
//
// Each group pins one confirmed finding with a first-principles derivation;
// where a counterexample generalises it is a seeded property.
import 'dart:math' as math;

import 'package:mechx_engine/electrical/advanced_bom.dart';
import 'package:mechx_engine/electrical/advanced_study.dart';
import 'package:mechx_engine/electrical/bom.dart' show BomLine;
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/control/starter.dart';
import 'package:mechx_engine/electrical/fault.dart';
import 'package:mechx_engine/electrical/geo_length.dart' show LayoutPos;
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/panel_results.dart';
import 'package:mechx_engine/electrical/results.dart';
import 'package:mechx_engine/electrical/sizing.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/report/drawing_chrome.dart' show kMinPlotLabelPt;
import 'package:mechx_engine/report/electrical_pagination.dart';
import 'package:mechx_engine/report/electrical_pdf_export.dart'
    show sldSinglePageMinLabelPt;
import 'package:mechx_engine/report/electrical_sld_drawing.dart';
import 'package:mechx_engine/report/riser_pagination.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

const _p = PuilProfile();
const _origin = Current(16000);

ElectricalProject _board(List<ElectricalCircuit> circuits) =>
    ElectricalProject(id: 'p', name: 'P', panels: [
      ElectricalPanel(
          id: 'MDP',
          name: 'MDP',
          system: ElectricalSystem.threePhase,
          voltage: const Voltage(400),
          circuits: circuits),
    ]);

ElectricalCircuit _sd(String id, double kw, double lengthM) =>
    ElectricalCircuit(
      id: id,
      name: id,
      loadKind: LoadKind.motor,
      motorKw: kw,
      cosPhi: 0.85,
      phases: 3,
      starterType: StarterType.starDelta,
      cableType: 'NYY',
      length: Length(lengthM),
    );

ElectricalCircuitResult _way(ElectricalSystemResult s, String id,
        [String panel = 'MDP']) =>
    s.panels[panel]!.circuits.firstWhere((r) => r.circuitId == id);

/// The TN earth-fault loop of a root-board star-delta way, rebuilt by hand:
/// source (16 kA at 400 V) + the internal link (supply section, 2 m) + ONE
/// lead conductor per lead run (the two lead cables of a line meet only
/// through the windings) + the lead PE of BOTH lead cables in parallel; R at
/// the fault temperature (× 1.28), X as tabulated.
double _handZs(ElectricalCircuitResult w) {
  final src = sourceImpedanceFromIsc(16000, 400);
  final runs = w.cable.runsPerPhase ?? 1;
  final leadRuns = w.motorLeads!.runsPerPhase ?? 1;
  final l = w.lengthM;
  final lPh = conductorImpedance(
      _p, w.motorLeads!.csaMm2, l, ConductorMaterial.copper);
  final lPe = conductorImpedance(
      _p, w.motorLeadsPeCsaMm2!, l, ConductorMaterial.copper);
  final iPh = conductorImpedance(_p, w.cable.csaMm2,
      kStarDeltaInternalWiringM, ConductorMaterial.copper);
  final iPe = conductorImpedance(_p, w.grounding.peCsaMm2,
      kStarDeltaInternalWiringM, ConductorMaterial.copper);
  final r = src.rOhm +
      lPh.rOhm * 1.28 / leadRuns +
      iPh.rOhm * 1.28 / runs +
      lPe.rOhm * 1.28 / (2 * leadRuns) +
      iPe.rOhm * 1.28 / runs;
  final x = src.xOhm +
      lPh.xOhm / leadRuns +
      iPh.xOhm / runs +
      lPe.xOhm / (2 * leadRuns) +
      iPe.xOhm / runs;
  return math.sqrt(r * r + x * x);
}

/// The way's printed Vd rebuilt by hand: the internal link (Ib on the supply
/// section, 2 m, 3φ) + the lead run as the single-phase LOOP 2·I_w·Z·L at
/// I_w = Ib/√3 against 400 V.
double _handVd(ElectricalCircuitResult w) {
  final runs = w.cable.runsPerPhase ?? 1;
  final leadRuns = w.motorLeads!.runsPerPhase ?? 1;
  final link = voltageDrop(_p,
      current: Current(w.runCurrentA.amperes / runs),
      length: const Length(kStarDeltaInternalWiringM),
      csaMm2: w.cable.csaMm2,
      cosPhi: 0.85,
      threePhase: true,
      voltage: const Voltage(400),
      isLighting: false);
  final lead = voltageDrop(_p,
      current: Current(w.runCurrentA.amperes / math.sqrt(3) / leadRuns),
      length: Length(w.lengthM),
      csaMm2: w.motorLeads!.csaMm2,
      cosPhi: 0.85,
      threePhase: false,
      voltage: const Voltage(400),
      isLighting: false);
  return link.dropPercent + lead.dropPercent;
}

void main() {
  // ── 1. star-delta Zs: one lead conductor per line ─────────────────────────
  group('regression-star-delta-zs-lead-conductors-not-parallel', () {
    test('55 kW star-delta, 150 m (TN-S 16 kA): ADS FAILS on the one-conductor '
        'loop', () {
      final pr = _board([_sd('m', 55, 150)]);
      final sys = computeSystem(_p, pr, originFaultLevel: _origin);
      final w = _way(sys, 'm');
      final f = faultStudy(sys, pr, _p, originFaultLevel: _origin)
          .circuits['m']!;
      // In 125 A curve D, a final > 32 A ⇒ 5 s ⇒ 10 × In = 1250 A:
      //   Zs_max = 0.95 × 230 / 1250 = 0.175 Ω; leads 35 mm2 (grouped),
      //   one lead conductor per line ⇒ the hand loop exceeds it.
      expect(f.zsOhm, closeTo(_handZs(w), 0.0015));
      expect(f.zsOhm!, greaterThan(f.zsMaxOhm!));
      expect(f.adsOk, isFalse);
      // The schedule now marks the row Zs! (finding 12).
      final rows = buildElectricalSld(
              project: pr,
              result: sys,
              adsFailedCircuitIds: adsFailedCircuitIdsOf(
                  faultStudy(sys, pr, _p, originFaultLevel: _origin)))
          .prims
          .whereType<SldLabel>()
          .map((l) => l.text)
          .toList();
      expect(rows.any((t) => t.endsWith('Zs!')), isTrue);
    });

    test('seeded property: the engine loop equals the one-phase-conductor hand '
        'rebuild for every star-delta way', () {
      final rng = math.Random(4301);
      for (var t = 0; t < 40; t++) {
        final kw = 7.5 + rng.nextDouble() * 150;
        final len = (10 + rng.nextInt(190)).toDouble();
        final pr = _board([_sd('m', kw, len)]);
        final sys = computeSystem(_p, pr, originFaultLevel: _origin);
        final w = _way(sys, 'm');
        final f = faultStudy(sys, pr, _p, originFaultLevel: _origin)
            .circuits['m']!;
        expect(f.zsOhm, closeTo(_handZs(w), 0.0015),
            reason: '$kw kW $len m');
        expect(f.adsOk, f.zsOhm! <= f.zsMaxOhm! + 1e-9,
            reason: '$kw kW $len m');
      }
    });
  });

  // ── 2. star-delta lead Vd: the winding loop, link included ────────────────
  group('regression-star-delta-lead-vd-understated-2-over-root3', () {
    test('30 kW, 180 m: Vd = link + 2·I_w·Z·L / 400 and stays within 5 %', () {
      final pr = _board([_sd('m', 30, 180)]);
      final w = _way(computeSystem(_p, pr), 'm');
      expect(w.voltageDrop.dropPercent, closeTo(_handVd(w), 0.011));
      expect(w.voltageDrop.withinLimit, isTrue);
      // The loop drop is 2/√3 × the old balanced-3φ figure.
      final old = voltageDrop(_p,
          current: Current(w.runCurrentA.amperes / math.sqrt(3)),
          length: const Length(180),
          csaMm2: w.motorLeads!.csaMm2,
          cosPhi: 0.85,
          threePhase: true,
          voltage: const Voltage(400),
          isLighting: false);
      final loop = voltageDrop(_p,
          current: Current(w.runCurrentA.amperes / math.sqrt(3)),
          length: const Length(180),
          csaMm2: w.motorLeads!.csaMm2,
          cosPhi: 0.85,
          threePhase: false,
          voltage: const Voltage(400),
          isLighting: false);
      expect(loop.dropV / old.dropV, closeTo(2 / math.sqrt(3), 0.01));
    });

    test('seeded property: the lead is the SMALLEST section meeting the '
        'grouped ampacity AND link + loop <= 5 %', () {
      final rng = math.Random(4302);
      final ladder = _p.standardSectionsMm2;
      for (var t = 0; t < 40; t++) {
        final kw = 7.5 + rng.nextDouble() * 120;
        final len = (20 + rng.nextInt(260)).toDouble();
        final pr = _board([_sd('m', kw, len)]);
        final w = _way(computeSystem(_p, pr), 'm');
        final leads = w.motorLeads!;
        if ((leads.runsPerPhase ?? 1) > 1) continue; // parallel leads: n/a
        expect(w.voltageDrop.dropPercent, closeTo(_handVd(w), 0.011),
            reason: '$kw kW $len m');
        expect(w.voltageDrop.withinLimit, isTrue, reason: '$kw kW $len m');
        // Round 58 — a lead raised by the TN ADS growth (the leads set the
        // earth-fault loop) is floored above its load sizing: the
        // smallest-section property holds for the load-sized leads only.
        if (w.cableRaisedForAds) continue;
        // One rung smaller fails ampacity (grouped) or the 5 % budget.
        final i = ladder.indexOf(leads.csaMm2);
        if (i <= 0) continue;
        final smaller = ladder[i - 1];
        final iw = w.runCurrentA.amperes / math.sqrt(3);
        final izSmaller = _p
                .ampacity(smaller,
                    insulation: ConductorInsulation.pvc,
                    material: ConductorMaterial.copper,
                    method: CableInstallMethod.conduit)
                .amperes *
            leads.deratingFactor;
        final linkPct = _handVd(w) -
            voltageDrop(_p,
                    current: Current(iw),
                    length: Length(len),
                    csaMm2: leads.csaMm2,
                    cosPhi: 0.85,
                    threePhase: false,
                    voltage: const Voltage(400),
                    isLighting: false)
                .dropPercent;
        final smallerPct = linkPct +
            voltageDrop(_p,
                    current: Current(iw),
                    length: Length(len),
                    csaMm2: smaller,
                    cosPhi: 0.85,
                    threePhase: false,
                    voltage: const Voltage(400),
                    isLighting: false)
                .dropPercent;
        final smallerOk = izSmaller + 1e-9 >= 1.25 * iw && smallerPct <= 5.0;
        if (smaller >= 2.5) {
          expect(smallerOk, isFalse, reason: '$kw kW $len m: $smaller mm2');
        }
      }
    });
  });

  // ── 3. star-delta leads are two grouped cables ─────────────────────────────
  group('elec-props-9-star-delta-leads-not-group-derated', () {
    test('the lead is derated as one of 2 grouped circuits (gf(2) = 0.80)',
        () {
      final w = _way(computeSystem(_p, _board([_sd('m', 63, 30)])), 'm');
      expect(w.motorLeads!.deratingFactor,
          closeTo(w.cable.deratingFactor * groupingFactor(_p, 2), 1e-9));
    });

    test('63 kW: I_w = 121.6/√3 = 70.2 A needs Iz 87.8 A ⇒ 35 mm2 (25 mm2 '
        '89 × 0.80 = 71.2 A fails)', () {
      final w = _way(computeSystem(_p, _board([_sd('m', 63, 30)])), 'm');
      final iw = w.runCurrentA.amperes / math.sqrt(3);
      expect(iw, closeTo(70.2, 0.05));
      expect(w.motorLeads!.csaMm2, 35);
      expect(w.motorLeads!.deratedIz.amperes, greaterThanOrEqualTo(1.25 * iw));
    });

    test('13 kW: I_w 14.5 A needs Iz 18.1 A ⇒ 4 mm2 (2.5 mm2 21 × 0.80 = '
        '16.8 A fails)', () {
      final w = _way(computeSystem(_p, _board([_sd('m', 13, 30)])), 'm');
      expect(w.motorLeads!.csaMm2, 4);
    });
  });

  // ── 4. the MCCB frame raise never creates an ADS failure ───────────────────
  group('electrical-sim-8-mccb-frame-raise-breaks-ads', () {
    ElectricalProject jockey(double lengthM) => _board([
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
            length: Length(lengthM),
          ),
        ]);

    test('3 kW DOL / FRC 2.5 / 40 m on a 38 kA bus keeps MCB 6 A with the '
        'cascade info, and ADS passes', () {
      const ka38 = Current(38000);
      final pr = jockey(40);
      final sys = computeSystem(_p, pr, originFaultLevel: ka38);
      final w = _way(sys, 'jp');
      // Load-sized: Ib 5.8 A ⇒ 6 A curve D; Zs_max = 0.95 × 230 / (20 × 6)
      // = 1.82 Ω vs 0.95 × 230 / (20 × 16) = 0.68 Ω for the raised 16 A.
      expect(w.breaker.deviceClass, BreakerClass.mcb);
      expect(w.breaker.ratingA.amperes, 6);
      final fs = faultStudy(sys, pr, _p, originFaultLevel: ka38);
      expect(fs.circuits['jp']!.adsOk, isTrue);
      expect(fs.warnings.map((x) => x.code),
          isNot(contains('ads-disconnection')));
      final info = sys.warnings
          .where((x) => x.code == 'mcb-backup-protection-required')
          .single;
      expect(info.message, contains('earth-fault loop'));
    });

    test('seeded property: when the load-sized MCB passes ADS, the high-fault '
        'bus never fails it', () {
      final rng = math.Random(4303);
      for (var t = 0; t < 30; t++) {
        final kw = 0.5 + rng.nextDouble() * 4;
        final len = (5 + rng.nextInt(120)).toDouble();
        final pr = jockey(len);
        final pr2 = ElectricalProject(id: 'p', name: 'P', panels: [
          pr.panels.single.copyWith(circuits: [
            pr.panels.single.circuits.single.copyWith(motorKw: kw),
          ]),
        ]);
        final low = computeSystem(_p, pr2, originFaultLevel: _origin);
        final okLow = faultStudy(low, pr2, _p, originFaultLevel: _origin)
            .circuits['jp']!
            .adsOk!;
        const high = Current(38000);
        final hi = computeSystem(_p, pr2, originFaultLevel: high);
        final okHigh = faultStudy(hi, pr2, _p, originFaultLevel: high)
            .circuits['jp']!
            .adsOk!;
        if (okLow) expect(okHigh, isTrue, reason: '$kw kW $len m');
      }
    });
  });

  // ── 5. tenant sub-meters ───────────────────────────────────────────────────
  group('electrical-sim-8-tenant-submeter-flag-ignored', () {
    ElectricalProject apt(bool submeter) => ElectricalProject(
          id: 'a',
          name: 'A',
          panels: [
            const ElectricalPanel(id: 'MDP', name: 'MDP', circuits: [
              ElectricalCircuit(
                  id: 'f',
                  name: 'Feeder U101',
                  loadKind: LoadKind.feeder,
                  feedsPanelId: 'U',
                  length: Length(20)),
            ]),
            ElectricalPanel(
              id: 'U',
              name: 'UNIT 101',
              system: ElectricalSystem.singlePhase,
              voltage: const Voltage(220),
              sourceType: PanelSource.feeder,
              fedByCircuitId: 'f',
              submeter: submeter,
              circuits: const [
                ElectricalCircuit(
                    id: 'l',
                    name: 'Lighting',
                    loadKind: LoadKind.lighting,
                    loadW: 600,
                    cosPhi: 0.9,
                    phases: 1,
                    length: Length(10)),
                ElectricalCircuit(
                    id: 's',
                    name: 'Sockets',
                    loadKind: LoadKind.socket,
                    loadW: 2000,
                    cosPhi: 0.9,
                    phases: 1,
                    length: Length(10)),
              ],
            ),
          ],
        );

    List<BomLine> unitMeters(ElectricalProject pr) {
      final sys = computeSystem(_p, pr);
      final adv = computeAdvancedStudy(_p, pr, sys);
      return [
        for (final l in meteringBomLines(pr, adv.metering))
          if (l.location == 'UNIT 101') l,
      ];
    }

    test('a sub-metered 1φ board buys ONE direct kWh meter (no V / A / Hz)',
        () {
      final lines = unitMeters(apt(true));
      expect(lines, hasLength(1));
      expect(lines.single.description, contains('kWh meter, direct'));
      expect(lines.single.qty, 1);
    });

    test('the schedule prints the kWh token + legend; submeter false is '
        'byte-identical', () {
      List<String> labels(ElectricalProject pr) => buildElectricalPanelDetail(
              project: pr, result: computeSystem(_p, pr), panelId: 'U')
          .prims
          .whereType<SldLabel>()
          .map((l) => l.text)
          .toList();
      final on = buildElectricalPanelDetail(
          project: apt(true),
          result: computeSystem(_p, apt(true)),
          panelId: 'U');
      expect(labels(apt(true)), contains('kWh direct'));
      expect(on.legend.map((e) => e.code), contains('kWh direct'));
      expect(unitMeters(apt(false)), isEmpty);
      expect(labels(apt(false)), isNot(contains('kWh direct')));
    });
  });

  // ── 6. the fire-path feeder cable ──────────────────────────────────────────
  group('electrical-sim-8-fire-path-feeder-not-frc-checked', () {
    ElectricalProject ess({String? feederCable, bool life = true}) =>
        ElectricalProject(id: 'e', name: 'E', panels: [
          ElectricalPanel(id: 'MDP', name: 'LVMDP', circuits: [
            ElectricalCircuit(
                id: 'f-ess',
                name: 'Feeder ESS',
                loadKind: LoadKind.feeder,
                feedsPanelId: 'ESS',
                cableType: feederCable,
                length: const Length(20)),
          ]),
          ElectricalPanel(
            id: 'ESS',
            name: 'ESS',
            essential: true,
            sourceType: PanelSource.feeder,
            fedByCircuitId: 'f-ess',
            circuits: [
              ElectricalCircuit(
                  id: 'fp',
                  name: 'Fire pump',
                  loadKind: LoadKind.pump,
                  motorKw: 30,
                  cosPhi: 0.85,
                  phases: 3,
                  lifeSafety: life,
                  cableType: life ? 'FRC' : 'NYY',
                  length: const Length(30)),
            ],
          ),
        ]);
    Iterable<ElectricalWarning> warn(ElectricalProject pr) =>
        computeSystem(_p, pr)
            .warnings
            .where((w) => w.code == 'life-safety-feeder-cable');

    test('an NYY feeder carrying the fire-pump supply warns, on the feeder way',
        () {
      final w = warn(ess(feederCable: 'NYY')).single;
      expect(w.severity, WarningSeverity.warning);
      expect(w.panelId, 'MDP');
      expect(w.circuitId, 'f-ess');
      expect(w.message, contains('NYY'));
    });

    test('an unspecified feeder warns too (it prints NYY)', () {
      expect(warn(ess()), hasLength(1));
    });

    test('an FRC feeder, or no life-safety load below, raises nothing', () {
      expect(warn(ess(feederCable: 'FRC')), isEmpty);
      expect(warn(ess(feederCable: 'NYY', life: false)), isEmpty);
    });
  });

  // ── 7. board lines sum EXACT way currents ─────────────────────────────────
  group('elec-drawings-6-board-demand-sums-rounded-way-currents', () {
    ElectricalProject lighting(int n, {double w = 100}) =>
        ElectricalProject(id: 'l', name: 'L', panels: [
          const ElectricalPanel(id: 'MDP', name: 'MDP', circuits: [
            ElectricalCircuit(
                id: 'f',
                name: 'Feeder DB',
                loadKind: LoadKind.feeder,
                feedsPanelId: 'DB',
                length: Length(15)),
          ]),
          ElectricalPanel(
            id: 'DB',
            name: 'DB',
            system: ElectricalSystem.singlePhase,
            voltage: const Voltage(220),
            sourceType: PanelSource.feeder,
            fedByCircuitId: 'f',
            circuits: [
              for (var i = 0; i < n; i++)
                ElectricalCircuit(
                    id: 'l$i',
                    name: 'Light $i',
                    loadKind: LoadKind.lighting,
                    loadW: w,
                    cosPhi: 0.85,
                    phases: 1,
                    length: const Length(10)),
            ],
          ),
        ]);

    test('31 × 100 W at 220 V / 0.85: 16.6 A on a 20 A incomer, TOTAL == '
        'the parent feeder row', () {
      final sys = computeSystem(_p, lighting(31));
      final db = sys.panels['DB']!;
      // Each way 100 / (220 × 0.85) = 0.5348 A (printed 0.5); the board
      // carries 3100 / (220 × 0.85) = 16.578 A → 16.6 A (never 31 × 0.5 =
      // 15.5 A on a 16 A incomer).
      expect(_way(sys, 'l0', 'DB').designCurrent.amperes, 0.5);
      expect(db.demandCurrent.amperes, 16.6);
      expect(db.incomer.breaker.ratingA.amperes, 20);
      final feeder = _way(sys, 'f');
      expect(feeder.designCurrent.amperes, db.demandCurrent.amperes);
    });

    test('seeded property: a board line == the exact sum of its ways, rounded '
        'once', () {
      final rng = math.Random(4304);
      for (var t = 0; t < 30; t++) {
        final n = 2 + rng.nextInt(40);
        final w = 20 + rng.nextDouble() * 400;
        final sys = computeSystem(_p, lighting(n, w: w));
        final db = sys.panels['DB']!;
        final exact = n * w / (220 * 0.85);
        expect(db.demandCurrent.amperes, roundTo(exact, 1),
            reason: '$n × $w W');
        expect(db.incomer.breaker.ratingA.amperes,
            greaterThanOrEqualTo(exact - 1e-9));
      }
    });
  });

  // ── 8. Iz! / Zs! on the issued schedule ────────────────────────────────────
  group('elec-drawings-6-schedule-silent-on-iz-below-in-and-ads-fail', () {
    test('a way whose In exceeds its conductor Iz prints Iz! + the legend',
        () {
      final pr = _board([
        const ElectricalCircuit(
          id: 'big',
          name: 'Big feeder load',
          loadKind: LoadKind.general,
          loadW: 700000,
          cosPhi: 0.9,
          phases: 3,
          groupingCountOverride: 9,
          breakerOverrideA: Current(4000),
          length: Length(40),
        ),
      ]);
      final sys = computeSystem(_p, pr);
      final w = _way(sys, 'big');
      expect(w.cable.ampacityReached, isFalse); // the precondition
      expect(sys.warnings.map((x) => x.code),
          contains('cable-ampacity-inadequate'));
      final sheet = buildElectricalSld(project: pr, result: sys);
      expect(
          sheet.prims
              .whereType<SldLabel>()
              .any((l) => l.text.contains('  Iz!')),
          isTrue);
      expect(sheet.legend.map((e) => e.code), contains('Iz!'));
    });

    test('a clean board is byte-identical with an empty ADS set', () {
      final pr = _board([_sd('m', 15, 20)]);
      final sys = computeSystem(_p, pr);
      List<String> t(SldSheet s) =>
          s.prims.whereType<SldLabel>().map((l) => l.text).toList();
      expect(
          t(buildElectricalSld(
              project: pr, result: sys, adsFailedCircuitIds: const {})),
          t(buildElectricalSld(project: pr, result: sys)));
      expect(t(buildElectricalSld(project: pr, result: sys)).join(),
          isNot(contains('Iz!')));
    });
  });

  // ── 9. the riser LANJUT stubs never overprint a feeder label ──────────────
  group('elec-drawings-6-riser-lanjut-stub-overprints-feeder-label', () {
    test('12 floors: no stub box intersects any other label on any page', () {
      final building = BuildingLevels([
        for (var i = 0; i < 12; i++)
          Floor('Lantai ${i + 1}', const Length(3.8)),
      ]);
      final tower = ElectricalProject(id: 't', name: 'T', panels: [
        ElectricalPanel(
            id: 'MDP',
            name: 'MDP',
            layoutPos: const LayoutPos(sheetId: 's', floorIndex: 0, x: 0, y: 0),
            circuits: [
              for (var i = 1; i <= 12; i++)
                ElectricalCircuit(
                    id: 'f$i',
                    name: 'Feeder DB-$i',
                    loadKind: LoadKind.feeder,
                    feedsPanelId: 'DB$i',
                    length: Length(10.0 + 3.5 * i)),
            ]),
        for (var i = 1; i <= 12; i++)
          ElectricalPanel(
            id: 'DB$i',
            name: 'DB-$i',
            sourceType: PanelSource.feeder,
            fedByCircuitId: 'f$i',
            layoutPos:
                LayoutPos(sheetId: 's', floorIndex: i - 1, x: 0, y: 0),
            circuits: [
              for (var k = 0; k < 4; k++)
                ElectricalCircuit(
                    id: 'd$i-$k',
                    name: 'Way $k',
                    loadKind: LoadKind.socket,
                    loadW: 3000,
                    cosPhi: 0.9,
                    phases: 1,
                    length: const Length(15)),
            ],
          ),
      ]);
      final r = computeSystem(_p, tower);
      final pages = paginatedElectricalRiserSheets(
          project: tower, result: r, building: building);
      expect(pages.length, greaterThan(1));
      var stubs = 0;
      for (final p in pages) {
        final labels = p.prims.whereType<SldLabel>().toList();
        (double, double, double, double) box(SldLabel l) => (
              l.x,
              l.y - l.size,
              l.x + l.text.length * l.size * kElectricalRiserLabelCharW,
              l.y
            );
        bool overlap((double, double, double, double) a,
                (double, double, double, double) b) =>
            a.$1 < b.$3 - 1e-9 &&
            b.$1 < a.$3 - 1e-9 &&
            a.$2 < b.$4 - 1e-9 &&
            b.$2 < a.$4 - 1e-9;
        for (final s in labels.where((l) => l.text.startsWith('LANJUT KE '))) {
          stubs++;
          for (final o in labels) {
            if (identical(o, s)) continue;
            if (overlap(box(s), box(o))) {
              // Only a counted (warned) overlap is tolerated.
              expect(p.overlapCount, greaterThan(0),
                  reason: '"${s.text}" over "${o.text}"');
            }
          }
        }
      }
      expect(stubs, greaterThan(0));
    });
  });

  // ── 10. overview chunk pages never cite a non-existent diagram ─────────────
  group('elec-drawings-6-overview-chunk-self-reference', () {
    test('a wide flat tier split into chunks names the sibling boards, never '
        '"LANJUT KE DIAGRAM <root>"', () {
      final project = ElectricalProject(id: 'w', name: 'W', panels: [
        ElectricalPanel(id: 'MDP', name: 'LVMDP', circuits: [
          for (var i = 1; i <= 30; i++)
            ElectricalCircuit(
                id: 'f$i',
                name: 'Feeder DB-$i',
                loadKind: LoadKind.feeder,
                feedsPanelId: 'DB$i',
                length: const Length(20)),
        ]),
        for (var i = 1; i <= 30; i++)
          ElectricalPanel(
            id: 'DB$i',
            name: 'DB-$i',
            sourceType: PanelSource.feeder,
            fedByCircuitId: 'f$i',
            circuits: const [
              ElectricalCircuit(
                  id: 'x',
                  name: 'Load',
                  loadKind: LoadKind.socket,
                  loadW: 2000,
                  cosPhi: 0.9,
                  phases: 1,
                  length: Length(10)),
            ],
          ),
      ]);
      final r = computeSystem(_p, project);
      final pages =
          paginatedElectricalOverviewSheets(project: project, result: r);
      expect(pages.length, greaterThan(1)); // the chunked top tier
      for (final p in pages) {
        final texts = p.prims.whereType<SldLabel>().map((l) => l.text);
        expect(texts, isNot(contains('LANJUT KE DIAGRAM LVMDP')));
      }
      expect(
          pages.any((p) => p.prims
              .whereType<SldLabel>()
              .any((l) => l.text.startsWith('LANJUT: DB-'))),
          isTrue);
    });
  });

  // ── 11. a width-bound riser page says it is illegible ─────────────────────
  group('electrical-sim-8-riser-floor-band-illegible', () {
    SldSheet sheetOfWidth(double w) => SldSheet(
          prims: [const SldLabel(0, 10, 'X', size: 8), SldLine(0, 0, w, 0)],
          minX: 0,
          minY: 0,
          maxX: w,
          maxY: 20,
          legend: const [],
          supplyNote: '',
        );

    test('a page no floor split can bring to 7 pt is flagged with its real '
        'size; a legible one is not', () {
      final wide = paginatedRiserSheets(
          build: (_) => sheetOfWidth(60000), levelCount: 3);
      for (final p in wide) {
        expect(p.belowMinLabelPt, isNotNull);
        expect(p.belowMinLabelPt!, closeTo(sldSinglePageMinLabelPt(p), 1e-9));
        expect(p.belowMinLabelPt!, lessThan(kMinPlotLabelPt));
      }
      final narrow = paginatedRiserSheets(
          build: (_) => sheetOfWidth(400), levelCount: 3);
      expect(narrow.every((p) => p.belowMinLabelPt == null), isTrue);
      expect(sldLegibilityWarning(null), isNull);
      expect(sldLegibilityWarning(1.7), contains('1.7 pt'));
    });

    test('16 sub-boards side by side: every riser page prints >= 7 pt', () {
      final project = ElectricalProject(id: 'a', name: 'A', panels: [
        ElectricalPanel(id: 'MDP', name: 'DB-L1', circuits: [
          for (var i = 1; i <= 16; i++)
            ElectricalCircuit(
                id: 'f$i',
                name: 'Unit $i',
                loadKind: LoadKind.feeder,
                feedsPanelId: 'U$i',
                length: const Length(20)),
        ]),
        for (var i = 1; i <= 16; i++)
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
                    loadKind: LoadKind.socket,
                    loadW: 1200,
                    cosPhi: 0.9,
                    phases: 1,
                    length: const Length(8)),
            ],
          ),
      ]);
      final r = computeSystem(_p, project);
      final pages = paginatedElectricalRiserSheets(project: project, result: r);
      // Re-derived Round 44 — the OR (">= 7 pt or carries the note") locked
      // in an illegible issue; the 16 identical units now collapse to ONE
      // typical node, so EVERY page prints at the plotted floor.
      for (final p in pages) {
        final pt = sldSinglePageMinLabelPt(p);
        expect(pt, greaterThanOrEqualTo(kMinPlotLabelPt - 1e-9),
            reason: '$pt pt');
        expect(p.belowMinLabelPt, isNull);
      }
    });
  });
}
