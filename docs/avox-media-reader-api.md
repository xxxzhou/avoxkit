# avox 只读媒体接口设计（IMediaReader）

状态：**avox 侧 P0/P1/P2 已落地**（`AvoxMedia.h`/`AvoxRuntime.h`/
`MediaReaderFF` + `avox/video/MediaThumbRenderer`，open/probe/index/grabFrame
全可用；抓帧走 Vulkan 离屏，无 Vulkan 回 `renderUnavailable`，不兜底 CPU）。
avoxkit 侧 `ak_probe`/`ak_index`/`ak_frames`/`ak_engine` 已全部切到新接口；
录屏混音/封装改走 `IMediaComposer`（`avox/AvoxCapture.h`），本仓已无任何
libav include，CMake 摘掉了 avformat/avcodec/avutil/swresample 链接。
以 avox 仓 `src/avox/AvoxMedia.h` 为最终接口口径，本文保留设计过程与决策记录。

目标：把 avoxkit 里直连 FFmpeg 的探测、索引、抓帧收回 avox，
让产品侧只保留一套媒体读取路径。

## 1. 背景

迁移前 avoxkit 的 `native/avtool` 有三处直接使用 libav（现已全部收回；
录屏混音模块 `ak_media_audio.cpp` 后来也切到了 avox `IMediaComposer`，不在本文范围）：

| 模块 | 现在做什么 | 直接依赖 |
|---|---|---|
| `ak_probe.cpp` | 打开容器，枚举音视频/字幕轨、时长、码率、可 seek | libavformat/libavcodec/libavutil |
| `ak_index.cpp` | 一次 demux，解音频算整片峰值，收集视频关键帧 | libavformat/libavcodec/libavutil |
| `ak_frames.cpp` | 按时间点 seek 到关键帧、向后解码、YUV 采样缩放成 RGBA、JPEG 编码 | libavformat/libavcodec/libavutil + avox 图片编码 |
| `ak_engine.cpp` | 启动自检、编码器/封装器/协议能力探测 | libavcodec/libavformat/libavutil |

任务执行链（转换、直拷、提取、截取、字幕导出、ASR）已经在走 avox 的
`IRecorder`/`exportSubtitleTrack`/`createAudioStt`，不属于本次范围。

这些 libav 调用集中在一个很窄的只读场景：打开容器、读轨信息、解音频算包络、取关键帧、
抓参考帧。avox 现有公共接口没有对应能力，所以当时落在 shim。现在把它们变成 avox 的
一个公共只读接口，产品侧不再保留第二套 demux/decode 代码。

## 2. 需要的能力

### 2.1 探测（ak_probe）

输入一个本地路径或 URL，输出：

- 容器格式名（如 `mov,mp4,m4a,3gp,3g2,mj2`）、总时长、总码率、是否可 seek。
- 视频轨：真实视频轨（跳过 `AV_DISPOSITION_ATTACHED_PIC` 封面图）、流索引、编码
  （h264/h265/…）、编码宽高、帧率。
- 音频轨：流索引、编码（aac/mp3/…）、声道数、采样率。
- 字幕轨：流索引、编码名、语言、标题、是否默认、是否强制、是否文本字幕。

当前 UI 实际消费的字段：`format`、`duration_ms`、视频 `codec/width/height/fps`、
音频 `codec`、字幕 `index/codec/language/title/text/default/forced`。
显示方向由抓帧出口保证，probe 不需要 `rotation/display_*` 字段；如果 avox 想加
诊断字段可以加，但 avoxkit UI 不依赖。
每轨码率、像素格式/采样格式目前没有消费者，可以不进新接口。

### 2.2 时间线索引（ak_media_index）

一次 demux，同时产出：

- 音频包络：把整片时长均分成 `buckets`（64–4000，UI 用 1400）个桶，每桶一个峰值。
- 视频关键帧：第一条可用视频轨的 `AV_PKT_FLAG_KEY` 时间戳，单位毫秒，单调递增。
- 有效时长与 `bucketMs`：容器时长为 0 时用音频末帧时间推算。
- 无音轨时峰值数组为空；无视频轨时关键帧数组为空。

