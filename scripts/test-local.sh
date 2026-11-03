#!/bin/bash
# No installation or live power mutations. Real smoke test is separate.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${INSOMNIA_WORK_DIR:-$ROOT/.local-work}"
export CLANG_MODULE_CACHE_PATH="$WORK/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$WORK/module-cache"
cd "$ROOT"
# Legacy shell installer/backstop and packaging have been replaced for local
# builds. Their suites are not evidence for the signed XPC route.
exec /usr/bin/swift test --disable-sandbox \
  --cache-path "$WORK/package-cache" \
  --config-path "$WORK/package-config" \
  --security-path "$WORK/package-security" \
  --scratch-path "$WORK/local-build" \
  --skip 'RecoveryScriptTests|PackagingTests' "$@"
