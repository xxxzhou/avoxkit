#!/usr/bin/env bash
# avoxkit macOS 打包: ffmpeg kit 校验 -> shim -> Flutter -> app bundle -> dist zip
#
# 依赖见 docs/macos-porting.md: avox 先按 --flavor=commercial 构建, kit 由
# script/ffmpeg/build_ffmpeg_macos.sh 产出（LGPL, 无 GPL 软编）。产物是 arm64、部署目标 12.0。
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DIST=${DIST:-"$ROOT/dist/avoxkit-macos-arm64"}
AVOX_ROOT=${AVOX_ROOT:-"$ROOT/../avox"}
AVOX_OUT_DIR=${AVOX_OUT_DIR:-"$AVOX_ROOT/build/macos/avox/install/aarch64/Release"}
AVOX_LIBRARY=${AVOX_LIBRARY:-"$AVOX_ROOT/../avox_library"}
ONNX_DYLIB=${ONNX_DYLIB:-"$AVOX_LIBRARY/3rdparty/library/darwin/onnxruntime/lib/libonnxruntime.1.23.2.dylib"}
KIT_DIR="$ROOT/third_party/ffmpeg/kit-macos"
APP="$ROOT/build/macos/Build/Products/Release/avoxkit.app"
SKIP_KIT_VERIFY=${SKIP_KIT_VERIFY:-0}
# 默认用 avoxkit-dev 自签证书: ad-hoc 每次重建 cdhash 都变, TCC 屏幕录制/
# 麦克风授权随即失效; 自签固定证书的 designated requirement 跨重建不变。
CODESIGN_IDENTITY=${CODESIGN_IDENTITY:-}
if [ -z "$CODESIGN_IDENTITY" ]; then
  if security find-identity -v -p codesigning 2>/dev/null |
      grep -q '"avoxkit-dev"'; then
    CODESIGN_IDENTITY="avoxkit-dev"
  else
    CODESIGN_IDENTITY="-"
  fi
fi

die() {
  echo "❌ $*" >&2
  exit 1
}

if [ -z "${FLUTTER:-}" ]; then
  if command -v flutter >/dev/null 2>&1; then
    FLUTTER=$(command -v flutter)
  elif [ -x "$HOME/development/flutter/bin/flutter" ]; then
    FLUTTER="$HOME/development/flutter/bin/flutter"
  else
    die "找不到 flutter; 用 FLUTTER=<path> 指定"
  fi
fi

[ -f "$AVOX_OUT_DIR/libavox.a" ] || die "avox 未构建: $AVOX_OUT_DIR/libavox.a"
[ -f "$KIT_DIR/lib/libavcodec.a" ] || die "ffmpeg kit 未构建: 先跑 script/ffmpeg/build_ffmpeg_macos.sh"

if [ "$SKIP_KIT_VERIFY" != "1" ]; then
  "$ROOT/script/ffmpeg/build_ffmpeg_macos.sh" --verify "$KIT_DIR/lib"
fi

cmake -S "$ROOT/native/avtool" -B "$ROOT/native/avtool/build" -DCMAKE_BUILD_TYPE=Release
cmake --build "$ROOT/native/avtool/build" --config Release --parallel "$(sysctl -n hw.ncpu)"

cd "$ROOT"
"$FLUTTER" pub get

# 增量缓存会留着旧的 icon tree-shake 子集: 源码比字体新就清掉, 否则图标缺字
ICON_FONT="$ROOT/build/flutter_assets/fonts/MaterialIcons-Regular.otf"
NEWEST_DART=$(find "$ROOT/lib" -name '*.dart' -newer "$ICON_FONT" -print -quit 2>/dev/null || true)
if [ ! -f "$ICON_FONT" ] || [ -n "$NEWEST_DART" ]; then
  rm -rf "$ROOT/.dart_tool/flutter_build" "$ROOT/build/flutter_assets"
fi

"$FLUTTER" build macos --release
[ -d "$APP" ] || die "Flutter 产物不存在: $APP"

STAGING="$DIST.staging-$$"
rm -rf "$STAGING"
mkdir -p "$STAGING"
ditto "$APP" "$STAGING/avoxkit.app"
STAGED_APP="$STAGING/avoxkit.app"

mkdir -p "$STAGED_APP/Contents/Frameworks/plugins" \
         "$STAGED_APP/Contents/Resources/glsl"
# macOS 走 getShaderPath(): Resources/glsl 或 Resources/avox.bundle/glsl;
# assets/ 前缀只有 Windows/Linux 分支认, 摆错会静默禁用 compute 层(录屏全绿)
# 旧包可能回灌进 Flutter 产物(SYNC_BUILD_APP), 这里清掉历史摆法
rm -rf "$STAGED_APP/Contents/Resources/assets" "$STAGED_APP/Contents/MacOS/assets"
cp -f "$ROOT/native/avtool/build/bin/avoxkit_native.dylib" \
      "$STAGED_APP/Contents/Frameworks/"
