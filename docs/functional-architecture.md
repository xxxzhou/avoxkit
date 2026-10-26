# avoxkit 功能架构(2026-10-26 评审稿)

> 由两个只读架构 agent 并行设计后汇总: A 负责能力域/产品功能, B 负责运行时/扩展机制。
> 事实来源: 本仓 `docs/architecture.md`、`docs/m1-plan.md`、`docs/m1-kickoff.md`、
> `docs/ui.md`; panvox 仓只读踩坑记录(见 §13)。本文只做设计, 不含实现代码。
>
> 一句话: **功能用 ToolSpec + Schema + Preset + Recipe 表达, 执行用 Task + Stage + Event
> 收口, 能力用 Capability + Model 显式化。常规新功能只动 Dart 数据; 只有新原语才动
> shim; 只有引擎缺口才动 avox。20 个后续功能都不需要改 `ak_*` ABI。**

## 0. 设计原则

1. **功能是数据, 不是分支。** 新工具优先用注册表 + 参数 schema + 预设 + recipe 表达,
   不新增页面、不新增队列、不新增 ABI。
2. **一个运行时。** 所有功能共用任务模型、状态机、取消、重试、进度、事件、日志、
   临时文件管理和错误分类。
3. **kind 是公开契约, pipeline 是 shim 内部实现。** Dart 只发 `kind + canonical params`;
   stage 列表由 shim 的 handler 生成, 事件只暴露稳定的 stage 字符串。
4. **线性流水线, 不做 DAG。** 需要分支时在 stage handler 内部 fan-out, 或拆成
   TaskGroup 顺序执行; 不先造拓扑调度器。
5. **边界纪律。** shim 不认识预设名/页面/文案; Dart 不接触引擎指针; UI 不 import
   `dart:ffi`。
6. **能力驱动可见性。** 未实现、平台不支持、模型/组件缺失的工具不注册或显示下载
   入口, 绝不静默降级冒充完整产物。
7. **常规功能零 ABI 变更。** ABI 只冻结信封(任务/事件/探测/能力), 新增原语只加
   handler 和 capability token。

## 1. 分层与边界

```
┌─ Flutter UI
│    ToolPage / OptionForm / TaskCenter / Settings / ModelCenter
│    只认 ToolSpec、TaskView、CapabilityView
│        │ Dart 接口
├─ Dart core
│    ToolRegistry / PresetResolver / TaskPlanner / TaskService /
│    TaskStore / CapabilityService / ErrorPresenter / ModelStore
│        │ AkApi 抽象
├─ Dart native adapter
│    ak_bindings / ak_events / NativeCallable 保活 / UTF-8
│        │ C ABI(int64 任务号 + JSON)
├─ ak_* shim(avoxkit_native.dll)
│    TaskRuntime / Handler registry / Queue / Event thread /
│    Artifact / Capability probe / Log / 引擎适配
│        │ 链接 avox.lib
├─ avox 引擎
│    TranscodeRecorder / StreamRecorder / AudioTap / ImageIO / 插件
│        │
└─ ffmpeg kit + 模型/组件
```

| 层 | 必须知道 | 禁止知道 |
|---|---|---|
| Flutter UI | ToolSpec、schema 展示元数据、TaskView、CapabilityView、错误展示 | `dart:ffi`、指针、引擎枚举、DLL 路径、FFmpeg 参数 |
| Dart core | 工具注册、预设展开、任务编排、能力协商、错误码→文案/动作、任务历史 | 引擎对象、线程、回调指针、avox 导出名 |
| Dart adapter | `ak_*` 签名、UTF-8、`NativeCallable` 保活、事件解析、`ak_event_free` | 业务规则、预设名、输出命名、UI 文案 |
| shim | 任务 JSON 契约、队列/状态机、临时文件、引擎调用、能力探测、日志 | 预设名、UI 文案、页面路由、用户偏好、Flutter 类型 |
| avox | 编解码、封装、IO、Vulkan、字幕/ASR/图像能力 | 产品任务模型、队列、UI 语义 |
| ffmpeg/模型 | 编解码器、协议、封装、模型文件 | 产品状态机、任务调度 |

三条硬边界:

- **shim 不认识 UI 预设名。** B 站/抖音/微信/Discord/10MB 都是 Dart 资产, 展开成
  codec/bitrate/resolution 后再提交。
- **Dart 不持引擎指针。** 只持 `int64 task_id` 和不透明字符串; `Pointer` 只在单次
  FFI 调用内出现。
- **shim 不做产品策略。** 不按分辨率自动决定倍率、不按文件名猜预设、不生成用户
  文案、不决定输出目录结构。

## 2. 能力域

域按“输入/输出/可组合原语”划分, 不按 UI 页面划分。侧栏只是域的投影。

| 域 | 回答的问题 | 输入 | 输出 | 原语 |
|---|---|---|---|---|
| D1 输入与探测 | 这是什么、能不能处理 | 本地/NAS 路径、URL 直链 | MediaInfo、指纹 | probe、fetch、validate_source |
| D2 封装与转码 | 换格式、换编码、压小 | MediaInfo + 时间线 | 新媒体文件 | demux、decode、filter、encode、mux |
| D3 音频 | 抽音轨、转 MP3/WAV/M4A | 源/指定音轨 | 音频产物 | select_tracks、resample、normalize、encode_audio |
| D4 字幕与语音 | 生成、翻译、提取、烧录 | 音频/视频/字幕轨 | SRT/ASS 或带字幕视频 | subtitle_parse、asr、translate、subtitle_export、subtitle_render |
| D5 图像 | 去水印、格式转换、抽帧 | 图片/视频帧 | 图片产物 | image_decode、image_filter(inpaint)、image_encode |
| D6 剪辑 | 无损掐头去尾、合并 | 媒体 + 区间/多段 | 媒体产物 | seek、keyframe_align、trim、concat、remux |
| D7 任务与批处理 | 排队、批量、重试、取消 | TaskSpec / TaskSpec[] | 事件流 + 产物 | enqueue、group、cancel、retry |
| D8 资产与能力 | 模型、预设、引擎能力 | manifest/探测结果 | 已安装模型、能力快照 | resolve、download、verify、capability |

明确不属于任何域: 多轨时间线、转场、画中画、账号、云同步、下载器。

### 2.1 五个执行族(kind)

| kind | 语义 | 覆盖功能 | M1 |
|---|---|---|---|
| `transcode` | 解码 + 可选滤镜/字幕 + 重编码 + 封装 | 格式转换、压缩、字幕烧录、视频去水印、画质增强、GIF/WebP | 是 |
| `remux` | 流拷贝 + 容器/轨道编辑 | 重封装、无损剪切、无损合并、音轨增删 | 否(M2) |
| `extract` | 不重编整条时间线, 派生旁路产物 | 提取音频、提取字幕、抽帧/封面 | 否(M2) |
| `analyze` | 只读/派生文本信息 | ASR 生成字幕、字幕翻译、响度分析 | 否(M3) |
| `image` | 单图进、单图出 | 图片去水印、图片格式转换/压缩 | 否(M3.5) |

