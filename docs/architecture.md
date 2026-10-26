# avoxkit 架构(2026-10-26 定稿)

> 本文是技术底稿: 分层决策、任务模型、`ak_*` C ABI 草案、功能→引擎映射、
> 引擎缺口清单(归 avox 仓)、构建配方、里程碑。
> 需求与市场取证见 `D:/Work/github/panvox-site/docs/seo/revenue/free-avox-tool-research.md`。

## 0. 决策记录

- 2026-10-26: **独立公开仓**, AGPL-3.0(与 avox 同源, GPL 家族, x264/x265 走
  gpl flavor 合法)。**不走 avox_cli 路线**——CLI 只当引擎调用面的示范样本;
  产品有自己的 GUI, 直接调 avox C++ API。**不复用 panvox 私有 shim 代码**,
  自建 `ak_*` 窄 ABI。引擎与 UI 之间所有新能力(队列、进度、参数面)落本仓。
- 2026-10-26: **ffmpeg 自建脚本**。出厂 ffmpeg 由本仓
  `script/ffmpeg/build_ffmpeg.py` 构建(改自 avox 脚本, 不回写 avox 仓):
  `kit` flavor = avox minsize 白名单 + gpl(x264/x265) + **libmp3lame**,
  产物落 `third_party/ffmpeg/kit`(不进 git)。`--verify` 只扫 nonfree 红线,
  GPL 标记在本仓 AGPL 渠道合法。
- 2026-10-26: **输入来源模型**。任务统一 `source{kind:file|url, uri}`。
  本地/文件夹/NAS 都是路径(不做单独来源类型); URL 只收直链媒体
  (http(s)/m3u8/rtsp/rtmp), 不抓网页、不做登录/Cookie/DRM、不上传。
  URL 任务多一个 `fetching` 阶段。
- 2026-10-26: **ffmpeg 走运行时替换**。avox 的 CMake 写死自家
  `3rdparty/library/<os>/ffmpeg`(`CMakeLists.txt:177-183`), 无 SDK 环境变量
  可换; 打包时用本仓 kit 的同名 DLL 顶替(同为 FFmpeg 9.0.1, SONAME 槽位
  一致), 启动自检 `--enable-libmp3lame`。avox 源与产物零改动。
- 2026-10-26: **功能架构定稿**, 见 `docs/functional-architecture.md`。确立:
  功能用 ToolSpec + OptionSchema + Preset + Recipe 表达, 执行用 Task + Stage +
  Event 收口, 能力用 Capability + Model 显式化; 五个执行族
  `transcode/remux/extract/analyze/image`; pipeline 留在 shim 内部且保持线性,
  不做 DAG; 常规新功能零 ABI 变更。本文 §1/§2/§3 的早期草案以该文为准。

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

> 早期草案: ABI v1 的函数面、事件所有权(`ak_event_free`)、`ak_init(config_json)`、
> 能力探测与版本协商以 `docs/functional-architecture.md` §5 为准。

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

task_json 形状(例):
```json
{"kind":"transcode",
 "source":{"kind":"file","uri":"C:/x/a.mkv"},
 "output":"C:/x/a.mp4",
 "video":{"codec":"h264","hardware":"off","rate_mode":"quality",
          "quality":60,"resolution":"source"},
 "audio":{"codec":"aac"},
 "preset":"bilibili_1080p"}
```

kind 集合 = `transcode | remux | extract_audio | asr | trim | burn_sub | image_inpaint`。
(`trim`/`burn_sub` 依赖 avox 侧缺口, `image_inpaint` 引擎现成; 见 §5。)

### 2.1 输入来源模型

- `source.kind = file | url`; `uri` 一律 UTF-8。
- **本地文件 / 文件夹**: 标准路径。**NAS / 网络盘**本质就是路径
  (UNC `\\nas\share\x.mkv` 或挂载盘), 不做单独来源类型; 选择器允许网络
  位置, 错误区分无权限/断连。
- **URL**: 只收直链媒体——http(s) 直链、HLS(`.m3u8`)、`rtsp`、`rtmp`。
  引擎侧已支持(`IOParseFF`: HTTP 分段缓存/TLS/RTSP transport/RTMP 超时)。
  明确不支持: 视频网站页面链接(需站点解析)、登录态/Cookie、DRM、上传。
- 统一先 `ak_probe(uri)` 出时长/轨/码率/是否支持 Range; URL 任务多一个
  `fetching` 阶段, 不支持 Range 时先下载到临时目录再处理。
