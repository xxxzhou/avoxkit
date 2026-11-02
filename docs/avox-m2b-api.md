# M2b 引擎接口设计：无损剪切 / 字幕烧录（2026-11-01）

> 性质：**跨仓接口设计稿**（avox 侧待排期）。按约定先对设计再写码；
> avox 侧接口一次列全生命周期/错误/数据所有权。
> 关联：`docs/m2-plan.md` M2b；`docs/functional-architecture.md` §7 #8/#9；
> avox `doc/plan/player/字幕画布多后端渲染计划.md` / `字幕样式设计.md`。

## 0. 共同约束

- **不加 ak_* 函数**：两项都只新增 params 字段与事件字段，`ak.h` 冻结面不变。
- **能力探测**：`ak_capabilities` 增加 token，Dart 按 token 显示 UI（未实现不上 UI）：
  `trim.lossless.keyframe` / `trim.lossless.smart` / `transcode.subtitle_burn`。
- 取消/错误/所有权沿用现状：`close()` 排空、错误码字符串、临时文件先写后换。
- 进度复用 `state{stage}` + `progress`；新 stage 只加字符串，Dart 未知值走默认文案。
- `done` 事件允许新增向后兼容字段（`mode_used` / `fallback_reason`），旧 Dart 忽略。

## A. 无损剪切

### A1 产品契约

`trim` 增加输出模式参数 `mode`：

| mode | 语义 | 切点精度 | 成本 |
|---|---|---|---|
| `encode`（现状默认） | 全片重编码 | 帧精确 | 慢，画质损失 |
| `copy` | 流拷贝，切点吸关键帧 | 起点≤请求点最近关键帧；终点包边界 | 秒级 |
| `smart` | 首尾局部 GOP 重编 + 中段直拷 | 帧精确 | 接近秒级，切点局部有损 |

- 起点吸附后**实际起点回传**（`done.actual_start_ms`），UI 显示真实起点，不假装精确。
- 音频：`copy` 直拷并随视频同轴平移；`smart` 默认**音频整轨重编**（AAC/MP3，成本小），
  避免逐段拼接的 priming/对齐问题；仅当音视频边界天然对齐时才直拷（引擎内部判定）。
- 字幕轨：文本/图形字幕直拷并平移时间戳；不能平移时丢弃该轨并 warning（不静默留错位）。
- 容器：默认同源容器；直拷流必须被目标容器接受，否则拒绝并提示（复用现有容器判定）。
- **回退矩阵（绝不静默失步）**：

| 情况 | 行为 |
|---|---|
| `smart` 但源为 open-GOP/交错/不支持的编码 | 回退 `copy` + warning |
| `copy` 但无关键帧索引（损坏/不可 seek） | 回退 `encode` + warning |
| 起点/终点落在片头前 0.1s 内 | 夹取并提示 |
| 输入无视频轨 | 拒绝（音频请用提取音频） |

### A2 avox 引擎接口（建议新增 `AvoxCut.h`）

```cpp
enum class CutMode : int32_t { KeyframeCopy = 0, Smart = 1 };

struct CutParam {
  int64_t startMs = 0;          // 请求起点; 实际起点经 CutResult 回传
  int64_t endMs = 0;            // <=0 或 >时长 = 到片尾
  CutMode mode = CutMode::KeyframeCopy;
  bool audioReencode = false;   // smart 且音频边界不对齐时由实现置 true
};

struct CutResult {
  int64_t actualStartMs = 0;    // 吸附/重编后的真实起点
  int64_t actualEndMs = 0;
  CutMode modeUsed = CutMode::KeyframeCopy;
  const char* fallbackReason = nullptr;  // 空=未回退; 生命周期到下次 open/close
};

class ICutObserver {  // 引擎线程回调, shim 转成事件
  virtual void onStateChange(CutState pre, CutState state) {}
  virtual void onProgress(int64_t ppm) {}          // 以输出时长为分母
  virtual void onStage(const char* stage) {}        // copy / reencode_head / reencode_tail
  virtual void onError(const char* code, const char* message) {}
  virtual void onComplete(const CutResult& result) {}
};

class ILosslessCutter {
 public:
  virtual ~ILosslessCutter() = default;
  virtual void setObserver(ICutObserver* ob) = 0;
  virtual bool open(const char* inputUrl, const char* outputUrl) = 0;  // 含索引
  virtual void setParam(const CutParam& param) = 0;                    // open 前
  virtual bool start() = 0;
  virtual void cancel() = 0;
  virtual void close() = 0;
  virtual CutState getState() = 0;
  virtual const CutResult* getResult() = 0;
};
AVOX_EXPORT ILosslessCutter* createLosslessCutter();
```

