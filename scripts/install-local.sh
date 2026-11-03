#!/bin/bash
# Reviewable plan by default. --apply is required for any installation.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARCHIVE="$ROOT/build/StayAwake-development.zip"
DEST="$HOME/Applications/Stay Awake.app"
case "${1:---plan}" in
  --plan)
    printf '%s\n' 'Plan: verify the signed/notarized archive; install Stay Awake.app in ~/Applications; register its restricted power service through SMAppService.' 'macOS may require approval in Login Items & Extensions. No session is started. No sudoers rule is created.' 'An existing installation is refused; use the recovery-first uninstaller before replacing it.'
    exit 0 ;;
  --apply) [[ $# == 1 ]] || exit 2 ;;
  *) echo 'usage: scripts/install-local.sh [--plan|--apply]' >&2; exit 2 ;;
esac
TEAM="${INSOMNIA_EXPECTED_TEAM_ID:-}"
[[ "$TEAM" =~ ^[A-Z0-9]{10}$ ]] || { echo 'Set INSOMNIA_EXPECTED_TEAM_ID to the Apple Developer team that signed your reviewed build. Nothing changed.' >&2; exit 1; }
REQUIREMENT="anchor apple generic and identifier \"local.insomnialocal.app\" and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"$TEAM\""
[[ -z "${INSOMNIA_HOME:-}" ]] || { echo 'Relocated home refused.' >&2; exit 1; }
[[ -f "$ARCHIVE" && ! -e "$DEST" && ! -L "$DEST" ]] || { echo 'Archive missing or installation already exists; nothing changed.' >&2; exit 1; }
STAGE="$(mktemp -d /private/tmp/insomnia-local-install.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT
/usr/bin/ditto -x -k "$ARCHIVE" "$STAGE"
APP="$STAGE/Stay Awake.app"
/usr/bin/codesign --verify --strict "-R=$REQUIREMENT" "$APP"
# This exact binary verifies its identifier and Developer ID before any copy.
/usr/sbin/spctl --assess --type execute "$APP"
"$APP/Contents/MacOS/Insomnia" --local-verify-signature >/dev/null
mkdir -p "$HOME/Applications"
/usr/bin/ditto --norsrc --noextattr "$APP" "$DEST"
/usr/bin/codesign --verify --strict "$DEST"
if ! "$DEST/Contents/MacOS/Insomnia" --local-register-power; then
  echo 'The app was copied but registration failed. No session was started. Keep the bundle for diagnosis/recovery; do not delete it blindly.' >&2
  exit 1
fi
echo 'Application copied. Approve the service in System Settings if requested. Perform a short supervised test before closing the lid.'
