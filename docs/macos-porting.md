# macOS 移植指南（环境、构建与打包）

状态：**移植指南，未落地**。内部文档，不外发（含引擎/库仓路径与构建细节）。
Windows 0.1.0 已发布；本文记录在 macOS 上从零配环境到跑通 `avoxkit` 的路径，
以及 2026-10-29 在 Windows 侧踩过的同类坑的 Apple 版。

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
- 真正的工作量不在改 `.cpp`，而在四件事：
  1. **静态链接清单**：avox 在 Apple 是静态库，shim 要把 avox 的全部第三方
     依赖一起链进来，且只能有一份 ffmpeg。
  2. **插件符号可见性**：macOS 插件用 `-undefined dynamic_lookup`，宿主必须
     让 avox 符号进全局符号表，否则插件全部加载失败（对应 Windows 的
     “插件发现不到”）。
  3. **GPL ffmpeg kit**：必须自带 `--enable-libmp3lame`，并补上 avox 图像
     IO 需要的 `mjpeg`/`png` 编码器和 `tga` 解码器。
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
- onnxruntime / opencv：sibling 库仓 `avox_library/3rdparty/library/darwin/`。
  `FindONNX.cmake` 先找库仓；`FindOpenCV.cmake` 先找 avox 仓、再回落库仓。

### 2.1 ffmpeg（GPL + libmp3lame，必须自建）

这是最容易踩坑的一项：

- 出厂 ffmpeg 必须是 **GPL flavor + libmp3lame**（见 `AGENTS.md` 许可证红线）。
  avox 自带的 `script/ffmpeg/build_ffmpeg_apple.sh` 是 LGPL 白名单 + VideoToolbox，
  **没有 libmp3lame，也没有 mjpeg/png 编码器**，不能直接用于 avoxkit。
- avox 在 macOS 是静态库，`FindFFmpeg.cmake` 从
  `avox/3rdparty/library/darwin/ffmpeg/{include,bin,lib}` 找 `libav*.a`。
  仓里默认只带 headers + pkgconfig，`.a` 要本机构建后放进去；找不到 ffmpeg
  时 avox 会直接关掉 FFmpeg 支持（转码/探测全废），不是报错退出。
- `libavox.a` 只保留对 ffmpeg 的未定义引用，最终由 shim 链接的 `.a` 解析。
  所以 avox 和 shim 必须链接 **同一份** `.a`，否则同一个 dylib 里会出现
  两份 ffmpeg 符号。
- avoxkit 需要的额外编解码器（Windows kit 已有，macOS 容易漏）：
  - 编码：`libmp3lame`、`aac`、`libx264`、`libx265`、`mjpeg`、`png`
  - 解码：`png/jpeg/bmp/targa/webp`（图像修复输入）、常用视频/音频解码
  - `mjpeg`/`png` 编码是 avox `ImageIO` 保存缩略图和修复结果用的；
    缺了表现是 `ak_media_frames` 报 `encode_failed`、
    图像修复报 `image_encode_failed`，不是崩溃，容易误判。

建议直接做全量 GPL 构建（不要用 `--disable-everything` 白名单，省得逐个补）：

```bash
# 依赖：lame/x264/x265 优先用静态库；先确认 .a 存在
brew install lame x264 x265 pkg-config
ls "$(brew --prefix)/opt/lame/lib/libmp3lame.a" \
   "$(brew --prefix)/opt/x264/lib/libx264.a" \
   "$(brew --prefix)/opt/x265/lib/libx265.a"
# Homebrew 缺 .a 时，从源码 prefix 到 $HOME/avoxkit-deps 再
# PKG_CONFIG_PATH=$HOME/avoxkit-deps/lib/pkgconfig 重来。
# 任何情况下都不要让产物依赖 /opt/homebrew 的 dylib（见 §6 验收）。

export PKG_CONFIG_PATH="$(brew --prefix)/opt/lame/lib/pkgconfig:$(brew --prefix)/opt/x264/lib/pkgconfig:$(brew --prefix)/opt/x265/lib/pkgconfig"
./configure \
  --prefix="$HOME/avoxkit-ffmpeg" \
  --enable-static --disable-shared --enable-pic \
  --enable-gpl --enable-version3 \
  --enable-libmp3lame --enable-libx264 --enable-libx265 \
  --enable-videotoolbox --enable-securetransport --enable-zlib \
  --disable-autodetect \
  --disable-programs --disable-doc --disable-avdevice --disable-avfilter --disable-swscale
make -j"$(sysctl -n hw.ncpu)" && make install
```

把产物合并进 avox 仓（不要删掉仓里自带的 `include/dav1d` 和 `lib/pkgconfig`）：

