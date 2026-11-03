#!/bin/bash
# Builds an isolated development app. Does not install, register jobs, run
# sudo, alter energy preferences or bypass Gatekeeper.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CACHE="${INSOMNIA_WORK_DIR:-$ROOT/.local-work}"
OUTPUT="$ROOT/build"
IDENTITY="${INSOMNIA_SIGNING_IDENTITY:--}"
CHANNEL="${INSOMNIA_BUILD_CHANNEL:-distribution}"
case "$CHANNEL" in
  distribution) ARCHIVE_NAME=StayAwake-development.zip ;;
  local-development)
    [[ "$IDENTITY" != - ]] || { echo 'Local privileged builds require an Apple Development identity.' >&2; exit 1; }
    ARCHIVE_NAME=StayAwake-local-source.zip ;;
  *) echo 'Unknown build channel.' >&2; exit 2 ;;
esac
[[ ! -e "$OUTPUT/$ARCHIVE_NAME" ]] || { echo 'Move the previous archive aside before rebuilding.' >&2; exit 1; }
mkdir -p "$CACHE/clang-cache" "$CACHE/module-cache" "$OUTPUT"
export CLANG_MODULE_CACHE_PATH="$CACHE/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CACHE/module-cache"
cd "$ROOT"
FLAGS=(--disable-sandbox --cache-path "$CACHE/package-cache" --config-path "$CACHE/package-config" --security-path "$CACHE/package-security" --scratch-path "$CACHE/local-build")
if [[ "$CHANNEL" == local-development ]]; then
  FLAGS+=(-Xswiftc -DINSOMNIA_LOCAL_DEVELOPMENT)
fi
/usr/bin/swift build "${FLAGS[@]}" -c release
BIN="$(/usr/bin/swift build "${FLAGS[@]}" -c release --show-bin-path)/Insomnia"
# A unique staging directory avoids replacing a running app or half-publishing.
STAGE="$(mktemp -d /private/tmp/insomnia-local-build.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/Stay Awake.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Library/LaunchDaemons"
cp "$BIN" "$APP/Contents/MacOS/Insomnia"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier local.insomnialocal.app' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName Stay Awake' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Stay Awake' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 2' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 0.3.1' "$APP/Contents/Info.plist"
if [[ "$CHANNEL" == local-development ]]; then
  /usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Stay Awake' "$APP/Contents/Info.plist"
fi
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/scripts/local-backstop.sh" "$APP/Contents/Resources/backstop.sh"
chmod 755 "$APP/Contents/Resources/backstop.sh"
cat > "$APP/Contents/Library/LaunchDaemons/local.insomnialocal.power.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>local.insomnialocal.power</string>
<key>BundleProgram</key><string>Contents/MacOS/Insomnia</string>
<key>ProgramArguments</key><array><string>Insomnia</string><string>--power-helper</string></array>
<key>MachServices</key><dict><key>local.insomnialocal.power</key><true/></dict>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><true/>
<key>ProcessType</key><string>Background</string>
<key>ThrottleInterval</key><integer>10</integer>
</dict></plist>
PLIST
/usr/bin/plutil -lint "$APP/Contents/Info.plist" "$APP/Contents/Library/LaunchDaemons/local.insomnialocal.power.plist"
if [[ "$IDENTITY" == - ]]; then
  /usr/bin/codesign --force --sign - "$APP"
  echo 'Development signature only: privileged sessions remain blocked. No jobs have been installed.'
elif [[ "$CHANNEL" == local-development ]]; then
  /usr/bin/codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$APP"
  # Reject the wrong signing channel or unexpected entitlements now. This
  # inspection authorizes no RPC, service registration or power mutation.
  "$APP/Contents/MacOS/Insomnia" --local-verify-build > "$STAGE/local-requirement.txt"
else
  /usr/bin/codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
fi
/usr/bin/codesign --verify --strict "$APP"
# Documents can be managed by iCloud, which adds Finder metadata to .app
# directories after signing. Export an archive of the verified local build;
# no quarantine, Gatekeeper, system setting or user-owned attribute is changed.
/usr/bin/ditto -c -k --keepParent --norsrc --noextattr "$APP" "$OUTPUT/$ARCHIVE_NAME"
VERIFY="$STAGE/verify"
mkdir "$VERIFY"
/usr/bin/ditto -x -k "$OUTPUT/$ARCHIVE_NAME" "$VERIFY"
/usr/bin/codesign --verify --strict "$VERIFY/Stay Awake.app"
/usr/bin/shasum -a 256 "$OUTPUT/$ARCHIVE_NAME" > "$OUTPUT/$ARCHIVE_NAME.sha256"
if [[ "$CHANNEL" == local-development ]]; then
  echo 'Local source build only; not notarized or suitable for binary redistribution.'
  echo 'Create its protected-installation package with scripts/package-local-source.sh.'
fi
echo "$OUTPUT/$ARCHIVE_NAME"
