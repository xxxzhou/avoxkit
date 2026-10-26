# native/avtool

avoxkit 的 `ak_*` C ABI shim(M1.0/M1.1 已落地)。

## 依赖

- avox 仓已按 `docs/m1-kickoff.md` §1.2 构建, 产物在
  `../../../avox/build-avoxkit/install/AMD64/Release`。
- ffmpeg kit 在 `../../third_party/ffmpeg/kit`。
- 两个编译门(`RtcPlayerApi.cpp` 的 ZLM guard、`CmdPlay.cpp` 的 freetype
  guard)已在 avox 仓补上; 若换机器, 先确认这两处。

## 构建

```bash
cmake -S native/avtool -B native/avtool/build -G "Visual Studio 17 2022" -A x64
cmake --build native/avtool/build --config Release --parallel 8
```

产物: `native/avtool/build/bin/Release/avoxkit_native.dll` + `ak_smoke.exe`。
构建后会把 `avox.dll` 和 kit 的 ffmpeg/运行时 DLL 拷到同目录。

## 验收

```bash
cd native/avtool/build/bin/Release
./ak_smoke.exe version
./ak_smoke.exe init  <work_dir>
./ak_smoke.exe caps  <work_dir>
./ak_smoke.exe probe <media_file> <work_dir>
./ak_smoke.exe transcode <in> <out> <work_dir> [--hardware off|auto|on]
              [--codec h264|hevc] [--quality N] [--cancel-ms N] [--overwrite]
./ak_smoke.exe queue <in> <out_dir> <work_dir> <count> [--hardware off|auto|on]
```

- `version`: ABI、shim/avox/ffmpeg 版本与配置哈希。
- `init`: 建日志目录、桥接 avox 日志、自检 `--enable-libmp3lame`/aac/avformat 63。
- `caps`: 编码器/容器/协议/features 快照; 硬编 `verified` 目前为 false。
- `probe`: libavformat 直接探测, 不启动引擎。
- `transcode`: 单文件转码; 事件会逐条打印(`[event] {...}`)。
- `queue`: 连续提交 N 个任务, 验证单 worker 串行与状态流转。

## Flutter 构建

先构建 shim, 再构建 Flutter; Windows runner 的 `OnDestroy` 会在销毁
FlutterController 之前调用 `ak_shutdown`, 兜底停线程/回调。

```bash
cmake -S native/avtool -B native/avtool/build -G "Visual Studio 17 2022" -A x64
cmake --build native/avtool/build --config Release --parallel 8

cd avoxkit
flutter pub get
flutter build windows --release
build/windows/x64/runner/Release/avoxkit.exe
```

`windows/runner/CMakeLists.txt` 会把 `native/avtool/build/bin/Release/*.dll`
拷到 exe 同目录。若先构建了 Flutter 再构建 shim, 需要重新跑一次
`flutter build windows`(或删 `build/windows` 重新配置), 否则 bundle 里还是旧 DLL。

或直接跑 `script/build_windows.ps1`, 产物在 `dist/avoxkit-windows-x64/`。

Dart 侧入口: `lib/main.dart` → `lib/core/engine.dart` → `lib/native/ak_bindings.dart`。
事件字符串由 shim 堆分配, Dart 回调里先 `toDartString()` 再 `ak_event_free`。

## 当前状态

- 已实现: ABI v1 全部函数; 事件线程; `transcode` handler; 单 worker 队列;
  queued/running/done/failed/cancelled; 取消 draining; 临时文件与原子改名;
  进度 5Hz 节流; 日志桥接。
- 未实现: remux/extract/analyze/image; 多产物; 批处理 UI; URL 输入。
- 临时文件是 `stem.avoxkit-part.ext`(扩展名放最后), 不要改成 `.part` 结尾,
  否则引擎按扩展名选 muxer 会失败。
- 运行时注意: `avox.dll` 依赖系统的 `d3dcompiler_47.dll`; 干净机器打包时确认
  系统提供, 不随包分发。
