// Fix round 6 (third drawing review, 2026-11-20) — app-level pins.
//
// T2: the tower's pump-set detail names its STANDBY transfer pump TPS
// (P-02, 8.3 L/s @ 128.8 m, 18.5 kW) 'TRANSFER PUMP' — the same rule M-601
// uses for 'Transfer pump (standby)' (a standby pump whose duty pump is a
// transfer pump) — never 'BOOSTER PUMP'. The booster set P-05 stays one.
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/electrical_feed.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/solve_store.dart';
import 'package:mechx_engine/report/mechanical_sld_drawing.dart'
    show plantMoverCaptions;

import '../packages/mechx_engine/test/reference/tower.dart';
import 'reference_drawing_loader.dart';

Future<ProviderContainer> _load(WidgetTester tester, String key) async {
  final spec = kRefDrawingSpecs.firstWhere((s) => s.key == key);
  final c = ProviderContainer();
  addTearDown(c.dispose);
  await tester.runAsync(() => loadRefDrawingSpec(c, spec));
  await tester.pumpWidget(UncontrolledProviderScope(
    container: c,
    child: const Directionality(
        textDirection: TextDirection.ltr, child: SizedBox.shrink()),
  ));
  await tester.pump();
  return c;
}

void main() {
  testWidgets('tower: T2 standby transfer pump captioned TRANSFER PUMP',
      (tester) async {
    final c = await _load(tester, 'tower');
    // The solve classifies only the duty pump as a transfer mover; the
    // schedule's rule adds its standby.
    expect(c.read(transferPumpNodeIdsProvider), contains(kTowerTransferPump));
    expect(c.read(transferPumpNodeIdsProvider),
        isNot(contains(kTowerStandbyTransferPump)));
    final ids = c.read(scheduledTransferPumpNodeIdsProvider);
    expect(ids, containsAll([kTowerTransferPump, kTowerStandbyTransferPump]));
    final caps = plantMoverCaptions(c.read(sizingNetworkProvider),
        detailByNodeId: {
          for (final e in c.read(issuedRiserEquipmentDetailsProvider).entries)
            e.key: e.value,
        },
        transferPumpNodeIds: ids);
    expect(caps.where((t) => t.startsWith('TRANSFER PUMP')), hasLength(2));
    expect(caps.where((t) => t.startsWith('BOOSTER PUMP')), hasLength(1));
    expect(caps.where((t) => t.contains('Q 8.3 L/s')).every(
        (t) => t.startsWith('TRANSFER PUMP')), isTrue);
  });
}
