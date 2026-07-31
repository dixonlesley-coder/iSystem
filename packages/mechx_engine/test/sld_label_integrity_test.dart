// Integrity of what the ISSUED single-line sheets actually print — the
// MODULE-AUDIT-REVIEW findings E1 (per-device breaking capacity), E2/E8c (one
// containment source, fill-checked), E8b (the 2-pole feeder token), X1 (the
// mechanical riser's labels vs the sheet's own ink) and X2 (the overview's
// feeder annotations at a bus split).
//
// Every expectation here is about a TOKEN a panel builder / foreman reads off
// the sheet, or about two pieces of ink not landing on top of each other.
import 'package:mechx_engine/electrical/advanced_study.dart'
    show computeAdvancedStudy;
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/containment.dart'
    show ConduitSpec, conduitFillSingle, sizeConduit;
import 'package:mechx_engine/electrical/fault.dart' show breakingCapacityKa;
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/report/electrical_sld_drawing.dart';
import 'package:mechx_engine/report/mechanical_sld_drawing.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/standards/sni.dart' show PlumbingFixture;
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

// ── Fixtures ────────────────────────────────────────────────────────────────

/// A MIXED board: a big MCCB-protected feeder + a 3-phase MCCB motor alongside
/// small MCB final ways, so one board carries devices of BOTH classes (their
/// breaking-capacity ladders do not overlap: MCB 6/10/15/25, MCCB 16/25/36…).
/// The 1-phase feeder to LP-1 exercises E8b (a 2-pole device on a 3-phase bus).
const _mixedProject = ElectricalProject(
  id: 'p-mixed',
  name: 'Mixed board',
  panels: [
    ElectricalPanel(
      id: 'MDP',
      name: 'MDP',
      tag: 'MDP',
      circuits: [
        // A 1-phase FEEDER off a 3-phase board -> a 2-POLE device (E8b).
        ElectricalCircuit(
          id: 'f-lp1',
          name: 'Feeder to LP-1',
          loadKind: LoadKind.feeder,
          feedsPanelId: 'LP1',
          length: Length(18),
        ),
        // A big motor -> MCCB frame.
        ElectricalCircuit(
          id: 'm-big',
          name: 'Chiller',
          loadKind: LoadKind.motor,
          motorKw: 55,
          cableType: 'NYY',
          length: Length(25),
        ),
        // Small final ways -> MCB frames.
        ElectricalCircuit(
          id: 'l-1',
          name: 'Lampu koridor',
          loadKind: LoadKind.lighting,
          isLighting: true,
          loadW: 900,
          cableType: 'NYM',
          length: Length(20),
        ),
        ElectricalCircuit(
          id: 's-1',
          name: 'Stop kontak',
          loadKind: LoadKind.socket,
          loadW: 3000,
          cableType: 'NYM',
          length: Length(16),
        ),
      ],
    ),
    ElectricalPanel(
      id: 'LP1',
      name: 'LP-1',
      tag: 'LP-1',
      system: ElectricalSystem.singlePhase,
      voltage: Voltage(220),
      sourceType: PanelSource.feeder,
      fedByCircuitId: 'f-lp1',
      circuits: [
        ElectricalCircuit(
          id: 'lp1-l1',
          name: 'Lighting',
          loadKind: LoadKind.lighting,
          isLighting: true,
          loadW: 1500,
          cableType: 'NYM',
          length: Length(18),
        ),
      ],
    ),
  ],
);

