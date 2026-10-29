# M1 开工方案(落地执行, 2026-10-26)

> **历史文档（2026-10-26）**：本文是 M1 当时的实测与落地记录，部分结论后来已
> 变化。当前用户功能与边界以 `docs/features.md` 为准；保留本文仅用于追溯设计过程。

> 承接 `docs/m1-plan.md`。那份是设计口径; 本文只写"怎么开工": 本次实测校正、
> 构建门、代码骨架、线程/取消语义、验收顺序。两边冲突时以本文的实测事实为准,
> 并把结论回写 `m1-plan.md`。
>
> 结论先说: **avox 在 M1 计划的那组 CMake 开关下编译不过**(两个可选组件门没关严),
> 需要先在 avox 仓补两个 `#ifdef` 或改用完整模块构建; shim 不需要自己调
> `AvoxManager::init()`, `avox.dll` 的 `DllMain` 已自动初始化。
>
> ABI 函数面、事件所有权、取消语义、能力探测以 `docs/functional-architecture.md`
> §4/§5 为准; 本文的 ABI 段是早期落地稿, 下一轮同步。

## 0. 本次实测基线

| 项 | 结果 |
|---|---|
| 工具链 | cmake 4.0.0-rc4; VS 2022 Community (MSBuild 17.14); Flutter 3.47.4 (`<flutter-sdk>`) |
| avox 配置 | 用 m1-plan §6 的开关 + `AVOX_ENABLE_AGENT=OFF`, configure 5 秒通过, 安装目录 `avox/build-avoxkit/install/AMD64` |
| avox 编译 | **失败**, 两个错误(见 §1.1), 与 avoxkit 代码无关 |
| ffmpeg 版本 | kit 与 avox 3rdparty 同为 9.0.1: avcodec 63 / avformat 63 / avutil 61 / swresample 7 |
| kit 导入库 | MSVC 可直接链接 (已用 `cl` + `avcodec.lib/avformat.lib/avutil.lib` 实测, 运行输出 `libmp3lame: yes`) |
| kit 编码器白名单 | `h264_mf,hevc_mf,aac,libx264,libx265,libmp3lame`; **没有** qsv/amf/nvenc |
| avox 初始化 | Windows 下 `DllMain(DLL_PROCESS_ATTACH)` 自动 `AvoxManager::Get().init()`; DETACH 自动 `clean()` |
| 公开头 | 安装到 `install/include/avox/*.h`; `AvoxManager.hpp` **不在**公开头里(也不需要) |
| 音频码率 | avox 已提供 `setAudioEncodeParam(AudioEncodeParam)`: `bitrateKbps/vbrQuality/profile` |
| close 语义 | `close()` 立即把状态置 `completed`(failed 除外), 排空后才回调 `onComplete`; 失败不回调 `onComplete` |
| 硬编开关 | `IRecorder` 没有 `setHardEncode`; 走 `getOption()->setBool("rec.hard.encode", ...)` |
| 递归所有权 | `createRecorder()` 内部 `new`, 调用方 `removeRecorderOb` 后 `delete` |
| 探测 | `getSourceInfo()/getDuration()` 要 `open()` 后才有效; 预探测在本仓用 libavformat 实现 |
| 测试工具 | 系统 `ffmpeg/ffprobe` 可用; 测试素材可用 `<avox-repo>/assets/video/*` 或现生成 |

## 1. 开工前置 P0(约半天)

### 1.1 avox 编译门(必须先解决)

关掉 ZLM/freetype 后, 核心 target 仍编译了依赖它们的代码:

1. `src/avox/player/RtcPlayerApi.cpp:3` 无条件 `#include "avox_zlmediakit/TestSdpOb.hpp"`
   → `mk_httpclient.h` 找不到。
2. `src/avox_cmd/commands/CmdPlay.cpp:951-953` 的 `case 'I'` 用了 `kOsdColors/
   kOsdColorCount`, 但声明在 `#ifdef AVOX_ENABLE_FREETYPE` 里 → 关 freetype 即报未声明。
   (`avox_cmd` 源码无论 `AVOX_ENABLE_CLI` 开关都会编进 `avox` target。)

**推荐: 在 avox 仓补两个门(改动小, 核心构建继续瘦身)**

