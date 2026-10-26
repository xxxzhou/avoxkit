# avoxkit 架构(2026-10-26 定稿)

> 本文是技术底稿: 分层决策、任务模型、`ak_*` C ABI 草案、功能→引擎映射、
> 引擎缺口清单(归 avox 仓)、构建配方、里程碑。
> 需求与市场取证见 `D:/Work/github/panvox-site/docs/seo/revenue/free-avox-tool-research.md`。

## 0. 决策记录

- 2026-10-26: **独立公开仓**, AGPL-3.0(与 avox 同源, GPL 家族, x264/x265 走
  gpl flavor 合法)。**不走 avox_cli 路线**——CLI 只当引擎调用面的示范样本;
  产品有自己的 GUI, 直接调 avox C++ API。**不复用 panvox 私有 shim 代码**,
  自建 `ak_*` 窄 ABI。引擎与 UI 之间所有新能力(队列、进度、参数面)落本仓。

## 1. 总体分层

```
┌─ Flutter 桌面壳(avoxkit UI, Win/mac/Linux 一套码)
│    任务列表 + 参数表单 + 进度; 不出现任何「剪辑时间线」
│        │  dart:ffi
├─ native/avtool —— 本仓自建 C ABI shim (avoxkit_native.dll/.so/.dylib)
│    任务模型: 队列/并发上限/进度/取消/重试; 参数解析(内部格式)
│        │  链接 avox.lib(动态/静态随 avox 默认产物)
├─ avox 引擎(独立仓, AGPL)
│    TranscodeRecorder / StreamRecorder / AudioStt+SubtitleAsr(avox_sherpa)
│    / ImageIO / FFVEncoder / Vulkan 层件
│        │
└─ ffmpeg(gpl flavor + libmp3lame, avox 构建脚本产出) + onnx 模型(字幕)
```

与 panvox 同构的部分只有「Flutter + FFI + C shim + 引擎」这个**模式**;
代码各写各的。avox 无官方 C 导出层, panvox 的 `pvx_*` 是私有 shim——这就是
本仓 native 层存在的理由。

## 2. `ak_*` C ABI 草案(v0, M1 定稿后冻结)

设计原则: **窄面 + JSON 参数**。函数个数少, 任务参数走 UTF-8 JSON 字符串
(迭代期免改 ABI; 稳定后可再拆结构体)。回调单次注册, 永远在 shim 自己的
线程上触发, Dart 侧只收事件不参与等待。

```c
// 全局
const char* ak_version(void);
int         ak_init(const char* work_dir_json);      // 日志/模型/临时目录
void        ak_shutdown(void);

// 任务(核心面)
int64_t     ak_task_submit(const char* task_json);   // 返回 task_id, <0 出错
int         ak_task_cancel(int64_t task_id);         // 优雅取消(引擎排空)
int         ak_task_remove(int64_t task_id);         // 队列中移除
int         ak_pause_all(int pause);                 // 全局暂停/恢复(可选)

// 回调(注册一次): on_event(const char* event_json, void* user)
//   event_json: {type: progress|state|error|done, task_id, ...}
typedef void (*ak_event_cb)(const char* event_json, void* user);
int         ak_set_event_cb(ak_event_cb cb, void* user);

// 探测(表单要用)
const char* ak_probe(const char* input_path);        // 时长/轨/编解码器摘要
int         ak_encoder_probe(void);                  // 硬编可用性(真编验证)
```

task_json 形状(例): `{"kind":"transcode","input":"...","output":"...",
"video":{"codec":"h264","hardware":"auto","quality":70,"targetMB":10},
"audio":{"codec":"aac","kbps":128},"preset":"bilibili_1080p"}`

kind 集合 = `transcode | remux | extract_audio | asr | trim | burn_sub`。
(后两个依赖 avox 侧缺口补齐, 见 §5。)

## 3. 任务模型与队列

- 引擎对象级并发天然可用(每个 IRecorder 独立实例), 但引擎**没有**队列/
  上限/重试框架——全部在本仓 shim 层建: 一个优先级队列 + 并发闸
  (默认 1 转码任务, 硬编探测通过后可放宽到 2)+ 失败重试(瞬态错误)。
- 状态机: `queued → running → done | failed | cancelled`; 进度事件直接透传
  引擎 RecorderProgress(currentMs/totalMs)(avox `AvoxMuxer.h:72-94`),
  百分比/ETA 由 UI 算。
- 取消走引擎 close 排空语义(`TranscodeRecorder.hpp:121-128`), 不杀线程。

## 4. 功能 → 引擎映射(现成, 引用 avox 仓内路径)

