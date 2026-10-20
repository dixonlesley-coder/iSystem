// Round 37 (2026-10-18) — electrical-sim-4-capacitor-bank-missing-from-bom.
//
// The capacitor bank the PF study counts / recommends and the customer
// transformer(s) the schedule and drawings size are taken off the BOM, each
// with a deterministic `elec:` price key (unmatched against the catalogue, so
// the quotation prices it or counts it unpriced — never drops it).
import 'package:mechx_engine/electrical/advanced_study.dart';
import 'package:mechx_engine/electrical/bom.dart';
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

const _p = PuilProfile();

List<ElectricalCircuit> _motors() => [
      for (var i = 0; i < 4; i++)
        ElectricalCircuit(
          id: 'm$i',
          name: 'Motor $i',
          loadKind: LoadKind.motor,
          motorKw: 30,
          cosPhi: 0.8,
          phases: 3,
          length: const Length(20),
        ),
    ];

List<BomLine> _bom(ElectricalProject p) {
  final sys = computeSystem(_p, p);
  return computeAdvancedStudy(_p, p, sys).bom.lines;
}

void main() {
  test('4 x 30 kW motors + a declared 100 kvar LV bank: one capacitor-bank '
      'line, priced on its kvar', () {
    final lines = _bom(ElectricalProject(
      capacitorBankKvar: 100,
      panels: [ElectricalPanel(id: 'mdp', name: 'MDP', circuits: _motors())],
    ));
    final bank = lines.where((l) =>
        l.priceKey == '${kElecPriceKeyPrefix}capacitor-bank:100kvar');
    expect(bank, hasLength(1));
    expect(bank.single.description, contains('Capacitor bank 100 kvar'));
    expect(bank.single.qty, 1);
  });

  test('a capacitor WAY (150 kvar) is taken off once, even with the same '
      'bank also declared on the LV bus', () {
    final lines = _bom(ElectricalProject(
      capacitorBankKvar: 150,
      panels: [
        ElectricalPanel(id: 'mdp', name: 'MDP', circuits: [
          ..._motors(),
          const ElectricalCircuit(
            id: 'cap',
            name: 'PFC',
            loadKind: LoadKind.capacitor,
            loadW: 150000,
            phases: 3,
            length: Length(5),
          ),
        ]),
      ],
    ));
    final banks =
        lines.where((l) => (l.priceKey ?? '').contains('capacitor-bank')).toList();
    expect(banks, hasLength(1));
    expect(banks.single.priceKey,
        '${kElecPriceKeyPrefix}capacitor-bank:150kvar');
  });

  test('no bank installed: the PF study\'s recommended bank is taken off', () {
    final p = ElectricalProject(
      panels: [ElectricalPanel(id: 'mdp', name: 'MDP', circuits: _motors())],
    );
    final sys = computeSystem(_p, p);
    final study = computeAdvancedStudy(_p, p, sys);
    final pf = study.powerFactor;
    final rec = study.bom.lines
        .where((l) => l.description.contains('APFC, recommended'))
        .toList();
    if (pf.needed && pf.bankKvar > 0) {
      expect(rec, hasLength(1));
      expect(rec.single.qty, pf.banks < 1 ? 1 : pf.banks);
    } else {
      expect(rec, isEmpty);
    }
  });

  test('a dual 2 x 500 kVA declared service: a transformer line, qty 2', () {
    final lines = _bom(ElectricalProject(
      supplyCapacityVa: const ApparentPower(1000000),
      dualTransformer: true,
      panels: [ElectricalPanel(id: 'mdp', name: 'MDP', circuits: _motors())],
    ));
    final tx = lines
        .where((l) => l.priceKey == '${kElecPriceKeyPrefix}transformer:500kva')
        .toList();
    expect(tx, hasLength(1));
    expect(tx.single.qty, 2);
  });

  test('an LV service with no bank: no transformer, no bank line', () {
    final lines = _bom(const ElectricalProject(
      panels: [
        ElectricalPanel(id: 'mdp', name: 'MDP', circuits: [
          ElectricalCircuit(
              id: 'h',
              name: 'Heater',
              loadKind: LoadKind.heating,
              loadW: 5000,
              cosPhi: 1,
              length: const Length(10)),
        ]),
      ],
    ));
    expect(lines.where((l) => (l.priceKey ?? '').contains('transformer')), isEmpty);
    expect(lines.where((l) => (l.priceKey ?? '').contains('capacitor-bank')), isEmpty);
  });
}
