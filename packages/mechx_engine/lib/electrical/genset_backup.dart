/// Genset backup demand (Round 13, elec-props-2-genset-ignores-essential-demand).
///
/// Pure, compute-free: reads the solved [ElectricalSystemResult] and the
/// project's essential designation only, so the drawing / schedule layers can
/// size the genset on the SAME basis as the power one-line.
library;

import '../units.dart' show ApparentPower;
import 'model.dart';
import 'panel_results.dart';

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
/// the demand W of each topmost genset-backed board (one whose parent is not
/// itself backed; its demand already aggregates every board it feeds),
/// converted at the SAME power-factor basis as the supply summary
/// (`supply.demandVa / supply.demandW`). 0 when nothing is flagged essential.
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
  var w = 0.0;
  for (final id in backed) {
    final parent = parentOf[id];
    if (parent != null && backed.contains(parent)) continue;
    w += sys.panels[id]?.demandW ?? 0;
  }
  final supplyW = sys.supply.demandW;
  final vaPerW = supplyW > 0 ? sys.supply.demandVa.voltAmperes / supplyW : 1.0;
  return w * vaPerW;
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
List<ElectricalWarning> gensetBackupWarnings(
    ElectricalProject project, ElectricalSystemResult sys) {
  final gen = project.sources?.generator;
  final forced = gen?.kva;
  if (gen == null || forced == null) return const [];
  final essentialVa = essentialDemandVa(project, sys);
  if (essentialVa <= 0 || forced.voltAmperes + 1e-6 >= essentialVa) {
    return const [];
  }
  String kva(double va) => (va / 1000).toStringAsFixed(1);
  return [
    ElectricalWarning(
      code: 'genset-below-essential-demand',
      severity: WarningSeverity.warning,
      message: 'Genset: the forced ${kva(forced.voltAmperes)} kVA nameplate is '
          'below the ${kva(essentialVa)} kVA demand of the essential '
          '(genset-backed) boards it must carry — raise the genset rating or '
          'shed essential load.',
    ),
  ];
}
