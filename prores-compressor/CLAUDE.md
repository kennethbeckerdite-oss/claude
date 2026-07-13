# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this directory.

## Project Overview

**ProRes Compressor** — a native macOS app (SwiftUI, macOS 14+, Apple Silicon primary) that exports large Apple ProRes masters (50–200+ GB `.mov`) as either:

1. **MP4** — H.265/H.264 at a user-chosen target size (2–4 GB range), via AVFoundation/VideoToolbox hardware encoding.
2. **DCP** — unencrypted SMPTE 2K 24 fps Digital Cinema Package, via vendored OpenJPEG (JPEG 2000) and asdcplib (MXF).

Personal-use build only: App Sandbox off, ad-hoc signing, no distribution packaging.

## Build & Test

The Xcode project is **generated** — never edit `ProResCompressor.xcodeproj` (it is gitignored); edit `project.yml` and regenerate:

```sh
xcodegen generate          # requires: brew install xcodegen
open ProResCompressor.xcodeproj
```

Engine unit tests (pure-logic: bitrate math, framing, color vectors, DCP XML golden files):

```sh
cd TranscodeKit && swift test
```

Note: building requires macOS + Xcode. Remote/Linux Claude sessions can edit sources but cannot compile; flag anything unverified in the commit/PR description.

## Architecture

Strict engine/UI split. The app target (`ProResCompressor/`) is a thin SwiftUI layer over the `TranscodeKit` local Swift package. All export logic goes in the package, never in views.

- `TranscodeKit` target — `SourceProbe` (async AVAsset probing), `Exporter` protocol + shared types, `BitrateCalculator` (pure math), `MP4Exporter` (AVAssetReader → AVAssetWriter).
- `DCPKit` target — the DCP pipeline: `DCPExporter` orchestrates decode → framing (`Framing`) → Rec.709→XYZ transform (`ColorTransform`) → JPEG 2000 (`J2KEncoder` over `COpenJPEG`) → MXF wrap (`MXFWriter` over `CASDCP`) → XML packaging (`DCPPackage`) → self-check (`DCPValidator`). Audio: `AudioConformer` (24-bit/48 kHz, 5.1-padded stereo).
- `COpenJPEG` — vendored OpenJPEG C sources (BSD-2). Do not hand-edit vendored files; record any required patches in `TranscodeKit/VENDORED.md`.
- `CASDCP` — vendored asdcplib C++ sources (BSD) plus `asdcp_shim.cpp/h`, a small extern-C API that is the only surface Swift touches. OpenSSL calls are mapped to CommonCrypto via a compat header (see `VENDORED.md`).

## Domain conventions

- MP4 size targeting: bitrate computed by `BitrateCalculator` with a 0.97 safety factor so output lands under the requested cap; 10-bit sources get HEVC Main10 and source color properties are passed through.
- DCP invariants: 12-bit X'Y'Z' (gamma 2.6, 48 cd/m² reference), DCI Cinema2K profile (≤250 Mbps), 6-channel 5.1-padded 24-bit/48 kHz audio, SMPTE ST 429 XML. Only 24.0/23.976 fps sources are accepted (23.976 conformed to 24 with 0.1% audio resample).
- Every DCP export must end with the `DCPValidator` self-check; never report success without it.