时间线选点依赖关键帧列表，所以这一项必须一次扫描同时产出，不能拆成两次解码。

### 2.3 参考帧/缩略图（ak_media_frames）

输入：时间点（单个或一组等距采样）、目标宽度（48–1280）、视频轨。

输出每帧：

- 请求时间、实际解码帧时间（可能晚于请求，因为是从前一个关键帧向后解）。
- 显示宽高（已按 display matrix 旋正）。
- RGBA8 图像（调用方再决定 JPEG/PNG 编码与质量）。

必须保留的细节：

- `av_seek_frame(BACKWARD)` 到目标前关键帧，再向后解码到目标时间。
- 旋转 90/180/270 按 display matrix。
- `width` 是**旋转后的显示宽度**，高度按显示比例算，不是编码宽高比。典型例子：
  编码 1920×1080、rotation=90 的竖拍视频，显示尺寸 1080×1920；请求 width=320
  时输出 **320×569**，不是 320×180。UI 必须按这个宽高比排版，不能套 16:9。
- YUV 8/10/12bit、420/422/444、NV12/P010 等格式直接在采样时缩放到目标宽度，
  不生成全尺寸 RGBA 中间图。
- 色彩矩阵按 `colorspace`（BT.601/709/2020）与 `color_range`（full/limited），
  未标注时按分辨率猜 709。
- 单次抓帧的包数/时间上限（防止坏文件卡死）。
- 无视频轨、不支持的像素格式返回明确错误。

HDR（PQ/HLG）v1 仍按 SDR 近似处理，不在本次接口里做 tone mapping；后续可以接 avox
的色彩管线，接口不变。

### 2.4 运行时能力（ak_engine / ak_capabilities_json / ak_encoder_probe）

为了把 `ak_engine.cpp` 里的 libav 也去掉，avox 需要暴露：

- FFmpeg 版本串、`avcodec/avformat/avutil` 版本号、编译配置串。
- 编码器是否注册（`libx264`、`libx265`、`aac`、`libmp3lame`、`h264_mf`、`hevc_mf` 等）。
- 封装器是否可用（mp4/matroska/mp3/wav）。
- 输入/输出协议名列表（用于能力页展示）。
- 编译配置里是否含某个 flag（如 `--enable-libmp3lame`）可由配置串自行判断。

这里的“编码器探测”仍然只检查注册，不做真实编码验证，语义与现在的 `ak_encoder_probe`
一致。

## 3. 公共接口草案

新增 `src/avox/AvoxMedia.h`：