**实现要点与理由**

- 读取复用 `IRawSource::onRawPacket`（原始包）+ `IMediaReader` 索引的 `keyframesMs`；
  不引入新的解码/封装栈。
- `copy`：从 ≤start 的关键帧起直拷到 end 前最后一个包；丢弃前置 GOP；
  输出时间戳以 actualStart 归零重写，音视频同轴平移。
- `smart`：前导 GOP（关键帧→start）解码重编；中段直拷；尾部 GOP 重编到 end；
  三段时间戳连续、同 time base——这是本设计最大的工程风险点（见 A5）。
- 错误码：`not_seekable` / `no_keyframe` / `unsupported_codec` / `timestamp_gap` /
  `encode_failed` / `output_unwritable`。
- 所有权：参数值拷贝；`CutResult` 由 cutter 持有到 `close()`；回调只在引擎线程，
  shim 负责转事件（与 IRecorder 现有模式一致）。

### A3 avoxkit shim 映射

- `kind=trim`，`params.trim`: `{start_ms, end_ms, mode: "encode"|"copy"|"smart"}`。
- 校验：`mode != encode` 要求源可 seek 且有视频轨；`smart` 要求本机有可用编码器
  （首尾 GOP 重编）；`copy` 不要求编码器。
- 能力不足时按 A1 回退矩阵降级，`done` 带 `mode_used` 与 `fallback_reason`。

### A4 UI 影响（引擎落地后）

- 截取页输出档位：现有「重新编码」→ 增加「无损（关键帧）」「精确（智能）」。
- 选中后时间线显示吸附后的起点；提交摘要写明真实模式与预期成本。
- 仍只支持单文件（时间线是单文件交互）。

### A5 未决问题（需 avox 侧确认）

1. **B 帧/时间戳偏移**：长 GOP + B 帧切点是否引入首帧 pts 前移（LosslessCut 的同款坑）；
   需要 avox 内部冻结一套「切点 -bf 补偿」策略。
2. open-GOP HEVC 能否安全 `copy` 起点（切点参考帧缺失）。
3. MP4 edit list / 负 CTS 输入的处理口径。
4. 多音轨/多字幕轨平移；v1 是否只保证首轨正确、其余直拷。
5. 章节与元数据保留策略。
6. 验收素材矩阵（H.264/H.265 × 短/长 GOP × MKV/MP4 × 多轨 × 30/60fps）。

## B. 字幕烧录

### B1 产品契约

- 输入三选一：内嵌文本轨、外挂 `srt/ass/vtt`、本应用 ASR 产出的 `.srt`。
- **语义与播放器预览一致**：同一套样式词汇（字体/字号/颜色/对齐/位置/边距/宽度、
  ASS 缩放与字体覆盖、延迟），预览所见即烧录所得。
- 样式生效矩阵沿用 `AvoxPlayer.h` ISubtitle 注释：纯文本样式只对 SRT/ASR 生效；
  内封/外挂 ASS 用自带样式，仅全局缩放/位移/透明度 + 字体覆盖 + 延迟生效。
- PGS/DVD/DVB 图形字幕 v1 不烧录，明确提示（要文字请走识别）。
- 字体：系统字体 + avox 字体目录；中文缺省 `Microsoft YaHei UI`；缺字体 → warning + 回退，
  不失败。
- 烧录必然视频重编；音频按 `trans_mode=audio_copy` 可直拷。
- 失败：字幕解析失败 → 任务失败并带原因；所选轨无文本 → 提交前拒绝。

### B2 avox 引擎接口

**核心问题**：现有字幕渲染绑在播放器时钟上（ISubtitle 属于 player 腿），
离线编码没有「按 PTS 取字幕画布并合成」的入口。建议抽独立接口：

