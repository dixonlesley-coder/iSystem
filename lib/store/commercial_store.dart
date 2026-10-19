/// Riverpod store for the Commercial workspace — the pricelist + quote settings
/// the user edits, plus the derived (pure-engine) BOM, cost estimate and
/// quotation built over them.
///
/// The engine commercial pipeline is pure (`electrical/{bom,costing,quotation}`):
///   electricalResultProvider  → buildBom(fullCatalog())     [electricalBomProvider]
///                             → estimateCost(bom, priceList) [electricalCostProvider]
///                             → buildQuotation(cost, …)      [electricalQuotationProvider]
/// Prices NEVER live in the committed catalogue — this store owns the
/// `sku → unit price` map (persisted in the `.mechx` `DesignSettings`). The same
/// map ALSO carries the mechanical prices (mech-namespaced keys), which the H10
/// `mechanicalCostProvider` / `mepQuotationProvider` fold into ONE M+E+P
/// quotation (`report/mep_commercial.dart`).
///
/// Riverpod: a [Notifier] for the mutable [CommercialSettings], `Provider`s for
/// the derived pipeline (recomputed whenever the project, the pricelist or the
/// quote settings change), mirroring the app's other stores.
library;

import 'package:flutter/widgets.dart' show immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/electrical/advanced_bom.dart';
import 'package:mechx_engine/electrical/bom.dart';
import 'package:mechx_engine/electrical/catalog.dart';
import 'package:mechx_engine/electrical/costing.dart';
import 'package:mechx_engine/electrical/quotation.dart';
import 'package:mechx_engine/report/mep_commercial.dart';
import 'package:mechx_engine/sizing/bom.dart'
    show ComponentLine, buildEquipmentTakeoff;

import '../ui/strings/app_strings.dart';
import 'app_state.dart' show localeProvider;
import 'electrical_feed.dart' show riserEquipmentDetailsProvider;
import 'electrical_store.dart';
import 'network_store.dart' show sizingNetworkProvider;
import 'history_store.dart' show SettingsUndoEntry, settingsHistoryProvider;
import 'solve_store.dart';

/// The user-editable commercial inputs: the catalogue pricelist (`sku → unit
/// price`) and the quotation markups. Immutable; the controller replaces it on
/// every edit so the derived providers recompute.
@immutable
class CommercialSettings {
  /// Unit price map (project currency). Holds BOTH the electrical catalogue
  /// order-codes AND the mechanical price keys (`mech:pipe:…` / `mech:fitting:…`,
  /// see `report/mep_commercial.dart` — they never collide with an electrical
  /// SKU), so the mechanical prices ride the existing persisted `priceList` with
  /// no new `.mechx` field. Prices NEVER live in the committed catalogue.
  final Map<String, double> priceList;

  /// Labour rate (currency per hour) used for the assembly-labour subtotal.
  final double labourRatePerHour;

  /// Overhead loading (%) on the prime (material + labour) cost.
  final double overheadPct;

  /// Contingency / risk allowance (%) on the prime cost.
  final double contingencyPct;

  /// Profit margin (%) — a TRUE gross margin on the cost base (see
  /// `buildQuotation`).
  final double marginPct;

  const CommercialSettings({
    this.priceList = const {},
    this.labourRatePerHour = 150000,
    this.overheadPct = 10,
    this.contingencyPct = 5,
    this.marginPct = 15,
  });

  CommercialSettings copyWith({
    Map<String, double>? priceList,
    double? labourRatePerHour,
    double? overheadPct,
    double? contingencyPct,
    double? marginPct,
  }) =>
      CommercialSettings(
        priceList: priceList ?? this.priceList,
        labourRatePerHour: labourRatePerHour ?? this.labourRatePerHour,
        overheadPct: overheadPct ?? this.overheadPct,
        contingencyPct: contingencyPct ?? this.contingencyPct,
        marginPct: marginPct ?? this.marginPct,
      );
}

