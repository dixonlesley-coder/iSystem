/// Genset backup demand (Round 13, elec-props-2-genset-ignores-essential-demand).
///
/// Pure, compute-free: reads the solved [ElectricalSystemResult] and the
/// project's essential designation only, so the drawing / schedule layers can
/// size the genset on the SAME basis as the power one-line.
library;

import 'dart:math' as math;

import '../units.dart' show ApparentPower, Power;
import 'model.dart';
import 'panel_results.dart';
import 'sizing.dart' show roundTo;
import 'sources.dart' show kGeneratorPf;

/// The name words that mark a board ESSENTIAL (on the genset-backed bus) in
/// either UI language: EN EMERGENCY / ESSENTIAL, ID DARURAT / ESENSIAL (the ID
/// UI's own word for the toggle) / EMERGENSI (the other common Indonesian
/// spelling). Round 17 follow-up (i18n-residuals-essential-name) — the ID
/// spellings were missed, so a board an ID user named 'LP-ESENSIAL' dropped out
/// of the genset sizing, the motor-start screen and the red colour split.
const List<String> kEssentialNameWords = [
  'EMERGENCY',
  'ESSENTIAL',
  'DARURAT',
  'ESENSIAL',
  'EMERGENSI',
];

/// NON / TIDAK / BUKAN (optionally joined by a space, '-' or '_') before an
/// essential word — the negated designation (Round 19).
final RegExp _negatedEssentialWord = RegExp(
    r'(?<![A-Z0-9])(NON|TIDAK|BUKAN)[\s_\-]*(' '${kEssentialNameWords.join('|')}' r')');

/// True when [name] marks a board essential ([kEssentialNameWords],
/// case-insensitive). The ONE name heuristic shared by [gensetBackedPanelIds]
/// and the single-line colour split, so they can never diverge. The explicit
/// [ElectricalPanel.essential] flag stays the authority; this is the fallback.
///
/// Round 19 (regression-non-essential-name-matches-essential) — a NEGATED
/// word is the opposite designation: 'PANEL NON ESENSIAL', 'LP NON-ESSENTIAL',
/// 'PANEL TIDAK ESENSIAL', 'BUKAN DARURAT' name the board meant to be SHED, so
/// those phrases are stripped before matching ([_negatedEssentialWord]) —
/// otherwise the genset was sized to carry exactly the load the design sheds.
bool isEssentialByName(String name) {
  final n = name.toUpperCase().replaceAll(_negatedEssentialWord, ' ');
  for (final w in kEssentialNameWords) {
    if (n.contains(w)) return true;
  }
  return false;
}

/// The ESSENTIAL (genset-backed) panel ids (Round 11): a panel flagged
/// [ElectricalPanel.essential], or named EMERGENCY / ESSENTIAL / DARURAT, plus
/// every board it feeds (the property propagates DOWN the emergency sub-tree) —
/// the same rule the single-line's normal / essential colour split uses.
Set<String> gensetBackedPanelIds(ElectricalProject project) {
  final children = <String, List<String>>{};
  for (final p in project.panels) {
    for (final c in p.circuits) {
      final fed = c.feedsPanelId;
      if (fed != null && fed.isNotEmpty) {
        (children[p.id] ??= <String>[]).add(fed);
      }
    }
  }
  bool own(ElectricalPanel p) => p.essential || isEssentialByName(p.name);

  final out = <String>{};
  final stack = [for (final p in project.panels) if (own(p)) p.id];
  while (stack.isNotEmpty) {
    final id = stack.removeLast();
    if (!out.add(id)) continue; // also guards a (sanitized-away) cycle
    stack.addAll(children[id] ?? const <String>[]);
  }
  return out;
}


