import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/data/autosave.dart';
import 'package:mechx/data/project_document.dart';
import 'package:mechx/store/reference_line_store.dart';
import 'package:mechx/ui/canvas/reference_line_overlay.dart';

/// B12 Ref line trace tool: two clicks create a construction line, and it
/// round-trips through the `.mechx` document (buildDocument → applyDocument).
void main() {
  testWidgets('two clicks create a reference line that persists via the document',
      (tester) async {
    final c = ProviderContainer();
    addTearDown(c.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: const Directionality(
          textDirection: TextDirection.ltr,
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 500,
              height: 400,
              child: ReferenceLineOverlay(sheetId: 's1', active: true),
            ),
          ),
        ),
      ),
    );

    // Identity viewport (no sheet seeded) ⇒ screen == world; underlay is a
    // no-op (no sheet), so the two taps land exactly.
    await tester.tapAt(const Offset(80, 120));
    await tester.pump();
    // First click only pends — no line yet.
    expect(c.read(referenceLinesProvider), isEmpty);

    await tester.tapAt(const Offset(300, 120));
    await tester.pump();

    final lines = c.read(referenceLinesProvider);
    expect(lines, hasLength(1));
    final l = lines.single;
    expect(l.sheetId, 's1');
    expect(l.x1, closeTo(80, 0.5));
    expect(l.x2, closeTo(300, 0.5));

    // Round-trip through the versioned document.
    final doc = buildDocument(c.read);
    final restored = ProjectDocument.decode(doc.encode());
    // Clear + reapply.
    c.read(referenceLinesProvider.notifier).clear();
    expect(c.read(referenceLinesProvider), isEmpty);
    applyDocument(c.read, restored);

    final after = c.read(referenceLinesProvider);
    expect(after, hasLength(1));
    expect(after.single.x1, closeTo(80, 0.5));
    expect(after.single.x2, closeTo(300, 0.5));
  });
}
