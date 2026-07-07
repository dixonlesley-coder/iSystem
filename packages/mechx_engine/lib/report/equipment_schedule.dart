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

import '../electrical/model.dart' show ElectricalProject, ElectricalSystemInfo;
import '../electrical/panel_results.dart';
import '../electrical/sources.dart' show selectGeneratorKva;
import '../sizing/fan.dart';
import '../sizing/pump.dart';
import '../units.dart' show ApparentPower;
import 'report_blocks.dart';
import 'report_strings.dart';

/// The category a schedule row belongs to — drives the section grouping. The
/// source apparatus (transformer / standby generator / capacitor bank) sit AFTER
/// the panel section so an existing (apparatus-free) schedule is byte-identical.
enum EquipmentCategory {
  pump,
  fan,
  airHandling,
  panel,
  transformer,
  generator,
  capacitorBank,
}

extension EquipmentCategoryInfo on EquipmentCategory {
  /// The schedule-section heading for this category.
  String get heading => switch (this) {
        EquipmentCategory.pump => 'Pumps',
        EquipmentCategory.fan => 'Fans',
        EquipmentCategory.airHandling => 'Air-handling (AHU / FCU / AC)',
        EquipmentCategory.panel => 'Electrical panels',
        EquipmentCategory.transformer => 'Transformer',
        EquipmentCategory.generator => 'Standby generator',
        EquipmentCategory.capacitorBank => 'Capacitor bank',
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

  /// The electrical project the source apparatus (transformer / standby genset /
  /// PF-correction bank) is read from (N22): a transformer row from
  /// [ElectricalProject.transformerKva], a genset row from
  /// `sources.generator` (kVA snapped up the standard ladder against the
  /// backup fraction × the diversified demand — the SAME derivation the building
  /// single-line source spine draws), and a capacitor row from
  /// `capacitorBankKvar`. Null (or an apparatus the project doesn't carry) ⇒ no
  /// such row — the highest-value long-lead apparatus is never fabricated, but
  /// no longer omitted from the tender schedule when the model does carry it.
  final ElectricalProject? electricalProject;

  /// N23 (residual) — engineer-entered "Model / spec" datasheet strings for the
  /// PANEL + source-apparatus rows (which, unlike pumps/fans, carry no per-item
  /// override), keyed by the row's STABLE tag: a panel's `tag`/`name`, and the
  /// fixed apparatus tags `TX-01` / `G-01` / `CB-01`. A missing/empty entry ⇒
  /// the engine's `'—'` placeholder (byte-identical to before). Never used for
  /// pump/fan rows (those keep their per-item [PumpScheduleItem.modelSpec]).
  final Map<String, String> modelSpecs;

  const EquipmentScheduleData({
    required this.projectName,
    required this.date,
    this.pumps = const [],
    this.fans = const [],
    this.electrical,
    this.electricalProject,
    this.modelSpecs = const {},
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

  // N23 (residual): the engineer-entered model/spec for a PANEL / apparatus row
  // by its stable tag, else the engine's '—' placeholder. Whitespace-only ⇒ '—'.
  String specFor(String tag) {
    final v = data.modelSpecs[tag];
    return (v != null && v.trim().isNotEmpty) ? v.trim() : '—';
  }

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
      final tag = (p.tag != null && p.tag!.isNotEmpty) ? p.tag! : p.name;
      rows.add(EquipmentScheduleRow(
        tag: tag,
        service: '${p.system.label} distribution',
        duty: '${_fmt(p.demandW / 1000.0, dp: 1)} kW demand',
        size: '${_fmt(p.incomer.breaker.ratingA.amperes, dp: 0)} A incomer',
        modelSpec: specFor(tag),
        qty: 1,
        category: EquipmentCategory.panel,
      ));
    }
  }

  // ── Source apparatus (transformer / standby genset / PF bank) ──────────────
  // The longest-lead, highest-value apparatus, tabulated from the project (no
  // new physics — the genset kVA is a ladder SELECTION mirroring the source
  // spine). Each is emitted only when the model actually carries it.
  final ep = data.electricalProject;
  if (ep != null) {
    final tx = ep.transformerKva;
    if (tx != null && tx.inKilovoltAmperes > 0) {
      rows.add(EquipmentScheduleRow(
        tag: 'TX-01',
        service: 'Distribution transformer',
        duty: '${_fmt(tx.inKilovoltAmperes, dp: 0)} kVA',
        size: '',
        modelSpec: specFor('TX-01'),
        qty: ep.dualTransformer ? 2 : 1,
        category: EquipmentCategory.transformer,
      ));
    }

    final gen = ep.sources?.generator;
    if (gen != null) {
      // Forced nameplate wins; else snap the backup demand up the genset ladder
      // (backupFraction × diversified demand), exactly as the source spine does.
      // No result / no demand and no forced kVA ⇒ can't size ⇒ no row.
      final demandVa = data.electrical?.supply.demandVa;
      final ApparentPower? genKva = gen.kva ??
          (demandVa != null && demandVa.inKilovoltAmperes > 0
              ? selectGeneratorKva(
                  ApparentPower(demandVa.voltAmperes * gen.backupFraction))
              : null);
      if (genKva != null && genKva.inKilovoltAmperes > 0) {
        rows.add(EquipmentScheduleRow(
          tag: 'G-01',
          service: 'Standby generator',
          duty: '${_fmt(genKva.inKilovoltAmperes, dp: 0)} kVA',
          size: '',
          modelSpec: specFor('G-01'),
          qty: 1,
          category: EquipmentCategory.generator,
        ));
      }
    }

    final kvar = ep.capacitorBankKvar;
    if (kvar != null && kvar > 0) {
      rows.add(EquipmentScheduleRow(
        tag: 'CB-01',
        service: 'PF-correction bank',
        duty: '${_fmt(kvar, dp: 0)} kvar',
        size: '',
        modelSpec: specFor('CB-01'),
        qty: 1,
        category: EquipmentCategory.capacitorBank,
      ));
    }
  }

  return rows;
}

/// Build the equipment schedule as the neutral block list — the one content
/// model behind the Markdown render ([buildEquipmentScheduleMarkdown]) and the
/// PDF typesetter.
/// The localized schedule-section heading for [cat] (the [EquipmentCategoryInfo]
/// extension getter stays the EN default for callers that don't localize).
String _categoryHeading(EquipmentCategory cat, ReportStrings strings) =>
    switch (cat) {
      EquipmentCategory.pump => strings(RptStringKey.catPumps),
      EquipmentCategory.fan => strings(RptStringKey.catFans),
      EquipmentCategory.airHandling => strings(RptStringKey.catAirHandling),
      EquipmentCategory.panel => strings(RptStringKey.catPanels),
      EquipmentCategory.transformer => strings(RptStringKey.catTransformer),
      EquipmentCategory.generator => strings(RptStringKey.catGenerator),
      EquipmentCategory.capacitorBank =>
        strings(RptStringKey.catCapacitorBank),
    };

List<RptBlock> buildEquipmentScheduleBlocks(EquipmentScheduleData data,
    [ReportStrings strings = const ReportStrings.en()]) {
  final rows = buildEquipmentScheduleRows(data);
  final blocks = <RptBlock>[
    RptHeading(1, strings(RptStringKey.headingEquipmentSchedule)),
    // The project/date pair uses a Markdown two-space hard break between the
    // lines — a stubborn legacy construct, kept verbatim via RptMarkdown.
    RptMarkdown(strings.format(RptStringKey.esProjectDate,
        {'name': data.projectName, 'date': data.date})),
  ];

  if (rows.isEmpty) {
    blocks.add(RptNote(strings(RptStringKey.esNoEquipment)));
    return blocks;
  }

  // One section per non-empty category, in enum order.
  for (final cat in EquipmentCategory.values) {
    final inCat = [for (final r in rows) if (r.category == cat) r];
    if (inCat.isEmpty) continue;
    blocks
      ..add(RptHeading(2, _categoryHeading(cat, strings)))
      ..add(RptTable(
        [
          strings(RptStringKey.tblTag),
          strings(RptStringKey.tblService),
          strings(RptStringKey.tblDuty),
          strings(RptStringKey.tblSize),
          strings(RptStringKey.tblModelSpec),
          strings(RptStringKey.tblQty),
        ],
        [
          for (final r in inCat)
            [r.tag, r.service, r.duty, r.size, r.modelSpec, '${r.qty}'],
        ],
        mdSeparator: '| --- | --- | --- | --- | --- | --- |',
      ));
  }

  blocks.add(RptNote(strings(RptStringKey.esClosingNote)));

  return blocks;
}

/// Render the full equipment schedule as Markdown.
String buildEquipmentScheduleMarkdown(EquipmentScheduleData data,
        [ReportStrings strings = const ReportStrings.en()]) =>
    renderRptMarkdown(buildEquipmentScheduleBlocks(data, strings));

/// Escape a value for a CSV cell: wrap in quotes and double any embedded
/// quotes when it contains a comma, quote or newline (mirrors
/// `electrical/commercial_export.dart`).
String _csv(String v) {
  if (v.contains(',') || v.contains('"') || v.contains('\n')) {
    return '"${v.replaceAll('"', '""')}"';
  }
  return v;
}

/// Render [rows] (from [buildEquipmentScheduleRows]) as CSV — the spreadsheet
/// deliverable the row model was designed for. One header line, then one line
/// per row: `tag,category,service,duty,size,model_spec,qty`.
String equipmentScheduleToCsv(List<EquipmentScheduleRow> rows) {
  final b = StringBuffer('tag,category,service,duty,size,model_spec,qty\n');
  for (final r in rows) {
    b
      ..write(_csv(r.tag))
      ..write(',')
      ..write(_csv(r.category.name))
      ..write(',')
      ..write(_csv(r.service))
      ..write(',')
      ..write(_csv(r.duty))
      ..write(',')
      ..write(_csv(r.size))
      ..write(',')
      ..write(_csv(r.modelSpec))
      ..write(',')
      ..write(r.qty)
      ..write('\n');
  }
  return b.toString();
}
