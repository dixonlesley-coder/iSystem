// Round 66 (elec-convergence-18-sectioned-service-one-main-earthing-set) — a
// SECTIONED (N-transformer) service takes off one transformer neutral
// (star-point) earthing conductor per section, each sized on its own
// section's service; the MET -> electrode conductor and the main bonding
// conductor stay single (one MET per installation, IEC 60364-5-54).
//
// Mall: transformerUnits = 3, TN-C-S, three service-entrance boards A / B /
// C of decreasing demand, each on its own section (roots = sections ⇒ one
// board per section). The star point of each unit is earthed by a conductor
// derived exactly like the main earthing conductor (Round 24 / 29: the
// service cable's PE per Table 54.7, times its parallel runs, floored at
// 16 mm2, made up on the section ladder) from THAT section's root incomer —
// so B's and C's conductors follow their own (smaller) incomers, never the
// governing A root's. A single-transformer service adds nothing.
library;

import 'package:mechx_engine/electrical/advanced_study.dart';
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/earthing.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/sizing.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

const _profile = PuilProfile();

ElectricalPanel _root(String id, double kw) => ElectricalPanel(
      id: id,
      name: 'LVMDP-$id',
      circuits: [
        for (var i = 0; i < 4; i++)
          ElectricalCircuit(
              id: '$id$i',
              name: 'Load $id$i',
              loadKind: LoadKind.motor,
              loadW: kw * 1000 / 4,
              cosPhi: 1,
              phases: 3,
              length: const Length(10)),
      ],
    );

ElectricalProject _mall({int? units}) => ElectricalProject(
      id: 'm',
      name: 'Mall',
      earthingSystem: EarthingSystem.tnCs,
      transformerUnits: units,
      transformerKva: units == null ? null : const ApparentPower(1000e3),
      panels: [_root('A', 700), _root('B', 450), _root('C', 350)],
    );

const _starPoint = 'Transformer neutral (star-point) earthing conductor';

void main() {
  test('3 sections: one star-point conductor per section, own incomer', () {
    final pr = _mall(units: 3);
    final sys = computeSystem(_profile, pr);
    final st = computeAdvancedStudy(_profile, pr, sys);
    final lines = [
      for (final l in st.bom.lines)
        if (l.description.startsWith(_starPoint)) l,
    ];
    expect(lines, hasLength(3));
    final sections = serviceSectionOfRoot(pr, sys);
    expect(sections.values.toSet(), {0, 1, 2});
    for (final id in ['A', 'B', 'C']) {
      final inA = sys.panels[id]!.incomer.breaker.ratingA;
      final cable = sizeCable(_profile,
          designCurrent: inA,
          breakerRating: inA,
          deratingFactor: 1,
          minSectionMm2: 4);
      final m = tnMainEarthingConductor(
          _profile, _profile.peConductorSizeMm2(cable.csaMm2),
          runsPerPhase: cable.runsPerPhase ?? 1);
      final line =
          lines.singleWhere((l) => l.description.contains('(LVMDP-$id)'));
      expect(line.qty, m.count.toDouble(), reason: id);
      final csa = m.perConductorMm2 == m.perConductorMm2.roundToDouble()
          ? m.perConductorMm2.toInt().toString()
          : m.perConductorMm2.toString();
      expect(line.description, contains('BC 1x$csa mm²'), reason: id);
      expect(line.description, contains('TX-${sections[id]! + 1} section'),
          reason: id);
    }
    // The MET -> electrode conductor and the bonding conductor stay single.
    expect(
        st.bom.lines
            .where((l) => l.description.startsWith('Main earthing conductor')),
        hasLength(1));
    expect(
        st.bom.lines.where((l) =>
            l.description.startsWith('Main protective bonding conductor')),
        hasLength(1));
  });

  test('a single-transformer service adds no star-point line', () {
    final pr = _mall();
    final st = computeAdvancedStudy(_profile, pr, computeSystem(_profile, pr));
    expect(st.bom.lines.where((l) => l.description.startsWith(_starPoint)),
        isEmpty);
  });
}
