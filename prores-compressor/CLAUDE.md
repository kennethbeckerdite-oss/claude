# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this directory.

## Project Overview

**ProRes Compressor** — a native macOS app (SwiftUI, macOS 14+, Apple Silicon primary) that exports large Apple ProRes masters (50–200+ GB `.mov`) as either:

1. **MP4** — H.265/H.264 via AVFoundation/VideoToolbox hardware encoding, with two modes: target file size (2–4 GB presets/custom) or the "Small & HQ" preset (H.264 High 6 Mb/s, ≤1080p, ported from Kenneth's HandBrake preset).
2. **DCP** — unencrypted SMPTE 2K 24 fps Digital Cinema Package, via vendored OpenJPEG (JPEG 2000) and asdcplib (MXF), with editable DCNC naming.

Personal-use build: App Sandbox off, ad-hoc signing.

## Audience & UI philosophy (Kenneth's direction — binding for UI work)

The users are **filmmakers who don't use software like this** — people who can't
afford commercial DCP services and need their short to play at festivals.
Clarity and simplicity beat pro-tool density:

- The UI is a single column of film cards. The whole window is always a drop
  target; the list is always visible; one primary button (Export / Export All).
- Every card must be exportable with **zero required decisions** (smart
  defaults: Festival MP4, title from filename, container from aspect, auto
  kind). New cards seed from last-used choices.
- **Plain language in every user-facing string**: outcomes, not codecs
  ("Festival upload file — an MP4 under 2 GB" not "H.264 High 6 Mb/s";
  "Making your cinema package… about 2 hours left" not "Encoding picture").
  Errors must say what to DO ("Export your film at 24 fps and try again"),
  with the technical detail in parentheses at most. `AppState.friendlyMessage`
  is the error-rewriting chokepoint.
- Technical controls live behind each card's "Advanced settings" disclosure —
  never on the main path.
- Export always asks where files should go (folder panel on Export, one choice
  per run, last choice remembered); engine settings carry an optional
  `destinationDirectory` with nil = next-to-source.

## Status (v1 verified on real footage, July 2026)

- MP4 path: confirmed working — 23 GB ProRes master → 1.9 GB MP4.
- DCP path: full export verified — plays in DCP-o-matic Player; clairmeta structural/hash checks pass (its schema-validation errors were a clairmeta packaging bug — PyPI wheel ships without XSDs; install from GitHub, see README).
- Anamorphic/PAR sources handled via track `naturalSize`; rotation metadata passes through on MP4 and is rejected for DCP.
- Exporter strips macOS `._*` AppleDouble files on non-APFS volumes; users must `dot_clean -m` after Finder-copying a DCP to another non-APFS drive.

## TODO / next steps (festival-readiness roadmap, approved by Kenneth)

Done in v2 workstream A (needs Kenneth's build verification):
- [x] **"Festival Short" MP4 preset** — 1.9 GB target, H.264, ≤1080p, AAC 160k (`MP4Settings.festivalShort`).
- [x] **True 5.1 DCP audio passthrough** — ≥6ch sources map by channel labels to L R C LFE Ls Rs (`AudioConformer.ChannelMap`); unlabeled sources pass through flagged in QC.
- [x] **QC report per export** — `QCReport` written next to MP4 (`….QC.txt`) and DCP (`<Folder>_QC.txt`, outside the folder); includes sample peak, mapping, PKL hashes, validator verdict. `ExportResult.qcReportURL` + DoneView button.
- [x] **Zip for Upload** — DoneView button, `ditto -c -k --norsrc --noqtn` (AppleDouble-free archive).

Done in v2 workstream B (needs Kenneth's build verification):
- [x] **25/30 fps DCP support** (+ 23.976/29.97 conform) — new `EditRate` type threads fps through `AudioConformer` (instance samples/frame), `J2KEncoder` (fps-scaled DCI ceiling), `DCPPackage` CPL EditRate/FrameRate, and `DCPValidator` (reads each CPL's own rate).
- [x] **Multi-composition packages** — `DCPPackage.writePackage([Composition])` emits one CPL per video, one shared PKL/ASSETMAP/VOLINDEX. `DCPExporter` loops per `DCPElement`; DCP settings pane has an "Add video…" list. Each video = its own title on the cinema server.

Done in v2 workstream C (needs Kenneth's build verification):
- [x] **Loudness metering** — `LoudnessMeter` (BS.1770-4 integrated LUFS, K-weighting + gating). DCP meters the delivered 6-channel program; MP4 meters the source. QC report gains an advisory Loudness line (warns when a DCP sits near web levels). Warn-only, never alters audio.
- [x] **Burned-in subtitles from SRT** (MP4) — `SRTParser` + `SubtitleRenderer` (CoreText, white/black-outline, bottom-centered). When an .srt is chosen, MP4 export switches to an 8-bit BGRA draw-and-encode path via `AVAssetWriterInputPixelBufferAdaptor`; passthrough is untouched when there's no SRT. UI: "Burn subtitles…" row.

Done in v2 workstream D (needs Kenneth's build verification):
- [x] **Batch queue** — `AppState.QueueJob` (pre-built `any Exporter` + status); jobs run strictly sequentially via `runQueue()`. Configure pane gains "Add to Queue" and a one-click "Screener + DCP" (Festival Short MP4 + DCP from one master). `QueueView` lists status/progress with per-item Reveal/QC. Additive — the single-file wizard is unchanged.
- [x] **DMG distribution** — `Scripts/make-dmg.sh`: xcodegen → xcodebuild Release → codesign (ad-hoc default; Developer ID + hardened runtime + `notarytool`/`stapler` when `DEVELOPER_ID`/`NOTARY_PROFILE` set) → `hdiutil` DMG with /Applications symlink. README "Distribution" section.

Cross-checked against Simple DCP's submission guidelines (July 2026): source
handling, frame-rate conforms, Flat/Scope letterboxing, 24-bit/48k audio, and
DCNC naming all align. Their concrete loudness guidance (−25 to −29 LUFS
integrated for festival films) is now the DCP QC advisory's reference range,
and their gamma-2.2 assumption for unlabeled masters motivated the
per-item Source gamma option (2.2/2.4/2.6, default 2.4/BT.1886).

Deferred:
- [ ] Software x264-quality option if hardware H.264 at 6 Mb/s underperforms the HandBrake original.
- [ ] DCP timed-text subtitles (real XML/PNG subs, vs. the MP4 burn-in above), 4K DCP, encrypted (KDM) DCPs, HDR tone mapping.
- [ ] Stereo-to-center routing option (dialogue speaker) for stereo sources; Leq(m) metering for trailers (TASA 85).
- [ ] Real cinema-server ingest test before any actual screening.

## Build & Test

The Xcode project is **generated** — never edit `ProResCompressor.xcodeproj` (it is gitignored); edit `project.yml` and regenerate:

```sh
xcodegen generate          # requires: brew install xcodegen
open ProResCompressor.xcodeproj
```

Adding a NEW file under `ProResCompressor/` (app target) requires re-running
`xcodegen generate` before it builds — the generated project snapshots the file
list. `TranscodeKit/` (SPM) globs automatically. When a commit adds app-target
files, say so in the reply so Kenneth knows to regenerate.

Engine unit tests (pure-logic: bitrate math, framing, color vectors, DCP XML golden files):

```sh
cd TranscodeKit && swift test
```

Note: building requires macOS + Xcode. Remote/Linux Claude sessions can edit sources but cannot compile; flag anything unverified in the commit/PR description. Kenneth builds locally and pastes back errors.

## Architecture

Strict engine/UI split. The app target (`ProResCompressor/`) is a thin SwiftUI layer over the `TranscodeKit` local Swift package. All export logic goes in the package, never in views.

App layer (post-redesign): `AppState` is item-centric — `QueueItem` (source +
per-item `Deliverable`/`MP4JobConfig`/`DCPJobConfig` + status/results), a
sequential runner (`exportAll`, "both" cards run MP4 then DCP, halves with
results are skipped on retry), and last-used-defaults seeding. Views:
`ContentView` (column + global drop + footer), `FilmCardView` (the card:
deliverable choice, title, Advanced disclosure, status/results),
`MP4SettingsView`/`DCPSettingsView` (Advanced content, bound to the item's
configs), `DropStripView`/`EmptyStateView`. There are no global export
settings and no wizard phases.

- `TranscodeKit` target — `SourceProbe` (async AVAsset probing incl. naturalSize/transform), `Exporter` protocol + shared types (`RenderSize` fitting), `BitrateCalculator` (pure math), `MP4Exporter` (AVAssetReader → AVAssetWriter).
- `DCPKit` target — the DCP pipeline: `DCPExporter` orchestrates decode → framing (`Framing`) → Rec.709→XYZ transform (`ColorTransform`) → JPEG 2000 (`J2KEncoder` over `COpenJPEG`, frame-parallel) → MXF wrap (`MXFWriter` over `CASDCP`) → XML packaging (`DCPPackage` + `DCNCOptions`) → self-check (`DCPValidator`). Audio: `AudioConformer` (24-bit/48 kHz, 5.1-padded stereo, 23.976→24 pull-up).
- `COpenJPEG` — vendored OpenJPEG C sources (BSD-2). Do not hand-edit vendored files; record any required patches in `TranscodeKit/VENDORED.md`.
- `CASDCP` — vendored asdcplib C++ sources (BSD, WITHOUT_SSL config — no OpenSSL) plus `asdcp_shim.cpp/h`, a small extern-C API that is the only surface Swift touches. See `VENDORED.md`.

## Domain conventions

- MP4 size targeting: bitrate computed by `BitrateCalculator` with a 0.97 safety factor so output lands under the requested cap; 10-bit sources get HEVC Main10 and source color properties are passed through. Output dimensions always derive from `naturalSize` (PAR-corrected), never coded dimensions.
- DCP invariants: 12-bit X'Y'Z' (gamma 2.6, 48 cd/m² reference), DCI Cinema2K profile (≤250 Mbps, a bitrate — so the per-frame byte cap scales with fps), 6-channel 5.1-padded 24-bit/48 kHz audio, SMPTE ST 429 XML. Supported rates: 24/25/30 (plus 23.976→24 and 29.97→30, each with the 0.1% audio pull-up); `EditRate` in DCPKit is the single source of truth for fps → edit rate, audio samples/frame, and CPL strings. A package may hold multiple compositions (one CPL each); `DCPPackage.write` is the single-composition convenience over `writePackage([Composition])`. CPL `ContentTitleText` carries the full DCNC name; the human title goes in `AnnotationText`.
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
