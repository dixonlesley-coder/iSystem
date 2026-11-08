/// The Loads palette shows ONE card per phase-variable load kind; a sticky
/// 1ph/3ph segment picks the phase. `resolvePaletteLoad` is the single
/// resolver both the drag payload and the keyboard path use — this pins every
/// (kind, phase) row to the values the former paired cards carried, and that
/// fixed cards ignore the segment.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/ui/electrical/electrical_palette.dart';
import 'package:mechx_engine/electrical/load_kind.dart';

void main() {
  group('resolvePaletteLoad', () {
    // (kind, phase) -> (loadW, motorKw), the former (1φ)/(3φ) card values.
    const expected = <(LoadKind, int), (double, double?)>{
      (LoadKind.hvac, 1): (2500, null),
      (LoadKind.hvac, 3): (5500, null),
      (LoadKind.heating, 1): (3000, null),
      (LoadKind.heating, 3): (9000, null),
      (LoadKind.evCharger, 1): (7400, null),
      (LoadKind.evCharger, 3): (22000, null),
      (LoadKind.general, 1): (2000, null),
      (LoadKind.general, 3): (7500, null),
      (LoadKind.pump, 1): (0, 0.75),
      (LoadKind.pump, 3): (0, 4),
    };

    test('every phase-variable (kind, phase) row resolves verbatim', () {
      expect(kPalettePhaseDefaults.keys.toSet(), expected.keys.toSet());
      for (final e in expected.entries) {
        final (kind, phase) = e.key;
        final r = resolvePaletteLoad(PaletteLoad(kind), phase,
            phaseVariable: true);
        expect(r.kind, kind);
        expect(r.phases, phase, reason: '$kind @ $phase');
        expect(r.loadW, e.value.$1, reason: '$kind @ $phase');
        expect(r.motorKw, e.value.$2, reason: '$kind @ $phase');
      }
    });

    test('the palette has exactly one phase-variable card per table kind', () {
      final variable = [
        for (final (load, v) in debugPaletteCards)
          if (v) load.kind,
      ];
      expect(variable.toSet(),
          {LoadKind.hvac, LoadKind.heating, LoadKind.evCharger,
           LoadKind.general, LoadKind.pump});
      expect(variable.length, 5, reason: 'no duplicated kind cards');
      expect(debugPaletteCards.length, 19);
    });

    test('fixed cards ignore the segment phase', () {
      for (final (load, v) in debugPaletteCards) {
        if (v) continue;
        for (final phase in const [1, 3]) {
          expect(identical(resolvePaletteLoad(load, phase), load), isTrue,
              reason: '${load.kind} must not follow the segment');
        }
      }
      // The fixed three-phase cards keep phases: 3; the fire pump stays
      // engine-inferred (null).
      final fixed3 = [
        for (final (l, v) in debugPaletteCards)
          if (!v && l.phases == 3) l.kind,
      ];
      expect(fixed3.toSet(),
          {LoadKind.socket, LoadKind.welding, LoadKind.capacitor});
      expect(
        debugPaletteCards.any((c) =>
            !c.$2 && c.$1.kind == LoadKind.pump && c.$1.motorKw == 15 &&
            c.$1.phases == null),
        isTrue,
      );
    });
  });

  test('palettePhaseProvider defaults to 1 and is sticky', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    expect(c.read(palettePhaseProvider), 1);
    c.read(palettePhaseProvider.notifier).set(3);
    expect(c.read(palettePhaseProvider), 3);
    c.read(palettePhaseProvider.notifier).set(7);
    expect(c.read(palettePhaseProvider), 1);
  });
}
