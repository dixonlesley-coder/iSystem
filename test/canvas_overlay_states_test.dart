/// Widget tests for the canvas-overlay decluttering batch (L-2a / L-3 / L-4):
///
///  - L-2a: the heatmap legend names its own basis ("residual at fixtures")
///    since the Results card beside it verdicts on zone STATIC instead.
///  - L-3: the "No plan attached" placeholder caption hides once the current
///    sheet actually carries drawn network elements (it was rendering half
///    hidden under pipework in goldens 01/06).
///  - L-4: the service-legend chip's row labels render at a legible size
///    (>= 9px, bumped from the dense `micro` chrome-label token).
///
/// Harness: ProviderScope + MechXTheme + Directionality + MediaQuery (no
/// MaterialApp — the app uses WidgetsApp only), matching the other canvas
/// widget-test files in this suite.
library;

import 'dart:io';

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/models/sheet.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/ui/canvas/heatmap_layer.dart';
import 'package:mechx/ui/canvas/sheet_canvas.dart';
import 'package:mechx/ui/layout/service_legend_chip.dart';
import 'package:mechx/ui/theme/mechx_theme.dart';
import 'package:mechx_engine/network/network.dart';

Future<void> _loadFonts() async {
  Future<ByteData> bytes(String path) async =>
      ByteData.sublistView(await File(path).readAsBytes());
  final sans = FontLoader('Roboto')
    ..addFont(bytes('assets/fonts/Roboto-Regular.ttf'))
    ..addFont(bytes('assets/fonts/Roboto-Medium.ttf'));
  await sans.load();
}

Widget _host(Widget child, {List<Override> overrides = const []}) =>
    ProviderScope(
      overrides: overrides,
      child: MechXTheme(
        data: MechXThemeData.dark,
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: MediaQuery(
            data: const MediaQueryData(size: Size(900, 700)),
            child: SizedBox(width: 900, height: 700, child: child),
          ),
        ),
      ),
    );

/// A network-controller override that always returns the supplied network —
/// the same minimal-fixture idiom used by `schematic_view_test.dart`.
class _FixedNetworkController extends NetworkController {
  _FixedNetworkController(this._fixed);
  final Network _fixed;

  @override
  DrawingState build() => DrawingState(network: _fixed);
}

const _sheet = Sheet(id: 's1', name: 'Sheet 1');

void main() {
  setUpAll(_loadFonts);

  group('L-2a — heatmap legend basis caption', () {
    testWidgets('shows the "residual at fixtures" basis caption', (tester) async {
      await tester.pumpWidget(_host(
        const HeatmapLegend(minKpa: 3.2, maxKpa: 400, targetKpa: 225),
      ));
      expect(find.text('Residual pressure'), findsOneWidget);
      expect(find.text('residual at fixtures'), findsOneWidget);
    });

    testWidgets('the caption still shows in the uniform-field state too',
        (tester) async {
      await tester.pumpWidget(_host(
        const HeatmapLegend(minKpa: 31, maxKpa: 31, targetKpa: 225),
      ));
      expect(find.text('residual at fixtures'), findsOneWidget);
    });
  });

  group('L-3 — placeholder caption hides once the sheet has drawn elements', () {
    testWidgets(
        'an empty sheet still shows "No plan attached" + the import hint',
        (tester) async {
      await tester.pumpWidget(_host(
        const PlaceholderSheetPage(sheet: _sheet),
        overrides: [
          networkControllerProvider.overrideWith(
            () => _FixedNetworkController(const Network()),
          ),
        ],
      ));
      expect(find.text('Sheet 1'), findsOneWidget);
      expect(find.textContaining('No plan attached'), findsOneWidget);
      expect(find.text('Import a PDF or DXF floor plan to draw to scale'),
          findsOneWidget);
    });

    testWidgets(
        'a sheet with a drawn node hides the caption but keeps the title',
        (tester) async {
      final net = Network(nodes: [
        NetNode(id: 'n0', sheetId: _sheet.id, x: 10, y: 10, floorIndex: 0),
      ]);
      await tester.pumpWidget(_host(
        const PlaceholderSheetPage(sheet: _sheet),
        overrides: [
          networkControllerProvider.overrideWith(
            () => _FixedNetworkController(net),
          ),
        ],
      ));
      expect(find.text('Sheet 1'), findsOneWidget);
      expect(find.textContaining('No plan attached'), findsNothing);
      expect(find.text('Import a PDF or DXF floor plan to draw to scale'),
          findsNothing);
    });

    testWidgets('a node drawn on a DIFFERENT sheet does not hide the caption',
        (tester) async {
      final net = Network(nodes: [
        NetNode(id: 'n0', sheetId: 'other-sheet', x: 10, y: 10, floorIndex: 0),
      ]);
      await tester.pumpWidget(_host(
        const PlaceholderSheetPage(sheet: _sheet),
        overrides: [
          networkControllerProvider.overrideWith(
            () => _FixedNetworkController(net),
          ),
        ],
      ));
      expect(find.textContaining('No plan attached'), findsOneWidget);
    });
  });

  group('L-4 — service legend chip row-label legibility', () {
    testWidgets('row labels render at >= 9px, the chip stays compact',
        (tester) async {
      await tester.pumpWidget(_host(const ServiceLegendChip()));
      await tester.pump();

      final labelFinder = find.text('Cold water');
      expect(labelFinder, findsOneWidget,
          reason: 'the default active layer (plumbing) is expanded by default');
      final paragraph = tester.renderObject<RenderParagraph>(labelFinder);
      expect(paragraph.text.style!.fontSize, greaterThanOrEqualTo(9));

      // The chip's row column stays within its unchanged compact max width.
      final constrainedBox = tester.widget<ConstrainedBox>(
          find.byType(ConstrainedBox).first);
      expect(constrainedBox.constraints.maxWidth, 176);
    });
  });
}