```cpp
// RtcPlayerApi.cpp
#ifdef AVOX_ENABLE_ZLMEDIAKIT
#include "avox_zlmediakit/TestSdpOb.hpp"
#endif

IRtcEventOb* createZlTestSdpAgent(IRtcPlayer* player, const char* serverUrl) {
#ifdef AVOX_ENABLE_ZLMEDIAKIT
  if (!player || !serverUrl) return nullptr;
  auto ob = new TestSdpOb(serverUrl);
  ob->setPlayer(player);
  return ob;
#else
  (void)player; (void)serverUrl;
  return nullptr;
#endif
}
```

```cpp
// CmdPlay.cpp, case 'I' 整段
#ifdef AVOX_ENABLE_FREETYPE
            case 'I': {  // 几何颜色循环
              geoColorIdx = (geoColorIdx + 1) % kOsdColorCount;
              drawGeoDecor();
              printf("  几何颜色: %s\n", kOsdColors[geoColorIdx].name);
              break;
            }
#endif
```

**备选**: 不改 avox, 打开 `AVOX_ENABLE_ZLMEDIAKIT` + 构建 freetype 模块。代价是
多带 mk_api/OpenSSL 依赖, 构建更慢; M1 用不到, 不推荐。

改动提交在 avox 仓(引擎仓), 本仓不 vendor 补丁。

### 1.2 更新后的构建命令

```bash
cd <avox-repo>
cmake -S . -B build-avoxkit -G "Visual Studio 17 2022" -A x64 \
  -DAVOX_DIST_FLAVOR=agpl \
  -DAVOX_ENABLE_FDKAAC=OFF -DAVOX_ENABLE_FAAC=OFF \
  -DAVOX_ENABLE_WEBRTC=OFF -DAVOX_ENABLE_ZLMEDIAKIT=OFF \
  -DAVOX_ENABLE_SWIG=OFF -DAVOX_ENABLE_GODOT=OFF -DAVOX_ENABLE_UNITY=OFF \
  -DAVOX_ENABLE_CLI=OFF -DAVOX_ENABLE_SAMPLES=OFF \
  -DAVOX_ENABLE_PLUGINS=OFF -DAVOX_ENABLE_AGENT=OFF \
  -DAVOX_ENABLE_FREETYPE=OFF
cmake --build build-avoxkit --config Release --target avox --parallel 8
```

- `FAAC=OFF`: 本机 `find_package(Faac)` 会命中并静态链入; M1 不需要, 也避开
  FFmpeg 体系里 FAAC 的 nonfree 争议。AAC 编码走 kit 的原生 `aac`。
- 产物: `build-avoxkit/install/AMD64/avox.dll` + `avox.lib`;
  公开头 `build-avoxkit/install/include/avox/`。
- avox 侧已提供音频编码参数改动。shim 用同一次构建装出的头, 不会错位;
  记录 `git rev-parse HEAD` 与构建环境, 避免换机器无法复现。

### 1.3 门 G0

- [ ] `avox.dll/avox.lib` 生成, `dumpbin /exports avox.dll` 能看到
      `createRecorder/addRecorderOb/removeRecorderOb/setLogAction/...`
- [ ] 用 `dumpbin /imports avox.dll` 的 av* 导入符号对 `dumpbin /exports` 的
      kit DLL 做差集, 必须为空(kit 白名单为 avox 超集)。
- [ ] 新建空目录跑一次 `LoadLibrary` + `ak_version`, 不依赖 avox 3rdparty 的 ffmpeg。

## 2. 本仓 native 骨架(M1.0, 约半天)

沿用 m1-plan §2 的目录, 补两个文件: `tools/ak_smoke.cpp` 与 `src/ak_probe.cpp`。

```
native/avtool/
  CMakeLists.txt
  include/ak.h
  src/ak_api.cpp        C 边界/字符串所有权/参数校验
  src/ak_engine.cpp     init/shutdown/自检/日志/工作目录
  src/ak_event.cpp      事件线程 + MPSC 队列 + JSON 序列化
  src/ak_task.cpp       Task/队列/worker/状态机/取消
  src/ak_json.cpp       任务 JSON 解析与默认值
  src/ak_probe.cpp      libavformat 探测(不启动引擎)
  src/ak_log.cpp        文件日志 + avox setLogAction 桥接
  third_party/nlohmann/json.hpp
  tools/ak_smoke.cpp    无 Flutter 的命令行验收程序
```

