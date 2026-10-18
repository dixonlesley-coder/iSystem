/// ROUND 11 (2026-10-18) — HVAC network duties + copilot safety.
///
///   hvac-network-1  a fan / pump delivers the flow LEAVING its source node
///                   (every trunk out of an AHU), not the single largest edge;
///   hvac-network-4  every connected air system gets its own fan duty;
///   hvac-network-2  a toilet / kitchen auto-places EXHAUST grilles only;
///   copilot-safety  malformed / non-finite / off-sheet / wrong-floor commands
///                   are rejected, a throwing client never strands the panel,
///                   and a no-op auto-place is never counted as applied.
library;

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/widgets.dart' show WidgetsFlutterBinding;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/ai/ai_client.dart';
import 'package:mechx/ai/commands.dart';
import 'package:mechx/ai/openai_client.dart';
import 'package:mechx/data/autosave.dart';
import 'package:mechx/store/ai_copilot_store.dart';
import 'package:mechx/store/annotation_store.dart';
import 'package:mechx/store/electrical_feed.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/store/sheets_store.dart';
import 'package:mechx/store/sizing_store.dart';
import 'package:mechx/store/solve_store.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/duct_static.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/fan.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/sizing/room_air.dart';
import 'package:mechx_engine/standards/sni.dart';
import 'package:mechx_engine/standards/ventilation.dart';
import 'package:mechx_engine/units.dart';

NetNode _n(String id, double x,
        {String sheet = 's1',
        int floor = 0,
        FlowRate? airflow,
        NodeComponent? component}) =>
    NetNode(
      id: id,
      sheetId: sheet,
      x: x,
      y: 0,
      floorIndex: floor,
      role: component?.role ?? NodeRole.main,
      component: component,
      airflow: airflow,
    );

ProviderContainer _with(Network net) {
  final c = ProviderContainer();
  c.read(projectControllerProvider.notifier)
    ..setCalibration('s1', const ScaleCalibration(0.01))
    ..setCalibration('s2', const ScaleCalibration(0.01));
  c.read(networkControllerProvider.notifier).loadNetwork(net);
  return c;
}

