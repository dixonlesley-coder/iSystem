/// Pure scalar-field module backing the pressure heatmap.
///
/// Architecture guardrail (§12): the heatmap is a *generated render of the
/// solved network*, never a parallel calculation. This module does NOT compute
/// pressures — it takes the already-solved node values (residual pressure for
/// pressurized systems, fill-ratio for gravity drainage) sampled at known
/// plan coordinates and interpolates them into a dense scalar grid the UI can
/// colour-map. It is dimension-agnostic on purpose (operates on plain
/// `double`s) so the same kernel serves any solved metric; the *meaning* and
/// units of the values live with the network solve that produced them.
///
/// Zero Flutter imports.
library;

import 'dart:math' as math;

/// A solved value sampled at a plan coordinate. [x]/[y] are in the same
/// coordinate space as the bounds passed to [sampleField] (engine SI metres in
/// practice, but the field treats them as opaque numbers).
class FieldNode {
  final double x;
  final double y;
  final double value;

  const FieldNode(this.x, this.y, this.value);
}

/// Rectangular sampling region in plan coordinates.
class FieldBounds {
  final double minX;
  final double minY;
  final double maxX;
  final double maxY;

  const FieldBounds(this.minX, this.minY, this.maxX, this.maxY);

  double get width => maxX - minX;
  double get height => maxY - minY;
}

/// Below this distance a sample is treated as coincident with a node, so we
/// return the node value exactly instead of dividing by (near) zero.
const double _coincidenceEpsilon = 1e-9;

/// Inverse-distance-weighted interpolation of [nodes] at point ([x], [y]).
///
/// Weight of each node is 1 / dⁿ where d is the distance and n is [power]
/// (2 ≈ a smooth, locally-dominated field). If the point coincides with a
/// node, that node's value is returned exactly. Returns NaN for an empty node
/// set (caller decides how to render "no data").
double idw(
  List<FieldNode> nodes,
  double x,
  double y, {
  double power = 2.0,
}) {
  if (nodes.isEmpty) return double.nan;
  var weightedSum = 0.0;
  var weightTotal = 0.0;
  for (final node in nodes) {
    final dx = node.x - x;
    final dy = node.y - y;
    final distance = math.sqrt(dx * dx + dy * dy);
    if (distance < _coincidenceEpsilon) return node.value;
    final weight = 1.0 / math.pow(distance, power);
    weightedSum += weight * node.value;
    weightTotal += weight;
  }
  return weightedSum / weightTotal;
}

/// A dense, row-major grid of interpolated scalar values. Cell (col, row) is
/// centred at ([centerX], [centerY]) in plan coordinates.
class ScalarField {
  final int cols;
  final int rows;
  final double cellSize;
  final double originX;
  final double originY;
  final List<double> values;

  const ScalarField({
    required this.cols,
    required this.rows,
    required this.cellSize,
    required this.originX,
    required this.originY,
    required this.values,
  });

  double valueAt(int col, int row) => values[row * cols + col];

  double centerX(int col) => originX + (col + 0.5) * cellSize;
  double centerY(int row) => originY + (row + 0.5) * cellSize;

  double get min => values.reduce(math.min);
  double get max => values.reduce(math.max);
}

/// Sample [nodes] onto a regular grid covering [bounds] with square cells of
/// edge [resolution] (plan units). Each cell takes the [idw] value at its
/// centre. The grid is sized by rounding the region up to whole cells, so it
/// always fully covers [bounds].
ScalarField sampleField({
  required List<FieldNode> nodes,
  required FieldBounds bounds,
  required double resolution,
  double power = 2.0,
}) {
  assert(resolution > 0, 'resolution must be positive');
  final cols = math.max(1, (bounds.width / resolution).ceil());
  final rows = math.max(1, (bounds.height / resolution).ceil());
  final values = List<double>.filled(cols * rows, 0.0);
  for (var row = 0; row < rows; row++) {
    for (var col = 0; col < cols; col++) {
      final x = bounds.minX + (col + 0.5) * resolution;
      final y = bounds.minY + (row + 0.5) * resolution;
      values[row * cols + col] = idw(nodes, x, y, power: power);
    }
  }
  return ScalarField(
    cols: cols,
    rows: rows,
    cellSize: resolution,
    originX: bounds.minX,
    originY: bounds.minY,
    values: values,
  );
}

/// Map a raw [value] to the colour parameter [0, 1] given the range
/// [[min], [max]], clamped at the ends. A degenerate (zero-width) range maps
/// to 0.5 so a uniform field renders as one mid-scale colour rather than NaN.
double normalize(double value, double min, double max) {
  if ((max - min).abs() < _coincidenceEpsilon) return 0.5;
  final t = (value - min) / (max - min);
  return t.clamp(0.0, 1.0);
}

/// Normalize an entire [field] against its own min/max — the values the UI
/// feeds to the colour ramp.
List<double> normalizeField(ScalarField field) {
  final mn = field.min;
  final mx = field.max;
  return field.values.map((v) => normalize(v, mn, mx)).toList();
}
