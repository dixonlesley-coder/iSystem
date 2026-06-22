import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';

import '../../store/network_store.dart';
import '../../store/sheets_store.dart';
import '../../store/sizing_store.dart';
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
    final sizing = ref.watch(showSizingProvider)
        ? ref.watch(sizingProvider)
        : const <String, EdgeSizing>{};
    return IgnorePointer(
      child: CustomPaint(
        size: Size.infinite,
        painter: _NetworkPainter(
          net: net,
          sheetId: sheetId,
          floorIndex: floorIndex,
          transform: transform,
          sizing: sizing,
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
  final Map<String, EdgeSizing> sizing;

  _NetworkPainter({
    required this.net,
    required this.sheetId,
    required this.floorIndex,
    required this.transform,
    required this.sizing,
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
        final pa = transform.worldToScreen(Offset(a.x, a.y));
        final pb = transform.worldToScreen(Offset(b.x, b.y));
        canvas.drawLine(
          pa,
          pb,
          Paint()
            ..color = color
            ..strokeWidth = 2.5
            ..strokeCap = StrokeCap.round
            ..style = PaintingStyle.stroke,
        );
        final s = sizing[e.id];
        if (s != null) {
          final mm = s.diameter.inMillimeters.round();
          final label = e.service.regime == FlowRegime.air ? 'Ø$mm' : 'DN$mm';
          _label(canvas, (pa + pb) / 2, label);
        }
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

  void _label(Canvas canvas, Offset center, String text) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: const TextStyle(
          fontFamily: 'Roboto',
          fontSize: 10.5,
          color: Color(0xFFFFFFFF),
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final rect = Rect.fromCenter(
      center: center,
      width: tp.width + 8,
      height: tp.height + 4,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(3)),
      Paint()..color = const Color(0xD915171B),
    );
    tp.paint(canvas, center - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  bool shouldRepaint(_NetworkPainter old) =>
      old.net != net ||
      old.transform != transform ||
      old.floorIndex != floorIndex ||
      old.sheetId != sheetId ||
      old.sizing != sizing;
}
