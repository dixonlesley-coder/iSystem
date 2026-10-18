// Round 12 (2026-10-18) — printed-parity + report-recompute findings, each
// pinned against the engine's own primitives (first-principles derivations in
// the comments).
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/headroom.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/sizing.dart';
import 'package:mechx_engine/electrical/sources.dart';
import 'package:mechx_engine/geometry/building.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/network/zoning.dart';
import 'package:mechx_engine/report/calc_report.dart';
import 'package:mechx_engine/report/electrical_calc_report.dart';
import 'package:mechx_engine/report/electrical_sld_drawing.dart';
import 'package:mechx_engine/report/equipment_schedule.dart';
import 'package:mechx_engine/report/mechanical_sld_drawing.dart';
import 'package:mechx_engine/report/mep_report.dart';
import 'package:mechx_engine/report/riser_tags.dart';
import 'package:mechx_engine/sizing/fan.dart';
import 'package:mechx_engine/sizing/fire_pump_rating.dart';
import 'package:mechx_engine/sizing/fire_standpipe.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/standards/sni.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

const _puil = PuilProfile();

CalcReportData _mech({
  BuildingLevels building = const BuildingLevels([Floor('G', Length(4))]),
  List<DownfeedZoneStatic> zones = const [],
  FireStandpipeDesign? standpipe,
  FirePumpRatingResult? rating,
  List<({String tag, FanDuty duty})> supplyFans = const [],
  FanDuty? fan,
  List<Revision> revisions = const [],
}) =>
    CalcReportData(
      projectName: 'R12',
      date: '2026-10-18',
      standardsName: 'SNI',
      standardsRevision: 'r',
      verifyItems: const [],
      building: building,
      feedStrategy: 'Upfeed',
      targetResidual: const Pressure(100000),
      zones: zones,
      standpipe: standpipe,
      firePumpRating: rating,
      supplyFans: supplyFans,
      fan: fan,
      revisions: revisions,
    );

List<String> _labels(SldSheet s) => [
      for (final p in s.prims)
        if (p is SldLabel) p.text,
    ];

