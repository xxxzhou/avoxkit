# Avoxkit

**English | [简体中文](README.zh-CN.md)**

Avoxkit is a desktop audio/video toolbox: convert, trim, extract audio and subtitles, and remove watermarks from images, with one queue for single files or whole folders.

> Flutter · Windows x64 · AGPLv3 · v0.1.0

[![Platform](https://img.shields.io/badge/Platform-Windows%20x64-blue)]()
[![License](https://img.shields.io/badge/License-AGPL_v3-important)](LICENSE)
[![Version](https://img.shields.io/badge/Version-0.1.0-green)]()

- **Free** — every feature is free; no subscription, no watermark.
- **Local** — media files are processed on this machine and never uploaded.
- **No account** — no sign-up, no sign-in, no usage data collected.

## What it does

Avoxkit is built for everyday audio/video work, not for editing. The current release offers:

| Feature | What it does |
|---|---|
| **Convert** | Change container, video codec, resolution or audio codec. When only the container changes and the target supports the source codecs, the file is remuxed instead of re-encoded. Single files and whole folders. |
| **Trim** | Pick a start and end point on a thumbnail, waveform and keyframe timeline, then save that segment. The clip is re-encoded, not losslessly cut. |
| **Extract audio** | Export M4A or MP3; for a single file you can also export the original audio track untouched. Single files and folders. |
| **Extract subtitles** | Export embedded text subtitles as SRT. When there is none, generate them with on-device speech recognition — nothing is uploaded. |
| **Image repair** | Remove watermarks, station logos and overlays from images. Detect them automatically or paint the area by hand; a local LaMa model fills in the background. Single images and folders. |
| **Tasks & batches** | One queue with progress and cancellation; a batch can be cancelled as a group and its failed items retried. On Windows, watch the picture or audio envelope while a job runs. |

Detailed behavior and output settings: **[docs/features.md](docs/features.md)** (currently in Chinese). Other technical documents are indexed in [docs/README.md](docs/README.md).

## Current release

- Version: 0.1.0
- Platform: Windows 64-bit desktop
- Status: under active development

## Build

- Native layer: [native/avtool/README.md](native/avtool/README.md).
- Windows packaging script: `script/build_windows.ps1`.

## Built with

The UI is built with Flutter. Media processing is done by the open-source engine [avox](https://github.com/xxxzhou/avox). The runtime uses an FFmpeg GPL build with x264, x265 and libmp3lame; speech recognition uses sherpa-onnx with SenseVoice (Apache-2.0) and Silero VAD (MIT); image repair uses LaMa and a YOLO26-Seg watermark model, downloaded on demand.

Released under **AGPL-3.0**.
