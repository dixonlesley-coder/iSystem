// Round 25 (2026-10-18) — engine half of the round-25 review fixes, each with
// a first-principles derivation and, where it fits, a seeded property:
//   regression-dxf-bounds-pass-unbounded-work   past the primitive cap an
//       INSERT grows the bounds by its block's memoised extent (O(instances)).
//   whole-building-2-declared-capacity-lowers-fault   a declared LV capacity
//       above the PLN TR ceiling never estimates BELOW the undeclared figure.
//   whole-building-2-socket-count-diversified   takeoff + DAYA read the
//       CONNECTED (undiversified) load.
//   whole-building-2-tanks-not-procured   drawn tanks reach the schedule.
//   whole-building-2-mccb-curve-letter   the fire-duty note names an MCCB by
//       class, no curve letter, and a fan is not a 'fire pump'.
//   drainage-4-1..4   override reducers, vent offsets, the base-connection
//       phantom, the individually-vented trap arm.
import 'dart:math' as math;

import 'package:mechx_engine/electrical/bom.dart';
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/fault.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/supply_design.dart';
import 'package:mechx_engine/geometry/dxf_drawing.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/electrical_sld_drawing.dart';
import 'package:mechx_engine/report/equipment_schedule.dart';
import 'package:mechx_engine/sizing/drainage_advisory.dart';
import 'package:mechx_engine/sizing/drainage_sizing.dart' as drain;
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

const _p = PuilProfile();

NetNode _n(String id, double x, double y,
        {int floor = 0, NodeRole role = NodeRole.main}) =>
    NetNode(
        id: id, sheetId: 's1', x: x, y: y, floorIndex: floor, role: role);

NetEdge _e(String id, String a, String b, ServiceType s,
        {EdgeKind kind = EdgeKind.run}) =>
    NetEdge(id: id, fromId: a, toId: b, service: s, kind: kind);

String _line(double x1, double y1, double x2, double y2) =>
    '0\nLINE\n8\n0\n10\n$x1\n20\n$y1\n11\n$x2\n21\n$y2\n';

String _wrap(String body, {String blocks = ''}) =>
    '${blocks.isEmpty ? '' : '0\nSECTION\n2\nBLOCKS\n${blocks}0\nENDSEC\n'}'
    '0\nSECTION\n2\nENTITIES\n${body}0\nENDSEC\n0\nEOF\n';

