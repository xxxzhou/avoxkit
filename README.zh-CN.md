# Avoxkit 音视频工具箱：免费视频转换器、录屏软件、字幕提取与图片去水印

**[English](README.md) | 简体中文**

[![Download](https://img.shields.io/badge/Download-v0.1.0-2ea44f?logo=github)](https://github.com/xxxzhou/avoxkit/releases/latest)
[![Platform](https://img.shields.io/badge/Platform-Windows%20x64%20%7C%20macOS%20arm64-blue)](https://github.com/xxxzhou/avoxkit/releases/latest)
[![License](https://img.shields.io/badge/License-AGPL--3.0-orange)](LICENSE)
[![Privacy](https://img.shields.io/badge/Privacy-local--only-success)](PRIVACY.md)

![Avoxkit 视频截取工具：画面参考、音频波形与关键帧时间线](docs/screenshots/ak-clip.webp)

*Windows 版截取页：画面参考显示在时间线上方，缩略图、音频波形和关键帧共用一条时间线；拖动手柄或直接输入时间，画面会跟着变。*

*预览画面来自 Sintel（© Blender Foundation，CC BY 3.0）。*

**Avoxkit 是一款免费、本地、免登录的桌面音视频工具箱，支持 Windows x64 和 macOS arm64（Apple Silicon）。** 它可以转换 MP4 / MKV / MOV，重编码为 H.264 / H.265，录制屏幕，截取视频片段，从视频中提取音频，导出内嵌字幕或用本地语音识别生成 SRT，还能去除图片水印。整个流程都在这台电脑上完成：文件不上传，成品不加水印。

所有媒体处理都在本机完成：没有会员，不需要账号，也没有遥测。Avoxkit 面向日常音视频处理——把这个文件转成需要的格式、截一段、取出音轨或字幕、清理一张图——而不是多轨剪辑。

## 为什么选择 Avoxkit

- **免费**：所有功能免费，没有会员等级，成品不加水印。
- **本地**：媒体文件只在这台电脑上读写，不上传，不经过云端。
- **免登录**：不用注册、不用登录，也不收集使用数据。语音识别和图像修复的模型按需下载，媒体文件始终留在本机。

## 下载 Avoxkit（Windows / macOS）

[**下载最新版 →**](https://github.com/xxxzhou/avoxkit/releases/latest) — 免费 · Windows x64 · macOS arm64（Apple Silicon）· v0.1.0 · 2026-10-31 发布。无需账号 · 无水印 · 不上传。macOS 版已 Developer ID 签名并公证。

直接下载：[Windows x64 ZIP](https://github.com/xxxzhou/avoxkit/releases/download/v0.1.0/Avoxkit-0.1.0-windows-x64.zip) · [macOS arm64 DMG](https://github.com/xxxzhou/avoxkit/releases/download/v0.1.0/Avoxkit-0.1.0-arm64.dmg)

[全部版本](https://github.com/xxxzhou/avoxkit/releases)

## 功能一览

六个日常工具共用一个界面。转换、截取、提取音频、提取字幕和图像修复这五个工具还共用一套任务队列；录屏有独立的录制与导出流程。完整行为与边界见 **[docs/features.md](docs/features.md)**。

### 视频转换：MP4、MKV、MOV，H.264 / H.265

改容器、视频编码、分辨率或音频编码。只换容器、且目标容器支持源编码时，Avoxkit 会直接封装，不重新编码；需要重编码时，可以选择 H.264 / H.265、2160p 到 480p、AAC / MP3，以及 0–100 的质量或按 MB 指定的目标体积。

- 输入：MKV、MP4、MOV、AVI、TS、FLV、WebM、WMV、M4V；输出容器：MP4、MKV、MOV。
- 出厂预设包括仅换容器 MP4、H.265 · 1080p、H.264 · 1080p 和 25 MB 目标体积，也可以把当前设置保存成自己的预设。
- 本机检测到可用硬件编码器时可以开启硬件编码；默认使用软件编码。
- 直接封装仍要完整读写文件，在机械盘、云盘或网络位置上不会“瞬间完成”。

![Avoxkit 免费视频转换器（Windows）：MP4、MKV、MOV 容器，H.264/H.265 编码与 1080p 输出设置](docs/screenshots/avoxkit-video-converter-windows.png)

*转换页同时处理格式转换和只换封装的直拷，提交前会显示源文件信息、处理方式和输出路径。*

### 录屏：显示器或固定区域，30 / 60 fps

录制显示器画面，或从显示器左上角起录一个固定区域，帧率可选 30 或 60 fps。麦克风和系统声音分别开关（系统声音在 0.1.0 中仅 Windows 可用）。停止后可以导出 H.264 + AAC 的 MP4，默认带深色渐变背景、留白、圆角和阴影。

- 每次录制按时间新建文件夹，保留原始画面、混音预览成片和工程文件，方便重复导出。
- 系统光标默认不烧进原始画面，导出时按轨迹重绘；打开开关则直接录进画面。
- 横屏输出 1920×1080，竖屏 1080×1920，方形 1080×1080；录制期间本应用窗口会被排除。
- 暂不支持摄像头画中画；导出包装固定，不能缩放、裁剪、分段或自定义背景、圆角和阴影。

![Avoxkit 录屏软件（Windows）：60 fps 录制 2560×1440 显示器，支持麦克风与系统声音](docs/screenshots/avoxkit-screen-recorder-windows.png)

*录制显示器或固定区域，30 / 60 fps 可选，麦克风和系统声音分别开关（系统声音仅 Windows）。*

### 视频截取：缩略图、波形与关键帧时间线

截取页是一条区间尺，不是播放器。缩略图按整片均匀采样，有音轨时显示音频包络，关键帧用小刻度标出。拖两个手柄设置入点和出点，也可以直接输入 `hh:mm:ss.mmm`、`mm:ss` 或秒数。

- 滚轮以指针为锚缩放，拖空白处平移，双击回到全片。
- 起点吸附到目标前最近的关键帧；终点按时间截断，可能有半秒内偏差；最短片段 0.1 秒。
- 片段会重新编码，**不是无损剪切**：视频为 H.264 / H.265，音频为 AAC，容器可选同源、MP4、MKV 或 MOV。
- 输出默认放在源文件旁，文件名加 `.clip`；质量 0–100 可调。

### 提取音频：M4A / MP3 / 原始音轨

从视频里取出第一条音轨，支持单个文件或整个文件夹。M4A（AAC）或 MP3 可选 128、192、256、320 kbps；单文件还可以原样导出原始音轨，不重新编码；目标容器不接受该编码时会自动重编码。

- 文件夹批量提供 M4A 和 MP3；没有音轨的文件会在提交时被拒绝，不影响其他文件。
- 输出默认放在源文件旁；文件夹模式可以保留子目录结构，也可以平铺。
- 文件夹批量导出时，已存在的输出会跳过。

![Avoxkit 提取音频页面：M4A / MP3 输出、码率选项与文件夹批量](docs/screenshots/avoxkit-extract-audio-windows.png)

*把第一条音轨导出为 M4A 或 MP3（128–320 kbps）；单文件还可原样导出原始音轨，目标容器不接受该编码时会自动重编码。*

### 提取字幕与语音识别转字幕：输出 SRT

有内嵌文本字幕轨时直接导出 SRT；没有时用本地语音识别生成。音频不会上传。

- 自动选择默认文本轨；没有默认轨时优先中文，再退回第一条文本字幕。也可以手动选择具体字幕轨。
- 支持 SRT、ASS/SSA、WebVTT、mov_text 等文本字幕轨。PGS、DVD、DVB 等图形字幕不能直接转成文字，界面会提示改用语音识别。
- 本地识别使用 SenseVoice + Silero VAD，支持中文、英文、日文、韩文、粤语。
- 模型不随安装包分发，首次使用按需下载约 230 MB，带 SHA-256 校验；下载完成后即可离线识别。

![Avoxkit 字幕提取与本地语音识别：SenseVoice 支持中文、英文、日文、韩文、粤语](docs/screenshots/avoxkit-subtitle-extractor-windows.png)

*没有内嵌文本字幕时，用本地 SenseVoice 识别生成 SRT；模型首次使用下载，之后离线可用。*

### 图片去水印：自动识别或手动涂抹

去掉图片里的水印、台标和叠加文字。自动识别先在本机检测可疑水印位置，再用 LaMa 补全背景；手动涂抹则只修复你涂出的区域。

- 自动识别适合位置不固定的水印；手动涂抹适合已知位置的台标、角标或文字，只对单张图片生效。
- 预览图会用框标出识别结果，修复后切到结果图，可随时切回原图对比。
- 输入 JPG、JPEG、PNG、BMP、WebP、TGA；输出 JPG、PNG、BMP、TGA。“保持原格式”跟随源文件，WebP 输入会输出 PNG。
- 文件夹批量统一走自动识别；识别不到水印的图片会跳过，并在任务里标记。
- 模型按需下载，约 290 MB，带 SHA-256 校验，不随安装包分发。修复是生成式补全，不保证与原背景完全一致；重要图片建议保留原图。

![Avoxkit 图片去水印：自动识别水印与修复结果预览](docs/screenshots/avoxkit-watermark-remover-windows.png)

*自动识别模式下的图像修复页：预览显示修复结果，可以切回原图对比。*

### 批量处理与任务队列

转换、截取、提取音频、提取字幕和图像修复共用一个任务队列。批量任务可以是一整个文件夹的视频或图片，任务页会显示进度、排队位置、失败原因和产物路径。

- 默认一次处理一个任务，避免多个编码器同时争抢 GPU 和磁盘。
- 批量组显示总数、完成、失败、进行中、排队和跳过数量；超过 20 项默认折叠。可以整组取消，也可以一键重试失败项。
- 「全部完成后」可选通知、睡眠或关机；只在所有任务正常结束时触发。关机有 60 秒延迟，可以取消；该选择只在本次运行内生效。
- Windows 版在重编码时显示当前画面或音频包络；macOS 当前只显示进度。
- 先写临时文件，失败或取消会清理；转换、提取音频和提取字幕的批量任务会跳过已存在的输出。
- 单次文件夹扫描最多 5000 个文件。任务历史保存在本机；上次退出时中断的任务会标记出来，可以手动重新排队，不会自动续跑。

<img src="docs/screenshots/avoxkit-batch-task-queue-windows.png" alt="Avoxkit 任务队列：已完成的视频转换任务与输出路径" width="620">

*单文件与批量组共用同一个队列，支持进度、取消和重试；图中是一个已完成的转换任务。*

## 隐私：文件不出本机

- 媒体文件只在本机读写，不会上传，也不经过云端处理。
- 没有账号系统，不收集使用数据，没有广告，成品不加水印。
- 除首次使用语音识别或图像修复时按需下载模型外，转换、录屏、截取、提取音频和导出内嵌字幕都不需要联网。
- 模型下载只获取模型文件，不读取、不上传你的媒体。
- 应用不含遥测、云同步或自动上传逻辑；任务历史只保存在本机应用数据目录。

完整说明见 [隐私政策](PRIVACY.md)。

## 常见问题

- **Avoxkit 真的免费吗？有水印吗？** 真的免费。0.1.0 的所有功能都不收费，没有会员等级，成品也不会被加上水印。
- **会把我选择的视频、图片上传吗？** 不会。媒体文件只在这台电脑上读写，没有云端处理，也没有账号和遥测。语音识别和图像修复的模型按需下载，下载请求不包含你的媒体文件。
- **需要注册账号或一直联网吗？** 不需要账号。转换、录屏、截取、提取音频和导出内嵌字幕都可以离线完成；语音识别（约 230 MB）和图像修复（约 290 MB）首次使用时下载模型，之后可离线运行。
- **支持哪些格式？** 输入支持 MKV、MP4、MOV、AVI、TS、FLV、WebM、WMV、M4V；输出容器为 MP4、MKV、MOV，视频编码可选 H.264 / H.265，音频可选 AAC / MP3。只换容器且编码兼容时会直接封装，不重新编码。
- **截取片段是无损剪切吗？** 不是。选中片段会重新编码为 H.264 / H.265 视频和 AAC 音频。起点会吸附到前一个关键帧，终点可能有半秒内偏差，最短片段 0.1 秒。
- **macOS 能录系统声音吗？** 0.1.0 不能。系统声音录制仅 Windows 可用；macOS 录屏可以录麦克风。两个平台都支持录制显示器或固定区域，帧率可选 30 或 60 fps。
- **批量处理有数量限制吗？** 单次文件夹扫描最多 5000 个文件，超过会停止扫描并提示缩小范围。任务默认一次处理一个，批量组可以整组取消或重试失败项；转换、提取音频和提取字幕的批量任务会跳过已存在的输出。

## 系统要求与下载

| 项目 | 说明 |
|---|---|
| 版本 | 0.1.0（2026-10-31 发布） |
| 界面 | 简体中文 |
| Windows | Windows x64 桌面版 |
| Windows 下载 | [Avoxkit-0.1.0-windows-x64.zip](https://github.com/xxxzhou/avoxkit/releases/download/v0.1.0/Avoxkit-0.1.0-windows-x64.zip) · [SHA-256](https://github.com/xxxzhou/avoxkit/releases/download/v0.1.0/Avoxkit-0.1.0-windows-x64.zip.sha256) |
| macOS | macOS arm64（Apple Silicon）；已 Developer ID 签名并公证 |
| macOS 下载 | [Avoxkit-0.1.0-arm64.dmg](https://github.com/xxxzhou/avoxkit/releases/download/v0.1.0/Avoxkit-0.1.0-arm64.dmg) · [SHA-256](https://github.com/xxxzhou/avoxkit/releases/download/v0.1.0/Avoxkit-0.1.0-arm64.dmg.sha256) |
| 网络 | 语音识别和图像修复首次使用时按需下载模型（约 230 MB / 约 290 MB）；转换、录屏、截取、提取音频可离线使用。 |
| 下载 | [GitHub Releases](https://github.com/xxxzhou/avoxkit/releases/latest) |
| 许可 | [AGPL-3.0](LICENSE) |

[**下载 Avoxkit 0.1.0 →**](https://github.com/xxxzhou/avoxkit/releases/latest)

## 从源码构建

- 原生层构建说明见 [native/avtool/README.md](native/avtool/README.md)。
- Windows 打包脚本：`script/build_windows.ps1`。
- macOS 打包脚本：`script/build_macos.sh`（arm64，产物在 `dist/`）。
- macOS 发布：`script/release_macos.sh`（构建 → 公证 → DMG → 装订）。

## 技术底座与许可

界面使用 Flutter 构建，媒体处理由开源引擎 [avox](https://github.com/xxxzhou/avox) 完成，运行时使用 FFmpeg。Windows 发行版是 GPL 构建，包含 x264、x265 和 libmp3lame；macOS 发行版是 LGPL 构建，不含 GPL 编解码器，H.264 / HEVC 编码走 VideoToolbox。

语音识别使用 sherpa-onnx，模型为 SenseVoice（Apache-2.0）和 Silero VAD（MIT）。图片修复使用 LaMa 与 YOLO26-Seg 水印模型，模型按需下载，不随安装包分发。

项目以 **AGPL-3.0** 发布，见 [LICENSE](LICENSE)、[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)、[SOURCE-OFFER.md](SOURCE-OFFER.md)。

更多文档：[功能与边界](docs/features.md)、[文档索引](docs/README.md)、[架构说明](docs/architecture.md)。