void main() {
  group('report-recompute-genset-prime-kva-mismatch', () {
    // One 3φ MDP, 4 × 15 kW HVAC ways (demand 60 kW / 0.85 = 70.6 kVA).
    ElectricalProject project(GeneratorMode mode) => ElectricalProject(
          id: 'g',
          name: 'G',
          sources: ElectricalSources(generator: GeneratorSource(mode: mode)),
          panels: [
            ElectricalPanel(
              id: 'MDP',
              name: 'MDP',
              system: ElectricalSystem.threePhase,
              voltage: const Voltage(400),
              circuits: [
                for (var i = 0; i < 4; i++)
                  ElectricalCircuit(
                    id: 'h$i',
                    name: 'HVAC $i',
                    loadKind: LoadKind.hvac,
                    loadW: 15000,
                    phases: 3,
                    length: const Length(10),
                  ),
              ],
            ),
          ],
        );

    for (final mode in GeneratorMode.values) {
      test('$mode: drawings + G-01 print the sizeGenerator rating', () {
        final p = project(mode);
        final r = computeSystem(_puil, p);
        final demandVa = r.supply.demandVa;
        // The ONE sizing basis: prime ⇒ 1.25 × backup, standby ⇒ backup.
        final expected = sizeGenerator(demandVa, mode: mode).ratingKva;
        final kva = expected.inKilovoltAmperes.round();
        if (mode == GeneratorMode.prime) {
          // 70.6 × 1.25 = 88.2 kVA ⇒ the 100 kVA rung (not 82).
          expect(kva, 100);
        }
        final overview =
            buildElectricalOverview(project: p, result: r, sourceChain: true);
        expect(_labels(overview), contains('GENSET $kva kVA'));
        final rows = buildEquipmentScheduleRows(EquipmentScheduleData(
            projectName: 'G', date: 'd', electrical: r, electricalProject: p));
        expect(rows.firstWhere((row) => row.tag == 'G-01').duty, '$kva kVA');
      });
    }
  });

  test('report-recompute-earthing-ignores-headroom — earthing follows the '
      'headroom-sized incomer', () {
    ElectricalProject p(HeadroomSpec? h) => ElectricalProject(
          id: 'e',
          name: 'E',
          panels: [
            ElectricalPanel(
              id: 'MDP',
              name: 'MDP',
              system: ElectricalSystem.threePhase,
              voltage: const Voltage(400),
              headroom: h,
              circuits: [
                for (var i = 0; i < 2; i++)
                  ElectricalCircuit(
                    id: 'h$i',
                    name: 'HVAC $i',
                    loadKind: LoadKind.hvac,
                    loadW: 12000,
                    phases: 3,
                    length: const Length(10),
                  ),
              ],
            ),
          ],
        );
    final base = computeSystem(_puil, p(null));
    final doubled =
        computeSystem(_puil, p(const HeadroomSpec(sparePercentage: 100)));
    final incomer = doubled.panels['MDP']!.incomer.breaker.ratingA;
    expect(incomer.amperes,
        greaterThan(base.panels['MDP']!.incomer.breaker.ratingA.amperes));
    // First principles: Ib = 2 × 12 kW / (√3·400·0.85) = 40.8 A; 100 %
    // headroom rates the incomer for 81.6 A ⇒ the 100 A rung. The service
    // cable that device protects is sized at 100 A / In 100 A ⇒ 50 mm²
    // (the probe in the finding) ⇒ PE 25 mm² ⇒ main earthing = max(16, 25)
    // = 25 mm² — where the demand basis printed 16 mm².
    expect(incomer.amperes, 100);
    final cable = sizeCable(_puil,
        designCurrent: incomer,
        breakerRating: incomer,
        deratingFactor: 1,
        minSectionMm2: 4);
    expect(cable.csaMm2, 50);
    final pe = _puil.peConductorSizeMm2(cable.csaMm2);
    expect(pe, 25);
    expect(doubled.earthing.mainEarthingConductorMm2, 25);
    expect(base.earthing.mainEarthingConductorMm2, 16);
    expect(doubled.earthing.mainBondingConductorMm2,
        greaterThan(base.earthing.mainBondingConductorMm2));
  });

  test('report-recompute-zone-floor-labels — zones name the Building floors',
      () {
    final md = buildCalcReportMarkdown(_mech(
      building: const BuildingLevels([
        Floor('B2', Length(3)),
        Floor('B1', Length(3)),
        Floor('G', Length(4)),
        Floor('L1', Length(3.5)),
        Floor('L2', Length(3.5)),
      ], groundIndex: 2),
      zones: const [
        DownfeedZoneStatic(
            zone: PressureZone(4, 2),
            topResidual: Pressure(150000),
            bottomStatic: Pressure(400000),
            withinLimit: true),
      ],
    ));
    expect(md, contains('| G–L2 |'));
    expect(md, isNot(contains('| 3–5 |')));
  });

  test('printed-parity-4 — one fire pump, one flow, labelled shaft power', () {
    final st = designStandpipe(risers: 1, buildingHeight: const Length(12));
    final rating = checkFirePumpRating(
        ratedFlow: st.requiredFlow, ratedHead: st.pumpHead);
    final md = buildCalcReportMarkdown(_mech(standpipe: st, rating: rating));
    final lps = st.requiredFlow.inLitersPerSecond.toStringAsFixed(1);
    expect(md, contains('**$lps L/s**'));
    expect(md, contains('rated $lps L/s'));
    expect(md, contains('kW shaft at rated point'));
    // The shared duty the schedule + EMG way read carries the NFPA 20 motor.
    final duty = firePumpDuty(
        ratedFlow: st.requiredFlow, ratedHead: st.pumpHead, rating: rating);
    expect(duty.selectedMotor.watts, rating.selectedMotor.watts);
  });

  test('report-recompute-second-ahu-missing — every supply unit is reported',
      () {
    final a = sizeFan(
        airflow: const FlowRate(0.5), totalStaticPressure: const Pressure(288));
    final b = sizeFan(
        airflow: const FlowRate(0.4), totalStaticPressure: const Pressure(292));
    final md = buildCalcReportMarkdown(_mech(
      fan: a,
      supplyFans: [(tag: 'AHU-01', duty: a), (tag: 'AHU-02', duty: b)],
    ));
    expect(md, contains('AHU-01:'));
    expect(md, contains('AHU-02:'));
    expect(md, contains('**400 L/s** · total static 292 Pa'));
    // One unit ⇒ legacy single trunk rows (byte-identical).
    final single = buildCalcReportMarkdown(
        _mech(fan: a, supplyFans: [(tag: 'AHU-01', duty: a)]));
    expect(single, buildCalcReportMarkdown(_mech(fan: a)));
  });

  group('report-recompute-fault-basis-omitted', () {
    const project = ElectricalProject(id: 'f', name: 'F', panels: [
      ElectricalPanel(id: 'MDP', name: 'MDP', circuits: [
        ElectricalCircuit(
            id: 'c', name: 'L', loadKind: LoadKind.lighting, loadW: 500),
      ]),
    ]);
    final result = computeSystem(_puil, project);
    ElectricalCalcReportData data(
            {double? fault, double? ct, FaultLevelBasis? basis}) =>
        ElectricalCalcReportData(
          projectName: 'F',
          date: 'd',
          standardsName: 'PUIL',
          standardsRevision: '2011',
          project: project,
          result: result,
          originFaultLevelA: fault,
          busbarClearingTimeS: ct,
          faultLevelBasis: basis,
        );

    test('a clearing time prints even without a fault level', () {
      final md = buildElectricalCalcReport(data(ct: 0.2));
      expect(md, contains('Busbar clearing time:'));
      expect(md, contains('**0.20 s**'));
    });

    test('the effective default prints with its provenance', () {
      final md = buildElectricalCalcReport(
          data(fault: 16000, ct: 0.1, basis: FaultLevelBasis.defaultValue));
      expect(md, contains('**16 kA**'));
      expect(md, contains('default — no service declared'));
    });
  });

  test('report-recompute-mep-revisions-duplicated — one revision prints once',
      () {
    const rev = Revision('2026-07-06', 'Issued for construction (Rev. 0)');
    const project = ElectricalProject(id: 'm', name: 'M', panels: [
      ElectricalPanel(id: 'MDP', name: 'MDP', circuits: [
        ElectricalCircuit(
            id: 'c', name: 'L', loadKind: LoadKind.lighting, loadW: 500),
      ]),
    ]);
    final md = buildMepUnifiedReport(
      mechanical: _mech(revisions: const [rev]),
      electrical: ElectricalCalcReportData(
        projectName: 'M',
        date: 'd',
        standardsName: 'PUIL',
        standardsRevision: '2011',
        project: project,
        result: computeSystem(_puil, project),
        revisions: const [rev],
      ),
      compliance: const ComplianceSummary(date: 'd', items: []),
    );
    expect('Issued for construction (Rev. 0)'.allMatches(md).length, 1);
  });

  group('printed-parity-3 — TRANSFER only with a roof tank', () {
    Network net({required bool roofTank}) => Network(
          nodes: [
            const NetNode(
                id: 'gt',
                sheetId: 's',
                x: 0,
                y: 0,
                floorIndex: 0,
                role: NodeRole.plant,
                component: NodeComponent.groundTank),
            const NetNode(
                id: 'p',
                sheetId: 's',
                x: 50,
                y: 0,
                floorIndex: 0,
                role: NodeRole.plant,
                component: NodeComponent.pump),
            const NetNode(id: 'j', sheetId: 's', x: 50, y: 0, floorIndex: 1),
            roofTank
                ? const NetNode(
                    id: 'top',
                    sheetId: 's',
                    x: 50,
                    y: 0,
                    floorIndex: 2,
                    role: NodeRole.plant,
                    component: NodeComponent.roofTank)
                : const NetNode(
                    id: 'top',
                    sheetId: 's',
                    x: 100,
                    y: 0,
                    floorIndex: 1,
                    role: NodeRole.fixture),
          ],
          edges: [
            const NetEdge(
                id: 'suc', fromId: 'gt', toId: 'p', service: ServiceType.coldWater),
            const NetEdge(
                id: 'up',
                fromId: 'p',
                toId: 'j',
                service: ServiceType.coldWater,
                kind: EdgeKind.riser),
            NetEdge(
                id: 'last',
                fromId: 'j',
                toId: 'top',
                service: ServiceType.coldWater,
                kind: roofTank ? EdgeKind.riser : EdgeKind.run),
          ],
        );
    const building = BuildingLevels([
      Floor('G', Length(4)),
      Floor('L1', Length(3.5)),
      Floor('L2', Length(3.5)),
    ]);

    test('upfeed ground-tank booster: no TRANSFER, suction not BOOSTER', () {
      final n = net(roofTank: false);
      final labels = _labels(buildMechanicalRiserSld(
          network: n, building: building, detailCallouts: true));
      expect(labels, isNot(contains('TRANSFER')));
      expect(labels, contains('BOOSTER'));
      expect(riserFunctionFor(n, n.edgeById('suc')!, downfeed: false), isNull);
      expect(riserFunctionFor(n, n.edgeById('up')!, downfeed: false),
          RiserFunction.booster);
    });

    test('ground tank + roof tank: TRANSFER', () {
      final labels = _labels(buildMechanicalRiserSld(
          network: net(roofTank: true), building: building, detailCallouts: true));
      expect(labels, contains('TRANSFER'));
    });
  });

  test('report-recompute-verify-items — standpipe + HW constants are listed',
      () {
    for (final v in [...standpipeVerifyChecklist]) {
      expect(v.verified, isFalse);
      expect(v.note, isNotNull);
    }
    expect(standpipeVerifyChecklist.map((v) => v.value), containsAll([15.0, 0.70]));
  });
}
