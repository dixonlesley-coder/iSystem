/// Re-export shim. The pure (Flutter-free) riser-tag helpers were lifted into
/// the engine (`package:mechx_engine/report/riser_tags.dart`) so the schematic
/// painter AND the pure-engine mechanical riser single-line builder
/// (`mechanical_sld_drawing.dart`) share ONE source of truth. This shim keeps
/// the painter's and the existing test's `import 'riser_tags.dart'` working.
library;

export 'package:mechx_engine/report/riser_tags.dart';
