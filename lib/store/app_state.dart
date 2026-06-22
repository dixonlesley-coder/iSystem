import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