CMake 关键点:

```cmake
set(CMAKE_CXX_STANDARD 17)
# avox 用 /MT 静态 CRT, shim 必须一致
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
set(AVOX_BUILD_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../avox/build-avoxkit" CACHE PATH "")
set(KIT_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../third_party/ffmpeg/kit" CACHE PATH "")
target_include_directories(avoxkit_native PRIVATE
  include "${AVOX_BUILD_DIR}/install/include" "${KIT_DIR}/include")
target_link_libraries(avoxkit_native PRIVATE
  "${AVOX_BUILD_DIR}/install/AMD64/avox.lib"
  "${KIT_DIR}/bin/avformat.lib" "${KIT_DIR}/bin/avcodec.lib"
  "${KIT_DIR}/bin/avutil.lib" "${KIT_DIR}/bin/swresample.lib")
```

初始化/关闭的正确做法(与 m1-plan §4 不同):

- `ak_init`: 建目录/日志 → `setLogAction(...)` → 自检 → 标记 ready。
  **不调用** `AvoxManager::init()`(DllMain 已调), 也不 include 内部头。
- `ak_shutdown`: 停队列/取消 running/join worker/摘 observer/删 recorder →
  释放自己的资源。**不调用** `AvoxManager::clean()`: 它会重复跑 cleanFuncs,
  且 DETACH 还会再跑一次。
- 自检项:
  - `avcodec_configuration()` 含 `--enable-libmp3lame`;
  - `avcodec_find_encoder_by_name("libmp3lame")` 非空;
  - `avcodec_find_encoder_by_name("aac")` 非空;
  - `avformat_version() >> 16 == 63`;
  - 失败返回 `AK_E_FFMPEG_MISMATCH`, 把实际配置串与 DLL 路径打进日志和 UI。

`ak_version` 返回 JSON: shim 版本、`AVOX_COMMIT_HASH/AVOX_COMMIT_VERSION`
(来自 `AvoxVersion.h`)、avox 运行目录、ffmpeg 版本与配置串摘要。

### 2.1 ABI 增量(相对 m1-plan)

- `ak_init(const char* work_dir)` 用普通 UTF-8 路径, 不用 JSON(与 m1-plan 一致,
  纠正 architecture.md 的 `work_dir_json` 写法)。
- `ak_probe(const char* uri)` 用 libavformat 直接打开, 返回:
  ```json
  {"ok":true,"duration_ms":60000,"format":"matroska",
   "video":[{"codec":"h264","width":1920,"height":1080,"fps":29.97}],
   "audio":[{"codec":"aac","channels":2,"sample_rate":48000,"bitrate_kbps":128}],
   "can_seek":true}
  ```
  失败返回 `{"ok":false,"code":...,"message":...}`。URL 探测在 M2 复用同一入口。
- 任务 JSON 增加 `audio.bitrate_kbps`(默认 `-1` = 按声道自动, avox 新参数面);
  其余字段同 m1-plan。M1 仍只接受 `source.kind=file`。

### 2.2 门 G1

- [ ] `ak_smoke version` 打印 avox/ffmpeg 版本与配置串;
- [ ] `ak_smoke init <tmpdir>` 成功, 重复 init 返回 `already_init`;
- [ ] 故意换成 avox 3rdparty 的 ffmpeg DLL, 启动报 `ffmpeg_mismatch` 且不进主界面。

## 3. 单任务全链(M1.2, 约一天)

调用顺序(已对照 avox 源码):

```cpp
IRecorder* rec = createRecorder(true);
rec->setVideoCodec(VCodecId::h264);
rec->setAudioCodec(ACodecId::aac);
VideoEncodeParam vp; vp.rateMode = EncodeRateMode::quality;
vp.quality = 60; vp.usage = EncodeUsage::record;
rec->setVideoEncodeParam(vp);
AudioEncodeParam ap; ap.bitrateKbps = -1;   // 按声道自动
rec->setAudioEncodeParam(ap);
rec->getOption()->setBool("rec.hard.encode", hardwareOn);
addRecorderOb(rec, observer);
rec->open(inputUtf8, tempOutputUtf8);       // true = 已进入 opening
// 运行中取消:
rec->close();                                // 排空语义, 不杀线程
// 收尾:
removeRecorderOb(rec, observer);
delete rec;
```

