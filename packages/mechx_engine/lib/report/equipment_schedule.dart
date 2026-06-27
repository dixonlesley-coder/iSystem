/// Equipment-schedule report generator — renders a first-class MEP equipment
/// SCHEDULE (the tabular take-off an engineer hands to procurement) as Markdown.
///
/// A schedule row is one line of equipment: a tag, the service it serves, its
/// governing duty (flow/head, airflow/static, or demand), a model/spec
/// placeholder the engineer fills from a datasheet, and a quantity. The engine
/// only TABULATES already-solved results — it adds no sizing physics: the duty
/// figures come straight from the live pump/fan duties, the room-air AHU/FCU/AC
/// selections, and the electrical panel results.
///
/// Pure: takes already-computed typed results in [EquipmentScheduleData] and
/// returns a string. Zero Flutter imports — the app gathers provider values into
/// the data struct and handles file IO.
///
/// The model/spec column is intentionally a placeholder ("—" by default, or a
/// caller-supplied override): iSystem sizes duties, it does not pick a
/// manufacturer's catalogue model. There is therefore no standards value here to
/// flag // VERIFY — a tag and a quantity are bookkeeping, not engineering claims.
library;

import '../electrical/model.dart' show ElectricalSystemInfo;
import '../electrical/panel_results.dart';
import '../sizing/fan.dart';
import '../sizing/pump.dart';

/// The category a schedule row belongs to — drives the section grouping.
enum EquipmentCategory { pump, fan, airHandling, panel }

extension EquipmentCategoryInfo on EquipmentCategory {
  /// The schedule-section heading for this category.
  String get heading => switch (this) {
        EquipmentCategory.pump => 'Pumps',
        EquipmentCategory.fan => 'Fans',
        EquipmentCategory.airHandling => 'Air-handling (AHU / FCU / AC)',
        EquipmentCategory.panel => 'Electrical panels',
      };
}

/// One row of the equipment schedule.
class EquipmentScheduleRow {
  /// The equipment tag (e.g. "P-01", "F-02", "MDP"). Never null in a row — the
  /// builders synthesise a sequential tag ("P-01", "F-01"…) when the source
  /// result carries none.
  final String tag;

  /// The service / role the equipment serves (e.g. "Domestic water supply",
  /// "Exhaust air", "Main distribution").
  final String service;

  /// The governing duty, human-readable (e.g. "20.0 L/s @ 30.0 m",
  /// "150 L/s @ 50 Pa", "12.5 kW demand").
  final String duty;

  /// Selected/recommended size, human-readable (e.g. "4.0 kW motor",
  /// "63 A incomer"). Empty when not applicable.
  final String size;

  /// Model / specification — a placeholder the engineer fills from a datasheet.
  /// "—" unless the caller supplied an override.
  final String modelSpec;

  /// Quantity of this item.
  final int qty;

  final EquipmentCategory category;

  const EquipmentScheduleRow({
    required this.tag,
    required this.service,
    required this.duty,
    required this.size,
    required this.modelSpec,
    required this.qty,
    required this.category,
  });
}

/// One pump duty to schedule, with its labelling context.
class PumpScheduleItem {
  final PumpDuty duty;

  /// Equipment tag override (e.g. "P-01"). Null ⇒ a sequential tag is assigned.
  final String? tag;

  /// Service the pump serves (e.g. "Domestic water supply", "Fire pump").
  final String service;

  /// Model/spec datasheet placeholder override. Null ⇒ "—".
  final String? modelSpec;

  final int qty;

  const PumpScheduleItem({
    required this.duty,
    required this.service,
    this.tag,
    this.modelSpec,
    this.qty = 1,
  });
}

/// One fan duty to schedule (covers both ventilation fans and AHU/FCU/AC supply
/// fans — [airHandling] flags the latter so it lands in the air-handling
/// section). Its labelling context mirrors [PumpScheduleItem].
class FanScheduleItem {
  final FanDuty duty;

  /// Equipment tag override (e.g. "F-01", "AHU-1"). Null ⇒ a sequential tag.
  final String? tag;

  /// Service the fan serves (e.g. "Exhaust air", "Office AHU").
  final String service;

  final String? modelSpec;

  final int qty;

  /// When true this duty is an AHU / FCU / packaged-AC air mover and is grouped
  /// under "Air-handling" rather than "Fans".
  final bool airHandling;

  const FanScheduleItem({
    required this.duty,
    required this.service,
    this.tag,
    this.modelSpec,
    this.qty = 1,
    this.airHandling = false,
  });
}

/// All inputs the equipment schedule tabulates. Empty lists ⇒ the section is
/// skipped; an all-empty data set yields an "(no equipment scheduled)" note.
class EquipmentScheduleData {
  final String projectName;
  final String date;

