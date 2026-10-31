# macOS 移植指南（环境、构建与打包）

状态：**macOS arm64 已落地**（2026-10-30）。shim/Flutter 构建、无头回归与
GUI 冒烟（选文件 → probe → 封装完成 → 退出）通过；Developer ID 签名/公证
待发布证书。**录屏/转码出画仍挂账：资源摆位不对导致视频轨全 0（§9.3）。**
Windows 0.1.0 已发布；本文记录在 macOS 上从零配环境到跑通
`avoxkit` 的路径，以及 2026-10-29 在 Windows 侧踩过的同类坑的 Apple 版。

先读 `docs/architecture.md` 和 `native/avtool/README.md`。本文只讲 macOS 特有的
部分，ABI、任务模型、功能映射与平台无关。

## 0. 结论先行

- avox 引擎有完整 macOS 支持：静态核心 `libavox.a` + 动态插件
  `libavox_*.dylib`，渲染走 Metal/Vulkan（MoltenVK），编解码走 VideoToolbox
  和 ffmpeg。`build_mac.py` 是官方构建入口。
- `native/avtool` 的 Windows 专有代码只有三处：预览窗口
  （`ak_preview_win.cpp`，非 Windows 全部是 no-op）、UTF-16 路径转换
  （`ak_task.cpp`，已有 POSIX 分支）、`MoveFileEx` 原子改名（已有
  `std::filesystem::rename` 分支）。其余 probe/index/frames/image/task
  都是可移植的 C++17 + ffmpeg + avox 公共 API。
- avox 必须关掉 RTC/ZLM 再构建：
  `AVOX_CMAKE_ARGS="-DAVOX_ENABLE_WEBRTC=OFF -DAVOX_ENABLE_ZLMEDIAKIT=OFF"`。
  avoxkit 不用这两个模块；默认构建会把 `libwebrtc_nosym.a` 内嵌的旧版
  ffmpeg/dav1d 拉进最终链接，与 kit 的新版 ffmpeg 撞符号（`dav1d_*` 重复
  定义）。关掉后 Agent 走 OpenSSL 3，shim 静态链 `libssl.a`/`libcrypto.a`。
- GPU 渲染（缩放/抓帧/场景层）依赖 Vulkan loader：把 avox install 目录的
  `libMoltenVK.dylib` 以 `libvulkan.1.dylib` 放到 shim 同目录。缺了
  `volkInitialize` 失败，`caps.vulkan=false`，缩放转码会
  `output_finalize_failed`、`ak_media_frames` 会 `render_unavailable`。
- 真正的工作量不在改 `.cpp`，而在四件事：
  1. **静态链接清单**：avox 在 Apple 是静态库，shim 要把 avox 的全部第三方
     依赖一起链进来，且只能有一份 ffmpeg。
  2. **插件符号可见性**：macOS 插件用 `-undefined dynamic_lookup`，宿主必须
     让 avox 符号进全局符号表，否则插件全部加载失败（对应 Windows 的
     “插件发现不到”）。
  3. **GPL ffmpeg kit**：与 avox 同为 n9.0.1，独立产物、不写 avox 3rdparty；
     必须自带 `--enable-libmp3lame`，并补上 avox 图像 IO 需要的 `mjpeg`/`png`
     编码器和 `tga` 解码器。最终链接时由 shim 用 kit 顶替 avox 那份 LGPL。
  4. **打包/签名**：`@rpath`、嵌套 dylib 签名、沙盒权限、公证。

## 1. 机器与目录

macOS 12.0+（avox 的部署目标硬性要求，`build_common.py` 里
`AVOX_MACOS_DEPLOYMENT_TARGET = "12.0"`）。建议 Apple Silicon（arm64）。

```bash
xcode-select --install
xcodebuild -version                 # Xcode 15+，命令行工具已就位
cmake --version                     # >= 3.25
python3 --version
brew install pkg-config
flutter --version
flutter config --enable-macos-desktop
```

安装 **LunarG Vulkan SDK for macOS**（avox 的 `cmake/LinkVulkan.cmake` 会自动
搜索 `~/VulkanSDK/*/macOS`，也认 `VULKAN_SDK` 环境变量）。只装 MoltenVK 不够，
需要 SDK 里的 Vulkan 头和 `MoltenVK.xcframework`。

仓库按兄弟目录摆放，和 Windows 一致：

```
~/src/
├── avox/            # 引擎
├── avox_library/    # 第三方二进制（AVOX_EXTERNAL_LIBRARY_DIR 默认 ../avox_library）
├── avox_model/      # 可选：测试模型
└── avoxkit/         # 本仓
```

`avox/CMakeLists.txt` 在没有 `AVOX_EXTERNAL_LIBRARY_DIR` 时默认找
`../avox_library`；找不到会直接 FATAL。若目录不同名，构建前设置：

```bash
export AVOX_EXTERNAL_LIBRARY_DIR=$HOME/src/avox_library
```

## 2. 第三方库（darwin）

目标目录分两处，别放反（`Find*.cmake` 的搜索顺序不同）：

- ffmpeg：**avox 仓内** `avox/3rdparty/library/darwin/ffmpeg/{include,lib}`。
  `FindFFmpeg.cmake` 只认 `${AVOX_TRDPARTY}/library/darwin`，不读 sibling 库仓。
  这份只给 avox 自己编译/测试用；avoxkit 出厂 kit 是独立产物，见 §2.1。
- onnxruntime / opencv：sibling 库仓 `avox_library/3rdparty/library/darwin/`。
  `FindONNX.cmake` 先找库仓；`FindOpenCV.cmake` 先找 avox 仓、再回落库仓。

### 2.1 ffmpeg（LGPL + libmp3lame，必须自建，但不改 avox）

先把版本口径钉死：

- avox darwin 3rdparty 是 **FFmpeg n9.0.1**（`include/libavutil/ffversion.h`），
  与 Windows 同版。本仓 kit 必须用同一个上游版本，只改 configure；不要升级或
  降级，也不要把 kit 复制进 `avox/3rdparty`。
