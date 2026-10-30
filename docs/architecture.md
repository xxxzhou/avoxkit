# avoxkit 架构(2026-10-26 定稿)

> 本文是技术底稿: 分层决策、任务模型、`ak_*` C ABI 草案、功能→引擎映射、
> 引擎缺口清单(归 avox 仓)、构建配方。部分设计尚未实现；当前用户功能与边界
> 以 `docs/features.md` 为准。

## 0. 决策记录

- 2026-10-26: **独立仓库**, AGPL-3.0(与 avox 同源, GPL 家族, x264/x265 走
  gpl flavor 合法)。**不走 avox_cli 路线**——CLI 只当引擎调用面的示范样本;
  产品有自己的 GUI, 直接调 avox C++ API。**不复用任何私有 shim 代码**,
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
  Event 收口, 能力用 Capability + Model 显式化; 当前执行族
  `transcode/remux/extract/subtitle/trim/image`, `analyze` 预留; pipeline 留在
  shim 内部且保持线性, 不做 DAG; 常规新功能零 ABI 变更。本文 §1/§2/§3 的早期
  草案以该文为准。

## 1. 总体分层

```
┌─ Flutter 桌面壳(avoxkit UI, 当前发布 Windows；三端结构预留)
│    任务列表 + 参数表单 + 进度; 不出现多轨剪辑时间线, 截取页只有区间尺
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

与 avox 的分层模式是「Flutter + FFI + C shim + 引擎」；本仓代码自建。
avox 没有官方 C 导出层, 因此本仓 native 层负责任务/事件/参数边界。

## 2. `ak_*` C ABI(v1，当前 minor 9)

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
//   event_json: {type: progress|state|wave|error|done, task_id, ...}
//   queued 的 state 事件带 queue_position(1 起); wave 带 pts_ms/bucket_ms/peaks[]
typedef void (*ak_event_cb)(const char* event_json, void* user);
int         ak_set_event_cb(ak_event_cb cb, void* user);

// 探测(表单要用)
const char* ak_probe(const char* input_path);        // 时长/轨/编解码器摘要
// 只读索引(v1.4): 音频包络峰值 + 视频关键帧时间, 供截取时间线;
// buckets 64-4000, 返回 {ok,duration_ms,bucket_ms,has_audio,peaks,keyframes_ms}
const char* ak_media_index(const char* input_path, int32_t buckets);
// 参考帧/缩略图(v1.5): 按时间 backward seek 抓帧, 采样缩放后出 JPEG base64;
// request = {count|times_ms, width, quality},
// 返回 {ok,duration_ms,has_video,width,height,frames:[{ms,image}]}
const char* ak_media_frames(const char* input_path, const char* request_json);
int         ak_encoder_probe(const char* codec);      // 编码器注册检查；真编验证未实现

// 原生窗口直显预览(v1.2, Windows): 窗口归页面, 绑定归当前可见任务;
// 只有录制中的任务显示原生窗, 排队/终态保持隐藏。其余平台 not_implemented。
int         ak_preview_set_host(void* host_hwnd);
int         ak_preview_open(void);
int         ak_preview_bind(int64_t task_id);
int         ak_preview_unbind(void);
int         ak_preview_rect(double x, double y, double w, double h);
int         ak_preview_close(void);

// 录屏会话(v1.7): 多输入=多文件; 停止只落盘, 收尾单独调用(v1.9)
const char* ak_capture_devices_json(void);
const char* ak_capture_start(const char* request_json);
const char* ak_capture_status(int64_t session_id);
int         ak_capture_pause(int64_t session_id);
int         ak_capture_resume(int64_t session_id);
// 会话状态在 native 内, 必须由创建会话的线程/isolate 调; 只回填 WAV/写 session.json
const char* ak_capture_stop(int64_t session_id);
// 收尾已停止目录(只读文件, 任意 isolate 可调): 混音 + remux + project.json
const char* ak_capture_finalize(const char* request_json);

// 录屏工程(v1.8): 场景包装 + 裁剪区间 + 导出 MP4
const char* ak_project_open(const char* request_json);
const char* ak_project_set(int64_t project_id, const char* patch_json);
const char* ak_project_export(int64_t project_id, const char* request_json);
const char* ak_project_status(int64_t project_id);
void        ak_project_close(int64_t project_id);
```

> 预览接/摘视口 = `setSurface(hwnd)` / `setOffSurface(yuv)`: WindowRender 拿到
> 窗口时自动启动呈现线程, 摘掉后循环继续消费、处理不停。宿主不需要开停接口。

