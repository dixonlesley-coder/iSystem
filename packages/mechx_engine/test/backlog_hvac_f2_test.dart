// Backlog F-2 (2026-11-13) — ONE face-velocity limit per terminal kind and
// application, read by both the room's bank sizing and the checker.
//
// The room's own return bank was counted at min(application, 4.0) while the
// checker accepted every return grille at 4.0, so the app recommended five
// grilles for the tower office and its checker passed four. The governing
// value is now `terminalFaceVelocityMax(kind, application)` = the
// application's table value capped by the kind's band (supply 3.0, return /
// exhaust 4.0 m/s) for both readers.
import 'package:mechx_engine/sizing/air_velocity.dart';
import 'package:mechx_engine/sizing/grille_sizing.dart';
import 'package:mechx_engine/sizing/room_air.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

void main() {
  group('backlog F-2 — one face-velocity limit per kind and application', () {
    test('the governing limit = min(application, kind cap)', () {
      double lim(AirTerminalKind k, GrilleApplication? a) =>
          terminalFaceVelocityMax(k, a).metersPerSecond;
      const s = AirTerminalKind.supply, r = AirTerminalKind.returnOrExhaust;
      expect(lim(s, GrilleApplication.bedroom), 2.0);
      expect(lim(r, GrilleApplication.bedroom), 2.0);
      expect(lim(s, GrilleApplication.office), 3.0);
      expect(lim(r, GrilleApplication.office), 3.0); // min(3.0, 4.0)
      expect(lim(s, GrilleApplication.retail), 3.0); // min(3.5, 3.0)
      expect(lim(r, GrilleApplication.retail), 3.5); // min(3.5, 4.0)
      expect(lim(s, GrilleApplication.industrial), 3.0);
      expect(lim(r, GrilleApplication.industrial), 4.0); // min(5.0, 4.0)
      // No room ⇒ the kind's band alone.
      expect(lim(s, null), kSupplyFaceVelocityMax.metersPerSecond);
      expect(lim(r, null), kReturnFaceVelocityMax.metersPerSecond);
    });

    test('the checker judges an office return grille at 3.0, not 4.0', () {
      // 0.925 m³/s through one 600 x 600 (0.36 x 0.8 free) = 3.21 m/s.
      const v = Velocity(0.925 / (0.36 * 0.8));
      expect(
          checkTerminalFaceVelocity(v, AirTerminalKind.returnOrExhaust,
                  application: GrilleApplication.office)
              .verdict,
          VelocityBandVerdict.tooHigh);
      // In no room (or an industrial one) the 4.0 band still passes it.
      expect(
          checkTerminalFaceVelocity(v, AirTerminalKind.returnOrExhaust)
              .verdict,
          VelocityBandVerdict.ok);
      expect(
          checkTerminalFaceVelocity(v, AirTerminalKind.returnOrExhaust,
                  application: GrilleApplication.industrial)
              .verdict,
          VelocityBandVerdict.ok);
      // openMin: the smallest-face case keeps an open lower bound.
      expect(
          checkTerminalFaceVelocity(const Velocity(0.5), AirTerminalKind.supply,
                  openMin: true)
              .verdict,
          VelocityBandVerdict.ok);
      expect(
          checkTerminalFaceVelocity(const Velocity(0.5), AirTerminalKind.supply)
              .verdict,
          VelocityBandVerdict.tooLow);
    });

    RoomAirResult office(double areaM2) => sizeRoomAir(
          floorArea: Area(areaM2),
          ceilingHeight: const Length(3.7),
          airChangesPerHour: 6.0,
          equipmentKind: AirEquipmentKind.ahu,
          grilleApplication: GrilleApplication.office,
        );

    test('tower office: 3.7 m³/s return → 5 grilles (the checker agrees)', () {
      final r = office(600.0); // 600 x 3.7 x 6 / 3600 = 3.7 m³/s
      expect(r.airflow.cubicMetersPerSecond, closeTo(3.7, 1e-12));
      // ceil(3.7 / (0.36 x 0.8 x 3.0)) = ceil(3.7 / 0.864) = ceil(4.282) = 5.
      expect(r.return_.count, 5);
      // 740 L/s each on 600 x 600 = 2.569 m/s: the checker passes it ...
      final v = r.return_.each.faceVelocity;
      expect(v.metersPerSecond, closeTo(0.74 / 0.288, 1e-9));
      expect(
          checkTerminalFaceVelocity(v, AirTerminalKind.returnOrExhaust,
                  application: GrilleApplication.office)
              .isWarning,
          isFalse);
      // ... and four (925 L/s each = 3.212 m/s) it no longer does.
      expect(
          checkTerminalFaceVelocity(const Velocity(0.925 / 0.288),
                  AirTerminalKind.returnOrExhaust,
                  application: GrilleApplication.office)
              .verdict,
          VelocityBandVerdict.tooHigh);
    });

    test('reference office: 0.925 m³/s return → 2 grilles', () {
      final r = office(150.0); // 150 x 3.7 x 6 / 3600 = 0.925 m³/s
      // ceil(0.925 / 0.864) = ceil(1.0706) = 2; 462.5 L/s each, 1.606 m/s.
      expect(r.return_.count, 2);
      expect(r.return_.each.faceVelocity.metersPerSecond,
          closeTo(0.4625 / 0.288, 1e-9));
    });

    test('every application: the bank never fails the checker, and one '
        'terminal fewer always would', () {
      for (final app in GrilleApplication.values) {
        for (final q in [0.5, 1.3, 2.2, 3.7, 6.1]) {
          final r = sizeRoomAir(
            floorArea: Area(q * 3600 / (3.0 * 6.0)),
            ceilingHeight: const Length(3.0),
            airChangesPerHour: 6.0,
            grilleApplication: app,
          );
          for (final (bank, kind) in [
            (r.supply, AirTerminalKind.supply),
            (r.return_, AirTerminalKind.returnOrExhaust),
          ]) {
            final limit = terminalFaceVelocityMax(kind, app);
            expect(
                checkTerminalFaceVelocity(bank.each.faceVelocity, kind,
                        application: app, openMin: true)
                    .isWarning,
                isFalse,
                reason: '${app.name} $q ${kind.name}');
            if (bank.count > 1) {
              final fewer =
                  r.airflow.cubicMetersPerSecond / (bank.count - 1);
              // Even the largest standard face (0.36 m²) is over the limit.
              expect(fewer / (0.36 * 0.8),
                  greaterThan(limit.metersPerSecond),
                  reason: '${app.name} $q ${kind.name}');
            }
          }
        }
      }
    });
  });
}
