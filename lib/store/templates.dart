import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/sizing/fire_sprinkler.dart';
import 'package:mechx_engine/standards/sni.dart';
import 'package:mechx_engine/units.dart';

import 'app_state.dart';
import 'fire_store.dart';
import 'project_store.dart';

/// A pure building descriptor — smart defaults for a common building type that
/// cut cold-start setup. A template prefills the floor stack (count + names +
/// heights), the [Occupancy] class, the sprinkler [FireHazardClass], and the
/// design rainfall intensity (mm/hr). It carries no Flutter dependency; it is
/// applied at runtime via [applyTemplate] by calling existing controller intent
/// methods, so there is NO `.mechx` schema change — a template is just a faster
/// way to reach a state the user could have typed in by hand.
class BuildingTemplate {
  /// Display name shown in the picker.
  final String name;

  /// A one-line description of the building type.
  final String description;

  /// The floor stack, lowest first — the §10 source of truth for vertical run
  /// length. Heights are floor-to-floor in metres.
  final List<Floor> floors;

  /// SNI fixture-unit occupancy class driving the water-supply demand curve.
  final Occupancy occupancy;

  /// Sprinkler hazard class driving the fire-sprinkler design.
  final FireHazardClass fireHazard;

  /// Design rainfall intensity (mm/hr) driving storm/rainwater sizing.
  final double rainfallMmPerHr;

  const BuildingTemplate({
    required this.name,
    required this.description,
    required this.floors,
    required this.occupancy,
    required this.fireHazard,
    required this.rainfallMmPerHr,
  });
}

/// The built-in building templates / smart defaults.
///
/// The occupancy + hazard mappings follow Indonesian practice but are general
/// design defaults, not verbatim SNI clauses — they are smart starting points
/// the engineer then refines. The rainfall intensity is a representative design
/// storm; the user should confirm it against the local design storm.
const List<BuildingTemplate> kBuildingTemplates = [
  BuildingTemplate(
    name: 'Residential highrise',
    description:
        'Multi-storey apartments — private dwelling loads, light fire hazard.',
    floors: [
      Floor('Ground', Length(4.0)),
      Floor('Level 1', Length(3.2)),
      Floor('Level 2', Length(3.2)),
      Floor('Level 3', Length(3.2)),
      Floor('Level 4', Length(3.2)),
      Floor('Level 5', Length(3.2)),
    ],
    occupancy: Occupancy.private,
    fireHazard: FireHazardClass.lightHazard,
    rainfallMmPerHr: 200.0,
  ),
  BuildingTemplate(
    name: 'Office tower',
    description:
        'Commercial offices — public occupancy, ordinary fire hazard.',
    floors: [
      Floor('Ground', Length(4.5)),
      Floor('Level 1', Length(3.8)),
      Floor('Level 2', Length(3.8)),
      Floor('Level 3', Length(3.8)),
      Floor('Level 4', Length(3.8)),
      Floor('Level 5', Length(3.8)),
      Floor('Level 6', Length(3.8)),
      Floor('Level 7', Length(3.8)),
    ],
    occupancy: Occupancy.public,
    fireHazard: FireHazardClass.ordinaryHazard1,
    rainfallMmPerHr: 200.0,
  ),
  BuildingTemplate(
    name: 'Hospital',
    description:
        'Healthcare — assembly occupancy, ordinary hazard group 2.',
    floors: [
      Floor('Ground', Length(4.5)),
      Floor('Level 1', Length(4.0)),
      Floor('Level 2', Length(4.0)),
      Floor('Level 3', Length(4.0)),
      Floor('Level 4', Length(4.0)),
    ],
    occupancy: Occupancy.assembly,
    fireHazard: FireHazardClass.ordinaryHazard2,
    rainfallMmPerHr: 250.0,
  ),
  BuildingTemplate(
    name: 'Retail shop',
    description:
        'Single/low-rise retail — public occupancy, ordinary hazard group 2.',
    floors: [
      Floor('Ground', Length(4.5)),
      Floor('Level 1', Length(4.0)),
    ],
    occupancy: Occupancy.public,
    fireHazard: FireHazardClass.ordinaryHazard2,
    rainfallMmPerHr: 200.0,
  ),
];

/// Apply [template] to the live project + design-settings providers via their
/// existing intent methods: replace the floor stack ([ProjectController.setFloors]),
/// set the [Occupancy], the [FireHazardClass], and the rainfall intensity.
///
/// Each provider records its own undo step (per the per-domain undo
/// architecture); calibration, drawn network, and the project name are left
/// untouched. Templates are transient smart defaults — nothing is persisted as
/// "the chosen template", only the resulting state (which round-trips normally).
void applyTemplate(WidgetRef ref, BuildingTemplate template) =>
    applyTemplateTo(ref.read, template);

/// Container-friendly core of [applyTemplate]: [read] is the `read` of a
/// `WidgetRef` (from the UI) or a `ProviderContainer` (from tests). Both expose
/// the same `read(provider)` shape, so the application logic lives in one place.
void applyTemplateTo(
  T Function<T>(ProviderListenable<T> provider) read,
  BuildingTemplate template,
) {
  read(projectControllerProvider.notifier).setFloors(template.floors);
  read(occupancyProvider.notifier).set(template.occupancy);
  read(fireHazardProvider.notifier).set(template.fireHazard);
  read(rainfallIntensityProvider.notifier).set(template.rainfallMmPerHr);
}