- `libavox.a` 只保留对 `av_*` 的未定义引用（`nm -u "$AVOX_OUT_DIR/libavox.a" |
  grep _avcodec` 可验证），最终由 shim 链接的静态库解析。所以做法和 Windows 的
  运行时替换等价：**avox 继续用自己那份 LGPL 构建编译，shim 最终链接本仓 kit
  的 `.a`**；avox 的目录、版本、产物都不动。
- 与 Windows 的差异只是替换时机：Windows 是打包时用同名 DLL 顶替，macOS 是
  最终链接时用 kit 的 `.a` 顶替。两边都只允许存在一份 ffmpeg。

构建：

```bash
# 版本/依赖自检（源码树默认 ../ffmpeg，avox 头默认 ../avox）
./script/ffmpeg/build_ffmpeg_macos.sh --check-version
./script/ffmpeg/build_ffmpeg_macos.sh --check-deps

# 静态依赖 prefix 到 $HOME/avoxkit-deps 后构建
DEPS_PREFIX=$HOME/avoxkit-deps ./script/ffmpeg/build_ffmpeg_macos.sh

# 出厂校验（nonfree、版本、符号、静态链接 + 组件自检）
./script/ffmpeg/build_ffmpeg_macos.sh --verify third_party/ffmpeg/kit-macos/lib
```

产物落在本仓 `third_party/ffmpeg/kit-macos/{include,lib}`，不写 avox 仓。
脚本按 avox Apple 白名单出静态库，并补 avoxkit 增量：

- 编码：`libmp3lame`、`aac`、`h264_videotoolbox`、`hevc_videotoolbox`、
  `mjpeg`、`png`（不含 x264/x265）
- 解码：`png/mjpeg(JPEG)/bmp/targa/webp`（图像修复输入）、常用视频/音频解码
- 硬解：`h264/hevc/vp9/av1` 的 VideoToolbox hwaccel（软解仍可用）
- 封装：`mp3`、`wav`、`ipod`（只含音轨的 `.m4a`）
- `mjpeg`/`png` 编码是 avox `ImageIO` 保存缩略图和修复结果用的；缺了表现是
  `ak_media_frames` 报 `encode_failed`、图像修复报 `image_encode_failed`，
  不是崩溃，容易误判。

依赖：`lame` 必须提供 **静态库**（`libmp3lame.a`）。Homebrew 只有 dylib 时
不要用，否则会把 `/opt/homebrew` 路径带进最终二进制（见 §6 验收）；从源码
prefix 到 `$HOME/avoxkit-deps` 即可，`DEPS_PREFIX` 会自动补 pkg-config 与
include/lib 路径。`dav1d` 可选，存在 `libdav1d.a` 时自动挂上 AV1 软解。

LAME 的静态库若带 mpglib 解码（Homebrew 4.x 就是），会引用 `mpg123_*`；
脚本会检测并一起收 `libmpg123.a`，缺了 `--check-deps` / `--verify` 会直接报。
源码构建 lame 加 `--disable-decoder` 可以避免这条依赖。`--verify` 最后会用
`clang` 把 kit 静态链一遍并跑 `kit_probe`，确认编解码器/muxer 真的注册成功，
不是只看符号表。

avox 自带的 `script/ffmpeg/build_ffmpeg_apple.sh` 是 LGPL 白名单 +
VideoToolbox，**没有 libmp3lame，也没有 mjpeg/png 编码器**，不能直接用于
avoxkit。许可证：本仓 macOS 链走 `--disable-gpl` + `libmp3lame`（LGPL）；
`--verify` 会拒绝含 `--enable-gpl` / `libx264` / `libx265` 的产物，也会
拒绝 `--enable-nonfree` / `--enable-libfdk-aac`（`AGENTS.md` 红线）。

### 2.2 ONNX Runtime 1.23.2（水印检测/修复、语音识别）

官方包 `onnxruntime-osx-arm64-1.23.2.tgz`，解压到库仓以下任一布局：

```
avox_library/3rdparty/library/darwin/onnxruntime/onnxruntime-osx-arm64-1.23.2/{include,lib}
avox_library/3rdparty/library/darwin/onnxruntime/{include,lib}          # 摊平布局
```

`FindONNX.cmake` 先找库仓、再找 avox 仓，Apple 分支也认
`onnxruntime-osx-x86_64-*` / `-universal2-*`。dylib 的
install name 是 `@rpath/libonnxruntime.1.23.2.dylib`，所以最终要把它放到
插件的 `plugins/` 目录（插件 `INSTALL_RPATH` 是 `@loader_path`，见
`cmake/avox_module.cmake`）。

注意：库仓里 `onnxruntime-osx-arm64-1.23.2/include`、`lib` 在 macOS 上是
符号链接；在 Windows 上 checkout 会变成普通文本文件（内容 `../include`），
不要把 Windows 工作区的这种文件当成库提交/拷贝。

### 2.3 OpenCV 4.13.0

放在库仓（`FindOpenCV.cmake` 先找 avox 仓、没有再回落这里）：

```
avox_library/3rdparty/library/darwin/opencv/include/opencv2/...
avox_library/3rdparty/library/darwin/opencv/lib/libopencv_world4130.a
```

avox 的 `FindOpenCV.cmake` 优先找 `opencv_world` 静态库，兜底
`opencv4` / `opencv_core` 或 Homebrew。avox_opencv 插件静态链 OpenCV，
所以 **不要把 Homebrew 的 OpenCV dylib 带进包**；缺静态库时用
`-DBUILD_opencv_world=ON -DBUILD_SHARED_LIBS=OFF` 自建。

## 3. 构建 avox

```bash
cd ~/src/avox
# 关 RTC/ZLM: 工具链不用, 且默认 webrtc_nosym 内嵌旧 ffmpeg/dav1d 会与 kit 撞符号
AVOX_CMAKE_ARGS="-DAVOX_ENABLE_WEBRTC=OFF -DAVOX_ENABLE_ZLMEDIAKIT=OFF" \
  python3 build_mac.py --flavor=commercial
```

- 改 `AVOX_CMAKE_ARGS` 后必须让 `AVOX_FORCE_REBUILD=True`（默认）清缓存
  重配，否则旧 CMakeCache 会把开关保持为 ON。
