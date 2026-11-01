# Avoxkit

**[English](README.md) | 简体中文**

Avoxkit 是一个桌面音视频工具箱：录屏、转换、截取片段、提取音频、提取字幕，单文件和整个文件夹走同一个队列。

> Flutter · Windows x64 / macOS arm64 · AGPLv3 · v0.1.0

[![Platform](https://img.shields.io/badge/Platform-Windows%20x64%20%7C%20macOS%20arm64-blue)(https://github.com/xxxzhou/avoxkit/releases/latest)
[![License](https://img.shields.io/badge/License-AGPL_v3-important)](LICENSE)
[![Version](https://img.shields.io/badge/Version-0.1.0-green)]()

- **免费** — 所有功能免费，没有会员、没有水印。
- **本地** — 媒体文件只在这台电脑上处理，不会上传到任何服务器。
- **无账号** — 不需要注册、登录，也不收集使用数据。

## 当前功能

Avoxkit 面向日常音视频处理，不是剪辑软件。当前版本提供：

| 功能 | 能做什么 |
|---|---|
| **转换** | 改容器、视频编码、分辨率和音频编码；只换容器且目标格式支持源编码时自动直接封装，不重新编码。支持单文件和整个文件夹。 |
| **录屏** | 录制显示器或固定屏幕区域，可同时录麦克风和系统声音（系统声音目前仅 Windows）；停止后可导出带背景、圆角、阴影的 MP4。 |
| **截取片段** | 在缩略图、波形和关键帧时间线上选择起止点，保存其中一段。片段会重新编码，不是无损剪切。 |
| **提取音频** | 导出 M4A、MP3；单文件还可原样导出原始音轨。支持单文件和文件夹批量。 |
| **提取字幕** | 有内嵌文本字幕轨时直接导出 SRT；没有时可用本地语音识别生成。识别在本机完成，文件不上传。 |
| **任务与批量** | 统一队列、进度、取消；批量组可整组取消、重试失败项；Windows 版可在处理中查看画面或音频包络，macOS 当前显示进度（原生预览为后续版本）。 |

完整的功能细节和输出设置见 **[docs/features.md](docs/features.md)**；其余技术文档见 [docs/README.md](docs/README.md)。

## 当前版本

- 版本：0.1.0
- 平台：Windows 64 位桌面版；macOS arm64（Apple Silicon）
- 状态：0.1.0 · macOS 版已 Developer ID 签名并公证
- 下载：[GitHub Releases](https://github.com/xxxzhou/avoxkit/releases/latest)
- macOS 说明：仅 Apple Silicon；录屏只录麦克风（系统声为 Windows 专属）；原生预览暂以进度代替。

## 构建

- 原生层构建说明见 [native/avtool/README.md](native/avtool/README.md)。
- Windows 打包脚本：`script/build_windows.ps1`。
- macOS 打包脚本：`script/build_macos.sh`（arm64，产物在 `dist/`）。
- macOS 发布：`script/release_macos.sh`（构建 → 公证 → DMG → 装订）。

## 技术底座与许可

Avoxkit 使用 Flutter 构建桌面界面，媒体处理由开源引擎 [avox](https://github.com/xxxzhou/avox) 完成。运行时使用 LGPL 的 FFmpeg 构建（libmp3lame + VideoToolbox，不含 GPL 编解码器）；语音识别使用 sherpa-onnx，模型为 SenseVoice（Apache-2.0）与 Silero VAD（MIT）。

项目以 **AGPL-3.0** 许可发布。