**批量不是 kind**, 是 TaskGroup; **URL 抓取不是 kind**, 是 transcode/analyze handler
内部的 `fetch` stage; **预览不是 kind**, 是 `priority=preview` 的轻任务。

## 3. 领域模型

| 对象 | 职责 | 生命周期 | 稳定/扩展 |
|---|---|---|---|
| **Source** | `kind=file|url`、uri、display_name、指纹 | 选择→探测→被任务引用 | 稳定 |
| **InputSelection** | 用户选择: 文件/文件夹/多选/URL + 展开选项(递归/扩展名/排除) | 选择→展开→生成 TaskSpec | 规划层 |
| **MediaInfo/TrackInfo** | 时长、容器、轨、编码、分辨率、帧率、can_seek、is_live | 探测后缓存, 指纹变化失效 | 稳定 |
| **ToolSpec** | 用户可见入口: id/域/分组/标题 key/图标/排序/输入基数/recipe/schema/预设/预览模式/能力与模型要求/status | 常量 | 扩展点 |
| **OptionSchema** | 声明式参数: 分组、字段、类型、默认值、约束、visibleWhen、单位、高级 | 版本化常量 | 稳定契约 |
| **Preset** | 参数补丁: id/version/标题 key/params_patch/requires | 内置只读; 用户可复制/导入 | 扩展点 |
| **Recipe** | 产品配方: kind + 参数默认值 + 能力要求 + 输出角色 + 估算模型。**不含引擎 stage 列表** | 版本化常量 | 扩展点 |
| **TaskSpec** | 一次执行的不可变规格: schema/client_task_id/group_id/retry_of/kind/sources/outputs/params/resources | 规划→提交→执行 | 稳定契约 |
| **Task** | 运行时: 状态机、当前 stage、进度、attempt、错误、产物 | queued→running→终态 | 稳定 |
| **TaskGroup** | 批量: 共享参数、串并行、停止条件、命名模板 | 创建→运行→完成 | M2 |
| **Stage** | handler 内部阶段: 类型 + 参数 + 输入/输出; 事件暴露 stage 字符串 | 随任务 | 扩展点 |
| **Artifact** | 产物: role、path、类型、大小、校验、是否 partial | `.part`→校验→原子改名 | 稳定 |
| **ModelSpec/State** | 模型清单: id/version/files/sha256/size/license/mirrors/dest | missing→downloading→ready | 扩展点 |
| **Capability** | 本机能力: `encoder.h264.hardware`、`stage.asr`、`container.mp4` | unknown→probing→available | 扩展点 |
| **Event/Error** | 进度/状态/终态/错误码 + category/retryable/detail/hint | 单次任务 | 稳定契约 |

关系:

```
ToolSpec ─1:1─ OptionSchema
   │  └─1:N─ Preset
   └─1:1─ Recipe ─N:N─ Capability ─N:N─ ModelSpec

Source ─1:1─ MediaInfo
TaskGroup ─1:N─ Task ─1:N─ Artifact
TaskSpec = kind + sources + outputs + params + resources
Planner: ToolSpec + 用户参数 + Preset + MediaInfo + Capability → TaskSpec
```

**为什么不把 stage 计划放进 TaskSpec**: 那会把引擎词汇泄漏到 Dart, 也会在还没
验证的需求上冻结一套 stage ABI。`kind + canonical params` 已经足够表达产品意图;
handler 内部怎么排 stage 是 shim 的自由。未来真需要声明式组合, 再加可选 `plan`
字段即可(未知字段策略保证向后兼容)。

## 4. 运行时模型

### 4.1 Handler + 线性 Stage

```
TaskRuntime
  ├─ HandlerRegistry: kind -> TaskHandler
  ├─ Queue: 1 worker(M1), FIFO
  ├─ EventThread: 唯一出口
  └─ Task -> Handler.run(task, cancel_token, events)
                └─ StagePlan [open, encode, finalize]  (handler 内部)
```

- `TaskHandler` 接口: `validate(params)`、`plan(params, caps)`、`run(task, cancel, events)`、
  `cleanup(task)`。M1 只有 `transcode` 一个实现, 但注册表从第一天就在。
- stage 是**粗粒度**的: `open/encode/finalize` 这类, 不是帧级算子。配置型 stage
  (demux/decode/encode/mux) 合并成一次 `IRecorder` 调用, 不真的每 stage 起线程。
- 事件里的 `stage` 用稳定英文串; UI 查本地化表, 查不到显示“处理中”。
- 新 kind = 新 handler + 注册一行 + capability token; 不改 ABI、不改队列。
- 新 stage = 改 handler 内部 + 事件加字符串; 不改 ABI、不改队列。

示例:

```
transcode:  open -> encode -> finalize
extract:    open -> demux_audio -> encode_audio -> write
analyze:    open -> stt -> write_subtitle
image:      decode -> filter(inpaint) -> encode
remux:      open -> select_tracks -> mux
```

### 4.2 状态机

公开五态(UI 只看这个):

```
queued -> running(stage) -> done | failed | cancelled
queued -> cancelled
```

内部状态:

```
queued -> starting -> running -> draining -> terminal
```

- 终态只写一次(CAS/锁); 重复终态忽略并记日志。
- `draining` 不暴露; 用户在 1 秒内看到 `cancelled`, 不看到“取消中”。
- `done` 必须在 rename 成功之后发; `failed` 至少带 temp 路径。
- `run_id/attempt` 进事件; 重试产生新 run, 不把原任务状态改回去。

### 4.3 取消(硬指标: 1 秒内)

事实: avox `close()` 立即置 `completed`(failed 除外), 排空后才回调 `onComplete`;
失败不回调 `onComplete`。因此不能把引擎状态当任务状态。

流程:

1. queued: 摘除队列 → 发 `cancelled`;
2. running: 置 `cancel_requested` → 调 `rec->close()` → **立即**发 `cancelled`,
   内部转 `draining`;
3. 引擎随后回调 `completed/onComplete`: 一律吞掉, 只更新 drain 状态;
4. 排空后删 `.part`、`removeRecorderOb`、`delete rec`;
5. 10 秒仍未回调: 记 `drain_timeout`, recorder 进 quarantine, 不 `delete`;
   worker 可继续接新任务, quarantine 上限 2, 超限暂停接新任务并告警;
6. `ak_shutdown` 不再等待 draining, 置回调闸后释放自己的引用。

