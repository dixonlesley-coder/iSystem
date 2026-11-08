/// Round 44 — the Commercial BOM (and so every quotation) takes off the SAME
/// containment + metering lines the advanced study derives and the issued
/// schedules print: conduit metres, V/A/Hz meters, every kWh meter
/// including a tenant board's sub-meter. Before, `electricalBomProvider`
/// called `advancedBomLines` without `containment:` / `metering:` so all of
/// it silently vanished from the quote.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/commercial_store.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx_engine/electrical/bom.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/units.dart';

ElectricalProject _tenanted() => const ElectricalProject(
      id: 'p',
      name: 'P',
      panels: [
        ElectricalPanel(
          id: 'MDP',
          name: 'MDP',
          system: ElectricalSystem.threePhase,
          voltage: Voltage(400),
          circuits: [
            ElectricalCircuit(
                id: 'h',
                name: 'Heater',
                loadKind: LoadKind.heating,
                loadW: 30000,
                phases: 3,
                length: Length(30)),
            ElectricalCircuit(
                id: 'f',
                name: 'DB',
                loadKind: LoadKind.feeder,
                feedsPanelId: 'DB',
                length: Length(20)),
          ],
        ),
        ElectricalPanel(
          id: 'DB',
          name: 'DB',
          system: ElectricalSystem.singlePhase,
          voltage: Voltage(230),
          submeter: true,
          circuits: [
            ElectricalCircuit(
                id: 'l',
                name: 'Lamp',
                loadKind: LoadKind.lighting,
                loadW: 2000,
                length: Length(15)),
          ],
        ),
      ],
    );

/// (description, qty) of the non-catalogue containment / metering lines.
Map<String, double> _cm(Bom b) {
  final out = <String, double>{};
  for (final l in b.lines) {
    final d = l.description.toLowerCase();
    if (!(d.contains('conduit') ||
        d.contains('tray') ||
        d.contains('meter') ||
        d.contains('ct '))) {
      continue;
    }
    out[l.description] = (out[l.description] ?? 0) + l.qty;
  }
  return out;
}

void main() {
  test('Commercial BOM carries the advanced study containment + metering',
      () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    c.read(electricalProjectProvider.notifier).setProject(_tenanted());

    final adv = c.read(electricalAdvancedProvider);
    final app = c.read(electricalBomProvider);
    final study = _cm(adv.bom);
    // Non-vacuous: the study does take off conduit and meters.
    expect(study.keys.any((k) => k.toLowerCase().contains('conduit')), isTrue);
    // Two kWh meters: the MDP's revenue meter + the tenant DB sub-meter.
    final kwhStudy = study.entries
        .where((e) => e.key.toLowerCase().contains('kwh meter'))
        .fold<double>(0, (s, e) => s + e.value);
    expect(kwhStudy, 2);
    // The quoted BOM carries exactly the same lines and quantities.
    expect(_cm(app), study);
  });
}