/// The diversified apparent-power demand (VA) of the ESSENTIAL sub-tree(s) —
/// the demand VA of each topmost genset-backed board (one whose parent is not
/// itself backed; its demand already aggregates every board it feeds).
///
/// Round 15 (regression-essential-genset-uses-building-pf) — each board's OWN
/// per-circuit VA ([ElectricalPanelResult.demandVa], `max(VA, W)`), never the
/// building-average `supply.demandVa / supply.demandW`: a 60 kW chiller board
/// at cos φ 0.72 is 83.3 kVA, not 60 kW × the building's 1.130 = 67.8 kVA (an
/// 82 kVA genset was selected against it). The averaged ratio stays only as
/// the fallback for a board with no VA record. 0 when nothing is essential.
double essentialDemandVa(ElectricalProject project, ElectricalSystemResult sys) {
  final backed = gensetBackedPanelIds(project);
  if (backed.isEmpty) return 0;
  final parentOf = <String, String>{};
  for (final p in project.panels) {
    for (final c in p.circuits) {
      final fed = c.feedsPanelId;
      if (fed != null && fed.isNotEmpty) parentOf[fed] = p.id;
    }
  }
  final supplyW = sys.supply.demandW;
  final vaPerW = supplyW > 0 ? sys.supply.demandVa.voltAmperes / supplyW : 1.0;
  var va = 0.0;
  for (final id in backed) {
    final parent = parentOf[id];
    if (parent != null && backed.contains(parent)) continue;
    final pr = sys.panels[id];
    if (pr == null) continue;
    va += pr.demandVa > 0
        ? (pr.demandVa > pr.demandW ? pr.demandVa : pr.demandW)
        : pr.demandW * vaPerW;
  }
  return va;
}

/// The demand the genset must BACK: `max(backupFraction × the diversified
/// building demand, the essential sub-tree's demand)`. The fraction alone
/// ignored the boards the set is designated to carry (a 30 % set sized 82 kVA
/// against a 120 kW essential board). A forced nameplate is NOT applied here —
/// callers keep `gen.kva` winning, and [gensetBackupWarnings] judges it.
/// No generator ⇒ the plain demand.
///
/// Round 35 (elec-core-2-genset-ignores-worst-phase) — a 3φ alternator is
/// rated PER PHASE (S / (√3·400)), so each basis is also raised to the
/// per-phase rating its HEAVIEST line needs ([gensetPhaseDemandVa]): two 1φ
/// 7 kW heaters on a 3φ MDP (30.3 A on L1 and L2, 14 kVA in total) need
/// √3·400·30.3 = 21.0 kVA, not the 17.5 kVA the balanced kW/0.8 gave (a
/// 20 kVA set is 28.9 A per phase — a silent 5 % overload). A balanced board
/// is unchanged (its worst-phase figure equals its demand VA).
ApparentPower gensetBackupDemandVa(
    ElectricalProject project, ElectricalSystemResult sys) {
  final gen = project.sources?.generator;
  final demand = sys.supply.demandVa.voltAmperes;
  if (gen == null) return ApparentPower(demand);
  final fractionVa = demand * gen.backupFraction;
  final essentialVa = essentialDemandVa(project, sys);
  final balanced = essentialVa > fractionVa ? essentialVa : fractionVa;
  final phase = gensetPhaseDemandVa(project, sys);
  return ApparentPower(
      _phaseBasisGoverns(project, sys, phase, balanced) ? phase : balanced);
}

/// Round 43 — the per-phase basis governs only when it exceeds the balanced
/// basis by more than the 0.1 A line QUANTISATION it is read through (each
/// board's printed line is rounded once to 0.1 A, so the per-phase figure
/// carries up to 0.05 A of rounding per summed board). A perfectly balanced
/// 5000 kVA board read at 7216.9 A (exact 7216.88 A) is 5 VA "over" its own
/// balanced figure — that is quantisation, not imbalance, and must never buy
/// a third 2500 kVA set. A genuinely imbalanced board (the Round-36 case)
/// clears this by orders of magnitude. Closes the Round-35 '~35 VA' residual.
bool _phaseBasisGoverns(ElectricalProject project, ElectricalSystemResult sys,
    double phaseVa, double balancedVa) {
  final boards = math.max(1,
      math.max(_rootPanelIds(project).length,
          _topmostBackedPanelIds(project).length));
  final quantumVa = capacityForLineCurrentVa(
      0.05 * boards, sys.supply.system, sys.supply.voltage.volts);
  return phaseVa > balancedVa + quantumVa;
}