取消优先于失败: `cancel_requested` 与 `onIoError` 同时到达时报 `cancelled`。
重复取消幂等返回 0; 已终态返回 `AK_E_TASK_NOT_RUNNING`。

### 4.4 队列

- M1: `mutex + condition_variable + 1 worker`, FIFO, `maxConcurrency=1` 内部字段。
- submit 只做校验/入队/发 queued, 不在调用线程 open 文件或启动引擎。
- `ak_task_remove` 只允许 queued; running 只能 cancel。
- 预留 `priority`/`lane`; M1 不暴露 UI, 全部 heavy lane。
- 批处理不需要单独 API: 队列天然接收 N 个任务, `group_id` 只用于 UI 归组。
- M2 再把预览/轻任务放独立 lane; M4 才评估多 worker(硬编 session、NAS 并发、
  draining 隔离都验证后)。

### 4.5 Artifact 与输出

- 临时文件: 输出同目录 `<stem>.avoxkit-part<ext>`(如 `a.avoxkit-part.mp4`);
  **扩展名必须在最后**, 否则引擎按扩展名选 muxer 会失败;
- 成功: `MoveFileExW(MOVEFILE_REPLACE_EXISTING)` 到最终路径;
- 失败/取消: 删除 `.part`;
- rename 失败: 保留 `.part`, 报 `output_finalize_failed`, detail 带路径;
- 提交前: 删除同名残留 `.part`; 输入=输出直接拒绝; 输出目录不可写预检拒绝;
- 默认不覆盖已存在输出; UI 确认后 `overwrite=true`;
- M1 不做跨任务事务, 每个任务只清理自己的 temp。

### 4.6 校验分层

| 层 | 内容 | 失败 |
|---|---|---|
| Dart OptionSchema | 控件类型、可见性、范围提示 | 表单内联错误, 不提交 |
| Dart Planner | 预设/能力匹配、必填、互斥、输出策略 | 提交前错误, 带字段路径 |
| shim `ak_json` | 权威类型/范围/枚举、安全钳位、schema 版本、未知字段 | `bad_json`/`bad_field`, 事件带 field |
| 引擎 setter | 只收已转换强类型 | 映射为任务错误 |

未知字段: 默认忽略, 保证旧 shim + 新 Dart 不会因新增可选字段失败。任务 JSON 带
`schema`; major 必须相等, minor 高于 shim 支持返回 `schema_too_new`。事件消费方
忽略未知字段/未知 type, 未知错误码按 `category` 兜底。

### 4.7 预设在哪展开

只在 Dart。顺序: 选工具/预设 → 合并用户覆盖 → 查 Capability → 展开别名
(`1080p`→宽高、`quality`→引擎字段、目标大小→码率) → 生成 canonical `params` →
提交。shim 不认识 `bilibili_1080p` 这类名字。

### 4.8 M1 现在要有 / 明确延后

| 现在就要有 | 为什么 |
|---|---|
| Task 状态机 + task_id + run_id | 所有功能共用, 晚做改事件和 UI |
| Handler 注册表(哪怕 1 项) | 防止 transcode 写死在队列里 |
| StagePlan(内部) + stage 事件 | 日志/诊断/UI 阶段文案 |
| Artifact + `.part` | 输出安全是 M1 验收项 |
| 事件信封 + seq + event_free | 晚做是 ABI 破坏 |
| 错误码/category/retryable/hint | 晚做到处写字符串 |
| Capability 快照 + 真编探测 | 硬编开关/UI 灰置/降级都依赖 |
| CancelToken + draining | 取消竞态是 M1 硬指标 |
| 伪引擎接口 | 无 Flutter 测试的前提 |
| 启动自检 + 版本哈希 | 防 DLL 错配 |

| 延后 | 原因 |
|---|---|
| DAG/拓扑调度 | 无真实需求 |
| 多输出事务 | M1 单输出 |
| 任务持久化/断点续跑 | M4 批处理再上 |
| 运行中暂停 | 引擎无可靠 pause |
| 自动重试 | M1 本地文件没有瞬态错误 |
| 多 worker | 并发风险未验证 |
| 优先级/抢占 | M1 FIFO |
| 插件热加载 | 需重启 |

## 5. `ak_*` ABI v1

### 5.1 函数面(冻结)

```c
uint32_t    ak_abi_version(void);               // major<<16 | minor
const char* ak_version_json(void);              // shim/avox/ffmpeg/构建哈希
int32_t     ak_init(const char* config_json);   // work_dir/models_dir/log_level
void        ak_shutdown(void);                  // 幂等、有界
int32_t     ak_set_event_cb(ak_event_cb cb, void* user);
void        ak_event_free(const char* event_json);
int64_t     ak_task_submit(const char* task_json);
int32_t     ak_task_cancel(int64_t task_id);
int32_t     ak_task_remove(int64_t task_id);    // 仅 queued
const char* ak_probe(const char* uri);          // JSON, ak_free_string
const char* ak_capabilities_json(void);         // 快照, ak_free_string
int32_t     ak_encoder_probe(const char* codec); // 便捷口, 1/0
void        ak_free_string(const char* s);
```

`ak_init` 用 JSON 而不是裸路径: M1 只传 `work_dir`, 以后 `models_dir`/`log_level`/
`max_concurrency` 都在同一封里加, 不再加导出函数。重复 init 返回 `already_init`。

### 5.2 任务 JSON

```json
{
  "schema": 1,
  "client_task_id": "uuid",
  "group_id": null,
  "retry_of": null,
  "kind": "transcode",
  "sources": [{"kind": "file", "uri": "C:/x/a.mkv"}],
  "outputs": [{"role": "primary", "path": "C:/x/a.mp4"}],
  "params": {
    "container": "mp4",
    "video": {"codec": "h264", "hardware": "off", "rate_mode": "quality",
              "quality": 60, "bitrate_kbps": 0, "resolution": "source", "fps": 0},
    "audio": {"codec": "aac", "bitrate_kbps": -1},
    "overwrite": false
  },
  "resources": {"priority": 0, "lane": "heavy"}
}
```

- `sources/outputs` 是数组, M1 只接受单入单出; 数组形状为 M2 多产物留口。
- `kind` 是五个执行族之一; shim 不认识 `recipe_id`/`preset_id`。
- 未知字段忽略; `x_` 前缀保留给扩展; 拼写错误不做模糊匹配。

### 5.3 事件 JSON 与所有权

```json
{"v":1,"seq":42,"ts_ms":1690000000000,"task_id":1,"run_id":1,"group_id":null,
 "type":"state","state":"running","stage":"open","stage_index":0,"stage_count":3}
{"v":1,"seq":43,"task_id":1,"run_id":1,"type":"progress",
 "stage":"encode","current_ms":1200,"total_ms":60000,"pct":2.0}
{"v":1,"seq":44,"task_id":1,"run_id":1,"type":"error",
 "code":"input_open_failed","category":"input","retryable":false,
 "stage":"open","message":"Cannot open input","detail":"...","hint":"choose_file"}
{"v":1,"seq":45,"task_id":1,"run_id":1,"type":"done",
 "outputs":[{"role":"primary","path":"C:/x/a.mp4"}],"duration_ms":60000}
```