```cpp
// AvoxSubtitle.h 追加
struct SubtitleStyle {  // 与 ISubtitle 同语义; 字段默认值 = 播放器当前默认
  const char* fontFamily = nullptr;   // nullptr=引擎默认
  int32_t fontPx = 0;                 // 1080 基准, <=0=默认
  float r = 1, g = 1, b = 1;
  int32_t halign = -1, valign = -1;   // -1=不变
  float anchorX = 0.5f, anchorY = 0.8f;
  float marginX = 0, marginY = 0;
  float maxWidth = 0.8f;
  float assScale = 1.0f;
  int64_t delayMs = 0;
};

struct SubtitleOverlayParam {
  const char* path = nullptr;         // UTF-8; srt/ass/vtt
  SubtitleEncoding encoding = SubtitleEncoding::unknown;  // unknown=自动探测
  SubtitleStyle style;
};

class ISubtitleRenderer {            // 与 player 解耦, 播放器侧改为复用本实现
 public:
  virtual ~ISubtitleRenderer() = default;
  virtual bool open(const SubtitleOverlayParam& param) = 0;
  // 把 pts=ptsMs 时刻的字幕画布合成进 frames(编码前帧); 无字幕时不动帧返回 true
  virtual bool renderInto(IFrameSink* sink, int64_t ptsMs) = 0;
  virtual void close() = 0;
};

// IRecorder 追加(open 前设置; 转码腿专用, 直拷腿忽略并告警):
virtual void enableSubtitleOverlay(const SubtitleOverlayParam& param) {};
virtual void disableSubtitleOverlay() {};
```

**实现要点与理由**

- 复用现有 libass 插件与「RGBA canvas → VkBlendLayer」合成路径，只把驱动源从
  播放器时钟换成逐帧 PTS；播放器改为消费同一 `ISubtitleRenderer`，避免两套渲染
  行为漂移（这是与 `字幕模块合并计划.md` 同向的收敛）。
- 烧录在编码前合成，因此输出分辨率缩放、HDR/SDR 与现有转码链一致；1080 基准
  按输出帧高缩放。
- 错误码：`subtitle_parse_failed` / `unsupported_format` / `subtitle_empty` /
  `render_failed`（字体缺失为 warning，不中断）。
- 所有权：`SubtitleOverlayParam` 字符串在 `enableSubtitleOverlay` 内拷贝；渲染器
  生命周期随 recorder。

### B3 avoxkit shim 映射

- `kind=transcode`，`params.subtitle`：
  `{path, encoding:"auto", delay_ms, style:{font_family, font_px, color:[r,g,b],
  align:[h,v], anchor:[x,y], margin:[x,y], max_width, ass_scale}}`。
- 校验：path 存在且扩展名受支持；`video` 必须为转码态（强制 `trans_mode` 不含
  `video_copy`）；字幕为空 → 拒绝。
- 能力 token：`transcode.subtitle_burn`。

### B4 UI 影响（引擎落地后）

- 字幕页：识别/提取完成后可「烧录进视频」；样式面板复用播放器预览实时看效果
  （预览与烧录同实现，所见即所得）。
- 转换页挂外挂字幕留到后续（同参数，入口不同）。

### B5 未决问题

1. 缺字体时的 warning 文案与回退链（系统字体提供器顺序）。
2. 描边/阴影/背景框是否进 v1（当前 ISubtitle 无描边字段，需与
   `字幕样式设计.md` 对齐）。
3. 多轨/双语同时烧录（v2，参数需预留 `tracks[]`）。
4. 输出非 1080 时样式基准缩放的一致性验收。
5. 打包字体（OFL 子集）还是只用系统字体——影响安装包体积与跨机一致性。

## C. 排期与验收

| 阶段 | 内容 | 验收 |
|---|---|---|
| 1 | `copy` 剪切 + SRT 烧录（系统字体） | 音画同步、时长与请求一致、可播 |
| 2 | `smart` 剪切 + ASS 样式/字体覆盖 | 切点帧精确、长 GOP/多轨矩阵回归 |
| 3 | 边界矩阵（open-GOP、edit list、多音轨、竖屏） | 回退矩阵全部有 warning 不静默 |

两项均在 avox 仓执行（AGENTS.md 红线：不在 avoxkit fork 引擎）；
本文定稿后再开 avox 侧施工卡与 avoxkit 侧 kickoff。
