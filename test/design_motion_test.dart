import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/ui/inspector/disclosure_header.dart';
import 'package:mechx/ui/theme/design_tokens.dart';
import 'package:mechx/ui/theme/mechx_theme.dart';

/// Wave-1 foundation of the design-craft campaign: the reduced-motion gate
/// (C1), the tabular-figure helper (C2), and the eased disclosure body (C3).
/// These two statics are a FROZEN contract the page waves consume, so their
/// behaviour is pinned here rather than left to each adopter.
void main() {
  group('C1 — MechXMotion.resolve (reduced-motion gate)', () {
    testWidgets('returns the base duration under a normal MediaQuery',
        (tester) async {
      late Duration resolved;
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(),
          child: Builder(
            builder: (context) {
              resolved = MechXMotion.resolve(context, MechXMotion.appear);
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      expect(resolved, MechXMotion.appear);
    });

    testWidgets('collapses to zero when the OS asks for reduced motion',
        (tester) async {
      final resolved = <Duration>[];
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Builder(
            builder: (context) {
              resolved
                ..add(MechXMotion.resolve(context, MechXMotion.appear))
                ..add(MechXMotion.resolve(context, MechXMotion.fast))
                ..add(MechXMotion.resolve(context, MechXMotion.dismiss));
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      expect(resolved, everyElement(Duration.zero));
    });

    testWidgets('falls back to the base duration with NO MediaQuery ancestor',
        (tester) async {
      // The `maybe` lookup matters: bare widget/painter harnesses pump without
      // a MediaQuery, and a throwing gate would take the whole app down.
      late Duration resolved;
      await tester.pumpWidget(
        Builder(
          builder: (context) {
            resolved = MechXMotion.resolve(context, MechXMotion.fast);
            return const SizedBox.shrink();
          },
        ),
      );
      expect(resolved, MechXMotion.fast);
    });
  });

  group('C2 — MechXTypography.tabular', () {
    test('adds tabular figures and preserves the rest of the style', () {
      const base = MechXTypography.standard;
      final tabular = MechXTypography.tabular(base.body);

      expect(tabular.fontFeatures, contains(const FontFeature.tabularFigures()));
      // Everything else about the style survives — it is the same type ramp,
      // just with fixed-advance digits.
      expect(tabular.fontFamily, base.body.fontFamily);
      expect(tabular.fontSize, base.body.fontSize);
      expect(tabular.fontWeight, base.body.fontWeight);
      expect(tabular.letterSpacing, base.body.letterSpacing);
      // The source style is untouched (copyWith, not a mutation).
      expect(base.body.fontFeatures, isNull);
    });

    test('applies to a caller-modified style too (colour already applied)', () {
      final coloured = MechXTypography.standard.caption
          .copyWith(color: const Color(0xFF123456));
      final tabular = MechXTypography.tabular(coloured);
      expect(tabular.color, const Color(0xFF123456));
      expect(tabular.fontFeatures, contains(const FontFeature.tabularFigures()));
    });
  });

  group('C3 — DisclosureSection still discloses (AnimatedSize regression)', () {
    Widget host({bool defaultExpanded = true}) => ProviderScope(
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: MechXTheme(
              data: MechXThemeData.light,
              child: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 280,
                  child: DisclosureSection(
                    name: 'Motion',
                    defaultExpanded: defaultExpanded,
                    child: const Text('BODY', textDirection: TextDirection.ltr),
                  ),
                ),
              ),
            ),
          ),
        );

    testWidgets('expands, collapses on tap, and re-expands', (tester) async {
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();

      // Header label + body both render at rest.
      expect(find.text('MOTION'), findsOneWidget);
      expect(find.text('BODY'), findsOneWidget);

      // Collapse: the body goes, the header stays.
      await tester.tap(find.text('MOTION'));
      await tester.pumpAndSettle();
      expect(find.text('BODY'), findsNothing);
      expect(find.text('MOTION'), findsOneWidget);

      // Re-expand: the body returns.
      await tester.tap(find.text('MOTION'));
      await tester.pumpAndSettle();
      expect(find.text('BODY'), findsOneWidget);
    });

    testWidgets('a default-collapsed section starts closed and opens on tap',
        (tester) async {
      await tester.pumpWidget(host(defaultExpanded: false));
      await tester.pumpAndSettle();
      expect(find.text('BODY'), findsNothing);

      await tester.tap(find.text('MOTION'));
      await tester.pumpAndSettle();
      expect(find.text('BODY'), findsOneWidget);
    });

    testWidgets('discloses instantly under reduced motion', (tester) async {
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: host(),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('BODY'), findsOneWidget);

      await tester.tap(find.text('MOTION'));
      // A single frame is enough: the gate zeroed every duration, so there is
      // nothing left to settle.
      await tester.pump();
      expect(find.text('BODY'), findsNothing);
      // No pending animation frames remain.
      expect(tester.hasRunningAnimations, isFalse);
    });
  });
}