# volk 按 libvulkan.1.dylib 找 loader; MoltenVK 直接充当 loader
cp -f "$ROOT/native/avtool/build/bin/libvulkan.1.dylib" \
      "$STAGED_APP/Contents/Frameworks/"
install_name_tool -id "@rpath/libvulkan.1.dylib" \
      "$STAGED_APP/Contents/Frameworks/libvulkan.1.dylib"
for name in libavox_sherpa.dylib libavox_cv.dylib libavox_onnx.dylib \
            libavox_opencv.dylib; do
  [ -f "$AVOX_OUT_DIR/plugins/$name" ] || die "avox 插件缺失: $name"
  cp -f "$AVOX_OUT_DIR/plugins/$name" "$STAGED_APP/Contents/Frameworks/plugins/"
done
[ -f "$ONNX_DYLIB" ] || die "onnxruntime 缺失: $ONNX_DYLIB"
cp -f "$ONNX_DYLIB" "$STAGED_APP/Contents/Frameworks/plugins/"
cp -f "$AVOX_ROOT"/glsl/target/*.spv "$STAGED_APP/Contents/Resources/glsl/"
# AGPL/GPL 分发合规: 许可与源码获取说明随包走
cp -f "$ROOT/LICENSE" "$STAGED_APP/Contents/Resources/LICENSE.txt"
cp -f "$ROOT/THIRD_PARTY_NOTICES.md" "$STAGED_APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
cp -f "$ROOT/SOURCE-OFFER.md" "$STAGED_APP/Contents/Resources/SOURCE-OFFER.md"

# 先内层后外层; 自签/- 不能开 hardened runtime: 没有 Team ID, 库校验会拒绝
# 加载 Flutter framework 与插件 dylib。公证分发(Developer ID)才开 runtime。
SIGN_FLAGS=(--timestamp=none)
if [[ "$CODESIGN_IDENTITY" == Developer\ ID\ Application:* ]]; then
  SIGN_FLAGS=(--options runtime --timestamp)
fi
find "$STAGED_APP/Contents/Frameworks" -name '*.dylib' -print0 |
  while IFS= read -r -d '' lib; do
    codesign --force "${SIGN_FLAGS[@]}" \
      --sign "$CODESIGN_IDENTITY" "$lib"
  done
# 公证要求嵌套 framework 也用同一身份签; 只签 dylib 会漏掉
# FlutterMacOS/App/file_selector/objective_c, 公证会直接失败。
find "$STAGED_APP/Contents/Frameworks" -name '*.framework' -type d -print0 |
  while IFS= read -r -d '' fw; do
    codesign --force "${SIGN_FLAGS[@]}" \
      --sign "$CODESIGN_IDENTITY" "$fw"
  done
codesign --force "${SIGN_FLAGS[@]}" \
  --entitlements "$ROOT/macos/Runner/Release.entitlements" \
  --sign "$CODESIGN_IDENTITY" "$STAGED_APP"
codesign --verify --deep --strict "$STAGED_APP"

REQUIRED=(
  "Contents/MacOS/avoxkit"
  "Contents/Frameworks/avoxkit_native.dylib"
  "Contents/Frameworks/libvulkan.1.dylib"
  "Contents/Frameworks/plugins/libavox_sherpa.dylib"
  "Contents/Frameworks/plugins/libavox_cv.dylib"
  "Contents/Frameworks/plugins/libavox_onnx.dylib"
  "Contents/Frameworks/plugins/libavox_opencv.dylib"
  "Contents/Frameworks/plugins/libonnxruntime.1.23.2.dylib"
  "Contents/Resources/glsl/scene.comp.spv"
)
for name in "${REQUIRED[@]}"; do
  [ -f "$STAGED_APP/$name" ] || die "包内缺少 $name"
done

# 换机验收: 只允许系统库和 @rpath/@loader_path, 不能带构建机路径
for bin in "$STAGED_APP/Contents/Frameworks/avoxkit_native.dylib" \
           "$STAGED_APP/Contents/Frameworks/libvulkan.1.dylib" \
           "$STAGED_APP/Contents/Frameworks/plugins/"*.dylib; do
  bad=$(otool -L "$bin" | tail -n +2 | awk '{print $1}' |
        grep -Ev '^(@rpath/|@loader_path/|/System/Library/|/usr/lib/)' || true)
  [ -z "$bad" ] || die "$(basename "$bin") 带非系统依赖:\n$bad"
done

[ "$(lipo -archs "$STAGED_APP/Contents/Frameworks/avoxkit_native.dylib")" = "arm64" ] ||
  die "shim 不是 arm64"

rm -rf "$DIST"
mv "$STAGING" "$DIST"
# Flutter 中间产物缺插件/资源, 直接双击会报"无法加载原生模块"; 同步完整包
if [ "${SYNC_BUILD_APP:-1}" = "1" ]; then
  rm -rf "$APP"
  ditto "$DIST/avoxkit.app" "$APP"
fi
ZIP="$DIST.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$DIST/avoxkit.app" "$ZIP"

echo
echo "app:  $DIST/avoxkit.app"
echo "zip:  $ZIP"