- 关闭 WebRTC 后 Agent/httplib 自动改用 OpenSSL 3；shim 静态链
  `libssl.a`/`libcrypto.a`，不再需要 `libwebrtc_nosym.a`/`libmk_api.dylib`。
- `avox_agent_tests`/`playtest` 目标在缺 `libdav1d.a` 时可能链接失败，
  不影响 `avox` 主目标产出 `libavox.a` 与 install 头；以 `libavox.a`
  时间戳和 `nm -gU ... | grep createMediaComposer` 为准。

- `--flavor=commercial`：LGPL 渠道。Apple 上 FFmpeg 软编兜底注入
  `h264_videotoolbox`/`hevc_videotoolbox`，不再带 x264/x265，和本仓 LGPL kit
  匹配。panvox 与本仓共用同一个 avox 构建树（`avox/build/macos/avox`），
  这里也顺便把 panvox 期望的 commercial flavor 恢复回来。
- 脚本会自动构建 `build/macos/{fdk-aac,freetype,sherpa-onnx,sentencepiece,...}`
  再编 avox；RTC/ZLM 已由上面的开关关闭。
- 插件默认全开（`plugins/options.cmake` 里 ONNX/OPENCV/CV/SHERPA 都是 ON）。
- 产物（以 configure 打印的 `CMAKE_INSTALL_PREFIX` 为准，通常是）：
  `build/macos/avox/install/aarch64/Release/`
  - `libavox.a`
  - `plugins/libavox_cv.dylib`、`libavox_onnx.dylib`、
    `libavox_opencv.dylib`、`libavox_sherpa.dylib`
  - 包内资源在**上一级** `install/aarch64/avox.bundle/`
    （`glsl/ fonts/ images/ models/ certs/`）。Apple 侧只认这个目录名，
    摆成 `assets/` 会被静默忽略，症状是「没报错但功能全哑」→ §4.5
  - `libMoltenVK.dylib` 也被拷到上一级 `install/aarch64/`（见
    `cmake/LinkVulkan.cmake`），打包时注意层级
  - 头文件在 `build/macos/avox/install/include`

构建后检查：

```bash
OUT=~/src/avox/build/macos/avox/install/aarch64/Release
ls "$OUT"/plugins
otool -L "$OUT"/plugins/libavox_onnx.dylib   # 应看到 @rpath/libonnxruntime.1.23.2.dylib
```

`plugins/` 里大概率缺 `libonnxruntime.1.23.2.dylib`：avox 的
`avox_plugin_copy_deps` 只在 Windows 生效。手工补：

```bash
cp ~/src/avox_library/3rdparty/library/darwin/onnxruntime/lib/libonnxruntime.1.23.2.dylib \
   "$OUT"/plugins/
```

### 3.1 必须在 avox 仓补/确认的两处

1. **`createWatermarkRemoval()` 导出**：本仓图像修复依赖它。截至 2026-10-29
   这只是 avox 工作区里的未提交改动（`src/avox/AvoxVision.h` +
   `src/avox/vision/Vision.cpp`）。移植前先在 avox 仓提交/推送，否则 Mac 上
   新 clone 的 avox 编出来的头没有这个声明，shim 链接失败。
2. **静态消费者的链接导出**：avox 目前没有 `install(EXPORT ...)`，shim 在
   树外链接 `libavox.a` 时拿不到它的传递依赖。两条路：
   - 短期：从 `platform/macos/playtest` 的链接命令抄（`cmake --build ... --target
     playtest --verbose` 能看到完整 `-l`/framework 列表）；
   - 推荐：在 avox 补一个 `avoxConfig.cmake` 导出（引擎侧改动，符合本仓
     “引擎缺口回 avox”的约定），shim 只 `find_package(avox)`。

## 4. shim（`native/avtool`）移植

### 4.1 代码：几乎不用改

| 文件 | 现状 | macOS 处理 |
|---|---|---|
| `include/ak.h` | 非 Windows 已用 `visibility("default")` | 不改 |
| `src/ak_util.cpp` | `gmtime_s`/`gmtime_r` 已分支 | 不改 |
| `src/ak_task.cpp` | `MoveFileExW` 有 `std::filesystem::rename` 分支；`utf8_to_wide` 只在 `_WIN32` 用 | 不改 |
| `src/ak_engine.cpp` | `platform` 已输出 `macos` | 不改 |
| `src/ak_preview_win.cpp` | 整个文件非 Windows 是 no-op，`ak_preview_open` 返回 false | UI 自动退化为占位；预览列为二期 |
| `src/ak_probe.cpp` / `ak_index.cpp` / `ak_frames.cpp` / `ak_image.cpp` | libav* + avox 公共 API | 不改；注意 ffmpeg 编解码器要齐 |

### 4.2 CMake：Apple 分支（已实现）

`native/avtool/CMakeLists.txt` 已加 Apple 分支（2026-10-30），要点：

- `AVOX_OUT_DIR = <avox>/build/macos/avox/install/aarch64/Release`
- `AVOX_LIB = ${AVOX_OUT_DIR}/libavox.a`（不是 `avox.lib`）
- 链接 avox 时用 **whole-archive 语义**，否则模块注册的静态初始化会被
  dead-strip 掉（avox 的 playtest 用
  `"$<LINK_LIBRARY:WHOLE_ARCHIVE,avox>"` 就是为这个）：
  ```cmake
  target_link_options(avoxkit_native PRIVATE "-Wl,-force_load,${AVOX_LIB}")
  ```
- ffmpeg 只链 **一份**：链本仓 `third_party/ffmpeg/kit-macos/lib` 的
  `libav*.a`（§2.1），不要链 `${AVOX_OUT_DIR}/libav*.a`，也不要链
  `${AVOX_TRDPARTY}/library/darwin/ffmpeg/lib/*.a`。`libavox.a` 里的 `av_*`
  是未定义引用，最终由 shim 这份 kit 解析；同时链两份会让同一个 dylib 出现
  两套 ffmpeg。kit 已把 lame/x264/x265/dav1d/mpg123 的 `.a` 收进同一目录，按
  `libavformat → libavcodec → libswresample → libavutil → 编码器依赖` 的顺序
  链接（`libmp3lame.a` 后面跟 `libmpg123.a`）。
