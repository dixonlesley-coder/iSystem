import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mechx_engine/network/network.dart';
import 'package:mechx_engine/sizing/network_sizing.dart';
import 'package:mechx_engine/standards/sni.dart';

/// HVAC duct preferences (shape + sizing method) driving the air code path.
@immutable
class DuctSettings {
  final DuctShape shape;
  final DuctSizingMethod method;
  const DuctSettings({
    this.shape = DuctShape.round,
    this.method = DuctSizingMethod.velocity,
  });

  DuctSettings copyWith({DuctShape? shape, DuctSizingMethod? method}) =>
      DuctSettings(shape: shape ?? this.shape, method: method ?? this.method);
}

final ductSettingsProvider =
    NotifierProvider<DuctSettingsController, DuctSettings>(
  DuctSettingsController.new,
);

class DuctSettingsController extends Notifier<DuctSettings> {
  @override
  DuctSettings build() => const DuctSettings();

  void setShape(DuctShape s) => state = state.copyWith(shape: s);
  void setMethod(DuctSizingMethod m) => state = state.copyWith(method: m);
}

/// How the building is fed (drives the supply solve): an upfeed pump pushing
/// water up from a low plant, or a roof tank distributing by gravity downward.
enum FeedStrategy { upfeed, downfeed }

/// Active feed strategy. Defaults to roof-tank downfeed (the project's chosen
/// strategy); switch to upfeed for pumped ground/basement supply.
final feedStrategyProvider =
    NotifierProvider<FeedStrategyController, FeedStrategy>(
  FeedStrategyController.new,
);

class FeedStrategyController extends Notifier<FeedStrategy> {
  @override
  FeedStrategy build() => FeedStrategy.downfeed;

  void set(FeedStrategy s) => state = s;
}

/// Building occupancy class (private dwelling / public / assembly) — selects the
/// SNI fixture-unit loads used to size the water supply.
final occupancyProvider =
    NotifierProvider<OccupancyController, Occupancy>(OccupancyController.new);

class OccupancyController extends Notifier<Occupancy> {
  @override
  Occupancy build() => Occupancy.private;

  void set(Occupancy o) => state = o;
}

/// Default service to use as the supply (for source auto-pick / solve).
const ServiceType kSupplyService = ServiceType.coldWater;

/// A transient, user-facing error message (e.g. a failed project open). Null
/// when there is nothing to show; the shell renders it as a dismissible banner.
final loadErrorProvider =
    NotifierProvider<LoadErrorController, String?>(LoadErrorController.new);

class LoadErrorController extends Notifier<String?> {
  @override
  String? build() => null;

  void set(String? message) => state = message;
  void clear() => state = null;
}

/// App-wide light/dark brightness. Defaults to dark (the restrained, low-glare
/// default for a drawing tool). Persisted to the project file later.
final brightnessProvider = NotifierProvider<BrightnessController, Brightness>(
  BrightnessController.new,
);

class BrightnessController extends Notifier<Brightness> {
  @override
  Brightness build() => Brightness.dark;

  void toggle() => state =
      state == Brightness.dark ? Brightness.light : Brightness.dark;

  void set(Brightness brightness) => state = brightness;
}

/// Whether the main area shows the generated schematic diagram instead of the
/// plan canvas.
final showSchematicProvider =
    NotifierProvider<ShowSchematicController, bool>(ShowSchematicController.new);

class ShowSchematicController extends Notifier<bool> {
  @override
  bool build() => false;

  void toggle() => state = !state;
}