task_json 形状(例):
```json
{"schema":1, "kind":"transcode",
 "sources":[{"kind":"file","uri":"C:/media/input.mkv"}],
 "outputs":[{"role":"primary","path":"C:/media/output.mp4"}],
 "params":{
   "container":"mp4",
   "trans_mode":"audio_copy",
   "video":{"codec":"hevc","width":1280,"height":720,
            "hardware":"off","rate_mode":"quality","quality":60},
   "audio":{"codec":"aac","bitrate_kbps":-1}}}
```

当前 kind 集合 = `transcode | remux | extract | subtitle | trim | image`；
`analyze` 尚未实现，URL 输入尚未在 UI 开放。

> `trim`(2026-10-28 已落地): 复用 TranscodeRecorder; 开录前 `io.startFrac`
> 定位到起点前最近关键帧, `params.trim.start_ms/end_ms` 由 shim 校验, 到出点
> 主动 close(非排空)截断。**这是重新编码的片段截取, 不是无损剪切**;
> 无损剪切仍等 avox M4 的 StreamRecorder seek+remux 成品 API。

**kind 由转换页逐文件判定后提交**, 用户只选输出目标:
- 视频/音频都直拷且容器变化 → `remux`;
- 其余 → `transcode`, `trans_mode` 三选一(`all` / `audio_copy` / `video_copy`);
- `video.width/height` 只在需要缩放时出现, shim 转 `IRecorder::setVideoDesc`;
- 容器装不下的音频编码由 `AudioCopy` 的 `audioCopySupported` 回退转码;
  `remux` 全直拷没有回退, 因此判定在提交前完成。

### 2.1 输入来源模型

- `source.kind = file | url`; `uri` 一律 UTF-8。
- **本地文件 / 文件夹**: 标准路径。**NAS / 网络盘**本质就是路径
  (UNC `\\nas\share\x.mkv` 或挂载盘), 不做单独来源类型; 选择器允许网络
  位置, 错误区分无权限/断连。
- **URL**: 只收直链媒体——http(s) 直链、HLS(`.m3u8`)、`rtsp`、`rtmp`。
  引擎侧已支持(`IOParseFF`: HTTP 分段缓存/TLS/RTSP transport/RTMP 超时)。
  明确不支持: 视频网站页面链接(需站点解析)、登录态/Cookie、DRM、上传。
  当前 UI 尚未开放 URL 输入，以下为预留模型。
- 统一先 `ak_probe(uri)` 出时长/轨/码率/是否支持 Range; URL 任务多一个
  `fetching` 阶段, 不支持 Range 时先下载到临时目录再处理。
- 任务 JSON 不区分 UI 来源; shim 按 scheme 判定。当前任务卡显示文件名与状态；
  来源徽标预留。

## 3. 任务模型与队列

- 引擎对象级并发天然可用(每个 IRecorder 独立实例), 但引擎**没有**队列/
  上限/重试框架——全部在本仓 shim 层建: 一个优先级队列 + 并发闸
  (当前固定 1 个转码任务) + 失败重试(预留)。
- 状态机: `queued → running → done | failed | cancelled`; 进度事件直接透传
  引擎 RecorderProgress(currentMs/totalMs)(avox `AvoxMuxer.h:72-94`),
  百分比由 UI 算；ETA 预留。
- 取消走引擎 close 排空语义(`TranscodeRecorder.hpp:121-128`), 不杀线程。

## 4. 功能 → 引擎映射(现成, 引用 avox 仓内路径)

> 下表是引擎能力映射，不代表当前 UI 已开放；当前可用功能与边界见
> `docs/features.md`。