```cpp
#pragma once

#include "AvoxDef.h"
#include "AvoxImage.h"
#include "AvoxSource.h"  // ISourceInfo / VTrackDesc / ATrackDesc / ISTrackDesc

namespace avox {

struct MediaIndexOptions {
  // 音频峰值桶数 [64, 4000]
  int32_t buckets = 1200;
  // 局部轨序号; -1 = 第一条可用轨
  int32_t audioTrack = -1;
  int32_t videoTrack = -1;
};

struct MediaFrameRequest {
  // 目标时间(ms); 超出片长按片尾处理
  int64_t timeMs = 0;
  // 输出宽度 [48, 1920]; 高度按显示比例
  int32_t width = 320;
  // 局部轨序号; -1 = 第一条可用轨
  int32_t videoTrack = -1;
};

struct MediaFrameInfo {
  int64_t requestedMs = 0;
  // 实际解码帧时间, 可能晚于请求(从关键帧向后解)
  int64_t actualMs = 0;
  // 显示尺寸(已按 display matrix 旋正)
  int32_t width = 0;
  int32_t height = 0;
};

enum class MediaError : int32_t {
  none = 0,
  inputOpenFailed = 1,
  noVideo = 2,
  noAudio = 3,
  decoderMissing = 4,
  seekFailed = 5,
  decodeFailed = 6,
  unsupported = 7,
  cancelled = 8,
  renderUnavailable = 9,
  invalidState = 10,
  other = 100,
};

enum class MediaReaderState : int32_t {
  idle = 0,
  opening,
  ready,
  indexing,
  grabbing,
  closing,
  closed,
};

enum class MediaOp : int32_t {
  open = 0,
  index,
  frame,
  close,
};

struct MediaIndexResult {
  int64_t durationMs = 0;
  int32_t bucketMs = 0;
  // 线性幅度 [0,1]; 只在 onIndexDone 回调内有效, 需要留存请拷贝
  const float* peaks = nullptr;
  int32_t peakCount = 0;
  // 毫秒时间戳, 单调递增; 只在 onIndexDone 回调内有效
  const int64_t* keyframesMs = nullptr;
  int32_t keyframeCount = 0;
};

class IMediaReaderOb {
 public:
  virtual ~IMediaReaderOb() = default;

  // 状态迁移; 所有回调串行, 不并发
  virtual void onStateChange(MediaReaderState pre, MediaReaderState state) {}

  // open 成功; ISourceInfo 从这一刻起有效
  virtual void onReady() {}

  // buildIndex 进度 0-100
  virtual void onIndexProgress(int32_t percent) {}

  // buildIndex 完成; peaks/keyframesMs 只在回调内有效
  virtual void onIndexDone(const MediaIndexResult& result) {}

  // grabFrame 完成; image 只在回调内有效, 需要留存请拷贝
  virtual void onFrame(const MediaFrameInfo& info, IImageBuffer* image) {}

  // op 指明阶段; 回调后 reader 回到可用状态(open 失败回 idle)
  virtual void onError(MediaOp op, MediaError code, const char* message) {}

  // close 完成
  virtual void onClose() {}
};

// 只读媒体读取器: 一次 open, 探测/索引/抓帧复用同一个容器上下文。
// 结果只经 observer 回调; 返回值只表示请求是否被接受。
// open/buildIndex/grabFrame/close 由调用方串行调用; cancel() 可跨线程。
class IMediaReader {
 public:
  virtual ~IMediaReader() = default;

  // 必须在 open 前设置; observer 生命周期覆盖到 close 返回
  virtual void setObserver(IMediaReaderOb* ob) = 0;

  // 返回 false = 请求未被接受(状态不对/参数非法); 结果经 onReady/onError
  virtual bool open(const char* uri) = 0;
  // 返回 false = 状态不对/参数非法; 结果经 onIndexProgress/onIndexDone/onError
  virtual bool buildIndex(const MediaIndexOptions& options) = 0;
  // 返回 false = 状态不对/参数非法; 结果经 onFrame/onError
  virtual bool grabFrame(const MediaFrameRequest& request) = 0;

  // 线程安全: 取消当前 open/index/frame, 经 onError(op, cancelled) 收尾
  virtual void cancel() = 0;
  // 同步关闭; 等待工作线程退出, 返回后不再回调, 调用方随后 delete
  virtual void close() = 0;

  // onReady 后有效, close 前; reader 托管
  virtual ISourceInfo* getSourceInfo() = 0;

  virtual MediaError lastError() = 0;
  // reader 托管, 下一次操作/close 前有效
  virtual const char* lastErrorMessage() = 0;
};

AVOX_EXPORT IMediaReader* createMediaReader();

}  // namespace avox
```

新增 `src/avox/AvoxRuntime.h`：

```cpp
#pragma once

#include "AvoxDef.h"

namespace avox {

struct FFmpegRuntimeInfo {
  const char* version = nullptr;      // av_version_info(), engine 托管
  const char* buildConfig = nullptr;  // avcodec_configuration(), engine 托管
  int32_t avcodecVersion = 0;
  int32_t avformatVersion = 0;
  int32_t avutilVersion = 0;
};

AVOX_EXPORT FFmpegRuntimeInfo getFFmpegRuntimeInfo();
// 只查编码器是否注册, 不做真编
AVOX_EXPORT bool isEncoderRegistered(const char* name);
AVOX_EXPORT bool hasMuxer(const char* name);
// 输入/输出协议名, engine 托管
AVOX_EXPORT int32_t getProtocolCount(bool output);
AVOX_EXPORT const char* getProtocolName(bool output, int32_t index);
// 抓帧所需的 Vulkan 渲染链是否可用
AVOX_EXPORT bool isVulkanAvailable();

}  // namespace avox
```

