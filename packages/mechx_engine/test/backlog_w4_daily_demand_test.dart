// Backlog W-4 (2026-11-14) — the daily water demand (population x litres per
// person per day) and the domestic water reserve in days (stored / daily
// demand). Informational: the owner's decision is that the fill rate is
// outside the designer's control, so nothing is judged. Hand arithmetic in
// comments.
import 'package:mechx_engine/sizing/tank_fill.dart';
import 'package:mechx_engine/standards/sni.dart';
import 'package:test/test.dart';

ReserveTank _t(String id, double? l, {double fire = 0, bool roof = false}) =>
    (tankId: id, roof: roof, capacityLitres: l, fireReserveLitres: fire);

void main() {
  test('the per-person table by occupancy, one verify entry', () {
    expect(dailyDemandPerPersonDefault(Occupancy.private), 120);
    expect(dailyDemandPerPersonDefault(Occupancy.public), 50);
    expect(dailyDemandPerPersonDefault(Occupancy.assembly), 10);
    final v = const SniProfile().dailyDemandPerPersonTable;
    expect(const SniProfile().verifyChecklist, contains(v));
    expect(v.isUnverified, isTrue);
  });

  test('daily demand = population x L/person/day; unknown ⇒ null', () {
    // 96 persons x 120 L = 11 520 L/day.
    expect(dailyDemandLitres(96, 120), 11520);
    expect(dailyDemandLitres(null, 120), isNull);
    expect(dailyDemandLitres(0, 120), isNull);
  });

  test('reserve = Σ domestic storage / daily demand', () {
    // 20 000 + 10 000 = 30 000 L over 11 520 L/day = 2.6042 days.
    final r = WaterReserve(
        tanks: [_t('GT', 20000), _t('RT', 10000, roof: true)],
        dailyLitres: 11520);
    expect(r.storedLitres, 30000);
    expect(r.days, closeTo(2.604167, 5e-7));
    expect(formatReserveDays(r.days!), '2.6 days');
    // Sub-day: 90 000 / 150 000 = 0.6 days = 14.4 h.
    expect(formatReserveDays(0.6), '0.6 days (14 h)');
  });

  test('a tank with no capacity is excluded and named; none ⇒ no figure', () {
    final r = WaterReserve(
        tanks: [_t('GT', null), _t('RT', 2000, roof: true)],
        dailyLitres: 1800);
    expect(r.excludedTankIds, ['GT']);
    // 2000 / 1800 = 1.1111 days.
    expect(r.days, closeTo(1.111111, 5e-7));
    final none = WaterReserve(tanks: [_t('GT', null)], dailyLitres: 1800);
    expect(none.storedLitres, isNull);
    expect(none.days, isNull);
  });

  test('no population ⇒ no figure (never 0)', () {
    final r = WaterReserve(tanks: [_t('GT', 20000)], dailyLitres: null);
    expect(r.storedLitres, 20000);
    expect(r.days, isNull);
  });

  test('a shared domestic + fire tank counts capacity less the fire reserve',
      () {
    // 100 000 L holding a 56 781 L fire reserve: 43 219 L domestic; over
    // 10 000 L/day = 4.3219 days.
    final r = WaterReserve(
        tanks: [_t('T', 100000, fire: 56781)], dailyLitres: 10000);
    expect(r.storedLitres, 43219);
    expect(r.days, closeTo(4.3219, 1e-9));
  });
}
