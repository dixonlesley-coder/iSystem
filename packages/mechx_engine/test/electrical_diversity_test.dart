import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/diversity_library.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

/// Occupancy-keyed diversity / demand-factor library tests.
///
/// The library overrides each circuit's per-kind `demandFactor` with an
/// occupancy + load-kind value ONLY when the panel sets `diversityLibraryId`
/// AND the library is supplied to `computeSystem`. With neither, the engine uses
/// the model's own `demandFactor` exactly as before (the byte-identical guard).
void main() {
  const p = PuilProfile();
  const lib = PuilDiversityLibrary();

  // A single 1-phase socket-outlet circuit, 10 kW connected. Its connected
  // demand W = 10000 × demandFactor.
  ElectricalProject projectWith({
    String? libraryId,
    double circuitDemandFactor = 0.7,
  }) =>
      ElectricalProject(
        id: 'pr',
        name: 'Bldg',
        panels: [
          ElectricalPanel(
            id: 'LP',
            name: 'Lighting/Power',
            system: ElectricalSystem.singlePhase,
            voltage: const Voltage(220),
            diversityLibraryId: libraryId,
            circuits: [
              ElectricalCircuit(
                id: 'c1',
                name: 'Sockets',
                loadKind: LoadKind.socket,
                loadW: 10000,
                demandFactor: circuitDemandFactor,
                length: const Length(20),
              ),
            ],
          ),
        ],
      );

  group('library factors', () {
    test('residential socket demand factor is 0.5, office is 0.4', () {
      // Hand-checked against the seeded table.
      expect(lib.demandFactorFor('residential', LoadKind.socket, fallback: 1),
          0.5);
      expect(
          lib.demandFactorFor('office', LoadKind.socket, fallback: 1), 0.4);
      // Lighting barely diversifies in an office (all on together).
      expect(
          lib.demandFactorFor('office', LoadKind.lighting, fallback: 1), 0.9);
    });

    test('unknown occupancy OR unmapped kind falls back', () {
      // No such occupancy → fallback verbatim.
      expect(lib.demandFactorFor('nope', LoadKind.socket, fallback: 0.33),
          0.33);
      // 'spare'/'feeder' are not in any column → fallback.
      expect(lib.demandFactorFor('office', LoadKind.spare, fallback: 0.42),
          0.42);
    });

    test('occupancy ids + labels are exposed', () {
      expect(lib.occupancyIds, contains('residential'));
      expect(lib.occupancyIds, contains('office'));
      expect(lib.occupancyLabel('office'), 'Office / commercial');
      expect(lib.occupancyLabel('mystery'), 'mystery'); // unknown → raw id
      expect(lib.hasOccupancy('office'), isTrue);
      expect(lib.hasOccupancy('mystery'), isFalse);
      expect(lib.interfaceVersion, 1);
    });
  });

  group('computeSystem wiring', () {
    test('no library OR no id ⇒ per-circuit demandFactor (byte-identical)', () {
      // demandFactor 0.7 ⇒ connected demand = 10000 × 0.7 = 7000 W.
      final noLib =
          computeSystem(p, projectWith(libraryId: null)); // id null
      expect(noLib.panels['LP']!.connectedW, 7000);

      // Even with a library supplied, a null id keeps the per-circuit factor.
      final libNoId = computeSystem(p, projectWith(libraryId: null),
          diversityLibrary: lib);
      expect(libNoId.panels['LP']!.connectedW, 7000);
    });

    test('id + library ⇒ occupancy factor overrides the per-circuit one', () {
      // Office socket factor = 0.4 ⇒ connected demand = 10000 × 0.4 = 4000 W,
      // overriding the circuit's own 0.7.
      final office = computeSystem(
        p,
        projectWith(libraryId: 'office', circuitDemandFactor: 0.7),
        diversityLibrary: lib,
      );
      expect(office.panels['LP']!.connectedW, 4000);

      // Residential socket factor = 0.5 ⇒ 10000 × 0.5 = 5000 W.
      final residential = computeSystem(
        p,
        projectWith(libraryId: 'residential', circuitDemandFactor: 0.7),
        diversityLibrary: lib,
      );
      expect(residential.panels['LP']!.connectedW, 5000);
    });

    test('id set but NO library supplied ⇒ still per-circuit (byte-identical)',
        () {
      // The id alone does nothing without the library object.
      final idOnly = computeSystem(p, projectWith(libraryId: 'office'));
      expect(idOnly.panels['LP']!.connectedW, 7000);
    });

    test('unknown library id ⇒ fallback to per-circuit factor', () {
      final unknown = computeSystem(
        p,
        projectWith(libraryId: 'no-such-occupancy', circuitDemandFactor: 0.7),
        diversityLibrary: lib,
      );
      expect(unknown.panels['LP']!.connectedW, 7000);
    });
  });

  test('effectiveDemandFactor: feeders are never re-diversified', () {
    const feeder = ElectricalCircuit(
      id: 'f1',
      name: 'Feeder',
      loadKind: LoadKind.feeder,
      feedsPanelId: 'SUB',
      demandFactor: 1,
    );
    // Even with a matching occupancy, a feeder keeps its own factor (1.0): it
    // already carries the diversified demand of the panel it feeds.
    expect(
      effectiveDemandFactor(feeder,
          library: lib, diversityLibraryId: 'office'),
      1,
    );
  });
}