/// ONE 3-phase board splitting to THREE sub-boards — the bus split whose feeder
/// annotations used to print on top of each other in the overview (X2).
const _splitProject = ElectricalProject(
  id: 'p-split',
  name: 'Bus split',
  panels: [
    ElectricalPanel(
      id: 'MDP',
      name: 'MDP',
      circuits: [
        ElectricalCircuit(
            id: 'f-a',
            name: 'Feeder A',
            loadKind: LoadKind.feeder,
            feedsPanelId: 'A',
            length: Length(18)),
        ElectricalCircuit(
            id: 'f-b',
            name: 'Feeder B',
            loadKind: LoadKind.feeder,
            feedsPanelId: 'B',
            length: Length(24)),
        ElectricalCircuit(
            id: 'f-c',
            name: 'Feeder C',
            loadKind: LoadKind.feeder,
            feedsPanelId: 'C',
            length: Length(30)),
      ],
    ),
    ElectricalPanel(
      id: 'A',
      name: 'PP-A',
      sourceType: PanelSource.feeder,
      fedByCircuitId: 'f-a',
      circuits: [
        ElectricalCircuit(
            id: 'a1',
            name: 'Motor A',
            loadKind: LoadKind.motor,
            motorKw: 7.5,
            length: Length(12)),
      ],
    ),
    ElectricalPanel(
      id: 'B',
      name: 'PP-B',
      sourceType: PanelSource.feeder,
      fedByCircuitId: 'f-b',
      circuits: [
        ElectricalCircuit(
            id: 'b1',
            name: 'Motor B',
            loadKind: LoadKind.motor,
            motorKw: 11,
            length: Length(14)),
      ],
    ),
    ElectricalPanel(
      id: 'C',
      name: 'PP-C',
      sourceType: PanelSource.feeder,
      fedByCircuitId: 'f-c',
      circuits: [
        ElectricalCircuit(
            id: 'c1',
            name: 'Motor C',
            loadKind: LoadKind.motor,
            motorKw: 15,
            length: Length(16)),
      ],
    ),
  ],
);

/// ONE parent, ONE sub-board — the uncollided case that must stay untouched.
const _singleFeederProject = ElectricalProject(
  id: 'p-one',
  name: 'One feeder',
  panels: [
    ElectricalPanel(
      id: 'MDP',
      name: 'MDP',
      circuits: [
        ElectricalCircuit(
            id: 'f-a',
            name: 'Feeder A',
            loadKind: LoadKind.feeder,
            feedsPanelId: 'A',
            length: Length(18)),
      ],
    ),
    ElectricalPanel(
      id: 'A',
      name: 'PP-A',
      sourceType: PanelSource.feeder,
      fedByCircuitId: 'f-a',
      circuits: [
        ElectricalCircuit(
            id: 'a1',
            name: 'Motor A',
            loadKind: LoadKind.motor,
            motorKw: 7.5,
            length: Length(12)),
      ],
    ),
  ],
);

List<String> _labelTexts(SldSheet s) =>
    s.prims.whereType<SldLabel>().map((l) => l.text).toList();

/// Every DEVICE cell on a board schedule (the cells that lead with a breaker
/// class code).
List<String> _deviceCells(SldSheet s) => _labelTexts(s)
    .where((t) => t.startsWith('MCB ') || t.startsWith('MCCB '))
    .toList();

/// Every PENGHANTAR (conductor) cell — the cells that carry a cable family.
List<String> _cableCells(SldSheet s) => _labelTexts(s)
    .where((t) => t.contains(' mm2') && t.contains(' · '))
    .toList();

// ── Mechanical riser fixture (X1) ───────────────────────────────────────────

NetNode _n(String id, double x, int floor,
        {NodeRole role = NodeRole.main,
        NodeComponent? component,
        PlumbingFixture? fixture}) =>
    NetNode(
      id: id,
      sheetId: 's1',
      x: x,
      y: 0,
      floorIndex: floor,
      role: role,
      component: component,
      fixture: fixture,
    );

NetEdge _e(String id, String from, String to,
        {ServiceType service = ServiceType.coldWater,
        EdgeKind kind = EdgeKind.run}) =>
    NetEdge(id: id, fromId: from, toId: to, service: service, kind: kind);

EdgeSizing _sz(String edgeId, double mm) => EdgeSizing(
      edgeId: edgeId,
      service: ServiceType.coldWater,
      flow: const FlowRate(1),
      diameter: Diameter.mm(mm),
      velocity: const Velocity(1.5),
    );