Pressure _static(ProviderContainer c, ServiceType service, String fan) {
  final sizing = c.read(sizingProvider);
  final project = c.read(projectControllerProvider);
  return solveDuctStatic(
    net: c.read(sizingNetworkProvider),
    service: service,
    fanNodeId: fan,
    edgeFlows: {for (final e in sizing.entries) e.key: e.value.flow},
    sizing: sizing,
    calibrationBySheet: project.calibrations,
    building: project.building,
    mounting: project.mounting,
  ).totalStaticPressure;
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // ── hvac-network-1 ─────────────────────────────────────────────────────────
  group('hvac-network-1 — an AHU feeding two trunks delivers BOTH', () {
    // AHU mid-corridor at x = 2000 px (20 m), two 20 m Ø ducts to diffusers of
    // 0.5 m³/s each at x = 0 and x = 4000 px.
    const q = FlowRate(0.5);
    final net = Network(
      nodes: [
        _n('ahu', 2000, component: NodeComponent.ahu),
        _n('d1', 0, airflow: q, component: NodeComponent.supplyDiffuser),
        _n('d2', 4000, airflow: q, component: NodeComponent.supplyDiffuser),
      ],
      edges: const [
        NetEdge(id: 'e1', fromId: 'ahu', toId: 'd1', service: ServiceType.duct),
        NetEdge(id: 'e2', fromId: 'ahu', toId: 'd2', service: ServiceType.duct),
      ],
    );

    test('the fan airflow is 1.0 m³/s (Σ of the root-incident trunks)', () {
      final c = _with(net);
      addTearDown(c.dispose);
      // Each trunk is sized for its own 0.5 m³/s …
      expect(c.read(sizingProvider)['e1']!.flow.cubicMetersPerSecond,
          closeTo(0.5, 1e-12));
      final fan = c.read(ductFanProvider)!;
      // … but the AHU moves both: 0.5 + 0.5 = 1.0 m³/s (it read 0.5).
      expect(fan.airflow.cubicMetersPerSecond, closeTo(1.0, 1e-12));
      // Static = the index run from the AHU + its 250 Pa internal allowance.
      final expected = sizeFan(
        airflow: const FlowRate(1.0),
        totalStaticPressure: Pressure(_static(c, ServiceType.duct, 'ahu')
                .pascals +
            defaultInternalStatic(AirEquipmentKind.ahu).pascals),
      );
      expect(fan.totalStaticPressure.pascals,
          closeTo(expected.totalStaticPressure.pascals, 1e-9));
      expect(fan.selectedMotor.watts, expected.selectedMotor.watts);
      // The air-balance readout carries the full 1000 L/s too.
      expect(c.read(airBalanceProvider)!.supplyLps, closeTo(1000, 1e-9));
    });
  });

  group('sourceDeliveredFlow (pure)', () {
    final net = Network(
      nodes: [_n('p', 0), _n('a', 100), _n('b', -100)],
      edges: const [
        NetEdge(id: 'ea', fromId: 'p', toId: 'a', service: ServiceType.coldWater),
        NetEdge(id: 'eb', fromId: 'p', toId: 'b', service: ServiceType.coldWater),
      ],
    );
    EdgeSizing sized(String id, double q) => EdgeSizing(
          edgeId: id,
          service: ServiceType.coldWater,
          flow: FlowRate(q),
          diameter: Diameter.mm(25),
          velocity: const Velocity(1),
        );

    test('one incident edge ⇒ that edge verbatim; none ⇒ zero', () {
      final one = Network(nodes: net.nodes, edges: [net.edges.first]);
      expect(
          sourceDeliveredFlow(one, {'ea': sized('ea', 0.3)},
                  ServiceType.coldWater, 'p')
              .cubicMetersPerSecond,
          0.3);
      expect(
          sourceDeliveredFlow(net, const {}, ServiceType.coldWater, 'p')
              .cubicMetersPerSecond,
          0);
    });

    test('UBAP branches re-diversify the SUMMED units once', () {
      // Branch UBAP 10 + 5 = 15 ⇒ probable flow of 15 UBAP, never Σ of the two
      // already-diversified branch flows, and never below the larger branch.
      const sni = SniProfile();
      final qa = sni.probableFlowForFixtureUnits(10).cubicMetersPerSecond;
      final qb = sni.probableFlowForFixtureUnits(5).cubicMetersPerSecond;
      final q15 = sni.probableFlowForFixtureUnits(15).cubicMetersPerSecond;
      final got = sourceDeliveredFlow(
        net,
        {'ea': sized('ea', qa), 'eb': sized('eb', qb)},
        ServiceType.coldWater,
        'p',
        edgeFixtureUnits: const {'ea': 10, 'eb': 5},
        flushSystem: FlushSystem.flushTank,
      ).cubicMetersPerSecond;
      expect(got, closeTo(math.max(q15, qa), 1e-12));
      // Without the UBAP record (e.g. ring edges) the flows simply add.
      expect(
          sourceDeliveredFlow(net, {'ea': sized('ea', qa), 'eb': sized('eb', qb)},
                  ServiceType.coldWater, 'p')
              .cubicMetersPerSecond,
          closeTo(qa + qb, 1e-12));
    });

    // Property: for any seeded pair of UBAP branches the re-diversified total
    // lies between the larger branch and the plain sum (the curve is concave).
    test('property: max(branch) ≤ delivered ≤ Σ branches', () {
      const sni = SniProfile();
      final rnd = math.Random(11);
      for (var i = 0; i < 200; i++) {
        final ua = 1 + rnd.nextInt(400).toDouble();
        final ub = 1 + rnd.nextInt(400).toDouble();
        final qa = sni.probableFlowForFixtureUnits(ua).cubicMetersPerSecond;
        final qb = sni.probableFlowForFixtureUnits(ub).cubicMetersPerSecond;
        final got = sourceDeliveredFlow(
          net,
          {'ea': sized('ea', qa), 'eb': sized('eb', qb)},
          ServiceType.coldWater,
          'p',
          edgeFixtureUnits: {'ea': ua, 'eb': ub},
          flushSystem: FlushSystem.flushTank,
        ).cubicMetersPerSecond;
        expect(got, greaterThanOrEqualTo(math.max(qa, qb) - 1e-12),
            reason: '$ua + $ub');
        expect(got, lessThanOrEqualTo(qa + qb + 1e-12), reason: '$ua + $ub');
      }
    });
  });

  // ── hvac-network-4 ─────────────────────────────────────────────────────────
  group('hvac-network-4 — two separate AHU systems each get a duty', () {
    final net = Network(
      nodes: [
        _n('ahu1', 0, component: NodeComponent.ahu),
        _n('d1', 1000,
            airflow: const FlowRate(0.5),
            component: NodeComponent.supplyDiffuser),
        _n('ahu2', 0, sheet: 's2', floor: 1, component: NodeComponent.ahu),
        _n('d2', 1500,
            sheet: 's2',
            floor: 1,
            airflow: const FlowRate(0.4),
            component: NodeComponent.supplyDiffuser),
      ],
      edges: const [
        NetEdge(id: 'e1', fromId: 'ahu1', toId: 'd1', service: ServiceType.duct),
        NetEdge(id: 'e2', fromId: 'ahu2', toId: 'd2', service: ServiceType.duct),
      ],
    );

    test('one duty per root, each on its own airflow + static', () {
      final c = _with(net);
      addTearDown(c.dispose);
      final duties = c.read(supplyFanDutiesByRootProvider);
      expect(duties.keys.toSet(), {'ahu1', 'ahu2'});
      expect(duties['ahu1']!.airflow.cubicMetersPerSecond, closeTo(0.5, 1e-12));
      expect(duties['ahu2']!.airflow.cubicMetersPerSecond, closeTo(0.4, 1e-12));
      final internal = defaultInternalStatic(AirEquipmentKind.ahu).pascals;
      expect(duties['ahu2']!.totalStaticPressure.pascals,
          closeTo(_static(c, ServiceType.duct, 'ahu2').pascals + internal, 1e-9));
      // The primary (largest) system is still the one `ductFanProvider` names.
      expect(c.read(ductFanProvider)!.airflow.cubicMetersPerSecond,
          closeTo(0.5, 1e-12));
      expect(c.read(airSystemRootNodesProvider).supply, 'ahu1');
      // Total supply on the balance readout = 0.5 + 0.4 m³/s.
      expect(c.read(airBalanceProvider)!.supplyLps, closeTo(900, 1e-9));
    });

    test('the SECOND AHU feeds the electrical model with its solved duty', () {
      final c = _with(net);
      addTearDown(c.dispose);
      final duty2 = c.read(supplyFanDutiesByRootProvider)['ahu2']!;
      final load = c
          .read(placedEquipmentLoadsProvider)
          .singleWhere((l) => l.id == 'node-ahu2');
      // Not the component's representative defaultMotorKw any more.
      expect(load.mechanicalPower.watts, duty2.selectedMotor.watts);
    });
  });

  // ── hvac-network-2 ─────────────────────────────────────────────────────────
  test('hvac-network-2 — a toilet auto-places EXHAUST grilles only', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    c.read(projectControllerProvider.notifier)
        .setCalibration('s1', const ScaleCalibration(0.01));
    final rooms = c.read(roomAreasProvider.notifier);
    // 3 × 2 m at 0.01 m/px.
    final id = rooms.add(
        sheetId: 's1', floorIndex: 0, ax: 0, ay: 0, bx: 300, by: 200)!;
    rooms.setRoomType(id, RoomType.toilet);
    rooms.setCeiling(id, 3.0);
    final room = c.read(roomAreasProvider).single;
    final s = room.sizing(0.01)!;
    expect(s.extractOnly, isTrue);
    // 18 m³ × 10 ACH / 3600 = 50 L/s (the Tabel 4.4.1 toilet rate).
    expect(room.effectiveAch(), 10);
    expect(s.airflow.inLitersPerSecond, closeTo(50, 1e-9));

    final ids = c
        .read(networkControllerProvider.notifier)
        .autoPlaceRoomTerminals(room: room, metersPerPixel: 0.01);
    final nodes = c.read(networkControllerProvider).network.nodes;
    expect(ids, isNotEmpty);
    expect(nodes.every((n) => n.component == NodeComponent.exhaustGrille),
        isTrue,
        reason: 'no supply diffuser, no recirculating return grille');
    final total =
        nodes.fold<double>(0, (a, n) => a + n.airflow!.cubicMetersPerSecond);
    expect(total, closeTo(0.05, 1e-12));
  });

  // ── copilot decode ─────────────────────────────────────────────────────────
  group('copilot decode never throws and records malformed fields', () {
    test('1e400 decodes to Infinity — flagged, never a placement', () {
      final args = jsonDecode('{"sheetId":"s1","floor":0,"x":1e400,"y":-1e400}')
          as Map;
      final cmd = AiCommand.fromJson('placeFitting', args)!;
      expect(cmd.invalidFields, containsAll(['x', 'y']));
      expect(cmd.x.isFinite && cmd.y.isFinite, isTrue);
    });

    test('a non-finite floor no longer throws out of fromJson', () {
      final args =
          jsonDecode('{"sheetId":"s1","floor":1e400,"x":1,"y":1}') as Map;
      final cmd = AiCommand.fromJson('placeFitting', args)!;
      expect(cmd.invalidFields, ['floor']);
    });

    test('missing / wrong-typed fields are flagged; numeric strings accepted',
        () {
      final bad = AiCommand.fromJson(
          'placeFitting', {'sheetId': 's1', 'floor': '2', 'x': '300', 'y': null})!;
      expect(bad.floor, 2);
      expect(bad.x, 300);
      expect(bad.invalidFields, ['y']);
      expect(
          AiCommand.fromJson('placeFitting', {'sheetId': 's1', 'floor': 1.5,
              'x': 1, 'y': 1})!.invalidFields,
          ['floor']);
      // Text-only kinds need no point.
      expect(AiCommand.fromJson('suggest', {'message': 'hi'})!.invalidFields,
          isEmpty);
    });

    test('the OpenAI parser drops nothing silently and never throws', () {
      final body = jsonEncode({
        'choices': [
          {
            'message': {
              'content': 'ok',
              'tool_calls': [
                {
                  'function': {
                    'name': 'placeFitting',
                    'arguments': '{"sheetId":"s1","floor":1e400,"x":1,"y":1}',
                  },
                },
              ],
            },
          },
        ],
      });
      final r = OpenAiAiClient.parseOpenAiResponse(body);
      expect(r, isA<AiOk>());
    });

    // Property: random JSON-ish argument maps never throw out of the decoder,
    // and a placement decodes with no invalid field ONLY when floor is an
    // integral finite number and x / y are finite.
    test('property: fuzzed args never throw; invalid ⇔ malformed', () {
      final rnd = math.Random(400);
      Object? val() => switch (rnd.nextInt(9)) {
            0 => null,
            1 => double.infinity,
            2 => double.nan,
            3 => 'abc',
            4 => '${rnd.nextInt(500)}',
            5 => rnd.nextInt(5),
            6 => rnd.nextDouble() * 1000,
            7 => <int>[1],
            _ => 1.5,
          };
      for (var i = 0; i < 1000; i++) {
        final args = {'sheetId': 's1', 'floor': val(), 'x': val(), 'y': val()};
        final cmd = AiCommand.tryFromJson('placeTerminal', args)!;
        double? f(Object? v) {
          final d = v is num
              ? v.toDouble()
              : v is String
                  ? double.tryParse(v)
                  : null;
          return d != null && d.isFinite ? d : null;
        }

        final fl = f(args['floor']);
        final ok = fl != null &&
            fl == fl.roundToDouble() &&
            f(args['x']) != null &&
            f(args['y']) != null;
        expect(cmd.invalidFields.isEmpty, ok, reason: '$args');
      }
    });
  });

  // ── copilot apply ──────────────────────────────────────────────────────────
  group('copilot apply validates the frame', () {
    ProviderContainer withPlan(AiPlan plan) {
      final c = ProviderContainer(overrides: [
        aiClientProvider.overrideWithValue(FakeAiClient((_) => AiOk(plan))),
      ]);
      addTearDown(c.dispose);
      c.read(sheetsControllerProvider.notifier).loadDemoSheets();
      return c;
    }

    test('malformed / off-sheet / wrong-floor placements are skipped', () async {
      final c = withPlan(AiPlan(commands: [
        // Valid — s1 maps to floor 0.
        const AiCommand(
            kind: AiCommandKind.placeFitting,
            sheetId: 's1',
            floor: 0,
            x: 100,
            y: 100),
        // Non-finite (decoded from 1e400).
        AiCommand.fromJson('placeFitting',
            jsonDecode('{"sheetId":"s1","floor":0,"x":1e400,"y":1}') as Map)!,
        // Far off the 1684 x 1190 px sheet.
        const AiCommand(
            kind: AiCommandKind.placeFitting,
            sheetId: 's1',
            floor: 0,
            x: 1e12,
            y: -5e9),
        // s2 is floor 1 — a floor-0 node would render on NO plan.
        const AiCommand(
            kind: AiCommandKind.placeComponent,
            sheetId: 's2',
            floor: 0,
            x: 100,
            y: 100,
            component: 'pump'),
      ]));
      await c.read(copilotProvider.notifier).ask('go');
      final out = c.read(copilotProvider.notifier).applyPlan();
      expect(out.applied, 1);
      expect(out.skippedCount, 3);
      expect(out.skipped.join('\n'), contains('missing or invalid x'));
      expect(out.skipped.join('\n'), contains('coordinates off sheet'));
      expect(out.skipped.join('\n'), contains('is floor 1, not 0'));
      // The project still encodes (no Infinity node landed).
      expect(() => buildDocument(c.read).encode(), returnsNormally);
    });

    test('the context names each sheet\'s mapped floor', () async {
      String? ctx;
      final c = ProviderContainer(overrides: [
        aiClientProvider.overrideWithValue(FakeAiClient((r) {
          ctx = r.contextSummary;
          return const AiOk(AiPlan(commands: []));
        })),
      ]);
      addTearDown(c.dispose);
      c.read(sheetsControllerProvider.notifier).loadDemoSheets();
      await c.read(copilotProvider.notifier).ask('hi');
      expect(ctx, contains('s2 | First Floor | 1684x1190 | floor 1'));
    });

    test('a throwing client lands in the error phase, never "thinking"',
        () async {
      final c = ProviderContainer(overrides: [
        aiClientProvider.overrideWithValue(
            FakeAiClient((_) => throw StateError('boom'))),
      ]);
      addTearDown(c.dispose);
      await c.read(copilotProvider.notifier).ask('go');
      expect(c.read(copilotProvider).phase, CopilotPhase.error);
      expect(c.read(copilotProvider).message, contains('boom'));
    });

    test('auto-place on an UNCALIBRATED sheet is skipped, not "applied"',
        () async {
      final c = withPlan(const AiPlan(commands: [
        AiCommand(kind: AiCommandKind.autoPlaceRoomTerminals, roomId: 'r0'),
      ]));
      c.read(roomAreasProvider.notifier).add(
          sheetId: 's1', floorIndex: 0, ax: 0, ay: 0, bx: 300, by: 200);
      await c.read(copilotProvider.notifier).ask('place');
      final out = c.read(copilotProvider.notifier).applyPlan();
      expect(out.applied, 0);
      expect(out.skippedCount, 1);
      expect(out.skipped.single, contains('uncalibrated'));
      expect(c.read(networkControllerProvider).network.nodes, isEmpty);
    });
  });
}
