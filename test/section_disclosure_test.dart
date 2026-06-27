import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/app.dart';
import 'package:mechx/store/inspector_store.dart';
import 'package:mechx/ui/inspector/disclosure_header.dart';
import 'package:mechx/ui/inspector/result_card.dart';
import 'package:mechx/ui/theme/mechx_theme.dart';

import 'test_util.dart';

/// Load the bundled Roboto faces so on-canvas text lays out (and a tofu check is
/// meaningful at the test surface).
Future<void> _loadFonts() async {
  Future<ByteData> bytes(String path) async =>
      ByteData.sublistView(await File(path).readAsBytes());
  final sans = FontLoader('Roboto')
    ..addFont(bytes('assets/fonts/Roboto-Regular.ttf'))
    ..addFont(bytes('assets/fonts/Roboto-Medium.ttf'));
  await sans.load();
  final mono = FontLoader('Roboto Mono')
    ..addFont(bytes('assets/fonts/RobotoMono-Regular.ttf'));
  await mono.load();
}

/// Pump a frame plus the disclosure rotation animation.
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  setUpAll(_loadFonts);

  testWidgets(
      'inspector sections render as collapsible disclosure headers with chevrons',
      (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();

    // The major sizing sections are now DisclosureSections (Draw, Sizing,
    // Network, Fire, HVAC always render; Tanks/Rooms only with content).
    expect(find.byType(DisclosureSection), findsWidgets);
    // Their uppercase labels are still present (the header replaces the old
    // MechXSectionLabel but keeps the same text).
    expect(find.text('DRAW'), findsOneWidget);
    expect(find.text('NETWORK'), findsOneWidget);
    expect(find.text('FIRE'), findsOneWidget);
  });

  testWidgets('a section starts expanded, collapses on tap, and re-expands',
      (tester) async {
    setDesktopSurface(tester);
    await tester.pumpWidget(const ProviderScope(child: MechXApp()));
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(MechXApp)),
      listen: false,
    );

    // The Fire section always renders and defaults expanded, so its detail
    // rows (e.g. "Sprinkler flow") are visible at rest.
    expect(find.text('Sprinkler flow'), findsOneWidget);
    expect(container.read(sectionVisibilityProvider)['Fire'], isNull);

    // The Fire header sits below the fold in the scrolling inspector; bring it
    // into view before tapping. Tapping it collapses the section: the detail
    // rows disappear, the label remains, and the toggle is recorded.
    final collapse = find.bySemanticsLabel('Collapse Fire section');
    await tester.ensureVisible(collapse);
    await tester.pump();
    await tester.tap(collapse);
    await _settle(tester);
    expect(container.read(sectionVisibilityProvider)['Fire'], isFalse);
    expect(find.text('Sprinkler flow'), findsNothing);
    // The header (label) survives the collapse.
    expect(find.text('FIRE'), findsOneWidget);

    // Tapping again re-expands and the detail rows return.
    final expand = find.bySemanticsLabel('Expand Fire section');
    await tester.ensureVisible(expand);
    await tester.pump();
    await tester.tap(expand);
    await _settle(tester);
    expect(container.read(sectionVisibilityProvider)['Fire'], isTrue);
    expect(find.text('Sprinkler flow'), findsOneWidget);
  });

  test('toggle() flips a section from its default seed', () {
    // The store toggles relative to the caller's default when never seen.
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final notifier = container.read(sectionVisibilityProvider.notifier);
    // Never-seen + default true ⇒ derived value is true.
    expect(
        container.read(sectionExpandedProvider(const SectionKey('X', true))),
        isTrue);
    // Toggling lands on the opposite of the default.
    notifier.toggle('X', true);
    expect(
        container.read(sectionExpandedProvider(const SectionKey('X', true))),
        isFalse);
    // A default-collapsed section seeds the other way.
    expect(
        container.read(sectionExpandedProvider(const SectionKey('Y', false))),
        isFalse);
    notifier.toggle('Y', false);
    expect(
        container.read(sectionExpandedProvider(const SectionKey('Y', false))),
        isTrue);
    // set() is explicit and overrides the seed.
    notifier.set('Y', false);
    expect(
        container.read(sectionExpandedProvider(const SectionKey('Y', false))),
        isFalse);
  });

  testWidgets('ResultCard renders the headline bold and colours its verdict',
      (tester) async {
    setDesktopSurface(tester, size: const Size(400, 300));
    const theme = MechXThemeData.light;
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: MechXTheme(
          data: theme,
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 260,
              child: ResultCard(
                headline: '2.50 kW',
                label: 'Pump motor',
                verdict: 'over',
                verdictColor: Color(0xFFFF3B30),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // Headline + label + verdict all render.
    final headline = tester.widget<Text>(find.text('2.50 kW'));
    expect(headline.style?.fontWeight, FontWeight.w700);
    expect(find.text('Pump motor'), findsOneWidget);

    // The verdict chip carries the danger colour passed in.
    final verdict = tester.widget<Text>(find.text('over'));
    expect(verdict.style?.color, const Color(0xFFFF3B30));
  });
}
