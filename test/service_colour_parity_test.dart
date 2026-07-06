import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/ui/canvas/service_style.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/drawing_chrome.dart';

/// E2 parity: the LIVE on-canvas `serviceColor` is the single truth, and the
/// engine's PDF `serviceChromeColor` (which the plan PDF exporters delegate to)
/// mirrors it channel-for-channel. Walk EVERY ServiceType so supply/return/
/// exhaust air (which used to disagree across canvas / PDF / DXF) can never
/// drift again without this failing.
void main() {
  test('canvas serviceColor == engine serviceChromeColor for every ServiceType',
      () {
    for (final s in ServiceType.values) {
      final c = serviceColor(s);
      final (r, g, b) = serviceChromeColor(s);
      // Color exposes 0..1 normalized components (.r/.g/.b); serviceChromeColor
      // is the same hex / 255, so each channel must match within float epsilon.
      expect(r, closeTo(c.r, 1e-9), reason: '$s red');
      expect(g, closeTo(c.g, 1e-9), reason: '$s green');
      expect(b, closeTo(c.b, 1e-9), reason: '$s blue');
    }
  });

  test('the DXF ACI colour is a valid index for every ServiceType (E2)', () {
    // Nearest-ACI to the same canvas hue family; every service resolves to a
    // real ACI index, and the air trio no longer collides on olive.
    for (final s in ServiceType.values) {
      expect(serviceAciColorFor(s), inInclusiveRange(1, 255), reason: '$s');
    }
    // Return air moved off olive (52) onto an azure blue matching #6F8FC0.
    expect(serviceAciColorFor(ServiceType.returnAir), 150);
  });
}