- 补 framework：`VideoToolbox CoreMedia CoreVideo AudioToolbox AudioUnit
  CoreAudio Security CoreFoundation CFNetwork Metal MetalKit QuartzCore
  IOSurface ScreenCaptureKit`；OpenSSL 用 Homebrew 的静态 `libssl.a` /
  `libcrypto.a`（Agent/httplib 无 BoringSSL 时依赖）。
- `libMoltenVK.dylib` 以 `libvulkan.1.dylib` 拷到 shim 同目录（volk 按该名
  加载 loader；MoltenVK 直接充当 loader）。
- 产物：`avoxkit_native.dylib`（`PREFIX ""`，与 Dart/Windows 同名），设置
  `INSTALL_NAME_DIR @rpath`、`BUILD_RPATH/INSTALL_RPATH "@loader_path"`。
- `CMAKE_OSX_ARCHITECTURES=arm64`、`CMAKE_OSX_DEPLOYMENT_TARGET=12.0`，与 avox
  保持一致。要 universal 就两边一起 universal，不要一个 arm64 一个通用。

### 4.3 插件符号可见性（最容易卡住的一步）

avox 的 Apple 插件是用 `-Wl,-undefined,dynamic_lookup` 编的（见
`cmake/avox_module.cmake`）：插件不链 avox，核心符号在 `dlopen` 时从全局
符号表回绑。而 Dart 的 `DynamicLibrary.open` 默认是 `RTLD_LOCAL`，avox 又
静态链在 shim 里 —— 结果就是插件 `dlopen` 报 `symbol not found`，
`createWatermarkRemoval()` 返回 null，图像修复能力“不存在”。

处理：在 Flutter Runner 里先以 `RTLD_GLOBAL` 把 shim 载入，再让 Dart 打开
同一路径（同一个 image，引用计数 +1）：

```swift
// MainFlutterWindow.awakeFromNib()，在 super 之前
if let fw = Bundle.main.privateFrameworksPath {
  let path = fw + "/avoxkit_native.dylib"
  dlopen(path, RTLD_NOW | RTLD_GLOBAL)
}
```

不要走“avox 静态进 exe + `-export_dynamic`”那条路：shim 和 exe 会各有一份
avox 单例，正是 avox 注释里警告的“AvoxManager 分裂”。

验证：

```bash
nm -gU "$APP/Contents/Frameworks/avoxkit_native.dylib" | grep -i AvoxManager
# 有输出才说明核心符号在动态符号表里
```

### 4.4 资源与插件目录

- **包内资源有两条合法摆法：`Contents/Resources/avox.bundle/<子目录>/`
  （整包，panvox 用）或 `Contents/Resources/<子目录>/`（扁平，只带需要的；
  avoxkit 的 `glsl/` 走这条）。**
  `glsl/`、`fonts/`、`images/`、`models/`、`certs/` 全部由
  `src/avox_apple/IOSHelper.mm` 的 `getBundlePath` 解析，查找链只有
  `mainBundle/avox.bundle/…` → `Contents/Resources/avox.bundle/…` →
  `Contents/Resources/<相对路径>` → 当前工作目录。
  **`assets/` 前缀只存在于 Windows/Linux 分支**（`getAvoxPath() + "/assets/"`）：
  macOS 分支压根不调 `getAvoxPath()`，所以「`Resources/assets/glsl` +
  `MacOS/assets` 软链」这套在 Apple 上一个文件都命中不了，而且失败是静默的
  （详见 §4.5）。资源也不能直接放 `Contents/MacOS`——`codesign --deep`
  会把 `.spv` 当未签名代码处理。
- 插件目录来自 `dladdr(avoxModuleMarker)`：avox 静态链在 shim 里，定位结果
  是 shim 的路径，所以插件放：
  ```
  avoxkit.app/Contents/Frameworks/plugins/libavox_cv.dylib ...
  ```
  `libonnxruntime.1.23.2.dylib` 也放这里（插件 rpath 是 `@loader_path`）。
- `libvulkan.1.dylib` 放 `Contents/Frameworks/`，shim 的 `@loader_path`
  rpath 能命中。
- 模型不随包：Dart 侧仍通过 `ak_init.models_dir` 注入
  `~/Library/Application Support/dev.avox.avoxkit/models`，shim 调
  `avox::setModelsRoot`，macOS 不需要改。首次使用下载 + sha256 校验。

### 4.5 Apple 资源与引用加载（panvox 实证口径，2026-10-30）

panvox 的在售包是这条链的权威参考：`panvox/tools/deploy_macos_runtime.sh`
（macOS）与 `panvox/tools/deploy_ios_runtime.sh`（iOS）。**照抄摆位，别自创目录名**——
2026-10-30 录屏全绿就是这么来的：着色器摆在 `Resources/assets/glsl`，引擎一个
都没加载上，`RGBA2YUV` 转换层被禁用，写出的视频轨每帧都是 0（YUV 0,0,0 在
播放器里显示为深绿），而日志里只有 4 行 warn。

