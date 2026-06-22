import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/fire_store.dart';
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
}