| 功能 | 引擎现状 | 位置(avox) |
|---|---|---|
| 格式转换/编码调整 | TranscodeRecorder: 解码→Vulkan 处理→重编码→封装 | `src/avox/muxer/TranscodeRecorder.hpp` |
| 片段截取 | TranscodeRecorder + io.startFrac(关键帧起点) + 到点 close | 同上; 终点随解码/封装的排队深度有 ±0.5s 误差 |
| 媒体索引(时间线) | IMediaReader buildIndex: 一趟 demux, 音频峰值(线性 [0,1])+关键帧 ms | avox `MediaReaderFF`; shim `src/ak_index.cpp` 只做 sqrt→0-100 换算 |
| 参考帧/缩略图 | IMediaReader grabFrame: 软件解码 + VK 离屏渲染(缩放/HDR→SDR/竖拍转置) + avox stb JPEG 出口 | avox `MediaReaderFF`/`MediaThumbRenderer`; shim `src/ak_frames.cpp` 只算目标时刻并编码; 无 Vulkan 回 `renderUnavailable`, 不兜底 |
| 网络直链输入 | IOParseFF: HTTP 分段缓存/TLS/HLS/RTSP/RTMP | `src/avox_ffmpeg/IOParseFF.cpp` |
| 录屏采集 | CaptureSession: 多路设备→多文件 + 会话时钟 + session.json; WGC/GDI(Win) / ScreenCaptureKit(mac) | `src/avox/player/CaptureSession.hpp`; `src/avox_windows/winrt/CaptureWindows.cpp` |
| 录屏包装导出 | TranscodeRecorder + VkSceneLayer + IEditorScene: 背景/留白/圆角/阴影/比例 + 光标精灵 | `src/avox_vulkan/layer/VkSceneLayer.*`; `src/avox/player/EditorScene.*` |
| 录屏混音/封装 | avox `IMediaComposer`: WAV 自解析 + swr 混音 + AAC + 流直拷 remux | `src/avox_ffmpeg/MediaComposerFF.cpp`; 本仓 `native/avtool/src/ak_media_audio.cpp` 只是薄壳 |
| 输出参数面 | quality/cbr/vbr/gop/profile/分辨率(setVideoDesc)/音频重采样 | `src/avox/AvoxMuxer.h:132-196` |
| 硬编 | 平台硬编可用(mf/qsv/amf/nvenc/vaapi/videotoolbox), 软编 x264/x265；产品默认软编, 硬编需显式开启 | `src/avox_ffmpeg/encoder/FFVEncoder.cpp:196,393` |
| 无损 remux | StreamRecorder(createRecorder(false)) | `src/avox/muxer/StreamRecorder.hpp` |
| 轨级直拷(换/抽音轨不重编) | TransMode AudioCopy/VideoCopy | `src/avox/AvoxMuxer.h:219-228` |
| 提取音频 | AudioTap + FFResample + WavSave + AAC/MP3 | `src/avox/audio/AudioTap.hpp` 等 |
| 本地字幕生成 | AudioStt(sherpa-onnx SenseVoice)→SubtitleAsr | `src/avox/audio/AudioStt.cpp`; `src/avox/subtitle/SubtitleAsr.hpp` |
| 内嵌字幕提取 | SubtitleExport: 解文本字幕包→SRT(ASS/SubRip 字段归一) | `src/avox/subtitle/SubtitleExport.cpp` |
| 识别生成字幕 | IAudioStt + Recorder AudioTap → ISrtWriter | `plugins/avox_sherpa`; `src/avox/audio/AudioStt.cpp` |
| 图片去水印 | IWatermarkRemoval: 自动检测 / 框选 region / mask 修复; LaMa·AOT-GAN·分块; GPU | `plugins/avox_cv/inpaint/`; 用法见 `src/avox_cmd/doc/doc_inpaint.md` |
| 抽帧/封面 | screenShot → JPEG/PNG/BMP/TGA | `src/avox/video/ImageIO.cpp:131` |
| 硬编探测 | 编码器注册检查；真编验证未实现 | avox `AvoxRuntime::isEncoderRegistered`; 本仓 `ak_encoder_probe` |
| 文件探测 | IMediaReader open(ISourceInfo 列轨, 跳过封面图流) | avox `MediaReaderFF`; shim `src/ak_probe.cpp` |
| 运行时能力 | FFmpeg 版本/配置、编码器/封装器/协议、Vulkan 可用性 | avox `AvoxRuntime.h`; 本仓 `ak_engine.cpp` 自检与能力页 |

### 4.0.1 参考帧抓取(2026-10-30 切 avox grabFrame)

- `ak_media_frames` 走 avox `IMediaReader::grabFrame`: 一次 open, 对每个请求时间
  seek 到关键帧、向后解码到该时刻, 返回**实际帧时间**(不假装精确到请求值)。
- 出图走 `MediaThumbRenderer`(`SurfaceRenderVk` 的 enableImage 分支): GPU 缩放、
  HDR→SDR tone map、竖拍转置都在 avox 内完成; shim 只拿 `MediaFrameInfo` +
  `IImageBuffer`, 用 avox `getImageBase64`(stb JPEG) 编码。
- 无 Vulkan 回 `renderUnavailable`, 不做 CPU 兜底; UI 按
  `MediaFrames.unavailableHint` 显示「Vulkan 组件未启用，缩略图/画面预览不可用」。
- 无视频轨/不支持的像素格式返回 `frames:[]` + `reason`, 时间线退化为波形刻度。
- Dart 在 isolate 里调用; `getImageBase64` 用进程级 static 缓冲, 缩略图与精确帧
  并发编码时取串与拷贝必须在锁内。

