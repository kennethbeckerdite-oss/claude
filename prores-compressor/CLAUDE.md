# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this directory.

## Project Overview

**ProRes Compressor** (working title) is a planned desktop video transcoding tool in the spirit of HandBrake, focused on one core job: taking large Apple ProRes files (often 50-200+ GB) and compressing them into high-quality MP4 files in a target size range of **2-4 GB**.

There is no source code yet. This document captures the product intent and the technical direction so future sessions can start building without re-deriving context.

## Core Use Case

- Input: ProRes 422 / 422 HQ / 4444 files (typically `.mov`), e.g. camera masters or NLE exports.
- Output: H.264 or H.265 MP4 targeted at a user-selected file size (default 2-4 GB), suitable for delivery, review, and archiving alongside the master.
- The user picks a target size (or a preset); the tool computes the video bitrate from duration and audio settings, then runs a two-pass (or constrained-quality) encode to hit it.

## Planned Technical Direction

- **Encoding engine:** FFmpeg (invoked as a subprocess or via libav bindings) — it handles ProRes decode and x264/x265 encode out of the box.
- **Size targeting:** bitrate = (target size − audio size − container overhead) / duration, with two-pass encoding for accuracy; optionally CRF mode with a size cap.
- **Hardware acceleration:** optional VideoToolbox (macOS), NVENC (NVIDIA), and QSV (Intel) paths for speed, with software x264/x265 as the quality reference.
- **Queue:** batch multiple files with per-file or global presets, HandBrake-style.
- **UI:** to be decided — likely a desktop GUI (e.g. Electron/Tauri or native) with a CLI mode for scripting.

## Development

No build, lint, or test commands exist yet. When scaffolding begins:

- Add build/test/lint commands to this file as they are introduced.
- Keep FFmpeg interaction isolated behind a single module/service so the engine can be tested independently of any UI.
