/// MODULE-AUDIT wave-A app-side wiring: the sizing flags the engine computes
/// are now CONSUMED, the terminal velocity judge stops warning about faces that
/// cannot be changed, `autoPlaceRoomTerminals` places the whole return bank, and
/// the three previously-dark design inputs (drainage slope, hot-water flow /
/// ΔT, cooling-load basis) are real.
///
/// Every expected value is hand-derived from first principles in the comment
/// above its assertion, or read back from the engine's own primitives where the
/// test is orchestration-level.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/data/project_document.dart';
import 'package:mechx/store/air_warnings_store.dart';
import 'package:mechx/store/annotation_store.dart';
import 'package:mechx/store/app_state.dart';
import 'package:mechx/store/design_issues_store.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/sheets_store.dart';
import 'package:mechx/store/sizing_store.dart';
import 'package:mechx/store/solve_store.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/air_velocity.dart';
import 'package:mechx_engine/standards/sni.dart' show PlumbingFixture;
import 'package:mechx_engine/standards/ventilation.dart' show RoomType;
import 'package:mechx_engine/units.dart';

ProviderContainer _container() {
  final c = ProviderContainer();
  addTearDown(c.dispose);
  return c;
}

/// A calibrated sheet `s1` at [metersPerPixel] so drawn runs have real length.
void _calibrate(ProviderContainer c, {double metersPerPixel = 0.1}) {
  c.read(projectControllerProvider.notifier).setCalibration(
        's1',
        ScaleCalibration(metersPerPixel),
      );
}

