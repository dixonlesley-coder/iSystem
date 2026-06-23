import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/ui/canvas/snapping.dart';

void main() {
  const from = Offset.zero;

  test('near-horizontal snaps to horizontal (dy ≈ 0)', () {
    final r = orthoSnap(from, const Offset(100, 8));
    expect(r.dy, closeTo(0, 1e-9));
    expect(r.dx, greaterThan(0));
  });

  test('near-vertical snaps to vertical (dx ≈ 0)', () {
    final r = orthoSnap(from, const Offset(8, 100));
    expect(r.dx, closeTo(0, 1e-9));
    expect(r.dy, greaterThan(0));
  });

  test('near-diagonal snaps to 45° (|dx| ≈ |dy|)', () {
    final r = orthoSnap(from, const Offset(100, 90));
    expect(r.dx.abs(), closeTo(r.dy.abs(), 1e-9));
  });

  test('length is preserved', () {
    final r = orthoSnap(from, const Offset(100, 12));
    expect(r.distance, closeTo(const Offset(100, 12).distance, 1e-9));
  });

  test('zero-length segment is returned unchanged', () {
    expect(orthoSnap(const Offset(5, 5), const Offset(5, 5)),
        const Offset(5, 5));
  });
}