### 4.1 字幕任务(2026-10-27)

- `kind=subtitle`: `params.subtitle.mode = auto|embedded|asr`;
  `stream_index` 用 probe 返回的容器 stream index; `allow_asr` 只在 `auto`
  没有文本轨时决定是否兜底。
- **内嵌**: `avox::exportSubtitleTrack` 解文本字幕包
  (SubRip/ASS/SSA/mov_text/WebVTT 等)写 SRT; PGS/DVD/DVB 位图返回 -3,
  UI 引导改用语音识别。SRT 写出走 `avox::ISrtWriter` 虚接口, 不跨 ABI
  传结构体数组。
- **识别**: TranscodeRecorder(video=none, audio=16k mono AAC 旁路) +
  AudioTap(16k/mono/S16) → `IAudioStt`(sherpa, offline) → `ISrtWriter`;
  音频旁路产物完成后删除, 只留 SRT。
- **模型**: 不随包。Dart `ModelStore` 在用户真正点识别时才下载
  SenseVoice + Silero VAD 到 `<app support>/models/stt/sense-voice/`,
  校验 sha256; `ak_init.models_dir` → `avox::setModelsRoot`。
- **插件**: `avox_sherpa.dll + sherpa-onnx-c-api.dll + onnxruntime.dll`
  随包放 `plugins/`; 模型目录不随包。

## 5. 引擎缺口清单(**全部归 avox 仓做**, 本仓只挂依赖)

按里程碑排序:

1. ~~**libmp3lame**~~(本仓已解决): `script/ffmpeg/build_ffmpeg.py` 的
   `kit` flavor 已加 libmp3lame + mp3/wav muxer, 产物 `third_party/ffmpeg/kit`;
   avox 仓源码与其编译脚本零改动。
2. **无损剪切成品 API**(M4): 关键帧对齐区间导出; 零件=StreamRecorder 的
   seek+remux。顺带**无损合并**(全仓现无 concat 实现)。
3. ~~**字幕轨导出**~~(本仓已解决): avox 新增 `AvoxSubtitle.h`
   (`exportSubtitleTrack` / `ISrtWriter` / `isTextSubtitleCodec`), 文本轨
   可导出 SRT; 位图字幕不做 OCR。
4. **离线字幕烧录**(M5 后): TranscodeRecorder 挂字幕模块(渲染三层已齐:
   libass 插件 + FreeType + PGS 解码, 差接线)。
5. (后置) GIF/WebP 编码器; 旋转/裁剪的录制链开关(VkTransposeLayer/
   VkResizeLayer 包一层 IRecordVideoFilter)。

注意: ffmpeg 显式禁了 avfilter/swscale(`build_ffmpeg.py:61-62`), 不能借
filtergraph 补能力——上述都走引擎自有链。

**图片去水印已落地**(2026-10-29): `avox_cv` 的 IWatermarkRemoval 现成
(detect / region / mask, LaMa·AOT-GAN·Tiled)。本仓通过 kind `image` 暴露,
手绘 mask 由 Flutter 生成 PNG、`ak_image_detect` 供自动识别预览; 模型按需
下载(LaMa + YOLO26-Seg, 约 290MB)。avox 补了 `createWatermarkRemoval()`
公共导出, 本仓不绕过公共头。视频去水印走同一能力逐帧处理, 慢, 后置。

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
- **shim**: `native/avtool/`(C++17), 当前只有 Windows 实现; 产物
  `avoxkit_native`; Dart 侧 `lib/native/` 用 ffi 生成式绑定手写
  (任务面小, 不上 ffigen)。macOS 移植见 `docs/macos-porting.md`。
- **Flutter**: 使用本机安装的 Flutter SDK（不在 PATH 时显式指定路径）；
  `flutter run --release` 为默认运行口径。

## 7. 当前状态

- 已完成: 单文件/文件夹转换、封装、提取音频、提取字幕（内嵌 + 本地识别）、
  片段截取、图像修复、任务队列、Windows 原生预览、录屏与工程导出
  （背景/留白/圆角/阴影 + 光标重绘）。
- 未完成: 无损剪切/合并、URL 输入、字幕翻译/烧录、录屏工程编辑器/自动缩放/
  摄像头画中画、三端打包。
- 用户功能与边界以 `docs/features.md` 为准；本文其余章节描述技术分层与后续扩展。

## 8. 关于页

只展示产品事实、开源引擎署名和版本信息；不做弹窗或常驻推广。
