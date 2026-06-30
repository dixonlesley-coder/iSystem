; iSystem — Inno Setup installer script (Workstream B).
;
; Builds an unsigned per-user/elevated installer for the native-Windows Flutter
; build, mirroring the model PanelMaker used with electron-builder NSIS
; (oneClick:false → a wizard the user can step through, choose an install dir,
; and that closes/relaunches the running app on upgrade so auto-update works).
;
; Build locally or in CI (see installer/README.md):
;   flutter build windows --release
;   iscc /dAppVersion=1.2.0 installer\iSystem.iss
; The version is injected with /dAppVersion=. If omitted, a fallback is used so
; a bare `iscc installer\iSystem.iss` still compiles.
;
; NOTE on the executable name: Flutter's Windows runner builds `mechx.exe`
; (windows/CMakeLists.txt BINARY_NAME=mechx, kept internal per the merge). The
; installer ships + relaunches it under the product name `iSystem.exe` by
; renaming on install (DestName below). A Flutter exe resolves its data/ and
; DLLs by RELATIVE path, not by its own filename, so the rename is safe.

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif

; The filename the Flutter Windows runner actually produces (BINARY_NAME).
#define BuiltExeName "mechx.exe"
; The product-branded name we install + relaunch as.
#define AppExeName "iSystem.exe"

[Setup]
; A FIXED GUID identifies the application across versions so upgrades replace the
; prior install in-place (do NOT regenerate this — auto-update relies on it).
AppId={{B3F1B7E2-6C4A-4E8D-9A1F-7C2E5D0A9B34}
AppName=iSystem
AppVersion={#AppVersion}
AppVerName=iSystem {#AppVersion}
AppPublisher=iSystem
DefaultDirName={autopf}\iSystem
DefaultGroupName=iSystem
DisableProgramGroupPage=yes
; Per-machine install when elevated; falls back to per-user when not.
PrivilegesRequiredOverridesAllowed=dialog commandline
OutputDir=..\build\installer
OutputBaseFilename=iSystem-{#AppVersion}-setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
; On upgrade, gracefully close the running app so a locked exe never blocks the
; update (the auto-update path runs the installer silently while iSystem is
; open). Relaunch is handled EXPLICITLY by the [Run] entries below, NOT by the
; Restart Manager: the in-app updater self-exits (exit(0)) before the installer
; copies files, so Setup never closes iSystem via the Restart Manager and so
; RestartApplications has nothing to restart — leaving the app dead after a
; silent update. Keep CloseApplications (close any still-running instance) but
; turn RestartApplications OFF so the explicit [Run] relaunch is the single,
; reliable restart path (no Restart-Manager double-launch).
CloseApplications=yes
RestartApplications=no
; Unsigned build: end users see a one-time SmartScreen "unknown publisher"
; prompt on first install. Sign the .exe with an Authenticode cert to remove it.

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
; The entire Flutter Release output (exe + flutter_windows.dll + data\ + plugin
; DLLs), recursively. The runner exe is renamed to the product name on install.
Source: "..\build\windows\x64\runner\Release\{#BuiltExeName}"; DestDir: "{app}"; DestName: "{#AppExeName}"; Flags: ignoreversion
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Excludes: "{#BuiltExeName}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\iSystem"; Filename: "{app}\{#AppExeName}"
Name: "{group}\Uninstall iSystem"; Filename: "{uninstallexe}"
Name: "{autodesktop}\iSystem"; Filename: "{app}\{#AppExeName}"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional shortcuts:"; Flags: unchecked

[Run]
; Relaunch iSystem after the update, on BOTH paths:
;   • INTERACTIVE install — a checkbox on the Finished wizard page (postinstall).
;     `skipifsilent` keeps it from showing during a silent auto-update.
; `runasoriginaluser` relaunches as the logged-in user (not elevated) when the
; installer ran per-machine, so the app doesn't come back up with admin rights.
Filename: "{app}\{#AppExeName}"; Description: "Launch iSystem"; Flags: nowait postinstall skipifsilent runasoriginaluser
;   • SILENT auto-update (the in-app updater runs the installer with /SILENT and
;     self-exits) — there is no Finished page, so relaunch automatically. Gated by
;     the built-in WizardSilent() so it fires ONLY on the silent path (the
;     interactive path uses the checkbox above), giving exactly ONE relaunch.
;     This is what makes the app auto-restart itself after an auto-update.
Filename: "{app}\{#AppExeName}"; Flags: nowait runasoriginaluser; Check: WizardSilent