**事件必须堆分配 + `ak_event_free`。** `NativeCallable.listener` 是异步投递到 Dart
isolate 的, 回调返回后栈/临时缓冲就失效; panvox 已为此改成堆事件
(`panvox_c_api.h:464-471`)。Dart 侧先 `toDartString()` 拷贝, 再 `ak_event_free`,
顺序不能反。

规则: `seq` 全局单调; 每个 run 终态恰好一次; 进度 5Hz 节流、终态必发、同值不重发;
`total_ms<=0` 只给 `current_ms`; 新增字段只加不改; 新增 type 旧 Dart 忽略。

### 5.4 回调线程模型

```
引擎线程(observer/engine callbacks)
  -> 只写 Task 字段 + push Event
唯一事件线程
  -> 串行序列化 -> ak_event_cb
Dart NativeCallable.listener
  -> 异步收到 -> 拷贝 -> ak_event_free
```

禁止引擎线程直接回调 Dart(panvox 退出期 SIGSEGV 的直接教训,
`docs/reports/exit-callback-sigsegv-20260929.md`)。回调内不得调 `ak_shutdown`
等阻塞 API; 回调必须尽快返回。

### 5.5 版本协商

| 版本 | 位置 | 规则 |
|---|---|---|
| C ABI | `ak_abi_version()` | major 必须相等; 新符号 try-lookup |
| 任务 schema | `task_json.schema` | major 相等; minor 高于 shim 返回 `schema_too_new` |
| 事件 schema | `event.v` | 只加字段; 旧消费方忽略未知 |

启动顺序: open → 查 ABI major → 查 `ak_version_json` → `ak_init` →
`ak_capabilities_json` → 主界面。版本不匹配时不建目录、不碰引擎, 直接错误页。

版本不能只看自报字段: panvox 的 `build_time/commit_hash` 会因增量构建不更新,
DLL 拷贝也会保留旧时间戳。`ak_version_json` 至少带 shim/avox/ffmpeg 的文件哈希或
构建 manifest。

### 5.6 兼容规则与反模式

| 变更 | 改 ABI major? | 规则 |
|---|---|---|
| 新增函数 | 否 | 追加导出; 旧 Dart 不调用 |
| 新增事件/任务可选字段 | 否 | 旧消费方忽略 |
| 新增 kind | 否 | 旧 shim 返回 `unsupported_kind`; Dart 用 capability 隐藏 |
| 新增错误码 | 否 | 旧 Dart 按 category 兜底 |
| 新增 stage 字符串 | 否 | 旧 Dart 显示通用阶段 |
| 改字段类型/语义 | 是 | 新函数名或新 major |
| 结构体布局变化 | 是 | v1 不引入结构体 |

反模式: ABI 传 `std::string/vector`; 结构体尾部追加就以为兼容; 事件指针回调期间
有效; 引擎线程直接进 Dart; `find_encoder_by_name` 当能力; shim 写预设/策略;
版本只报 commit; 取消时立即 `delete rec`; shutdown 里 join 网络线程。

### 5.7 初始化/关闭

- Windows: `avox.dll` 的 `DllMain` 已自动 `AvoxManager::init()`, DETACH 自动
  `clean()`; shim **不调用** `AvoxManager::init/clean`。
- `ak_shutdown` 顺序: 拒新 submit → 清 queued → running 置 cancel + close →
  有界等 worker(3s) → 置回调闸 → join 事件线程 → 刷日志。不 join 引擎线程。
- Dart 在 `AppLifecycleListener` 调一次; Windows runner `OnDestroy` 在
  `flutter_controller_=nullptr` 之前兜底; `ak_shutdown` 幂等。
- macOS/Linux 没有 DllMain, avox 也没有公开 init/shutdown C 入口; 记引擎缺口,
  M5 前补。代码结构现在就按“平台层只做路径/钩子, 核心共享”组织。

## 6. 能力探测与降级

| 能力 | 探测 | 结果 |
|---|---|---|
| ffmpeg 版本/配置 | `avcodec_configuration()`、`avformat_version()` | version/config_sha256/has_libmp3lame |
| 软编 | `avcodec_find_encoder_by_name` + **真编 3 帧** | verified |
| 硬编 | `h264_mf/hevc_mf` 真编 3 帧 | verified |
| 封装 | muxer 存在 + 小样本写头 | containers |
| 协议 | 编译配置 | protocols |
| 组件/插件 | 文件 + 引擎加载结果 | components |
| 模型 | manifest + sha256 | models |
| GPU/Vulkan | 引擎自检或真编一次 | gpu |
| URL/Range | 每个源 `ak_probe().can_seek` | 任务级 |

**硬编只认真编验证。** panvox 的 `hevc_mf` 就是 open 成功、首帧才死
(`panvox_c_api.h:607-611`)。kit 白名单只有 `h264_mf/hevc_mf`, 没有 qsv/amf/nvenc,
M1 的硬编面就是 MF 或软编。

Dart 侧统一 `CapabilityService` 持快照, UI/Planner 只读它, 不直接调原生探针。
降级矩阵:

| 场景 | 行为 |
|---|---|
| `hardware=auto`, MF 验证通过 | 用硬编 |
| `hardware=auto`, 失败 | 软编 + warning `hardware_unavailable` |
| `hardware=on`, 失败 | 提交前拒绝 `capability_missing` |
| 运行中编码失败 | `encode_failed` + hint `retry_software`, M1 不自动回退 |
| 容器/编码不支持 | 提交前拒绝, 带可选替代 |
| 模型缺失 | 任务不启动, `model_missing`; 工具页显示下载 CTA |
| 组件缺失 | capability false, 工具隐藏/灰置 |
| GPU/Vulkan 不可用 | `gpu.unavailable`; 是否可转码由真编结果决定 |
| URL 不支持 Range | `can_seek=false`, M2 先下载到临时目录 |

产品默认 `hardware=off`(软编 libx264/libx265): 画质与体积可控、不依赖驱动。
`auto`/`on` 是显式 opt-in, 换来速度; MF 质量档的 CRF 映射不如 x264 稳定,
同码率下通常体积更大或细节更少。

探测在 `ak_init` 后做一次, 进程级缓存; 驱动更新后由 `ak_refresh_capabilities`(预留)
重探。

## 7. 扩展成本模型

