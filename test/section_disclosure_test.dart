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

    // The major sections are now DisclosureSections (Draw, Design inputs,
    // Results, Fire, HVAC always render as headers; Tanks/Rooms only with
    // content). Their uppercase labels survive whether the section is expanded
    // (content-bearing) or collapsed (data-gated empty) — the header replaces
    // the old MechXSectionLabel but keeps the same text.
    expect(find.byType(DisclosureSection), findsWidgets);
    expect(find.text('DRAW'), findsOneWidget);
    // E5: the plumbing-results section is 'Results' (was 'Network').
    expect(find.text('RESULTS'), findsOneWidget);
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

    // The Draw section always renders and defaults expanded (it is not
    // data-gated the way Fire/HVAC now are), so its detail (e.g. the "Ortho"
    // toggle) is visible at rest.
    expect(find.text('Ortho'), findsOneWidget);
    expect(container.read(sectionVisibilityProvider)['Draw'], isNull);

    // Tapping the Draw header collapses the section: the detail disappears, the
    // label remains, and the toggle is recorded.
    final collapse = find.bySemanticsLabel('Collapse Draw section');
    await tester.ensureVisible(collapse);
    await tester.pump();
    await tester.tap(collapse);
    await _settle(tester);
    expect(container.read(sectionVisibilityProvider)['Draw'], isFalse);
    expect(find.text('Ortho'), findsNothing);
    // The header (label) survives the collapse.
    expect(find.text('DRAW'), findsOneWidget);

    // Tapping again re-expands and the detail returns.
    final expand = find.bySemanticsLabel('Expand Draw section');
    await tester.ensureVisible(expand);
    await tester.pump();
    await tester.tap(expand);
    await _settle(tester);
    expect(container.read(sectionVisibilityProvider)['Draw'], isTrue);
    expect(find.text('Ortho'), findsOneWidget);
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
