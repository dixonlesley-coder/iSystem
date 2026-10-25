// Round 58 (2026-10-18) — plumbing-hvac-convergence-8-vent-stack-developed-
// length-ignored: a vent stack is sized on UPC Table 703.2's DFU column AND
// its maximum developed length column.
//
// First principles: UPC 703.2 vent maximum developed length (ft -> m at
// 0.3048): DN50 120 ft = 36.58 m, DN65 180 ft = 54.86 m, DN75 212 ft =
// 64.62 m. A 16-storey building at 3.5 m with a vent stack V0..V15 and a VTR
// one storey above V15 measures 16 x 3.5 = 56.0 m of riser (the §10
// elevation delta). At 32 DFU the DFU column alone gives DN65 (24 < 32 <=
// 48) whose limit 54.86 m < 56 m => DN75 (64.62 m >= 56 m). At 24 DFU the DFU
// column gives DN50 (36.58 m) — two sizes small — => DN75.
library;

import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/drainage_sizing.dart' as drain;
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

NetNode _n(String id, double x, int f, {NodeRole role = NodeRole.main}) =>
    NetNode(id: id, sheetId: 's1', x: x, y: 0, floorIndex: f, role: role);

NetEdge _e(String id, String a, String b, ServiceType s,
        {EdgeKind k = EdgeKind.run}) =>
    NetEdge(id: id, fromId: a, toId: b, service: s, kind: k);

BuildingLevels _floors(int n) => BuildingLevels(
    [for (var i = 0; i < n; i++) Floor('L$i', const Length(3.5))]);

/// [storeys]-storey soil stack S0.. (one [dfuPerFloor] fixture per storey),
/// a per-storey vent tie into the vent stack V0.. and a VTR riser one storey
/// above the top (the building has [storeys] + 1 levels so the VTR sits on
/// the roof level).
({Network net, Map<String, double> dfu}) _stack(
    int storeys, double dfuPerFloor) {
  final nodes = <NetNode>[_n('out', 0, 0)];
  final edges = <NetEdge>[_e('sewer', 'out', 'S0', ServiceType.drainage)];
  final dfu = <String, double>{};
  for (var f = 0; f < storeys; f++) {
    nodes
      ..add(_n('S$f', 100, f))
      ..add(_n('V$f', 120, f))
      ..add(_n('fx$f', 200, f, role: NodeRole.fixture));
    dfu['fx$f'] = dfuPerFloor;
    edges
      ..add(_e('fb$f', 'S$f', 'fx$f', ServiceType.drainage))
      ..add(_e('rv$f', 'S$f', 'V$f', ServiceType.vent));
    if (f > 0) {
      edges
        ..add(_e('s$f', 'S${f - 1}', 'S$f', ServiceType.drainage,
            k: EdgeKind.riser))
        ..add(
            _e('v$f', 'V${f - 1}', 'V$f', ServiceType.vent, k: EdgeKind.riser));
    }
  }
  nodes.add(_n('VTR', 120, storeys));
  edges.add(
      _e('vtr', 'V${storeys - 1}', 'VTR', ServiceType.vent, k: EdgeKind.riser));
  return (net: Network(nodes: nodes, edges: edges), dfu: dfu);
}

/// Round 59 — the same 16-storey stack with a one-storey vent OFFSET at L8:
/// risers V0..V8, a run V8 -> W8 ([bends] bare elbows between), risers
/// W8..W15 and the VTR; storeys 0..7 tie into V, 8..15 into W.
({Network net, Map<String, double> dfu}) _offsetStack(double dfuPerFloor,
    {int bends = 0}) {
  const storeys = 16;
  final nodes = <NetNode>[_n('out', 0, 0)];
  final edges = <NetEdge>[_e('sewer', 'out', 'S0', ServiceType.drainage)];
  final dfu = <String, double>{};
  for (var f = 0; f < storeys; f++) {
    final v = f <= 7 ? 'V$f' : 'W$f';
    nodes
      ..add(_n('S$f', 100, f))
      ..add(_n('fx$f', 200, f, role: NodeRole.fixture));
    dfu['fx$f'] = dfuPerFloor;
    edges
      ..add(_e('fb$f', 'S$f', 'fx$f', ServiceType.drainage))
      ..add(_e('rv$f', 'S$f', v, ServiceType.vent));
    if (f > 0) {
      edges.add(_e('s$f', 'S${f - 1}', 'S$f', ServiceType.drainage,
          k: EdgeKind.riser));
    }
  }
  for (var f = 0; f <= 8; f++) {
    nodes.add(_n('V$f', 120, f));
    if (f > 0) {
      edges.add(
          _e('v$f', 'V${f - 1}', 'V$f', ServiceType.vent, k: EdgeKind.riser));
    }
  }
  for (var f = 8; f < storeys; f++) {
    nodes.add(_n('W$f', 140, f));
    if (f > 8) {
      edges.add(
          _e('v$f', 'W${f - 1}', 'W$f', ServiceType.vent, k: EdgeKind.riser));
    }
  }
  var prev = 'V8';
  for (var b = 0; b < bends; b++) {
    nodes.add(_n('BB$b', 125.0 + b, 8));
    edges.add(_e(b == 0 ? 'off' : 'off$b', prev, 'BB$b', ServiceType.vent));
    prev = 'BB$b';
  }
  edges.add(_e(bends == 0 ? 'off' : 'off$bends', prev, 'W8', ServiceType.vent));
  nodes.add(_n('VTR', 140, storeys));
  edges.add(_e('vtr', 'W15', 'VTR', ServiceType.vent, k: EdgeKind.riser));
  return (net: Network(nodes: nodes, edges: edges), dfu: dfu);
}