图例: **R**=Dart 数据(registry/schema/recipe/preset), **P**=Planner 规则,
**N**=shim handler, **E**=avox 引擎缺口, **M**=模型清单, **U**=专用 UI 编辑器,
**Q**=队列/分组核心(一次)。**没有一列是 ABI。**

| # | 功能 | kind | 新增 | 需要改什么 |
|---|---|---|---|---|
| 1 | 格式转换 | transcode | R | registry/schema/recipe |
| 2 | 压缩到目标大小 | transcode | R+P | 复用 1, 加码率换算/估算 |
| 3 | Remux | remux | N | 新 handler, 复用队列/事件 |
| 4 | 提取音频 | extract | N | 新 handler |
| 5 | ASR 生成字幕 | analyze | N+M | handler + 模型 manifest |
| 6 | 字幕翻译 | analyze | N+M | handler + 模型 manifest |
| 7 | 字幕提取 | extract | N+E | handler + avox SrtParser 写出 |
| 8 | 字幕烧录 | transcode | N+E | transcode handler 加 stage |
| 9 | 无损剪切 | remux | N+E+U | handler + 入出点编辑器 |
| 10 | 无损合并 | remux | N+E | handler + avox concat |
| 11 | 图片去水印 | image | N+M+U | handler + mask 编辑器 |
| 12 | 视频去水印 | transcode | N+M+U | transcode 加 inpaint stage |
| 13 | 抽帧/封面 | extract | N | handler |
| 14 | GIF/WebP | transcode/image | N+E | handler + 引擎编码器 |
| 15 | 批量队列 | — | Q | 一次 TaskGroup 核心, 之后自动获得 |
| 16 | URL 直链 | 同 recipe | N | handler 加 fetch stage |
| 17 | 预设/预设市场 | — | R | 数据 + 导入/导出 |
| 18 | 音量归一化 | transcode/extract | N+E | audio_filter stage |
| 19 | 音轨增删/替换 | remux | N | select_tracks 复用 |
| 20 | 画质增强 | transcode | N+M | video_filter stage + 模型 |

结论: 20/20 不改 ABI; 3 项纯数据; 11 项只动 shim; 5 项等 avox 补缺口; 2 项需要
专用编辑器; 1 次队列核心改动。

**新增功能 checklist:** 注册 ToolSpec → 写 OptionSchema → 复用/新增 Recipe →
需要则加 Preset → 需要则加 ModelSpec → 新原语才加 handler + 注册一行 → 需要才加
专用 editor → schema/planner 单测 + 真实素材集成 → 不改 shell/侧栏/任务中心。

## 8. UI 信息架构

| 分组 | 初始 | 后续 |
|---|---|---|
| 转换 | 格式转换、压缩 | 重封装、批量转换 |
| 音频 | 提取音频 | 音频格式转换、音量归一化 |
| 字幕 | 生成字幕(M3) | 提取、翻译、烧录 |
| 图片 | 图片去水印(M3.5) | 视频去水印、抽帧、GIF/WebP |
| 剪辑 | 无损剪切(M4) | 无损合并 |
| 任务 | 全部/进行中/失败/批量组 | 持久化历史(可选) |
| 设置 | 通用、模型、能力、预设、诊断、关于 | — |

侧栏、路由、任务过滤、模型中心行、预设列表全部由 `ToolRegistry` 派生; 不手写
导航。`ToolSpec` 字段: id/domain/group/order/titleKey/descKey/icon/platforms/
input(类型、数量、是否 URL)/recipeId/schemaId/presets/previewMode/customEditor/
capabilities/models/status/outputPolicy。

`ToolPage` 固定骨架: 页头 → 左栏(拖放/源列表/MediaInfo/MediaPreview) → 右栏
(OptionForm + 输出位置 + 估算 + 运行) → 最近任务(过滤 TaskCenter)。只有 mask 和
trim 两种字段挂专用编辑器, 其余全部 schema 渲染。

输入区统一一个入口, 接受 文件 / 文件夹 / URL; `ToolSpec.input` 声明
`accepts(file/folder/url)`、`expansion(fanout/aggregate)`、`acceptExtensions`、
`recursiveDefault`、`maxItems`。文件夹的展开规则见 §15。

任务中心统一列表 + 分组折叠; 每卡: 来源徽标、工具名、状态、stage、进度、ETA、
取消/重试/打开产物/打开日志。重试创建新 Task(`retry_of`), 原任务保持终态。

设置: 通用/模型中心/能力/预设/诊断/关于。模型中心由 ModelRegistry 生成行, 所有
工具共享; 能力页显示引擎/ffmpeg 版本、硬编、容器/编码/stage、重新探测。

预览: 统一 `MediaPreview` 四模式(frame/filmstrip/waveform/image-canvas); 预览是
`priority=preview` 的轻任务, 独立 lane, 可取消、有缓存; 失败退化为进度条; 不做
播放 transport。

批量: 输入基数 `many` 的工具复用同一 ToolPage; 批量=TaskGroup; 默认串行; 逐项
覆盖由 schema `perItem` 决定, 默认不允许。

国际化: zh-Hans 为源语言, en 从 M1 进 ARB; 不复制 panvox 的 13 语种。ToolSpec/
Schema 只存 key; native 只返回 code; lint 禁止 UI 层中文字面量。ASR 识别语言是
任务参数, 不是 UI locale。

## 9. 横切规则

| 规则 | 实现 |
|---|---|
| 本地/隐私 | 网络出口白名单: URL fetch、模型/组件显式下载、可选预设目录。无遥测、无上传、无云同步; 静态扫描越界 socket |
| 免费/无账号 | 不引入 auth/entitlement/配额/水印模块; 无付费入口 |
| 错误/空态 | 稳定 code + category + retryable + hint + detail; UI 映射 ARB; 不允许只有 failed |
| 日志 | `<work_dir>/logs/avoxkit-YYYYMMDD.log`, 按天/大小滚动; 桥接 avox `setLogAction`; 默认 info; debug 用环境变量 |
| 任务时间线 | 每任务事件环(256 条); M1 UI 显示最近 5 条; M2 加 `ak_task_diagnostics` |
| 模型 | 统一 ModelManifest/ModelStore; 显式下载或离线导入; sha256; 原子安装; 不做静默下载 |
| 预设 | JSON schema 校验; 内置只读; 用户可复制/导入导出; 只含参数补丁, 不含路径/命令 |
| 安全 | 路径规范化、拒绝相对路径、防目录穿越; URL 仅 http(s)/rtsp/rtmp 直链; 不执行 shell; 模型包防 zip slip |
| 性能 | 重任务并发 1; 预览独立 lane; 进度 5Hz; 取消 5s 看门狗; 终态必发 |
| 平台 | Windows 先行; 启动自检配置串/哈希; 三端共享 avtool_core, 平台层只做路径/DLL/钩子 |

