import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/report/equipment_schedule.dart';
import 'package:mechx_engine/sizing/fan.dart';
import 'package:mechx_engine/sizing/pump.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

void main() {
  // ── Pump row ────────────────────────────────────────────────────────────
  // Duty: Q = 0.02 m³/s (= 20.0 L/s), H = 30 m, default η_pump = 0.70.
  //   Hydraulic P = ρ·g·Q·H = 1000 · 9.81 · 0.02 · 30 = 5886 W.
  //   Shaft P     = 5886 / 0.70 = 8408.57 W = 8.41 kW.
  //   selectMotor picks the smallest standard ≥ 8.41 kW ⇒ 11.0 kW.
  test('a pump duty produces a schedule row with flow/head and motor size', () {
    final pump = sizePump(
      flow: const FlowRate(0.02),
      head: const Head(30),
    );
    // Sanity-check the hand-computed selected motor.
    expect(pump.selectedMotor.inKiloWatts, closeTo(11.0, 1e-9));

    final data = EquipmentScheduleData(
      projectName: 'Test building',
      date: '2026-06-27',
      pumps: [
        PumpScheduleItem(
          duty: pump,
          service: 'Domestic water supply',
          tag: 'P-01',
        ),
      ],
    );

    final rows = buildEquipmentScheduleRows(data);
    expect(rows, hasLength(1));
    final r = rows.single;
    expect(r.category, EquipmentCategory.pump);
    expect(r.tag, 'P-01');
    expect(r.service, 'Domestic water supply');
    // 20.0 L/s @ 30.0 m.
    expect(r.duty, '20.0 L/s @ 30.0 m');
    // 11.00 kW motor.
    expect(r.size, '11.00 kW motor');
    expect(r.modelSpec, '—');
    expect(r.qty, 1);

    final md = buildEquipmentScheduleMarkdown(data);
    expect(md, contains('# Equipment schedule'));
    expect(md, contains('## Pumps'));
    expect(md, contains('| P-01 | Domestic water supply | 20.0 L/s @ 30.0 m'));
  });

  // ── Fan row ─────────────────────────────────────────────────────────────
  // Duty: Q = 0.15 m³/s (= 150 L/s), Δp = 50 Pa, default η_fan = 0.65.
  //   Air P   = Q·Δp = 0.15 · 50 = 7.5 W.
  //   Shaft P = 7.5 / 0.65 = 11.54 W = 0.01154 kW.
  //   selectMotor picks the smallest standard ≥ 0.01154 kW ⇒ 0.37 kW.
  test('a fan duty produces a schedule row with airflow/pressure and motor', () {
    final fan = sizeFan(
      airflow: const FlowRate(0.15),
      totalStaticPressure: const Pressure(50),
    );
    expect(fan.selectedMotor.inKiloWatts, closeTo(0.37, 1e-9));

    final data = EquipmentScheduleData(
      projectName: 'Test building',
      date: '2026-06-27',
      fans: [
        FanScheduleItem(
          duty: fan,
          service: 'Exhaust air',
          tag: 'F-01',
        ),
      ],
    );

    final rows = buildEquipmentScheduleRows(data);
    expect(rows, hasLength(1));
    final r = rows.single;
    expect(r.category, EquipmentCategory.fan);
    expect(r.tag, 'F-01');
    expect(r.service, 'Exhaust air');
    // 150 L/s @ 50 Pa (airflow + pressure rounded to whole units).
    expect(r.duty, '150 L/s @ 50 Pa');
    // 0.37 kW motor.
    expect(r.size, '0.37 kW motor');
    expect(r.qty, 1);

    final md = buildEquipmentScheduleMarkdown(data);
    expect(md, contains('## Fans'));
    expect(md, contains('| F-01 | Exhaust air | 150 L/s @ 50 Pa'));
  });

  // ── AHU/FCU/AC grouping + sequential tags ───────────────────────────────
  test('air-handling fans land in their own section with AHU- tags', () {
    final ahu = sizeFan(
      airflow: const FlowRate(0.5),
      totalStaticPressure: const Pressure(200),
    );
    final data = EquipmentScheduleData(
      projectName: 'B',
      date: 'd',
      fans: [
        FanScheduleItem(duty: ahu, service: 'Office AHU', airHandling: true),
      ],
    );
    final rows = buildEquipmentScheduleRows(data);
    expect(rows.single.category, EquipmentCategory.airHandling);
    // No tag supplied ⇒ synthesised AHU-01.
    expect(rows.single.tag, 'AHU-01');
    expect(buildEquipmentScheduleMarkdown(data),
        contains('## Air-handling (AHU / FCU / AC)'));
  });

  // ── Electrical panel row ────────────────────────────────────────────────
  test('a solved panel produces one schedule row (tag + demand + incomer)', () {
    const profile = PuilProfile();
    const project = ElectricalProject(
      id: 'p1',
      name: 'Test building',
      panels: [
        ElectricalPanel(
          id: 'MDP',
          name: 'MDP',
          tag: 'MDP',
          circuits: [
            ElectricalCircuit(
              id: 'c1',
              name: 'Lighting',
              loadKind: LoadKind.lighting,
              isLighting: true,
              loadW: 1800,
              length: Length(20),
            ),
            ElectricalCircuit(
              id: 'c2',
              name: 'Sockets',
              loadKind: LoadKind.socket,
              loadW: 3000,
              length: Length(20),
            ),
          ],
        ),
      ],
    );
    final result = computeSystem(profile, project);

    final data = EquipmentScheduleData(
      projectName: 'Test building',
      date: '2026-06-27',
      electrical: result,
    );

    final rows = buildEquipmentScheduleRows(data);
    expect(rows, hasLength(1));
    final r = rows.single;
    expect(r.category, EquipmentCategory.panel);
    expect(r.tag, 'MDP');
    expect(r.service, '3-phase distribution');
    expect(r.duty, contains('kW demand'));
    expect(r.size, contains('A incomer'));

    final md = buildEquipmentScheduleMarkdown(data);
    expect(md, contains('## Electrical panels'));
    expect(md, contains('| MDP | 3-phase distribution |'));
  });

  // ── Empty data set ──────────────────────────────────────────────────────
  test('an empty data set renders the no-equipment note', () {
    const data = EquipmentScheduleData(projectName: 'B', date: 'd');
    expect(buildEquipmentScheduleRows(data), isEmpty);
    expect(buildEquipmentScheduleMarkdown(data),
        contains('(no equipment scheduled)'));
  });

  // ── Sequential pump tags when none supplied ─────────────────────────────
  test('pumps without tags get sequential P-01, P-02 labels', () {
    final pump = sizePump(flow: const FlowRate(0.01), head: const Head(10));
    final data = EquipmentScheduleData(
      projectName: 'B',
      date: 'd',
      pumps: [
        PumpScheduleItem(duty: pump, service: 'A'),
        PumpScheduleItem(duty: pump, service: 'B'),
      ],
    );
    final rows = buildEquipmentScheduleRows(data);
    expect(rows.map((r) => r.tag), ['P-01', 'P-02']);
  });

  // ── CSV emitter ──────────────────────────────────────────────────────────
  group('equipmentScheduleToCsv', () {
    test('emits the header plus one plain line per row', () {
      // Pump duty as in the first test: 20.0 L/s @ 30.0 m → 11.00 kW motor.
      final pump = sizePump(flow: const FlowRate(0.02), head: const Head(30));
      final rows = buildEquipmentScheduleRows(EquipmentScheduleData(
        projectName: 'B',
        date: 'd',
        pumps: [
          PumpScheduleItem(
              duty: pump, service: 'Domestic water supply', tag: 'P-01'),
        ],
      ));
      expect(
        equipmentScheduleToCsv(rows),
        'tag,category,service,duty,size,model_spec,qty\n'
        'P-01,pump,Domestic water supply,20.0 L/s @ 30.0 m,11.00 kW motor,—,1\n',
      );
    });

    test('quotes cells containing commas / quotes / newlines (pinned)', () {
      // Hand-built row so every escape case is exercised: a comma in the
      // service, an embedded double quote (doubled per RFC 4180) in the
      // model/spec, and a newline in the duty.
      const rows = [
        EquipmentScheduleRow(
          tag: 'F-01',
          service: 'Kitchen, exhaust',
          duty: '150 L/s\n@ 50 Pa',
          size: '0.37 kW motor',
          modelSpec: 'per "approved" datasheet',
          qty: 2,
          category: EquipmentCategory.fan,
        ),
      ];
      expect(
        equipmentScheduleToCsv(rows),
        'tag,category,service,duty,size,model_spec,qty\n'
        'F-01,fan,"Kitchen, exhaust","150 L/s\n@ 50 Pa",0.37 kW motor,'
        '"per ""approved"" datasheet",2\n',
      );
    });

    test('an empty row list yields the header only', () {
      expect(equipmentScheduleToCsv(const []),
          'tag,category,service,duty,size,model_spec,qty\n');
    });
  });
}