- 任务 JSON 不区分 UI 来源; shim 按 scheme 判定。任务卡显示来源徽标
  (本地/网络/链接)。

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
| 网络直链输入 | IOParseFF: HTTP 分段缓存/TLS/HLS/RTSP/RTMP | `src/avox_ffmpeg/IOParseFF.cpp` |
| 输出参数面 | quality/cbr/vbr/gop/profile/分辨率/音频重采样 | `src/avox/AvoxMuxer.h:132-196` |
| 硬编 | 平台硬编默认开启(mf/qsv/amf/nvenc/vaapi/videotoolbox), 软编 x264/x265 | `src/avox_ffmpeg/encoder/FFVEncoder.cpp:196,393` |
| 无损 remux | StreamRecorder(createRecorder(false)) | `src/avox/muxer/StreamRecorder.hpp` |
| 轨级直拷(换/抽音轨不重编) | TransMode AudioCopy/VideoCopy | `src/avox/AvoxMuxer.h:219-228` |
| 提取音频 | AudioTap + FFResample + WavSave + AAC; mp3 待补 | `src/avox/audio/AudioTap.hpp` 等 |
| 本地字幕生成 | AudioStt(sherpa-onnx SenseVoice)→SubtitleAsr | `src/avox/audio/AudioStt.cpp`; `src/avox/subtitle/SubtitleAsr.hpp` |
| 图片去水印 | IWatermarkRemoval: 自动检测 / 框选 region / mask 修复; LaMa·AOT-GAN·分块; GPU | `plugins/avox_cv/inpaint/`; 用法见 `src/avox_cmd/doc/doc_inpaint.md` |
| 抽帧/封面 | screenShot → JPEG/PNG/BMP/TGA | `src/avox/video/ImageIO.cpp:131` |
| 硬编探测 | 真编 3 帧验证(panvox 有先例 `pvx_encoder_probe`, 本仓重写) | 思路见 panvox_c_api.h:607(仅参考) |
| 文件探测 | IoPlan/白名单按 probe 打开 | `src/avox_ffmpeg/IOParseFF.cpp` |

## 5. 引擎缺口清单(**全部归 avox 仓做**, 本仓只挂依赖)

按里程碑排序:

1. ~~**libmp3lame**~~(本仓已解决): `script/ffmpeg/build_ffmpeg.py` 的
   `kit` flavor 已加 libmp3lame + mp3/wav muxer, 产物 `third_party/ffmpeg/kit`;
   avox 仓源码与其编译脚本零改动。
2. **无损剪切成品 API**(M4): 关键帧对齐区间导出; 零件=StreamRecorder 的
   seek+remux。顺带**无损合并**(全仓现无 concat 实现)。
3. **字幕轨导出**(M3 后): SrtParser 补写出(SrtParser.hpp:13-19 只有 parse)。
4. **离线字幕烧录**(M5 后): TranscodeRecorder 挂字幕模块(渲染三层已齐:
   libass 插件 + FreeType + PGS 解码, 差接线)。
5. (后置) GIF/WebP 编码器; 旋转/裁剪的录制链开关(VkTransposeLayer/
   VkResizeLayer 包一层 IRecordVideoFilter)。

注意: ffmpeg 显式禁了 avfilter/swscale(`build_ffmpeg.py:61-62`), 不能借
filtergraph 补能力——上述都走引擎自有链。

**图片去水印不是引擎缺口**: `avox_cv` 的 IWatermarkRemoval 已现成
(detect / region / mask / GPU, LaMa·AOT-GAN·Tiled)。本仓缺的只是
`ak_*` 暴露(kind `image_inpaint`)与 onnx 模型分发口径(与字幕模型同机制)。
视频去水印走同一能力逐帧处理, 慢, 后置。

## 6. 构建配方

- **ffmpeg**: 本仓 `script/ffmpeg/build_ffmpeg.py`(`kit` flavor =
  avox minsize 白名单 + gpl + libmp3lame), 产物 `third_party/ffmpeg/kit`。
  avox 的 CMake 写死 `3rdparty/library/<os>/ffmpeg`, 没有 SDK 环境变量可换,
  所以采用**运行时替换**: 打包只带 kit 的 `avcodec-63 / avformat-63 /
  avutil-61 / swresample-7` 与依赖 DLL, 不带 avox `3rdparty` 的 ffmpeg;
  版本同为 FFmpeg 9.0.1, SONAME 槽位一致。
  启动自检: `avcodec_configuration()` 必须含 `--enable-libmp3lame`,
  否则拒绝启动(防装错 DLL)。不写 avox 3rdparty、不改 avox CMake。
  依赖 MSYS2 `mingw-w64-x86_64-libx264/x265/lame/vulkan-headers`
  (`--check-deps` 自检; **x264 元包勿装**, 会拖入 ffmpeg 全家)。
  出厂前 `--verify` 只扫 nonfree/fdk-aac; GPL 标记在 AGPL 渠道合法。
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
| M1 | avox 链接打通; 第一条 transcode 任务(本地文件→输出, 进度/取消)全链跑通; 队列 v0(并发 1); NAS 路径天然支持 | Windows 先行 |
| M2 | remux + 提取音频; URL 直链输入(直链/m3u8/rtsp/rtmp) | 本仓 ffmpeg kit |
| M3 | 本地字幕生成(avox_sherpa + 模型分发口径: 首用下载/便携包) | avox_sherpa |
| M3.5 | 图片工具 v0: 去水印(自动检测/框选/mask); 模型分发复用 M3 机制 | avox_cv(现成) |
| M4 | 无损剪切 + 批量队列成形 | avox#2 |
| M5 | 三端打包(安装/便携) + 落地页 + Show HN(归 panvox-site) | avox#3–4 后置 |

## 8. 引流闭环(产品层, 不进代码逻辑)

工具内唯一出口: 「关于」页 Powered by avox(GitHub 链接) + Panvox 推荐位;
不做弹窗不做常驻横幅。落地页/发文/Show HN 稿全部归 panvox-site 仓运营。
