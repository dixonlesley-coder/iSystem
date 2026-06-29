import 'dart:convert';

import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/headroom.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/sources.dart';
import 'package:mechx_engine/report/electrical_dxf_export.dart';
import 'package:mechx_engine/report/electrical_pdf_export.dart';
import 'package:mechx_engine/report/electrical_sld_drawing.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

void main() {
  const profile = PuilProfile();

  // MDP feeds a 1-phase sub-panel LP-1 (one lighting way) + carries its own
  // motor way, so the drawing exercises feeders, ways, and both phase counts.
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
            id: 'f1',
            name: 'Feeder to LP-1',
            loadKind: LoadKind.feeder,
            feedsPanelId: 'LP1',
            length: Length(15),
          ),
          ElectricalCircuit(
            id: 'm1',
            name: 'Pompa',
            loadKind: LoadKind.motor,
            motorKw: 3,
            cableType: 'NYY',
            length: Length(22),
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
        fedByCircuitId: 'f1',
        circuits: [
          ElectricalCircuit(
            id: 'c1',
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

  final result = computeSystem(profile, project);
  final sheet = buildElectricalSld(project: project, result: result);

  test('emits a non-empty drawing with finite bounds', () {
    expect(sheet.isEmpty, isFalse);
    expect(sheet.minX.isFinite && sheet.maxX.isFinite, isTrue);
    expect(sheet.maxX, greaterThan(sheet.minX));
    expect(sheet.maxY, greaterThan(sheet.minY));
  });

  test('draws a block (rect) + a busbar (thick line) per panel', () {
    final rects = sheet.prims.whereType<SldRect>().length;
    final thick = sheet.prims.whereType<SldLine>().where(
        (l) => l.weight == SldWeight.thick);
    // Two panels → at least two outer blocks; each bus is two thick verticals.
    expect(rects, greaterThanOrEqualTo(2));
    expect(thick.length, greaterThanOrEqualTo(4));
  });

  test('labels carry the drafter way content (table columns + breaker/cable)',
      () {
    final texts =
        sheet.prims.whereType<SldLabel>().map((t) => t.text).toList();
    final joined = texts.join('\n');
    expect(joined, contains('Incomer'));
    expect(joined, contains('MCB'));
    // The aligned-table column headers (BRI DIAGRAM PANEL).
    expect(joined, contains('GRUP'));
    expect(joined, contains('PENGHANTAR'));
    expect(joined, contains('DAYA'));
    expect(joined, contains('KETERANGAN'));
    // The two cable families used appear verbatim.
    expect(joined, contains('NYM'));
    expect(joined, contains('NYY'));
    // The sub-panel name reads in the feeding way's KETERANGAN column.
    expect(joined, contains('-> LP-1'));
  });

  test('detail rows carry the Indonesian DIAGRAM PANEL conventions', () {
    final joined =
        sheet.prims.whereType<SldLabel>().map((t) => t.text).join('\n');
    // Schedule breaker leads with rating + phase: `MCB <A>A 1ph|3ph`.
    expect(RegExp(r'MC(B|CB) \d+A (1|3)ph').hasMatch(joined), isTrue);
    // Cable carries the ASCII mm2 unit suffix.
    expect(joined, contains('mm2'));
    // DAYA(WATT): the LP-1 lighting way's connected 1500 W reads as 1.5kW.
    expect(joined, contains('1.5kW'));
    // Busbar make-up reads "Cu bus".
    expect(joined, contains('Cu bus'));
    // A TOTAL footer per block.
    expect(joined, contains('TOTAL'));
    // ASCII-safe: no unicode phase glyph / squared metres in the labels.
    expect(joined.contains('Ø'), isFalse); // Ø
    expect(joined.contains('²'), isFalse); // ²
  });

  test('a panel with spare-ways + a fault level shows CADANGAN + Icw', () {
    // Headroom (2 spare ways) + an origin fault level (so the busbar withstand
    // fold runs ⇒ Icw is reported). MDP carries the headroom + fault.
    const hp = ElectricalProject(
      id: 'hp',
      name: 'Headroom',
      panels: [
        ElectricalPanel(
          id: 'MDP',
          name: 'MDP',
          headroom: HeadroomSpec(sparePercentage: 20, spareWays: 2),
          circuits: [
            ElectricalCircuit(
                id: 'm1', name: 'Pompa', loadKind: LoadKind.motor, motorKw: 5,
                length: Length(20)),
          ],
        ),
      ],
    );
    final hpResult = computeSystem(profile, hp,
        originFaultLevel: const Current(16000), busbarClearingTimeS: 0.1);
    final hpSheet = buildElectricalSld(project: hp, result: hpResult);
    final joined =
        hpSheet.prims.whereType<SldLabel>().map((t) => t.text).join('\n');
    expect(joined, contains('CADANGAN'));
    expect(joined, contains('Icw'));
  });

  test('the feeder is routed (medium lines) from the way to the sub-panel', () {
    final medium = sheet.prims
        .whereType<SldLine>()
        .where((l) => l.weight == SldWeight.medium);
    // The orthogonal feeder channel is ≥ 3 medium segments.
    expect(medium.length, greaterThanOrEqualTo(3));
  });

  test('legend lists the symbols actually used + a supply note', () {
    final codes = sheet.legend.map((e) => e.code).toList();
    expect(codes, contains('MCB'));
    expect(codes, contains('Ib'));
    expect(codes.any((c) => c.startsWith('Curve')), isTrue);
    expect(codes, contains('NYM'));
    expect(sheet.supplyNote, contains('kVA'));
  });

  test('breakerLabel / cableLabel format to drafter notation', () {
    const profile = PuilProfile();
    final b = profile.breakerClassFor(16);
    expect(b, BreakerClass.mcb);
    // 1-phase lighting cable: 3-core notation, family preserved.
    expect(cableLabel(null, 2.5, false), 'Cu 3x2.5');
    // 3-phase: 5-core notation.
    expect(cableLabel(null, 6, true), 'Cu 5x6');
  });

  test('an empty project yields an empty drawing (no blocks)', () {
    const empty = ElectricalProject(id: 'e', name: 'Empty');
    final emptyResult = computeSystem(profile, empty);
    final emptySheet =
        buildElectricalSld(project: empty, result: emptyResult);
    expect(emptySheet.prims.whereType<SldRect>(), isEmpty);
  });

  group('single-panel detail filter (onlyPanelId / buildElectricalPanelDetail)',
      () {
    test('emits ONE block at origin with only that panel\'s ways', () {
      final detail =
          buildElectricalPanelDetail(project: project, result: result,
              panelId: 'LP1');
      final joined =
          detail.prims.whereType<SldLabel>().map((t) => t.text).join('\n');
      // The filtered panel's own content is present.
      expect(joined, contains('LP-1'));
      expect(joined, contains('Lighting'));
      // The OTHER panel (MDP) and its motor way are excluded.
      expect(joined, isNot(contains('Pompa')));
      // Re-origined to x=0: the outer block starts at minX == 0.
      expect(detail.minX, 0);
      // No feeder channel ⇒ tighter than the full sheet's max width.
      expect(detail.maxX, lessThanOrEqualTo(sheet.maxX));
    });

    test('an unknown panel id yields an empty sheet', () {
      final none = buildElectricalSld(
          project: project, result: result, onlyPanelId: 'NOPE');
      expect(none.prims.whereType<SldRect>(), isEmpty);
    });

    test('onlyPanelId=null is byte-identical to the default full sheet', () {
      final a = buildElectricalSld(project: project, result: result);
      final b =
          buildElectricalSld(project: project, result: result, onlyPanelId: null);
      expect(b.prims.length, a.prims.length);
      expect(b.minX, a.minX);
      expect(b.maxX, a.maxX);
      expect(b.maxY, a.maxY);
    });
  });

  group('source-spine fields drive the spine (capacitor / transformer kVA)', () {
    const basePanels = <ElectricalPanel>[
      ElectricalPanel(
        id: 'LVMDP',
        name: 'LVMDP',
        circuits: [
          ElectricalCircuit(
              id: 'c1', name: 'Load', loadKind: LoadKind.general,
              loadW: 30000, length: Length(10)),
        ],
      ),
    ];

    test('an explicit transformerKva labels the TRANSFORMER node verbatim', () {
      const withTx = ElectricalProject(
        id: 's', name: 'Sources',
        transformerKva: ApparentPower(630000),
        panels: basePanels,
      );
      final r = computeSystem(profile, withTx);
      final s =
          buildElectricalOverview(project: withTx, result: r, sourceChain: true);
      final joined = s.prims.whereType<SldLabel>().map((t) => t.text).join('\n');
      expect(joined, contains('TRANSFORMER 630 kVA'));
    });

    test('a capacitorBankKvar shows the kvar on the CAPACITOR BANK node', () {
      const withCap = ElectricalProject(
        id: 's', name: 'Sources',
        capacitorBankKvar: 50,
        panels: basePanels,
      );
      final r = computeSystem(profile, withCap);
      final s =
          buildElectricalOverview(project: withCap, result: r, sourceChain: true);
      final joined = s.prims.whereType<SldLabel>().map((t) => t.text).join('\n');
      expect(joined, contains('CAPACITOR BANK'));
      expect(joined, contains('50 kvar'));
      // No bare proxy caption when a real bank is set.
      expect(joined, isNot(contains('PF correction')));
    });

    test('buildElectricalSourceSpine: empty for a bare project, populated when '
        'sources/fields set', () {
      // Bare project (no demand, no sources) ⇒ empty spine.
      const bare = ElectricalProject(id: 'b', name: 'Bare');
      final br = computeSystem(profile, bare);
      expect(
          buildElectricalSourceSpine(project: bare, result: br).isEmpty, isTrue);

      // A capacitor field alone is enough to draw the spine.
      const withCap = ElectricalProject(
        id: 's', name: 'Sources', capacitorBankKvar: 50, panels: basePanels);
      final r = computeSystem(profile, withCap);
      final spine = buildElectricalSourceSpine(project: withCap, result: r);
      expect(spine.isEmpty, isFalse);
      final joined =
          spine.prims.whereType<SldLabel>().map((t) => t.text).join('\n');
      expect(joined, contains('PANEL UTAMA TEGANGAN RENDAH'));
      expect(joined, contains('CAPACITOR BANK'));
      // It carries the Source legend entry.
      expect(spine.legend.map((e) => e.code), contains('Source'));
    });
  });

  group('buildElectricalOverview (zoomed-out building single-line)', () {
    // LV main feeds a normal sub-board (LP-1) and an EMERGENCY sub-board that
    // carries a life-safety load → the essential colour must propagate.
    const ov = ElectricalProject(
      id: 'ov',
      name: 'Tower',
      panels: [
        ElectricalPanel(
          id: 'LVMDP',
          name: 'LVMDP',
          circuits: [
            ElectricalCircuit(
                id: 'f1', name: 'MDP Normal', loadKind: LoadKind.feeder,
                feedsPanelId: 'LP1', length: Length(20)),
            ElectricalCircuit(
                id: 'f2', name: 'MDP Emergency', loadKind: LoadKind.feeder,
                feedsPanelId: 'EMG', length: Length(20)),
          ],
        ),
        ElectricalPanel(
          id: 'LP1', name: 'LP-1', sourceType: PanelSource.feeder,
          circuits: [
            ElectricalCircuit(
                id: 'c1', name: 'Lighting', loadKind: LoadKind.lighting,
                isLighting: true, loadW: 1500, length: Length(15)),
          ],
        ),
        ElectricalPanel(
          id: 'EMG', name: 'MDP EMERGENCY', sourceType: PanelSource.feeder,
          circuits: [
            ElectricalCircuit(
                id: 'fs', name: 'Fire pump', loadKind: LoadKind.motor,
                motorKw: 7.5, lifeSafety: true, feedsPanelId: 'FS',
                length: Length(25)),
          ],
        ),
        ElectricalPanel(
          id: 'FS', name: 'PP FIRE STAIRS', sourceType: PanelSource.feeder,
          circuits: [
            ElectricalCircuit(
                id: 'e1', name: 'Emergency light', loadKind: LoadKind.lighting,
                lifeSafety: true, loadW: 800, length: Length(18)),
          ],
        ),
      ],
    );

    final ovResult = computeSystem(profile, ov);
    final sheet = buildElectricalOverview(project: ov, result: ovResult);

    test('draws one compact node (rect) per panel', () {
      expect(sheet.prims.whereType<SldRect>().length, 4);
    });

    test('the EMERGENCY sub-tree is essential (red); normal stays normal', () {
      final labels = sheet.prims.whereType<SldLabel>();
      SldRole roleOf(String name) =>
          labels.firstWhere((l) => l.text.contains(name)).role;
      expect(roleOf('LVMDP'), SldRole.normal);
      expect(roleOf('LP-1'), SldRole.normal);
      expect(roleOf('MDP EMERGENCY'), SldRole.essential);
      // Propagated to the child of the emergency board.
      expect(roleOf('PP FIRE STAIRS'), SldRole.essential);
    });

    test('panels are tiered top-down by feeder depth', () {
      // The bold name label sits at a fixed offset inside each node, so its y is
      // monotonic with the panel's tier.
      double yOf(String name) => sheet.prims
          .whereType<SldLabel>()
          .firstWhere((l) => l.bold && l.text.contains(name))
          .y;
      expect(yOf('LVMDP'), lessThan(yOf('LP-1')));
      expect(yOf('MDP EMERGENCY'), lessThan(yOf('PP FIRE STAIRS')));
    });

    test('legend names the normal / essential split', () {
      final codes = sheet.legend.map((e) => e.code).toList();
      expect(codes, contains('Normal'));
      expect(codes, contains('Essential'));
    });

    test('overview PDF colours the essential branch red, normal byte-stable',
        () {
      final s = latin1.decode(electricalSldToPdf(
          project: ov, result: ovResult, overview: true));
      expect(s.startsWith('%PDF-1.4'), isTrue);
      expect(s, contains('0.80 0.13 0.13 RG')); // essential red stroke
      expect(s, contains('MDP EMERGENCY'));
    });

    test('overview DXF tags the essential branch ACI red (62 / 1)', () {
      final dxf = electricalSldToDxf(
          project: ov, result: ovResult, overview: true);
      expect(dxf, contains('PP FIRE STAIRS'));
      // group code 62 with value 1 (red) appears for essential entities.
      expect(dxf, contains('62\n1\n'));
    });

    test('sourceChain=false is byte-identical to the default overview', () {
      final a = buildElectricalOverview(project: ov, result: ovResult);
      final b = buildElectricalOverview(
          project: ov, result: ovResult, sourceChain: false);
      // Same prim count, same first/last label text, same bounds + legend.
      expect(b.prims.length, a.prims.length);
      expect(b.minX, a.minX);
      expect(b.maxY, a.maxY);
      expect(b.legend.length, a.legend.length);
      // And the PDF bytes are byte-identical (default off ⇒ no spine).
      final pa = electricalSldToPdf(
          project: ov, result: ovResult, overview: true);
      final pb = electricalSldToPdf(
          project: ov, result: ovResult, overview: true, sourceChain: false);
      expect(pb, equals(pa));
    });

    test('sourceChain=true prepends source-role nodes + a TEGANGAN spine', () {
      final src = buildElectricalOverview(
          project: ov, result: ovResult, sourceChain: true);
      final sourceRects = src.prims
          .whereType<SldRect>()
          .where((r) => r.role == SldRole.source);
      // PLN + LV main (+ TX) at minimum.
      expect(sourceRects.length, greaterThanOrEqualTo(3));
      final joined =
          src.prims.whereType<SldLabel>().map((t) => t.text).join('\n');
      expect(joined, contains('PLN MV STATION'));
      expect(joined, contains('TEGANGAN RENDAH'));
      // The legend gains the Source entry.
      expect(src.legend.map((e) => e.code), contains('Source'));
      // More prims than the default (the spine added rects + connectors).
      final base = buildElectricalOverview(project: ov, result: ovResult);
      expect(src.prims.length, greaterThan(base.prims.length));
    });

    test('a genset in sources adds a GENSET source node', () {
      const withGen = ElectricalProject(
        id: 'g',
        name: 'Tower+gen',
        sources: ElectricalSources(
          generator: GeneratorSource(backupFraction: 0.5),
        ),
        panels: [
          ElectricalPanel(
            id: 'LVMDP',
            name: 'LVMDP',
            circuits: [
              ElectricalCircuit(
                  id: 'c1', name: 'Load', loadKind: LoadKind.general,
                  loadW: 12000, length: Length(10)),
            ],
          ),
        ],
      );
      final gr = computeSystem(profile, withGen);
      final s = buildElectricalOverview(
          project: withGen, result: gr, sourceChain: true);
      final joined =
          s.prims.whereType<SldLabel>().map((t) => t.text).join('\n');
      expect(joined, contains('GENSET'));
      expect(joined, contains('CAPACITOR BANK'));
      // dualTransformer is false but sources != null ⇒ the MV main is drawn.
      expect(joined, contains('TEGANGAN MENENGAH'));
    });
  });
}