/// The mutable commercial settings (pricelist + quote markups). Edited by the
/// Commercial workspace; loaded / saved with the project via [DesignSettings].
final commercialSettingsProvider =
    NotifierProvider<CommercialController, CommercialSettings>(
  CommercialController.new,
);

class CommercialController extends Notifier<CommercialSettings> {
  @override
  CommercialSettings build() => const CommercialSettings();

  /// Replace the whole settings object (used by `applyDocument` on load).
  void set(CommercialSettings settings) => state = settings;

  /// Round 28 (persist-undo-2-2) — the pricelist and markups are persisted in
  /// `.mechx` and drive the issued quotation, so each user edit records ONE
  /// [UndoDomain.settings] step (an edit that changes nothing records
  /// nothing). [set] (load) stays non-recording.
  void _commit(CommercialSettings next) {
    final previous = state;
    if (_same(previous, next)) return;
    state = next;
    ref.read(settingsHistoryProvider.notifier).record(SettingsUndoEntry(
          label: MechXStringsData(ref.read(localeProvider))(
              StringKey.undoLabelPricelist),
          undo: () => state = previous,
          redo: () => state = next,
        ));
  }

  static bool _same(CommercialSettings a, CommercialSettings b) {
    if (a.labourRatePerHour != b.labourRatePerHour ||
        a.overheadPct != b.overheadPct ||
        a.contingencyPct != b.contingencyPct ||
        a.marginPct != b.marginPct ||
        a.priceList.length != b.priceList.length) {
      return false;
    }
    for (final e in a.priceList.entries) {
      if (b.priceList[e.key] != e.value) return false;
    }
    return true;
  }

  /// Set / clear one part's unit price. A null or non-positive [price] removes
  /// the entry (so an empty cell un-prices the line rather than pinning 0).
  void setPrice(String sku, double? price) {
    final next = Map<String, double>.from(state.priceList);
    if (price == null || price <= 0) {
      next.remove(sku);
    } else {
      next[sku] = price;
    }
    _commit(state.copyWith(priceList: next));
  }

  /// Remove one part's price.
  void clearPrice(String sku) => setPrice(sku, null);

  /// Replace the whole pricelist (e.g. paste / import).
  void setPriceList(Map<String, double> priceList) =>
      _commit(state.copyWith(priceList: Map<String, double>.from(priceList)));

  void setLabourRate(double rate) =>
      _commit(state.copyWith(labourRatePerHour: rate < 0 ? 0 : rate));

  void setOverheadPct(double pct) =>
      _commit(state.copyWith(overheadPct: pct.clamp(0.0, 100.0)));

  void setContingencyPct(double pct) =>
      _commit(state.copyWith(contingencyPct: pct.clamp(0.0, 100.0)));

  void setMarginPct(double pct) =>
      _commit(state.copyWith(marginPct: pct.clamp(0.0, 99.9)));
}

/// Derived: the electrical bill of materials over the FULL multi-brand catalogue
/// (so the matcher binds order codes from every brand), recomputed whenever the
/// sized electrical result changes.
///
/// Breakers match catalogue parts whose breaking capacity covers each board's
/// prospective fault (the same fault study the schedule's kA tokens read —
/// audit r8 costing-4), so the quote never prices a 6 kA MCB at an 18 kA bus.
final electricalBomProvider = Provider<Bom>((ref) {
  final adv = ref.watch(electricalAdvancedProvider);
  final sys = ref.watch(electricalResultProvider);
  // Round 15 — each device matches the SPECIFIED kA the schedule prints.
  final ka = faultSpecifiedKa(adv.fault);
  return buildBom(
    sys,
    parts: fullCatalog(),
    requiredIcuKaByPanelId: ka.bus,
    incomerKaByPanelId: ka.incomers,
    breakerKaByCircuitId: ka.breakers,
    // Round 21 (bom-quote-4/-5) — each enclosure at its sized W x H x D, and
    // the designed control gear / genset + ATS / SPDs / earthing taken off.
    enclosureByPanelId: adv.enclosure,
    extraLines: advancedBomLines(
      project: ref.watch(electricalProjectProvider),
      sys: sys,
      controlAssemblies: adv.controlAssemblies,
      spd: adv.spd,
      electrode: adv.electrode,
    ),
  );
});