Map<String, EdgeSizing> _size(int storeys, double dfuPerFloor,
    {bool withBuilding = true}) {
  final t = _stack(storeys, dfuPerFloor);
  return autoSizeNetwork(t.net, const SizingContext(),
      leafDemand: const {},
      nodeDrainageUnits: t.dfu,
      building: withBuilding ? _floors(storeys + 1) : null);
}

void main() {
  test('the UPC 703.2 length column (ft -> m)', () {
    expect(drain.ventDiameterForLength(50, 36.0), 50);
    expect(drain.ventDiameterForLength(50, 37.0), 65);
    expect(drain.ventDiameterForLength(65, 56.0), 75);
    expect(drain.ventDiameterForLength(32, 56.0), 75);
    expect(drain.ventDiameterForLength(100, 56.0), 100);
    expect(drain.ventLengthExceedsTable(155.0), isFalse);
    expect(drain.ventLengthExceedsTable(160.0), isTrue);
  });

  test('16 x 3.5 m at 32 DFU: DN75 (DN65 limit 54.9 m < 56 m)', () {
    expect(drain.ventDiameterForDfu(32).inMillimeters, 65);
    final s = _size(16, 2);
    for (final id in ['v1', 'v8', 'v15', 'vtr']) {
      expect(s[id]!.diameter.inMillimeters, 75, reason: id);
    }
  });

  test('16 x 3.5 m at 24 DFU: DN75 (DN50 36.6 m, DN65 54.9 m too short)', () {
    expect(drain.ventDiameterForDfu(24).inMillimeters, 50);
    final s = _size(16, 1.5);
    for (final id in ['v1', 'v8', 'v15', 'vtr']) {
      expect(s[id]!.diameter.inMillimeters, 75, reason: id);
    }
  });

  test(
      'Round 59: a 16 x 3.5 m stack OFFSET at L8 at 32 DFU is one 56 m stack '
      '=> DN75 on every riser, the offset run and the VTR', () {
    for (final bends in [0, 2]) {
      final t = _offsetStack(2, bends: bends);
      final s = autoSizeNetwork(t.net, const SizingContext(),
          leafDemand: const {},
          nodeDrainageUnits: t.dfu,
          building: _floors(17));
      // 8 risers V1..V8 + 7 risers W9..W15 + the VTR = 16 x 3.5 = 56.0 m
      // (the uncalibrated offset adds 0 m) > DN65's 54.86 m => DN75.
      for (final id in ['v1', 'v8', 'off', 'v9', 'v12', 'vtr']) {
        expect(s[id]!.diameter.inMillimeters, 75, reason: '$id bends $bends');
      }
    }
  });

  test('a short stack keeps its DFU size (byte-identical)', () {
    // 4 storeys: 4 x 3.5 = 14 m — inside every row from DN40 up.
    final withB = _size(4, 2);
    final noB = _size(4, 2, withBuilding: false);
    for (final id in ['v1', 'v2', 'v3', 'vtr']) {
      expect(withB[id]!.diameter.inMillimeters, noB[id]!.diameter.inMillimeters,
          reason: id);
    }
  });

  test('property: every stack height n x 3.5 m sizes within its length row',
      () {
    for (var n = 2; n <= 40; n += 3) {
      for (final dfu in [1.0, 2.0, 6.0]) {
        final s = _size(n, dfu);
        final total = (n) * 3.5; // n risers incl. the VTR, 3.5 m each
        final mm = s['vtr']!.diameter.inMillimeters;
        final row = drain.kVentMaxDevelopedLengthM
            .firstWhere((r) => r.$1 == mm, orElse: () => (mm, 1e9));
        if (!drain.ventLengthExceedsTable(total)) {
          expect(total, lessThanOrEqualTo(row.$2 + 1e-9),
              reason: 'n=$n dfu=$dfu DN$mm');
        }
        // Never below the DFU column.
        expect(
            mm,
            greaterThanOrEqualTo(
                drain.ventDiameterForDfu(n * dfu).inMillimeters));
      }
    }
  });
}
