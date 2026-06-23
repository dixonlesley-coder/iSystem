# iSystem

Offline, native **Windows desktop** application for **MEP** (mechanical /
electrical / plumbing) design. Load PDF floor plans, calibrate scale, set
per-floor heights, drag duct/pipe elements, and the app auto-sizes everything to
**Indonesian SNI / PUIL** standards — sizing pumps and fire systems, auto-drawing
schematic risers, showing a live pressure heatmap, designing the **electrical**
panels/feeders (cables, breakers, busbars, earthing), and producing a Bill of
Materials. No internet connection required.

> Formerly **MechX** (M+P); the electrical ("E") domain was merged in, so the
> product is now **iSystem**. The internal Dart packages (`mechx_engine`, the
> `mechx` app package) keep their names; only the product/UI branding changed.

> **Spec:** [`MEP-PDF-Sizing-Tool-Build-Plan.md`](MEP-PDF-Sizing-Tool-Build-Plan.md)
> is the authoritative, living source of truth. Read it first.

## Status

**Step 1 complete** — project scaffolded and anchored on green seed tests. UI
work (Phase 0) has **not** started yet.

## Structure

```
mechx/                       Flutter app (Windows/Linux/macOS)  — package: mechx
├─ lib/{ui,data,store}/      screens / persistence / state       (P0+)
├─ test/                     widget + integration tests
└─ packages/mechx_engine/    PURE-DART engine (zero Flutter imports)
   ├─ lib/units.dart         SI typed quantities
   ├─ lib/hydraulics.dart    hydraulic-formula kernel
   ├─ lib/pressure_field.dart heatmap scalar-field kernel
   ├─ lib/standards/sni.dart pluggable SNI standards data
   └─ test/                  seed correctness anchors
```

The calculation engine is a **separate pure-Dart package** so it has zero
Flutter dependencies and runs under `dart test` with full coverage. The Flutter
app consumes it by path.

## Developing

Requires Flutter (≥3.44) / Dart (≥3.12).

```bash
# Engine — pure Dart, the correctness anchor:
cd packages/mechx_engine
dart pub get
dart test          # 29 seed tests, all green
dart analyze       # clean

# App shell:
cd ../..
flutter pub get
flutter test
# Windows build is produced on a Windows machine:  flutter build windows
```

## ⚠️ SNI values are unverified placeholders

Every value in `standards/sni.dart` tagged `// VERIFY` (and with
`StandardValue.verified == false`) is a **draft placeholder**, not an
authoritative SNI figure. They are surfaced as **UNVERIFIED** and must be
transcribed from the official SNI PDFs before any real use. Top of the list:
SNI 8153 max fixture static pressure (zoning trigger) and the demand-curve table.
