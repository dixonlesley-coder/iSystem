import 'package:mechx_engine/pressure_field.dart';
import 'package:test/test.dart';

/// Seed tests for the heatmap scalar-field kernel. Hand-computed anchors for
/// inverse-distance weighting, normalization, and grid sampling.
void main() {
  group('inverse-distance weighting', () {
    test('a single node fills the whole field with its value', () {
      const nodes = [FieldNode(0, 0, 100)];
      expect(idw(nodes, 0, 0), 100.0);
      expect(idw(nodes, 5, 5), 100.0);
    });

    test('coincident sample returns the node value exactly (no /0)', () {
      const nodes = [FieldNode(0, 0, 10), FieldNode(10, 0, 100)];
      expect(idw(nodes, 0, 0), 10.0);
    });

    test('equidistant between two nodes is the mean', () {
      const nodes = [FieldNode(0, 0, 0), FieldNode(10, 0, 100)];
      expect(idw(nodes, 5, 0), closeTo(50.0, 1e-9));
    });

    test('power=2 weighting favours the nearer node', () {
      const nodes = [FieldNode(0, 0, 0), FieldNode(10, 0, 100)];
      // d1=2, d2=8 → w1=1/4, w2=1/64 → (100/64)/(1/4+1/64) = 5.88235…
      expect(idw(nodes, 2, 0, power: 2), closeTo(5.882352941, 1e-6));
    });

    test('empty node set yields NaN', () {
      expect(idw(const [], 0, 0).isNaN, isTrue);
    });
  });

  group('normalize', () {
    test('maps within range', () {
      expect(normalize(50, 0, 100), closeTo(0.5, 1e-12));
      expect(normalize(0, 0, 100), closeTo(0.0, 1e-12));
      expect(normalize(100, 0, 100), closeTo(1.0, 1e-12));
    });

    test('clamps outside range', () {
      expect(normalize(150, 0, 100), 1.0);
      expect(normalize(-50, 0, 100), 0.0);
    });

    test('degenerate (zero-width) range maps to mid-scale', () {
      expect(normalize(5, 5, 5), 0.5);
    });
  });

  group('sampleField', () {
    test('covers bounds with whole square cells', () {
      const nodes = [FieldNode(0, 0, 42)];
      final field = sampleField(
        nodes: nodes,
        bounds: const FieldBounds(0, 0, 10, 10),
        resolution: 5,
      );
      expect(field.cols, 2);
      expect(field.rows, 2);
      expect(field.values.length, 4);
      // single node → uniform field
      expect(field.min, closeTo(42.0, 1e-9));
      expect(field.max, closeTo(42.0, 1e-9));
      // cell centres
      expect(field.centerX(0), closeTo(2.5, 1e-12));
      expect(field.centerY(1), closeTo(7.5, 1e-12));
    });

    test('values stay within the node value range', () {
      const nodes = [FieldNode(0, 0, 0), FieldNode(10, 10, 100)];
      final field = sampleField(
        nodes: nodes,
        bounds: const FieldBounds(0, 0, 10, 10),
        resolution: 5,
      );
      expect(field.min, greaterThanOrEqualTo(0.0));
      expect(field.max, lessThanOrEqualTo(100.0));
    });
  });

  group('ScalarField indexing & normalizeField', () {
    test('row-major valueAt', () {
      const field = ScalarField(
        cols: 2,
        rows: 2,
        cellSize: 1,
        originX: 0,
        originY: 0,
        values: [0, 25, 50, 100],
      );
      expect(field.valueAt(0, 0), 0);
      expect(field.valueAt(1, 0), 25);
      expect(field.valueAt(0, 1), 50);
      expect(field.valueAt(1, 1), 100);
    });

    test('normalizeField scales to [0,1] against own min/max', () {
      const field = ScalarField(
        cols: 2,
        rows: 2,
        cellSize: 1,
        originX: 0,
        originY: 0,
        values: [0, 25, 50, 100],
      );
      expect(normalizeField(field), [0.0, 0.25, 0.5, 1.0]);
    });
  });
}