void main() {
  // ───────────────────────────────────────────────────────────────────────────
  // M10 — autoPlaceRoomTerminals places the WHOLE return bank.
  // ───────────────────────────────────────────────────────────────────────────
  group('M10 auto-place drops every sized return grille', () {
    test('a 600 m2 office hall places 4 supply diffusers AND 4 return grilles',
        () {
      final c = _container();
      final n = c.read(networkControllerProvider.notifier);

      // 300 x 200 px at 0.1 m/px = 30 m x 20 m = 600 m^2, default 3 m ceiling,
      // default office room type:
      //   volume        = 600 * 3                       = 1800 m^3
      //   office ACH    = 6.0  (SNI 03-6572-2001 Tabel 4.4.1)
      //   Q             = 1800 * 6 / 3600               = 3.0 m^3/s
      //   max per face  = 0.36 (600x600) * 0.8 free * 3.0 (office) = 0.864
      //   count         = ceil(3.0 / 0.864) = ceil(3.472)          = 4
      //   each          = 3.0 / 4                                  = 0.75 m^3/s
      //   face: smallest std gross >= (0.75/3.0)/0.8 = 0.3125 m^2 -> 600x600
      // Supply and return banks are sized by the SAME call, so both are 4.
      const room = RoomArea(
        id: 'r0',
        sheetId: 's1',
        floorIndex: 0,
        ax: 0,
        ay: 0,
        bx: 300,
        by: 200,
      );
      final ids = n.autoPlaceRoomTerminals(room: room, metersPerPixel: 0.1);
      expect(ids.length, 4, reason: '4 supply diffusers for 3.0 m^3/s');

      final net = c.read(networkControllerProvider).network;
      final supplies = net.nodes
          .where((nd) => nd.component == NodeComponent.supplyDiffuser)
          .toList();
      final returns = net.nodes
          .where((nd) => nd.component == NodeComponent.returnGrille)
          .toList();
      expect(supplies.length, 4);
      // The bug: ONE grille was placed carrying `airflowEach`, so 3 of the 4
      // sized returns (75 % of the return air) never entered the network.
      expect(returns.length, 4, reason: 'the whole return bank is placed');

      // Each return carries the per-terminal airflow and the chosen face...
      for (final r in returns) {
        expect(r.airflow!.cubicMetersPerSecond, closeTo(0.75, 1e-9));
        expect(r.faceWidthMm, 600);
        expect(r.faceHeightMm, 600);
        expect(r.role, NodeComponent.returnGrille.role);
        // ...and sits inside the room footprint on its sheet/floor.
        expect(r.sheetId, 's1');
        expect(r.floorIndex, 0);
        expect(r.x, inInclusiveRange(0, 300));
        expect(r.y, inInclusiveRange(0, 200));
      }
      // ...so the placed return air now equals the room's design airflow.
      final placedReturn = returns.fold<double>(
          0, (a, r) => a + r.airflow!.cubicMetersPerSecond);
      expect(placedReturn, closeTo(3.0, 1e-9));

      // Still ONE undo step for the whole placement.
      expect(n.canUndo, isTrue);
      n.undo();
      expect(c.read(networkControllerProvider).network.nodes, isEmpty);
    });

    test('a single-return room still places it at the footprint centre', () {
      final c = _container();
      final n = c.read(networkControllerProvider.notifier);
      // 100 x 50 px at 0.1 = 10 m x 5 m = 50 m^2 -> Q = 0.25 m^3/s -> count 1
      // (0.25 <= 0.864). With count == 1 the grid is 1x1, whose only cell
      // centre is (loX + w/2, loY + h/2) — exactly where the single grille was
      // placed before, so this case is byte-identical.
      const room = RoomArea(
        id: 'r0',
        sheetId: 's1',
        floorIndex: 0,
        ax: 100,
        ay: 100,
        bx: 200,
        by: 150,
      );
      n.autoPlaceRoomTerminals(room: room, metersPerPixel: 0.1);
      final returns = c
          .read(networkControllerProvider)
          .network
          .nodes
          .where((nd) => nd.component == NodeComponent.returnGrille)
          .toList();
      expect(returns.length, 1);
      expect(returns.single.x, 150);
      expect(returns.single.y, 125);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // M7 — the smallest catalogue face is not judged too-low (no smaller exists).
  // ───────────────────────────────────────────────────────────────────────────
  group('M7 terminal face velocity at the smallest catalogue face', () {
    NetNode diffuser(double airflow, double w, double h) => NetNode(
          id: 'd',
          sheetId: 's1',
          x: 0,
          y: 0,
          floorIndex: 0,
          role: NodeRole.fixture,
          component: NodeComponent.supplyDiffuser,
          airflow: FlowRate(airflow),
          faceWidthMm: w,
          faceHeightMm: h,
        );

    test('the catalogue minimum is 150 x 150', () {
      expect(kSmallestGrilleFaceMm, (150.0, 150.0));
    });

    test('a 150x150 face below 1.0 m/s is NOT warned (no smaller face exists)',
        () {
      final c = _container();
      // 150x150 gross = 0.0225 m^2; free = 0.8 * 0.0225 = 0.018 m^2.
      // v = 0.005 / 0.018 = 0.278 m/s — under the 1.0 m/s supply-face minimum,
      // but the engine itself stamps this face (nothing smaller is stocked), so
      // the warning was unactionable.
      c
          .read(networkControllerProvider.notifier)
          .loadNetwork(Network(nodes: [diffuser(0.005, 150, 150)]));
      final check = c.read(airVelocityChecksProvider)['d']!;
      expect(check.actual.metersPerSecond, closeTo(0.2778, 1e-3));
      expect(check.verdict, VelocityBandVerdict.ok);
      expect(check.isWarning, isFalse);
      expect(c.read(airWarningCountProvider), 0);
    });

    test('a LARGER manually-chosen face at the same low velocity still warns',
        () {
      final c = _container();
      // 300x300 gross = 0.09 m^2; free = 0.072 m^2; v = 0.05 / 0.072 = 0.694
      // m/s < 1.0 — and here a smaller face (150x150, or 300x150) IS available,
      // so the too-low verdict is actionable and is kept.
      c
          .read(networkControllerProvider.notifier)
          .loadNetwork(Network(nodes: [diffuser(0.05, 300, 300)]));
      final check = c.read(airVelocityChecksProvider)['d']!;
      expect(check.actual.metersPerSecond, closeTo(0.6944, 1e-3));
      expect(check.verdict, VelocityBandVerdict.tooLow);
    });

    test('a 150x150 face that is too FAST is still warned (deliberate)', () {
      final c = _container();
      // 0.2 / 0.018 = 11.1 m/s >> 3.0. At the smallest face a too-HIGH verdict
      // is actionable (choose a bigger face / split the airflow), so only the
      // too-LOW branch is suppressed above — not the whole check.
      c
          .read(networkControllerProvider.notifier)
          .loadNetwork(Network(nodes: [diffuser(0.2, 150, 150)]));
      expect(c.read(airVelocityChecksProvider)['d']!.verdict,
          VelocityBandVerdict.tooHigh);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // Flag fan-ins: over-capacity (beyond air), self-cleansing, water velocity.
  // ───────────────────────────────────────────────────────────────────────────
  group('wave-1 sizing flags reach the Review list', () {
    test('a storm downpipe past the largest table size is a locatable warning',
        () {
      final c = _container();
      _calibrate(c);
      c.read(sheetsControllerProvider.notifier).loadDemoSheets();
      // A roof drain with a 5000 m^2 catchment at the default 200 mm/hr and
      // C = 0.9 (rational method):
      //   Q = C * i * A / 3.6e6 = 0.9 * 200 * 5000 / 3.6e6 = 0.25 m^3/s
      //     = 250 L/s, far past the largest tabulated downpipe (DN200, 65 L/s)
      // so the sizer clamps to DN200 and raises EdgeSizing.overCapacity.
      const drain = NetNode(
        id: 'rd',
        sheetId: 's1',
        x: 0,
        y: 0,
        floorIndex: 0,
        role: NodeRole.fixture,
        roofAreaM2: 5000,
      );
      const outlet =
          NetNode(id: 'out', sheetId: 's1', x: 200, y: 0, floorIndex: 0);
      const pipe = NetEdge(
        id: 'dp',
        fromId: 'rd',
        toId: 'out',
        service: ServiceType.rainwater,
      );
      c.read(networkControllerProvider.notifier).loadNetwork(
          const Network(nodes: [drain, outlet], edges: [pipe]));

      final sizing = c.read(sizingProvider)['dp']!;
      expect(sizing.flow.inLitersPerSecond, closeTo(250.0, 1e-6));
      expect(sizing.overCapacity, isTrue, reason: 'engine flag (M3)');

      // The discipline-neutral provider the on-plan red triangle now reads.
      expect(c.read(overCapacityEdgesProvider), contains('dp'));
      // ...and the air-only view deliberately does NOT (it stays air-scoped).
      expect(c.read(airOverCapacityProvider), isEmpty);

      final issue = c
          .read(designIssuesProvider)
          .firstWhere((i) => i.kind == 'storm-over-capacity');
      expect(issue.severity, IssueSeverity.warning);
      expect(issue.title, 'Downpipe over capacity');
      expect(issue.message, contains('roof outlets'));
      expect(issue.locate!.edgeId, 'dp');
      expect(issue.locate!.sheetId, 's1');
    });

    test('an oversize AIR duct keeps its own duct-over-capacity issue', () {
      final c = _container();
      _calibrate(c);
      c.read(sheetsControllerProvider.notifier).loadDemoSheets();
      // 20 m^3/s through one duct: no standard round duct (<= 1000 mm) holds it
      // within the velocity band, so the sizer clamps and flags. The widened
      // fan-in must still route an AIR edge to the DUCT message, not the new
      // water/storm ones.
      c.read(networkControllerProvider.notifier).loadNetwork(const Network(
            nodes: [
              NetNode(
                id: 'ahu',
                sheetId: 's1',
                x: 0,
                y: 0,
                floorIndex: 0,
                role: NodeRole.plant,
                component: NodeComponent.ahu,
              ),
              NetNode(
                id: 'd',
                sheetId: 's1',
                x: 100,
                y: 0,
                floorIndex: 0,
                role: NodeRole.fixture,
                component: NodeComponent.supplyDiffuser,
                airflow: FlowRate(20.0),
                faceWidthMm: 600,
                faceHeightMm: 600,
              ),
            ],
            edges: [
              NetEdge(
                  id: 'duct',
                  fromId: 'ahu',
                  toId: 'd',
                  service: ServiceType.duct),
            ],
          ));
      final issues = c.read(designIssuesProvider);
      final issue =
          issues.firstWhere((i) => i.kind == 'duct-over-capacity');
      expect(issue.title, 'Duct over capacity');
      expect(issue.locate!.edgeId, 'duct');
      expect(issues.where((i) => i.kind == 'storm-over-capacity'), isEmpty);
      expect(issues.where((i) => i.kind == 'water-over-capacity'), isEmpty);
    });

    test('a drainage branch AT the DFU minimum raises NO self-cleansing '
        'advisory (G1 — no smaller compliant pipe exists)', () {
      final c = _container();
      _calibrate(c);
      c.read(sheetsControllerProvider.notifier).loadDemoSheets();
      // A lavatory branch (DFU 1) sizes to the branch table's minimum, DN40,
      // and at the default 1:100 laid slope with Manning n = 0.010 the
      // full-bore velocity is v = (1/n) * R^(2/3) * S^(1/2) with R = D/4:
      //   DN40 -> R = 0.0100 -> R^(2/3) = 0.0464 -> v = 100*0.0464*0.1 = 0.46
      // — under the 0.6 m/s self-cleansing floor. It is the smallest pipe the
      // DFU table allows, so no pipe change can fix it: the engine leaves the
      // flag true and the Review list stays quiet about it (the real levers,
      // the laid slope and the grouped discharge, are separate inputs).
      const basin = NetNode(
        id: 'wb',
        sheetId: 's1',
        x: 0,
        y: 0,
        floorIndex: 0,
        role: NodeRole.fixture,
        fixture: PlumbingFixture.lavatory,
      );
      const stack =
          NetNode(id: 'st', sheetId: 's1', x: 100, y: 0, floorIndex: 0);
      const branch = NetEdge(
        id: 'br',
        fromId: 'wb',
        toId: 'st',
        service: ServiceType.drainage,
      );
      c.read(networkControllerProvider.notifier).loadNetwork(
          const Network(nodes: [basin, stack], edges: [branch]));

      final sizing = c.read(sizingProvider)['br']!;
      expect(sizing.diameter.inMillimeters, closeTo(40, 1e-9));
      expect(sizing.velocity.metersPerSecond, lessThan(0.6));
      expect(sizing.selfCleansingOk, isTrue, reason: 'at the DFU minimum (G1)');
      expect(c.read(selfCleansingDefectsProvider), isEmpty);

      final issues = c.read(designIssuesProvider);
      expect(issues.where((i) => i.kind == 'drainage-self-cleansing'), isEmpty);
      // …and the gravity TOO-LOW velocity must not leak out as the other row
      // either: the edge inspector still reports it honestly, but neither
      // Review row can name an action here.
      expect(issues.where((i) => i.kind.startsWith('water-velocity:')), isEmpty);
      expect(c.read(waterVelocityChecksProvider)['br']!.verdict,
          VelocityBandVerdict.tooLow);
    });

    test('a drainage branch hand-sized ABOVE the DFU minimum IS a locatable '
        'self-cleansing advisory, reported ONCE', () {
      final c = _container();
      _calibrate(c);
      c.read(sheetsControllerProvider.notifier).loadDemoSheets();
      // Same lavatory branch (DFU 1 ⇒ DN40 minimum), but hand-picked at DN50:
      //   DN50 -> R = 0.0125 -> R^(2/3) = 0.0539 -> v = 100*0.0539*0.1 = 0.54
      // still under 0.6 m/s — and now it IS actionable by pipe (DN40 is
      // compliant and runs faster), so the advisory fires.
      const basin = NetNode(
        id: 'wb',
        sheetId: 's1',
        x: 0,
        y: 0,
        floorIndex: 0,
        role: NodeRole.fixture,
        fixture: PlumbingFixture.lavatory,
      );
      const stack =
          NetNode(id: 'st', sheetId: 's1', x: 100, y: 0, floorIndex: 0);
      const branch = NetEdge(
        id: 'br',
        fromId: 'wb',
        toId: 'st',
        service: ServiceType.drainage,
        sizeOverride: Diameter(0.050),
      );
      c.read(networkControllerProvider.notifier).loadNetwork(
          const Network(nodes: [basin, stack], edges: [branch]));

      final sizing = c.read(sizingProvider)['br']!;
      expect(sizing.diameter.inMillimeters, closeTo(50, 1e-9));
      expect(sizing.velocity.metersPerSecond, lessThan(0.6));
      expect(sizing.selfCleansingOk, isFalse, reason: 'engine flag (M5/G1)');
      expect(c.read(selfCleansingDefectsProvider), contains('br'));

      final issues = c.read(designIssuesProvider);
      final advisory =
          issues.where((i) => i.kind == 'drainage-self-cleansing').toList();
      expect(advisory.length, 1);
      expect(advisory.single.severity, IssueSeverity.info);
      expect(advisory.single.message, contains('0.6 m/s'));
      // G1 — the copy names the levers the app actually has, and no longer
      // advises the smaller pipe the DFU table forbids.
      expect(advisory.single.message, contains('drainage slope'));
      expect(advisory.single.message, isNot(contains('smaller pipe')));
      expect(advisory.single.locate!.edgeId, 'br');

      // The same physics must not ALSO print as a water-velocity warning: the
      // gravity band's minimum IS this self-cleansing floor.
      expect(issues.where((i) => i.kind.startsWith('water-velocity:')), isEmpty);
      // ...but the edge inspector's own verdict IS now honest about it (M5:
      // it used to read OK against an unreachable 3.0 m/s ceiling).
      expect(c.read(waterVelocityChecksProvider)['br']!.verdict,
          VelocityBandVerdict.tooLow);
    });

    test('an over-velocity pressurized run fans in as a water-velocity warning',
        () {
      final c = _container();
      _calibrate(c);
      c.read(sheetsControllerProvider.notifier).loadDemoSheets();
      // Four flush-valve WCs on a hand-pinned DN10 cold-water run: whatever the
      // diversified demand works out to, v = Q/A at 10 mm is far past the
      // sniVerbatim 2,0 m/s supply cap. The velocity is read back from the
      // engine (orchestration-level test) rather than re-derived here.
      final nodes = <NetNode>[
        const NetNode(
          id: 'src',
          sheetId: 's1',
          x: 0,
          y: 0,
          floorIndex: 0,
          role: NodeRole.plant,
        ),
        for (var i = 0; i < 4; i++)
          NetNode(
            id: 'wc$i',
            sheetId: 's1',
            x: 100.0 * (i + 1),
            y: 0,
            floorIndex: 0,
            role: NodeRole.fixture,
            fixture: PlumbingFixture.waterClosetFlushValve,
          ),
      ];
      final edges = <NetEdge>[
        const NetEdge(
          id: 'main',
          fromId: 'src',
          toId: 'wc0',
          service: ServiceType.coldWater,
          sizeOverride: Diameter(0.010),
        ),
        for (var i = 1; i < 4; i++)
          NetEdge(
            id: 'b$i',
            fromId: 'wc${i - 1}',
            toId: 'wc$i',
            service: ServiceType.coldWater,
          ),
      ];
      c
          .read(networkControllerProvider.notifier)
          .loadNetwork(Network(nodes: nodes, edges: edges));

      final v = c.read(sizingProvider)['main']!.velocity.metersPerSecond;
      expect(v, greaterThan(2.0), reason: 'over the SNI supply cap');

      final issue = c
          .read(designIssuesProvider)
          .firstWhere((i) => i.kind == 'water-velocity:main');
      expect(issue.severity, IssueSeverity.warning);
      expect(issue.title, 'Pipe velocity out of band');
      expect(issue.message, contains('too high'));
      expect(issue.locate!.edgeId, 'main');
      expect(issue.locate!.sheetId, 's1');
    });

    test('a clean project raises none of the new flag issues', () {
      final c = _container();
      _calibrate(c);
      c.read(sheetsControllerProvider.notifier).loadDemoSheets();
      const kinds = {
        'storm-over-capacity',
        'water-over-capacity',
        'drainage-self-cleansing',
        'loop-unbalanced',
        'pump-motor-oversized',
        'fan-motor-oversized',
      };
      final issues = c.read(designIssuesProvider);
      expect(issues.where((i) => kinds.contains(i.kind)), isEmpty);
      expect(issues.where((i) => i.kind.startsWith('water-velocity:')), isEmpty);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // M13/M14 — the dark thresholds become reachable design inputs.
  // ───────────────────────────────────────────────────────────────────────────
  group('M13 the drainage slope input reaches the min-slope advisory', () {
    void seedDrainage(ProviderContainer c) {
      _calibrate(c);
      c.read(sheetsControllerProvider.notifier).loadDemoSheets();
      c.read(networkControllerProvider.notifier).loadNetwork(const Network(
            nodes: [
              NetNode(
                id: 'wb',
                sheetId: 's1',
                x: 0,
                y: 0,
                floorIndex: 0,
                role: NodeRole.fixture,
                fixture: PlumbingFixture.lavatory,
              ),
              NetNode(id: 'st', sheetId: 's1', x: 100, y: 0, floorIndex: 0),
            ],
            edges: [
              NetEdge(
                id: 'br',
                fromId: 'wb',
                toId: 'st',
                service: ServiceType.drainage,
              ),
            ],
          ));
    }

    test('at the 1:100 default the advisory is silent (its threshold is 1:200)',
        () {
      final c = _container();
      seedDrainage(c);
      expect(c.read(drainageSlopeProvider), 0.01);
      expect(
          c.read(designIssuesProvider).where((i) => i.kind == 'drainage-slope'),
          isEmpty);
    });

    test('laying the branch at 1:250 trips it, and re-sizes on that gradient',
        () {
      final c = _container();
      seedDrainage(c);
      final vBefore = c.read(sizingProvider)['br']!.velocity.metersPerSecond;

      // 1:250 = 0.004 m/m, under the engine's 0.005 minimum-slope threshold.
      c.read(drainageSlopeProvider.notifier).set(0.004);
      expect(c.read(drainageSlopeProvider), 0.004);

      final advisory = c
          .read(designIssuesProvider)
          .firstWhere((i) => i.kind == 'drainage-slope');
      expect(advisory.severity, IssueSeverity.info);
      expect(advisory.locate!.edgeId, 'br');

      // The slope also reaches the SIZER: v scales with sqrt(S), so dropping
      // 0.01 -> 0.004 scales the Manning velocity by sqrt(0.4) = 0.6325.
      final vAfter = c.read(sizingProvider)['br']!.velocity.metersPerSecond;
      expect(vAfter, closeTo(vBefore * 0.632455, 1e-6));
    });
  });

  group('M14 the hot-water inputs reach the Legionella check', () {
    void seedHotWater(ProviderContainer c) {
      _calibrate(c);
      c.read(sheetsControllerProvider.notifier).loadDemoSheets();
      c.read(networkControllerProvider.notifier).loadNetwork(const Network(
            nodes: [
              NetNode(
                id: 'hw0',
                sheetId: 's1',
                x: 0,
                y: 0,
                floorIndex: 0,
                role: NodeRole.plant,
              ),
              NetNode(
                id: 'hw1',
                sheetId: 's1',
                x: 300,
                y: 0,
                floorIndex: 0,
                role: NodeRole.fixture,
                fixture: PlumbingFixture.lavatory,
              ),
            ],
            edges: [
              NetEdge(
                id: 'hw',
                fromId: 'hw0',
                toId: 'hw1',
                service: ServiceType.hotWater,
              ),
            ],
          ));
    }

    test('at the 60 C / 5 K defaults the return models 55 C — no risk', () {
      final c = _container();
      seedHotWater(c);
      expect(c.read(hotWaterFlowTempProvider), 60.0);
      expect(c.read(hotWaterDeltaTProvider), 5.0);
      // 60 - 5 = 55 exactly, and the check is `< 55` ⇒ never true. This is the
      // documented reason the advisory was dark.
      expect(c.read(hotWaterRecircProvider)!.returnTempC, closeTo(55.0, 1e-9));
      expect(c.read(hotWaterLegionellaProvider), isNull);
      expect(c.read(designIssuesProvider).where((i) => i.kind == 'legionella'),
          isEmpty);
    });

    test('storing at 55 C models a 50 C return and raises the advisory', () {
      final c = _container();
      seedHotWater(c);
      c.read(hotWaterFlowTempProvider.notifier).set(55);
      // 55 - 5 = 50 C < the 55 C anti-Legionella floor.
      expect(c.read(hotWaterRecircProvider)!.returnTempC, closeTo(50.0, 1e-9));
      expect(c.read(hotWaterLegionellaProvider), closeTo(50.0, 1e-9));
      final issue = c
          .read(designIssuesProvider)
          .firstWhere((i) => i.kind == 'legionella');
      expect(issue.severity, IssueSeverity.info);
      expect(issue.message, contains('50'));
    });

    test('a 10 K allowable drop from 60 C also trips it (50 C return)', () {
      final c = _container();
      seedHotWater(c);
      c.read(hotWaterDeltaTProvider.notifier).set(10);
      expect(c.read(hotWaterRecircProvider)!.returnTempC, closeTo(50.0, 1e-9));
      expect(c.read(hotWaterLegionellaProvider), closeTo(50.0, 1e-9));
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // M15 — the cooling-load basis dispatches to the detailed estimator.
  // ───────────────────────────────────────────────────────────────────────────
  group('M15 cooling-load basis', () {
    // 100 x 50 px at 0.1 m/px = 10 m x 5 m = 50 m^2, 3.0 m ceiling, office.
    const room = RoomArea(
      id: 'r0',
      sheetId: 's1',
      floorIndex: 0,
      ax: 0,
      ay: 0,
      bx: 100,
      by: 50,
      roomType: RoomType.office,
    );

    test('simple = area x office density x ceiling correction', () {
      // 50 m^2 * 600 BTU/h/m^2 * (3.0 / 3.0) = 30 000 BTU/h.
      final load = room.coolingLoad(0.1)!;
      expect(load.btuPerHr, closeTo(30000.0, 1e-6));
    });

    test('detailed sums the real heat-gain streams (hand-derived)', () {
      // occupants        = round(0.1 /m^2 * 50 m^2)          = 5
      //   people sensible = 5 * 75                           =  375 W
      //   people latent   = 5 * 55                           =  275 W
      // lighting          = 10 W/m^2 * 50                    =  500 W
      // equipment         = 12 W/m^2 * 50                    =  600 W
      // ventilation V     = 50 * 3.0 * 1.0 ACH / 3600        = 0.0416667 m^3/s
      //   sensible        = 1.2 * 1005 * 0.0416667 * 9.0 K   =  452.25 W
      //   latent          = 1.2 * 2.45e6 * 0.0416667 * 0.010 = 1225.00 W
      // envelope (wall/roof/glass) = 0 — a rectangular room annotation carries
      // no facade, so nothing is invented there.
      //   sensible total  = 375 + 500 + 600 + 452.25         = 1927.25 W
      //   latent total    = 275 + 1225                       = 1500.00 W
      //   TOTAL                                              = 3427.25 W
      final load =
          room.coolingLoad(0.1, method: CoolingLoadMethod.detailed)!;
      expect(load.watts, closeTo(3427.25, 1e-6));
      // A genuinely different basis, not a relabelled simple estimate.
      expect(load.btuPerHr, isNot(closeTo(30000.0, 1.0)));
    });

    test('roomCoolingLoadProvider follows coolingLoadMethodProvider', () {
      final c = _container();
      _calibrate(c);
      c.read(roomAreasProvider.notifier).set(const [room]);

      // Default basis ⇒ the area-density figure.
      expect(c.read(coolingLoadMethodProvider), CoolingLoadMethod.simple);
      expect(c.read(roomCoolingLoadProvider('r0'))!.btuPerHr,
          closeTo(30000.0, 1e-6));

      // Switching the project setting switches the basis for every consumer.
      c
          .read(coolingLoadMethodProvider.notifier)
          .set(CoolingLoadMethod.detailed);
      expect(c.read(roomCoolingLoadProvider('r0'))!.watts,
          closeTo(3427.25, 1e-6));

      // An unknown room id ⇒ null (never a fabricated load).
      expect(c.read(roomCoolingLoadProvider('nope')), isNull);
    });

    test('an uncalibrated sheet yields no load (no scale ⇒ no area)', () {
      final c = _container();
      c.read(roomAreasProvider.notifier).set(const [room]);
      expect(c.read(roomCoolingLoadProvider('r0')), isNull);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // R6 — dead settings dropped, live settings persisted.
  // ───────────────────────────────────────────────────────────────────────────
  group('R6 DesignSettings: dead multi-zone fields dropped', () {
    Map<String, dynamic> settingsJsonOf(DesignSettings s) =>
        s.toJson().cast<String, dynamic>();

    test('an encoded document carries neither dropped multi-zone key', () {
      final json = settingsJsonOf(const DesignSettings());
      expect(json.containsKey('multiZoneDiversityFactor'), isFalse);
      expect(json.containsKey('multiZoneExhaustStrategy'), isFalse);
      // The basis that IS wired stays.
      expect(json['coolingLoadMethod'], 'simple');
    });

    test('the live design inputs round-trip at their engine defaults', () {
      final json = settingsJsonOf(const DesignSettings());
      expect(json['drainageSlope'], 0.01);
      expect(json['hotWaterFlowTempC'], 60.0);
      expect(json['hotWaterDeltaTK'], 5.0);

      final back = DesignSettings.fromJson(settingsJsonOf(const DesignSettings(
        drainageSlope: 0.004,
        hotWaterFlowTempC: 55,
        hotWaterDeltaTK: 10,
        coolingLoadMethod: 'detailed',
      )));
      expect(back.drainageSlope, 0.004);
      expect(back.hotWaterFlowTempC, 55);
      expect(back.hotWaterDeltaTK, 10);
      expect(back.coolingLoadMethod, 'detailed');
    });

    test('a LEGACY document still carrying the multi-zone keys loads fine', () {
      // The tolerant decoder ignores unknown keys, so a `.mechx` written by a
      // build that persisted the dead settings opens unchanged — the stale keys
      // are simply dropped on the next save.
      final legacy = DesignSettings.fromJson(<String, dynamic>{
        'occupancy': 'public',
        'coolingLoadMethod': 'detailed',
        'multiZoneDiversityFactor': 0.75,
        'multiZoneExhaustStrategy': 'balanced',
      });
      expect(legacy.coolingLoadMethod, 'detailed');
      expect(legacy.drainageSlope, 0.01, reason: 'absent ⇒ engine default');
      expect(legacy.hotWaterFlowTempC, 60.0);
      expect(legacy.hotWaterDeltaTK, 5.0);
      expect(settingsJsonOf(legacy).containsKey('multiZoneDiversityFactor'),
          isFalse);
    });

    test('hand-edited out-of-band values are clamped, not trusted', () {
      final s = DesignSettings.fromJson(<String, dynamic>{
        'drainageSlope': 99.0,
        'hotWaterFlowTempC': 500.0,
        'hotWaterDeltaTK': 0.0,
      });
      expect(s.drainageSlope, 0.1);
      expect(s.hotWaterFlowTempC, 90.0);
      expect(s.hotWaterDeltaTK, 1.0);
    });
  });
}