线程与所有权规则:

- `IRecorderOb` 的回调在 avox 的源/编码线程上触发; 回调里只做"写 Task 字段 +
  投递事件", 不碰队列锁外的共享对象, 不调 `ak_*` 以外的引擎 API。
- 每个 running Task 独占一个 recorder; observer 是 Task 的成员, 必须等
  `onComplete/onIoError` 且 worker 退出后再删 Task。
- 引擎对象不跨线程共享; 事件序列化统一在事件线程做。

状态机 `queued → running(opening→recording→closing) → done|failed|cancelled`:

- `queued`: submit 校验通过后发。
- `running/opening`: `open()` 返回 true 后发; `onStateChange(recording)` 发 stage。
- `done`: `onComplete` 且未请求取消 → rename `.part` → `output` → 发 done。
- `failed`: `onIoError/onEncodeError`, 或 `open()` 返回 false → 删 `.part` → 发 error。
- `cancelled`: 见下。

取消语义(M1 的硬指标是 1 秒内回到 cancelled):

1. `ak_task_cancel` 置 `cancelRequested`, 对 running 调 `rec->close()`;
2. **立即**把任务置 `cancelled` 并发事件(不再等排空);
3. 引擎随后仍会回调 `onStateChange(completed)` 和 `onComplete`——一律吞掉,
   不得再发 `done`;
4. 排空结束后删 `.part`, 释放 recorder; 队列 worker 在此之前不接下一个任务
   (并发仍为 1, 但 UI 已经看到 cancelled)。
5. 若 5 秒仍未回调, 记录一条 warning 并强制收尾(不杀线程, 只释放我们自己的引用)。

失败/取消都写临时文件 `输出同目录/<stem>.avoxkit-part<ext>`(扩展名放最后,
否则引擎按扩展名选 muxer 会失败), 完成后
`MoveFileExW(MOVEFILE_REPLACE_EXISTING)`; 失败/取消删除。

进度: 引擎 `RecorderProgress{currentTimeMs,totalTimeMs}`; 200ms 节流;
`totalTimeMs<=0` 时只发 `current_ms`, 不发 `pct`; 终态必发一次 100%。

### 3.1 错误码映射

| 引擎事件 | ak code |
|---|---|
| `open()` false / `onIoError` in opening | `input_open_failed` |
| 解码车道死/解码错误 | `decode_failed` |
| `onEncodeError` | `encode_failed` |
| muxer/open 输出失败 | `output_not_writable` |
| 取消 | `cancelled` |
| shutdown | `shutdown` |
| 自检失败 | `ffmpeg_mismatch` |

### 3.2 门 G2

- [ ] 10 秒 720p → H.264 MP4, `ffprobe` 时长/分辨率/音频轨正确;
- [ ] 进度事件单调, 200ms 级别, 完成后收到 `done`;
- [ ] 30% 时取消, ≤1 秒收到 `cancelled`, `.part` 与最终输出都不存在;
- [ ] 中文/空格/长路径通过; 只读输出目录报 `output_not_writable`;
- [ ] 连续 20 次提交/取消, 句柄与内存不增长。

## 4. 队列 v0(M1.3, 约半天)

- `mutex + condition_variable + 1 worker`; `maxConcurrency=1` 留字段。
- `ak_task_submit` 只做校验/入队/发 queued; 不在调用线程打开文件。
- `ak_task_remove` 只允许 queued; running 只能 cancel。
- 关闭顺序: 停止接收 → 取消 running → join worker → 删任务 → 停事件线程。
- 单测: JSON 解析/默认值/错误码; 状态机(queued cancel、running cancel、
  失败、正常完成); 重复取消幂等。

门 G3: 单测全绿 + 并发提交 10 个任务, 串行完成, 状态无回退。

## 5. Dart/Flutter(M1.4, 约一天半)

- `pubspec.yaml` 加 `ffi: ^2.2.0`、`file_selector: ^1.1.0`(本机 pub 缓存已有,
  离线可解析); 拖拽区可再加 `desktop_drop 0.5.0`。
