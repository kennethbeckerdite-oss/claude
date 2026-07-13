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

## Engine tests

All engine logic lives in the `TranscodeKit` local Swift package (no UI):

```sh
cd TranscodeKit
swift test
```

Covers bitrate math, DCI framing geometry, Rec.709→XYZ color test vectors, and DCP XML golden files.

## Using the app

1. Drag a ProRes `.mov` onto the window (or click **Choose File…**).
2. Pick **MP4** or **DCP**:
   - MP4: choose target size (2/3/4 GB or custom) and codec (HEVC default).
   - DCP: choose Flat (1998×1080) or Scope (2048×858) and J2K bitrate (default 125 Mbps).
3. Export. Output lands next to the source file.

DCP sources must be 24.0 or 23.976 fps (23.976 is conformed to 24 with a 0.1% audio resample). DCP encodes are CPU-bound JPEG 2000 — expect roughly 15–25 fps on an M4, i.e. a 90-minute feature takes ~2–4 hours. The app prevents sleep while exporting.

## Validating a DCP

Layered checks, cheapest first:

1. **Built-in** — every DCP export ends with a self-verification pass (asset hashes vs PKL, CPL/PKL/ASSETMAP cross-references, MXF essence re-read). The UI shows "Exported & verified" only if it passes.
2. **clairmeta** (independent SMPTE compliance checker):
   ```sh
   pipx install clairmeta   # or: pip install clairmeta
   python -m clairmeta.cli check -type dcp "/path/to/MyFilm_..._DCP"
   ```
3. **Playback** — open the DCP folder in the free [DCP-o-matic Player](https://dcpomatic.com/) and check picture, color, and audio mapping.
4. **Real hardware** — before an actual screening, ask the venue/festival for a test ingest on their projection server.

## Repository layout

- `ProResCompressor/` — SwiftUI app (thin UI over the engine).
- `TranscodeKit/` — Swift package with all engine logic:
  - `TranscodeKit` target: probing, MP4 export (AVFoundation/VideoToolbox).
  - `DCPKit` target: DCP pipeline (color transform, JPEG 2000, MXF, packaging, validation).
  - `COpenJPEG` target: vendored [OpenJPEG](https://github.com/uclouvain/openjpeg) (BSD-2) for DCI-profile JPEG 2000.
  - `CASDCP` target: vendored [asdcplib](https://github.com/cinecert/asdcplib) (BSD) for MXF track files, with a small C shim (`asdcp_shim.h`) exposed to Swift.