## 10. 测试与交付

**`ak_smoke` 必须先于 Flutter 页面存在:**

```
ak_smoke version
ak_smoke init <workdir>
ak_smoke caps
ak_smoke probe <file>
ak_smoke transcode <in> <out> [--hardware off|auto|on]
ak_smoke cancel <in> <out> --at 30%
ak_smoke stress --n 100 --cancel
```

**伪引擎**: shim 内部抽象 `IEngineBackend`, 真实实现包 `IRecorder`, 伪实现按脚本
产生 progress/state/complete/error/hang; CI 不链接 avox.dll 也能测取消竞态/状态机。

**集成素材**: 10 秒 720p→H.264 MP4; 中文/空格/长路径; 只读目录; 损坏源; 30%
取消; 连续 100 次提交/取消; 硬编不可用; 错 ffmpeg DLL。

**CI 最小集**: Windows Flutter analyze/test/build; Windows/Linux fake shim 单测;
macOS compile-only; 真实引擎集成放 nightly/手动。panvox 的 CI 只做 Flutter,
原生靠人工 `*_test.exe`, avoxkit 至少把 shim 编译和 fake engine 测试放进 CI。

**部署**: 只带 kit ffmpeg + avox.dll + shim; `runtime-manifest.json` 记录每个运行时
文件的 sha256/版本; 启动自检 `--enable-libmp3lame`、`libmp3lame`、`aac`、版本哈希;
不自动下载/替换 DLL; 不做静默自更新。可选组件放 `components/`/`plugins/`, 缺失时
capability false, 安装后要求重启。

## 11. M1 冻结面 / 预留口 / 明确不做

### 11.1 冻结

| 类别 | 内容 |
|---|---|
| C ABI | `ak_abi_version`、`ak_version_json`、`ak_init(config_json)`、`ak_shutdown`、`ak_set_event_cb`、`ak_event_free`、`ak_task_submit`、`ak_task_cancel`、`ak_task_remove`、`ak_probe`、`ak_capabilities_json`、`ak_encoder_probe`、`ak_free_string` |
| 任务 JSON | schema、client_task_id、group_id、retry_of、kind、sources[]、outputs[]、params、resources |
| 事件 JSON | v、seq、ts_ms、task_id、run_id、group_id、type、state、stage、stage_index、stage_count、current_ms、total_ms、pct、code、category、retryable、message、detail、hint、outputs |
| 状态机 | queued→running→done/failed/cancelled; 内部 starting/running/draining/terminal |
| 错误 | code/category/retryable/hint 四元组 + M1 错误表 |
| Artifact | 输入只读; `stem.avoxkit-part.ext` 同目录; 成功 rename; 失败/取消删除; 预检清理 |
| 能力 | encoders/codecs/containers/components/protocols/features; 硬编真编验证 |
| 队列 | 单 worker; FIFO; maxConcurrency=1; queued 可 remove; running 只能 cancel |
| 生命周期 | ak_init 幂等; ak_shutdown 幂等有界; Dart + runner 双钩子 |
| 部署 | `/MT`; kit ffmpeg 自检; runtime-manifest; 版本哈希 |
| 测试 | ak_smoke; fake engine; shim 单测; Flutter analyze/test |

### 11.2 预留口

`priority`/`lane`、多 `outputs[]`、`ak_pause_dispatch`、`ak_task_retry`、
`ak_task_diagnostics`、`ak_set_log_level`、`ak_refresh_capabilities`、
`component-manifest.json`、新 stage 字符串、`capabilities.features`、
TaskGroup 的 `group_id` UI。

### 11.3 明确不做

通用 DAG、多 worker、运行中暂停/恢复、自动重试/退避、M1 任务持久化、
M1 批量 UI、URL/网络源、模型下载器/插件安装器、热加载/热替换、自更新、
多产物事务、播放器/时间线、结构体 ABI、shim 内预设/文案/输出命名策略、
文件夹监听/自动入库。

## 12. 关键决策(默认建议)

| # | 决策 | 默认 |
|---|---|---|
| 1 | 功能模型 | ToolSpec+Schema+Preset+Recipe; 5 个 kind |
| 2 | pipeline 归属 | shim handler 内部; 线性; 不做 DAG |
| 3 | 事件所有权 | 堆事件 + `ak_event_free` |
| 4 | 事件线程 | 唯一事件线程; 引擎线程只入队 |
| 5 | `ak_init` | config JSON(work_dir/models_dir/log_level) |
| 6 | 取消 | 立即 `cancelled` + draining 隔离; 不提前 delete |
| 7 | 并发 | M1 单 worker; 预览 lane M2 |
| 8 | 硬编 | auto; 真编验证; 失败不自动回退 |
| 9 | 输出覆盖 | 默认拒绝; UI 确认后 overwrite=true |
| 10 | 失败/取消产物 | 删除 `.part`; rename 失败例外保留 |
| 11 | 任务持久化 | M4; M1 内存 + client_task_id |
| 12 | 模型/组件 | 显式安装/离线导入; 不静默下载 |
| 13 | 国际化 | zh-Hans + en; 不再扩语种 |
| 14 | 预设 | Dart 展开; 导入/导出; 不做在线市场 |
| 15 | 第三方插件 | 不做; 扩展点编译期内置 |
| 16 | 跨平台 | Windows 先行; 代码结构支持三端; init/shutdown 缺口 M5 前补 |
| 17 | 文件夹输入 | Dart 展开为 TaskGroup; 执行层只收具体文件; 不做 folder kind |
| 18 | 批量输出 | sidecar/mirror/flat 由 ToolSpec 声明; 默认跳过已存在输出 |
| 19 | 文件夹监听 | 不做; 需要时单独立项, 不复用批任务模型 |

## 13. panvox 踩坑索引(只读借鉴, 不复制代码)

