# native/avtool

avoxkit 的 `ak_*` C ABI shim（ABI v1）。

## 依赖

- avox 仓已按 `docs/m1-kickoff.md` §1.2 构建, 产物在
  `../../../avox/build-avoxkit/install/AMD64/Release`。图像修复还需要
  `avox_cv` / `avox_onnx` / `avox_opencv` 三个插件, 构建开关见
  `docs/m1-kickoff.md`（`AVOX_ENABLE_ONNX/OPENCV/CV=ON`）。
- avox 公共头需含 `createWatermarkRemoval()`（avox 2026-10-29 补充的导出）。
- ffmpeg kit 在 `../../third_party/ffmpeg/kit`（Windows）。x264/x265 是 MinGW
  构建, kit/bin 必须同时有 `libstdc++-6.dll`、`libwinpthread-1.dll`、
  `libgcc_s_seh-1.dll`; 缺 `libgcc` 时只有 PATH 里带 mingw64 的环境能启动,
  普通双击会报 error 126。`script/build_windows.ps1` 会从 MSYS2 自动补齐。
- macOS kit 用 `script/ffmpeg/build_ffmpeg_macos.sh` 产出到
  `third_party/ffmpeg/kit-macos`（静态、LGPL + libmp3lame、与 avox 同为
  n9.0.1；`--disable-gpl`，不含 x264/x265）。shim 最终链接这份 kit，不复制进
  avox 3rdparty，也不改 avox 版本；avox 需关闭 WebRTC/ZLM，否则
  `libwebrtc_nosym.a` 内嵌的旧 ffmpeg/dav1d 会与 kit 撞符号。细节见
  `docs/macos-porting.md` §2.1/§3/§4.2。
- 两个编译门(`RtcPlayerApi.cpp` 的 ZLM guard、`CmdPlay.cpp` 的 freetype
  guard)已在 avox 仓补上; 若换机器, 先确认这两处。
- macOS 移植的依赖、静态链接、插件符号可见性和打包步骤见
  `docs/macos-porting.md`; 本节只写 Windows 路径。

## 构建

```bash
cmake -S native/avtool -B native/avtool/build -G "Visual Studio 17 2022" -A x64
cmake --build native/avtool/build --config Release --parallel 8
```

产物: `native/avtool/build/bin/Release/avoxkit_native.dll` + `ak_smoke.exe`。
构建后会把 `avox.dll` 和 kit 的 ffmpeg/运行时 DLL 拷到同目录。

### macOS

先按 `docs/macos-porting.md` §3 构建 avox（`--flavor=commercial`，并关闭
`AVOX_ENABLE_WEBRTC/ZLMEDIAKIT`），kit 用 §2.1 的脚本产出，然后：

```bash
cmake -S native/avtool -B native/avtool/build -DCMAKE_BUILD_TYPE=Release
cmake --build native/avtool/build --config Release --parallel "$(sysctl -n hw.ncpu)"
```

产物：`native/avtool/build/bin/avoxkit_native.dylib` + 无头工具。同目录会带
`plugins/`（4 个 avox 插件 + onnxruntime）、`assets/glsl/`、
`libvulkan.1.dylib`（MoltenVK）。整包用 `script/build_macos.sh`，输出
`dist/avoxkit-macos-arm64{,.zip}`。

## 验收

```bash
cd native/avtool/build/bin/Release
./ak_smoke.exe version
./ak_smoke.exe init  <work_dir>
./ak_smoke.exe caps  <work_dir>
./ak_smoke.exe probe <media_file> <work_dir>
./ak_smoke.exe transcode <in> <out> <work_dir> [--hardware off|auto|on]
              [--codec h264|hevc] [--quality N] [--cancel-ms N]
              [--trans-mode all|audio_copy|video_copy]
              [--audio-codec aac|mp3] [--container mp4|mov|mkv]
              [--width N --height N] [--overwrite]
./ak_smoke.exe queue <in> <out_dir> <work_dir> <count> [--hardware off|auto|on]
./ak_smoke.exe remux <in> <out> <work_dir> [--overwrite]
./ak_smoke.exe extract <in> <out> <work_dir> [--codec aac|mp3|copy]
              [--bitrate N] [--overwrite]
./ak_smoke.exe trim <in> <out> <work_dir> <start_ms> <end_ms>
              [--codec h264|hevc] [--quality N] [--container mp4|mkv] [--overwrite]
./ak_smoke.exe index <file> [buckets]
./ak_smoke.exe frames <file> <out_dir> [count] [width] [--times a,b,c]
./ak_image_test.exe <image> <models_dir>
```

- `version`: ABI、shim/avox/ffmpeg 版本与配置哈希。
- `init`: 建日志目录、桥接 avox 日志、自检 `--enable-libmp3lame`/aac/avformat 63。
- `caps`: 编码器/容器/协议/features 快照; 硬编 `verified` 目前为 false; `vulkan`
  为 avox `isVulkanAvailable()`。
- `probe`: avox `IMediaReader` open + ISourceInfo 列轨(跳过封面图流), 不启动引擎。
- `transcode`: 单文件转码; 事件会逐条打印(`[event] {...}`)。
- `queue`: 连续提交 N 个任务, 验证单 worker 串行与状态流转。
- `remux`: 双轨直拷换容器(`createRecorder(false)`)。
- `extract`: 丢视频轨导出音频; `--codec copy` 为原样封装(不重编码)。
- `trim`: 重新编码的片段截取, 起点按关键帧定位。
- `index`: avox `IMediaReader` buildIndex, 读音频包络(线性峰值, shim 转 0-100)
  与视频关键帧, 供时间线使用。
- `frames`: avox `IMediaReader` grabFrame 抓参考帧/缩略图(JPEG)。出图走 VK
  (缩放/HDR→SDR/竖拍转置), 无 Vulkan 回 `renderUnavailable`, 不兜底 CPU。
- `ak_image_test`: 图像修复链路（`ak_image_detect` + kind `image` 自动/手绘 mask），
  需要 LaMa + YOLO 模型。

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

- 已实现: ABI v1 全部函数; 事件线程; `transcode`/`remux`/`extract`/`subtitle`/
  `trim`/`image` handler; `ak_media_index`/`ak_media_frames`/`ak_image_detect`;
  单 worker 队列; queued/running/done/failed/cancelled; 取消 draining; 临时文件与
  原子改名; 进度 5Hz 节流; 日志桥接; Windows 原生窗口预览。
- 未实现: `analyze`; 多产物; URL 输入。
- 图像修复的模型不随包: App 在首次使用时下载 LaMa + YOLO26-Seg 到
  `<models>/inpaint/`；shim 只经 `avox::getModelFilePath` 读取。
- 批处理在 Dart 层展开为多个普通任务, shim 只接收具体文件; 组卡、重试和
  输出策略都在 UI 侧。
- 临时文件是 `stem.avoxkit-part.ext`(扩展名放最后), 不要改成 `.part` 结尾,
  否则引擎按扩展名选 muxer 会失败。
- `extract` 出 `.m4a` 依赖 kit 编入 `ipod` muxer; 出 mp3 时 shim 会显式
  `setAudioDesc(FLTP)`, 因为引擎默认按源的 `flt` 开 libmp3lame 会失败。
- 运行时注意: `avox.dll` 依赖系统的 `d3dcompiler_47.dll`; 干净机器打包时确认
  系统提供, 不随包分发。
