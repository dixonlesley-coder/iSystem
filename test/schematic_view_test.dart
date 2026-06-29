/// Widget tests for SchematicView.
///
/// Harness: ProviderScope + MechXTheme + Directionality + MediaQuery
/// (no MaterialApp — the app uses WidgetsApp only).
///
/// Tests are intentionally light: they assert the widget builds without
/// throwing and renders the expected empty/non-empty states.  Pixel positions
/// are NOT asserted.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/ui/schematic/schematic_view.dart';
import 'package:mechx/ui/theme/mechx_theme.dart';
import 'package:mechx_engine/network/network.dart';

// ---------------------------------------------------------------------------
// Minimal notifier override — always returns the supplied network.
// ---------------------------------------------------------------------------

class _FixedNetworkController extends NetworkController {
  _FixedNetworkController(this._fixed);

  final Network _fixed;

  @override
  DrawingState build() => DrawingState(network: _fixed);
}

// ---------------------------------------------------------------------------
// A small two-floor demo network used by several tests.
// ---------------------------------------------------------------------------

const _demoNetwork = Network(
  nodes: [
    NetNode(id: 'n0', sheetId: 's1', x: 100, y: 200, floorIndex: 0),
    NetNode(id: 'n1', sheetId: 's1', x: 300, y: 200, floorIndex: 0),
    NetNode(id: 'n2', sheetId: 's1', x: 200, y: 200, floorIndex: 0),
    NetNode(id: 'n3', sheetId: 's1', x: 200, y: 100, floorIndex: 1),
  ],
  edges: [
    NetEdge(
      id: 'e0',
      fromId: 'n0',
      toId: 'n1',
      service: ServiceType.coldWater,
    ),
    NetEdge(
      id: 'e1',
      fromId: 'n2',
      toId: 'n3',
      service: ServiceType.coldWater,
      kind: EdgeKind.riser,
    ),
  ],
);

List<Override> _demoOverrides() => [
      networkControllerProvider.overrideWith(
        () => _FixedNetworkController(_demoNetwork),
      ),
    ];

// ---------------------------------------------------------------------------
// Test harness helper
// ---------------------------------------------------------------------------

/// Wraps [child] in the minimal tree required by [SchematicView]:
///   ProviderScope → MechXTheme → Directionality → MediaQuery → SizedBox
Widget _harness(Widget child, {List<Override> overrides = const []}) =>
    ProviderScope(
      overrides: overrides,
      child: MechXTheme(
        data: MechXThemeData.dark,
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: MediaQuery(
            data: const MediaQueryData(size: Size(800, 600)),
            child: SizedBox(width: 800, height: 600, child: child),
          ),
        ),
      ),
    );

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('SchematicView — empty network', () {
    testWidgets('builds without throwing and shows the empty-state text',
        (tester) async {
      await tester.pumpWidget(_harness(const SchematicView()));
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.text('No network drawn'), findsOneWidget);
    });
  });

  group('SchematicView — demo network', () {
    testWidgets('renders without throwing with a two-floor network',
        (tester) async {
      await tester.pumpWidget(
        _harness(const SchematicView(), overrides: _demoOverrides()),
      );
      await tester.pump();

      expect(tester.takeException(), isNull);
      // Empty-state placeholder must NOT appear when there are nodes.
      expect(find.text('No network drawn'), findsNothing);
    });

    testWidgets('a CustomPaint is present when the network is non-empty',
        (tester) async {
      await tester.pumpWidget(
        _harness(const SchematicView(), overrides: _demoOverrides()),
      );
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.byType(CustomPaint), findsWidgets);
    });

    testWidgets('Auto legend lists every service present in the demo network',
        (tester) async {
      await tester.pumpWidget(
        _harness(const SchematicView(), overrides: _demoOverrides()),
      );
      await tester.pump();

      expect(tester.takeException(), isNull);
      // 'Legend' appears twice: the toolbar toggle button + the legend card
      // header (the legend is ON by default).
      expect(find.text('Legend'), findsNWidgets(2));
      // Pipe tags are CustomPaint-only, so a found 'CW' Text widget proves the
      // legend (the only place 'CW' is a Flutter Text) rendered, and the full
      // serviceLabel row confirms the service is listed by name.
      expect(find.text('CW'), findsWidgets);
      // 'Cold water' appears in the toolbar service chip AND the legend row.
      expect(find.text('Cold water'), findsNWidgets(2));
    });
  });

  group('SchematicView — legend on empty network', () {
    testWidgets('legend overlay is unreachable for an empty network',
        (tester) async {
      await tester.pumpWidget(_harness(const SchematicView()));
      await tester.pump();

      expect(tester.takeException(), isNull);
      // The Auto view early-returns the empty-state text before the legend
      // Stack, so no legend service row renders.
      expect(find.text('No network drawn'), findsOneWidget);
      expect(find.text('Cold water'), findsNothing);
    });
  });
}
