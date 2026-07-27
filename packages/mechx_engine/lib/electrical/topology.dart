/// Pure feeder-topology normalization for electrical projects.
///
/// [sanitizeFeederTopology] removes dangling feeder references and repairs
/// mismatched back-pointers between panels and their feeding circuits. It never
/// invents new topology, only cleans up references that became invalid after
/// deletes or edits.
///
/// Used by the app's delete intents (e.g., when a circuit or panel is removed)
/// and on document load to ensure consistency after external edits.
///
/// Zero Flutter imports.
library;

import 'model.dart' show ElectricalCircuit, ElectricalPanel, PanelSource;

/// Normalizes feeder circuit topology across a panel list.
///
/// Rules:
/// 1. Removes feeder circuits (feedsPanelId != null) that target a non-existent
///    panel or have an empty-string target.
/// 2. Clears [fedByCircuitId] and resets [sourceType] to [PanelSource.utility]
///    on panels whose feeding circuit (after rule 1) either doesn't exist or
///    does not target this panel.
/// 3. Repairs [fedByCircuitId] on panels targeted by exactly one live feeder
///    circuit when the back-pointer is null or mismatched.
///
/// Identity-preserving: returns the same list instance if nothing changes, and
/// reuses unchanged panel instances within modified lists.
///
/// Idempotent: sanitize(sanitize(x)) == sanitize(x) (structurally).
List<ElectricalPanel> sanitizeFeederTopology(List<ElectricalPanel> panels) {
  // Fast path: empty list.
  if (panels.isEmpty) return panels;

  // Build a map of panel id → panel for O(1) target lookup.
  final panelById = <String, ElectricalPanel>{};
  for (final panel in panels) {
    panelById[panel.id] = panel;
  }

  // ─── Rule 1: Remove feeder circuits with invalid targets ───────────────
  // Collect all live (valid-target) feeder circuit ids per target panel id.
  final liveFeedersByTargetPanelId = <String, List<ElectricalCircuit>>{};

  for (final panel in panels) {
    final cleanedCircuits = <ElectricalCircuit>[];
    for (final circuit in panel.circuits) {
      final targetPanelId = circuit.feedsPanelId;

      // Feeder with empty or non-existent target → remove.
      if (targetPanelId != null && targetPanelId.isNotEmpty) {
        if (panelById.containsKey(targetPanelId)) {
          cleanedCircuits.add(circuit);
          liveFeedersByTargetPanelId.putIfAbsent(targetPanelId, () => []);
          liveFeedersByTargetPanelId[targetPanelId]!.add(circuit);
        }
        // else: target doesn't exist → drop the circuit.
      } else if (targetPanelId == null) {
        // Non-feeder circuit → keep.
        cleanedCircuits.add(circuit);
      }
      // else: targetPanelId == '' → drop the circuit (rule 1).
    }

    // Update panel's circuits if anything was removed.
    if (cleanedCircuits.length != panel.circuits.length) {
      panelById[panel.id] =
          panel.copyWith(circuits: cleanedCircuits);
    }
  }

  // ─── Rule 2 & 3: Repair back-pointers ─────────────────────────────────
  var anyChanged = false;
  final resultPanels = <ElectricalPanel>[];

  for (final originalPanel in panels) {
    // Use the potentially updated panel from rule 1.
    var panel = panelById[originalPanel.id]!;

    final feedingCircuits = liveFeedersByTargetPanelId[panel.id] ?? [];
    final hasSingleFeeder = feedingCircuits.length == 1;
    final singleFeederId = hasSingleFeeder ? feedingCircuits[0].id : null;

    // Rule 2: Check if the back-pointer is valid.
    // A back-pointer is valid if the circuit it references:
    //   - exists on some panel (was not removed in rule 1) AND
    //   - targets this panel
    bool backPointerIsValid = false;
    if (panel.fedByCircuitId != null) {
      // Check if this circuit id exists in any panel's circuits and targets this panel.
      for (final currentPanel in panelById.values) {
        for (final circuit in currentPanel.circuits) {
          if (circuit.id == panel.fedByCircuitId &&
              circuit.feedsPanelId == panel.id) {
            backPointerIsValid = true;
            break;
          }
        }
        if (backPointerIsValid) break;
      }
    }

    if (panel.fedByCircuitId != null && !backPointerIsValid) {
      // Rule 2: Clear the dangling or mismatched back-pointer.
      panel = panel.copyWith(
        sourceType: PanelSource.utility,
        clearFedByCircuitId: true,
      );
      anyChanged = true;
    }

    // Rule 3: Repair mismatched back-pointer.
    // If exactly one feeder targets this panel but the back-pointer is
    // null or points to a different circuit, repair it.
    if (hasSingleFeeder && panel.fedByCircuitId != singleFeederId) {
      panel = panel.copyWith(
        sourceType: PanelSource.feeder,
        fedByCircuitId: singleFeederId,
      );
      anyChanged = true;
    }

    resultPanels.add(panel);
  }

  // Identity-preserving: return the same list if nothing changed.
  if (!anyChanged && panelById.values.every((p) => panels.contains(p))) {
    return panels;
  }

  return resultPanels;
}