/// The per-phase VA a set of boards needs: Σ over [panelIds] of the
/// [capacityForLineCurrentVa] of each board's DIVERSIFIED worst-phase current
/// (√3·V_LL·I on a 3φ board, V·I on a 1φ board) — the inverse of the
/// service-capacity judge's conversion. [roundCurrent] rounds each current to
/// 0.1 A first, exactly as the judge does (the recommended daya must never
/// disagree with it). Pure.
///
/// Round 36 (regression-genset-1ph-essential-board-per-phase) — [asSystem] /
/// [asVolts] convert every board's current on ONE supply basis instead of the
/// board's own: a 1φ 230 V essential board fed from one line of a 3φ MDP puts
/// its whole current on ONE phase of the 3φ alternator, which is rated
/// S / (√3·400) per phase, so it needs √3·400·I — not the 230·I its own basis
/// gives (one third of it). The daya path keeps the board basis (there the
/// root board IS the service).
double worstPhaseDemandVa(ElectricalProject project, ElectricalSystemResult sys,
    Iterable<String> panelIds,
    {bool roundCurrent = false,
    ElectricalSystem? asSystem,
    double? asVolts,
    bool withLargestMachine = false}) {
  final modelById = {for (final p in project.panels) p.id: p};
  var va = 0.0;
  for (final id in panelIds) {
    final r = sys.panels[id];
    final m = modelById[id];
    if (r == null || m == null) continue;
    var a = roundCurrent
        ? roundTo(r.diversifiedDemandCurrent.amperes, 1)
        : r.diversifiedDemandCurrent.amperes;
    // Round 40 — a limiter must also pass the largest single machine on or
    // below the board at its UNDIVERSIFIED running current (one machine does
    // not diversify against itself; the same figure floors the incomer and
    // the `service-capacity-below-demand` judge).
    if (withLargestMachine && r.largestDownstreamRunA > a) {
      a = r.largestDownstreamRunA;
    }
    va += capacityForLineCurrentVa(
        a, asSystem ?? m.system, asVolts ?? m.voltage.volts);
  }
  return va;
}

/// The root (utility-fed) board ids: no feeder way points at them.
Set<String> _rootPanelIds(ElectricalProject project) {
  final fed = <String>{
    for (final p in project.panels)
      for (final c in p.circuits)
        if (c.feedsPanelId != null && c.feedsPanelId!.isNotEmpty)
          c.feedsPanelId!,
  };
  return {
    for (final p in project.panels)
      if (!fed.contains(p.id) && p.fedByCircuitId == null) p.id,
  };
}

/// The topmost genset-backed board ids (a backed board whose parent is not
/// itself backed — its demand aggregates every board it feeds).
Set<String> _topmostBackedPanelIds(ElectricalProject project) {
  final backed = gensetBackedPanelIds(project);
  if (backed.isEmpty) return const {};
  final parentOf = <String, String>{};
  for (final p in project.panels) {
    for (final c in p.circuits) {
      final fed = c.feedsPanelId;
      if (fed != null && fed.isNotEmpty) parentOf[fed] = p.id;
    }
  }
  return {
    for (final id in backed)
      if (!(parentOf[id] != null && backed.contains(parentOf[id]))) id,
  };
}

/// Round 35 — the per-phase VA the genset must be rated for:
/// `max(backupFraction × the roots' worst-phase VA, the topmost essential
/// boards' worst-phase VA)` ([worstPhaseDemandVa]). 0 with no generator.
///
/// Round 36 — both terms are converted on the SUPPLY's (the alternator's)
/// basis when it is 3φ, so a 1φ essential board contributes √3·V_LL·I (its
/// whole current sits on one alternator phase). A 1φ supply keeps each
/// board's own basis (every board is then 1φ).
double gensetPhaseDemandVa(
    ElectricalProject project, ElectricalSystemResult sys) {
  final gen = project.sources?.generator;
  if (gen == null) return 0;
  final threePhaseSupply =
      sys.supply.system == ElectricalSystem.threePhase;
  if (!threePhaseSupply) {
    // A 1φ supply: every board is 1φ, the board basis is the alternator's.
    final fraction =
        worstPhaseDemandVa(project, sys, _rootPanelIds(project)) *
            gen.backupFraction;
    final essential =
        worstPhaseDemandVa(project, sys, _topmostBackedPanelIds(project));
    return essential > fraction ? essential : fraction;
  }
  final fraction = alternatorLineDemandVa(project, sys, _rootPanelIds(project)) *
      gen.backupFraction;
  final essential =
      alternatorLineDemandVa(project, sys, _topmostBackedPanelIds(project));
  return essential > fraction ? essential : fraction;
}