- `lib/native/ak_bindings.dart`: `DynamicLibrary.open('avoxkit_native.dll')`,
  函数签名 + UTF-8 转换; 返回字符串用完 `ak_free_string`。
- `lib/native/ak_events.dart`: `NativeCallable.listener` → 广播 Stream; 事件模型。
- `lib/core/engine.dart`: 启动 `ak_init`; 失败页显示错误码/配置串/修复建议。
- `lib/core/task.dart` + `task_store.dart`: ChangeNotifier; 只保留最近进度值。
- `lib/ui/`: 先落 `AkTokens` + `AppShell` + `ToolPage` + 转换页 + 任务页;
  参数控件用最小 `OptionForm`(质量/目标大小/分辨率/编码/容器)。
  其余工具页 M2 再进, 遵守 docs/ui.md 的 registry 扩展方式。
- DLL 部署: `windows/CMakeLists.txt` 加 post-build copy, 把
  `avoxkit_native.dll / avox.dll / kit 的 avcodec-63 等 + libmp3lame/x264/x265/
  zlib1/libwinpthread/libgcc_s_seh-1` 拷到 `$<TARGET_FILE_DIR:${BINARY_NAME}>`;
  **不要**拷 avox 3rdparty 的 ffmpeg。kit 的 x264/x265 走 libstdc++,
  缺 `libgcc_s_seh-1.dll` 时只有带 mingw64 PATH 的进程能启动, 普通双击报 126。

门 G4: `flutter run --release` 启动, 选文件→提交→进度→完成; 队列页状态正确;
关闭窗口无崩溃/无残留进程。

## 6. 错误态与打包(M1.5/M1.6, 约一天)

- 自检失败页: 错误码 + 实际 `avcodec_configuration()` + 期望 DLL 名/路径。
- 日志: `<work_dir>/logs/avoxkit-YYYYMMDD.log`, 同时桥接 avox 日志;
  失败任务在 UI 提供"打开日志目录"。
- 打包脚本: `script/deploy_windows.ps1`(或 CMake install) 固定 DLL 清单;
  干净目录(无 MSYS2/VS)冒烟启动 + 转码。
- 门 G5: 干净机器/新用户目录启动; 首启不依赖开发机 PATH。

## 7. 与 m1-plan 的差异(需回写)

1. `close()` 会把状态置 completed; 取消必须在 shim 层单独记账并吞掉完成事件。
2. 硬编开关是 option `rec.hard.encode`, 不是 `IRecorder::setHardEncode`。
3. shim 不调用 `AvoxManager::init/clean`; Windows 由 DllMain 托管。
   Linux/macOS 没有 DllMain, 需要 avox 补一个公开的 init/shutdown C 入口
   (记入 architecture.md §5 引擎缺口, M5 前处理)。
4. 音频码率旋钮已经存在(`setAudioEncodeParam`), M1 直接暴露
   `audio.bitrate_kbps`, 目标大小估算可扣音频预算。
5. `ak_probe` 用 libavformat 在本仓实现, 不启动引擎; `IRecorder::getSourceInfo`
   只能在 open 之后用。
6. kit 的硬编白名单只有 `h264_mf/hevc_mf`; `ak_encoder_probe` 在 M1 只报
   "MF 或软编可用", 真编 3 帧验证放 M1.5。qsv/amf/nvenc 要等扩 kit 白名单。

## 8. 还缺的决定(默认值已选, 可改)

1. avox 侧音频参数改动: 按提交号构建, 避免依赖本地工作区。
2. M1 是否带拖拽: **带**(desktop_drop 已在缓存), 但文件选择器是必选路径。
3. 取消后的 `.part`: **删除**(默认)。
4. 失败自动重试: **不自动**(默认), 只提供手动重试。
5. 硬编默认: **off**(软编), `auto`/`on` 由调用方显式 opt-in; 硬编失败引擎
   自动回退软编。`ak_encoder_probe` 为 0 时 UI 直接关掉硬编开关。

## 9. 本次落地进展(2026-10-26)

