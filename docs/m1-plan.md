# M1 编码方案(Windows 先行, 2026-10-26)

> **历史文档（2026-10-26）**：本文是 M1 当时的实现口径，部分决策后来已调整
> （如硬编默认值、音频码率、预览与批量）。当前用户功能与边界以
> `docs/features.md` 为准；保留本文仅用于追溯设计过程。

> 目标: avox 链接打通, 跑通第一条 `transcode` 全链(提交→进度→取消→完成),
> 建立队列 v0 与 `ak_*` shim 的最小冻结面。本文是实现口径, 架构背景见
> `docs/architecture.md`。
>
> 落地执行、构建门与实测校正见 `docs/m1-kickoff.md`; 两者冲突时以 kickoff 的
> 实测事实为准。ABI/事件所有权/取消语义/能力探测以
> `docs/functional-architecture.md` §4/§5 为准。

## 0. 完成定义(DoD)

- `avoxkit_native.dll` 可加载; `ak_version/ak_init/ak_shutdown` 正常。
- 启动自检通过: 运行中的 `avcodec` 是 kit build(`--enable-libmp3lame`),
  avox 初始化成功; 任一失败给出明确错误码, 不进入主界面。
- 单文件转码: 选本地文件 → 提交 → 进度事件 → 完成; 输出文件可播放。
- 取消: 运行中取消 1 秒内回到 `cancelled`, 不残留半成品输出。
- 队列 v0: 并发 1, 五态 `queued/running/done/failed/cancelled` 正确流转。
- Flutter 侧: 转换页可用(选文件/参数/提交), 任务页实时显示状态与进度。
- Windows `flutter run --release` 可跑; DLL 随构建产物部署。
- 单测 + 一条集成用例(10 秒素材)通过。

## 1. 关键决策

| # | 决策 | 理由 |
|---|---|---|
| D1 | ffmpeg 运行时替换: 打包只带 kit 的同名 DLL | avox CMake 写死 3rdparty, 不能换 SDK; 版本同为 9.0.1, SONAME 一致 |
| D2 | shim: C++17 + `extern "C"`, JSON 用 vendored nlohmann/json(MIT) | 面窄、免 ffigen、参数可演进 |
| D3 | 单 worker 队列 + 独立事件线程; 回调注册一次 | 引擎对象非线程安全, 串行化最稳; Dart 只收事件 |
| D4 | 任务 JSON 统一 `source{kind,uri}`; M1 只允许 `kind=file` | 为 M2 的 URL 直链留口, 不返工 |
| D5 | 硬编默认开; M1 并发固定 1 | 先求稳, 探测通过后放宽到 2 放 M2 |
| D6 | 取消 = `close()` 排空, 不杀线程; 删除半成品 | 引擎的 close 语义就是优雅收尾 |
| D7 | 进度节流 5 Hz + 终态必发 | 避免事件风暴; UI 仍平滑 |
| D8 | Dart 回调用 `NativeCallable.listener` | 从原生线程回调 Dart 的安全路径 |

## 2. 目录结构

```
native/
  avtool/
    CMakeLists.txt
    include/ak.h              // 唯一公开头, extern "C"
    src/ak_api.cpp            // C 边界: 参数校验/字符串所有权
    src/ak_engine.cpp/.hpp    // init/shutdown/ffmpeg 自检/日志
    src/ak_task.cpp/.hpp      // Task 模型/队列/worker/状态机
    src/ak_json.cpp/.hpp      // 任务 JSON 解析与默认值
    src/ak_event.cpp/.hpp     // 事件序列化/派发线程
    src/ak_log.cpp/.hpp
  third_party/nlohmann/json.hpp
lib/
  native/ak_bindings.dart     // DynamicLibrary.open + 函数签名 + Utf8 转换
  native/ak_events.dart       // 事件模型 + Stream
  core/engine.dart            // init/shutdown/submit/cancel/事件分发
  core/task.dart              // Task/状态机/进度
  core/tool_registry.dart     // ToolSpec(扩展点)
  core/option_schema.dart     // 声明式参数
  ui/shell/, ui/pages/, ui/widgets/
third_party/ffmpeg/kit/       // 构建产物, .gitignore
```

## 3. ABI v0(冻结面)

```c
const char* ak_version(void);                 // shim/avox/ffmpeg 版本 JSON
int         ak_init(const char* work_dir);    // UTF-8; 建日志/临时目录
void        ak_shutdown(void);
int         ak_set_event_cb(ak_event_cb cb, void* user);  // 只注册一次

int64_t     ak_task_submit(const char* task_json); // <0 错误码
int         ak_task_cancel(int64_t task_id);
int         ak_task_remove(int64_t task_id);       // 仅 queued 可移除
const char* ak_probe(const char* uri);             // JSON, ak_free_string 释放
int         ak_encoder_probe(void);                // 1 可用 / 0 不可用
void        ak_free_string(const char* s);         // shim 分配, shim 释放
```

- 字符串所有权: 返回值由 shim 分配, 调用方必须 `ak_free_string`;
  事件里的 `event_json` 仅在回调期间有效。