`ISourceInfo`（`AvoxSource.h`）追加以下只读方法，只追加到末尾；`canSeek()` 已存在，
不再重复：

```cpp
// 容器总时长(ms); 未知/直播为 0
virtual int64_t durationMs() { return 0; }
// 容器总码率; 未知为 0
virtual int64_t bitRate() { return 0; }
// 容器格式名(avformat iformat name); 未知为空串
virtual const char* formatName() { return ""; }
```

display matrix 旋转只在 reader 内部处理：抓帧出口直接给显示方向的 JPEG 和显示宽高，
不通过 `ISourceInfo` 暴露 rotation，avoxkit 也不读、不二次旋转。

`AVSource` 覆盖 `durationMs()`（复用 `duration()`）；`IOParseFF` 覆盖 `bitRate()`/
`formatName()`（读 `fmtCtx`）；`RawSource` 用默认值。`IMediaReader` 只返回
`ISourceInfo*`，不再单独定义 `MediaInfo`/`formatName()`。

`ISTrackDesc`（`AvoxCodec.h`）追加两个只读方法，只追加、不插到中间：

```cpp
// 原始 avcodec 名(如 "subrip"/"hdmv_pgs_subtitle"/"webvtt"), 生命周期同本对象
virtual const char* codecName() const { return ""; }
// 容器默认轨
virtual bool isDefault() const { return false; }
```

`STrackDescImpl` 内部补上对应字段；`text` 判定继续用已有的公共函数
`avox::isTextSubtitleCodec(codecName)`，不新增冗余字段。

## 4. 行为约定

- **所有权**：`createMediaReader()` 返回的对象由调用方 `close()` 后 `delete`，
  与 `createMediaPlayer()`/`createRecorder()` 一致。
- **线程/回调**：回调串行、不并发；实现可以是同步（回调在调用线程）或内部单工作线程，
  调用方只依赖回调顺序，不依赖线程。`open/buildIndex/grabFrame/close` 由调用方串行
  调用；`cancel()` 可跨线程。
- **生命周期**：`idle -> opening -> ready`；`ready` 后可反复 `buildIndex`/`grabFrame`，
  各自走 `ready -> indexing/grabbing -> ready`。open 失败回 `idle`，index/frame 失败
  回 `ready`。`close` 走 `closing -> closed`。回调顺序：状态进入 → `onReady`/
  `onIndexDone`/`onFrame` → 状态回到 `ready`；失败是 `onError` → 状态回退；
  close 是状态 `closing` → `onClose` → 状态 `closed`。
- **返回值与错误**：`open/buildIndex/grabFrame` 返回 `false` 只表示请求未被接受
  （状态不对/参数非法），此时不触发回调，读 `lastError()`；请求被接受后结果只经回调，
  失败经 `onError(op, code, message)`。`cancel()` 经
  `onError(op, cancelled)` 收尾。
- **数据生命周期**：`ISourceInfo` 在 `onReady` 后到 `close` 前有效；`onIndexDone` 的
  `peaks`/`keyframesMs`、`onFrame` 的 `image`、`onError` 的 `message` 只在回调内
  有效，需要留存请立即拷贝。
- **峰值**：`onIndexDone` 返回线性幅度 `[0,1]`，显示曲线由调用方决定。avoxkit 继续用
  `sqrt(peak)*100` 映射到 0–100，保持现有 UI 外观。
- **关键帧**：沿用 `AV_PKT_FLAG_KEY`；没有关键帧标志的容器返回空数组。
- **抓帧**：输出 RGBA8 SDR（HDR 由 VK 管线 tone map 到 SDR），已旋正；`actualMs`
  是实际解码帧时间，不假装等于请求时间。无视频轨返回 `noVideo`，不支持的像素格式
  返回 `unsupported`，无 Vulkan 返回 `renderUnavailable`。