- **avox 编译门已补**(avox 仓): `src/avox/player/RtcPlayerApi.cpp` 加
  `AVOX_ENABLE_ZLMEDIAKIT` guard; `src/avox_cmd/commands/CmdPlay.cpp` 的 `case 'I'`
  加 `AVOX_ENABLE_FREETYPE` guard。音频编码参数已在 avox `4954d5e` 提交。
- **avox 构建通过**: `build-avoxkit/install/AMD64/Release/avox.dll + avox.lib`;
  `dumpbin` 确认 `createRecorder/addRecorderOb/removeRecorderOb/setLogAction/
  getAvoxRunDir` 导出; 运行时依赖 kit 的 avcodec/avformat/avutil/swresample。
- **shim 骨架已落**: `native/avtool/`(CMake + `include/ak.h` + engine/event/log/
  probe/task/api + `tools/ak_smoke.cpp`), 按 `/MT` 链接 `avox.lib` 与 kit 导入库,
  构建后自动拷运行时 DLL。
- **ak_smoke 验收通过**:
  - `version`: ABI 1.0, avox 1.0.0970/4954d5e, ffmpeg 9.0.1, `libmp3lame=true`;
  - `init`: 自检通过, 日志落到 `<work_dir>/logs/avoxkit-YYYYMMDD.log`;
  - `caps`: h264/hevc 软硬编、aac/mp3、mp4/matroska、协议列表与 features;
  - `probe`: 对 `<avox-repo>/assets/video/avox_electron.mp4` 返回 hevc 1392x880@30、
    83.4s、can_seek=true。
- **实现期踩坑**:
  1. `init` 里持 `engine().mtx` 再调 `make_version_json()` 会二次锁同一把
     `std::mutex`, MSVC 抛 `system_error` 直接终止; 已改为锁外构建。
  2. avox 日志走异步队列; 关文件前必须 `avox::flushLog()`, 否则桥接日志在
     `restoreLogObserver()` 后落到 stdout 而不是文件。
  3. FFmpeg 9 的 `AVCodecParameters` 没有 `channels`, 用 `ch_layout.nb_channels`。
- **M1.2/M1.3 已完成**:
  - transcode handler 接上 `TranscodeRecorder`; 单 worker 队列、queued/running/
    done/failed/cancelled、取消 draining、临时文件原子改名、进度 5Hz 节流。
  - 10 秒 720p 素材(H.264/AAC)软编转码通过: 输出 H.264 1280x720、9.96s、AAC 48k;
    `--hardware auto`(h264_mf)也通过。
  - 取消 `--cancel-ms 300` 在 1 秒内收到 `cancelled`, 输出和 `.avoxkit-part`
    都不存在。
  - `queue 3` 三个任务串行完成, task_id 1/2/3, 输出 `out_0/1/2.mp4`。
  - `caps.features.transcode` 已置 true。
- **临时文件命名修正**: 用 `stem.avoxkit-part.ext`(如 `a.avoxkit-part.mp4`),
  扩展名必须在最后; 否则引擎按扩展名选 muxer 会失败。
- **M1.4 已完成**: Flutter 壳(AkTokens + AppShell + 转换/任务/关于页)、FFI 绑定、
  事件 TaskStore、Windows bundle; 实测 UI 选 `sample.mp4` → 开始转换 → 完成,
  输出 `sample.converted.mp4` 正确; 关闭窗口 exit=0。
- **退出崩溃修复**: 静态 `EventSink`/`TaskRuntime` 的 `std::thread` 在进程退出时
  仍 joinable, 析构触发 `std::terminate`(0xC0000409)。已给两者加析构 `stop()`,
  并在 `windows/runner/flutter_window.cpp` 的 `OnDestroy` 里先调 `ak_shutdown`
  再销毁 FlutterController。
- **M1.5/M1.6-lite 已完成**:
  - 启动失败页显示错误码/原因/详情 + “打开日志目录”; 任务失败卡也提供日志入口。
  - 字体随包分发: `assets/fonts` 放 Albert Sans + JetBrains Mono(均 OFL),
    `pubspec.yaml` 注册; dist 的 `FontManifest.json` 已包含两族。
  - `script/build_windows.ps1`: 构建 shim → `flutter build windows --release` →
    复制 `dist/avoxkit-windows-x64`; 已用 dist 冒烟启动/转换/关闭(exit=0)。
  - Windows 标题栏强制暗色 (`DWMWA_USE_IMMERSIVE_DARK_MODE`, 创建后与 Show 后
    各设一次), 已实测生效。
