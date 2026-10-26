# Avoxkit

> Free, local, private — an audio & video toolbox for everyone, not for editors.
> Powered by [avox](https://github.com/xxxzhou/avox), our open-source media engine.

- **Free** — every feature, no watermark, no membership tiers.
- **Local** — your files never leave your machine. No uploads, ever.
- **No account** — no sign-up, no sign-in, no tracking, no ads.

## What it does (planned first release)

1. **Convert** — HEVC → H.264 and one-click presets (Bilibili / Douyin / WeChat / Discord…); a single file or a whole folder.
2. **Compress** — shrink a video to a target size (e.g. 10 MB for chat apps).
3. **Remux & extract audio** — lossless MKV ↔ MP4 container swap; export MP3 / M4A; folders supported.
4. **Subtitles** — generate SRT from speech, fully offline (nothing uploaded to any cloud).
5. **Lossless trim** — cut the head/tail without re-encoding.
6. **Image cleanup** — remove watermarks or logos from photos, fully offline.

Later: subtitle extraction & hard-burn, frame grabs / GIF, AI enhancement…

## Status

🚧 Under active development — nothing to download yet. See
[docs/architecture.md](docs/architecture.md) for the technical plan.

## Platforms

Windows · macOS · Linux (desktop first).

## License & credits

Avoxkit is licensed under **AGPL-3.0**, same as the
[avox](https://github.com/xxxzhou/avox) engine it is built on.
Built with FFmpeg (GPL build, with x264/x265/libmp3lame) and
[sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) for offline speech recognition.

Looking for a player instead? Try our sister product
**Panvox** — a cross-platform video player with AI subtitle translation.

---

中文说明:Avoxkit 是一款面向普通人的免费音视频工具箱——格式转换、压缩、提取音频、
本地生成字幕、无损剪切、图片去水印。全部功能免费、无水印、不需要账号;所有处理都在你自己的
电脑上完成,文件不会被上传到任何服务器。技术底座是开源引擎
[avox](https://github.com/xxxzhou/avox)(AGPL-3.0)。项目开发中,敬请期待。
