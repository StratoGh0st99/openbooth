# OpenBooth (Deutsch)

Englische Hauptfassung: [README.md](README.md). Diese deutsche Fassung wird mitgepflegt.

Offene Fotobox-App für das iPad. Die Kamera hängt direkt per USB-C am iPad, kein Rechner dazwischen.

**Einfach, basic, funktional.** Keine Filter, keine Rahmen, keine Sticker, kein Abo. Das Foto kommt so aus der Kamera,
wie der Fotograf sie eingestellt hat, als JPEG oder RAW, und landet dort, wo es hin soll: iPad-Mediathek, Immich, WebDAV.
Reduziert auf das Nötigste, mit ein paar schlauen Details (Leerlauf-Collage, die bei Bewegung aufwacht, Fernauslöser
wird mitgenommen, QR-Code zum Album, Display regelt sich selbst). Auf Performance optimiert, quelloffen.

Status: **Prototyp, Kern funktioniert.** Stand 2026-09-05: Sony ILCE-7M4 per USB-C am iPad Air (M4) erkannt,
PTP-Durchreichen bestätigt, Sony-Handshake und Liveview laufen. Auslösen und Bildabruf implementiert, im Test.

## Technik

- SwiftUI, iPadOS 17+
- Kamera-Anbindung über `ImageCaptureCore`: iPadOS reicht rohe PTP-Kommandos an USB-Kameras durch
  (`ICCameraDevice.requestSendPTPCommand`). Dafür ist `NSCameraUsageDescription` Pflicht.
- Sony-Protokoll (PC-Fernbedienung) nachimplementiert nach libgphoto2 `camlibs/ptp2` (LGPL):
  Handshake `0x9201` Phase 1/2, `0x9202`, Phase 3, PriorityMode; Liveview über Objekt `0xFFFFC002`;
  Auslösen über `0x9207` mit `0xD2C1`/`0xD2C2`; Bild aus dem RAM über `0xFFFFC001`, sobald `0xD215 >= 0x8000`.
- Kameras: zuerst Sony ILCE-7M4, am Event vermutlich ILCE-6400. Canon später über die EOS-PTP-Erweiterung.

## Bauen

```bash
brew install xcodegen
cd openbooth
cp Local.xcconfig.example Local.xcconfig   # eigene Team-ID eintragen
xcodegen generate
open OpenBooth.xcodeproj
```

Signing über `Local.xcconfig` (nicht im Repo): Apple-Development-Team, optional eigene Bundle-ID. Ein kostenloses
Personal Team reicht, die App läuft dann 7 Tage und muss neu installiert werden. Direkt aufs iPad ohne Xcode-GUI:
`xcrun devicectl list devices`, ID in `.device` schreiben, dann `tools/install.sh`. Log holen: `tools/pull-log.sh`.

## Erkenntnisse aus dem ersten Gerätetest

- iPadOS 26 erlaubt `requestSendPTPCommand` an die Sony ohne Sonderrechte, der gefürchtete Fehler
  `ICReturnPTPNotAuthorizedToSendCommand` (-21249) trat nicht auf. `NSCameraUsageDescription` genügt.
- Die Completion liefert die Blöcke in der Reihenfolge (Data-In, Response-Container, Error).
  Der Response-Container ist ein normaler 12-Byte-PTP-Container, Code an Offset 6.
- Transaction-IDs vergibt das Framework selbst, der Wert im gesendeten Command wird ersetzt.
- Liveview: ~15 Bilder/s à ~180 KB über `GetObject 0xFFFFC002`, begrenzt durch die Kamera.
- Photos lehnt ein ARW als `alternatePhoto` zum JPEG ab (PHPhotosError 3300); getrennte Einträge funktionieren.
- Die Sony meldet sich im PC-Remote-Modus als `ICCameraDevice` mit `ICTransportTypeUSB`.

## Bedienung

- **Gästemodus** (Standard): Vollbild-Liveview, roter Knopf, Countdown, große Vorschau mit „Noch ein Foto!", Galerie.
- **Leerlauf-Collage**: nach einstellbarer Zeit ohne Aktion wechselnde Collage aus den Fotos des Abends, der Knopf bleibt sichtbar.
- **Admin**: mit zwei Fingern von oben nach unten wischen, PIN eingeben (Standard `0000`, im Admin ändern). Dort Kameraeinstellungen
  (ISO, Blende, Verschluss, Fokus, Einstellungseffekt, Speicherziel), Countdown, Vorschau- und Leerlaufzeiten, Texte,
  Spiegelung, Galerie für Gäste, Debug-Modus.