| 功能 | 引擎现状 | 位置(avox) |
|---|---|---|
| 格式转换/压缩 | TranscodeRecorder: 解码→Vulkan 处理→重编码→封装 | `src/avox/muxer/TranscodeRecorder.hpp` |
| 输出参数面 | quality/cbr/vbr/gop/profile/分辨率/音频重采样 | `src/avox/AvoxMuxer.h:132-196` |
| 硬编 | 平台硬编默认开启(mf/qsv/amf/nvenc/vaapi/videotoolbox), 软编 x264/x265 | `src/avox_ffmpeg/encoder/FFVEncoder.cpp:196,393` |
| 无损 remux | StreamRecorder(createRecorder(false)) | `src/avox/muxer/StreamRecorder.hpp` |
| 轨级直拷(换/抽音轨不重编) | TransMode AudioCopy/VideoCopy | `src/avox/AvoxMuxer.h:219-228` |
| 提取音频 | AudioTap + FFResample + WavSave + AAC; mp3 待补 | `src/avox/audio/AudioTap.hpp` 等 |
| 本地字幕生成 | AudioStt(sherpa-onnx SenseVoice)→SubtitleAsr | `src/avox/audio/AudioStt.cpp`; `src/avox/subtitle/SubtitleAsr.hpp` |
| 抽帧/封面 | screenShot → JPEG/PNG/BMP/TGA | `src/avox/video/ImageIO.cpp:131` |
| 硬编探测 | 真编 3 帧验证(panvox 有先例 `pvx_encoder_probe`, 本仓重写) | 思路见 panvox_c_api.h:607(仅参考) |
| 文件探测 | IoPlan/白名单按 probe 打开 | `src/avox_ffmpeg/IOParseFF.cpp` |

## 5. 引擎缺口清单(**全部归 avox 仓做**, 本仓只挂依赖)

按里程碑排序:

1. **libmp3lame**(M2 前要): ffmpeg 白名单加入 + 重出 gpl 产物;
   现状「写 mp3 被静默忽略」(`build_ffmpeg.py:154-155`)。
2. **无损剪切成品 API**(M4): 关键帧对齐区间导出; 零件=StreamRecorder 的
   seek+remux。顺带**无损合并**(全仓现无 concat 实现)。
3. **字幕轨导出**(M3 后): SrtParser 补写出(SrtParser.hpp:13-19 只有 parse)。
4. **离线字幕烧录**(M5 后): TranscodeRecorder 挂字幕模块(渲染三层已齐:
   libass 插件 + FreeType + PGS 解码, 差接线)。
5. (后置) GIF/WebP 编码器; 旋转/裁剪的录制链开关(VkTransposeLayer/
   VkResizeLayer 包一层 IRecordVideoFilter)。

注意: ffmpeg 显式禁了 avfilter/swscale(`build_ffmpeg.py:61-62`), 不能借
filtergraph 补能力——上述都走引擎自有链。

## 6. 构建配方

- **ffmpeg**: avox 仓 `script/ffmpeg/build_ffmpeg.py`, 选 **gpl flavor**,
  追加 libmp3lame; 出厂前 `--verify` 扫描(禁 nonfree/fdk-aac 红线,
  AGENTS.md 已钉)。SDK 目录用环境变量钉(本仓 `AVOXKIT_FFMPEG_SDK`,
  与 panvox 的 PANVOX_FFMPEG_SDK 同机制)。
- **avox 库**: CMake 开关 `AVOX_ENABLE_FFMPEG/CLI/PLUGINS...`
  (avox `CMakeLists.txt:201-218`); 工具链路不需要播放呈现层, CLI 开关
  可关, avox_sherpa 插件必开。首次链接(M1)时钉下具体 target 清单。
- **shim**: `native/avtool/`(C++17), 三端各一薄层 + 共享 `avtool_core`;
  产物 `avoxkit_native`; Dart 侧 `lib/native/` 用 ffi 生成式绑定手写
  (任务面小, 不上 ffigen)。
- **Flutter**: SDK 在 `D:/Work/flutter`; `flutter run --release` 为默认
  运行口径(与 panvox 同纪律)。

## 7. 里程碑

| 里程碑 | 内容 | 依赖 |
|---|---|---|
| M0(本提交) | 仓骨架: 壳 + 架构 + ABI 草案 + README/AGENTS | — |
| M1 | avox 链接打通; 第一条 transcode 任务(文件→输出, 进度/取消)全链跑通; 队列 v0 | Windows 先行 |
| M2 | remux + 提取音频; avox 侧 libmp3lame 落地 | avox#1 |
| M3 | 本地字幕生成(avox_sherpa + 模型分发口径: 首用下载/便携包) | avox_sherpa |
| M4 | 无损剪切 + 批量队列成形 | avox#2 |
| M5 | 三端打包(安装/便携) + 落地页 + Show HN(归 panvox-site) | avox#3–4 后置 |

## 8. 引流闭环(产品层, 不进代码逻辑)

工具内唯一出口: 「关于」页 Powered by avox(GitHub 链接) + Panvox 推荐位;
不做弹窗不做常驻横幅。落地页/发文/Show HN 稿全部归 panvox-site 仓运营。
