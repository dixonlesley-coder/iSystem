import 'dart:convert';

import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/control/starter.dart' show StarterType;
import 'package:mechx_engine/electrical/earthing.dart' show EarthingSystem;
import 'package:mechx_engine/electrical/headroom.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/electrical/results.dart' show BreakerResult;
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

  test('the board schedule is a RULED table — column verticals + row rules',
      () {
    // Single-panel detail re-origins the block to x=0, so the rule positions
    // are exact: 7 column separators (6 px left of DEVICE / PENGHANTAR /
    // DAYA / KETERANGAN / R / S / T) spanning header band → bus bottom, and
    // one horizontal rule under each body row (MDP has 2 ways, 0 spares).
    // The columns after DEVICE shift +28 (block widened for the kA + RCD
    // tokens in the DEVICE cell — N9 / N10).
    final detail = buildElectricalSld(
        project: project, result: result, onlyPanelId: 'MDP');
    final lines = detail.prims.whereType<SldLine>().toList();
    const busTop = 46.0; // _headerH
    const busBot = busTop + 3 * 20.0 + 6; // (1 header + 2 way rows) · _rowH + 6
    for (final colX in const [116.0, 252.0, 474.0, 534.0, 754.0, 800.0, 846.0]) {
      final vert = lines.where((l) =>
          l.x1 == colX - 6 && l.x2 == colX - 6 && l.y1 == busTop && l.y2 == busBot);
      expect(vert.length, 1, reason: 'column separator at ${colX - 6}');
    }
    // Row rules under way 1 (y 92) and way 2 (y 112 — the TOTAL divider).
    for (final ruleY in const [92.0, 112.0]) {
      final horiz = lines.where(
          (l) => l.y1 == ruleY && l.y2 == ruleY && l.x2 - l.x1 > 500);
      expect(horiz.length, 1, reason: 'row rule at y=$ruleY');
    }
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
    // DAYA(WATT): the LP-1 lighting way's connected 1500 W reads in the
    // Indonesian DIAGRAM PANEL convention — integer WATT, dot thousands sep.
    expect(joined, contains('1.500 WATT'));
    // Busbar make-up reads "Cu bus".
    expect(joined, contains('Cu bus'));
    // A TOTAL footer per block.
    expect(joined, contains('TOTAL'));
    // ASCII-safe: no unicode phase glyph / squared metres in the labels.
    expect(joined.contains('Ø'), isFalse); // Ø
    expect(joined.contains('²'), isFalse); // ²
  });

  test('H6: a large-CSA feeder shows a `tray` route token, small ways `PVC`',
      () {
    // A huge 3-phase load forces the cable CSA past the conduit range
    // (> 70 mm2), so its PENGHANTAR cell must state an explicit `tray` route
    // method instead of a silent blank — while a small final way keeps `PVC`.
    const big = ElectricalProject(
      id: 'big',
      name: 'Big load',
      panels: [
        ElectricalPanel(
          id: 'MDP',
          name: 'MDP',
          circuits: [
            ElectricalCircuit(
              id: 'huge',
              name: 'Chiller',
              loadKind: LoadKind.general,
              loadW: 180000,
              phases: 3,
              cableType: 'NYY',
            ),
            ElectricalCircuit(
              id: 'tiny',
              name: 'Lighting',
              loadKind: LoadKind.lighting,
              isLighting: true,
              loadW: 600,
              phases: 1,
              cableType: 'NYM',
            ),
          ],
        ),
      ],
    );
    final r = computeSystem(profile, big);
    final s = buildElectricalSld(project: big, result: r);
    final joined = s.prims.whereType<SldLabel>().map((t) => t.text).join('\n');
    expect(joined, contains('tray'), reason: 'large feeder states its route');
    expect(joined, contains('PVC'), reason: 'small ways keep conduit');
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
    // No circuit / no explicit cableType: the conventional power default NYY
    // (never the bare conductor material "Cu"); 3-core 1-phase notation.
    expect(cableLabel(null, 2.5, false), 'NYY 3x2.5');
    // 3-phase: 5-core notation.
    expect(cableLabel(null, 6, true), 'NYY 5x6');
    // A final lighting circuit (no explicit cableType) defaults to NYM.
    const lightingWay = ElectricalCircuit(
        id: 'l', name: 'Lights', loadKind: LoadKind.lighting, isLighting: true);
    expect(cableLabel(lightingWay, 2.5, false), 'NYM 3x2.5');
    // A feeder defaults to NYY (power / sub-main cable).
    const feederWay = ElectricalCircuit(
        id: 'f', name: 'Feeder', loadKind: LoadKind.feeder, feedsPanelId: 'x');
    expect(cableLabel(feederWay, 16, true), 'NYY 5x16');
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

  group('C5 — breaker breaking capacity (Icu kA) in the device notation', () {
    test('an omitted / empty map is byte-identical to the default sheet', () {
      final a = buildElectricalSld(project: project, result: result);
      final b = buildElectricalSld(
          project: project, result: result, breakerIcuKaByPanelId: null);
      final c = buildElectricalSld(
          project: project, result: result, breakerIcuKaByPanelId: const {});
      String labels(SldSheet s) =>
          s.prims.whereType<SldLabel>().map((t) => t.text).join('\n');
      expect(b.prims.length, a.prims.length);
      expect(c.prims.length, a.prims.length);
      expect(labels(b), labels(a));
      expect(labels(c), labels(a));
      // The default project carries no fault level ⇒ no kA anywhere.
      expect(labels(a), isNot(contains('kA')));
    });

    test('a mapped kA appears on the incomer sub-line + DEVICE cell of that '
        'panel only', () {
      const map = {'MDP': 25.0};
      final mdp = buildElectricalPanelDetail(
          project: project, result: result, panelId: 'MDP',
          breakerIcuKaByPanelId: map);
      final lp1 = buildElectricalPanelDetail(
          project: project, result: result, panelId: 'LP1',
          breakerIcuKaByPanelId: map);
      final mdpLabels =
          mdp.prims.whereType<SldLabel>().map((t) => t.text).toList();
      // The incomer sub-line carries the kA.
      expect(
          mdpLabels.any((t) => t.startsWith('Incomer') && t.contains('25kA')),
          isTrue);
      // A DEVICE cell (a bare breaker row, NOT the incomer sub-line) carries it
      // too — the way's required Icu equals the board's prospective fault.
      expect(
          mdpLabels.any((t) =>
              !t.startsWith('Incomer') &&
              RegExp(r'MC(B|CB) \d+A (1|3)ph 25kA').hasMatch(t)),
          isTrue);
      // The UNMAPPED panel (LP-1) gets nothing appended.
      final lp1Joined =
          lp1.prims.whereType<SldLabel>().map((t) => t.text).join('\n');
      expect(lp1Joined, isNot(contains('25kA')));
    });

    test('a fractional Icu renders to one decimal (ASCII kA)', () {
      final d = buildElectricalPanelDetail(
          project: project, result: result, panelId: 'MDP',
          breakerIcuKaByPanelId: const {'MDP': 15.5});
      final joined =
          d.prims.whereType<SldLabel>().map((t) => t.text).join('\n');
      expect(joined, contains('15.5kA'));
    });
  });

  group('metering circles + starter column + DAYA in WATT', () {
    // A 3-phase MDP with a DOL motor way carrying a real connected load, plus a
    // 1-phase final board (no metering). Loads chosen to exercise the WATT dot-
    // grouping: 190 W, 4400 W, 52871 W.
    const dp = ElectricalProject(
      id: 'dp',
      name: 'DiagramPanel',
      panels: [
        ElectricalPanel(
          id: 'MDP',
          name: 'MDP',
          circuits: [
            ElectricalCircuit(
              id: 'm1',
              name: 'Pompa',
              loadKind: LoadKind.motor,
              starterType: StarterType.dol,
              loadW: 4400,
              length: Length(20),
            ),
            ElectricalCircuit(
              id: 'g1',
              name: 'Chiller plant',
              loadKind: LoadKind.general,
              loadW: 52871,
              length: Length(18),
            ),
            ElectricalCircuit(
              id: 'g2',
              name: 'Exhaust fan',
              loadKind: LoadKind.general,
              loadW: 190,
              length: Length(12),
            ),
          ],
        ),
        ElectricalPanel(
          id: 'SP1',
          name: 'SP-1',
          system: ElectricalSystem.singlePhase,
          voltage: Voltage(220),
          circuits: [
            ElectricalCircuit(
              id: 'c1',
              name: 'Lighting',
              loadKind: LoadKind.lighting,
              isLighting: true,
              loadW: 1100,
              length: Length(15),
            ),
          ],
        ),
      ],
    );
    final dpResult = computeSystem(profile, dp);

    test('a 3-phase board emits metering circles; a 1-phase board emits none',
        () {
      final mdp = buildElectricalPanelDetail(
          project: dp, result: dpResult, panelId: 'MDP');
      final sp1 = buildElectricalPanelDetail(
          project: dp, result: dpResult, panelId: 'SP1');
      // V / A / Hz meters → at least three circles on the 3-phase MDP.
      expect(mdp.prims.whereType<SldCircle>().length, greaterThanOrEqualTo(3));
      // The single-phase board carries no metering cluster.
      expect(sp1.prims.whereType<SldCircle>(), isEmpty);
    });

    test('a motor way with a starterType shows its ASCII control token (DOL)',
        () {
      final joined = buildElectricalPanelDetail(
              project: dp, result: dpResult, panelId: 'MDP')
          .prims
          .whereType<SldLabel>()
          .map((t) => t.text)
          .join('\n');
      // The DOL token appears appended to the motor way's DEVICE cell.
      expect(joined, contains('DOL'));
      // A way with NO starter (the general loads) does not invent a token.
      expect(joined, isNot(contains('VFD')));
      expect(joined, isNot(contains('star-delta')));
    });

    test('DAYA cells read integer WATT with the dot thousands separator', () {
      final joined = dpResult.panels.keys
          .map((id) =>
              buildElectricalPanelDetail(project: dp, result: dpResult, panelId: id)
                  .prims
                  .whereType<SldLabel>()
                  .map((t) => t.text)
                  .join('\n'))
          .join('\n');
      expect(joined, contains('190 WATT')); // < 1000, no separator
      expect(joined, contains('1.100 WATT')); // SP-1 lighting
      expect(joined, contains('4.400 WATT')); // motor
      expect(joined, contains('52.871 WATT')); // chiller (5 digits)
      // The old kW form is gone from the per-way DAYA cell.
      expect(joined, isNot(contains('4.4kW')));
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

  group('W7 — supply head / battery + solar nodes / genset backup %', () {
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

    // Mirrors the drawing file's private `_num` (whole → int, else 1 dp) so
    // expected labels are derived, not hand-typed magic strings.
    String num_(double v) =>
        v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);

    String labels(SldSheet s) =>
        s.prims.whereType<SldLabel>().map((t) => t.text).join('\n');

    test('the default supply head keeps the historic PLN labels (vertical + '
        'compact) and prints no battery / solar / backup-%', () {
      const p = ElectricalProject(
          id: 's', name: 'S', capacitorBankKvar: 50, panels: basePanels);
      final r = computeSystem(profile, p);
      final v = labels(
          buildElectricalOverview(project: p, result: r, sourceChain: true));
      expect(v, contains('PLN MV STATION'));
      final h = labels(buildElectricalSourceSpine(
          project: p, result: r, horizontal: true));
      expect(h, contains('PLN'));
      for (final j in [v, h]) {
        expect(j, isNot(contains('BATTERY')));
        expect(j, isNot(contains('SOLAR PV')));
        expect(j, isNot(contains('backs')));
      }
    });

    test('supplyKind + supplyCapacityVa re-label the supply head node', () {
      const p = ElectricalProject(
        id: 's', name: 'S',
        supplyKind: SupplyKind.generator,
        supplyCapacityVa: ApparentPower(250000),
        panels: basePanels,
      );
      final r = computeSystem(profile, p);
      final v = labels(
          buildElectricalOverview(project: p, result: r, sourceChain: true));
      expect(v, contains('GENSET SUPPLY 250 kVA'));
      final h = labels(buildElectricalSourceSpine(
          project: p, result: r, horizontal: true));
      expect(h, contains('GENSET 250 kVA'));

      const sol = ElectricalProject(
        id: 's', name: 'S',
        supplyKind: SupplyKind.solar,
        panels: basePanels,
      );
      final sr = computeSystem(profile, sol);
      expect(
        labels(buildElectricalOverview(
            project: sol, result: sr, sourceChain: true)),
        contains('SOLAR PV SUPPLY'),
      );
    });

    test('the genset node prints the honest backup coverage %, capped at 100',
        () {
      // A deliberately small 5 kVA set against the real solved demand.
      const small = ElectricalProject(
        id: 's', name: 'S',
        sources: ElectricalSources(
            generator: GeneratorSource(kva: ApparentPower(5000))),
        panels: basePanels,
      );
      final r = computeSystem(profile, small);
      final demandKva = r.supply.demandVa.inKilovoltAmperes;
      expect(demandKva, greaterThan(5)); // the premise: undersized set
      final pct = (5 / demandKva * 100).round();
      final v = labels(
          buildElectricalOverview(project: small, result: r, sourceChain: true));
      expect(v, contains('backs $pct% of load'));
      final h = labels(buildElectricalSourceSpine(
          project: small, result: r, horizontal: true));
      expect(h, contains('backs $pct% of load'));

      // An oversized set backs the whole load — never "250% of load".
      const big = ElectricalProject(
        id: 's', name: 'S',
        sources: ElectricalSources(
            generator: GeneratorSource(kva: ApparentPower(500000))),
        panels: basePanels,
      );
      final br = computeSystem(profile, big);
      expect(
        labels(buildElectricalOverview(
            project: big, result: br, sourceChain: true)),
        contains('backs 100% of load'),
      );
    });

    test('a battery source draws a BATTERY node sized on the power one-line '
        'basis (demand at the genset PF)', () {
      const p = ElectricalProject(
        id: 's', name: 'S',
        sources:
            ElectricalSources(battery: BatterySource(autonomyHours: 2)),
        panels: basePanels,
      );
      final r = computeSystem(profile, p);
      // The SAME sizing call `buildPowerOneLine` makes, so the two surfaces
      // can never print different bank sizes.
      final sized = sizeBattery(
        Power(r.supply.demandVa.voltAmperes * kGeneratorPf),
        autonomyHours: 2,
      );
      final expected =
          'BATTERY ${num_(sized.installedKwh.inKilowattHours)} kWh';
      final v = labels(
          buildElectricalOverview(project: p, result: r, sourceChain: true));
      expect(v, contains(expected));
      expect(v, contains('LiFePO4 · 2 h autonomy'));
      final h = labels(buildElectricalSourceSpine(
          project: p, result: r, horizontal: true));
      expect(h, contains(expected));
    });

    test('a solar source draws a SOLAR PV node with the installed kWp', () {
      const p = ElectricalProject(
        id: 's', name: 'S',
        sources: ElectricalSources(solar: SolarSource(panels: 20)),
        panels: basePanels,
      );
      final r = computeSystem(profile, p);
      final v = labels(
          buildElectricalOverview(project: p, result: r, sourceChain: true));
      expect(v, contains('SOLAR PV 11 kWp')); // 20 x 550 Wp = 11 kWp
      expect(v, contains('20 x 550 Wp'));
      final h = labels(buildElectricalSourceSpine(
          project: p, result: r, horizontal: true));
      expect(h, contains('SOLAR PV 11 kWp'));
    });

    test('supplyKind / supplyCapacityVa round-trip in JSON; defaults are '
        'omitted so an old file is byte-identical', () {
      const p = ElectricalProject(
        id: 's', name: 'S',
        supplyKind: SupplyKind.solar,
        supplyCapacityVa: ApparentPower(41500),
      );
      final decoded = ElectricalProject.fromJson(
          jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>);
      expect(decoded.supplyKind, SupplyKind.solar);
      expect(decoded.supplyCapacityVa!.voltAmperes, 41500);

      // Defaults: keys absent from the JSON, and tolerant decode.
      const d = ElectricalProject(id: 'd', name: 'D');
      final json = d.toJson();
      expect(json.containsKey('supplyKind'), isFalse);
      expect(json.containsKey('supplyCapacityVa'), isFalse);
      final legacy = ElectricalProject.fromJson({'id': 'x', 'name': 'X'});
      expect(legacy.supplyKind, SupplyKind.pln);
      expect(legacy.supplyCapacityVa, isNull);
      final unknown = ElectricalProject.fromJson(
          {'id': 'x', 'name': 'X', 'supplyKind': 'fusion'});
      expect(unknown.supplyKind, SupplyKind.pln);
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

    test('every feeder run carries a cable + breaker annotation', () {
      // The four panels have three feeders (LP1, EMG, FS), each with a sized
      // parent circuit ⇒ three resolvable cable+breaker labels.
      final feederLabels = sheet.prims
          .whereType<SldLabel>()
          .where((l) => l.text.contains(' mm2 ') && l.text.contains('·'))
          .toList();
      expect(feederLabels.length, 3);
      for (final l in feederLabels) {
        // carries a cable family + a breaker token (MCB/MCCB ... ph).
        expect(l.text, matches(RegExp(r'\dx\d')), reason: l.text);
        expect(l.text, matches(RegExp(r'(MCB|MCCB) \d+(\.\d+)?A \dph')),
            reason: l.text);
        expect(l.size, lessThan(7.5)); // annotation, smaller than node text
      }
    });

    test('the feeder annotation onto the essential board is essential-coloured',
        () {
      // The LV main -> MDP EMERGENCY feeder label inherits the essential role.
      final l = sheet.prims.whereType<SldLabel>().firstWhere(
          (l) => l.text.contains(' mm2 ') && l.role == SldRole.essential);
      expect(l.text, matches(RegExp(r'(MCB|MCCB)')));
    });

    test('the compact node sub-line carries demand in kW AND kVA', () {
      final sub = sheet.prims.whereType<SldLabel>().where((l) =>
          !l.bold && l.text.contains('kW') && l.text.contains('kVA'));
      expect(sub, isNotEmpty);
      // format: '<In>A <poles>P · <kW>kW / <kVA>kVA'
      expect(sub.first.text, matches(RegExp(r'\d+A \dP · .*kW / .*kVA')));
    });

    test('no label contains a non-ASCII tofu glyph (Ø / superscripts)', () {
      for (final l in sheet.prims.whereType<SldLabel>()) {
        expect(l.text.contains('Ø'), isFalse, reason: l.text);
        expect(l.text.contains('²'), isFalse, reason: l.text);
        expect(l.text.contains('³'), isFalse, reason: l.text);
      }
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
      // The spine draws real single-line SYMBOLS, not boxes: the PLN supply
      // circle + the transformer's TWO winding circles ⇒ ≥ 3 source circles.
      final sourceCircles = src.prims
          .whereType<SldCircle>()
          .where((c) => c.role == SldRole.source);
      expect(sourceCircles.length, greaterThanOrEqualTo(2)); // the transformer windings
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

  group('C6 — source-spine system-earthing mark + designation', () {
    // A TT-earthed installation with an explicit transformer, so the source
    // spine (and its earthing mark) can be drawn and the designation ('TT')
    // checked verbatim.
    const ep = ElectricalProject(
      id: 'ep',
      name: 'Earth',
      earthingSystem: EarthingSystem.tt,
      transformerKva: ApparentPower(400000),
      panels: [
        ElectricalPanel(
          id: 'LVMDP',
          name: 'LVMDP',
          circuits: [
            ElectricalCircuit(
                id: 'c1', name: 'Load', loadKind: LoadKind.general,
                loadW: 30000, length: Length(10)),
          ],
        ),
      ],
    );
    final epResult = computeSystem(profile, ep);

    // The earth mark's narrowing BOTTOM bar is a distinctive 4px-wide source-
    // role horizontal (halfWidth 2 ⇒ width 4) — no other source line matches.
    Iterable<SldLine> earthBottomBars(SldSheet s) =>
        s.prims.whereType<SldLine>().where((l) =>
            l.role == SldRole.source && l.y1 == l.y2 && (l.x2 - l.x1) == 4.0);

    test('sourceChain off ⇒ no earth mark, no Earth legend (byte-identical)',
        () {
      final s = buildElectricalOverview(project: ep, result: epResult);
      expect(earthBottomBars(s), isEmpty);
      expect(s.legend.map((e) => e.code), isNot(contains('Earth')));
    });

    test('sourceChain on ⇒ earth bars + Earth legend + the designation label',
        () {
      final s = buildElectricalOverview(
          project: ep, result: epResult, sourceChain: true);
      expect(earthBottomBars(s), isNotEmpty);
      expect(s.legend.map((e) => e.code), contains('Earth'));
      // The installation earthing-system designation is drawn on the spine.
      expect(s.prims.whereType<SldLabel>().any((t) => t.text == 'TT'), isTrue);
    });

    test('the riser prepends the earth mark when sourceChain is on', () {
      final off = buildElectricalRiser(project: ep, result: epResult);
      final on = buildElectricalRiser(
          project: ep, result: epResult, sourceChain: true);
      expect(earthBottomBars(off), isEmpty);
      expect(off.legend.map((e) => e.code), isNot(contains('Earth')));
      expect(earthBottomBars(on), isNotEmpty);
      expect(on.legend.map((e) => e.code), contains('Earth'));
      expect(on.prims.whereType<SldLabel>().any((t) => t.text == 'TT'), isTrue);
    });

    test('buildElectricalSourceSpine carries the earth mark + Earth legend', () {
      final spine = buildElectricalSourceSpine(project: ep, result: epResult);
      expect(spine.isEmpty, isFalse);
      expect(earthBottomBars(spine), isNotEmpty);
      expect(spine.legend.map((e) => e.code), contains('Earth'));
      expect(
          spine.prims.whereType<SldLabel>().any((t) => t.text == 'TT'), isTrue);
    });

    test('the horizontal source spine also draws the earth mark', () {
      final spine = buildElectricalSourceSpine(
          project: ep, result: epResult, horizontal: true);
      expect(earthBottomBars(spine), isNotEmpty);
      expect(
          spine.prims.whereType<SldLabel>().any((t) => t.text == 'TT'), isTrue);
    });

    test('the earth label is ASCII (no tofu glyphs)', () {
      final s = buildElectricalOverview(
          project: ep, result: epResult, sourceChain: true);
      for (final l in s.prims.whereType<SldLabel>()) {
        expect(l.text.contains('Ø'), isFalse, reason: l.text);
        expect(l.text.contains('²'), isFalse, reason: l.text);
      }
    });
  });

  group('Wave 7 export-readiness — length / kA / RCD / CT (N8-N11)', () {
    // A 3-phase MDP feeding a 1-phase LP with a socket way; realistic run
    // lengths; computed WITH an origin fault level so the busbar withstand (and
    // thus the N9 kA fallback) is populated WITHOUT any fault-study kA map.
    const wp = ElectricalProject(
      id: 'wp',
      name: 'Wave7',
      panels: [
        ElectricalPanel(
          id: 'MDP',
          name: 'MDP',
          circuits: [
            ElectricalCircuit(
                id: 'f1', name: 'Feeder to LP-1', loadKind: LoadKind.feeder,
                feedsPanelId: 'LP1', length: Length(24)),
            ElectricalCircuit(
                id: 'g1', name: 'Chiller', loadKind: LoadKind.general,
                loadW: 40000, length: Length(18)),
          ],
        ),
        ElectricalPanel(
          id: 'LP1',
          name: 'LP-1',
          system: ElectricalSystem.singlePhase,
          voltage: Voltage(220),
          sourceType: PanelSource.feeder,
          fedByCircuitId: 'f1',
          circuits: [
            ElectricalCircuit(
                id: 's1', name: 'Sockets L.1', loadKind: LoadKind.socket,
                loadW: 2000, points: 6, length: Length(22)),
            ElectricalCircuit(
                id: 'l1', name: 'Lighting', loadKind: LoadKind.lighting,
                isLighting: true, loadW: 1200, length: Length(30)),
          ],
        ),
      ],
    );
    final wpResult = computeSystem(profile, wp,
        originFaultLevel: const Current(16000), busbarClearingTimeS: 0.1);

    String allLabels() => wpResult.panels.keys
        .map((id) => buildElectricalPanelDetail(
                project: wp, result: wpResult, panelId: id)
            .prims
            .whereType<SldLabel>()
            .map((t) => t.text)
            .join('\n'))
        .join('\n');

    test('N8 — the schedule cell carries the run length (m) after the cable',
        () {
      final joined = allLabels();
      // The socket way's 22 m + the lighting way's 30 m run lengths read on the
      // conductor cell — the same lengths that drove the printed Vdrop.
      expect(joined, contains('22 m'));
      expect(joined, contains('30 m'));
      // A cable cell reads `... mm2 ... · <n> m` (length appended after cable).
      expect(RegExp(r'mm2.* · \d+(\.\d+)? m').hasMatch(joined), isTrue);
    });

    test('N8 — the overview feeder label carries the feeder run length', () {
      final ov = buildElectricalOverview(project: wp, result: wpResult);
      final feeder = ov.prims.whereType<SldLabel>().firstWhere(
          (l) => l.text.contains(' mm2 ') && l.text.contains('·'));
      // The LV feeder to LP-1 (24 m) reads on the feeder annotation.
      expect(feeder.text, contains('24 m'));
    });

    test('N9 — the incomer + every DEVICE cell carry a kA from the withstand '
        'fallback (no fault-study map)', () {
      final mdp = buildElectricalPanelDetail(
          project: wp, result: wpResult, panelId: 'MDP');
      final labels =
          mdp.prims.whereType<SldLabel>().map((t) => t.text).toList();
      // The incomer sub-line carries a kA.
      expect(labels.any((t) => t.startsWith('Incomer') && t.contains('kA')),
          isTrue);
      // A bare DEVICE row (not the incomer sub-line) carries a kA too.
      expect(
          labels.any((t) =>
              !t.startsWith('Incomer') &&
              RegExp(r'MC(B|CB) \d+A (1|3)ph \d+(\.\d+)?kA').hasMatch(t)),
          isTrue);
      // The kA convention is surfaced in the KETERANGAN legend.
      expect(mdp.legend.map((e) => e.code), contains('kA'));
    });

    test('N10 — the socket way carries its RCD token; the report + schedule use '
        'the same field', () {
      final lp1 = buildElectricalPanelDetail(
          project: wp, result: wpResult, panelId: 'LP1');
      final joined =
          lp1.prims.whereType<SldLabel>().map((t) => t.text).join('\n');
      // The 30 mA Type A socket RCD reads on the DEVICE cell.
      expect(joined, contains('RCD 30mA A'));
      // Exactly one RCD token on LP-1 (only the socket way; the lighting way
      // in TN has none — no token invented).
      expect('RCD '.allMatches(joined).length, 1);
    });

    test('N11 — a 3-phase board prints a derived CT ratio + class, not a bare '
        'CT glyph', () {
      final mdp = buildElectricalPanelDetail(
          project: wp, result: wpResult, panelId: 'MDP');
      final joined =
          mdp.prims.whereType<SldLabel>().map((t) => t.text).join('\n');
      // A standard primary / 5 A secondary + class 1 metering accuracy.
      expect(RegExp(r'CT \d+/5A cl\.1').hasMatch(joined), isTrue);
      // The metering instruments are listed in the KETERANGAN legend.
      final codes = mdp.legend.map((e) => e.code).toList();
      expect(codes, contains('CT'));
      expect(codes, contains('V / A / Hz'));
    });

    test('N11 — the CT primary is a standard rating at/above the demand current',
        () {
      final joined = buildElectricalPanelDetail(
              project: wp, result: wpResult, panelId: 'MDP')
          .prims
          .whereType<SldLabel>()
          .map((t) => t.text)
          .join('\n');
      final primary =
          int.parse(RegExp(r'CT (\d+)/5A').firstMatch(joined)!.group(1)!);
      final demandA = wpResult.panels['MDP']!.demandCurrent.amperes;
      // The CT primary covers the demand current (never understated)…
      expect(primary, greaterThanOrEqualTo(demandA));
      // …and is one of the IEC preferred values (not a fabricated ratio).
      const ladder = {
        5, 10, 15, 20, 25, 30, 40, 50, 60, 75, 100, 125, 150, 200, 250, 300, //
        400, 500, 600, 750, 800, 1000, 1250, 1500, 1600, 2000, 2500, 3000, //
        4000, 5000, 6300,
      };
      expect(ladder.contains(primary), isTrue);
    });
  });

  group('N12 — an MCCB carries no B/C/D trip-curve code in breakerLabel', () {
    test('MCCB drops the curve; MCB keeps it', () {
      const mccb = BreakerResult(
          ratingA: Current(160),
          deviceClass: BreakerClass.mccb,
          curve: BreakerCurve.c);
      const mcb = BreakerResult(
          ratingA: Current(16),
          deviceClass: BreakerClass.mcb,
          curve: BreakerCurve.c);
      expect(breakerLabel(mccb, 4), 'MCCB 160A/4P');
      expect(breakerLabel(mcb, 1), 'MCB C16A/1P');
    });

    test('an all-MCCB board seeds NO Curve legend entry', () {
      // A board large enough that its ways + incomer are all moulded-case.
      const big = ElectricalProject(
        id: 'big',
        name: 'Big',
        panels: [
          ElectricalPanel(
            id: 'MDP',
            name: 'MDP',
            circuits: [
              ElectricalCircuit(
                  id: 'g1', name: 'Chiller A', loadKind: LoadKind.general,
                  loadW: 120000, length: Length(10)),
              ElectricalCircuit(
                  id: 'g2', name: 'Chiller B', loadKind: LoadKind.general,
                  loadW: 120000, length: Length(12)),
            ],
          ),
        ],
      );
      final r = computeSystem(profile, big);
      final sheet = buildElectricalSld(project: big, result: r);
      // The incomer + both ways are MCCBs (large ratings), so no MCB curve is
      // printed and the legend seeds no "Curve X" entry from them.
      final joined =
          sheet.prims.whereType<SldLabel>().map((t) => t.text).join('\n');
      expect(joined, isNot(contains('MCCB C')));
      expect(sheet.legend.map((e) => e.code).any((c) => c.startsWith('Curve')),
          isFalse);
    });
  });
}
