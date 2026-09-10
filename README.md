# OpenBooth

A simple, open-source photo booth for the iPad. Connect a camera via USB-C, take a photo and save it locally or to your server. No filters, frames or subscription.

Live view, countdown, photo review and gallery. Optional photo series, idle slideshow and a QR code to an Immich album.

**Status: prototype.** Tested with Sony ILCE-7M4 and Canon EOS R100 on an iPad Air (M4). Canon still needs endurance testing. Other camera models are not yet verified. The iPad’s own camera is available as a fallback.

## Install

Requires a Mac with Xcode, XcodeGen and an iPad with iPadOS 17 or later. USB camera tests have been performed on iPadOS 26.

```bash
brew install xcodegen
git clone https://github.com/StratoGh0st99/openbooth.git
cd openbooth
cp Local.xcconfig.example Local.xcconfig
```

Enter your Apple development team ID in `Local.xcconfig`, then generate and open the project:

```bash
xcodegen generate
open OpenBooth.xcodeproj
```

Select your connected iPad in Xcode and run the app.

For subsequent builds, save the device ID from `xcrun devicectl list devices` in `.device` and run `tools/install.sh` to build, install and launch. The script uses the default bundle ID; use Xcode if you customize it.

## Set up and use

The defaults work out of the box: photos go to the app gallery and the iPad photo library, and the iPad's own camera is used until a USB camera is connected. Optional steps in Admin:

1. Connect a Sony (in **PC Remote** mode) or Canon EOS via USB-C.
2. Create or select an event under **Event**. The page lists anything that still needs attention, such as a missing photo-library permission or an untested server.
3. Under **Destinations**, add Immich or WebDAV and test the connection.

Guests press **Take a photo**, wait for the countdown and see the result. They can take another photo or browse the gallery.

Live view of USB cameras is paced to 30 fps; the log reports the measured rate and the per-frame timing.

To reopen Admin, swipe down with two fingers and enter the PIN. The default is `0000`; change it under **Access**. Countdown and photo series are under **Flow**, camera controls under **Camera**.

## Save photos

- **App gallery:** always keeps a display copy, normally up to 2000 px, under `Documents/Fotos/<event>/`.
- **iPad photo library:** saves originals or display copies.
- **Immich:** enter server URL and API key. The event name becomes the album name. The optional guest QR code links to a public album.
- **WebDAV:** enter base URL, username and password. The event name becomes a subfolder. For Nextcloud: `https://your-server/remote.php/dav/files/your-user`.

RAW files also go to enabled destinations, even when display copies are selected.

Failed uploads remain queued for retry. New entries keep their destination across event changes. Finish pending uploads before switching events after an upgrade: older WebDAV entries use the current destination.

**Originals in the app are temporary.** Cleanup removes JPEG originals and RAW files older than two minutes when no upload queue needs them. Photo-library failures do not prevent cleanup; verify your saved originals.

## Troubleshooting and reset

Check **Event** for open issues and **Destinations** for upload status. For camera problems, check power, USB cable and camera mode. The app attempts to reconnect automatically. Diagnostics are under **Admin → Log**.

**Remove from gallery** removes only the local gallery copy. Copies already saved elsewhere remain.

**Admin → Access → Reset OpenBooth…** clears settings, credentials, local event photos, queues and logs. Copies in the iPad photo library, Immich and WebDAV remain. iPadOS permissions are managed separately in Settings.

## Development and license

SwiftUI with ImageCaptureCore for USB cameras. Driver and protocol details are in `Sources/OpenBooth/`. Use `tools/pull-log.sh` and `tools/pull-caps.sh` to retrieve diagnostics.

[MIT](LICENSE) for the app’s code. Protocol knowledge from libgphoto2 (LGPL-2.1); no code copied.
