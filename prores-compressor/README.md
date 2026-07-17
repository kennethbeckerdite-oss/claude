# ProRes Compressor

A native macOS app (SwiftUI, Apple Silicon) that takes large Apple ProRes masters and exports either:

- **MP4** — H.265/H.264 compressed to a target file size (2–4 GB presets or custom), or
- **DCP** — an unencrypted SMPTE 2K 24 fps Digital Cinema Package for theatrical/festival playback.

Personal-use build: no sandbox, ad-hoc code signing, runs from Xcode.

## Setup

The Xcode project is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
brew install xcodegen        # once
cd prores-compressor
xcodegen generate
open ProResCompressor.xcodeproj
```

Build and run with ⌘R (scheme: ProResCompressor).

> **After pulling changes that add new files under `ProResCompressor/`**, re-run
> `xcodegen generate` — the generated project only lists files that existed at
> generation time ("Cannot find X in scope" on a brand-new view is the tell).
> `TranscodeKit/` files don't need this; Swift packages pick up files automatically.

## Distribution (DMG)

`Scripts/make-dmg.sh` builds a Release app and packages it into a shareable DMG.

- **Personal (default):** ad-hoc signed. Recipients right-click the app → **Open** the first time to clear Gatekeeper's "unidentified developer" prompt.
  ```sh
  ./Scripts/make-dmg.sh
  ```
- **Distribution (notarized):** requires a paid Apple Developer account. Sign with a Developer ID identity and notarize so it opens cleanly on any Mac:
  ```sh
  # one-time: xcrun notarytool store-credentials prc-notary --apple-id … --team-id … --password …
  DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" \
    NOTARY_PROFILE=prc-notary ./Scripts/make-dmg.sh
  ```
  With `DEVELOPER_ID` set the app is signed with the hardened runtime; adding `NOTARY_PROFILE` notarizes and staples the DMG. The app uses no sandbox entitlements or private APIs, so nothing else needs to change to distribute it.

## Engine tests

All engine logic lives in the `TranscodeKit` local Swift package (no UI):

```sh
cd TranscodeKit
swift test
```

Covers bitrate math, DCI framing geometry, Rec.709→XYZ color test vectors, and DCP XML golden files.

## Using the app

1. Drop your film anywhere in the window (works at any time, even mid-export) or click **Choose Film…** — each film becomes a card.
2. On the card, answer one question — *What do you need?*: **Festival upload file** (MP4 under 2 GB), **Cinema package (DCP)**, or **Both**. Everything else has smart defaults; per-film technical controls (codec, target size, container, bitrate, DCNC codes, extra videos in the package, subtitle burn-in, source gamma) live under **Advanced settings**.
3. Hit **Export / Export All** and pick where the exports should go (the app remembers your last choice). Cards run one at a time with live progress; finished cards offer **Show in Finder / Report / Zip for Upload**.

DCP sources must be 24, 25, or 30 fps (23.976/29.97 are conformed with a 0.1% audio resample). DCP encodes are CPU-bound JPEG 2000 — expect roughly 15–25 fps on an M4, i.e. a 90-minute feature takes ~2–4 hours. The app prevents sleep while exporting.

## Validating a DCP

Layered checks, cheapest first:

1. **Built-in** — every DCP export ends with a self-verification pass (asset hashes vs PKL, CPL/PKL/ASSETMAP cross-references, MXF essence re-read). The UI shows "Exported & verified" only if it passes.
2. **clairmeta** (independent SMPTE compliance checker). The PyPI wheel is
   missing its XSD schemas, so install from GitHub:
   ```sh
   python3 -m venv ~/clairmeta-env
   ~/clairmeta-env/bin/pip install git+https://github.com/Ymagis/ClairMeta.git
   ~/clairmeta-env/bin/python -m clairmeta.cli check -type dcp "/path/to/MyFilm_..._DCP"
   ```
   Optional deeper probes: `brew install mediainfo sox`.

   Note on non-APFS drives (exFAT/NTFS): macOS creates hidden `._*`
   AppleDouble files next to anything it writes. The exporter strips them,
   but they reappear whenever Finder copies the DCP — run
   `dot_clean -m "/path/to/DCP"` after copying to an ingest drive.
3. **Playback** — open the DCP folder in the free [DCP-o-matic Player](https://dcpomatic.com/) and check picture, color, and audio mapping.
4. **Real hardware** — before an actual screening, ask the venue/festival for a test ingest on their projection server.

## Repository layout

- `ProResCompressor/` — SwiftUI app (thin UI over the engine).
- `TranscodeKit/` — Swift package with all engine logic:
  - `TranscodeKit` target: probing, MP4 export (AVFoundation/VideoToolbox).
  - `DCPKit` target: DCP pipeline (color transform, JPEG 2000, MXF, packaging, validation).
  - `COpenJPEG` target: vendored [OpenJPEG](https://github.com/uclouvain/openjpeg) (BSD-2) for DCI-profile JPEG 2000.
  - `CASDCP` target: vendored [asdcplib](https://github.com/cinecert/asdcplib) (BSD) for MXF track files, with a small C shim (`asdcp_shim.h`) exposed to Swift.