/// Round 37 (regression-genset-1ph-boards-on-different-lines-summed) — the
/// per-phase VA a 3φ alternator needs to carry [panelIds], accumulated per
/// alternator LINE rather than per board: a 3φ board adds its diversified
/// L1 / L2 / L3 currents (`phaseBalance × diversityFactor`), a 1φ board adds
/// its whole diversified current to the line its feeding way occupies on the
/// parent board (the way's solved phase). The heaviest line then converts
/// once, `√3·V_LL·I_max` ([capacityForLineCurrentVa]). Three 1φ 30.4 A
/// essential boards on L1 / L2 / L3 load each alternator phase with 30.4 A
/// and need √3·400·30.4 = 21.1 kVA — the Round-36 per-board sum gave three
/// times that (a 65 kVA set where a 33 kVA set carries 47.6 A per phase). A
/// 1φ board whose line cannot be resolved (no parent, or the way is not on
/// one line) keeps the conservative per-board term √3·V_LL·I. Pure.
double alternatorLineDemandVa(ElectricalProject project,
    ElectricalSystemResult sys, Iterable<String> panelIds) {
  final volts = sys.supply.voltage.volts;
  final modelById = {for (final p in project.panels) p.id: p};
  // child panel id → (parent id, feeding circuit id)
  final feedOf = <String, (String, String)>{};
  for (final p in project.panels) {
    for (final c in p.circuits) {
      final fed = c.feedsPanelId;
      if (fed != null && fed.isNotEmpty) feedOf[fed] = (p.id, c.id);
    }
  }
  var l1 = 0.0, l2 = 0.0, l3 = 0.0;
  var unresolvedVa = 0.0;
  for (final id in panelIds) {
    final r = sys.panels[id];
    final m = modelById[id];
    if (r == null || m == null) continue;
    if (m.system == ElectricalSystem.threePhase) {
      // Round 39 r3 — the ONE labelled assignment each board prints: the
      // assignment is persisted in the document (`assignedPhase`), so the
      // per-phase sum is a function of the document alone.
      final b = r.phaseBalance;
      final d = r.diversityFactor;
      l1 += b.l1 * d;
      l2 += b.l2 * d;
      l3 += b.l3 * d;
      continue;
    }
    final a = r.diversifiedDemandCurrent.amperes;
    final feed = feedOf[id];
    final parent = feed == null ? null : sys.panels[feed.$1];
    PhaseAssignment? line;
    if (parent != null && parent.system == ElectricalSystem.threePhase) {
      // Round 39 r3 — the labelled line the parent's schedule prints.
      for (final cr in parent.circuits) {
        if (cr.circuitId == feed!.$2) {
          line = cr.phase;
          break;
        }
      }
    }
    switch (line) {
      case PhaseAssignment.l1:
        l1 += a;
      case PhaseAssignment.l2:
        l2 += a;
      case PhaseAssignment.l3:
        l3 += a;
      default:
        unresolvedVa += capacityForLineCurrentVa(
            a, ElectricalSystem.threePhase, volts);
    }
  }
  final worst = l1 > l2 ? (l1 > l3 ? l1 : l3) : (l2 > l3 ? l2 : l3);
  return capacityForLineCurrentVa(worst, ElectricalSystem.threePhase, volts) +
      unresolvedVa;
}

