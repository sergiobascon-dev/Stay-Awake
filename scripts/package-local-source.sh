#!/bin/bash
# Create a local, unsigned Installer package containing only a reviewed app.
# No installation, scripts, job registration or power changes occur here.
set -euo pipefail
umask 022
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARCHIVE="$ROOT/build/StayAwake-local-source.zip"
case "${1:---fresh}" in
  --fresh) PACKAGE_MODE=fresh; OUTPUT="$ROOT/build/StayAwake-local-source.pkg" ;;
  --update) PACKAGE_MODE=update; OUTPUT="$ROOT/build/StayAwake-local-update.pkg" ;;
  *) echo 'usage: scripts/package-local-source.sh [--fresh|--update]' >&2; exit 2 ;;
esac
[[ -f "$ARCHIVE" && ! -e "$OUTPUT" ]] || { echo 'Missing local-source archive or package already exists.' >&2; exit 1; }
STAGE="$(mktemp -d /private/tmp/insomnia-source-package.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT
PAYLOAD="$STAGE/payload"
PARENT="$PAYLOAD"
mkdir -p "$PARENT"
/usr/bin/ditto -x -k "$ARCHIVE" "$PARENT"
APP="$PARENT/Stay Awake.app"
/usr/bin/codesign --verify --strict "$APP"
"$APP/Contents/MacOS/Insomnia" --local-verify-build > "$STAGE/requirement.txt"
REQUIREMENT="$(/bin/cat "$STAGE/requirement.txt")"
[[ "$REQUIREMENT" == *'and cdhash H"'* && "$REQUIREMENT" == *'certificate leaf[field.1.2.840.113635.100.6.1.12] exists'* ]] || { echo 'Not an exact-build local-development archive.' >&2; exit 1; }
/usr/bin/codesign --verify --strict "-R=$REQUIREMENT" "$APP"
# The package copies root-owned 755 directories / 644 resources / 755 binaries.
# No symlinks, hard links, nested apps or executable installer scripts.
/usr/bin/pkgbuild --analyze --root "$PAYLOAD" "$STAGE/components.plist"
/usr/bin/python3 - "$STAGE/components.plist" <<'PY'
import plistlib, sys
p = sys.argv[1]
with open(p, 'rb') as f: items = plistlib.load(f)
expected = 'Stay Awake.app'
assert len(items) == 1 and items[0]['RootRelativeBundlePath'] == expected
items[0]['BundleIsRelocatable'] = False
items[0]['BundleHasStrictIdentifier'] = True
with open(p, 'wb') as f: plistlib.dump(items, f)
PY
PKG="$STAGE/component.pkg"
/usr/bin/pkgbuild --root "$PAYLOAD" --component-plist "$STAGE/components.plist" \
  --identifier local.insomnialocal.source-installer --version 0.3.1 \
  --install-location '/Library/Application Support/InsomniaSafeLocal' --ownership recommended "$PKG"
/usr/bin/python3 - "$ROOT" "$STAGE" "$PACKAGE_MODE" <<'PY'
from pathlib import Path
import sys
root, stage = map(Path, sys.argv[1:3])
mode = sys.argv[3]
preflight = (root / 'scripts/package-resources/preflight.js').read_text()
assert ']]>' not in preflight
distribution = '''<?xml version="1.0" encoding="UTF-8"?>
<installer-gui-script minSpecVersion="2">
  <title>Stay Awake — compilación local</title>
  <options customize="never" allow-external-scripts="false" hostArchitectures="arm64"/>
  <domains enable_anywhere="false" enable_currentUserHome="false" enable_localSystem="true"/>
  <welcome file="welcome.html" mime-type="text/html"/>
  <conclusion file="conclusion.html" mime-type="text/html"/>
  <installation-check script="freshInstall()"/>
  <volume-check script="true"><allowed-os-versions><os-version min="26.0"/></allowed-os-versions></volume-check>
  <script><![CDATA[''' + preflight + ''']]></script>
  <choices-outline><line choice="app"/></choices-outline>
  <choice id="app" visible="false"><pkg-ref id="local.insomnialocal.source-installer"/></choice>
  <pkg-ref id="local.insomnialocal.source-installer"><must-close><app id="local.insomnialocal.app"/></must-close></pkg-ref>
  <pkg-ref id="local.insomnialocal.source-installer" version="0.3.1">component.pkg</pkg-ref>
</installer-gui-script>'''
if mode == 'update':
    distribution = distribution.replace('script="freshInstall()"', 'script="preparedUpdate()"')
    distribution = distribution.replace('— compilación local', '— actualización local')