  final List<PumpScheduleItem> pumps;
  final List<FanScheduleItem> fans;

  /// Solved electrical system whose panels become one schedule row each. Null ⇒
  /// the panel section is skipped.
  final ElectricalSystemResult? electrical;

  const EquipmentScheduleData({
    required this.projectName,
    required this.date,
    this.pumps = const [],
    this.fans = const [],
    this.electrical,
  });
}

String _fmt(double v, {int dp = 1}) => v.toStringAsFixed(dp);

/// Sequential tag like "P-01", "F-02" — used when a source result carries none.
String _seqTag(String prefix, int oneBasedIndex) =>
    '$prefix-${oneBasedIndex.toString().padLeft(2, '0')}';

/// Build the ordered list of schedule rows from [data]. Pure — the same list
/// backs both the Markdown renderer and any future PDF/CSV emitter.
List<EquipmentScheduleRow> buildEquipmentScheduleRows(
  EquipmentScheduleData data,
) {
  final rows = <EquipmentScheduleRow>[];

  // ── Pumps ────────────────────────────────────────────────────────────────
  for (var i = 0; i < data.pumps.length; i++) {
    final item = data.pumps[i];
    final d = item.duty;
    rows.add(EquipmentScheduleRow(
      tag: item.tag ?? _seqTag('P', i + 1),
      service: item.service,
      duty: '${_fmt(d.flow.inLitersPerSecond)} L/s @ '
          '${_fmt(d.head.meters)} m',
      size: '${_fmt(d.selectedMotor.inKiloWatts, dp: 2)} kW motor',
      modelSpec: item.modelSpec ?? '—',
      qty: item.qty,
      category: EquipmentCategory.pump,
    ));
  }

  // ── Fans + AHU/FCU/AC ──────────────────────────────────────────────────────
  // Separate sequential counters so fans read F-01.. and air-handling AHU-01..
  var fanSeq = 0;
  var ahuSeq = 0;
  for (final item in data.fans) {
    final d = item.duty;
    final isAhu = item.airHandling;
    final tag = item.tag ??
        (isAhu ? _seqTag('AHU', ++ahuSeq) : _seqTag('F', ++fanSeq));
    rows.add(EquipmentScheduleRow(
      tag: tag,
      service: item.service,
      duty: '${_fmt(d.airflow.inLitersPerSecond, dp: 0)} L/s @ '
          '${_fmt(d.totalStaticPressure.pascals, dp: 0)} Pa',
      size: '${_fmt(d.selectedMotor.inKiloWatts, dp: 2)} kW motor',
      modelSpec: item.modelSpec ?? '—',
      qty: item.qty,
      category:
          isAhu ? EquipmentCategory.airHandling : EquipmentCategory.fan,
    ));
  }

  // ── Electrical panels ──────────────────────────────────────────────────────
  final e = data.electrical;
  if (e != null) {
    for (final id in e.order) {
      final p = e.panels[id];
      if (p == null) continue;
      rows.add(EquipmentScheduleRow(
        tag: (p.tag != null && p.tag!.isNotEmpty) ? p.tag! : p.name,
        service: '${p.system.label} distribution',
        duty: '${_fmt(p.demandW / 1000.0, dp: 1)} kW demand',
        size: '${_fmt(p.incomer.breaker.ratingA.amperes, dp: 0)} A incomer',
        modelSpec: '—',
        qty: 1,
        category: EquipmentCategory.panel,
      ));
    }
  }

  return rows;
}

/// Render the full equipment schedule as Markdown.
String buildEquipmentScheduleMarkdown(EquipmentScheduleData data) {
  final rows = buildEquipmentScheduleRows(data);
  final b = StringBuffer();

  b.writeln('# Equipment schedule');
  b.writeln();
  b.writeln('**Project:** ${data.projectName}  ');
  b.writeln('**Date:** ${data.date}');
  b.writeln();

  if (rows.isEmpty) {
    b.writeln('_(no equipment scheduled)_');
    return b.toString();
  }

  // One section per non-empty category, in enum order.
  for (final cat in EquipmentCategory.values) {
    final inCat = [for (final r in rows) if (r.category == cat) r];
    if (inCat.isEmpty) continue;
    b.writeln('## ${cat.heading}');
    b.writeln();
    b.writeln('| Tag | Service | Duty | Size | Model / spec | Qty |');
    b.writeln('| --- | --- | --- | --- | --- | --- |');
    for (final r in inCat) {
      b.writeln('| ${r.tag} | ${r.service} | ${r.duty} | '
          '${r.size} | ${r.modelSpec} | ${r.qty} |');
    }
    b.writeln();
  }

  b.writeln('_Model / spec is a placeholder for the engineer to complete from '
      'the selected manufacturer datasheet; iSystem sizes the duty, not the '
      'catalogue model._');

  return b.toString();
}
