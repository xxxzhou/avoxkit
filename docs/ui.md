# avoxkit UI 设计基准(2026-10-26)

> 视觉语言：黑漆底 + 金色信号 + 铜绿状态。
> 本文是 Flutter 端的落地基准；颜色、字号、圆角、动效统一走 `AkTokens`。

## 1. Token 映射(Flutter 端唯一来源)

以 `AkTokens`(ThemeExtension)承载, 新组件禁止硬编码颜色/字号/圆角/动效。

| 语义 | 值(来源) | 用途 |
|---|---|---|
| bg | lacquer-black `oklch(7% 0.006 95)` | 页面底 |
| bgDeep | lacquer-deep `oklch(4% 0.004 95)` | 侧栏/输入井/画布底 |
| surface | raised-lacquer `oklch(11% 0.006 95)` | 面板/卡片 |
| surfaceAlt | graphite `oklch(15% 0.008 95)` | 轨道/次级填充 |
| surfaceHi | graphite-2 `oklch(19% 0.008 95)` | 选中段/键帽 |
| accent | kinpaku-gold `oklch(84% 0.19 80.46)` | 主按钮/活动指示/关键帧线 |
| accentInk | dark-ink `oklch(14% 0.018 95)` | 金色上的文字 |
| state | verdigris-patina `oklch(70% 0.12 188)` | 选中/焦点/已完成状态 |
| text | text-warm `oklch(88% 0 0)` | 正文 |
| textStrong | champagne `oklch(91% 0 0)` | 标题 |
| muted / faint | 72% / 62% | 说明/元信息 |
| border | gold-hairline `oklch(78% 0 0 / 0.16)` | 分隔/控件边界 |
| borderActive | gold-hairline-strong `oklch(74% 0.09 82 / 0.6)` | 悬停/激活边界 |
| danger | vermilion `oklch(64% 0.17 28)` | 仅错误 |
| radius | 3 / 8 / 999 | 小控件 / 面板 / 胶囊 |
| controlH | 26 / 32 / 44 | 小 / 常规 / 大 |
| motion | 120ms 状态变化, 200ms 元素到达, `cubic-bezier(.2,.8,.2,1)` | 全局 |
| font | Albert Sans(界面) + JetBrains Mono(数字/标签) | 两族, 不加第三族 |

规则: 金色是信号不是大面积填充; 铜绿只表状态; 正文不使用金色(对比度)。
字体必须随包分发(本地/离线叙事, 运行时不联网取字体); 设计稿用 CDN 仅为预览。
字号梯级: 页面标题 24 / 面板标题 14 / 正文 13 / 标签 12 / 微标签 11(下限)。

## 2. 组件清单(先复用, 再专用)

- **AppShell**: 标题栏(品牌/引擎状态/窗口钮) + 侧栏 + 内容区。侧栏分组与排序由 registry 生成。
  窄容器(≤860px)侧栏收成 74px 图标轨, 用短标签(`data-short`), 不做换行横排导航。
- **ToolPage**: 页头(eyebrow / 标题 / 一句说明) + 两栏(文件区 / 参数面板) + 动作区。
  新工具默认套这个骨架, 不新造版式。
- **转换页**: 一个入口完成原来的格式转换/封装转换。设置 = 容器 / 视频编码 /
  分辨率 / 音频编码 / 码率 / 质量 / 硬件, 默认全部「同源」; 顶部两个预设
  (`仅换容器 MP4`、`H.265 · 1080p`)。提交前显示实时判定条(直接封装 / 重编码视频 /
  重编码音频 / 无需转换), 批量逐文件判定并提示封装/转码/跳过数量。
  MP4 内保留 HEVC/AV1 或旧式多声道音频(E-AC-3/AC-3/ALAC)时, 判定条额外提示
  「Windows 自带播放器可能打不开」, 避免把系统播放器的解码缺口当成产物损坏。
- **提取字幕页(2026-10-27)**: 单文件/文件夹同一入口。自动选默认或中文文本轨;
  有文本轨直接导出 SRT, 没有时用本地 SenseVoice 识别。PGS/DVD/DVB 图形字幕
  明确提示不能直接导出文字。语音识别模型不随包, 页面只在需要时显示下载卡
  (约 230 MB, sha256 校验); 不识别不下载。批量提交时逐文件探测并统计
  内嵌/识别/跳过数量。
- **图像修复页(2026-10-29)**: 单图预览 + 模式切换(自动识别 / 手动涂抹)。
  自动模式可先「识别水印」在预览图上标框, 也可直接提交; 手绘模式在预览图上
  拖动涂抹, 笔刷宽度按图宽归一化, 支持撤销/清空。结果图在预览位直接替换,
  可切回原图对比。模型(LaMa + YOLO26-Seg, 约 290 MB)按需下载; 批量只走
  自动识别, 输出名加 `-repaired`。预览用 Flutter 的 `Image.memory`, 不启
  原生 Vulkan 窗(静态图没有连续呈现的需求)。
  当前导航 7 项: 转换 / 截取片段 / 提取音频 / 提取字幕 / 图像修复 / 任务 / 关于。
