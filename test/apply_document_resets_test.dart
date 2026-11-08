import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/data/autosave.dart';
import 'package:mechx/data/project_document.dart';
import 'package:mechx/store/schematic_layout_store.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/units.dart';

/// Opening / New / recovering a document resets every per-project store —
/// including ones keyed by ids that restart per project (n0, n1, …).
void main() {
  test(
      'applyDocument clears the diagram-only riser x overrides '
      '(node ids restart per project)', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    // Project A: the engineer dragged riser n3–n4 sideways in the Riser view.
    c.read(schematicLayoutProvider.notifier).setNodesX({'n3': 900, 'n4': 900});
    expect(c.read(schematicLayoutProvider).schematicXOverrides, hasLength(2));

    // Open project B (File→New goes through the same path).
    const doc = ProjectDocument(
      projectName: 'B',
      floors: [Floor('G', Length(3.0))],
      calibrations: {},
      sheets: [],
      network: Network(nodes: [], edges: []),
    );
    applyDocument(c.read, doc);

    expect(c.read(schematicLayoutProvider).isEmpty, isTrue);
  });
}
