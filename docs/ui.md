# avoxkit UI 设计基准(2026-10-26)

> 视觉语言来自 `D:/Work/github/impeccable`(Design Guidance for AI coding agents)
> 的 DESIGN.md / kinpaku token 体系(Neo kinpaku: kinpaku gold + verdigris patina
> 落在黑漆底上)。本仓只取**设计语言与规则**, 不复制其代码——impeccable 是
> AI 代理用的设计工作流 + 它自己的 web UI, 不是 Flutter 组件库。
> 原型是会话内的静态设计稿, 不是本仓源码; 落地时按本文实现。

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
- **OptionForm**: schema 驱动的参数区, 控件原子 = chip 组 / segmented / select /
  range / number / toggle / file。新工具多数只写 schema。
- **MediaPreview**: 共享预览件, 四模式 `frame | filmstrip | waveform | image-canvas`。
  进度数字是唯一事实来源; 抽帧/波形失败时退化为纯进度条, 不阻塞任务。
  不做播放 transport(无 play/pause/连续 seek), 不是播放器。
- **TaskQueue**: 统一任务模型(kind + params JSON + 状态机
  `queued → running → done | failed | cancelled`), 与具体工具解耦。
- **About**: 三句话(免费/本地/无账号) + Powered by avox + Panvox 推荐位, 不做弹窗横幅。

## 3. 新增一个工具(固定 checklist)

1. `ToolSpec` 一条: id / category / icon / title / description / order /
   page builder / 支持的 task kind / 需要的 preview 模式。
2. `OptionSchema` 一份: 该工具的输入与选项。
3. 只有真正特异的交互(图片 mask 编辑、剪切入出点吸附)才写专用组件,
   壳、表单、预览、动作区全部复用。
4. 引擎侧新增 `ak_*` task kind 与 handler(缺口归 avox 仓, 见 architecture.md §5)。
5. 文案走 AGENTS.md 口径: 三句话、识别/未识别、未实现不上 UI。
6. 验收: 320px 起可用、键盘可达、失败态可读; 当前只有暗色主题, 不假装有浅色。

**成本口径**: 常规工具 = registry 1 条 + schema 1 份; 不需要改 shell、侧栏、
工作台或队列。

## 4. 边界(设计即约束)

- 不做播放器/多轨时间线(剪映式); 预览件只做"看与对齐"。
- 工具页不超过两栏; 参数面板不堆第三列。
- 新功能默认进「工具箱」组; 异步任务类进「任务」组。
- 视觉评审可借用 impeccable 的 critique/audit 思路, 但其 62 条 detector
  面向 web DOM/CSS, Flutter 端不能直接跑。
