// Round 34 (2026-10-18) — issued electrical drawing findings:
//
//   electrical-drawings-4-tall-board-schedule-illegible   a tall board
//     continues on way-range pages; every page prints at 7 pt.
//   electrical-drawings-4-overview-feeder-labels-struck-by-drops   no feeder
//     tag is struck through by a vertical feeder line.
//   electrical-drawings-4-overview-pagination-leaves-top-page-below-floor
//     a wide flat tier splits into chunk pages, each at 7 pt.
//   electrical-drawings-4-detail-schedule-no-essential-mark   an essential
//     board's schedule says so (and is framed in the essential role).
//   electrical-drawings-4-overview-legend-keys-unprinted   the legend keys only
//     printed roles; an LV service is not an 'MV' supply chain.
//   electrical-drawings-4-lv-power-one-line-omits-daya   the LV power one-line
//     states the declared connection capacity.
import 'dart:math' as math;

import 'package:mechx_engine/electrical/advanced_study.dart'
    show powerOneLineUtilitySub;
import 'package:mechx_engine/electrical/compute.dart';
import 'package:mechx_engine/electrical/headroom.dart';
import 'package:mechx_engine/electrical/load_kind.dart';
import 'package:mechx_engine/electrical/model.dart';
import 'package:mechx_engine/report/drawing_chrome.dart' show kMinPlotLabelPt;
import 'package:mechx_engine/report/electrical_pagination.dart';
import 'package:mechx_engine/report/electrical_pdf_export.dart'
    show electricalBoardScheduleSheets, sldSinglePageMinLabelPt;
import 'package:mechx_engine/report/electrical_sld_drawing.dart';
import 'package:mechx_engine/standards/puil.dart';
import 'package:mechx_engine/units.dart';
import 'package:test/test.dart';

const _profile = PuilProfile();

ElectricalCircuit _socket(String id) => ElectricalCircuit(
    id: id,
    name: 'Socket $id',
    loadKind: LoadKind.socket,
    loadW: 900,
    length: const Length(15));

ElectricalCircuit _feeder(String id, String to) => ElectricalCircuit(
    id: id,
    name: 'Feeder $to',
    loadKind: LoadKind.feeder,
    feedsPanelId: to,
    phases: 3,
    length: const Length(20));

/// One 3-phase board with [n] 900 W socket ways + 4 spares.
ElectricalProject _tall(int n) => ElectricalProject(id: 't', name: 'T', panels: [
      ElectricalPanel(
          id: 'DB',
          name: 'DB-1',
          headroom: const HeadroomSpec(spareWays: 4),
          circuits: [for (var i = 1; i <= n; i++) _socket('s$i')]),
    ]);

/// A root feeding [n] sub-boards (3-phase feeders), [essentialFrom] onward
/// flagged essential.
ElectricalProject _fan(int n,
        {int? essentialFrom, ApparentPower? capacity}) =>
    ElectricalProject(
        id: 'f',
        name: 'F',
        supplyCapacityVa: capacity,
        panels: [
          ElectricalPanel(
              id: 'MDP',
              name: 'MDP',
              circuits: [for (var i = 1; i <= n; i++) _feeder('f$i', 'SDP$i')]),
          for (var i = 1; i <= n; i++)
            ElectricalPanel(
                id: 'SDP$i',
                name: 'SDP-$i',
                sourceType: PanelSource.feeder,
                fedByCircuitId: 'f$i',
                essential: essentialFrom != null && i >= essentialFrom,
                circuits: [_socket('w$i'), _socket('x$i')]),
        ]);

bool _labelStruckByVertical(SldLabel l, List<SldLine> lines) {
  final w = l.text.length * l.size * 0.6;
  final x0 = l.x, x1 = l.x + w, y0 = l.y - l.size, y1 = l.y;
  for (final ln in lines) {
    if (ln.weight == SldWeight.thin) continue;
    if ((ln.x1 - ln.x2).abs() > 1e-9) continue; // vertical only
    final x = ln.x1;
    final lo = math.min(ln.y1, ln.y2), hi = math.max(ln.y1, ln.y2);
    if (x > x0 + 1e-6 && x < x1 - 1e-6 && hi > y0 + 1e-6 && lo < y1 - 1e-6) {
      return true;
    }
  }
  return false;
}

