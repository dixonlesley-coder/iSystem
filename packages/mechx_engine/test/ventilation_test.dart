/// Tests for the air-side ventilation (ACH) standards profile.
library;

import 'package:mechx_engine/sizing/grille_sizing.dart';
import 'package:mechx_engine/standards/sni.dart';
import 'package:mechx_engine/standards/ventilation.dart';
import 'package:test/test.dart';

void main() {
  const profile = SniVentilationProfile();

  group('recommendedAch', () {
    test('office is 6 ACH', () {
      expect(profile.recommendedAch(RoomType.office).value, closeTo(6.0, 1e-9));
    });

    test('commercial kitchen demands more air than an office', () {
      expect(
        profile.recommendedAch(RoomType.commercialKitchen).value,
        greaterThan(profile.recommendedAch(RoomType.office).value),
      );
    });

    test('every room type has a positive ACH', () {
      for (final t in RoomType.values) {
        expect(profile.recommendedAch(t).value, greaterThan(0.0),
            reason: '${roomTypeLabel(t)} must have positive ACH');
      }
    });

    test('all ACH values are surfaced as UNVERIFIED (secondarySource)', () {
      // Provenance honesty (§12.6): nothing is sniVerbatim until the official
      // SNI 03-6572-2001 PDF is checked.
      for (final t in RoomType.values) {
        final v = profile.recommendedAch(t);
        expect(v.verified, isFalse);
        expect(v.status, VerificationStatus.secondarySource);
        expect(v.isUnverified, isTrue);
      }
    });

    test('note is human-readable and carries the value', () {
      final v = profile.recommendedAch(RoomType.office);
      expect(v.note, isNotNull);
      expect(v.note, contains('Office'));
    });
  });

  group('coolingLoadDensityBtuPerHrM2', () {
    test('office is 600 BTU/h per m²', () {
      expect(profile.coolingLoadDensityBtuPerHrM2(RoomType.office).value,
          closeTo(600.0, 1e-9));
    });

    test('a server room demands more cooling per m² than an office', () {
      expect(
        profile.coolingLoadDensityBtuPerHrM2(RoomType.serverRoom).value,
        greaterThan(profile.coolingLoadDensityBtuPerHrM2(RoomType.office).value),
      );
    });

    test('every room type has a positive density, all UNVERIFIED', () {
      for (final t in RoomType.values) {
        final v = profile.coolingLoadDensityBtuPerHrM2(t);
        expect(v.value, greaterThan(0.0));
        expect(v.status, VerificationStatus.secondarySource);
        expect(v.verified, isFalse);
      }
    });
  });

  group('grilleApplicationFor', () {
    test('bedroom maps to the quietest (bedroom) face class', () {
      expect(profile.grilleApplicationFor(RoomType.bedroom),
          GrilleApplication.bedroom);
    });

    test('office maps to the office face class', () {
      expect(profile.grilleApplicationFor(RoomType.office),
          GrilleApplication.office);
    });

    test('server room maps to the least-sensitive (industrial) face class', () {
      expect(profile.grilleApplicationFor(RoomType.serverRoom),
          GrilleApplication.industrial);
    });

    test('every room type maps to some face class', () {
      for (final t in RoomType.values) {
        expect(() => profile.grilleApplicationFor(t), returnsNormally);
      }
    });
  });

  group('roomTypeLabel', () {
    test('covers every enum value with a non-empty label', () {
      for (final t in RoomType.values) {
        expect(roomTypeLabel(t), isNotEmpty);
      }
    });

    test('commercialKitchen label is human-readable', () {
      expect(roomTypeLabel(RoomType.commercialKitchen), 'Commercial kitchen');
    });
  });

  group('verifyChecklist', () {
    test('is non-empty and every entry is unverified', () {
      expect(profile.verifyChecklist, isNotEmpty);
      for (final v in profile.verifyChecklist) {
        expect(v.isUnverified, isTrue);
      }
    });
  });
}