- **抓帧渲染**：走 `SurfaceRenderVk` 的独立图像输出分支
  （`setOffSurface(YuvType::other)` + `enableImage(IImageBuffer*)` +
  `render(const YUVFrame&)`），GPU 做缩放；`enableImage` 只支持 rgba8，buffer
  生命周期必须覆盖到 `disableImage`，首次 enable/换尺寸后先渲染一张 dummy 帧让图重建
  落位（`QEnhanceFilter` 同款处理）。
- **HDR**：`setHdrMode(HdrMode::follow)` + 默认 tone map，HDR→SDR；不支持
  `forceHDR`（16f 输出，`fetchData` 也会拒绝，不适合 RGBA8 抓帧）。
- **旋转**：只处理容器 display matrix 声明的 90/180/270；0° 文件完全不动。手机竖拍
  视频的编码画面是横的，容器靠矩阵声明播放时转 90°，不转缩略图会横躺。transpose
  定稿在渲染入口一次性处理（avox `a62f0ab`），抓帧/预览直接出显示方向画面，不再
  做二次 CPU 旋转。旋转是 avox 内部语义，avoxkit 不读 rotation、不二次旋转，
  只消费回调里的 JPEG/RGBA 和 width/height。
- **Vulkan 要求**：抓帧必须走 Vulkan；无 Vulkan 返回 `renderUnavailable`，不保留
  CPU 兜底。`ak_capabilities_json` 增加 `vulkan` 字段，UI 显示
  「Vulkan 组件未启用，缩略图/画面预览不可用」；probe/index 不受影响。
- **封面图**：带 `AV_DISPOSITION_ATTACHED_PIC` 的封面流不算视频轨；probe 不列或显式
  标 `attached_pic`，索引/抓帧跳过，也不参与 rotation/aspect 计算。
- **直播/未知时长**：索引要求有限时长；直播流返回 `unsupported`，抓帧仍可按时间尝试。
- **取消/复用**：取消后 reader 可继续使用；下一次 `buildIndex`/`grabFrame` 重新开始。

## 5. avox 内实现方案

### 5.1 文件落点

- `src/avox/AvoxMedia.h`：公共接口。
- `src/avox/AvoxRuntime.h` / `AvoxRuntime.cpp`：运行时能力查询。
- `src/avox_ffmpeg/MediaReaderFF.hpp/.cpp`：`IMediaReader` 的 FFmpeg 实现与工厂。
- `src/avox/source/BaseSource.hpp`：`STrackDescImpl` 补 `codecName/isDefault`。
- 根 `CMakeLists.txt` 的 `copy_head()` 增加 `avox/AvoxMedia.h`、`avox/AvoxRuntime.h`。

### 5.2 探测

`open()` 里 `avformat_open_input` + `avformat_find_stream_info`，填 `ISourceInfo`
（`durationMs/bitRate/formatName/canSeek`）和轨道描述：

- 视频：`VTrackDesc`（codecId/width/height/fps/YuvType/colorSpace）。
- 音频：`ATrackDesc`（codecId/channels/sampleRate/AudioFormat）。
- 字幕：`STrackDescImpl`（trackId=容器 stream index、SCodecId、lang、title、
  forced、default、codecName）。
- 轨道描述由 reader 自己持有，`getSourceInfo()` 返回 `this` 或内部 `ISourceInfo`
  实现；实现里直接复用 `BaseSource` 的 desc 容器也可以，但 `canSeek` 需要单独给。

### 5.3 索引

单个 `av_read_frame` 循环：

- 视频关键包：记 `pts`（减去 stream start_time）到关键帧数组。
- 音频包：送解码器，每帧算峰值，按时间映射到 `buckets` 桶。
- 进度：按当前包 PTS / 总时长回调 `onIndexProgress`，每 1% 或每 N 个包一次。
- 每个包检查 `cancel` 标志。
- 结束时 `durationMs = duration > 0 ? duration : 音频末帧时间`；
  `bucketMs = max(1, duration / buckets)`。
