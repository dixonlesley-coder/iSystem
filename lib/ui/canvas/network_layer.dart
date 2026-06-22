import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/network/network.dart';

import '../../store/network_store.dart';
import '../../store/sheets_store.dart';
import 'service_style.dart';
import 'viewport.dart';

/// Always-on render of the drawn network for the current sheet/floor, painted
/// in screen space via the sheet's viewport transform. Pointer-transparent so
/// the canvas keeps panning/zooming underneath.
class NetworkLayer extends ConsumerWidget {
  final String sheetId;
  final int floorIndex;

  const NetworkLayer({super.key, required this.sheetId, required this.floorIndex});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final net = ref.watch(networkControllerProvider).network;
    final transform = ref.watch(sheetsControllerProvider).viewportFor(sheetId) ??
        const ViewportTransform();
    return IgnorePointer(
      child: CustomPaint(
        size: Size.infinite,
        painter: _NetworkPainter(
          net: net,
          sheetId: sheetId,
          floorIndex: floorIndex,
          transform: transform,
        ),
      ),
    );
  }
}

class _NetworkPainter extends CustomPainter {
  final Network net;
  final String sheetId;
  final int floorIndex;
  final ViewportTransform transform;

  _NetworkPainter({
    required this.net,
    required this.sheetId,
    required this.floorIndex,
    required this.transform,
  });

  bool _onThisFloor(NetNode n) => n.sheetId == sheetId && n.floorIndex == floorIndex;

  @override
  void paint(Canvas canvas, Size size) {
    for (final e in net.edges) {
      final a = net.nodeById(e.fromId);
      final b = net.nodeById(e.toId);
      if (a == null || b == null) continue;
      final color = serviceColor(e.service);

      if (e.kind == EdgeKind.run) {
        if (!_onThisFloor(a) || !_onThisFloor(b)) continue;
        canvas.drawLine(
          transform.worldToScreen(Offset(a.x, a.y)),
          transform.worldToScreen(Offset(b.x, b.y)),
          Paint()
            ..color = color
            ..strokeWidth = 2.5
            ..strokeCap = StrokeCap.round
            ..style = PaintingStyle.stroke,
        );
      } else {
        final lowFloor = math.min(a.floorIndex, b.floorIndex);
        for (final n in [a, b]) {
          if (_onThisFloor(n)) {
            _riserMarker(
              canvas,
              transform.worldToScreen(Offset(n.x, n.y)),
              color,
              up: n.floorIndex == lowFloor,
            );
          }
        }
      }
    }

    // Nodes on top.
    for (final n in net.nodes) {
      if (!_onThisFloor(n)) continue;
      final p = transform.worldToScreen(Offset(n.x, n.y));
      canvas.drawCircle(p, 3, Paint()..color = const Color(0xFF15171B));
      canvas.drawCircle(
        p,
        3,
        Paint()
          ..color = const Color(0xFFFFFFFF)
          ..strokeWidth = 1
          ..style = PaintingStyle.stroke,
      );
    }
  }

  void _riserMarker(Canvas canvas, Offset p, Color color, {required bool up}) {
    canvas.drawCircle(p, 7, Paint()..color = color.withAlpha(38));
    canvas.drawCircle(
      p,
      7,
      Paint()
        ..color = color
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke,
    );
    final path = Path();
    if (up) {
      path.moveTo(p.dx, p.dy - 4);
      path.lineTo(p.dx - 3, p.dy + 2);
      path.lineTo(p.dx + 3, p.dy + 2);
    } else {
      path.moveTo(p.dx, p.dy + 4);
      path.lineTo(p.dx - 3, p.dy - 2);
      path.lineTo(p.dx + 3, p.dy - 2);
    }
    path.close();
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_NetworkPainter old) =>
      old.net != net ||
      old.transform != transform ||
      old.floorIndex != floorIndex ||
      old.sheetId != sheetId;
}