| 教训 | 证据 | avoxkit 规避 |
|---|---|---|
| ABI 按功能长, 102 个导出、start/start2/start_ex 多代入口 | `panvox/native/include/panvox_c_api.h` | 只冻结信封; 新功能加 handler 不加导出 |
| 每功能一套 worker/取消/终态 | `pvx_thumb.inc`、`pvx_aisub.inc`、`pvx_enhance.inc` | 一个 TaskRuntime/队列/事件 |
| 退出期回调 SIGSEGV(Dart VM 已销毁) | `docs/reports/exit-callback-sigsegv-20260929.md` | 唯一事件线程 + 回调闸 + Dart/runner 双钩子 |
| 产品策略写进 shim(倍率/码率/凭据) | `pvx_enhance.inc:111-127`、`panvox_c_api.h:553-558` | 预设/策略全在 Dart |
| 模型状态机整件镜像 | `app/lib/core/models/enhance_model.dart:11` | 一个 ModelStore/Manifest |
| 任务页/设置页硬编码 | `settings_tasks_page.dart` 1131 行、`app_shell.dart:98-109` | registry 驱动 UI |
| 页面直接查原生探针 | `settings_tasks_page.dart` | CapabilityService 抽象 |
| 结构体尾部追加导致 ABI bump | `panvox_c_api.h:26-35` | v1 不用结构体 |
| 静态 CRT 错配 `std::mutex` 崩 | `docs/reports/2026-09-14-msvcp140-mutex-crash.md` | shim `/MT`; ABI 只 C/POD/JSON |
| 版本自报会撒谎 | `.workbuddy/memory/2026-09-22.md` | 版本 + 文件哈希 + 配置串 |
| shim 旧副本导致“引擎修了 app 没好” | `.workbuddy-ai/memory/2026-10-04.md` | 一个部署脚本 + manifest 校验 |
| ffmpeg bin/lib 不同批序号错位 | `docs/avox-build-and-deploy.md` §2.6 | bin/lib 同批; 名字导入库; 哈希 |
| 取消后提前 delete/worker 继续跑 | `pvx_enhance_cancel` | draining 隔离; 不提前 delete |
| 硬编 open 成功首帧死 | `panvox_c_api.h:607-611` | 真编 3 帧验证 |
| 打开失败污染后续任务 | `docs/reports/open-hang-pollution-20260925.md` | 每任务独立 recorder; open 超时; 状态复位 |
| URL 直链 seek 卡死 | `docs/reports/2026-09-24-nas-http-avi-seek-hang.md` | fetch stage + 看门狗 + Range 探测 |
| 模型缺失静默回退冒充完整产物 | `docs/design/ai-video-enhance-frontend-integration.md` | 显式阻断/标注, 不静默 |

## 14. 与现有文档的关系

- 本文取代 `docs/architecture.md` 的 §1 分层、§2 ABI 草案、§3 任务模型;
  §4 功能→引擎映射、§5 引擎缺口、§6 构建配方、§7 里程碑仍然有效。
- `docs/m1-plan.md` 的取消语义、硬编开关、`ak_init` 形状、事件所有权按本文
  §4/§5 修正; M1 冻结面下一轮同步。
- `docs/m1-kickoff.md` 的构建门/实测事实仍有效; ABI 部分以本文 §5 为准。
- `docs/ui.md` 的 token 与组件清单仍然有效; ToolSpec/Recipe 的字段以本文 §8 为准。

## 15. 文件夹与批量输入(2026-10-26 补充)

> 场景: 选中一个文件夹, 对目录下所有视频做同一件事, 例如“给文件夹下所有视频
> 提取字幕”。本节把这种输入纳入上面的模型, 不新增 kind、不改 ABI。

### 15.1 结论

- **文件夹是规划层的 `InputSelection`, 不是 task kind, 不进 ABI。** Dart 扫描/过滤后
  展开成 N 个普通 TaskSpec, 用一个 `group_id` 归组; shim 执行时永远只看到具体文件。
- 这样重试、进度、取消、部分失败、输出命名全部复用单文件任务, 不需要一套“批处理
  引擎”。
- 必须区分三种语义, 不要混成一个“文件夹功能”:

| 语义 | 例子 | 任务形态 | 产物 | 现在做? |
|---|---|---|---|---|
| **fan-out 批处理** | 文件夹下每个视频提取字幕/转码 | N 个 Task, 每个 1 个源 | N 份产物 | M2 |
| **aggregate 聚合** | 文件夹下所有视频合并成一个 | 1 个 Task, `sources[]` 有序 | 1 份产物 | M4(需 concat) |
| **watch 监听** | 监控文件夹, 新文件自动处理 | 常驻调度器 | 持续产物 | **不做**, 需要时单独立项 |

“提取字幕”两种实现都是 fan-out: 抽已有字幕轨是 `extract`, 离线识别是 `analyze`;
同一个 TaskGroup 模型, 只是耗时/模型要求不同。

### 15.2 ToolSpec 的输入声明

```json
{
  "input": {
    "accepts": ["file", "folder", "url"],
    "expansion": "fanout",
    "acceptExtensions": ["mkv", "mp4", "mov", "avi", "ts", "flv", "webm", "wmv"],
    "recursiveDefault": true,
    "maxItems": 5000,
    "dedupe": "canonical_path"
  }
}
```

- 单输入工具(`trim`、`image` 单图)把 `folder` 从 `accepts` 去掉, UI 不显示“选择文件夹”。
- `aggregate` 工具的文件夹语义是“把匹配文件按顺序追加到源列表”, UI 必须显示顺序并
  允许拖动排序; 不能默默按扫描顺序合并。
- `acceptExtensions` 由工具/域声明, 不靠猜。字幕/音频提取仍按视频扩展名收文件;
  图片工具按图片扩展名。
- `maxItems` 是保护上限; 超过时停止扫描并让用户缩小范围, 不静默截断。

### 15.3 扫描与展开规则

1. **默认递归**, 但提供“包含子文件夹”开关; 扫描前显示匹配数量。
2. 按**相对路径自然排序**(数字感知, 如 `第2集` 在 `第10集` 前), 顺序稳定。
3. 过滤: 扩展名白名单 + 跳过隐藏/系统文件、`.avoxkit-part`、临时目录、以及**本工具
   自己会产出的文件**(防止把上次输出再处理一遍)。
4. 规范化路径去重; **默认不跟随符号链接**; 深度上限(如 32)与数量上限
   (`maxItems`)。
5. **提交时快照**: 之后文件夹新增/删除文件不自动加入队列; 用户要重新扫描。
6. 单个条目无权限/断链/损坏: 记为 skipped + 原因, 不中断整个扫描。
7. 扫描在后台 isolate 做, 先返回首页结果; 大目录虚拟化列表; 扫描可取消。
8. NAS/UNC: 显示“扫描中”; 断连时组级失败(或已开始的任务逐个失败), 不静默重试。
9. **规划阶段不逐个 probe**: 1000 个 NAS 文件逐个 probe 会很慢。probe 放在任务
   `open` 阶段; 组的 ETA 用“已完成任务的平均耗时”估算。小批量可选“预扫描时长”。
10. 扫描默认在 Dart isolate; 若将来 NAS 大目录性能不够, 再加 `ak_list_dir` 追加
   符号, 不改现有 ABI。不要为了扫描把文件夹塞进 task JSON。

### 15.4 输出策略

由 `ToolSpec.outputPolicy` 声明默认值, 用户可以改输出根目录:

| 策略 | 规则 | 适用 |
|---|---|---|
| `sidecar` | 源同目录, 同名换扩展名(如 `a.mkv` → `a.srt`) | 提取字幕/音频、ASR |
| `mirror` | 输出根目录 + 源的相对子路径 | 转码/压缩批量 |
| `flat` | 输出根目录 + 文件名; 冲突加后缀 | 小批量/临时 |

