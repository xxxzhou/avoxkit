# Third-Party Notices — avoxkit 0.1.0

avoxkit 以 **AGPL-3.0** 发布（见 `LICENSE`）。

## 应用与引擎

| 组件 | 许可证 |
|---|---|
| Flutter / Dart SDK | BSD-3-Clause |
| avox 媒体引擎 | AGPL-3.0 / 商业双许可 |
| Dart pub packages（file_selector / path_provider / ffi / crypto / path / desktop_drop 等） | 各自 LICENSE，BSD-3-Clause、MIT 为主 |

## 随包链接的原生库（Windows 发行链 = GPL flavor）

| 组件 | 版本/说明 | 许可证 |
|---|---|---|
| FFmpeg | n9.0.1，GPL flavor | GPL-2.0-or-later |
| x264 | H.264 编码 | GPL-2.0-or-later |
| x265 | H.265 编码 | GPL-2.0-or-later |
| LAME | MP3 编码 | LGPL-2.1 |
| zlib | 压缩 | zlib |
| OpenSSL | TLS / 摘要 | Apache-2.0 |
| OpenCV | 图像处理 | Apache-2.0 |
| ONNX Runtime | 推理运行时 | MIT |
| sherpa-onnx | 语音识别 | Apache-2.0 |
| nlohmann/json | JSON | MIT |

> macOS 发行链不同：avox `--flavor=commercial` + FFmpeg `--disable-gpl`（LGPL），
> H.264/HEVC 编码走 VideoToolbox，不随包分发 GPL 软编。以对应平台的包为准。

## 运行时下载的模型（不随包分发）

| 模型 | 用途 | 许可证 |
|---|---|---|
| LaMa | 图像修复 | Apache-2.0 |
| YOLO26-Seg watermark | 水印检测 | AGPL-3.0 |
| SenseVoice | 语音识别 | MIT |
| Silero VAD | 语音活动检测 | MIT |

模型由 `https://github.com/xxxzhou/avox_model` 在用户首次使用对应功能时下载；下载前会提示体积（约 230 MB / 290 MB）。

## 源码获取

本包包含 GPL-2.0-or-later 的 FFmpeg/x264/x265 与 AGPL-3.0/商业双许可的 avox 组件，对应源码获取方式见 `SOURCE-OFFER.md`。
