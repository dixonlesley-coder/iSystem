import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/fire_store.dart';
import 'package:mechx_engine/sizing/fire_pump_rating.dart';
import 'package:mechx_engine/sizing/fire_sprinkler.dart';

void main() {
  test('sprinkler + standpipe designs derive sane values', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);

    final sprinkler = c.read(sprinklerDesignProvider);
    expect(sprinkler.requiredFlow.inLitersPerSecond, greaterThan(0));
    expect(sprinkler.sprinklerCount, greaterThan(0));

    final standpipe = c.read(standpipeDesignProvider);
    // single riser → 550 gpm (SNI 03-1745-2000) = 550 × 3.785411784 / 60 L/s
    expect(
      standpipe.requiredFlow.inLitersPerSecond,
      closeTo(550.0 * 3.785411784 / 60.0, 1e-6),
    );
    expect(standpipe.pumpHead.meters, greaterThan(0));
  });

  test('raising the hazard class increases sprinkler demand', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final before = c.read(sprinklerDesignProvider).requiredFlow.inLitersPerSecond;
    c.read(fireHazardProvider.notifier).set(FireHazardClass.extraHazard);
    final after = c.read(sprinklerDesignProvider).requiredFlow.inLitersPerSecond;
    expect(after, greaterThan(before));
  });

  test('remote-area + fire-pump rating providers derive from the designs', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);

    // OH1 default → per-head 60 L/min, K = 80 → P = (60/80)² = 0.5625 bar ≥ 0.5.
    final remote = c.read(sprinklerRemoteAreaProvider);
    expect(remote.kFactor, 80.0);
    expect(remote.remoteHeadPressure.inBar, closeTo(0.5625, 1e-9));
    expect(remote.meetsMinimumPressure, isTrue);

    // Rating curve built off the standpipe pump duty (rated flow + head).
    final standpipe = c.read(standpipeDesignProvider);
    final rating = c.read(firePumpRatingProvider);
    expect(
      rating.ratedFlow.cubicMetersPerSecond,
      closeTo(standpipe.requiredFlow.cubicMetersPerSecond, 1e-12),
    );
    expect(rating.churn.head.meters,
        closeTo(standpipe.pumpHead.meters * 1.40, 1e-9));
    expect(rating.overload.head.meters,
        closeTo(standpipe.pumpHead.meters * 0.65, 1e-9));
    expect(rating.designation, PumpDesignation.duty);
    expect(rating.standbyRecommended, isTrue);
  });

  test('lowering the K-factor raises required remote-head pressure', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final pHigh = c.read(sprinklerRemoteAreaProvider).remoteHeadPressure.inBar;
    c.read(firePerHeadKFactorProvider.notifier).set(40);
    final pLow = c.read(sprinklerRemoteAreaProvider).remoteHeadPressure.inBar;
    // P ∝ 1/K²; halving K quadruples P.
    expect(pLow, closeTo(pHigh * 4.0, 1e-9));
  });
}