| 坑 | 症状 | 口径 |
|---|---|---|
| macOS 把资源摆成 `Resources/assets/…` | 全部 compute 层被禁用：`glsl module null, layer disabled`；采集/转码产出的视频轨全 0（深绿/全黑），场景层不出图 | 整包拷 `install/aarch64/avox.bundle` → `Contents/Resources/avox.bundle`，或只摆 `Contents/Resources/glsl`（avoxkit 用后者） |
| 加载失败静默 | 无报错、无崩溃，只是「功能没效果」 | release 下 `LOGASSERT` 被编掉，只剩一行 warn。判据见下「自查三连」 |
| iOS 用 `*.bundle` 后缀 | App Store 90035「嵌套代码未签名」，本地 codesign 全绿也拒 | 改名 `avox_res`；引擎 `getBundlePath` 查不到 `avox.bundle` 会自动再试 `avox_res` |
| 资源目录里带脚本类文件 | 90035 逐文件点名（无 shebang、无执行位也判） | 入包前删 `.py/.mm/.m/.sh/.rb/.pl`（iOS 上是死重） |
| 资源目录里有非 ASCII 文件名 | 90035 按字节漂移点名，本地验不出 | 同样入包前按字节删除 |
| 构建相位里 `rm -rf` 大目录 | 本机批量删除保护（>50 文件）拦下子进程，`script_phase` 在编译完成之后整体失败 | 用 `ditto` 原地覆盖合并，不要删 |
| 二进制/资源在 xcodebuild 之外补拷 | macOS 代码门禁拒绝加载（`dlopen` 报 ENOENT），事后重签也无效 | 拷入与签名放进 Podfile `script_phase`（panvox `app/macos/Podfile` 的 `Deploy Panvox Native Engine` 同款） |
| iOS 主执行文件被 strip | 全局符号连导出表一起削光，`DynamicLibrary.process()` 取符号全空（TestFlight 1.0.0(2) 实证） | 引擎+shim 链成 framework dylib；avoxkit 走 `avoxkit_native.dylib`，天然免疫 |
| iOS `use_frameworks` 后资源进了框架 | `mainBundle` 找不到 `avox.bundle`，资源全哑 | 查找链已含 `Frameworks/<pod>.framework/avox.bundle/`，摆对即可 |
| iOS 沙盒打不开系统字体 | 字幕整行 tofu（方框数 = 字符数） | 喂 `avox.bundle/fonts/` 的包内字体，别依赖系统 PingFang |
| 插件目录摆错 | 插件全缺、`image_inpaint=0` | `dladdr` 定位到 shim ⇒ 插件放 `Contents/Frameworks/plugins/`（§4.4） |
| 增量构建后仍链旧 ffmpeg | 部署静默链旧库（panvox 10/14 缺 `_ff_httpproxy_protocol` 实证） | 3rdparty 换批后跑一次默认全量构建，再 `nm` 复核符号 |

上 App Store 的资源目录只留数据文件：脚本类文件与非 ASCII 文件名入包前剥掉
（avoxkit 的 `agent/skills` 在 iOS 上是死重），模型不随包、改 App 内下载。

自查三连（贴进 bug 报告）：

```bash
grep -E "load shader failed|layer disabled" \
  ~/Library/Application\ Support/dev.avox.avoxkit/work/logs/avoxkit-*.log
find "$APP/Contents/Resources" -maxdepth 3 -name "*.spv" | head -3
ffmpeg -i <产物.mkv> -vf signalstats,metadata=print -f null - 2>&1 | grep YAVG
# YAVG 恒 0 或三平面全 0 = 管线没写像素, 不是播放器问题
```


## 5. Flutter 侧

### 5.1 dylib 路径（已实现）

`lib/native/ak_bindings.dart` 的 `_defaultLibraryPath()` 已加 macOS 分支：
`Contents/MacOS/avoxkit` → `Contents/Frameworks/avoxkit_native.dylib`；找不到
时回退到 `avoxkit_native.dylib`（isolate 里同样走绝对路径）。

### 5.2 工程脚手架

`macos/` 目录原先是 Windows 上生成的；在 Mac 上 `flutter pub get` 会补
`macos/Podfile`、`Flutter-*.xcconfig` 的 Pods include。Flutter 3.47 走 SPM +
CocoaPods 混合，构建直接 `flutter build macos --release` 即可。

`path_provider_foundation` 在 `.flutter-plugins-dependencies` 里标记
`native_build:false`，因此 `GeneratedPluginRegistrant.swift` 只有
`file_selector_macos` 是正常的；实测模型/工作目录仍能拿到
`Application Support`（启动日志 `work_dir=.../dev.avox.avoxkit/work`）。

### 5.3 部署目标与架构

- Xcode 工程 `MACOSX_DEPLOYMENT_TARGET = 12.0`（avox 是 12.0，低了链接警告/
  运行挂）。
- avox 的 macOS 构建默认 `arm64`。Flutter 默认出 universal
  （arm64 + x86_64）。建议先对齐 arm64：
  `flutter config --enable-macos-arm64-only`（或在 Xcode 里
  `EXCLUDED_ARCHS[sdk=macosx*] = x86_64`）。要 Intel 就 avox/shim/ffmpeg
  全部按 `x86_64` 或 `universal` 重编，别混。

### 5.4 沙盒与权限（已实现）

`macos/Runner/Release.entitlements` 已关闭 `app-sandbox`：直接分发（DMG）时
“输出到源文件旁边 / 文件夹批量 / 挂载的 NAS 路径”才不会被沙盒拦。
`DebugProfile.entitlements` 保持沙盒 + `allow-jit` + `network.server`。

若以后改回沙盒，至少补：

```xml
<key>com.apple.security.network.client</key><true/>          <!-- 模型下载 / URL 直链 -->
<key>com.apple.security.files.user-selected.read-write</key><true/>
<key>com.apple.security.files.bookmarks.app-scope</key><true/> <!-- 最近文件 -->
```

注意沙盒下 `file_selector` 选中的是“安全作用域”授权：选中文件夹才能写同目录
的 `-repaired` sidecar；跨目录输出要用户再选一次。

### 5.5 退出钩子（已实现）

`macos/Runner/AppDelegate.swift` 在 `applicationWillTerminate` 里
`dlopen`/`dlsym` 取 `ak_shutdown` 并调用。2026-10-30 GUI 冒烟中 Cmd+Q 退出，
日志可见完整 `shutdown: ... done` 序列，进程退出且无新崩溃报告。

### 5.6 预览

`ak_preview_*` 在 macOS 全部 no-op（`ak_preview_win.cpp` 的 `#else` 分支），
UI 会自动退化成占位/进度，这是设计好的降级，不是 bug。要真正原生预览，
二期加 `ak_preview_mac.mm`：`NSView` + `CAMetalLayer`，通过 MoltenVK 的
`vkCreateMacOSSurfaceMVK` 把 layer 交给 avox 的渲染面。工作量与 Windows 的
`ak_preview_win.cpp` 相当，不要和首版移植绑在一起。

