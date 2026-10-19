// Round 26 (riser-drafting-3-1) — the live riser flow arrows point the way
// the SOLVED flow runs: the triangle's apex is the tip (the base used to sit on
// the wrong side, so every arrow pointed backwards) and the direction reads
// `EdgeSizing.flowFromId` (the issued sheet's chevron basis), the drawing
// direction only when unsized.
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/ui/schematic/schematic_view.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/units.dart';

void main() {
  group('riserArrowPath: the apex is the tip', () {
    const tip = Offset(100, 50);
    test('an UP arrow has its base BELOW the tip (screen y grows down)', () {
      final b = riserArrowPath(tip, pointUp: true).getBounds();
      // Apex at y 50, base at y 50 + 6 = 56: the shape spans [50, 56].
      expect(b.top, closeTo(50, 1e-9));
      expect(b.bottom, closeTo(56, 1e-9));
    });
    test('a DOWN arrow has its base ABOVE the tip', () {
      final b = riserArrowPath(tip, pointUp: false).getBounds();
      expect(b.top, closeTo(44, 1e-9));
      expect(b.bottom, closeTo(50, 1e-9));
    });
  });

  group('riserFlowGoesUp follows the solved flow', () {
    // ds3 on L3 (screen y 100) drawn DOWN to ds2 on L2 (screen y 300).
    const edge = NetEdge(
        id: 'dsr3',
        fromId: 'ds3',
        toId: 'ds2',
        service: ServiceType.drainage,
        kind: EdgeKind.riser);
    const upper = Offset(200, 100);
    const lower = Offset(200, 300);
    EdgeSizing sized(String from) => EdgeSizing(
        edgeId: 'dsr3',
        service: ServiceType.drainage,
        flow: const FlowRate(0.001),
        diameter: const Diameter(0.075),
        velocity: const Velocity(0.5),
        flowFromId: from);

    test('a drainage stack solved from the upper node flows DOWN', () {
      expect(riserFlowGoesUp(edge, upper, lower, sized('ds3')), isFalse);
    });
    test('a riser drawn top-down but solved from below flows UP', () {
      // A transfer riser drawn from the roof tank down to the pump: the
      // solve says the flow comes FROM the lower node ⇒ an UP arrow.
      expect(riserFlowGoesUp(edge, upper, lower, sized('ds2')), isTrue);
    });
    test('unsized: the drawing direction (top -> bottom = down)', () {
      expect(riserFlowGoesUp(edge, upper, lower, null), isFalse);
      expect(riserFlowGoesUp(edge, lower, upper, null), isTrue);
    });
    test('property: reversing the drawing never changes a solved arrow', () {
      const rev = NetEdge(
          id: 'dsr3',
          fromId: 'ds2',
          toId: 'ds3',
          service: ServiceType.drainage,
          kind: EdgeKind.riser);
      for (final from in ['ds3', 'ds2']) {
        expect(riserFlowGoesUp(rev, lower, upper, sized(from)),
            riserFlowGoesUp(edge, upper, lower, sized(from)),
            reason: 'flow from $from');
      }
    });
  });
}