- 冲突默认 **skip**(输出已存在就跳过), 用户可切 overwrite(需确认)或 suffix。
- 输入路径 = 输出路径直接拒绝; 同目录批量时跳过本工具自己的输出。
- 文件夹有统一根, 可以 `mirror`; 多选文件没有共同根, 只能用 `sidecar`/`flat`,
  或让用户选输出根 + suffix。
- `sidecar` 写到源目录在只读 NAS 上会失败; 预检时提示改用输出根目录。
- 多产物用 `outputs[]` 的 role 区分; 字幕命名: 已知语言用
  `<basename>.<lang>.srt`, 否则 `<basename>.srt`。
- 提交前把“将被跳过”的数量算出来展示, 不让用户等到跑完才发现。

### 15.5 TaskGroup 与队列

- 每个 TaskSpec 带 `group_id`; 组元数据(根目录、展开选项、计数、显示名)由 Dart 持有,
  shim 不需要懂“批”。
- 组状态: `planning → queued → running → completed | partial | failed | cancelled`;
  计数: `total/done/failed/skipped/running/queued`。
- 组进度 = 已完成/总数 + 失败/跳过数; 有真实时长时按总时长加权, 没有就按任务数。
- 取消组: 先取消 queued, 再对 running 逐个 cancel; M1/M2 用 Dart 循环, 预留
  `ak_cancel_group` 以后再说。
- 重试失败项: 为 failed 项创建新 Task(`retry_of`), 保留原组; UI 只提供“重试失败项”。
- M1/M2 仍单 worker; 一个 500 文件的组会形成长队列, UI 必须显示 queued 数量并允许
  整组取消。
- **公平性**: 大组会饿死一个快速单任务。`priority/lane` 已在信封里预留; M2 可加
  “整组前移”或快速任务优先, M1 不暴露优先级。

### 15.6 部分失败

- 单文件失败只影响该 Task, 组继续跑, 最终 `partial`。
- 组级失败(扫描失败、输出根不可写、模型缺失)在开始前阻断, 已入队的任务取消。
- 结果摘要: 成功/失败/跳过数量 + 每文件错误码/原因; 支持“只看失败”“重试失败项”。
- 全部失败 = `failed`; 有成功有失败 = `partial`; 全跳过 = `completed` + skipped 计数。

### 15.7 幂等与续跑

- 默认 **skip 已存在输出**; `client_task_id` 用
  `group_id + relative_path + params_hash` 生成, 便于重复提交时识别。
- 提交前清理同名残留 `.avoxkit-part`; 检查输出已存在时直接标 skipped, 不启动任务。
- M1 不持久化任务簿, 关应用就丢队列; 长批量(尤其 ASR)要在提交前提示“关闭会中断”。
- M4 的 `TaskRepository` 恢复组与已完成项; 因 ASR 批量耗时长, 组持久化可能提前到 M3。

### 15.8 UI

- 输入区统一: 拖放(文件或文件夹) + “选择文件” + “选择文件夹” + “粘贴链接”。
- 文件夹卡: 路径、匹配数量、递归开关、扩展名过滤、“查看/排除”列表; 数量实时更新。
- 展开列表虚拟化, 带复选框、相对路径、全选/反选; 支持先排除几个再提交。
- 提交前摘要: “将处理 N 个文件, 预计 …; 已存在将跳过 M 个; 输出策略 …”, 以及
  空目录/超过上限/输入输出同路径等警告。
- 任务中心: 组卡 + 可展开子任务; 组卡显示进度、计数、整组取消、重试失败项、
  打开输出目录; 子任务卡显示相对路径与来源徽标。
- 失败筛选: 按组过滤“只看失败”; 错误码 + 文件路径, 不显示一长串引擎日志。
- 空态: 告诉用户接受哪些扩展名、为什么 0 个匹配。

### 15.9 边界情况

| 情况 | 行为 |
|---|---|
| 空目录/无匹配 | 空态, 不创建组 |
| 超过 `maxItems` | 停止扫描, 提示缩小范围或分批 |
| 某文件无权限 | skipped + 原因, 继续 |
| NAS 断连 | 扫描阶段组失败; 运行中剩余任务逐个失败, 组 partial |
| 子目录同名文件 | `mirror` 保留结构; `flat` 加后缀 |
| 输出已存在 | 默认 skip; 可 overwrite/suffix |
| 输出目录在源目录内 | 跳过本工具输出, 防递归处理 |
| 隐藏/系统文件 | 跳过 |
| 符号链接 | 默认不跟随; 规范化去重 |
| 运行中文件夹变化 | 不改已提交快照 |
| 超长/中文路径 | UTF-8; Windows 长路径边界用例 |
| 磁盘空间不足 | M2 起按估算大小提示; M1 至少失败可读 |
| 模型缺失 | 组开始前阻断, 显示下载 CTA |
| 单个文件损坏 | 该任务失败, 组 partial |
| 某文件无字幕轨/无音轨 | 该任务 `no_subtitle_track`/`no_audio_track`, 组 partial |
| 源目录只读(NAS)+ sidecar | 预检提示改用输出根目录 |
| 输出根中途不可用 | 剩余任务失败, 组 partial |
| 全部失败 | 组 failed |

### 15.10 批量性能

- 模型/session 在进程内**加载一次**, 由引擎缓存复用; 不能每个文件重新加载 ASR/
  inpaint 模型。
- 优先“每文件一个 Task + 模型缓存”, 保住逐文件进度/重试/取消; 不要为了省开销做成
  一个黑盒批处理 handler。
- 只有在实测“每任务模型加载/初始化开销 > 总耗时 20%”时, 才考虑 batch handler
  内部循环但按文件发子事件; 先测量再优化。
- 规划阶段不预 probe; UI 更新节流; 大列表虚拟化。

### 15.11 里程碑

| 里程碑 | 内容 |
|---|---|
| M1 | 单文件; 信封里已有 `sources[]`/`group_id`, 不实现文件夹 UI |
| M2 前置 | 文件夹展开 + fan-out TaskGroup(基础组卡、skip 已存在) |
| M2 | 组 UI 完整(取消/重试失败/输出策略); remux/extract 也支持文件夹 |
| M3 | ASR 长批量; 组持久化视需要提前 |
| M4 | aggregate(合并)与完整批处理 |
| 以后 | watch 监听单独立项, 不复用本模型 |

**一句话**: 文件夹是“选源方式 + 规划展开”, 不是新的执行种类; 展开后仍是一堆普通
文件任务, 用 `group_id` 归组。这样批量能力只实现一次, 所有工具自动获得, 且不碰
`ak_*` ABI。
