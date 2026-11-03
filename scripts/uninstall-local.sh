#!/bin/bash
# Never deletes recovery evidence until the signed app confirms restoration.
set -euo pipefail
DEST="$HOME/Applications/Stay Awake.app"
SUPPORT="$HOME/Library/Application Support/InsomniaLocal"
PLIST="$HOME/Library/LaunchAgents/local.insomnialocal.recovery.plist"
case "${1:---plan}" in
  --plan)
    printf '%s\n' 'Plan: ask Stay Awake to quit and restore; verify root and user journals are clean; unload login, recovery and power services; then remove the local app and exact runtime files.' 'Settings, logs and hotspot credentials are retained. If recovery fails, nothing is deleted.'
    exit 0 ;;
  --apply) [[ $# == 1 ]] || exit 2 ;;
  *) echo 'usage: scripts/uninstall-local.sh [--plan|--apply]' >&2; exit 2 ;;
esac
TEAM="${INSOMNIA_EXPECTED_TEAM_ID:-}"
[[ "$TEAM" =~ ^[A-Z0-9]{10}$ ]] || { echo 'Set INSOMNIA_EXPECTED_TEAM_ID to the Apple Developer team that signed your reviewed build. Nothing changed.' >&2; exit 1; }
REQUIREMENT="anchor apple generic and identifier \"local.insomnialocal.app\" and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"$TEAM\""
[[ -z "${INSOMNIA_HOME:-}" ]] || { echo 'Relocated home refused.' >&2; exit 1; }
[[ -d "$DEST" && ! -L "$DEST" && ! -L "$SUPPORT" && ! -L "$PLIST" ]] || { echo 'App missing or unexpected symlink; nothing removed.' >&2; exit 1; }
/usr/bin/codesign --verify --strict "-R=$REQUIREMENT" "$DEST"
"$DEST/Contents/MacOS/Insomnia" --local-verify-signature >/dev/null
"$DEST/Contents/MacOS/Insomnia" --local-prepare-uninstall
# The recovery lock is not unlinked: a process already waiting on its inode
# must never acquire a different lock. Saved preferences and logs stay local.
for name in session.json state.json unfinished-command.json; do
  FILE="$SUPPORT/$name"
  if [[ -e "$FILE" ]]; then
    [[ -f "$FILE" && ! -L "$FILE" ]] || { echo 'Unexpected runtime file; nothing further removed.' >&2; exit 1; }
    /bin/rm "$FILE"
  fi
done
[[ ! -e "$PLIST" ]] || /bin/rm "$PLIST"
/bin/rm -rf "$DEST"
echo 'Application and services removed after verified recovery. Settings, logs and saved hotspot credential retained.'
