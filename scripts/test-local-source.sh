#!/bin/bash
# Real signing/XPC tests, still without installation or energy mutations.
# Requires the same locally available development identity used to build.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IDENTITY="${INSOMNIA_SIGNING_IDENTITY:?Set the development signing identity for the re-signing rejection test}"
STAGE="$(mktemp -d /private/tmp/insomnia-source-tests.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT
/usr/bin/ditto -x -k "$ROOT/build/StayAwake-local-source.zip" "$STAGE"
APP="$STAGE/Stay Awake.app"
BIN="$APP/Contents/MacOS/Insomnia"
/usr/bin/codesign --verify --strict "$APP"
REQUIREMENT="$("$BIN" --local-verify-build)"
[[ "$REQUIREMENT" == *'and cdhash H"'* ]] || { echo 'Missing exact-build restriction.' >&2; exit 1; }
/usr/bin/codesign --verify --strict "-R=$REQUIREMENT" "$APP"
"$BIN" --local-gui-self-test
"$BIN" --local-xpc-self-test
"$BIN" --local-self-test
if "$BIN" --local-register-power; then
  echo 'ERROR: unprotected build was allowed to register.' >&2; exit 1
fi
# Never run a tampered or re-signed copy. Only the system verifier reads it.
printf '\n# deliberate test mutation\n' >> "$APP/Contents/Resources/backstop.sh"
if /usr/bin/codesign --verify --strict "$APP" >/dev/null 2>&1; then
  echo 'ERROR: modified resource was accepted.' >&2; exit 1
fi
/usr/bin/codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$APP"
/usr/bin/codesign --verify --strict "$APP"
if /usr/bin/codesign --verify --strict "-R=$REQUIREMENT" "$APP" >/dev/null 2>&1; then
  echo 'ERROR: a different build signed with the same key was accepted.' >&2; exit 1
fi
echo 'PASS: resource tampering and same-key re-signing rejected by the approved-build policy.'