/// Derived: the priced material estimate — the BOM costed against the live
/// pricelist. Unmatched lines (no sku, or a sku with no price) are kept but
/// contribute nothing, so the table can prompt the user to resolve them.
final electricalCostProvider = Provider<CostEstimate>(
  (ref) => estimateCost(
    ref.watch(electricalBomProvider),
    ref.watch(commercialSettingsProvider).priceList,
  ),
);

/// Derived: the finished quotation (material + labour + overhead + contingency +
/// margin → sell price) over the priced estimate and the live quote settings.
/// Labour is derived from the BOM via the engine's labour standard.
final electricalQuotationProvider = Provider<Quotation>((ref) {
  final settings = ref.watch(commercialSettingsProvider);
  return buildQuotation(
    ref.watch(electricalCostProvider),
    bom: ref.watch(electricalBomProvider),
    labourRate: settings.labourRatePerHour,
    overheadPct: settings.overheadPct,
    contingencyPct: settings.contingencyPct,
    marginPct: settings.marginPct,
  );
});

/// Derived (H10): the priced MECHANICAL material estimate — the sized mechanical
/// pipe/duct BOM + fittings (from the solve store) costed against the live
/// pricelist by mechanical key, enriched with the pipe cut-plan (stock bars /
/// waste). Unpriced lines contribute nothing and are counted, so the pricelist
/// can prompt the user. Empty when nothing mechanical is sized ⇒ zero subtotal.
/// Round 30 (costing-2-1) — the drawn PLANT (pumps, tanks, boosters, AHU /
/// FCU, fans, AC units) taken off per piece by its duty — the same per-node
/// detail the riser and the schedule print (tank m3 / the machine's motor
/// kW) — so the quotation never silently omits the largest items.
final equipmentTakeoffProvider = Provider<List<ComponentLine>>((ref) {
  return buildEquipmentTakeoff(
    net: ref.watch(sizingNetworkProvider),
    dutyByNodeId: ref.watch(riserEquipmentDetailsProvider),
  );
});

final mechanicalCostProvider = Provider<MechCostEstimate>((ref) {
  return estimateMechanicalCost(
    pipes: ref.watch(bomProvider),
    fittings: ref.watch(fittingsProvider),
    components: ref.watch(componentTakeoffProvider),
    equipment: ref.watch(equipmentTakeoffProvider),
    priceList: ref.watch(commercialSettingsProvider).priceList,
    cutPlan: ref.watch(pipeCutPlanProvider),
  );
});

/// Derived (H10): the unified M+E+P quotation — the mechanical + electrical
/// material subtotals folded into ONE costed roll-up with per-discipline
/// figures. Labour is the mechanical install hours + the electrical assembly
/// hours; overhead / contingency / margin apply to the combined prime. An
/// ELECTRICAL-only project (no mechanical BOM) reduces to the electrical-only
/// quotation (byte-identical roll-up).
final mepQuotationProvider = Provider<MepQuotation>((ref) {
  final settings = ref.watch(commercialSettingsProvider);
  return buildMepQuotation(
    mechanical: ref.watch(mechanicalCostProvider),
    electrical: ref.watch(electricalCostProvider),
    electricalBom: ref.watch(electricalBomProvider),
    mechanicalPipes: ref.watch(bomProvider),
    mechanicalFittings: ref.watch(fittingsProvider),
    mechanicalComponents: ref.watch(componentTakeoffProvider),
    mechanicalEquipment: ref.watch(equipmentTakeoffProvider),
    labourRate: settings.labourRatePerHour,
    overheadPct: settings.overheadPct,
    contingencyPct: settings.contingencyPct,
    marginPct: settings.marginPct,
  );
});