- **剩余**: 任务失败重试按钮/诊断包导出/干净机器冒烟/安装包; 这些不影响 M1
  主链验收。

## 10. M2.0 提前落地: remux + extract(2026-10-26)

- **ABI 未变**: 两个 kind 都是新 handler; `TaskRuntime` 队列/事件/取消原样复用。
- `remux`: `createRecorder(false)` 双轨直拷, 只按输出扩展名换容器。
- `extract`: `createRecorder(true)` + `setVideoCodec(none)`; 音频 `aac`/`mp3`
  重编, `copy` 走 `TransMode::AudioCopy` 原样封装。
- 提交前用 `probe_uri_json` 拦掉无音轨, 返回 `AK_E_BAD_SOURCE`, UI 按钮同步禁用。
- **kit 缺口**: `.m4a` 需要 `ipod` muxer; 白名单已加并重建,
  `--verify` 仍无 nonfree。
- **引擎缺口**: mp3 编码时引擎按源格式 `flt` 开 libmp3lame, 报
  "Specified sample format flt is not supported"; shim 侧
  `setAudioDesc(FLTP, 源采样率, ≤2 声道)` 解决。引擎侧应自行协商支持格式(待 avox)。
- **实测**(ak_smoke, `sherpa.mp4` / `subtext_bg.mp4`):
  - extract → m4a: 10s AAC、仅音轨;
  - extract → mp3 192k: 58.7s、192 kbps、44.1 kHz;
  - extract copy → m4a: 源 128 kbps 未重编;
  - remux mp4→mkv→mp4: h264+aac 原样, 时长一致;
  - 无音轨素材提交返回 -8, 不产生任务。
- **UI**: 侧栏新增 提取音频 / 封装转换; 媒体信息与任务回执抽成
  `widgets/media_source.dart`、`widgets/task_summary.dart` 复用。

## 11. M2.1: 文件夹批量(2026-10-26)

- **按工具接受文件夹, 不做独立批量页**: 三个工具页的源文件区都有“或处理一个
  文件夹”; 选中后显示文件夹卡(递归/匹配数/待处理/跳过), 选项区自动切换成输出
  策略。单个文件与整个文件夹是同一入口的两种选择。
- **规划在 Dart**: `folder_scan.dart`(isolate 扫描、自然排序、过滤隐藏/临时/
  上次产物、去重、5000 上限) + `batch.dart`(sidecar/mirror/flat 命名与冲突)。
  shim 只看到具体文件; 任务 JSON 新增 `group_id` 透传, 事件里原样回显。
- **组生命周期**: `TaskGroup` 只在 Dart; 工具页与任务页都显示组卡(进度/完成/失败/跳过,
  整组取消、重试失败项)。重试用建组时的 params 原样重建任务。
- **失败隔离**: 单个文件被拒(无音轨/容器不收)只影响该任务, 组继续; 提交时
  统计被拒数量提示。
- **默认跳过已存在输出**, 同目录批量时跳过本工具上次的 `.converted`/`.remux`
  产物, 避免递归处理。
- **测试**: `flutter test` 12 项(自然排序、递归/非递归、过滤、截断、三种命名
  策略、跳过已存在); UI 实测提取音频批量: 4 个视频 → 4 个 m4a, 组卡显示
  完成/失败/跳过。

## 12. M3: 字幕提取 + 本地识别(2026-10-27)

- **两个来源**: 有内嵌文本字幕轨(SubRip/ASS/SSA/mov_text/WebVTT)直接导出
  SRT; 没有时用本地 sherpa SenseVoice 识别生成。PGS/DVD/DVB 位图字幕不做
  OCR, UI 引导改用识别。
- **avox 新增**: `src/avox/AvoxSubtitle.h` + `src/avox/subtitle/SubtitleExport.cpp`
  (`exportSubtitleTrack` / `ISrtWriter` / `isTextSubtitleCodec`)。SRT 写出走
  虚接口, 不跨 ABI 传结构体/裸指针。
