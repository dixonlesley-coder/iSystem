// Round 34 — the app's electrical exports:
//
//   electrical-drawings-4-app-schedule-conduit-ladder-not-study   every board
//     schedule the app builds carries the containment STUDY's conduit (one
//     containment source), never the CSA-ladder fallback.
//   electrical-drawings-4-standalone-layout-dwg-number   a standalone layout
//     sheet is numbered by its position among the electrical layout sheets
//     (E-10k, Sheet k of n) — the submittal's numbering — never a flat E-101.
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/electrical_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/sheets_store.dart';
import 'package:mechx/ui/electrical/electrical_export.dart';
import 'package:mechx_engine/electrical/advanced_study.dart'
    show containmentByCircuitIdOf;
import 'package:mechx_engine/electrical/geo_length.dart' show LayoutPos;
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/report/electrical_sld_drawing.dart';
import 'package:mechx_engine/units.dart';

Future<(WidgetRef, ProviderContainer)> _harness(WidgetTester tester) async {
  late WidgetRef capturedRef;
  await tester.pumpWidget(
    ProviderScope(
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Consumer(builder: (context, ref, _) {
          capturedRef = ref;
          return const SizedBox.shrink();
        }),
      ),
    ),
  );
  await tester.pump();
  final container = ProviderScope.containerOf(
      tester.element(find.byType(Consumer)),
      listen: false);
  return (capturedRef, container);
}

/// SDP-0 with a 7.5 kW 3-phase AHU motor way (NYY 4-core) + a socket way,
/// placed on [sheetId] when given.
ElectricalProject _project({String? sheetId}) =>
    ElectricalProject(id: 'p', name: 'P', panels: [
      ElectricalPanel(
        id: 'SDP0',
        name: 'SDP-0',
        layoutPos: sheetId == null
            ? null
            : LayoutPos(sheetId: sheetId, floorIndex: 1, x: 200, y: 200),
        circuits: const [
          ElectricalCircuit(
              id: 'ahu',
              name: 'AHU',
              loadKind: LoadKind.motor,
              motorKw: 7.5,
              phases: 3,
              cableType: 'NYY',
              length: Length(25)),
          ElectricalCircuit(
              id: 'sk',
              name: 'Socket',
              loadKind: LoadKind.socket,
              loadW: 900,
              length: Length(15)),
        ],
      ),
    ]);

void main() {
  testWidgets('the app schedule prints the containment STUDY conduit',
      (tester) async {
    final (ref, c) = await _harness(tester);
    c.read(electricalProjectProvider.notifier).setProject(_project());
    final study = containmentByCircuitIdOf(c.read(electricalAdvancedProvider));
    expect(study, isNotEmpty);
    // The app helper IS the study map (one source).
    final app = containmentByCircuit(ref);
    expect(app.keys.toSet(), study.keys.toSet());
    final sheet = buildElectricalSld(
      project: c.read(electricalProjectProvider),
      result: c.read(electricalResultProvider),
      containmentByCircuitId: app,
    );
    final texts = [for (final l in sheet.prims.whereType<SldLabel>()) l.text];
    for (final e in study.entries) {
      final spec = e.value;
      // A run that fits a standard conduit prints the study's trade size.
      if (spec.fillPct <= 40) {
        expect(
            texts.any(
                (t) => t.contains('PVC ${spec.conduitSizeMm.round()}mm')),
            isTrue,
            reason: '${e.key}: ${spec.conduitSizeMm} mm (study)');
      }
    }
  });

  testWidgets('a standalone layout sheet is numbered by its position',
      (tester) async {
    final (ref, c) = await _harness(tester);
    c.read(sheetsControllerProvider.notifier).loadDemoSheets(); // s1 s2 s3
    for (final s in ['s1', 's2', 's3']) {
      c.read(projectControllerProvider.notifier)
          .setCalibration(s, const ScaleCalibration(0.02));
    }
    // Two layout sheets: s2 (SDP-0) and s3 (a second board).
    final base = _project(sheetId: 's2');
    c.read(electricalProjectProvider.notifier).setProject(ElectricalProject(
          id: base.id,
          name: base.name,
          panels: [
            ...base.panels,
            const ElectricalPanel(
              id: 'SDP1',
              name: 'SDP-1',
              layoutPos:
                  LayoutPos(sheetId: 's3', floorIndex: 2, x: 300, y: 300),
              circuits: [
                ElectricalCircuit(
                    id: 'l',
                    name: 'Light',
                    loadKind: LoadKind.lighting,
                    isLighting: true,
                    loadW: 400,
                    length: Length(10)),
              ],
            ),
          ],
        ));
    expect(electricalLayoutSheetIds(ref), ['s2', 's3']);
    final s2 = electricalLayoutChrome(ref, 's2');
    final s3 = electricalLayoutChrome(ref, 's3');
    expect(s2.drawingNumber, 'E-101');
    expect(s2.sheetCounter, '1 of 2');
    expect(s3.drawingNumber, 'E-102');
    expect(s3.sheetCounter, '2 of 2');
    // A sheet with no electrical content yet takes its rail slot (n + 1).
    final s1 = electricalLayoutChrome(ref, 's1');
    expect(s1.drawingNumber, 'E-101');
    expect(s1.sheetCounter, '1 of 3');
  });
}