- 结果放进 `MediaIndexResult`，通过 `onIndexDone` 回调；`peaks` 指向 reader 内部
  `std::vector<float>`，只在回调内有效。

音频解码直接用 libav（与现在 shim 一致），复用 `FFHelper` 的格式转换/错误串工具。

### 5.4 抓帧

每个 `grabFrame`：

1. 目标时间按 `origin` 换算成 stream time_base，`av_seek_frame(BACKWARD)`。
2. `avcodec_flush_buffers`，向后解码到 `pts >= target` 或包数/时间上限。
3. 把解码帧包成 `YUVFrame`（`ffYuvType` 映射 `YuvType`），填入 plane/stride。
4. 交给 `SurfaceRenderVk`：`setOffSurface(YuvType::other)`、
   `setColorSpace(stream/frame 色彩空间)`、`setHdrMode(HdrMode::follow)`，
   `enableImage` 指向 reader 内部的 RGBA buffer（目标尺寸）。
5. `render(yuvFrame)`；图内 `VkYUV2RGBALayer` 做 YUV→RGBA + HDR tone map，
   `VkResizeLayer` 缩放到 buffer 尺寸，`VkOutputLayer` 把 staging 内存引用到
   `enableImage` 的 buffer；`graph->run()` 等 fence，返回时数据已就绪。
6. reader 把内部 buffer 按 display matrix 做 90/180/270 旋转（缩图后的小图，
   CPU 成本可忽略），填 `MediaFrameInfo`，通过 `onFrame` 把借用图像交给调用方；
   调用方需要留存请在回调内拷贝。

实现要点：

- `enableImage` 之后先渲染一张 dummy 帧，让图重建和 staging 映射落位；换目标尺寸
  时同样处理。
- `enableImage` 的 buffer 生命周期必须覆盖到 `disableImage`；每帧渲染完立即拷出，
  不跨帧持有 `getPointer()`。
- `YuvType::other` 或 `getVkVideoRender(render) == nullptr` 时返回
  `unsupported`/`renderUnavailable`；不做 CPU 兜底，避免再维护一套色彩/缩放实现。
- 音频索引仍走 CPU demux/decode；只有图像转换和缩放走 VK。
- 解码先用软件解码；后续可把硬件解码帧直接喂 `GpuFrame`，接口不变。

### 5.5 运行时能力

`getFFmpegRuntimeInfo()` 直接返回 `av_version_info()`/`avcodec_configuration()`/
三个版本号；`isEncoderRegistered` 用 `avcodec_find_encoder_by_name`；`hasMuxer` 用
`av_guess_format`；协议列表用 `avio_enum_protocols`。语义与现在 `ak_engine.cpp` 的
自检/能力页一致。

### 5.6 是否复用 IOParseFF

两条路：

- **v1（已实现）**：probe/index 的 demux 用 libavformat/libavcodec，抓帧解码后用
  `SurfaceRenderVk` 做 YUV→RGBA、HDR tone map 和缩放。同步批处理，行为最容易对齐；
  实现仅本地文件（网络 URI 打开即拒绝，回 `unsupported`），HTTP 直链等网络源等 v2
  接 avox IO 路径时一并支持，不复用 avox 的 HTTP 分段缓存/代理/HLS 逻辑。
- **v2**：网络/HLS/代理成为正式需求时，把 reader 的 IO 换成 avox 的 IO 路径或抽出
  可复用的同步 demux 会话；公共接口不变。

v1 的方案仍然只有一套“产品可见”的媒体读取路径：avoxkit 不再 include/link libav，
所有能力从 avox 出；图像转换和缩放复用 avox 的 VK 管线，不再手写 CPU 采样器。
avox 内部同时存在播放/录制和批处理读取两类 FFmpeg 用法，这是引擎内部的模块分工，
不是产品侧的第二套实现。

## 6. avoxkit 迁移

shim 自己实现一个 `IMediaReaderOb`，用 `condition_variable` 把回调等成现有同步 JSON
ABI；`ak_*` 对 Flutter 仍是阻塞调用，内部只是按 `onReady/onIndexDone/onFrame/onError`
串成一次请求。

