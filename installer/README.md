# iSystem Windows installer (Inno Setup)

`iSystem.iss` packages the native-Windows Flutter Release build into a single
`iSystem-<version>-setup.exe` installer. This replaces the model PanelMaker used
with electron-builder NSIS; the in-app auto-updater (`lib/update/`) downloads and
silently runs this installer to upgrade in place.

## Prerequisites

- A Windows machine (or `windows-latest` CI runner) — `flutter build windows`
  and `iscc` (the Inno Setup compiler) only run on Windows.
- [Inno Setup 6](https://jrsoftware.org/isinfo.php). In CI:
  `choco install innosetup -y`.

## Build locally

```bat
:: 1. Build the Flutter Windows Release bundle.
flutter build windows --release

:: 2. Compile the installer, injecting the version (use your pubspec version).
iscc /dAppVersion=1.2.0 installer\iSystem.iss
```

The installer is written to `build\installer\iSystem-1.2.0-setup.exe`.

- `/dAppVersion=X.Y.Z` sets `AppVersion`. If you omit it (`iscc
  installer\iSystem.iss`) it falls back to `0.0.0` so the script still compiles.
- The script reads the Flutter Release output from
  `build\windows\x64\runner\Release\` (relative to `installer\`).

## Notes

- **Executable name.** Flutter's Windows runner produces `mechx.exe`
  (`windows/CMakeLists.txt` `BINARY_NAME=mechx`, kept internal). The installer
  ships and relaunches it under the product name **`iSystem.exe`** by renaming on
  install (`DestName`). A Flutter executable resolves its `data\` folder and DLLs
  by relative path, not by its own filename, so the rename is safe.
- **Fixed `AppId` GUID.** Upgrades replace the prior install in place — never
  regenerate the GUID in `iSystem.iss` or auto-update will install side-by-side.
- **Silent install.** Accepts `/SILENT` and `/VERYSILENT`; the auto-updater runs
  `iSystem-<v>-setup.exe /SILENT`. `CloseApplications=yes` +
  `RestartApplications=yes` close the running app for the upgrade and relaunch it
  afterwards, so a locked exe never blocks the update.
- **Unsigned.** End users see a one-time Windows SmartScreen "unknown publisher"
  prompt on first install. Auto-update still works (Inno just runs the new
  installer). Sign the produced `.exe` with an Authenticode certificate to remove
  the prompt.
