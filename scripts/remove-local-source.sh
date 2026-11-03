#!/bin/bash
# Removal is recovery-first and never replaces an installed application.
set -euo pipefail
APP='/Library/Application Support/InsomniaSafeLocal/Stay Awake.app'
case "${1:---plan}" in
  --plan)
    printf '%s\n' 'Ask the protected app to quit, restore and unregister its services.' \
      'Only then request macOS administrator authorization to check for a root recovery journal and an unloaded daemon.' \
      'If either remains, removal is refused. Otherwise remove only this local app and its package receipt.' \
      'User settings, logs, credentials and recovery lock are retained. No sudoers or security settings are changed.'
    exit 0 ;;
  --apply) [[ $# == 1 ]] || exit 2 ;;
  *) echo 'usage: scripts/remove-local-source.sh [--plan|--apply]' >&2; exit 2 ;;
esac
[[ -z "${INSOMNIA_HOME:-}" && -d "$APP" && ! -L "$APP" ]] || { echo 'Unexpected home or missing app; nothing removed.' >&2; exit 1; }
# The app checks its exact development signature, Hardened Runtime, sealed
# resources, protected ancestors and root-owned tree before doing any work.
"$APP/Contents/MacOS/Insomnia" --local-verify-signature >/dev/null
"$APP/Contents/MacOS/Insomnia" --local-prepare-uninstall
# The administrator command is fixed, with no caller paths, dynamic shell
# fragments or user-owned executable. Never execute a staged script as root.
/usr/bin/osascript <<'APPLESCRIPT'
set cleanup to "set -eu; result=$(/bin/launchctl print system/local.insomnialocal.power 2>&1) && exit 20; case \"$result\" in *'Could not find service \"local.insomnialocal.power\"'*) ;; *) exit 21 ;; esac; journal='/Library/Application Support/InsomniaLocalPower/power-lease.json'; test ! -e \"$journal\" && test ! -L \"$journal\" || exit 22; dir='/Library/Application Support/InsomniaLocalPower'; test ! -L \"$dir\" || exit 23; if test -e \"$dir\"; then /bin/rmdir \"$dir\"; fi; /bin/rm -rf '/Library/Application Support/InsomniaSafeLocal/Stay Awake.app'; /bin/rmdir '/Library/Application Support/InsomniaSafeLocal'; /usr/sbin/pkgutil --forget local.insomnialocal.source-installer"
do shell script cleanup with administrator privileges
APPLESCRIPT
echo 'Protected local app removed after recovery. User settings and saved hotspot credentials retained.'
