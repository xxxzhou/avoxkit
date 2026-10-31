# Third-Party Notices — avoxkit 0.1.0

avoxkit 以 **AGPL-3.0** 发布（见 `LICENSE`）。macOS 0.1.0 包内含或链接以下组件。

## 应用与引擎

| 组件 | 许可证 |
|---|---|
| Flutter / Dart SDK | BSD-3-Clause |
| avox 媒体引擎（本次构建 `--flavor=commercial`，商业/LGPL 渠道） | AGPL-3.0 / 商业双许可 |
| Dart pub packages（file_selector / path_provider / ffi / crypto / path 等） | 各自 LICENSE，BSD-3-Clause 为主 |

## 随包链接的原生库

| 组件 | 版本/说明 | 许可证 |
|---|---|---|
| FFmpeg | n9.0.1，`--disable-gpl` | LGPL-2.1-or-later |
| LAME | MP3 编码 | LGPL-2.1 |
| zlib | 压缩 | zlib |
| dav1d | AV1 解码（启用时） | BSD-2-Clause |
| OpenSSL | TLS / 摘要 | Apache-2.0 |
| OpenCV | 图像处理 | Apache-2.0 |
| ONNX Runtime | 推理运行时 | MIT |
| sherpa-onnx | 语音识别 | Apache-2.0 |
| MoltenVK / Vulkan loader | Metal 上的 Vulkan | Apache-2.0 |
| nlohmann/json | JSON | MIT |

H.264 / HEVC 编码由 macOS 自带的 VideoToolbox 完成，不随包分发 GPL 编解码器。

## 运行时下载的模型（不随包分发）

| 模型 | 用途 | 许可证 |
|---|---|---|
| LaMa | 图像修复 | Apache-2.0 |
| YOLO26-Seg watermark | 水印检测 | AGPL-3.0 |
| SenseVoice | 语音识别 | MIT |
| Silero VAD | 语音活动检测 | MIT |

模型由 `https://github.com/xxxzhou/avox_model` 在用户首次使用对应功能时下载；下载前会提示体积（约 230 MB / 290 MB）。

## 源码获取

本包包含 LGPL-2.1-or-later 的 FFmpeg 与 AGPL-3.0/商业双许可的 avox 组件，对应源码获取方式见 `SOURCE-OFFER.md`。
