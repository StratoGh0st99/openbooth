#!/bin/zsh
# Holt den Faehigkeitsbericht der Kamera vom iPad nach ./logs/capabilities.log
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd "$(dirname "$0")/.." || exit 1
# Geraete-ID: Argument, Umgebung OPENBOOTH_DEVICE oder Datei .device (siehe tools/install.sh)
ID=${1:-${OPENBOOTH_DEVICE:-$(cat .device 2>/dev/null)}}
[ -z "$ID" ] && { echo "Keine Geraete-ID: xcrun devicectl list devices, dann ID in .device schreiben"; exit 1; }
mkdir -p logs; rm -f logs/capabilities.log
xcrun devicectl device copy from --device "$ID" --domain-type appDataContainer --domain-identifier de.reingruber.openbooth --source Documents/openbooth-capabilities.log --destination logs/capabilities.log >/dev/null 2>&1
if [ -s logs/capabilities.log ]; then echo "logs/capabilities.log ($(wc -l < logs/capabilities.log | tr -d ' ') Zeilen)"; else echo "Bericht konnte nicht geholt werden (Kamera schon verbunden?)"; fi
