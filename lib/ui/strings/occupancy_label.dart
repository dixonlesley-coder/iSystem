import 'package:mechx_engine/standards/sni.dart' show Occupancy;

import 'app_strings.dart';

/// Round 29 (ui-journeys-3-occupancy-two-vocabularies) — the ONE label for an
/// [Occupancy] class: the Building page's input, the live riser KETERANGAN
/// notes and the exported riser sheet all print the SAME words (Residential /
/// Office / public / Assembly / mall, localized), never the internal enum
/// name ('Private').
StringKey occupancyLabelKey(Occupancy o) => switch (o) {
      Occupancy.private => StringKey.inspectorOccupancyResidential,
      Occupancy.public => StringKey.inspectorOccupancyPublic,
      Occupancy.assembly => StringKey.inspectorOccupancyAssembly,
    };
