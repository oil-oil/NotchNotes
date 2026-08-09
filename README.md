# NotchNotes

![NotchNotes preview](docs/assets/readme-hero.png)

NotchNotes is a small native macOS app that lives at the top edge of your MacBook screen. Open it by hovering or clicking the notch area to use a Markdown notebook, park files for quick access, or keep your Mac awake.

## Download

- [Download the latest release](https://github.com/oil-oil/NotchNotes/releases/latest)
- [Open the homepage](https://oil-oil.github.io/NotchNotes/)

After downloading, unzip the app, move it to Applications, then right-click and choose Open on the first launch.

## Stack

- Swift + AppKit for the floating panels, window levels, screen targeting, and cursor-triggered behavior.
- SwiftUI for the notebook interface.
- UserDefaults for lightweight local note storage.
- MarkdownEngine for live Markdown editing and embedded images.

## Run

```bash
swift run NotchNotes
```

After launch, hover or click the top-center notch area. Drag files into the shelf to copy them, or hold Command while dragging to cut them.

## Package

```bash
./Scripts/package-app.sh
open NotchNotes.app
```

## Distribution

The current downloadable ZIP is intended for testing. For public distribution outside the Mac App Store, sign the app with a Developer ID Application certificate and submit it for Apple notarization.