const _levels = BuildingLevels([
  Floor('Ground', Length(4)),
  Floor('Lantai 1', Length(4)),
]);

/// The issued-sheet plant cluster that collided: a GROUND TANK whose label
/// ("Ground tank · 5.0 m3") reaches right across the suction run into the
/// junction box and the booster PUMP glyph, on the same in-line main.
Network _plantNet() => Network(
      nodes: [
        _n('gt', 60, 0,
            role: NodeRole.plant, component: NodeComponent.groundTank),
        _n('j', 150, 0),
        _n('pump', 190, 0,
            role: NodeRole.plant, component: NodeComponent.pump),
        _n('up', 190, 1),
        _n('wc', 320, 1,
            role: NodeRole.fixture,
            fixture: PlumbingFixture.waterClosetFlushValve),
      ],
      edges: [
        _e('s1', 'gt', 'j'),
        _e('s2', 'j', 'pump'),
        _e('r1', 'pump', 'up', kind: EdgeKind.riser),
        _e('b1', 'up', 'wc'),
      ],
    );

SldSheet _plantSheet() => buildMechanicalRiserSld(
      network: _plantNet(),
      sizing: {
        's1': _sz('s1', 32),
        's2': _sz('s2', 32),
        'r1': _sz('r1', 32),
        'b1': _sz('b1', 25),
      },
      building: _levels,
      edgeLengths: const {
        's1': Length(1.6),
        's2': Length(4.4),
        'r1': Length(4.0),
        'b1': Length(2.8),
      },
      equipmentDetailByNodeId: const {'gt': '5.0 m3', 'pump': '2.2 kW'},
      notes: const ['Sistem upfeed booster'],
      detailCallouts: true,
    );

/// A label's collision box, sized with the builder's OWN per-char advance.
({double minX, double minY, double maxX, double maxY}) _labelBox(SldLabel l) => (
      minX: l.x,
      minY: l.y - l.size,
      maxX: l.x + l.text.length * l.size * kMechRiserLabelCharW,
      maxY: l.y,
    );

bool _overlaps(({double minX, double minY, double maxX, double maxY}) a,
        ({double minX, double minY, double maxX, double maxY}) b) =>
    a.minX < b.maxX && b.minX < a.maxX && a.minY < b.maxY && b.minY < a.maxY;