(stage / 'Distribution').write_text(distribution)
(stage / 'resources').mkdir()
(stage / 'resources/welcome.html').write_text('''<!doctype html><meta charset="utf-8">
<h2>Stay Awake</h2><p>Compilación del código fuente realizada en este Mac.
Aplicación de barra de menús para sesiones temporales o permanentes.</p>
<p>Se copiará únicamente la aplicación en una carpeta protegida del sistema.
Este paquete local no está notarizado para distribución a terceros.</p>
<p>No se inicia ninguna sesión ni se cambia energía, red, SIP, Gatekeeper o sudoers.
La activación del servicio será un paso independiente desde la aplicación.</p>
<p>Versión experimental: las pruebas completas con tapa cerrada, hotspot y
restauración real todavía requieren una sesión supervisada.</p>''')
(stage / 'resources/conclusion.html').write_text('''<!doctype html><meta charset="utf-8">
<h2>Aplicación copiada</h2><p>Abre Stay Awake.app en:</p>
<p>/Library/Application Support/InsomniaSafeLocal/</p>
<p>En sus ajustes, pulsa «Configurar servicio» y completa la autorización de macOS.
Después pulsa «Comprobar». No cierres la tapa hasta que indique «Disponible»
y se haya realizado una sesión breve supervisada.</p>''')
PY
PRODUCT="$STAGE/StayAwake-local-source.pkg"
/usr/bin/productbuild --distribution "$STAGE/Distribution" --package-path "$STAGE" \
  --resources "$STAGE/resources" "$PRODUCT"
/usr/sbin/pkgutil --expand-full "$PRODUCT" "$STAGE/expanded"
/usr/bin/python3 - "$STAGE/expanded" "$PACKAGE_MODE" <<'PY'
from pathlib import Path
import sys, subprocess, stat, xml.etree.ElementTree as ET
root = Path(sys.argv[1])
infos = list(root.rglob('PackageInfo'))
assert len(infos) == 1
info = ET.parse(infos[0]).getroot()
assert info.attrib['install-location'] == '/Library/Application Support/InsomniaSafeLocal'
assert info.find('scripts') is None
assert not list(root.rglob('preinstall')) and not list(root.rglob('postinstall'))
dist = ET.parse(root / 'Distribution').getroot()
assert dist.find('options').attrib['allow-external-scripts'] == 'false'
expected_check = 'preparedUpdate()' if sys.argv[2] == 'update' else 'freshInstall()'
assert dist.find('installation-check').attrib['script'] == expected_check
assert dist.find("pkg-ref/must-close/app").attrib['id'] == 'local.insomnialocal.app'
for bom in root.rglob('Bom'):
    records = subprocess.check_output(['/usr/bin/lsbom', '-p', 'fmug', str(bom)], text=True)
    for row in records.splitlines():
        name, mode, uid, gid = row.split('\t')
        mode = int(mode, 8)
        assert uid == gid == '0', row
        assert not mode & 0o6022, row
        assert stat.S_ISDIR(mode) or stat.S_ISREG(mode), row
        assert name == '.' or name.startswith('./Stay Awake.app') or name == './._Stay Awake.app', row
PY
COPIED="$STAGE/expanded/component.pkg/Payload/Stay Awake.app"
/usr/bin/codesign --verify --strict "$COPIED"
"$COPIED/Contents/MacOS/Insomnia" --local-verify-build > "$STAGE/copied-requirement.txt"
/usr/bin/cmp "$STAGE/requirement.txt" "$STAGE/copied-requirement.txt"
(set -C; /bin/cat "$PRODUCT" > "$OUTPUT")
/usr/bin/shasum -a 256 "$OUTPUT" > "$OUTPUT.sha256"
echo 'Local unsigned package built. It installs files only; it does not register or start the power service.'
echo "$OUTPUT"
