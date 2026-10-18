/// Genset backup demand (Round 13, elec-props-2-genset-ignores-essential-demand).
///
/// Pure, compute-free: reads the solved [ElectricalSystemResult] and the
/// project's essential designation only, so the drawing / schedule layers can
/// size the genset on the SAME basis as the power one-line.
library;

import '../units.dart' show ApparentPower, Power;
import 'model.dart';
import 'panel_results.dart';
import 'sources.dart' show kGeneratorPf;

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
  bool own(ElectricalPanel p) {
    final n = p.name.toUpperCase();
    return p.essential ||
        n.contains('EMERGENCY') ||
        n.contains('ESSENTIAL') ||
        n.contains('DARURAT');
  }

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
ApparentPower gensetBackupDemandVa(
    ElectricalProject project, ElectricalSystemResult sys) {
  final gen = project.sources?.generator;
  final demand = sys.supply.demandVa.voltAmperes;
  if (gen == null) return ApparentPower(demand);
  final fractionVa = demand * gen.backupFraction;
  final essentialVa = essentialDemandVa(project, sys);
  return ApparentPower(essentialVa > fractionVa ? essentialVa : fractionVa);
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
  final forced = gen?.kva;
  if (gen == null || forced == null) return const [];
  final essentialVa = essentialDemandVa(project, sys);
  final essentialW = essentialDemandW(project, sys);
  final deliveredW = forced.voltAmperes * kGeneratorPf;
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