## 6. 打包、签名、公证

### 6.1 目录布局

```
avoxkit.app/Contents/
├── MacOS/
│   └── avoxkit                       # Flutter Runner
├── Frameworks/
│   ├── avoxkit_native.dylib          # shim + libavox.a + kit 的 libav*.a
│   ├── libvulkan.1.dylib             # MoltenVK, volk 的 loader
│   └── plugins/
│       ├── libavox_cv.dylib
│       ├── libavox_onnx.dylib
│       ├── libavox_opencv.dylib
│       ├── libavox_sherpa.dylib
│       └── libonnxruntime.1.23.2.dylib
└── Resources/
    └── avox.bundle/                  # Apple 侧唯一认的资源根 (§4.4/§4.5)
        ├── glsl/*.spv
        ├── fonts/
        ├── images/
        └── certs/cacert.pem
```

打包入口：`script/build_macos.sh`（kit 校验 → shim → Flutter → 签名 → zip）。

### 6.2 链接检查（换机必做）

```bash
APP=build/macos/Build/Products/Release/avoxkit.app
otool -L "$APP/Contents/Frameworks/avoxkit_native.dylib"
otool -L "$APP/Contents/Frameworks/plugins/libavox_onnx.dylib"
```

要求：只出现 `@rpath/`、`@loader_path/`、`/System/Library/`、
`/usr/lib/`。出现 `/opt/homebrew/...` 或 `/Users/<构建机>/...` 就是没打包
干净，换台机器必挂。`script/build_macos.sh` 会逐库跑这条检查，并给
`libvulkan.1.dylib` 改 install id（原值指向 Homebrew molten-vk）。

### 6.3 签名与公证

**本地测试默认用固定自签证书 `panvox-dev`**（`script/build_macos.sh` 检测到就
自动选用）：ad-hoc 签名的 designated requirement 是 cdhash，每次重建都变，
屏幕录制/麦克风的 TCC 授权随之失效——反复重建后 System Settings 里开关仍
显示打开，采集却报 `-3801/userDeclined`。自签证书的 requirement 是
`identifier + certificate leaf`，跨重建稳定，授权只需给一次。

自签/`--sign -` **不要加 `--options runtime`**：没有 Team ID，hardened
runtime 的库校验会拒绝加载 Flutter framework 与插件 dylib
（`mapping process and mapped file (non-platform) have different Team IDs`）。
脚本只在 `Developer ID Application:` 身份下开 runtime 和 timestamp。

Developer ID 分发时，嵌套 dylib/framework 与主程序必须用同一 identity 签：

```bash
# 先内层后外层：每个 dylib 都要签，hardened runtime 才允许加载
codesign --force --options runtime --timestamp \
  --sign "Developer ID Application: ..." \
  "$APP/Contents/Frameworks/plugins/"*.dylib
codesign --force --options runtime --timestamp \
  --sign "Developer ID Application: ..." \
  "$APP/Contents/Frameworks/"*.dylib
# 嵌套 framework 也必须签: 只签 dylib 会漏掉
# FlutterMacOS/App/file_selector/objective_c, 公证会直接失败
find "$APP/Contents/Frameworks" -name '*.framework' -type d -exec \
  codesign --force --options runtime --timestamp \
  --sign "Developer ID Application: ..." {} \;
codesign --force --options runtime --timestamp --entitlements macos/Runner/Release.entitlements \
  --sign "Developer ID Application: ..." "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

xcrun notarytool submit avoxkit.zip --keychain-profile avoxkit --wait
xcrun stapler staple "$APP"
```

本地开发可以 ad-hoc：`codesign --force --deep --sign - "$APP"`（不要用于分发）。

### 6.4 分发渠道与许可证

本仓 AGPL-3.0。macOS 0.1.0 包使用 **avox commercial（LGPL 渠道）+ LGPL
FFmpeg**（`--disable-gpl`，无 x264/x265；H.264/HEVC 走 VideoToolbox）。
DMG/官网 + 公证可直接分发，分发时随包提供对应源码（或书面 offer）。

MAS 仍需单独处理：avoxkit 自身的 AGPL 与 App Store 条款冲突（需要 §7
App Store 例外或双许可）、2.4.5(i) 沙盒文件流、2.4.5(iv) 模型下载，以及
账号级 4.3 风险。不要拿 DMG 包直接提审。

Windows 0.1.0 仍使用 GPL kit（x264/x265），只影响 Windows 包；macOS 发行链
已切到 LGPL。

## 7. 验收清单

在 Mac 上按 Windows 的顺序跑一遍，全部通过再谈“移植完成”。

### 7.1 无头

```bash
./script/ffmpeg/build_ffmpeg_macos.sh --check-version
./script/ffmpeg/build_ffmpeg_macos.sh --verify third_party/ffmpeg/kit-macos/lib

cd native/avtool/build/bin/Release
./ak_smoke version            # abi=1.x, platform=macos, has_libmp3lame
./ak_smoke init  <work_dir>
./ak_smoke caps  <work_dir>   # image=1 image_inpaint=1
./ak_smoke probe <media> <work_dir>
./ak_smoke transcode <in> <out> <work_dir> --audio-codec mp3 --container mp4 --overwrite
./ak_smoke extract <in> <out.m4a> <work_dir> --codec aac --overwrite
./ak_smoke trim <in> <out> <work_dir> 10000 16000
./ak_smoke index <in> 300
./ak_smoke frames <in> <out_dir> 8 320
./ak_image_test <image> <models_dir>
```

`ak_image_test` 要看到 `image_plugin=1 image_inpaint=1`，自动检测/手绘 mask
都能出 PNG；样图没有水印时接受 `no_watermark`。

2026-10-30 实测（arm64 / macOS 26.1）：

- `ak_features_test` 170 checks / 0 failed（`ass_test.mkv`，覆盖缩放、抓帧、
  队列、错误路径、MP3、直拷 GOP）；
- `ak_subtitle_test` 9 / 0；`ak_image_test` PASS
  （`image_plugin=1 image_inpaint=1`）；