void main() {
  const puil = PuilProfile();

  // ── E1 — the DEVICE cell carries the WAY's own breaking capacity ───────────
  group('E1 — per-circuit breaking capacity', () {
    final result = computeSystem(puil, _mixedProject,
        originFaultLevel: const Current(16000), busbarClearingTimeS: 0.1);
    final advanced = computeAdvancedStudy(puil, _mixedProject, result,
        originFaultLevel: const Current(16000));
    final perCircuitKa = <String, double>{
      for (final e in advanced.fault.circuits.entries) e.key: e.value.breakerKa,
    };
    final perPanelKa = <String, double>{
      for (final e in advanced.fault.panels.entries) e.key: e.value.incomerKa,
    };

    test('the board really is MIXED (both device classes on one bus)', () {
      final mdp = result.panels['MDP']!;
      final classes = {for (final c in mdp.circuits) c.breaker.deviceClass};
      expect(classes, containsAll(<BreakerClass>{
        BreakerClass.mcb,
        BreakerClass.mccb,
      }));
    });

    test('an MCB way prints an MCB-ladder kA, an MCCB way its own', () {
      final sheet = buildElectricalPanelDetail(
        project: _mixedProject,
        result: result,
        panelId: 'MDP',
        breakerIcuKaByPanelId: perPanelKa,
        breakerKaByCircuitId: perCircuitKa,
      );
      final mcbLadder = breakingCapacityKa[BreakerClass.mcb]!;
      final mccbLadder = breakingCapacityKa[BreakerClass.mccb]!;
      final cells = _deviceCells(sheet);
      expect(cells, isNotEmpty);
      var sawMcb = false, sawMccb = false;
      for (final cell in cells) {
        final ka = double.parse(
            RegExp(r'([\d.]+)kA').firstMatch(cell)!.group(1)!);
        if (cell.startsWith('MCB ')) {
          sawMcb = true;
          expect(mcbLadder, contains(ka),
              reason: '"$cell" states a kA no MCB is built to');
        } else {
          sawMccb = true;
          expect(mccbLadder, contains(ka),
              reason: '"$cell" states a kA off the MCCB ladder');
        }
      }
      expect(sawMcb && sawMccb, isTrue);
      // The two ladders only partly overlap (MCB 6/10/15/25 vs MCCB
      // 16/25/36/50/70), so the MCCB floor 16 kA — exactly the figure a
      // 16 kA-origin board's panel map stamps — is NOT an MCB rating: one
      // board-wide figure could not be right for both classes at once.
      expect(mccbLadder.first, 16.0);
      expect(mcbLadder, isNot(contains(16.0)));
    });

    test('each way carries the study figure for ITS OWN circuit', () {
      final sheet = buildElectricalPanelDetail(
        project: _mixedProject,
        result: result,
        panelId: 'MDP',
        breakerKaByCircuitId: perCircuitKa,
      );
      final cells = _deviceCells(sheet);
      for (final c in result.panels['MDP']!.circuits) {
        final ka = perCircuitKa[c.circuitId]!;
        final want = '${c.breaker.deviceClass == BreakerClass.mccb ? 'MCCB' : 'MCB'} '
            '${_numText(c.breaker.ratingA.amperes)}A';
        expect(
            cells.where((t) => t.startsWith(want) && t.contains('${_numText(ka)}kA')),
            isNotEmpty,
            reason: 'no DEVICE cell "$want ... ${_numText(ka)}kA"');
      }
    });

    test('without the map the panel figure still applies (byte-identical)', () {
      final withPanelOnly = buildElectricalPanelDetail(
          project: _mixedProject,
          result: result,
          panelId: 'MDP',
          breakerIcuKaByPanelId: perPanelKa);
      // The legacy behaviour: ONE figure on every way.
      final kas = _deviceCells(withPanelOnly)
          .map((t) => RegExp(r'([\d.]+)kA').firstMatch(t)!.group(1)!)
          .toSet();
      expect(kas.length, 1);
    });
  });

  // ── E8b — a 1-phase feeder off a 3-phase board is a 2-POLE device ─────────
  group('E8b — the 2P feeder token', () {
    final result = computeSystem(puil, _mixedProject);

    test('the feeder row reads 2P; an ordinary 1-phase final way keeps 1ph',
        () {
      final sheet = buildElectricalPanelDetail(
          project: _mixedProject, result: result, panelId: 'MDP');
      final cells = _deviceCells(sheet);
      final feeder = result.panels['MDP']!.circuits
          .firstWhere((c) => c.circuitId == 'f-lp1');
      expect(feeder.threePhase, isFalse);
      expect(result.panels['MDP']!.system.isThreePhase, isTrue);
      // EXACTLY one row reads 2P — the single-phase feeder (16 A here).
      final twoPole = cells.where((t) => t.contains(' 2P')).toList();
      expect(twoPole.length, 1);
      expect(twoPole.single,
          'MCB ${_numText(feeder.breaker.ratingA.amperes)}A 2P');
      // Every OTHER single-phase way on the same board still reads `1ph`.
      final oneP = cells.where((t) => t.contains(' 1ph')).toList();
      expect(oneP, isNotEmpty);
      final singlePhaseFinals = result.panels['MDP']!.circuits
          .where((c) => !c.threePhase && c.circuitId != 'f-lp1');
      expect(oneP.length, singlePhaseFinals.length);
    });

    test('breakerScheduleLabel itself: twoPole swaps only the phase token', () {
      final b = result.panels['MDP']!.circuits.first.breaker;
      expect(breakerScheduleLabel(b, 1), endsWith(' 1ph'));
      expect(breakerScheduleLabel(b, 1, twoPole: true), endsWith(' 2P'));
      expect(breakerScheduleLabel(b, 3), endsWith(' 3ph'));
    });

    test('the OVERVIEW feeder annotation uses the same 2P convention', () {
      final overview =
          buildElectricalOverview(project: _mixedProject, result: result);
      expect(_labelTexts(overview).where((t) => t.contains(' 2P · ')),
          isNotEmpty);
    });
  });

  // ── E2 / E8c — ONE containment source, and never an impossible size ───────
  group('E2/E8c — the conduit token', () {
    test('a 5x70 mm2 run can no longer print the impossible 50 mm', () {
      // Hand-derived from the containment module's own geometry:
      //   conductor d = 2*sqrt(70/pi)          = 9.44 mm
      //   insulation  = 0.7 + 0.05*sqrt(70)    = 1.12 mm
      //   core d      = 9.44 + 2*1.12          = 11.68 mm
      //   layup (5)   = 2.7   -> 31.5 mm; sheath = 1 + 0.05*11.68 = 1.58
      //   OD          = 31.5 + 2*1.58          = 34.7 mm  (area 945 mm2)
      //   50 mm bore 44.3 -> 1541 mm2 * 0.53   = 817 mm2  < 945  => TOO SMALL
      //   63 mm bore 56.5 -> 2507 mm2 * 0.53   = 1329 mm2 > 945  => fits
      final spec = sizeConduit(70, 5);
      expect(spec.cableOdMm, closeTo(34.7, 0.2));
      expect(spec.conduitSizeMm, 63.0);

      // G5: the probe way is a MOTOR — motor-like ⇒ no neutral ⇒ the sized
      // grounding is 3L + PE = 4 cores, so the cable cell reads `4x70` (the
      // conduit basis is unchanged: the fallback ladder still sizes the
      // conservative 5-core bundle).
      final sheet = _scheduleForCsa(puil, 70, threePhase: true);
      final cable = _cableCells(sheet)
          .firstWhere((t) => t.contains('4x70 mm2'), orElse: () => '');
      expect(cable, isNotEmpty, reason: 'the 70 mm2 run must be on the sheet');
      expect(cable, isNot(contains('PVC 50mm')));
      expect(cable, contains('PVC 63mm'));
    });

    test('a run whose ladder pick already satisfies the fill is unchanged', () {
      // 5x16 mm2: the CSA ladder says 40 mm, the fill check only needs 32 mm —
      // the conservative max() keeps the ladder's 40 mm, so existing sheets do
      // not shift.
      expect(sizeConduit(16, 5).conduitSizeMm, 32.0);
      final sheet = _scheduleForCsa(puil, 16, threePhase: true);
      // G5: the motor probe has no neutral ⇒ `4x16` (see above).
      final cable = _cableCells(sheet)
          .firstWhere((t) => t.contains('4x16 mm2'), orElse: () => '');
      expect(cable, contains('PVC 40mm'));
    });

    test('a study-fed way prints the STUDY conduit verbatim', () {
      final result = computeSystem(puil, _mixedProject);
      final advanced = computeAdvancedStudy(puil, _mixedProject, result);
      final byCircuit = <String, ConduitSpec>{
        for (final c in advanced.containment.values)
          for (final cc in c.conduits) cc.circuitId: cc.conduit,
      };
      expect(byCircuit, isNotEmpty);
      final sheet = buildElectricalPanelDetail(
        project: _mixedProject,
        result: result,
        panelId: 'MDP',
        containmentByCircuitId: byCircuit,
      );
      final mdp = result.panels['MDP']!;
      for (final c in mdp.circuits) {
        final spec = byCircuit[c.circuitId];
        if (spec == null) continue;
        final want = spec.fillPct > conduitFillSingle * 100
            ? ' · tray'
            : ' · PVC ${spec.conduitSizeMm.round()}mm';
        // G5: the schedule prints the REAL core count the sizing resolved
        // (3L+PE for a motor, 3L+N+PE otherwise) — the same count the
        // containment study sizes its conduit from.
        final cores = c.grounding.cores;
        final cell = _cableCells(sheet).firstWhere(
            (t) => t.contains('${cores}x${_numText(c.cable.csaMm2)} mm2'),
            orElse: () => '');
        expect(cell, isNotEmpty);
        expect(cell, contains(want),
            reason: 'way ${c.circuitId}: the schedule must state the study '
                'conduit "$want"');
      }
    });

    test('the study map and the fallback agree on "no conduit fits" = tray', () {
      // 5x150 mm2 exceeds even the 63 mm bore at the 53 % limit, so BOTH paths
      // print `tray` rather than one issuing a 72 %-full conduit.
      final spec = sizeConduit(150, 5);
      expect(spec.conduitSizeMm, 63.0);
      expect(spec.fillPct, greaterThan(conduitFillSingle * 100));
      final sheet = _scheduleForCsa(puil, 150, threePhase: true);
      // G5: the motor probe has no neutral ⇒ `4x150` (see above).
      final cable = _cableCells(sheet)
          .firstWhere((t) => t.contains('4x150 mm2'), orElse: () => '');
      expect(cable, contains(' · tray'));
    });
  });

  // ── X1 — the mechanical riser's labels vs the sheet's own ink ─────────────
  group('X1 — mechanical riser label integrity', () {
    test('no label is struck through by a pipe run / riser leg', () {
      final s = _plantSheet();
      final legs = s.prims.whereType<SldLine>().where((l) =>
          l.weight == SldWeight.medium &&
          (l.x1 == l.x2 || l.y1 == l.y2)); // the axis-aligned L-route legs
      for (final l in s.prims.whereType<SldLabel>()) {
        final b = _labelBox(l);
        for (final leg in legs) {
          final legBox = (
            minX: leg.x1 < leg.x2 ? leg.x1 : leg.x2,
            minY: leg.y1 < leg.y2 ? leg.y1 : leg.y2,
            maxX: leg.x1 > leg.x2 ? leg.x1 : leg.x2,
            maxY: leg.y1 > leg.y2 ? leg.y1 : leg.y2,
          );
          expect(_overlaps(b, legBox), isFalse,
              reason: 'label "${l.text}" is drawn through a pipe leg');
        }
      }
    });

    test('no label is printed over an equipment glyph', () {
      final s = _plantSheet();
      // Every drawn equipment glyph is a rect/circle cluster around a node; the
      // sheet's own component markers are the rects that are NOT the bordered
      // detail / notes blocks (those are far wider than a glyph).
      final glyphs = s.prims
          .whereType<SldRect>()
          .where((r) => r.w <= 24 && r.h <= 24)
          .toList();
      expect(glyphs, isNotEmpty);
      for (final l in s.prims.whereType<SldLabel>()) {
        final b = _labelBox(l);
        for (final g in glyphs) {
          expect(
              _overlaps(b, (
                minX: g.x,
                minY: g.y,
                maxX: g.x + g.w,
                maxY: g.y + g.h
              )),
              isFalse,
              reason: 'label "${l.text}" is drawn over an equipment glyph');
        }
      }
    });

    test('every tag still survives — nothing is dropped to make room', () {
      final texts = _labelTexts(_plantSheet());
      for (final want in [
        'Ground tank · 5.0 m3',
        'Pump · 2.2 kW',
        '32-CW-PPR - 1.6 m',
        '32-CW-PPR-BOOSTER - 4.4 m',
        'WC',
      ]) {
        expect(texts, contains(want));
      }
    });

    test('no two labels overlap each other either', () {
      final labels = _plantSheet().prims.whereType<SldLabel>().toList();
      for (var i = 0; i < labels.length; i++) {
        for (var j = i + 1; j < labels.length; j++) {
          expect(_overlaps(_labelBox(labels[i]), _labelBox(labels[j])), isFalse,
              reason: '"${labels[i].text}" / "${labels[j].text}"');
        }
      }
    });

    test('a leader lands on the NEAR end of the tag, never across it', () {
      final s = _plantSheet();
      final leaders = s.prims.whereType<SldLine>().where(
          (l) => l.weight == SldWeight.thin && l.x1 != l.x2 && l.y1 != l.y2);
      expect(leaders, isNotEmpty, reason: 'the cluster must divert something');
      for (final l in s.prims.whereType<SldLabel>()) {
        final b = _labelBox(l);
        for (final ld in leaders) {
          // A leader may touch the label's edge; it must not END inside it.
          final insideX = ld.x2 > b.minX + 0.5 && ld.x2 < b.maxX - 0.5;
          final insideY = ld.y2 > b.minY - 0.5 && ld.y2 < b.maxY + 0.5;
          expect(insideX && insideY, isFalse,
              reason: 'a leader ends inside "${l.text}"');
        }
      }
    });
  });

  // ── X2 — the overview's feeder annotations at a bus split ─────────────────
  group('X2 — overview feeder annotations', () {
    test('three feeders off ONE bus do not overprint', () {
      final result = computeSystem(puil, _splitProject);
      final s = buildElectricalOverview(project: _splitProject, result: result);
      final tags = s.prims
          .whereType<SldLabel>()
          .where((l) => l.text.contains(' mm2 · '))
          .toList();
      expect(tags.length, 3);
      for (var i = 0; i < tags.length; i++) {
        for (var j = i + 1; j < tags.length; j++) {
          final a = tags[i], b = tags[j];
          double w(SldLabel l) =>
              l.text.length * l.size * kElectricalRiserLabelCharW;
          final overlap = a.x < b.x + w(b) &&
              b.x < a.x + w(a) &&
              a.y - a.size < b.y &&
              b.y - b.size < a.y;
          expect(overlap, isFalse,
              reason: '"${a.text}" overprints "${b.text}"');
        }
      }
      // Each feeder still states its own run length — none was dropped.
      for (final m in ['18 m', '24 m', '30 m']) {
        expect(tags.where((t) => t.text.endsWith(m)), isNotEmpty);
      }
    });

    test('a single-feeder parent keeps its exact legacy anchor', () {
      final result = computeSystem(puil, _singleFeederProject);
      final s = buildElectricalOverview(
          project: _singleFeederProject, result: result);
      final tags = s.prims
          .whereType<SldLabel>()
          .where((l) => l.text.contains(' mm2 · '))
          .toList();
      expect(tags.length, 1);
      // No collision ⇒ no leader was added for it (a leader is the only thin
      // diagonal line on an overview).
      expect(
          s.prims.whereType<SldLine>().where((l) =>
              l.weight == SldWeight.thin && l.x1 != l.x2 && l.y1 != l.y2),
          isEmpty);
    });
  });
}

/// The engine's own number formatting for a schedule figure (integer when
/// whole, else one decimal) — mirrored here so expectations read like the sheet.
String _numText(double v) =>
    v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);

/// A one-board schedule whose single way is forced onto [csaMm2] via an
/// explicit cable override, so the conduit token for that exact conductor can
/// be read off the sheet.
SldSheet _scheduleForCsa(PuilProfile puil, double csaMm2,
    {required bool threePhase}) {
  final project = ElectricalProject(
    id: 'p-csa',
    name: 'CSA probe',
    panels: [
      ElectricalPanel(
        id: 'P',
        name: 'P',
        system: threePhase
            ? ElectricalSystem.threePhase
            : ElectricalSystem.singlePhase,
        voltage: threePhase ? const Voltage(400) : const Voltage(220),
        circuits: [
          ElectricalCircuit(
            id: 'w1',
            name: 'Probe',
            loadKind: LoadKind.motor,
            motorKw: threePhase ? 30 : 5,
            cableType: 'NYY',
            length: const Length(20),
            cableOverrideMm2: csaMm2,
          ),
        ],
      ),
    ],
  );
  final result = computeSystem(puil, project);
  return buildElectricalPanelDetail(
      project: project, result: result, panelId: 'P');
}
