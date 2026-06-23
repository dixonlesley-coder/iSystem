#!/bin/bash
# iSystem SessionStart hook — provision the Flutter/Dart toolchain + deps so the
# gate (engine `dart test` + app `flutter test` + `flutter analyze`) is runnable
# in a Claude Code on the web session. Idempotent; web-only.
set -euo pipefail

# Local dev machines already have Flutter — only provision the remote web env.
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

FLUTTER_VERSION="3.44.3"   # bundles Dart 3.12.2 (matches pubspec sdk: ^3.12.2)
FLUTTER_DIR="/opt/flutter"
ARCHIVE="https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz"

# 1. Install the SDK (skipped once the container image caches /opt/flutter).
if [ ! -x "${FLUTTER_DIR}/bin/flutter" ]; then
  echo "Installing Flutter ${FLUTTER_VERSION}..." >&2
  tmp="$(mktemp -d)"
  curl -fSL --retry 3 -o "${tmp}/flutter.tar.xz" "${ARCHIVE}"
  tar -xJf "${tmp}/flutter.tar.xz" -C /opt
  rm -rf "${tmp}"
fi

# 2. Put flutter/dart on PATH. Symlinks survive in the cached container; the env
#    file makes PATH explicit for this session's (non-login) shells.
ln -sf "${FLUTTER_DIR}/bin/flutter" /usr/local/bin/flutter
ln -sf "${FLUTTER_DIR}/bin/dart" /usr/local/bin/dart
git config --global --add safe.directory "${FLUTTER_DIR}" || true
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  echo "export PATH=\"${FLUTTER_DIR}/bin:\$PATH\"" >> "${CLAUDE_ENV_FILE}"
fi
export PATH="${FLUTTER_DIR}/bin:$PATH"

# 3. Fetch dependencies (cached in ~/.pub-cache after the first run).
cd "${CLAUDE_PROJECT_DIR}"
flutter pub get >&2
( cd packages/mechx_engine && dart pub get >&2 )

echo "Flutter toolchain ready: $(flutter --version 2>/dev/null | head -1)" >&2