- `probe` / `transcode`(MP3) / `extract`(m4a) / `trim` / `index` / `frames`
  全部 exit 0；`caps.vulkan=true`；
- 无音轨源（`avox_electron.mp4`）转码不再被 `audio_missing` 误判（见 §9.1）。

### 7.2 GUI

1. **从 Finder 双击启动**（不要从终端启动 —— 终端可能带 Homebrew PATH，
   把“没打包干净”的依赖藏起来，Windows 的 `libgcc` 事故就是这么漏的）。
2. 选视频转 MP4（H.264 + AAC）、提取 MP3、截取片段、抓缩略图。
3. 图像修复：自动识别 → 修复 → 再跑一次确认覆盖 `-repaired`；文件夹批量。
4. 退出应用，确认无崩溃、无残留进程（Activity Monitor）。

2026-10-30 实测：`open` 启动后引擎就绪、四个插件全部发现；转换页选
`ass_test.mkv`，probe 显示 H.264+AAC 30s；改 MP4 直接封装完成，产物
`ffmpeg -i` 为 H.264+AAC 30s；Cmd+Q 退出日志完整、无残留进程、无新崩溃报告。
分辨率改档未在 GUI 冒烟里重复点击，同一路径已由 `ak_features_test` 的缩放
用例覆盖。

### 7.3 换机

拷到另一台 Mac（最好同架构、无开发环境）双击启动；`otool -L` 和
`codesign --verify` 在打包机先过一遍。

## 8. 坑位对照表

| 现象 | 原因 | 处理 |
|---|---|---|
| 插件全部缺失 / `image_inpaint=0` | shim 以 RTLD_LOCAL 载入，插件 `dynamic_lookup` 找不到 avox 符号 | Runner 先 `dlopen(RTLD_GLOBAL)`；`nm -gU` 确认符号导出 |
| `dlopen` 插件报 `symbol not found` | 同上；或 avox 侧漏了 `AVOX_EXPORT` | 在 avox 补导出，不要 fork 核心 |
| `createWatermarkRemoval` 链接失败 | avox 头/库没有该导出（工作区改动未提交） | 在 avox 提交并重编，同步 install 头 |
| `caps.vulkan=false`；缩放转码 `output_finalize_failed`；frames `render_unavailable` | 缺 Vulkan loader，`volkInitialize` 失败 | 把 `libMoltenVK.dylib` 以 `libvulkan.1.dylib` 放到 shim 同目录 |
| 链接报重复 `dav1d_*` 符号 | avox 默认构建静态链入 `libwebrtc_nosym.a`，内含旧 ffmpeg/dav1d | 用 `AVOX_ENABLE_WEBRTC=OFF AVOX_ENABLE_ZLMEDIAKIT=OFF` 重配 avox |
| 无音轨源转码报 `audio_missing` | 产物缺音轨校验没判断源是否有音轨 | 已修：源无音轨时跳过该校验（`ak_task.cpp`） |
| MP3 出声失败 / `ak_init` 报 ffmpeg mismatch | ffmpeg 没有 `--enable-libmp3lame` | 按 §2.1 用 `build_ffmpeg_macos.sh` 重建 kit，`has_libmp3lame=true` |
| 缩略图/修复保存失败（`encode_failed`） | kit 缺 `mjpeg`/`png` 编码器或 `tga` 解码器 | 重新跑 §2.1 脚本；`--verify` 会直接报缺哪个符号 |
| 链接时报重复 `av_*` 符号 | 同时链了 avox 3rdparty 和本仓 kit 的 ffmpeg | 只链 kit；avox 的 `.a` 只用于编译 `libavox.a`，不进最终链接 |
| 转码静默丢帧、预览/场景全黑、录屏出深绿（视频轨全 0） | 资源摆在 `Resources/assets/`，Apple 侧一个都加载不上，`RGBA2YUV` 等 compute 层被禁用 | 整包拷成 `Contents/Resources/avox.bundle/`（§4.4/§4.5）；`grep "load shader failed"` 复核 |
| `codesign --deep` 报 `...spv ... not signed` | 非代码资源放在 `Contents/MacOS` 下 | 资源移 `Contents/Resources`，别用 `MacOS/assets` 软链 |
| iOS 提审 90035「嵌套代码未签名」 | 资源目录用了 `*.bundle` 后缀 / 里面有脚本类文件 / 非 ASCII 文件名 | 改名 `avox_res`，入包前剥脚本类与非 ASCII 名（§4.5） |
| ad-hoc 包启动即崩：`different Team IDs` | ad-hoc 签名 + `--options runtime` 的库校验 | ad-hoc 不加 runtime；Developer ID 时全部用同一 identity |
| 换机后插件加载失败 | 插件依赖 `/opt/homebrew` 或构建机绝对路径 dylib | `otool -L` 检查，`install_name_tool` 改 `@rpath`，或静态链 |
| Intel Mac 启动即崩/找不到镜像 | app universal 但 dylib 只有 arm64 | 全部按同一架构构建，或 `--enable-macos-arm64-only` |
| 打开文件/输出失败 | 沙盒未授权 | 补 `files.user-selected.read-write`，或关沙盒走 DMG |
| 模型下载失败 | 沙盒缺 `network.client` | 补 entitlement |
| 退出偶发崩溃 | 没调 `ak_shutdown` | AppDelegate 终止钩子 |
| `flutter build macos` 缺 Podfile/Pods | Windows 上生成的脚手架不完整 | `flutter pub get` 会生成；必要时 `flutter create --platforms=macos .` |
| 录屏报 `-3801/userDeclined`，系统设置开关却是开的 | ad-hoc 签名 cdhash 每次重建都变，旧 TCC 授权对不上 | 用固定自签证书签（默认 `panvox-dev`）；`tccutil reset ScreenCapture dev.avox.avoxkit` 后重新授权 |
| 长录音 `mic.wav` 只有最后 5 秒 | avox `WavSave::patchHeader` 回填头后写指针停在 44，覆盖已写数据 | 已修（avox `b8105dd`），回填后 seek 回数据末尾 |
| 导出报 `cannot finalize output: Cross-device link` | 保存位置与工程目录跨卷（外置盘/iCloud），`rename` 返回 EXDEV | 已修：`replace_file` 退化为 copy + remove |
| 点「打开所在文件夹」没反应 | `_reveal` 只处理了 Windows | 已修：macOS 走 `open -R` |

