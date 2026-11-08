/// Round 30 commercial / ejector seed suite (2026-10-18):
///   * costing-2-1 — drawn plant is taken off as priced-per-piece EQUIPMENT
///     (unpriced until priced), with install labour and a proposal note.
///   * costing-2-5 — the MEP BOM CSV's electrical key is the PRICE key, and
///     its unit is 'm' for cable / 'ea' otherwise.
///   * costing-2-6 — the assumed HW recirculation return / pump say so, never
///     inherit the drawn cut plan, and the pump keys on its component.
///   * costing-2-7 — the MEP proposal localizes (EN byte-identical).
///   * mech-sim-4-ejector-pump-no-duty-no-schedule — a drawn sewage ejector
///     has a solved duty (lift + friction at the pit's DFU inflow).
library;

import 'package:mechx_engine/electrical/bom.dart' as elec;
import 'package:mechx_engine/electrical/catalog.dart' show PartCategory;
import 'package:mechx_engine/electrical/costing.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/mep_commercial.dart';
import 'package:mechx_engine/report/report_strings.dart';
import 'package:mechx_engine/sizing/bom.dart';
import 'package:mechx_engine/sizing/ejector.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/sizing/pipe_optimizer.dart';
import 'package:mechx_engine/standards/sni.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

NetNode _n(String id, double x, double y,
        {int floor = 0,
        NodeRole role = NodeRole.main,
        NodeComponent? component}) =>
    NetNode(
        id: id,
        sheetId: 's1',
        x: x,
        y: y,
        floorIndex: floor,
        role: component?.role ?? role,
        component: component);

NetEdge _e(String id, String a, String b, ServiceType s,
        {EdgeKind kind = EdgeKind.run}) =>
    NetEdge(id: id, fromId: a, toId: b, service: s, kind: kind);

const _emptyElec = CostEstimate(
    lines: [], grandTotal: 0, currency: 'IDR', unmatchedCount: 0);