void main() {
  group('a tall board continues on way-range pages', () {
    for (final n in [24, 36, 48]) {
      test('$n ways: every page >= 7 pt, every way once, header first, TOTAL '
          'last', () {
        final project = _tall(n);
        final r = computeSystem(_profile, project);
        final whole = buildElectricalSld(
            project: project, result: r, onlyPanelId: 'DB');
        // Precondition (the defect): one page prints below the floor.
        expect(sldSinglePageMinLabelPt(whole), lessThan(kMinPlotLabelPt));
        final pages = electricalBoardScheduleSheets(
            project: project, result: r, panelId: 'DB');
        expect(pages.length, greaterThan(1));
        for (final p in pages) {
          expect(sldSinglePageMinLabelPt(p),
              greaterThanOrEqualTo(kMinPlotLabelPt - 1e-9));
        }
        List<String> texts(int i) =>
            [for (final l in pages[i].prims.whereType<SldLabel>()) l.text];
        // Every real way + every spare (W1..W(n+4)) is printed exactly once.
        for (var w = 1; w <= n + 4; w++) {
          var count = 0;
          for (var i = 0; i < pages.length; i++) {
            count += texts(i).where((t) => t == 'W$w').length;
          }
          expect(count, 1, reason: 'W$w');
        }
        expect(texts(0).any((t) => t.startsWith('Incomer ')), isTrue);
        for (var i = 1; i < pages.length; i++) {
          expect(texts(i).any((t) => t.startsWith('Incomer ')), isFalse);
          expect(texts(i).any((t) => t.contains('LANJUTAN W')), isTrue);
        }
        expect(texts(pages.length - 1).any((t) => t.startsWith('TOTAL ')),
            isTrue);
        for (var i = 0; i < pages.length - 1; i++) {
          expect(texts(i).any((t) => t.startsWith('TOTAL ')), isFalse);
          expect(texts(i).contains('CADANGAN (spare)'), isFalse);
        }
      });
    }

    test('a board that fits keeps ONE identical page', () {
      final project = _tall(8);
      final r = computeSystem(_profile, project);
      final pages = electricalBoardScheduleSheets(
          project: project, result: r, panelId: 'DB');
      expect(pages, hasLength(1));
      final whole =
          buildElectricalSld(project: project, result: r, onlyPanelId: 'DB');
      expect(pages.single.prims.length, whole.prims.length);
    });
  });

  test('no overview feeder tag is struck by a vertical feeder line', () {
    for (final n in [3, 6, 8, 10]) {
      final project = _fan(n);
      final r = computeSystem(_profile, project);
      final s =
          buildElectricalOverview(project: project, result: r, sourceChain: true);
      final lines = s.prims.whereType<SldLine>().toList();
      final tags = s.prims
          .whereType<SldLabel>()
          .where((l) => l.text.contains(' mm2 '))
          .toList();
      expect(tags, isNotEmpty);
      for (final t in tags) {
        expect(_labelStruckByVertical(t, lines), isFalse,
            reason: '$n children: "${t.text}"');
      }
    }
  });

  test('a wide flat tier paginates into chunk pages, each at 7 pt', () {
    final project = _fan(14);
    final r = computeSystem(_profile, project);
    final whole =
        buildElectricalOverview(project: project, result: r, sourceChain: true);
    expect(sldSinglePageMinLabelPt(whole), lessThan(kMinPlotLabelPt));
    final pages = paginatedElectricalOverviewSheets(project: project, result: r);
    expect(pages.length, greaterThan(1));
    for (final p in pages) {
      expect(sldSinglePageMinLabelPt(p),
          greaterThanOrEqualTo(kMinPlotLabelPt - 1e-9));
    }
    // Every sub-board is on exactly one page.
    for (var i = 1; i <= 14; i++) {
      var n = 0;
      for (final p in pages) {
        n += p.prims
            .whereType<SldLabel>()
            .where((l) => l.bold && l.text == 'SDP-$i')
            .length;
      }
      expect(n, 1, reason: 'SDP-$i');
    }
  });

  group('essential boards on the schedule + honest legends', () {
    final project = _fan(3, essentialFrom: 3);
    final r = computeSystem(_profile, project);

    test('the essential board says so; a normal board does not', () {
      final ess = buildElectricalSld(
          project: project, result: r, onlyPanelId: 'SDP3');
      final normal = buildElectricalSld(
          project: project, result: r, onlyPanelId: 'SDP1');
      expect(
          ess.prims.whereType<SldLabel>().any(
              (l) => l.text.contains('ESSENTIAL (GENSET)') &&
                  l.role == SldRole.essential),
          isTrue);
      expect(ess.prims.whereType<SldRect>().first.role, SldRole.essential);
      expect(ess.legend.map((e) => e.code), contains('Essential'));
      expect(
          normal.prims
              .whereType<SldLabel>()
              .any((l) => l.text.contains('ESSENTIAL')),
          isFalse);
      expect(normal.legend.map((e) => e.code), isNot(contains('Essential')));
    });

    test('an all-essential overview page keys no Normal; LV is not MV', () {
      final sub = buildElectricalOverview(
          project: project, result: r, subtreeRootId: 'SDP3');
      expect(sub.legend.map((e) => e.code), isNot(contains('Normal')));
      expect(sub.legend.map((e) => e.code), contains('Essential'));
      final lv = buildElectricalOverview(
          project: project, result: r, sourceChain: true);
      final source = lv.legend.firstWhere((e) => e.code == 'Source');
      expect(source.meaning, 'Utility supply chain');
    });
  });

  test('the LV power one-line states the declared connection capacity', () {
    final declared = _fan(2, capacity: const ApparentPower(197000));
    expect(
        powerOneLineUtilitySub(declared, const ApparentPower(100000)),
        '400 V LV · 197 kVA');
    // Nothing declared ⇒ null (the builder's bare '400 V LV').
    expect(powerOneLineUtilitySub(_fan(2), const ApparentPower(100000)),
        isNull);
  });
}