- 同一进程只允许一次 `ak_init`; 重复调用返回 `AK_E_ALREADY_INIT`。
- 事件回调在 shim 事件线程串行触发, 不得在回调里调用 `ak_shutdown`。

### 任务 JSON(M1)

```json
{"kind":"transcode",
 "source":{"kind":"file","uri":"C:/media/input.mkv"},
 "output":"C:/media/output.mp4",
 "video":{"codec":"h264","hardware":"off","rate_mode":"quality",
          "quality":60,"bitrate_kbps":0,"resolution":"source","fps":0},
 "audio":{"codec":"aac"},
 "container":"mp4"}
```

### 事件 JSON

```json
{"type":"state","task_id":1,"state":"queued"}
{"type":"state","task_id":1,"state":"running","stage":"opening"}
{"type":"progress","task_id":1,"current_ms":1200,"total_ms":60000,"pct":2.0}
{"type":"error","task_id":1,"code":"input_open_failed","stage":"open","message":"..."}
{"type":"done","task_id":1,"output":"C:/media/output.mp4","duration_ms":60000}
```

错误码: `bad_json / bad_source / unsupported_kind / output_not_writable /
input_open_failed / decode_failed / encode_failed / mux_failed / cancelled /
shutdown / already_init / not_initialized / ffmpeg_mismatch`。

## 4. shim 内部

- **状态机**: `queued → running(opening→recording→closing) → done|failed|cancelled`。
  终态只写一次; 所有状态变化同时发 `state` 事件。
- **队列**: `mutex + condition_variable + 1 worker`。submit 只做校验和入队;
  worker 串行创建/打开/关闭 recorder。M1 并发 1, 结构上留 `maxConcurrency`。
- **取消**: 控制线程置 `cancelRequested`, 对 running 任务调用 `recorder->close()`
  (引擎排空语义); worker 等 `onComplete/onClose` 后删半成品、发 `cancelled`。
  queued 任务直接从队列摘除。
- **进度**: `RecorderProgress{currentTimeMs,totalTimeMs}` → 百分比; 200ms 节流;
  总时长未知(直播)时只发 `current_ms`, 不发 `pct`。
- **事件线程**: 单消费者 MPSC(互斥队列即可); 序列化 JSON 后回调; 回调内异常
  全部捕获, 绝不让异常穿过 C 边界。
- **关闭顺序**: 停止接收 → 取消所有 running → join worker → 移除观察者 →
  `AvoxManager::clean()` → 释放回调 → 幂等。
- **路径**: Windows 在边界做 UTF-8 ↔ UTF-16 转换; 拒绝空路径与相对路径。
- **ffmpeg 自检**: `avcodec_configuration()` 含 `--enable-libmp3lame` 且
  `avcodec_find_encoder_by_name("libmp3lame")` 非空; 否则
  `ak_init` 返回 `ffmpeg_mismatch`。

## 5. 引擎调用链(transcode)

```cpp
AvoxManager::Get().init();
IRecorder* rec = createRecorder(true);        // TranscodeRecorder
rec->setVideoCodec(VCodecId::h264);
rec->setAudioCodec(ACodecId::aac);
VideoEncodeParam p;
p.rateMode = EncodeRateMode::quality;
p.quality  = 60;
p.usage    = EncodeUsage::record;
rec->setVideoEncodeParam(p);
// 分辨率变化: VideoDesc{width,height,fps=0}; 不变则不调
addRecorderOb(rec, &ob);                      // 全局 C 接口
ob.onProgress  -> 节流 -> progress 事件
ob.onStateChange -> state 事件
ob.onComplete/onIoError/onEncodeError -> 终态
rec->open(inputUri, outputPath);              // 返回 false 即 open 失败
rec->close();                                 // 取消或收尾
removeRecorderOb(rec, &ob);
delete rec;                                   // 工厂所有权: 核实后按实际约定
```

- 硬编: 默认开, 走 `rec.hard.encode`; 失败时由上层重试为软编(M1 先手动重试)。
- 音频: `AudioDesc{channels,format,sampleRate}` 只管格式/重采样, **没有码率字段**;
  M1 用编码器默认(128k 量级)。码率旋钮列为引擎缺口, M2 视需要补。
- 转封装/直拷在 M2 用 `createRecorder(false)` 或 `TransMode`。

### UI 旋钮 → 引擎字段

| UI | 字段 |
|---|---|
| 质量滑杆 0-100 | `VideoEncodeParam.quality` |
| 目标大小 MB | `bitrate_kbps = (MB*8*1024*1000/duration_s) - audio_kbps`(M1 单遍估算) |
| 分辨率 | `VideoDesc.width/height`(保持源则不调) |
| 编码 H.264/H.265 | `setVideoCodec` |
| 硬编 auto/off | `rec.hard.encode` + `ak_encoder_probe` |
| 容器 | 输出扩展名 + `MuxerType`(M1 固定 ffmpeg) |

预设(B站/抖音/微信/Discord)在 Dart 层展开成上表字段, shim 不认识预设名。

## 6. 构建