void main() {
  group('equipment take-off', () {
    // groundTank -> pump -> roofTank -> gateValve -> fixture (CW), AHU ->
    // diffuser (duct), and an AC cassette.
    final net = Network(nodes: [
      _n('GT', 0, 0, component: NodeComponent.groundTank),
      _n('P', 50, 0, component: NodeComponent.pump),
      _n('RT', 100, 0, floor: 1, component: NodeComponent.roofTank),
      _n('GV', 150, 0, floor: 1, component: NodeComponent.gateValve),
      _n('F', 200, 0, floor: 1, role: NodeRole.fixture),
      _n('AHU', 0, 100, component: NodeComponent.ahu),
      _n('SD', 50, 100, component: NodeComponent.supplyDiffuser),
      _n('AC', 0, 200, component: NodeComponent.acCassette),
    ], edges: [
      _e('a', 'GT', 'P', ServiceType.coldWater),
      _e('b', 'P', 'RT', ServiceType.coldWater, kind: EdgeKind.riser),
      _e('c', 'RT', 'GV', ServiceType.coldWater),
      _e('d', 'GV', 'F', ServiceType.coldWater),
      _e('e', 'AHU', 'SD', ServiceType.duct),
    ]);

    test('every drawn plant item is listed (by duty) and stays unpriced '
        'until priced', () {
      final eq = buildEquipmentTakeoff(
          net: net, dutyByNodeId: const {'P': '1.50 kW', 'RT': '10 m3'});
      final comps = {for (final l in eq) l.component};
      expect(comps, {
        NodeComponent.groundTank,
        NodeComponent.pump,
        NodeComponent.roofTank,
        NodeComponent.ahu,
        NodeComponent.acCassette,
      });
      expect(eq.every((l) => l.equipment), isTrue);
      final est = estimateMechanicalCost(
          pipes: const [],
          fittings: const [],
          equipment: eq,
          priceList: {
            mechEquipmentKey(NodeComponent.pump, '1.50 kW'): 12000000,
          });
      // 5 equipment lines, 1 priced (the pump) ⇒ 4 unpriced, total 12 M.
      final lines = est.lines
          .where((l) => l.category == MechItemCategory.equipment)
          .toList();
      expect(lines.length, 5);
      expect(est.unpricedCount, 4);
      expect(est.grandTotal, 12000000);
      expect(lines.any((l) => l.key == 'mech:equipment:roofTank:10 m3'), isTrue);
      // Labour: 5 pieces × 4.0 h (the equipment standard).
      expect(
          mechanicalLabourHours(
              pipes: const [], fittings: const [], equipment: eq),
          closeTo(5 * mechInstallHoursPerEquipment, 1e-9));
      // The proposal names them and counts the unpriced ones.
      final q = buildMepQuotation(
          mechanical: est,
          electrical: _emptyElec,
          mechanicalEquipment: eq);
      expect(q.unpricedCount, 4);
      final md = mepQuotationToMarkdown(q,
          mechanical: est, electrical: _emptyElec);
      expect(md, contains('5 scheduled equipment item(s)'));
      expect(md, contains('4 line(s) are unpriced'));
    });
  });

  group('assumed recirculation lines', () {
    test('the assumed DN20 return says so and never inherits the drawn '
        'cut-plan bars; the assumed pump keys on its component', () {
      const drawn = BomLine(
          service: ServiceType.hotWater,
          kind: EdgeKind.run,
          diameterMm: 20,
          material: 'PPR',
          totalLength: Length(30),
          segmentCount: 3);
      const assumed = BomLine(
          service: ServiceType.hotWater,
          kind: EdgeKind.run,
          diameterMm: 20,
          material: 'PPR',
          totalLength: Length(42),
          segmentCount: 1,
          assumed: true);
      // The DRAWN 30 m packs into 5 x 6 m bars (no offcut).
      const plan = [
        PipeCutGroup(
          service: ServiceType.hotWater,
          diameterMm: 20,
          material: 'PPR',
          stockLengthM: 6,
          plan: StockCutPlan(
              stockLengthM: 6, fullBars: 5, packedBars: [], requiredM: 30),
        ),
      ];
      final est = estimateMechanicalCost(
        pipes: const [drawn, assumed],
        fittings: const [],
        components: const [
          ComponentLine(
              service: ServiceType.hotWater,
              component: NodeComponent.pump,
              sizeLabel: '0.12 kW',
              count: 1,
              assumed: true),
        ],
        priceList: const {},
        cutPlan: plan,
      );
      final d = est.lines[0], a = est.lines[1], p = est.lines[2];
      expect(d.assumed, isFalse);
      expect(d.stockBars, isNotNull);
      expect(a.assumed, isTrue);
      expect(a.description, endsWith(kMechAssumedSuffix));
      expect(a.stockBars, isNull);
      expect(a.wastePercent, isNull);
      expect(p.key, 'mech:component:hotWater:pump:-');
      expect(p.description, contains('0.12 kW'));
      expect(p.description, endsWith(kMechAssumedSuffix));
      final md = mepQuotationToMarkdown(
          buildMepQuotation(mechanical: est, electrical: _emptyElec),
          mechanical: est,
          electrical: _emptyElec);
      expect(md, contains('2 mechanical line(s) are assumptions'));
    });
  });

  group('MEP BOM CSV electrical columns', () {
    test('key = the price key, unit = m for cable, ea otherwise', () {
      const est = CostEstimate(
        lines: [
          CostLine(
            line: elec.BomLine(
                description: 'Cable NYM 5x4 mm2',
                qty: 25,
                category: PartCategory.cable,
                sku: 'NYM-4',
                priceKey: 'NYM-4:5C'),
            matched: true,
            unitPrice: 30000,
            lineTotal: 750000,
          ),
          CostLine(
            line: elec.BomLine(
                description: 'Enclosure 550x350x200 mm IP41',
                qty: 1,
                category: PartCategory.enclosure,
                priceKey: 'elec:enclosure:550x350x200'),
            matched: false,
          ),
        ],
        grandTotal: 750000,
        currency: 'IDR',
        unmatchedCount: 1,
      );
      final csv = mepBomToCsv(
          estimateMechanicalCost(
              pipes: const [], fittings: const [], priceList: const {}),
          est);
      expect(csv, contains('electrical,25,m,cable,Cable NYM 5x4 mm2,NYM-4:5C,'));
      expect(
          csv,
          contains('electrical,1,ea,enclosure,Enclosure 550x350x200 mm IP41,'
              'elec:enclosure:550x350x200,'));
    });
  });

  group('MEP proposal localizes', () {
    test('ID headings / rows / notes; EN unchanged', () {
      final est = estimateMechanicalCost(
          pipes: const [
            BomLine(
                service: ServiceType.coldWater,
                kind: EdgeKind.run,
                diameterMm: 50,
                totalLength: Length(20),
                segmentCount: 1),
          ],
          fittings: const [],
          priceList: const {});
      final q = buildMepQuotation(mechanical: est, electrical: _emptyElec);
      final en = mepQuotationToMarkdown(q,
          mechanical: est, electrical: _emptyElec, projectName: 'X');
      expect(en, startsWith('# MEP proposal — X'));
      expect(en, contains('| Mechanical material |'));
      expect(en, contains('| **Grand total** |'));
      final id = mepQuotationToMarkdown(q,
          mechanical: est,
          electrical: _emptyElec,
          projectName: 'X',
          strings: const ReportStrings.id());
      expect(id, startsWith('# Penawaran MEP — X'));
      expect(id, contains('| Material mekanis |'));
      expect(id, contains('| **Total keseluruhan** |'));
      expect(id, contains('(belum berharga)'));
      expect(id, isNot(contains('Grand total')));
      expect(id, isNot(contains('unpriced (no price')));
    });
  });

  group('sewage ejector duty', () {
    test('pit at B1 lifting to the ground-floor sewer: flow = curve(DFU), '
        'head = lift + friction', () {
      // 2 levels x 3.0 m, groundIndex 1: B1 slab -3.0, L0 slab 0.0.
      const b = BuildingLevels([Floor('B1', Length(3)), Floor('L0', Length(3))],
          groundIndex: 1);
      final net = Network(nodes: [
        _n('WC', -50, 0, role: NodeRole.fixture),
        _n('PIT', 0, 0, component: NodeComponent.groundTank),
        _n('EJ', 20, 0, component: NodeComponent.pump),
        _n('R1', 20, 0, floor: 1),
        _n('SW', 120, 0, floor: 1),
      ], edges: [
        _e('in', 'WC', 'PIT', ServiceType.drainage),
        _e('pe', 'PIT', 'EJ', ServiceType.drainage),
        _e('rs', 'EJ', 'R1', ServiceType.drainage, kind: EdgeKind.riser),
        _e('sw', 'R1', 'SW', ServiceType.drainage),
      ]);
      expect(drawnEjectorPumpIds(net), ['EJ']);
      final fu = <String, double>{};
      final sizing = autoSizeNetwork(net, const SizingContext(),
          leafDemand: const {},
          nodeDrainageUnits: const {'WC': 20},
          fixtureUnitsOut: fu);
      final p = ejectorDutyPoint(
          net: net,
          pumpId: 'EJ',
          sizing: sizing,
          edgeFixtureUnits: fu,
          building: b,
          calibrationBySheet: const {'s1': ScaleCalibration(0.05)})!;
      // Flow: the 20 DFU the pit carries through the flush-tank curve.
      expect(p.flow.inLitersPerSecond,
          closeTo(const SniProfile().probableFlowForFixtureUnits(20)
              .inLitersPerSecond, 1e-9));
      // Lift: pump on the B1 slab (-3.0 m, a plant on its floor surface) up
      // the riser to R1 — a bare L0 drainage junction above the lowest level
      // reads under its slab, the ceiling of B1 = 0.0 - 0.3 = -0.3 m.
      // Lift = -0.3 - (-3.0) = 2.7 m; friction > 0 over the riser + run.
      expect(p.staticLift.meters, closeTo(2.7, 1e-9));
      expect(p.head.meters, greaterThan(p.staticLift.meters));
      final duty = ejectorPumpDuty(
          net: net,
          pumpId: 'EJ',
          sizing: sizing,
          edgeFixtureUnits: fu,
          building: b,
          calibrationBySheet: const {'s1': ScaleCalibration(0.05)})!;
      expect(duty.flow.inLitersPerSecond, closeTo(p.flow.inLitersPerSecond, 1e-12));
      expect(duty.head.meters, closeTo(p.head.meters, 1e-12));
    });

    test('a supply / fire pump is never an ejector', () {
      final net = Network(nodes: [
        _n('P', 0, 0, component: NodeComponent.pump),
        _n('X', 10, 0),
      ], edges: [
        _e('a', 'P', 'X', ServiceType.coldWater),
      ]);
      expect(drawnEjectorPumpIds(net), isEmpty);
    });
  });
}
