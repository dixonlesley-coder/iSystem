# Claude Code on the web — session setup

`hooks/session-start.sh` is a **SessionStart hook**: in a Claude Code *web*
session (`$CLAUDE_CODE_REMOTE == true`) it provisions the toolchain the gate
needs — installs **Flutter 3.44.3 / Dart 3.12.2** (pinned to match
`pubspec.yaml` `sdk: ^3.12.2`) into `/opt/flutter`, puts `flutter`/`dart` on
PATH, and runs `flutter pub get` (app) + `dart pub get` (engine). It is
idempotent (the SDK download is skipped once the container image caches
`/opt/flutter`) and a no-op on local machines.

This exists because the web environment ships **without** the Flutter SDK; the
hook lets a fresh session run the gate (`dart test` + `flutter test` +
`flutter analyze`) without a manual install.

## Activation

The hook only runs automatically once it is registered in
`.claude/settings.json`:

```json
{
  "hooks": {
    "SessionStart": [
      { "hooks": [ { "type": "command",
        "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/session-start.sh" } ] }
    ]
  }
}
```

(Registering a SessionStart hook is treated as agent-config self-modification,
so the file is added deliberately rather than auto-generated.) Once this is on
the repo's default branch, all future web sessions use it. It runs
**synchronously** (the session starts only after deps are ready — no race where
a test runs before the toolchain exists); switch to async mode if faster
startup is preferred over that guarantee.
