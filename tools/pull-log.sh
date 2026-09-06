#!/bin/zsh
# Holt das App-Log vom iPad (per Kabel oder WLAN) nach ./logs/openbooth.log
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd "$(dirname "$0")/.." || exit 1
# Geraete-ID: Argument, Umgebung OPENBOOTH_DEVICE oder Datei .device (siehe tools/install.sh)
ID=${1:-${OPENBOOTH_DEVICE:-$(cat .device 2>/dev/null)}}
[ -z "$ID" ] && { echo "Keine Geraete-ID: xcrun devicectl list devices, dann ID in .device schreiben"; exit 1; }
mkdir -p logs; rm -f logs/openbooth.export.log
xcrun devicectl device copy from --device "$ID" --domain-type appDataContainer --domain-identifier de.reingruber.openbooth --source Documents/openbooth.export.log --destination logs/openbooth.export.log >/dev/null 2>&1
if [ -s logs/openbooth.export.log ]; then mv -f logs/openbooth.export.log logs/openbooth.log; echo "logs/openbooth.log ($(wc -l < logs/openbooth.log | tr -d ' ') Zeilen)"; tail -n ${2:-40} logs/openbooth.log
else echo "Log konnte nicht geholt werden (App laeuft? iPad erreichbar?)"; fi