1. `ak_probe.cpp`：`createMediaReader` → `open` → 等 `onReady` → 读 `ISourceInfo`
   （时长/码率/容器名/轨道）→ 拼现有 JSON（字段名不变）。字幕 `text` 用
   `isTextSubtitleCodec(track->codecName())`。
2. `ak_index.cpp`：`createMediaReader` → `open` → 等 `onReady` → `buildIndex` →
   在 `onIndexDone` 里拷贝 `peaks`/`keyframesMs`；峰值按 `sqrt(peak)*100` 转 0–100；
   时长/`bucket_ms` 取 `MediaIndexResult`。删除全部 libav 代码。
3. `ak_frames.cpp`：`createMediaReader` → `open` → 等 `onReady` → 对每个时间
   `grabFrame`，在 `onFrame` 里用 `getImageBytes`/`getImageBase64` 编码 JPEG；
   删除手写 YUV 采样器和 libav 解码，图像转换/缩放改由 avox 的 VK 管线完成。
4. `ak_engine.cpp`：改用 `getFFmpegRuntimeInfo`/`isEncoderRegistered`/`hasMuxer`/
   协议列表/`isVulkanAvailable`；删除 libav include。
5. `native/avtool/CMakeLists.txt`：去掉 `avformat.lib`/`avcodec.lib`/`avutil.lib`/
   `swresample.lib` 的链接，只留 `avox.lib`；运行时 DLL 仍由 avox 依赖，拷贝逻辑不变。
6. `ak_capabilities_json` 增加 `vulkan` 字段；Dart 侧在抓帧返回
   `render_unavailable` 或能力里 `vulkan=false` 时显示
   「Vulkan 组件未启用，缩略图/画面预览不可用」，不再静默退化成空白。
7. `docs/architecture.md` 的“功能 → 引擎映射”改为 reader；`native/avtool/README.md`
   去掉“libavformat 直接探测”的描述。
8. 先保持 `ak_*` JSON/ABI 不变，Flutter 侧零改动；后续如果要把缩略图条和精确帧合并成
   一个长生命周期 reader，再在 shim 增加 handle API，不在本次范围。

### 6.1 9:16 / 显示宽高比（avoxkit UI）

原则：avox 出什么就用什么。抓帧回调里的 JPEG/RGBA 已经是显示方向，
`MediaFrames.width/height` 是显示宽高；avoxkit 不读 rotation、不交换宽高、不二次旋转。

- 预览窗口（`AkFramePreview`、`AkLivePreview`、clip_page 参考图槽）保持 16:9 +
  `BoxFit.contain`；9:16 素材出现左右黑边是正常行为，不为它改窗口比例。
- 只有时间线缩略图条需要按 `MediaFrames.width/height` 排版：`AkFilmstrip` 不能再用
  `height * 16 / 9`，也不能用 `BoxFit.cover` 裁切；`TrimTimeline` 把 strip 的
  `width/height` 传进去。这是用 avox 的输出做布局，不是自己算旋转。
- `ak_probe` 不需要 `rotation/display_*` 字段；`MediaFrames.width/height` 已经够时间线
  用。avox 想加诊断字段可以加，但 avoxkit UI 不依赖。
- 如果抓帧回调吐的是未旋转帧 + rotation，那说明 avox 没把显示方向收干净；avoxkit
  不在 UI 层补旋转。
- `repair_page` 是图片预览，和视频 display matrix 无关。

## 7. 验收

- `grep -r "libav" native/avtool/src native/avtool/include` 无结果。
- `dumpbin /dependents avoxkit_native.dll` 不出现 `avformat/avcodec/avutil/swresample`，
  只有 `avox.dll`（以及系统库）。
