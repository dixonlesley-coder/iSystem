import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/fixture_library_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/sizing_store.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/standards/custom_fixture.dart';
import 'package:mechx_engine/standards/sni.dart';

void main() {
  test('sizingProvider auto-sizes a drawn run', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final n = c.read(networkControllerProvider.notifier);
    n.setService(ServiceType.coldWater);
    n.setTool(DrawTool.drawRun);
    n.placeRunPoint('s1', 0, const Offset(0, 0));
    n.placeRunPoint('s1', 0, const Offset(1000, 0));

    final sizing = c.read(sizingProvider);
    expect(sizing, isNotEmpty);
    final s = sizing.values.first;
    expect(s.service, ServiceType.coldWater);
    expect(s.diameter.inMillimeters, greaterThan(0));
    expect(s.velocity.metersPerSecond, lessThanOrEqualTo(2.0));
  });

  test('empty network → empty sizing', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    expect(c.read(sizingProvider), isEmpty);
  });

  // Builds a single cold-water run s1/floor0 from (0,0) to (1000,0) and returns
  // the container + the id of the far (terminal) node.
  ({ProviderContainer c, String terminalId}) runWithTerminal() {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final n = c.read(networkControllerProvider.notifier);
    n.setService(ServiceType.coldWater);
    n.setTool(DrawTool.drawRun);
    n.placeRunPoint('s1', 0, const Offset(0, 0));
    n.placeRunPoint('s1', 0, const Offset(1000, 0));
    final net = c.read(networkControllerProvider).network;
    // The far node is the one at x == 1000.
    final terminal = net.nodes.firstWhere((nd) => nd.x == 1000);
    return (c: c, terminalId: terminal.id);
  }

  test('a custom fixture with lavatory-equal units sizes identically to a '
      'built-in lavatory', () {
    // A built-in lavatory at private occupancy carries UBAP 1.0 and DFU 1.0;
    // a custom fixture with the same units must yield the same diameter.
    const profile = SniProfile();
    expect(profile.fixtureUnitLoad(PlumbingFixture.lavatory), 1.0);

    final builtIn = runWithTerminal();
    builtIn.c
        .read(networkControllerProvider.notifier)
        .setNodeFixture(builtIn.terminalId, PlumbingFixture.lavatory);
    final builtInSizing = builtIn.c.read(sizingProvider).values.single;

    final custom = runWithTerminal();
    custom.c.read(fixtureLibraryProvider.notifier).add(const CustomFixture(
          id: 'cf-lav',
          name: 'Lav (custom)',
          supplyUnits: 1.0,
          drainageUnits: 1.0,
        ));
    custom.c
        .read(networkControllerProvider.notifier)
        .setNodeCustomFixture(custom.terminalId, 'cf-lav');
    final customSizing = custom.c.read(sizingProvider).values.single;

    expect(customSizing.diameter.meters, builtInSizing.diameter.meters);
    expect(customSizing.flow.cubicMetersPerSecond,
        builtInSizing.flow.cubicMetersPerSecond);
  });

  test('an unknown customFixtureId falls back to the no-fixture default '
      '(no throw)', () {
    // Reference: a terminal with NO fixture assigned at all.
    final plain = runWithTerminal();
    final plainSizing = plain.c.read(sizingProvider).values.single;

    // A node pointing at an id that is NOT in the (empty) library.
    final dangling = runWithTerminal();
    dangling.c
        .read(networkControllerProvider.notifier)
        .setNodeCustomFixture(dangling.terminalId, 'does-not-exist');
    final danglingSizing = dangling.c.read(sizingProvider).values.single;

    // Falls back to the same default flow/diameter as no fixture at all.
    expect(danglingSizing.diameter.meters, plainSizing.diameter.meters);
    expect(danglingSizing.flow.cubicMetersPerSecond,
        plainSizing.flow.cubicMetersPerSecond);
  });

  test('showSizing toggles', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    expect(c.read(showSizingProvider), isFalse);
    c.read(showSizingProvider.notifier).toggle();
    expect(c.read(showSizingProvider), isTrue);
  });
}
