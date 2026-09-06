#!/bin/zsh
# Baut OpenBooth, installiert und startet es auf dem iPad (Kabel oder WLAN nach Kopplung).
# Voraussetzungen: Xcode, xcodegen (brew install xcodegen), Local.xcconfig mit eigenem Team,
# Geraete-ID in .device (xcrun devicectl list devices) oder Umgebungsvariable OPENBOOTH_DEVICE.
set -e -o pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
ID=${1:-${OPENBOOTH_DEVICE:-$(cat .device 2>/dev/null)}}
[ -z "$ID" ] && { echo "Keine Geraete-ID: xcrun devicectl list devices, dann ID in .device schreiben"; exit 1; }
[ -f Local.xcconfig ] || { echo "Local.xcconfig fehlt, Vorlage: Local.xcconfig.example"; exit 1; }
xcodegen generate >/dev/null   # immer, damit neue Dateien im Projekt landen
OUT=$(xcodebuild -project OpenBooth.xcodeproj -scheme OpenBooth -destination "id=$ID" -configuration Debug \
  -allowProvisioningUpdates -derivedDataPath build/dd build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)" | sed "s#$PWD/##")
echo "$OUT"
grep -q "BUILD SUCCEEDED" <<< "$OUT" || { echo "Build fehlgeschlagen"; exit 1; }
xcrun devicectl device install app --device "$ID" build/dd/Build/Products/Debug-iphoneos/OpenBooth.app | grep -iE "installed|error"
xcrun devicectl device process launch --device "$ID" de.reingruber.openbooth | tail -1