- 同一组 fixture 上，迁移前后：
  - `ak_media_index` 的 `duration_ms`、`bucket_ms`、`keyframes_ms` 完全一致；
    `peaks` 在转换后逐桶一致（或允许 ±1 的归一化误差）。
  - `ak_media_frames` 的 `actual_ms`、`width/height`、旋转方向一致；SDR fixture 的 JPEG
    视觉无明显差异；HDR fixture 允许差异（新路径做 tone map，旧路径是 SDR 近似）。
  - `ak_probe` 的 `format/duration_ms/can_seek/视频/音频/字幕` 字段与现在一致；
    `width/height` 仍是编码尺寸，不需要新增 rotation/display 字段
    （每轨 `bit_rate`/`pix_fmt`/`sample_fmt` 可以不保留，UI 未消费）。
- 9:16 fixture：编码 1920×1080、rotation=90；`ak_smoke frames ... 320` 输出
  320×569；`AkFilmstrip` 按 320/569 排版、不裁切；`AkFramePreview`/`AkLivePreview`
  保持 16:9，允许左右黑边，不拉伸、不裁切。
- fixture 覆盖：H.264/AAC MP4、HEVC/MKV、10bit/竖拍旋转、HDR、无音轨、无视频轨、
  坏文件。
- 取消：长片索引过程中从另一线程 `cancel()`，收到
  `onError(index, cancelled)`，状态回 `ready`，reader 可再次使用。
- 生命周期：正常顺序是 `open -> onReady -> index -> onIndexDone -> frame -> onFrame ->
  close`；`getSourceInfo()` 在 `onReady` 前为 nullptr；坏文件走 `onError(open, ...)`；
  `close()` 返回后不再有任何回调。
- 无 Vulkan：抓帧返回 `renderUnavailable`，probe/index 仍正常；UI 显示
  「Vulkan 组件未启用，缩略图/画面预览不可用」，不出现空白图或静默失败。
- 旋转：普通视频（display matrix=0）画面不变；竖拍 fixture 旋正，且宽高为显示方向。
- 网络：v1 仅本地文件，网络 URI 打开即回 `unsupported`
  （"v1 supports local files only"，已验证）；HTTP 直链/HLS/RTSP/代理作为 v2 验收项。

## 8. 结论与待确认

1. **MediaInfo 合并**：已定。合并进 `ISourceInfo`，`IMediaReader` 只返回
   `ISourceInfo*`；索引推算出的有效时长放在 `MediaIndexResult.durationMs`，不写回
   `ISourceInfo`。命名用 `durationMs/bitRate/formatName`。
2. **抓帧走 VK**：已定。`SurfaceRenderVk` + `enableImage`，GPU 缩放 + HDR→SDR；
   **无 Vulkan 不兜底**，返回 `renderUnavailable`，UI 显示「Vulkan 组件未启用」。
   旋转只处理容器 display matrix 声明的 90/180/270，0° 文件完全不动；transpose 定稿
   在渲染入口一次性处理（avox `a62f0ab`），抓帧/预览直接出显示方向画面，调用方不参与
   旋转。预览窗口仍保持 16:9 + `BoxFit.contain`，9:16 左右黑边是正常行为；只有时间线
   `AkFilmstrip` 按 `MediaFrames.width/height` 排版。旋转不出口、不由 avoxkit 二次处理。
3. **同步/异步**：接口按事件驱动设计，结果只经 observer 回调；实现可以先单线程同步
   （回调在调用线程），以后换内部工作线程不改接口。avoxkit shim 用
   `condition_variable` 等回调，对 Flutter 仍保持同步 JSON ABI。
4. **峰值类型**：建议 avox 返回线性 `float[0,1]`，avoxkit 自己转 0–100 的 sqrt 曲线；
   不把 UI 的显示曲线写进引擎。
5. **轨道描述**：建议复用 `ISourceInfo`/`ISTrackDesc`，只追加 `codecName/isDefault`
   两个虚函数；不另建一套 reader 专用轨道结构。
6. **v1 网络范围**：已定 v1 仅本地文件（网络 URI 打开即回 `unsupported`）；HTTP
   直链/HLS/RTSP/代理等需要 avox IO 能力时再做 v2。
7. **抓帧输出**：建议返回 RGBA8 `IImageBuffer`，JPEG/PNG 编码留在调用方（继续用
   `getImageBytes`）；reader 不绑死图片格式。
