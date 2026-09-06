# OpenBooth

Open-source photo booth app for the iPad. The camera is connected directly to the iPad via USB-C, no computer in between.

**Simple, basic, functional.** No filters, no frames, no stickers, no subscription. The photo comes out of the camera
exactly as the photographer set it up, as JPEG or RAW, and lands where it belongs: iPad photo library, Immich, WebDAV.
Reduced to the essentials, with a few smart details (idle collage that wakes on motion, the camera’s own shutter is
picked up, QR code to the album, the display regulates itself). Optimized for performance, open source.

Languages: English (primary), German (maintained alongside). Deutsche Fassung: [README.de.md](README.de.md).

Status: **prototype, core works.** As of 2026-09-06: Sony ILCE-7M4 over USB-C on an iPad Air (M4), PTP pass-through
confirmed, Sony handshake, live view, capture, RAW, uploads, remote shutter via camera events, all verified on device.

## Technology

- SwiftUI, iPadOS 17+
- Camera link via `ImageCaptureCore`: iPadOS passes raw PTP commands through to USB cameras
  (`ICCameraDevice.requestSendPTPCommand`). `NSCameraUsageDescription` is required for that.
- Sony protocol (PC Remote) re-implemented after libgphoto2 `camlibs/ptp2` (LGPL):
  handshake `0x9201` phases 1/2, `0x9202`, phase 3, PriorityMode; live view via object `0xFFFFC002`;
  shutter via `0x9207` with `0xD2C1`/`0xD2C2`; image from RAM via `0xFFFFC001` once `0xD215 >= 0x8000`.
- Cameras: Sony ILCE-7M4 first, ILCE-6400 next. Canon later via the EOS PTP extension.
- iPad camera (front or rear) as a fallback when no USB camera is present.

## Building

```bash
brew install xcodegen
cd openbooth
cp Local.xcconfig.example Local.xcconfig   # enter your own team ID
xcodegen generate
open OpenBooth.xcodeproj
```

Signing via `Local.xcconfig` (not in the repo): Apple development team, optionally your own bundle ID. A free
Personal Team is enough; the app then runs for 7 days and must be reinstalled. Straight to the iPad without the Xcode
GUI: `xcrun devicectl list devices`, write the ID to `.device`, then `tools/install.sh`. Fetch the log: `tools/pull-log.sh`.

Localization: strings are English in code, German lives in `Sources/OpenBooth/Localizable.xcstrings` and
`InfoPlist.xcstrings`. Every new UI string gets its German translation in the same change.

## Findings from the first device test

- iPadOS 26 allows `requestSendPTPCommand` to the Sony without special entitlements; the feared
  `ICReturnPTPNotAuthorizedToSendCommand` (-21249) never occurred. `NSCameraUsageDescription` suffices.
- The completion delivers the blocks in the order (data-in, response container, error).
  The response container is a regular 12-byte PTP container, code at offset 6.
- Transaction IDs are assigned by the framework; the value in the sent command is replaced.
- Live view: ~24 fps at ~180 KB via `GetObject 0xFFFFC002`, limited by the camera.
- Photos rejects an ARW as `alternatePhoto` to the JPEG (PHPhotosError 3300); separate assets work.
- Sony vendor events (`0xC201 ObjectAdded`, `0xC203 PropertyChanged`) are passed through to the app.
- In PC Remote mode the Sony appears as `ICCameraDevice` with `ICTransportTypeUSB`.

## Usage

- **Guest mode** (default): full-screen live view, red button, countdown, large review with “One more!”, gallery.
- **Idle collage**: after a configurable time without activity, a changing collage of the evening’s photos; the button stays visible.
- **Admin**: swipe down with two fingers, enter the PIN (default `0000`, change it in Admin). Sidebar with sections
  Event, Camera, Flow, Display & Sounds, Destinations, Phrases, Access, Log.
- **Camera settings** (ISO, aperture, shutter, focus, setting effect, save destination) are set directly in the camera;
  values set in the app are remembered per model and restored on reconnect.
- **RAW**: set image quality to RAW+JPEG or RAW; both objects are fetched from camera RAM (the counter `0xD215` reports
  `0x8001` after the first fetch); the ARW is stored as its own asset in the library and under `Fotos/raw`.
  With “RAW only”, the embedded 1616×1080 preview of the ARW is used for display.
- **Event**: the event name is the Immich album and the WebDAV folder; both are created automatically.
- **Destinations**: app gallery (always, source for review and collage), iPad photo library, Immich, WebDAV, each switchable.
- **Immich upload** (optional): server, API key (keychain) and album; each photo is queued via `POST /api/assets` and then
  added to the album (`PUT /api/albums/{id}/assets`). Offline uploads catch up later, “Test connection” checks key and album.
- **WebDAV upload** (optional): base URL, user, password (keychain). Folder via `MKCOL`, files via `PUT`, own retry queue.
  Tested with Nextcloud (`remote.php/dav/files/USER`).
- **Collage ends on motion**: the live view is downscaled to 32×18 gray, split into 4×4 cells; the strongest cell minus the
  median (global brightness changes) above an adaptive threshold ends the collage. Idle level is logged every 30 s.
- **Camera shutter pickup**: photos taken with the camera’s own shutter or a remote are detected instantly via the Sony event
  `0xC201 ObjectAdded`, stored the same way and shown in review. Polling `0xD215` remains a safety net.
- **Gallery**: full screen, three columns, large view with paging, auto-closes after a configurable idle time;
  800 px thumbnails via ImageIO cached in `.thumbs/`.
- **Sounds** (switchable): welcome chime on wake-up, countdown beeps, shutter signal, all synthesized.
- **Display**: QR page always at full brightness, optionally permanent; the idle collage restores the previous value.
- **Histogram** (RGB and luminance) in live view and review, Admin › Camera.
- **Capability report**: after the handshake the app writes `openbooth-capabilities.log` (operations, events, properties),
  fetch with `tools/pull-caps.sh`.
- **Remote access** (optional, Admin › Access): read-only status page on Wi‑Fi on port 8787 (own HTTP server on
  Network.framework, Bonjour “OpenBooth”): camera, frame rate, photos, destinations, battery, last log lines, motion
  threshold, send diagnostics. PIN login, five failed attempts lock for one minute.
- **Diagnostics**: “Share diagnostics” (share sheet) or “Send to OpenBooth” (HTTPS endpoint); contains environment,
  capabilities with raw data and the log, no credentials, serial number shortened. Optionally automatic on errors.
- Series of 1/3/5 shots with pause, review with progress bar and delete, editable phrases, status banner with automatic
  recovery, log in `Documents/openbooth.log` (fetch with `tools/pull-log.sh`).

## Roadmap

1. Test Sony ILCE-6400 (protocol version 2, settings are set stepwise)
2. Photo printer via AirPrint (plain 10×15), later Canon EOS

## License

MIT for the app’s own code. Protocol knowledge from libgphoto2 (LGPL-2.1), no code copied.
