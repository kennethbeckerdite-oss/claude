# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this directory.

## Project Overview

**ProRes Compressor** — a native macOS app (SwiftUI, macOS 14+, Apple Silicon primary) that exports large Apple ProRes masters (50–200+ GB `.mov`) as either:

1. **MP4** — H.265/H.264 via AVFoundation/VideoToolbox hardware encoding, with two modes: target file size (2–4 GB presets/custom) or the "Small & HQ" preset (H.264 High 6 Mb/s, ≤1080p, ported from Kenneth's HandBrake preset).
2. **DCP** — unencrypted SMPTE 2K 24 fps Digital Cinema Package, via vendored OpenJPEG (JPEG 2000) and asdcplib (MXF), with editable DCNC naming.

Personal-use build: App Sandbox off, ad-hoc signing.

## Status (v1 verified on real footage, July 2026)

- MP4 path: confirmed working — 23 GB ProRes master → 1.9 GB MP4.
- DCP path: full export verified — plays in DCP-o-matic Player; clairmeta structural/hash checks pass (its schema-validation errors were a clairmeta packaging bug — PyPI wheel ships without XSDs; install from GitHub, see README).
- Anamorphic/PAR sources handled via track `naturalSize`; rotation metadata passes through on MP4 and is rejected for DCP.
- Exporter strips macOS `._*` AppleDouble files on non-APFS volumes; users must `dot_clean -m` after Finder-copying a DCP to another non-APFS drive.

## TODO / next steps (festival-readiness roadmap, approved by Kenneth)

Priority batch (roughly a session's worth):
- [ ] **"Festival Short" MP4 preset**: hard cap ~1.9 GB (festivals ask "2 GB or under"; leave upload headroom), H.264 for screener compatibility. Reuses target-size rate control + preset row.
- [ ] **True 5.1 DCP audio passthrough**: 6-channel sources currently get downmixed to stereo + silence padding — a paid 5.1 mix is lost silently. Detect ≥6ch and map L R C LFE Ls Rs through `AudioConformer`.
- [ ] **QC report per export**: text file next to output — duration, specs, audio peaks, checksums, validator results. Data already exists in probe/validator.

Next:
- [ ] **25/30 fps DCP support**: SMPTE allows 24/25/30; app currently rejects non-24. Edit rate is already parameterized through MXF/CPL — relax the gate, adjust audio samples-per-frame (48000/25=1920, 48000/30=1600) and bitrate caps per rate.
- [ ] **Multi-reel DCP** (Kenneth's back-to-back request): several videos in ONE composition — CPL with N reels, each reel its own picture/sound MXF pair; servers play them seamlessly. UI = ordered file list. CPL generator already emits a reel list with one entry.
- [ ] **Batch queue** (HandBrake-style): multiple files/settings; the key pairing is MP4 screener + DCP from the same master in one run.
- [ ] **Loudness measurement** (LUFS now, Leq(m) later): warn, don't auto-correct — catches web-hot mixes before a theater screening.
- [ ] **Burned-in subtitles from SRT** (MP4 first; DCP timed-text is a much bigger lift).
- [ ] **Package-for-upload**: zip the DCP folder (single archive, AppleDouble-free) for festivals taking uploads.
- [ ] **DMG distribution**: `make-dmg` script that builds Release, signs, and packages a shareable DMG. Free tier = ad-hoc signing (right-click → Open); proper tier = Developer ID cert ($99/yr) + `notarytool` + staple. No code changes needed — no sandbox or private APIs in use.
- [ ] Software x264-quality option if hardware H.264 at 6 Mb/s underperforms the HandBrake original.
- [ ] 4K DCP, encrypted (KDM) DCPs — deliberately deferred.
- [ ] Real cinema-server ingest test before any actual screening.

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

Note: building requires macOS + Xcode. Remote/Linux Claude sessions can edit sources but cannot compile; flag anything unverified in the commit/PR description. Kenneth builds locally and pastes back errors.

## Architecture

Strict engine/UI split. The app target (`ProResCompressor/`) is a thin SwiftUI layer over the `TranscodeKit` local Swift package. All export logic goes in the package, never in views.

- `TranscodeKit` target — `SourceProbe` (async AVAsset probing incl. naturalSize/transform), `Exporter` protocol + shared types (`RenderSize` fitting), `BitrateCalculator` (pure math), `MP4Exporter` (AVAssetReader → AVAssetWriter).
- `DCPKit` target — the DCP pipeline: `DCPExporter` orchestrates decode → framing (`Framing`) → Rec.709→XYZ transform (`ColorTransform`) → JPEG 2000 (`J2KEncoder` over `COpenJPEG`, frame-parallel) → MXF wrap (`MXFWriter` over `CASDCP`) → XML packaging (`DCPPackage` + `DCNCOptions`) → self-check (`DCPValidator`). Audio: `AudioConformer` (24-bit/48 kHz, 5.1-padded stereo, 23.976→24 pull-up).
- `COpenJPEG` — vendored OpenJPEG C sources (BSD-2). Do not hand-edit vendored files; record any required patches in `TranscodeKit/VENDORED.md`.
- `CASDCP` — vendored asdcplib C++ sources (BSD, WITHOUT_SSL config — no OpenSSL) plus `asdcp_shim.cpp/h`, a small extern-C API that is the only surface Swift touches. See `VENDORED.md`.

## Domain conventions

- MP4 size targeting: bitrate computed by `BitrateCalculator` with a 0.97 safety factor so output lands under the requested cap; 10-bit sources get HEVC Main10 and source color properties are passed through. Output dimensions always derive from `naturalSize` (PAR-corrected), never coded dimensions.
- DCP invariants: 12-bit X'Y'Z' (gamma 2.6, 48 cd/m² reference), DCI Cinema2K profile (≤250 Mbps), 6-channel 5.1-padded 24-bit/48 kHz audio, SMPTE ST 429 XML. Only 24.0/23.976 fps sources are accepted (23.976 conformed to 24 with 0.1% audio resample). CPL `ContentTitleText` carries the full DCNC name; the human title goes in `AnnotationText`.
- Every DCP export must end with the `DCPValidator` self-check; never report success without it.

## DCNC package naming (what the folder name means)

DCP folder names follow the ISDCF Digital Cinema Naming Convention — one underscore-separated string that projectionists and festival techs read at a glance. Example from this app:

```
RemyLive_SHR-1_F_XX-XX_51_2K_20260714_PRC_SMPTE_OV
│        │     │ │  │  │  │  │        │   │     └─ OV = Original Version (vs VF, a patch on another DCP)
│        │     │ │  │  │  │  │        │   └─ standard: SMPTE (vs legacy Interop)
│        │     │ │  │  │  │  │        └─ facility code (who made it; ours defaults to PRC)
│        │     │ │  │  │  │  └─ date created (yyyymmdd)
│        │     │ │  │  │  └─ resolution (always 2K here)
│        │     │ │  │  └─ audio config: 51 = 5.1 layout, MOS = no sound
│        │     │ │  └─ subtitle language (XX = none)
│        │     │ └─ audio language (XX = unspecified; use e.g. EN)
│        │     └─ aspect: F = Flat 1.85, S = Scope 2.39
│        └─ content kind + version: SHR = short, FTR = feature, TLR = trailer, TST = test
└─ title in CamelCase, max ~14 chars
```

The app builds this automatically; the DCP settings pane exposes kind, both language codes, and the facility code, with a live preview. The same string goes into the CPL as `ContentTitleText`, which is what a cinema server displays in its ingest list — so a correct string is how a booth operator confirms they're loading the right file, in the right format, in the right language.