## 9. 移植待办

### 9.1 已完成（2026-10-30）

1. avox：`createWatermarkRemoval()` 已随 `c9e9fb4` 导出，install 头/库同步。
2. 本仓：`kit-macos` 构建 + `--verify`（n9.0.1、LGPL/libmp3lame、nonfree/ GPL
   标记检查、静态链接 + 组件自检）。
3. avox：`build_mac.py --flavor=commercial`，关闭 WebRTC/ZLM，`libavox.a` 含
   `IMediaComposer`/`createWatermarkRemoval`。
4. shim：Apple CMake 分支、`avoxkit_native.dylib`、kit 唯一 ffmpeg、OpenSSL
   静态、插件/glsl/libvulkan.1.dylib 拷贝。
5. Flutter：dylib 路径、Release 关沙盒、`ak_shutdown` 钩子、
   `RTLD_GLOBAL` 预加载、`flutter build macos --release`。
6. 打包：`script/build_macos.sh` 产出 zip，`otool`/`codesign` 验收通过。
7. 无音轨源 `audio_missing` 误判修复，`ak_features_test` 170/0 回归。
8. 录屏整链打通：SCStream 输出队列生命周期修复（avox `e8379bb`）、
   macOS 显示器/麦克风枚举、WAV 周期回填覆盖修复（avox `b8105dd`）；
   实测 43.8s 录屏 `mic.wav` 全长度、`capture.mkv` 带 AAC 音轨。
   ⚠️ 该次验收只核了音轨与时长，**没核画面像素**——视频轨实际全 0，见 §9.3。
9. 工程导出跨卷修复（`EXDEV` → copy+remove），导出到 `/Volumes/PSSD`
   实测 H.264+AAC；「打开所在文件夹」补 macOS `open -R`。
10. 本地/内测包默认用固定自签证书 `panvox-dev`，TCC 授权跨重建有效。

### 9.2 发布前仍需

1. Developer ID Application 证书（Xcode → Settings → Accounts → Manage
   Certificates → +），然后跑 `script/release_macos.sh`：构建 → 公证 app →
   装订 → 出 DMG → 公证/装订 DMG → `spctl` 校验。公证凭据用团队 ASC API Key
   一次性 `notarytool store-credentials`，见脚本头注释。
2. 换一台没有 Xcode/Homebrew/Vulkan SDK 的 Mac 双击验收（§7.3）。
3. 已完成（2026-10-31）：`LICENSE.txt` / `THIRD_PARTY_NOTICES.md` /
   `SOURCE-OFFER.md` 随包进 `Contents/Resources/`，DMG 根目录再放一份；
   `Info.plist` 补了 `NSScreenCaptureUsageDescription`、
   `LSApplicationCategoryType`、`ITSAppUsesNonExemptEncryption`。
4. 二期：NSView/Metal 原生预览；Intel 或 universal 构建。

### 9.3 已修缺陷（2026-10-30 发现并当天修复）

**结论：已修并实测通过。** `script/build_macos.sh` 现摆
`Contents/Resources/glsl/`，同时清掉旧包回灌的 `Resources/assets` 与
`MacOS/assets`；无头工具在 `<bin>/glsl` 也放一份（macOS 只查
`Resources/glsl` 或 `CWD/glsl`）。2026-10-30 22:58 实录 19.27s：
`screen.mkv` 的 `YAVG≈50.3`（修复前恒 0），日志管线为
`VkInputLayer(rgba8) → VkRGBA2YUVLayer(r8) → VkOutputLayer(r8)`，
无 `layer disabled`。

以下为事故复盘（保留）：

**录屏/转码产出的视频轨全 0，播放显示深绿。** 根因不是采集也不是编码：

- `script/build_macos.sh` 的 spv 摆放段（未入库，约 72-78 行）把
  `glsl/target/*.spv` 摆到 `Contents/Resources/assets/glsl/`，再建
  `Contents/MacOS/assets` 软链，
  依据是「`getAvoxPath()/<exe dir>/assets/glsl`」——那是 Windows/Linux 分支
  的解析方式；macOS 分支只走 `getShaderPath()`，查找链里没有 `assets/` 前缀
  （§4.4），于是 4 个 shader 全部加载失败：
  `rgba2yuvV1` / `resize` / `yuv2rgbaV1` / `scene`。
- 失败静默：`LOGASSERT` 在 release 被编掉，只剩 `VkLayer.cpp` 一行
  `glsl module null, layer disabled`。`VkRGBA2YUVLayer` 被禁用后，
  `VkInputLayer(rgba8) → VkRGBA2YUVLayer → VkOutputLayer(r8)` 这条链上没人往
  输出 YUV 表面写数据，`screen.mkv` 219 帧全是 YUV(0,0,0)。
- YUV 全 0 在播放器里就是深绿（色度 0 = 极饱和绿），所以 Finder 缩略图和
  导出成片（1920×1080，导出只是放大重编）都是绿的。已有产物无法恢复。

本次采用方案 1（出包侧，未动引擎）：

1. `build_macos.sh` 改摆 `Contents/Resources/glsl/`（查找链内的扁平形态），
   删掉 `MacOS/assets` 软链，并在 staging 时清掉历史包回灌的旧目录。
   判据：录 5 秒后 `ffmpeg -i screen.mkv -vf signalstats,metadata=print -f null -`
   的 `YAVG` 不再恒 0。
2. 引擎侧加固（可选，尚未做）：`VkShader::loadShaderModule` 的 `__APPLE__`
   分支在 `getShaderPath()` 返回 null 时回退 `getAvoxPath() + "/assets/" + path`，
   让 macOS 与 Windows/Linux 对称（属 avox 引擎缺口，按 AGENTS.md 在 avox 仓改）。

验收口径补一条：**录屏/转码类改动必须核像素（signalstats 或抽一帧看），
只看时长与音轨会漏掉整条视频轨。**