```bash
LIB=$HOME/src/avox/3rdparty/library/darwin/ffmpeg
mkdir -p "$LIB/include" "$LIB/lib"
cp -R "$HOME/avoxkit-ffmpeg/include/"* "$LIB/include/"
cp -R "$HOME/avoxkit-ffmpeg/lib/"* "$LIB/lib/"
```

验收（二选一）：

```bash
# 构建后 shim 的 ak_smoke version 会打印 ffmpeg 配置哈希
native/avtool/build/bin/Release/ak_smoke version | grep -i libmp3lame
# 或直接扫静态库里的 configure 串
strings "$LIB/lib/libavcodec.a" | grep -E -- '--enable-(gpl|libmp3lame)'
```

出现 `--enable-nonfree` 或 `--enable-libfdk-aac` 的产物任何渠道不可分发
（`AGENTS.md` 红线）。

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
python3 build_mac.py --flavor=agpl
```

- `--flavor=agpl`：允许 GPL 软件编码（libx264/libx265）。`commercial` 渠道会
  关掉这些，和本仓的 GPL kit 不匹配。
- 脚本会自动构建 `build/macos/{fdk-aac,freetype,sherpa-onnx,sentencepiece,...}`
  再编 avox；插件默认全开（`plugins/options.cmake` 里 ONNX/OPENCV/CV/SHERPA
  都是 ON）。
- 产物（以 configure 打印的 `CMAKE_INSTALL_PREFIX` 为准，通常是）：
  `build/macos/avox/install/aarch64/Release/`
  - `libavox.a`
  - `plugins/libavox_cv.dylib`、`libavox_onnx.dylib`、
    `libavox_opencv.dylib`、`libavox_sherpa.dylib`
  - `assets/glsl/`（缺了转码会静默丢帧/预览全黑，Windows 已有教训）
  - `libMoltenVK.dylib` 被拷到上一级 `install/aarch64/`（见
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

### 4.2 CMake：新增 Apple 分支

现有 `native/avtool/CMakeLists.txt` 是 MSVC 专用（`/MT`、`/utf-8`、
`avformat.lib`、`.dll` 拷贝）。Apple 分支至少要做：

- `AVOX_OUT_DIR = <avox>/build/macos/avox/install/aarch64/Release`
- `AVOX_LIB = ${AVOX_OUT_DIR}/libavox.a`（不是 `avox.lib`）
- 链接 avox 时用 **whole-archive 语义**，否则模块注册的静态初始化会被
  dead-strip 掉（avox 的 playtest 用
  `"$<LINK_LIBRARY:WHOLE_ARCHIVE,avox>"` 就是为这个）：
  ```cmake
  target_link_options(avoxkit_native PRIVATE "-Wl,-force_load,${AVOX_LIB}")
  ```
- ffmpeg 只链 **一份**：优先用 `${AVOX_OUT_DIR}/libav*.a`（avox 构建时由
  `avox_run_module_copy` 从 avox 仓的 ffmpeg 目录拷过来），没有就直接链
  `${AVOX_TRDPARTY}/library/darwin/ffmpeg/lib/*.a`。两者必须是同一次
  §2.1 的 GPL 构建；不要再加第二个 ffmpeg prefix。
- 补 framework：`VideoToolbox CoreMedia CoreVideo AudioToolbox Security
  CoreFoundation Metal MetalKit QuartzCore` 以及 `libMoltenVK.dylib`；
  以 playtest 的实际链接行为准。
- 产物：`avoxkit_native.dylib`，设置
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

- avox 在 Apple 上 `getAvoxPath()` 取的是**主可执行文件**目录
  （`_NSGetExecutablePath`），不是 `libavox.a` 所在目录。所以
  `assets/glsl` 要放到：
  ```
  avoxkit.app/Contents/MacOS/assets/glsl/
  ```
  这就是 Windows 版 `windows/runner/CMakeLists.txt` 拷 glsl 的等价动作；
  漏了会转码静默丢帧。
- 插件目录来自 `dladdr(avoxModuleMarker)`：avox 静态链在 shim 里，定位结果
  是 shim 的路径，所以插件放：
  ```
  avoxkit.app/Contents/Frameworks/plugins/libavox_cv.dylib ...
  ```
  `libonnxruntime.1.23.2.dylib` 也放这里（插件 rpath 是 `@loader_path`）。
- 模型不随包：Dart 侧仍通过 `ak_init.models_dir` 注入
  `~/Library/Application Support/dev.avox.avoxkit/models`，shim 调
  `avox::setModelsRoot`，macOS 不需要改。首次使用下载 + sha256 校验。

## 5. Flutter 侧

### 5.1 dylib 路径

`lib/native/ak_bindings.dart` 的 `_defaultLibraryPath()` 只有 Windows 分支，
macOS 会 fallback 到 `avoxkit_native.dll`（必然失败）。加：

```dart
if (Platform.isMacOS) {
  // Contents/MacOS/avoxkit -> Contents/Frameworks/avoxkit_native.dylib
  return p.normalize(p.join(
    p.dirname(Platform.resolvedExecutable),
    '..', 'Frameworks', 'avoxkit_native.dylib',
  ));
}
```

### 5.2 工程脚手架

`macos/` 目录是 Windows 上生成的，缺 Podfile/SPM 的完整脚手架，
`GeneratedPluginRegistrant.swift` 里目前只有 `file_selector_macos`。在 Mac 上：

```bash
flutter pub get
flutter build macos --release
# 若提示缺 Podfile / Pods：
flutter create --platforms=macos .
# 先备份并检查 diff，不要覆盖 Runner 的签名/entitlements 配置
```

构建后确认 `path_provider_foundation` 出现在
`macos/Flutter/GeneratedPluginRegistrant.swift`，否则模型/工作目录拿不到
`Application Support`。

### 5.3 部署目标与架构

- Xcode 工程 `MACOSX_DEPLOYMENT_TARGET = 12.0`（avox 是 12.0，低了链接警告/
  运行挂）。
- avox 的 macOS 构建默认 `arm64`。Flutter 默认出 universal
  （arm64 + x86_64）。建议先对齐 arm64：
  `flutter config --enable-macos-arm64-only`（或在 Xcode 里
  `EXCLUDED_ARCHS[sdk=macosx*] = x86_64`）。要 Intel 就 avox/shim/ffmpeg
  全部按 `x86_64` 或 `universal` 重编，别混。

### 5.4 沙盒与权限

`macos/Runner/*.entitlements` 目前只有 `app-sandbox`。直接分发（DMG）建议
**关掉沙盒**，否则“输出到源文件旁边 / 文件夹批量 / 挂载的 NAS 路径”会被
沙盒拦。若保留沙盒，至少补：

```xml
<key>com.apple.security.network.client</key><true/>          <!-- 模型下载 / URL 直链 -->
<key>com.apple.security.files.user-selected.read-write</key><true/>
<key>com.apple.security.files.bookmarks.app-scope</key><true/> <!-- 最近文件 -->
```

注意沙盒下 `file_selector` 选中的是“安全作用域”授权：选中文件夹才能写同目录
的 `-repaired` sidecar；跨目录输出要用户再选一次。

### 5.5 退出钩子

Windows runner 在 `OnDestroy` 里调 `ak_shutdown`，是为了停任务线程/日志线程，
避免退出竞态（2026-10-27 修过一次）。macOS 同样要加：在 `AppDelegate` 的
`applicationWillTerminate` 里 `dlopen`/`dlsym` 取 `ak_shutdown` 并调用，
或让 Dart 在 `AppLifecycleState.detached` 时调 `bindings.shutdown()`。
不做的话表现是偶发退出崩溃/残留线程，和 Windows 修之前一样。

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
│   ├── avoxkit                       # Flutter Runner
│   └── assets/glsl/                  # avox getAvoxPath() 找这里
├── Frameworks/
│   ├── avoxkit_native.dylib          # shim + libavox.a + libav*.a
│   ├── libMoltenVK.dylib
│   └── plugins/
│       ├── libavox_cv.dylib
│       ├── libavox_onnx.dylib
│       ├── libavox_opencv.dylib
│       ├── libavox_sherpa.dylib
│       └── libonnxruntime.1.23.2.dylib
└── Resources/
```

### 6.2 链接检查（换机必做）

```bash
APP=build/macos/Build/Products/Release/avoxkit.app
otool -L "$APP/Contents/Frameworks/avoxkit_native.dylib"
otool -L "$APP/Contents/Frameworks/plugins/libavox_onnx.dylib"
```

要求：只出现 `@rpath/`、`@loader_path/`、`/System/Library/`、
`/usr/lib/`。出现 `/opt/homebrew/...` 或 `/Users/<构建机>/...` 就是没打包
干净，换台机器必挂。修正：

```bash
install_name_tool -change /opt/homebrew/opt/lame/lib/libmp3lame.0.dylib \
  @rpath/libmp3lame.0.dylib "$APP/Contents/Frameworks/avoxkit_native.dylib"
```

（更稳的做法是 ffmpeg 静态链 lame/x264/x265，从源头避免。）

### 6.3 签名与公证

```bash
# 先内层后外层：每个 dylib 都要签，hardened runtime 才允许加载
codesign --force --options runtime --timestamp \
  --sign "Developer ID Application: ..." \
  "$APP/Contents/Frameworks/plugins/"*.dylib
codesign --force --options runtime --timestamp \
  --sign "Developer ID Application: ..." \
  "$APP/Contents/Frameworks/"*.dylib
codesign --force --options runtime --timestamp --entitlements macos/Runner/Release.entitlements \
  --sign "Developer ID Application: ..." "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

xcrun notarytool submit avoxkit.zip --keychain-profile avoxkit --wait
xcrun stapler staple "$APP"
```

本地开发可以 ad-hoc：`codesign --force --deep --sign - "$APP"`（不要用于分发）。

### 6.4 分发渠道与许可证

本仓 AGPL-3.0，ffmpeg 是 GPL + libmp3lame。**App Store 分发与 GPL 不兼容**
（VLC 先例），首版走 DMG/官网 + 公证。分发时随包提供对应源码（或书面
offer），不要把 GPL 组件塞进闭源壳。

## 7. 验收清单

在 Mac 上按 Windows 的顺序跑一遍，全部通过再谈“移植完成”。

### 7.1 无头

```bash
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

### 7.2 GUI

1. **从 Finder 双击启动**（不要从终端启动 —— 终端可能带 Homebrew PATH，
   把“没打包干净”的依赖藏起来，Windows 的 `libgcc` 事故就是这么漏的）。
2. 选视频转 MP4（H.264 + AAC）、提取 MP3、截取片段、抓缩略图。
3. 图像修复：自动识别 → 修复 → 再跑一次确认覆盖 `-repaired`；文件夹批量。
4. 退出应用，确认无崩溃、无残留进程（Activity Monitor）。

### 7.3 换机

拷到另一台 Mac（最好同架构、无开发环境）双击启动；`otool -L` 和
`codesign --verify` 在打包机先过一遍。

## 8. 坑位对照表

| 现象 | 原因 | 处理 |
|---|---|---|
| 插件全部缺失 / `image_inpaint=0` | shim 以 RTLD_LOCAL 载入，插件 `dynamic_lookup` 找不到 avox 符号 | Runner 先 `dlopen(RTLD_GLOBAL)`；`nm -gU` 确认符号导出 |
| `dlopen` 插件报 `symbol not found` | 同上；或 avox 侧漏了 `AVOX_EXPORT` | 在 avox 补导出，不要 fork 核心 |
| `createWatermarkRemoval` 链接失败 | avox 头/库没有该导出（工作区改动未提交） | 在 avox 提交并重编，同步 install 头 |
| MP3 出声失败 / `ak_init` 报 ffmpeg mismatch | ffmpeg 没有 `--enable-libmp3lame` | 按 §2.1 重建 GPL kit，`has_libmp3lame=true` |
| 缩略图/修复保存失败（`encode_failed`） | kit 缺 `mjpeg`/`png` 编码器或 `tga` 解码器 | configure 补 `--enable-encoder=mjpeg,png`、`--enable-decoder=targa` |
| 转码静默丢帧、预览全黑 | 没拷 `assets/glsl` | 放到 `Contents/MacOS/assets/glsl` |
| 换机后插件加载失败 | 插件依赖 `/opt/homebrew` 或构建机绝对路径 dylib | `otool -L` 检查，`install_name_tool` 改 `@rpath`，或静态链 |
| Intel Mac 启动即崩/找不到镜像 | app universal 但 dylib 只有 arm64 | 全部按同一架构构建，或 `--enable-macos-arm64-only` |
| 打开文件/输出失败 | 沙盒未授权 | 补 `files.user-selected.read-write`，或关沙盒走 DMG |
| 模型下载失败 | 沙盒缺 `network.client` | 补 entitlement |
| 退出偶发崩溃 | 没调 `ak_shutdown` | AppDelegate 终止钩子 |
| `flutter build macos` 缺 Podfile/Pods | Windows 上生成的脚手架不完整 | `flutter create --platforms=macos .` 后检查 diff |

## 9. 移植待办（按顺序）

1. avox：提交 `createWatermarkRemoval()` 导出；补静态消费者 CMake 导出
   （或记录 playtest 链接清单）。
2. 库仓：按 §2 准备 darwin ffmpeg/onnxruntime/opencv，装 Vulkan SDK。
3. avox：`python3 build_mac.py --flavor=agpl`，按 §3 检查产物。
4. shim：加 Apple CMake 分支，静态链 avox + 单份 ffmpeg，出
   `avoxkit_native.dylib`。
5. Flutter：dylib 路径、entitlements、arm64-only、`ak_shutdown` 钩子、
   `RTLD_GLOBAL` 预加载。
6. 打包：目录布局、`otool`/`codesign` 验收、公证。
7. 二期：NSView/Metal 原生预览；如果要做 Intel，统一 universal 构建。