- **shim**: `kind=subtitle`; `params.subtitle.mode=auto|embedded|asr`,
  `stream_index` 用 probe 的 container stream index。识别链 =
  TranscodeRecorder(仅音频 16k mono AAC 旁路) + AudioTap → `IAudioStt`
  (offline SenseVoice) → 写 SRT; 旁路音频完成后删除。
- **构建 avox**(与 M1 相同目录, 追加插件开关):
  ```bash
  cmake -S . -B build-avoxkit -G "Visual Studio 17 2022" -A x64 \
    -DCMAKE_BUILD_TYPE=Release \
    -DAVOX_DIST_FLAVOR=agpl -DAVOX_ENABLE_FDKAAC=OFF -DAVOX_ENABLE_FAAC=OFF \
    -DAVOX_ENABLE_WEBRTC=OFF -DAVOX_ENABLE_ZLMEDIAKIT=OFF \
    -DAVOX_ENABLE_SWIG=OFF -DAVOX_ENABLE_GODOT=OFF -DAVOX_ENABLE_UNITY=OFF \
    -DAVOX_ENABLE_CLI=OFF -DAVOX_ENABLE_SAMPLES=OFF -DAVOX_ENABLE_AGENT=OFF \
    -DAVOX_ENABLE_FREETYPE=OFF -DAVOX_ENABLE_PLUGINS=ON \
    -DAVOX_ENABLE_SHERPA=ON -DAVOX_ENABLE_ONNX=ON \
    -DAVOX_ENABLE_OPENCV=ON -DAVOX_ENABLE_TRANSLATION=OFF \
    -DAVOX_ENABLE_CV=ON -DAVOX_ENABLE_OCR=OFF -DAVOX_ENABLE_OPENVINO=OFF \
    -DAVOX_ENABLE_AVATAR=OFF -DAVOX_ENABLE_TORRENT=OFF \
    -DAVOX_ENABLE_CALIB=OFF -DAVOX_ENABLE_FBX=OFF -DAVOX_ENABLE_ASS=OFF \
    -DAVOX_ENABLE_TEMPO=OFF -DAVOX_ENABLE_DISC=OFF -DAVOX_ENABLE_DECKLINK=OFF
  cmake --build build-avoxkit --config Release \
    --target avox avox_sherpa avox_onnx avox_opencv avox_cv --parallel 8
  ```
  `CMAKE_BUILD_TYPE=Release` 是必须的: VS 多配置生成器默认空值,
  `FindSherpaOnnx` 会去 `sherpa-onnx/lib/` 找不到 `Release` 库。
- **打包**: `avox_sherpa.dll + sherpa-onnx-c-api.dll + sherpa-onnx-cxx-api.dll`
  从 `install/AMD64/Release/plugins/` 复制到 shim 的 `plugins/`; 再从
  `avox/build/windows/sherpa-onnx/bin/Release/onnxruntime.dll` 补 CPU 版 ORT。
  图像修复另带 `avox_cv.dll + avox_onnx.dll + avox_opencv.dll +
  opencv_world4130.dll`（同一 plugins 目录）。ORT 与 opencv 都放 `plugins/`，
  由 avox 的插件加载器把它加入 DLL 搜索路径。模型**不打包**。
- **图像修复的引擎入口**: 公共头原本只有 `IWatermarkRemoval` 接口、没有创建函数
  （只能经未安装的 `AvoxManager` 拿）。2026-10-29 在 avox `src/avox/vision/Vision.cpp`
  补了 `createWatermarkRemoval()` 导出，本仓按公共头调用，不 include 私有
  `AvoxManager.hpp`。
- **模型按需下载**: `lib/core/model_store.dart` 在用户点识别且模型缺失时下载
  SenseVoice + Silero VAD 到 `<app support>/models`, sha256 校验; 只下三个
  文件(约 230 MB), 不用识别就不下载。图像修复同理, 首次使用时下载
  `inpaint/lama_base.onnx` + `inpaint/yolo26m-seg_watermark.onnx`（约 290 MB）。
- **测试**: `flutter test` 53 项; `ak_subtitle_test` 9 checks;
  `ak_features_test` 131 checks。ASR 实测 `<avox-repo>/assets/video/sherpa.mp4`
  → 12 条中/日文字幕。


