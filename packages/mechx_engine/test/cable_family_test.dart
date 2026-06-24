import 'package:mechx_engine/electrical/cable_family.dart';
import 'package:mechx_engine/electrical/results.dart';
import 'package:mechx_engine/electrical/sizing.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

/// A circuit's cable family (the Supreme NYY/NYM/NYA/NYAF/FRC types) drives the
/// insulation temperature-class used in the KHA (ampacity) lookup. Expected
/// values are hand-derived from the PUIL/Supreme in-conduit (B1) tables.
void main() {
  const p = PuilProfile();

  group('insulationForCableType', () {
    test('FRC → XLPE (90 °C class), even on a PVC-default panel', () {
      expect(insulationForCableType('FRC', fallback: ConductorInsulation.pvc),
          ConductorInsulation.xlpe);
    });

    test('NYY/NYM/NYA/NYAF → PVC (70 °C), overriding an XLPE panel default', () {
      for (final t in ['NYY', 'NYM', 'NYA', 'NYAF']) {
        expect(insulationForCableType(t, fallback: ConductorInsulation.xlpe),
            ConductorInsulation.pvc,
            reason: t);
      }
    });

    test('null cableType → the panel fallback (byte-identical to before)', () {
      expect(insulationForCableType(null, fallback: ConductorInsulation.xlpe),
          ConductorInsulation.xlpe);
      expect(insulationForCableType(null, fallback: ConductorInsulation.pvc),
          ConductorInsulation.pvc);
    });

    test('an unknown family falls back (no throw)', () {
      expect(insulationForCableType('XYZ', fallback: ConductorInsulation.pvc),
          ConductorInsulation.pvc);
    });
  });

  group('the family changes the sized section via its KHA table', () {
    // In-conduit (ref. method B1): PVC 16 mm² = 80 A, 25 mm² = 105 A;
    // XLPE 16 mm² = 88 A. A run whose Iz must reach ≥ 85 A (here In = 85 A,
    // 1.25·Ib = 12.5 A → Iz_req = 85 A) forces PVC up to 25 mm², while the
    // 90 °C XLPE class fits 16 mm².
    CableResult size(ConductorInsulation ins) => sizeCable(
          p,
          designCurrent: const Current(10),
          breakerRating: const Current(85),
          deratingFactor: 1.0,
          minSectionMm2: 1.5,
          insulation: ins,
          method: CableInstallMethod.conduit,
        );

    test('NYY (PVC, 70 °C) needs 25 mm² for an 85 A duty', () {
      final r =
          size(insulationForCableType('NYY', fallback: ConductorInsulation.pvc));
      expect(r.csaMm2, 25);
      expect(r.baseKha.amperes, 105);
    });

    test('FRC (XLPE, 90 °C) fits 16 mm² for the same duty', () {
      final r =
          size(insulationForCableType('FRC', fallback: ConductorInsulation.pvc));
      expect(r.csaMm2, 16);
      expect(r.baseKha.amperes, 88);
    });
  });
}