1. **avox**(一次): `cmake -S ../avox -B ../avox/build-avoxkit -G "Visual Studio 17 2022" -A x64`
   加 `-DAVOX_DIST_FLAVOR=agpl -DAVOX_ENABLE_FDKAAC=OFF
   -DAVOX_ENABLE_WEBRTC=OFF -DAVOX_ENABLE_ZLMEDIAKIT=OFF
   -DAVOX_ENABLE_SWIG=OFF -DAVOX_ENABLE_GODOT=OFF -DAVOX_ENABLE_UNITY=OFF
   -DAVOX_ENABLE_CLI=OFF -DAVOX_ENABLE_SAMPLES=OFF -DAVOX_ENABLE_PLUGINS=OFF`
   (M1 不开插件; M3 再开 sherpa/cv)。产出 `avox.dll + avox.lib`。
2. **shim**: `native/avtool/CMakeLists.txt` 通过 `AVOX_ROOT`(默认 `../avox`)与
   `AVOX_BUILD_DIR` 找头文件/导入库; 链接 `avox.lib` + kit 的
   `avcodec.lib/avutil.lib`(自检用)。
3. **Flutter**: `pubspec.yaml` 加 `ffi: ^2.1.0`; Windows runner 构建后把
   `avoxkit_native.dll / avox.dll / kit 的 avcodec-63 等 + libmp3lame/x264/x265/
   zlib1/libwinpthread` 拷到 exe 同目录。**不要拷 avox 3rdparty 的 ffmpeg**。
4. **运行**: `flutter run --release`; 启动日志打印实际 avcodec 配置串。

## 7. Flutter 侧

- `ak_bindings.dart`: `DynamicLibrary.open('avoxkit_native.dll')`; 所有
  `const char*` 用 `toNativeUtf8()` / `Utf8.fromUtf8()`; 返回值用完 `ak_free_string`。
- 事件: `NativeCallable<Void Function(Pointer<Utf8>, Pointer<Void>)>.listener`
  → `StreamController<AkEvent>.broadcast()`; 解析 `type` 后分发。
- `Engine`: 启动时 `ak_init`; 失败页显示错误码与修复建议(如 DLL 放错)。
- `TaskStore(ChangeNotifier)`: 持有 Task 列表; 事件更新状态/进度; 队列页与
  工具页共用。进度只保留最近值, 历史不入内存。
- `ToolRegistry`: 每个 ToolSpec 声明 page builder / task kind / 参数 schema;
  转换页是第一个实例。
- M1 不做 `MediaPreview`; 进度先用数字 + 进度条, 预览在 M1.5/M2 接。

## 8. 测试与验收

- 单测: JSON 解析/默认值/错误码; 队列状态机(含取消 queued/running)。
- 集成: 10 秒 720p 素材 → H.264 MP4; `ak_probe` 校验时长/分辨率;
  30% 时取消, 断言 `cancelled` 且输出不存在。
- 边界: 中文/空格路径、长路径、只读输出目录、源文件被占用、重复取消。
- 稳定性: 连续 100 次提交/取消, 进程句柄与内存不持续增长。

## 9. 风险

| 风险 | 缓解 |
|---|---|
| 运行时装错 ffmpeg DLL | 启动自检配置串 + 打印 DLL 路径 |
| avox 与 kit 的 FFmpeg 配置差异导致符号缺失 | 同版本 + 白名单为 avox minsize 超集; CI 里跑一次真实转码 |
| 回调解引用 Dart 已释放对象 | 回调只发 JSON 字符串, user 指针在 shutdown 前置空 |
| close 与 onComplete 竞态 | 终态只写一次; 状态机加锁 |
| 硬编不可用/驱动异常 | open 失败 → 状态带 stage; M1 手动重试软编 |
| 半成品输出 | 失败/取消后删除; 写临时文件名, 完成再 rename |

## 10. 任务拆分

| 步骤 | 内容 | 验收 |
|---|---|---|
| M1.0 | shim 骨架 + ak_version/init/shutdown + 事件线程 | 空任务可初始化/关闭 |
| M1.1 | avox 构建脚本 + 链接 + 自检 | 启动打印 avox/ffmpeg 版本 |
| M1.2 | transcode 单任务 + 进度 + 取消 | 集成用例通过 |
| M1.3 | 队列 v0 + 五态 + 半成品清理 | 并发提交/取消稳定 |
| M1.4 | Flutter 转换页 + TaskStore | release 下可跑 |
| M1.5 | 失败态/日志/错误码 UI + 自检失败页 | 错误可读可恢复 |
| M1.6 | 打包脚本(DLL 部署) + 冒烟 | 干净机器可启动 |

## 11. 待确认(默认值已选)

1. 取消后半成品: **删除**(默认) vs 保留并标记 partial。
2. 失败自动重试: M1 **不自动**, 只提供手动重试。
3. 音频码率: M1 用编码器默认; 需要旋钮则在 avox 补 option(M2)。
4. 转码临时文件: 输出同目录 `stem.avoxkit-part.ext`(扩展名放最后, 保证引擎
   按扩展名选 muxer), 完成后 rename(默认)。