/// JUDGE-ONLY: a FORCED genset nameplate (`gen.kva`) below the essential
/// sub-tree's demand cannot carry the boards it is designated to back. Never
/// resizes — the engineer's nameplate stands.
///
/// Two independent limits (Round 17, regression-forced-genset-kw-limit-
/// unjudged): the alternator's kVA against the essential VA
/// (`genset-below-essential-demand`), and the ENGINE's kW = [kGeneratorPf] ×
/// kVA against the essential W (`genset-below-essential-power`) — a
/// 100 kVA / 80 kW set passes the VA test against a 94.7 kVA / 90 kW board
/// (cos φ 0.95) yet overloads its engine by 10 kW.
List<ElectricalWarning> gensetBackupWarnings(
    ElectricalProject project, ElectricalSystemResult sys) {
  final gen = project.sources?.generator;
  // Round 44 — the forced PLANT capacity (per-set kVA × paralleled sets).
  final forced = gen?.totalKva;
  if (gen == null || forced == null) return const [];
  final essentialVa = essentialDemandVa(project, sys);
  final essentialW = essentialDemandW(project, sys);
  final deliveredW = forced.voltAmperes * kGeneratorPf;
  final phaseVa = gensetPhaseDemandVa(project, sys);
  // Fires only where the IMBALANCE raises the need above the balanced
  // basis (the two balanced limits above already judge the rest).
  final fractionVa = sys.supply.demandVa.voltAmperes * gen.backupFraction;
  final balancedVa = essentialVa > fractionVa ? essentialVa : fractionVa;
  String kva(double va) => (va / 1000).toStringAsFixed(1);
  return [
    if (essentialVa > 0 && forced.voltAmperes + 1e-6 < essentialVa)
      ElectricalWarning(
        code: 'genset-below-essential-demand',
        severity: WarningSeverity.warning,
        message: 'Genset: the forced ${kva(forced.voltAmperes)} kVA nameplate is '
            'below the ${kva(essentialVa)} kVA demand of the essential '
            '(genset-backed) boards it must carry — raise the genset rating or '
            'shed essential load.',
      ),
    if (essentialW > 0 && deliveredW + 1e-6 < essentialW)
      ElectricalWarning(
        code: 'genset-below-essential-power',
        severity: WarningSeverity.warning,
        message: 'Genset: the forced ${kva(forced.voltAmperes)} kVA nameplate '
            'delivers ${kva(deliveredW)} kW (at the rated pf '
            '${kGeneratorPf.toStringAsFixed(1)}), below the ${kva(essentialW)} '
            'kW real-power demand of the essential (genset-backed) boards — the '
            'engine is overloaded; raise the genset rating or shed essential '
            'load.',
      ),
    // Round 35 — a 3φ alternator is rated PER PHASE: the heaviest line of
    // the backed boards must fit S / (√3·400). Judge-only.
    if (phaseVa > 0 &&
        forced.voltAmperes + 1e-6 < phaseVa &&
        _phaseBasisGoverns(project, sys, phaseVa, balancedVa))
      ElectricalWarning(
        code: 'genset-phase-overload',
        severity: WarningSeverity.warning,
        message: 'Genset: the forced ${kva(forced.voltAmperes)} kVA nameplate '
            'is rated ${(lineCurrentForCapacityA(forced.voltAmperes, sys.supply.system, sys.supply.voltage.volts)).toStringAsFixed(1)} A '
            'per phase, below the heaviest line of the boards it backs '
            '(needs ${kva(phaseVa)} kVA of per-phase rating) — the alternator '
            'overloads on that phase; raise the genset rating or rebalance the '
            'single-phase load.',
      ),
  ];
}

/// Round 16 (supply-sources-genset-kw-limit-ignored) — the REAL power (W) the
/// genset must back, on the same basis as [gensetBackupDemandVa]:
/// `max(backupFraction × the building demand W, the essential sub-tree's
/// demand W)`. A genset's engine is rated kW = pf_rated (0.8) × kVA, so a load
/// above cos φ 0.8 is kW-limited, not kVA-limited — sizing on the kVA alone
/// selected a 100 kVA / 80 kW set for a 90 kW load. No generator ⇒ the plain
/// building demand W.
Power gensetBackupDemandW(
    ElectricalProject project, ElectricalSystemResult sys) {
  final gen = project.sources?.generator;
  final demandW = sys.supply.demandW;
  if (gen == null) return Power(demandW);
  final fractionW = demandW * gen.backupFraction;
  final essentialW = essentialDemandW(project, sys);
  return Power(essentialW > fractionW ? essentialW : fractionW);
}

/// The diversified REAL-power demand (W) of the ESSENTIAL sub-tree(s) — the
/// demand W of each topmost genset-backed board (its demand already
/// aggregates every board it feeds). 0 when nothing is essential. The kW twin
/// of [essentialDemandVa], shared by [gensetBackupDemandW] and the forced-
/// nameplate judge in [gensetBackupWarnings].
double essentialDemandW(ElectricalProject project, ElectricalSystemResult sys) {
  final backed = gensetBackedPanelIds(project);
  if (backed.isEmpty) return 0;
  final parentOf = <String, String>{};
  for (final p in project.panels) {
    for (final c in p.circuits) {
      final fed = c.feedsPanelId;
      if (fed != null && fed.isNotEmpty) parentOf[fed] = p.id;
    }
  }
  var essentialW = 0.0;
  for (final id in backed) {
    final parent = parentOf[id];
    if (parent != null && backed.contains(parent)) continue;
    essentialW += sys.panels[id]?.demandW ?? 0;
  }
  return essentialW;
}