- **截取片段页(2026-10-28)**: 单文件入口(不接受文件夹)。页面主体是**区间尺**,
  不是剪映式多轨时间线:
  - 时间尺 + 缩略图条 + 音频包络 + 关键帧刻度; 有包络就画波形, 没有就只留刻度,
    不阻塞选点。缩略图条按整片均匀采样(6-24 张, 跟着面板宽度), 放大后单张保持
    自然宽度、不拉伸, 空隙表示该处没有采样帧。
  - 时间线上方固定一张**画面参考**: 悬停显示指针时刻, 拖手柄显示手柄时刻,
    空闲回到最近触碰的入点/出点。拖动时先用最近缓存帧, 停 120ms 后换精确帧;
    不做逐帧连续预览, 也不是播放器。
  - 两个手柄定义入/出点; 起点始终吸附到目标前最近关键帧(引擎按关键帧定位,
    这样屏显时间就是产物真实起点), 终点按时间截断。
  - 滚轮缩放(以指针为锚)、拖空白处平移、双击回到全片; 悬停显示时间;
    下方数字输入框是精确值来源, 支持 `hh:mm:ss.mmm` / `mm:ss` / 秒数。
  - 选中区间用金色描边 + 弱填充, 区间外压暗; 关键帧用铜绿短刻度。
  - 只做"看与对齐": 没有播放头/连续播放/多轨。
  - 起点超过片长 90% 时明确拒绝: 引擎 `io.startFrac` 上限 0.9, 强行拉回会让
    产物开头多一截; 不做静默纠正。
  - 输出固定重新编码(视频 H.264/H.265 + AAC), 容器同源或 MP4/MKV/MOV;
    页面明说终点可能有半秒内偏差, 不宣称无损/帧精确。
- **OptionForm**: schema 驱动的参数区, 控件原子 = chip 组 / segmented / select /
  range / number / toggle / file。新工具多数只写 schema。
- **MediaPreview**: 共享预览件，当前已落地 `frame | filmstrip | waveform`；
  `image-canvas` 由图像修复页用 Flutter 自绘（图片 + 涂抹/识别框），不启原生窗。
  进度数字是唯一事实来源; 抽帧/波形失败时退化为纯进度条, 不阻塞任务。
  不做播放 transport(无 play/pause/连续 seek), 不是播放器。
  **Flutter 侧(2026-10-28)**: `frame` 与 `filmstrip` 已落地为可复用组件:
  `MediaFrameSource`(每文件一个, 负责取帧/去抖/单飞/LRU 缓存, 不碰 UI) +
  `AkFramePreview`(参考卡, 先显示最近缓存帧再换精确帧) +
  `AkFilmstrip`(按时间铺图, 只画图, 压暗交给父级) +
  `TimeViewport`(ms↔px、以指针为锚缩放、平移、刻度间隔, 纯逻辑可单测)。
  `AkTrimTimeline` 只是这四个的组合; 抽帧/封面、去水印底图、字幕烧录预览
  直接复用, 不重写取帧链路。取帧走 `ak_media_frames`(JPEG base64, isolate),
  不写临时文件。
  **Windows 原生直显已落地(2026-10-27)**: 宿主主窗上挂一个原生子窗, avox 经
  `ISurfaceRender::setSurface(HWND)` 直渲, 预览线程负责建窗/跟矩形/呈现,
  Dart 只投递请求; 不做纹理共享、不做 CPU 取帧。
  - 窗口归页面(`preview_open/close`), 绑定归当前可见任务(`preview_bind/unbind`);
    同一时刻只绑一个, 串行调度让这个约束天然成立。
  - 只有录制中的任务显示原生窗; 排队/终态/`IndexedStack` 切页时隐藏并露出 Flutter 占位。
  - 接/摘视口只切 `setSurface(hwnd)` / `setOffSurface(yuv)`: 拿到窗口时呈现线程自动启动,
    摘掉后循环继续消费, 转码处理不停; 不需要额外开停接口。
  - 任务详情页按 task_id 绑定; 工具页批量提交后绑组内当前运行项, 两者共用同一 `AkLivePreview`。
  - 波形来自 `AudioTap`(转码/提取重编码), 直拷与封装没有 PCM, 显示无波形说明。
- **TaskQueue**: 统一任务模型(kind + params JSON + 状态机
  `queued → running → done | failed | cancelled`), 与具体工具解耦。
- **About**: 三句话(免费/本地/无账号) + Powered by avox + 版本信息, 不做弹窗或常驻推广。

## 3. 新增一个工具(固定 checklist)

1. `ToolSpec` 一条: id / category / icon / title / description / order /
   page builder / 支持的 task kind / 需要的 preview 模式。
2. `OptionSchema` 一份: 该工具的输入与选项。
3. 只有真正特异的交互(图片 mask 编辑、截取区间尺)才写专用组件,
   壳、表单、预览、动作区全部复用。区间尺见 `widgets/trim_timeline.dart`,
   其缩略图/参考画面/视口分别是 `widgets/filmstrip.dart`、`frame_preview.dart`、
   `time_viewport.dart`; 取帧缓存见 `core/media_frame_source.dart`。
4. 引擎侧新增 `ak_*` task kind 与 handler(缺口归 avox 仓, 见 architecture.md §5)。
5. 文案走 AGENTS.md 口径: 三句话、识别/未识别、未实现不上 UI。
6. 验收: 320px 起可用、键盘可达、失败态可读; 当前只有暗色主题, 不假装有浅色。

**成本口径**: 常规工具 = registry 1 条 + schema 1 份; 不需要改 shell、侧栏、
工作台或队列。

## 4. 边界(设计即约束)

- 不做播放器/多轨时间线(剪映式); 预览件只做"看与对齐"。
- 工具页不超过两栏; 参数面板不堆第三列。
- 新功能默认进「工具箱」组; 异步任务类进「任务」组。
- 视觉评审按本文的 token 与组件约束执行；Flutter 端不使用面向 web DOM/CSS 的检查器。