- **Debug-Modus**: Seitenleiste mit Kamera-Schritten und PTP-Log bleibt dauerhaft sichtbar.
- Kamera wird automatisch verbunden, Liveview wird bei Aussetzern neu gestartet, das iPad bleibt wach.
- **RAW**: Bildqualität in den Kameraeinstellungen auf RAW+JPEG oder RAW stellen; beide Objekte werden aus dem Kamera-RAM
  geholt (der Zähler `0xD215` meldet nach dem ersten Abruf `0x8001`), das ARW landet als eigener Eintrag in der
  Mediathek und unter `Fotos/raw`. Bei „nur RAW" dient die eingebettete 1616×1080-Vorschau der ARW als Anzeige.
- **Immich-Upload** (optional): Server, API-Key (Schlüsselbund) und Album im Admin, jedes Foto geht per
  `POST /api/assets` in die Warteschlange und danach ins Album (`PUT /api/albums/{id}/assets`). Ohne Netz wird
  nachgeholt, „Verbindung testen" prüft Key und Album. RAW optional mit.
- **Veranstaltung**: der Eventname im Admin ist Immich-Album und WebDAV-Ordner zugleich, beides wird automatisch angelegt.
- **Speicherorte** im Admin: App-Galerie (immer, Quelle für Rückschau und Collage), iPad-Mediathek, Immich und WebDAV einzeln schaltbar.
- **WebDAV-Upload** (optional): Ordner-URL, Benutzer, Passwort (Schlüsselbund). Ordner wird per `MKCOL` angelegt, Dateien per `PUT`,
  eigene Warteschlange mit Wiederholung. Getestet mit Nextcloud (`remote.php/dav/files/NAME/Ordner`).
- **Collage endet bei Bewegung**: Liveview wird im Leerlauf auf 32×18 Graustufen verkleinert, die mittlere Änderung zum Vorbild
  über einer adaptiven Schwelle (Admin: Empfindlichkeit, aktueller Wert wird angezeigt) beendet die Collage.
- **Fremdauslösung**: Bilder vom Auslöser an der Kamera oder per Fernauslöser werden sofort über das Sony-Event
  `0xC201 ObjectAdded` erkannt (iPadOS reicht PTP-Events durch), genauso übernommen und in der Rückschau gezeigt.
  Polling auf `0xD215` bleibt als Sicherheitsnetz (alle 30 s, ohne Events alle 2 s). Speicherziel muss auf Übertragung an die App stehen.
- **Galerie** im Vollbild mit drei Spalten, Großansicht mit Durchwischen (ScrollView mit Seiten-Einrasten, TabView rastete
  nicht sauber), schließt nach einstellbarer Zeit ohne Berührung; Vorschauen 800 px per ImageIO in `.thumbs/` gecacht.
- **Töne** (schaltbar): Willkommensklang beim Aufwachen, Countdown-Piepen, Auslösesignal, alles synthetisiert.
- **Display**: QR-Seite immer voll hell, optional dauerhaft; die Leerlauf-Collage stellt den vorherigen Wert wieder her.
- **Fähigkeitsbericht**: nach dem Handshake schreibt die App `openbooth-capabilities.log` (Operationen, Events, Properties),
  holen mit `tools/pull-caps.sh`.
- **Fernzugriff** (optional, Admin › Zugang): Statusseite im WLAN auf Port 8787 (eigener HTTP-Server auf Network.framework,
  Bonjour „OpenBooth“), nur lesend: Kamera, Bildrate, Fotos, Speicherziele, letzte Protokollzeilen, Diagnose senden.
  Login mit der Admin-PIN, nach fünf Fehlversuchen eine Minute Sperre.
- **Diagnose**: „Diagnose teilen“ (Teilen-Menü) oder „An OpenBooth senden“ (HTTPS-Endpunkt); enthält Umgebung, Fähigkeiten
  mit Rohdaten und Protokoll, keine Zugangsdaten, Seriennummer gekürzt. Optional automatisch bei Fehlern.
- Bilderserie 1/3/5 mit Pause, Rückschau mit Restzeitbalken und Löschen, editierbare Sprüche, Statusbanner mit
  automatischer Wiederherstellung, Log in `Documents/openbooth.log` (holen mit `tools/pull-log.sh`).

## Fahrplan

1. Sony ILCE-6400 (Protokoll Version 2) testen, dort werden Einstellungen schrittweise gesetzt
2. QR-Code auf den Immich-Freigabelink des Albums, später Canon EOS

## Lizenz

MIT für den eigenen Code. Protokollwissen aus libgphoto2 (LGPL-2.1), keine Codeübernahme.
