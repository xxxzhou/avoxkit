# avoxkit 源码获取（AGPL-3.0 / LGPL-2.1 合规）

avoxkit 0.1.0 的 macOS 分发包内含 **AGPL-3.0** 的 avoxkit、**AGPL-3.0 / 商业双许可**的 avox 引擎（本次为 commercial/LGPL 渠道），以及 **LGPL-2.1-or-later** 的 FFmpeg。按许可证要求，现提供对应源码。

## 获取方式（任选一种）

1. **公开仓库**：`https://github.com/xxxzhou/avoxkit` 的 `v0.1.0` tag；GitHub 同时提供 Source code (zip/tar.gz)。
2. **随发布包提供**：每个 release 同时提供 `avoxkit-<version>-source.tar.gz`，内容包括本仓源码、`script/`、`macos/`、`native/`、`pubspec.*`，以及 `script/ffmpeg/build_ffmpeg_macos.sh` 的 configure。
3. **书面申请**：在本仓库开 issue，标题 `source request`，注明需要的版本。该书面要约自该版本发布之日起 **三年内** 有效。

## 源码范围

- **avoxkit**：发布页标注的 commit（UI、原生 shim、构建脚本、Xcode 工程）。
- **avox**：发布页标注的 commit（本次为 `--flavor=commercial`）。
- **FFmpeg**：n9.0.1，configure 参数见 `script/ffmpeg/build_ffmpeg_macos.sh`（`--disable-gpl`、libmp3lame、VideoToolbox/SecureTransport）。
- **LAME / dav1d**：上游对应版本；版本与校验逻辑在同脚本内。
- **不包含**：用户媒体文件；模型权重（`avox_model` 仓库单独公开）。

## 构建

见 `docs/macos-porting.md`。产物为 arm64、部署目标 macOS 12.0。