void main() {
  group('DXF: the bounds-only continuation is O(instances)', () {
    // BIG = 10 000 vertical LINEs x = 0..9999, y 0..10 ⇒ block extent
    // [0, 9999] x [0, 10]. A 100 x 100 array (spacing 20 000 / 100) is
    // 10 000 instances = 1e8 primitives; the 400 000 cap fills after 40
    // instances. The remaining 9 960 instances used to re-walk all 10 000
    // lines each (~1e8 transforms, tens of seconds); now each grows the box
    // by 4 transformed corners.
    final big = StringBuffer('0\nBLOCK\n8\n0\n2\nBIG\n10\n0\n20\n0\n');
    for (var i = 0; i < 10000; i++) {
      big.write(_line(i.toDouble(), 0, i.toDouble(), 10));
    }
    big.write('0\nENDBLK\n');
    const tick = '0\nBLOCK\n8\n0\n2\nTICK\n10\n0\n20\n0\n'
        '0\nLINE\n8\n0\n10\n0\n20\n0\n11\n10\n21\n0\n0\nENDBLK\n';
    const array = '0\nINSERT\n8\n0\n2\nBIG\n10\n0\n20\n0\n'
        '70\n100\n71\n100\n44\n20000\n45\n100\n';
    // A TICK (0,0)-(10,0) rotated 90° at (-5000, 0) AFTER the cap: its image
    // is (-5000, 0)-(-5000, 10), so minX = -5000 exactly.
    const rotated = '0\nINSERT\n8\n0\n2\nTICK\n10\n-5000\n20\n0\n50\n90\n';

    test('complete bounds, flagged truncated, in bounded time', () {
      final sw = Stopwatch()..start();
      final d =
          parseDxf(_wrap(array + rotated, blocks: big.toString() + tick))!;
      sw.stop();
      expect(d.truncated, isTrue);
      expect(d.polylines, hasLength(400000));
      // maxX = 99 · 20 000 + 9 999; maxY = 99 · 100 + 10.
      expect(d.bounds.maxX, closeTo(99 * 20000 + 9999, 1e-6));
      expect(d.bounds.maxY, closeTo(99 * 100 + 10, 1e-6));
      expect(d.bounds.minX, closeTo(-5000, 1e-6));
      expect(d.bounds.minY, closeTo(0, 1e-6));
      // The old walk took tens of seconds here; generous CI headroom.
      expect(sw.elapsed.inSeconds, lessThan(15));
    });

    test('property: the extent box is a superset of the exact walk', () {
      // A small block (never capped) placed by seeded random INSERTs: the
      // exact bounds are known; a second copy placed after a capping array
      // must report bounds that CONTAIN the exact ones (conservative box).
      final rnd = math.Random(25);
      const blockDef = '0\nBLOCK\n8\n0\n2\nB\n10\n1\n20\n2\n'
          '0\nLINE\n8\n0\n10\n0\n20\n0\n11\n30\n21\n5\n'
          '0\nCIRCLE\n8\n0\n10\n10\n20\n10\n40\n4\n0\nENDBLK\n';
      for (var t = 0; t < 20; t++) {
        final x = rnd.nextDouble() * 1e5 - 5e4;
        final y = rnd.nextDouble() * 1e5 - 5e4;
        final rot = rnd.nextDouble() * 360;
        final sx = 0.5 + rnd.nextDouble() * 2;
        final ins = '0\nINSERT\n8\n0\n2\nB\n10\n$x\n20\n$y\n41\n$sx\n'
            '42\n$sx\n50\n$rot\n';
        final exact = parseDxf(_wrap(ins, blocks: blockDef))!.bounds;
        final capped = parseDxf(
                _wrap(array + ins, blocks: big.toString() + blockDef))!
            .bounds;
        expect(capped.minX, lessThanOrEqualTo(exact.minX + 1e-6));
        expect(capped.minY, lessThanOrEqualTo(exact.minY + 1e-6));
        expect(capped.maxX, greaterThanOrEqualTo(exact.maxX - 1e-6));
        expect(capped.maxY, greaterThanOrEqualTo(exact.maxY - 1e-6));
      }
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  group('declared LV capacity never lowers the fault estimate', () {
    // Isc = S / (√3 · 400 · 0.04) for a transformer of S VA.
    double txFault(double va) => va / (math.sqrt(3) * 400 * 0.04);
    ElectricalProject withCap(double? va) => ElectricalProject(
          id: 'p',
          name: 'p',
          panels: const [],
          supplyCapacityVa: va == null ? null : ApparentPower(va),
        );

    test('630 kVA declared: 630000 / 27712.8 = 22733.2 A (was a flat 16 kA)',
        () {
      expect(txFault(630000), closeTo(22733.2, 0.05));
      expect(estimatedServiceFaultLevelA(withCap(630000))!.amperes,
          closeTo(22733.2, 0.05));
    });

    test('with a 600 kVA demand the study transformer governs (>= undeclared)',
        () {
      const demand = ApparentPower(600000);
      final undeclared =
          estimatedServiceFaultLevelA(withCap(null), demand: demand)!.amperes;
      // The study's pick for 600 kVA, by the same formula.
      final s = determineSupply(demand);
      expect(s.isMv, isTrue);
      expect(undeclared, closeTo(txFault(s.transformerKva! * 1000), 0.05));
      final declared =
          estimatedServiceFaultLevelA(withCap(630000), demand: demand)!
              .amperes;
      expect(declared, greaterThanOrEqualTo(undeclared - 1e-6));
      expect(declared,
          closeTo(math.max(txFault(630000), undeclared), 0.05));
    });

    test('300 kVA declared: 10 825 A from the formula, floored at 16 kA', () {
      expect(txFault(300000), lessThan(16000));
      expect(
          estimatedServiceFaultLevelA(withCap(300000))!.amperes, 16000);
      // The LV rungs are unchanged.
      expect(estimatedServiceFaultLevelA(withCap(5500))!.amperes, 6000);
      expect(estimatedServiceFaultLevelA(withCap(100000))!.amperes, 10000);
    });

    test('property: monotone in capacity, never below the undeclared figure',
        () {
      final rnd = math.Random(2510);
      for (var t = 0; t < 200; t++) {
        final demand = ApparentPower(rnd.nextDouble() * 3e6);
        final c1 = 197001 + rnd.nextDouble() * 3e6;
        final c2 = c1 + rnd.nextDouble() * 1e6;
        final undeclared =
            estimatedServiceFaultLevelA(withCap(null), demand: demand)
                    ?.amperes ??
                16000;
        final f1 =
            estimatedServiceFaultLevelA(withCap(c1), demand: demand)!.amperes;
        final f2 =
            estimatedServiceFaultLevelA(withCap(c2), demand: demand)!.amperes;
        expect(f1, greaterThanOrEqualTo(undeclared - 0.1), reason: '$t');
        expect(f1, greaterThanOrEqualTo(16000));
        expect(f2, greaterThanOrEqualTo(f1 - 0.1), reason: '$t');
      }
    });
  });

  group('socket takeoff + DAYA read the connected load', () {
    // A 3000 W socket way at demand factor 0.7: diversified 2100 W, connected
    // 3000 W. Sockets = ceil(3000 / 200) = 15 (was ceil(2100 / 200) = 11).
    const project = ElectricalProject(id: 'p', name: 'p', panels: [
      ElectricalPanel(
        id: 'LP',
        name: 'LP',
        system: ElectricalSystem.singlePhase,
        voltage: Voltage(220),
        circuits: [
          ElectricalCircuit(
              id: 's1',
              name: 'Sockets',
              loadKind: LoadKind.socket,
              loadW: 3000,
              demandFactor: 0.7,
              length: Length(15)),
        ],
      ),
    ]);
    final sys = computeSystem(_p, project);
    final r = sys.panels['LP']!.circuits.single;

    test('loadW is diversified, connectedW is not', () {
      expect(r.loadW, closeTo(2100, 1e-9));
      expect(r.connectedW, closeTo(3000, 1e-9));
    });

    test('the BOM orders 15 socket outlets', () {
      final socket = buildPanelBom(sys.panels['LP']!)
          .firstWhere((l) => l.description.startsWith('Socket outlet'));
      expect(socket.qty, (3000 / 200).ceil());
      expect(socket.qty, 15);
    });

    test('the schedule DAYA prints 3.000 WATT', () {
      final labels = buildElectricalPanelDetail(
              project: project, result: sys, panelId: 'LP')
          .prims
          .whereType<SldLabel>()
          .map((l) => l.text)
          .toList();
      expect(labels, contains('3.000 WATT'));
      expect(labels, isNot(contains('2.100 WATT')));
    });

    test('a motor way connects at shaft kW / efficiency, undiversified', () {
      const m = ElectricalCircuit(
          id: 'm',
          name: 'm',
          loadKind: LoadKind.motor,
          motorKw: 7.5,
          demandFactor: 0);
      expect(circuitUndiversifiedW(m),
          closeTo(7500 / kAssumedMotorEfficiency, 1e-9));
      expect(circuitConnectedW(m), 0);
    });
  });

  group('fire-duty note wording follows the device class + load kind', () {
    const project = ElectricalProject(id: 'p', name: 'p', panels: [
      ElectricalPanel(
        id: 'EP',
        name: 'EP',
        system: ElectricalSystem.threePhase,
        voltage: Voltage(400),
        circuits: [
          ElectricalCircuit(
              id: 'fp',
              name: 'Fire pump',
              loadKind: LoadKind.pump,
              motorKw: 75,
              phases: 3,
              lifeSafety: true,
              cableType: 'FRC',
              length: Length(30)),
          ElectricalCircuit(
              id: 'sp',
              name: 'Stair pressurisation fan',
              loadKind: LoadKind.motor,
              motorKw: 2.2,
              phases: 3,
              lifeSafety: true,
              cableType: 'FRC',
              length: Length(30)),
        ],
      ),
    ]);
    final sys = computeSystem(_p, project);
    String note(String id) => sys.warnings
        .firstWhere((w) => w.code == 'fire-pump-protection' && w.circuitId == id)
        .message;

    test('an MCCB is named by class, never with a curve letter', () {
      final fp = sys.panels['EP']!.circuits.firstWhere((c) => c.circuitId == 'fp');
      expect(fp.breaker.deviceClass, isNot(BreakerClass.mcb));
      expect(note('fp'), contains('A ${fp.breaker.deviceClass.code} device'));
      expect(note('fp'), isNot(contains('curve')));
      expect(note('fp'), contains('fire pump way'));
    });

    test('a life-safety fan is a motor way, its MCB keeps its curve', () {
      final sp = sys.panels['EP']!.circuits.firstWhere((c) => c.circuitId == 'sp');
      expect(sp.breaker.deviceClass, BreakerClass.mcb);
      expect(note('sp'), contains('life-safety motor way'));
      expect(note('sp'), isNot(contains('fire pump way')));
      expect(note('sp'), contains('curve '));
      expect(note('sp'), contains(' MCB device'));
    });
  });

  group('drawn tanks reach the equipment schedule', () {
    test('one row per tank with its own m3, never fabricated', () {
      const data = EquipmentScheduleData(
        projectName: 'p',
        date: '2026-10-18',
        tanks: [
          TankScheduleItem(tag: 'TK-01', roof: false, capacityLitres: 60000),
          TankScheduleItem(tag: 'TK-02', roof: true, capacityLitres: 20000),
          TankScheduleItem(tag: 'TK-03', roof: true),
        ],
      );
      final rows = buildEquipmentScheduleRows(data);
      expect(rows.map((r) => r.category).toSet(), {EquipmentCategory.tank});
      expect(rows.map((r) => r.tag), ['TK-01', 'TK-02', 'TK-03']);
      // 60 000 L = 60.0 m3, 20 000 L = 20.0 m3.
      expect(rows[0].duty, '60.0 m3');
      expect(rows[0].service, contains('Ground tank'));
      expect(rows[1].duty, '20.0 m3');
      expect(rows[1].service, contains('Roof tank'));
      expect(rows[2].duty, 'capacity not set');
      expect(buildEquipmentScheduleMarkdown(data), contains('## Tanks'));
    });
  });

  group('drainage-4-1: no reducer below a hand-oversized pipe', () {
    // fx (4 DFU) —br→ S1 (floor 1) —st (riser)→ S0 —bd→ out.
    Network net() => Network(nodes: [
          _n('fx', 0, 0, floor: 1, role: NodeRole.fixture),
          _n('S1', 100, 0, floor: 1),
          _n('S0', 100, 0),
          _n('out', 400, 0),
        ], edges: [
          _e('br', 'fx', 'S1', ServiceType.drainage),
          _e('st', 'S1', 'S0', ServiceType.drainage, kind: EdgeKind.riser),
          _e('bd', 'S0', 'out', ServiceType.drainage),
        ]);
    Map<String, EdgeSizing> size(Map<String, Diameter> ov) => autoSizeNetwork(
        net(), const SizingContext(),
        leafDemand: const {},
        nodeDrainageUnits: const {'fx': 4},
        sizeOverrides: ov);

    test('no override: the auto sizes carry no override-pass flag', () {
      final auto = size(const {});
      for (final id in ['br', 'st', 'bd']) {
        expect(auto[id]!.belowCodeMinimum, isFalse, reason: id);
      }
      // The building drain is never raised by the override pass.
      expect(auto['bd']!.stackRaisedForBranch, isFalse);
    });

    test('br overridden to DN150 raises the stack and the drain below', () {
      final auto = size(const {});
      expect(auto['st']!.diameter.inMillimeters, lessThan(150));
      final s = size({'br': Diameter.mm(150)});
      expect(s['br']!.diameter.inMillimeters, 150);
      expect(s['st']!.diameter.inMillimeters, 150);
      expect(s['st']!.stackRaisedForBranch, isTrue);
      expect(s['bd']!.diameter.inMillimeters, 150);
      expect(s['bd']!.stackRaisedForBranch, isTrue);
    });

    test('a hand pick below a hand pick above it is flagged, not resized', () {
      final s = size({'br': Diameter.mm(150), 'st': Diameter.mm(100)});
      expect(s['st']!.diameter.inMillimeters, 100);
      expect(s['st']!.belowCodeMinimum, isTrue);
    });

    test('property: no gravity edge is smaller than an override above it', () {
      final rnd = math.Random(4141);
      const ladder = [50.0, 65.0, 75.0, 100.0, 125.0, 150.0];
      // A 4-floor stack with a branch per floor.
      final nodes = <NetNode>[_n('out', 500, 0), _n('S0', 100, 0)];
      final edges = <NetEdge>[_e('bd', 'S0', 'out', ServiceType.drainage)];
      final dfu = <String, double>{};
      for (var f = 1; f <= 4; f++) {
        nodes
          ..add(_n('S$f', 100, 0, floor: f))
          ..add(_n('fx$f', 0, 0, floor: f, role: NodeRole.fixture));
        edges
          ..add(_e('st$f', 'S$f', 'S${f - 1}', ServiceType.drainage,
              kind: EdgeKind.riser))
          ..add(_e('br$f', 'fx$f', 'S$f', ServiceType.drainage));
        dfu['fx$f'] = 2.0 + f;
      }
      final g = Network(nodes: nodes, edges: edges);
      // Downstream chain of each edge, toward `out`.
      final down = <String, List<String>>{
        for (var f = 1; f <= 4; f++) ...{
          'br$f': [for (var k = f; k >= 1; k--) 'st$k', 'bd'],
          'st$f': [for (var k = f - 1; k >= 1; k--) 'st$k', 'bd'],
        },
      };
      for (var t = 0; t < 60; t++) {
        final ov = <String, Diameter>{};
        for (final e in edges) {
          if (rnd.nextDouble() < 0.3) {
            ov[e.id] = Diameter.mm(ladder[rnd.nextInt(ladder.length)]);
          }
        }
        final s = autoSizeNetwork(g, const SizingContext(),
            leafDemand: const {}, nodeDrainageUnits: dfu, sizeOverrides: ov);
        for (final up in ov.keys) {
          for (final d in down[up] ?? const <String>[]) {
            final ok = s[d]!.diameter.inMillimeters >=
                    ov[up]!.inMillimeters - 1e-9 ||
                (ov.containsKey(d) && s[d]!.belowCodeMinimum);
            expect(ok, isTrue, reason: 'seed $t: $up -> $d');
          }
        }
      }
    });
  });

  group('drainage-4-2: a vent stack with an offset is uniform', () {
    test('4 floors x 10 DFU, offset at floor 2: every segment DN65', () {
      // Soil stack DS0..DS3 (10 DFU per floor ⇒ 40); vent v1: V0→V1,
      // v2: V1→V2a, offset run vof: V2a→V2b, v3: V2b→V3, vtr: V3→VTR.
      // Ties: V0/V1/V2a/V3 to DS0..DS3. The VTR carries 40 DFU; UPC 703.2:
      // 24 < 40 ≤ 48 ⇒ DN65 over the whole developed length.
      final nodes = <NetNode>[_n('out', 0, 0)];
      final edges = <NetEdge>[_e('sewer', 'out', 'DS0', ServiceType.drainage)];
      final dfu = <String, double>{};
      for (var f = 0; f < 4; f++) {
        nodes
          ..add(_n('DS$f', 100, 0, floor: f))
          ..add(_n('fx$f', 200, 0, floor: f, role: NodeRole.fixture));
        dfu['fx$f'] = 10;
        edges.add(_e('fb$f', 'DS$f', 'fx$f', ServiceType.drainage));
        if (f > 0) {
          edges.add(_e('ds$f', 'DS${f - 1}', 'DS$f', ServiceType.drainage,
              kind: EdgeKind.riser));
        }
      }
      nodes.addAll([
        _n('V0', 120, 0),
        _n('V1', 120, 0, floor: 1),
        _n('V2a', 120, 0, floor: 2),
        _n('V2b', 160, 0, floor: 2),
        _n('V3', 160, 0, floor: 3),
        _n('VTR', 160, 0, floor: 4),
      ]);
      edges.addAll([
        _e('v1', 'V0', 'V1', ServiceType.vent, kind: EdgeKind.riser),
        _e('v2', 'V1', 'V2a', ServiceType.vent, kind: EdgeKind.riser),
        _e('vof', 'V2a', 'V2b', ServiceType.vent),
        _e('v3', 'V2b', 'V3', ServiceType.vent, kind: EdgeKind.riser),
        _e('vtr', 'V3', 'VTR', ServiceType.vent, kind: EdgeKind.riser),
        _e('t0', 'V0', 'DS0', ServiceType.vent),
        _e('t1', 'V1', 'DS1', ServiceType.vent),
        _e('t2', 'V2a', 'DS2', ServiceType.vent),
        _e('t3', 'V3', 'DS3', ServiceType.vent),
      ]);
      final s = autoSizeNetwork(Network(nodes: nodes, edges: edges),
          const SizingContext(),
          leafDemand: const {}, nodeDrainageUnits: dfu);
      expect(drain.ventDiameterForDfu(40).inMillimeters, 65);
      for (final id in ['v1', 'v2', 'vof', 'v3', 'vtr']) {
        expect(s[id]!.diameter.inMillimeters, 65, reason: id);
      }
      // A floor tie above the base keeps its own 10 DFU.
      expect(s['t2']!.diameter.inMillimeters,
          drain.ventDiameterForDfu(10).inMillimeters);
    });
  });

  group('drainage-4-3: the base connection adds no phantom DFU', () {
    // Soil stack: out — j1 (floor 0, the FOOT, no fixture) —riser→ DS1..DS3,
    // a fixture of 8 DFU per floor ⇒ 24 DFU. Vent stack tied at DS1..DS3.
    // The foot's net vent seed is 24 − 24 = 0. UPC 703.2: 8 < 24 ≤ 24 ⇒ DN50
    // (the phantom +2 used to make it 26 ⇒ DN65).
    Network build({required bool baseRun}) {
      final nodes = <NetNode>[_n('out', 0, 0), _n('j1', 100, 0)];
      final edges = <NetEdge>[_e('sewer', 'out', 'j1', ServiceType.drainage)];
      var below = 'j1';
      for (var f = 1; f <= 3; f++) {
        nodes
          ..add(_n('DS$f', 100, 0, floor: f))
          ..add(_n('fx$f', 200, 0, floor: f, role: NodeRole.fixture))
          ..add(_n('V$f', 120, 0, floor: f));
        edges
          ..add(_e('ds$f', below, 'DS$f', ServiceType.drainage,
              kind: EdgeKind.riser))
          ..add(_e('fb$f', 'DS$f', 'fx$f', ServiceType.drainage))
          ..add(_e('t$f', 'V$f', 'DS$f', ServiceType.vent));
        if (f > 1) {
          edges.add(_e('v$f', 'V${f - 1}', 'V$f', ServiceType.vent,
              kind: EdgeKind.riser));
        }
        below = 'DS$f';
      }
      nodes.add(_n('VTR', 120, 0, floor: 4));
      edges.add(_e('vtr', 'V3', 'VTR', ServiceType.vent, kind: EdgeKind.riser));
      if (baseRun) {
        nodes.add(_n('Vb', 120, 0));
        edges
          ..add(_e('vbr', 'j1', 'Vb', ServiceType.vent))
          ..add(_e('v1', 'Vb', 'V1', ServiceType.vent, kind: EdgeKind.riser));
      } else {
        edges.add(_e('v1', 'j1', 'V1', ServiceType.vent, kind: EdgeKind.riser));
      }
      return Network(nodes: nodes, edges: edges);
    }

    const dfu = {'fx1': 8.0, 'fx2': 8.0, 'fx3': 8.0};
    test('vent riser from the foot: the stack is DN50 on 24 DFU', () {
      final fu = <String, double>{};
      final s = autoSizeNetwork(build(baseRun: false), const SizingContext(),
          leafDemand: const {}, nodeDrainageUnits: dfu, fixtureUnitsOut: fu);
      expect(drain.ventDiameterForDfu(24).inMillimeters, 50);
      for (final id in ['v1', 'v2', 'v3', 'vtr']) {
        expect(fu[id], 24, reason: id);
        expect(s[id]!.diameter.inMillimeters, 50, reason: id);
      }
    });

    test('a horizontal base run carries the stack size, not 2 DFU', () {
      final fu = <String, double>{};
      final s = autoSizeNetwork(build(baseRun: true), const SizingContext(),
          leafDemand: const {}, nodeDrainageUnits: dfu, fixtureUnitsOut: fu);
      expect(fu['vbr'], 24);
      expect(s['vbr']!.diameter.inMillimeters, 50);
      expect(s['vtr']!.diameter.inMillimeters, 50);
    });
  });

  group('drainage-4-4: an individually vented fixture has a ~0 trap arm', () {
    test('a vent at the fixture node itself ends the walk', () {
      final nodes = [
        _n('lv', 0, 0, floor: 1, role: NodeRole.fixture),
        _n('st', 600, 0, floor: 1),
        _n('base', 600, 0),
        _n('lvV', 0, 0, floor: 2),
      ];
      final edges = [
        _e('br', 'lv', 'st', ServiceType.drainage),
        _e('stack', 'st', 'base', ServiceType.drainage, kind: EdgeKind.riser),
        _e('iv', 'lv', 'lvV', ServiceType.vent, kind: EdgeKind.riser),
      ];
      final net = Network(nodes: nodes, edges: edges);
      final sizing = autoSizeNetwork(net, const SizingContext(),
          leafDemand: const {}, nodeDrainageUnits: const {'lv': 1});
      final runs =
          trapArmRuns(net: net, sizing: sizing, lengthOf: (_) => 6.0);
      final lv = runs.firstWhere((r) => r.fixtureNodeId == 'lv');
      expect(lv.developedLengthM, 0);
      // Without the individual vent the same 6 m arm is reported.
      final bare = Network(nodes: nodes, edges: edges.sublist(0, 2));
      final bareSizing = autoSizeNetwork(bare, const SizingContext(),
          leafDemand: const {}, nodeDrainageUnits: const {'lv': 1});
      expect(
          trapArmRuns(net: bare, sizing: bareSizing, lengthOf: (_) => 6.0)
              .firstWhere((r) => r.fixtureNodeId == 'lv')
              .developedLengthM,
          6.0);
    });
  });
}
