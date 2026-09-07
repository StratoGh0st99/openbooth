#!/bin/zsh
# Fetches the camera capability report from the iPad to ./logs/capabilities.log
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd "$(dirname "$0")/.." || exit 1
# Device ID: argument, environment OPENBOOTH_DEVICE or file .device (see tools/install.sh)
ID=${1:-${OPENBOOTH_DEVICE:-$(cat .device 2>/dev/null)}}
[ -z "$ID" ] && { echo "No device ID: run xcrun devicectl list devices, then write the ID to .device"; exit 1; }
mkdir -p logs; rm -f logs/capabilities.log
xcrun devicectl device copy from --device "$ID" --domain-type appDataContainer --domain-identifier de.reingruber.openbooth --source Documents/openbooth-capabilities.log --destination logs/capabilities.log >/dev/null 2>&1
if [ -s logs/capabilities.log ]; then echo "logs/capabilities.log ($(wc -l < logs/capabilities.log | tr -d ' ') lines)"; else echo "Could not fetch the report (is the camera connected yet?)"; fi
