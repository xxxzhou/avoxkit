#!/usr/bin/env bash
# avoxkit 出厂 ffmpeg 构建 (macOS, 静态, LGPL + libmp3lame)
#
# 与 Windows `script/ffmpeg/build_ffmpeg.py` 同一口径:
#   1. 产物只落本仓 `third_party/ffmpeg/kit-macos`, 不写 avox 3rdparty, 不碰 avox 仓;
#   2. 上游版本必须与 avox darwin 3rdparty 一致 (当前 n9.0.1), 只改 configure;
#   3. macOS 下 avox 是静态库, 替换发生在最终链接: `libavox.a` 对 av_* 只有
#      未定义引用, shim 链本 kit 的 `.a` 即顶替 avox 那份 LGPL 构建。
#      所以 avox 的 ffmpeg 版本和目录都不动 (docs/macos-porting.md §2.1/§4.2)。
#
# 依赖 (静态库):
#   lame; 可选 dav1d (AV1 软解)。
#   lame 若带 mpglib 解码会引用 mpg123_*, 此时还需要 libmpg123.a
#   (源码构建 lame 加 --disable-decoder 可去掉)。
#   推荐 prefix 到 $HOME/avoxkit-deps, 再:
#     DEPS_PREFIX=$HOME/avoxkit-deps script/ffmpeg/build_ffmpeg_macos.sh
#   Homebrew 只有 dylib 时不要用: 会把 /opt/homebrew 路径带进产物, 换机必挂。
#
# 用法:
#   script/ffmpeg/build_ffmpeg_macos.sh
#   script/ffmpeg/build_ffmpeg_macos.sh --check-version
#   script/ffmpeg/build_ffmpeg_macos.sh --check-deps
#   script/ffmpeg/build_ffmpeg_macos.sh --verify third_party/ffmpeg/kit-macos/lib

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
SRC_DIR=${FFMPEG_SRC:-"$REPO_ROOT/../ffmpeg"}
AVOX_FFMPEG_INC=${AVOX_FFMPEG_INC:-"$REPO_ROOT/../avox/3rdparty/library/darwin/ffmpeg/include"}
PREFIX=${PREFIX:-"$REPO_ROOT/third_party/ffmpeg/kit-macos"}
DAV1D_PREFIX=${DAV1D_PREFIX:-"$SRC_DIR/../dav1d/out-macos"}
DEPS_PREFIX=${DEPS_PREFIX:-}
JOBS=${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 4)}

NONFREE_MARKS="--enable-nonfree|--enable-libfdk-aac"

die() {
  echo "❌ $*" >&2
  exit 2
}

info() {
  echo "== $* =="
}

avox_ffmpeg_version() {
  local header="$AVOX_FFMPEG_INC/libavutil/ffversion.h"
  [ -f "$header" ] || return 1
  awk -F'"' '/FFMPEG_VERSION/ {print $2}' "$header" | sed 's/^n//'
}

source_ffmpeg_version() {
  if [ -f "$SRC_DIR/RELEASE" ]; then
    tr -d '[:space:]' < "$SRC_DIR/RELEASE"
    return 0
  fi
  [ -f "$SRC_DIR/libavutil/ffversion.h" ] || return 1
  awk -F'"' '/FFMPEG_VERSION/ {print $2}' "$SRC_DIR/libavutil/ffversion.h" | sed 's/^n//'
}

check_version() {
  local expected actual
  expected=$(avox_ffmpeg_version) || die "找不到 avox ffmpeg 头: $AVOX_FFMPEG_INC"
  actual=$(source_ffmpeg_version) || die "找不到 ffmpeg 源码版本: $SRC_DIR/RELEASE"
  echo "avox 3rdparty: n$expected"
  echo "ffmpeg 源码:   $actual"
  if [ "$expected" != "$actual" ]; then
    die "版本不一致。不要换 avox 版本, 请把 FFMPEG_SRC 指到 $expected 的源码树"
  fi
  echo "✅ 同版本, 可以链接"
}

setup_deps_env() {
  if [ -n "$DEPS_PREFIX" ]; then
    export PKG_CONFIG_PATH="$DEPS_PREFIX/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
    export CFLAGS="${CFLAGS:-} -I$DEPS_PREFIX/include"
    export LDFLAGS="${LDFLAGS:-} -L$DEPS_PREFIX/lib"
  fi
  # configure_args 在子 shell 里跑, 这里必须先把 dav1d 的 .pc 路径挂上
  local dav1d
  if dav1d=$(dav1d_lib); then
    if [ -d "$(dirname "$dav1d")/pkgconfig" ]; then
      export PKG_CONFIG_PATH="$(dirname "$dav1d")/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
    fi
  fi
}

static_lib_for() {
  local pkg=$1 name=$2 dir
  if pkg-config --exists "$pkg" 2>/dev/null; then
    dir=$(pkg-config --variable=libdir "$pkg")
    if [ -f "$dir/$name" ]; then
      echo "$dir/$name"
      return 0
    fi
  fi
  if [ -n "$DEPS_PREFIX" ] && [ -f "$DEPS_PREFIX/lib/$name" ]; then
    echo "$DEPS_PREFIX/lib/$name"
    return 0
  fi
  return 1
}

lame_lib() {
  static_lib_for lame libmp3lame.a
}

# Homebrew/lame 4.x 的静态库带 mpglib 解码时会引用 mpg123_*;
# 源码构建加 --disable-decoder 可去掉, 否则必须一起链 libmpg123.a。
lame_needs_mpg123() {
  local lib
  lib=$(lame_lib) || return 1
  (set +o pipefail; nm -u "$lib" 2>/dev/null | grep -q '^_mpg123_')
}

mpg123_lib() {
  static_lib_for libmpg123 libmpg123.a || static_lib_for mpg123 libmpg123.a
}

dav1d_lib() {
  if [ -f "$DAV1D_PREFIX/lib/libdav1d.a" ]; then
    echo "$DAV1D_PREFIX/lib/libdav1d.a"
    return 0
  fi
  static_lib_for dav1d libdav1d.a
}

check_deps() {
  local missing=0
  echo "ffmpeg 源码: $SRC_DIR"
  [ -f "$SRC_DIR/configure" ] && echo "  ✅ configure" || { echo "  ❌ 缺 configure"; missing=1; }
  command -v xcrun >/dev/null && echo "  ✅ xcrun" || { echo "  ❌ 缺 Xcode Command Line Tools"; missing=1; }
  command -v pkg-config >/dev/null && echo "  ✅ pkg-config" || { echo "  ❌ 缺 pkg-config"; missing=1; }
  command -v make >/dev/null && echo "  ✅ make" || { echo "  ❌ 缺 make"; missing=1; }
  [ -n "$DEPS_PREFIX" ] && echo "DEPS_PREFIX: $DEPS_PREFIX"

  local lib pkg name
  for item in "lame:libmp3lame.a"; do
    pkg=${item%%:*}
    name=${item##*:}
    if lib=$(static_lib_for "$pkg" "$name"); then
      echo "  ✅ $name ($lib)"
    else
      echo "  ❌ $name (只认静态库; dylib 不算)"
      missing=1
    fi
  done
  if lame_needs_mpg123; then
    if lib=$(mpg123_lib); then
      echo "  ✅ libmpg123.a ($lib, lame 的解码依赖)"
    else
      echo "  ❌ libmpg123.a (lame 静态库引用 mpg123_*, 但没找到静态库)"
      missing=1
    fi
  fi
  if lib=$(dav1d_lib); then
    echo "  ✅ libdav1d.a ($lib)"
  else
    echo "  ⚠️  libdav1d.a 缺席: AV1 只能硬解, 与 avox Apple 脚本行为一致"
  fi
  if [ "$missing" -ne 0 ]; then
    cat <<'EOF'

缺少静态依赖。优先用源码 prefix 到 $HOME/avoxkit-deps:
  lame 3.100 ./configure --prefix=$HOME/avoxkit-deps --enable-static --disable-shared
  (lame: --disable-frontend --disable-decoder)
  lame 若带 mpglib 解码, 还要提供 libmpg123.a, 否则链最终产物会报 mpg123_* 未定义。
然后:
  DEPS_PREFIX=$HOME/avoxkit-deps script/ffmpeg/build_ffmpeg_macos.sh
不要用 Homebrew 的 dylib 版, 否则产物会把 /opt/homebrew 路径带进最终二进制。
EOF
    return 1
  fi
  echo "✅ 静态依赖齐全"
}

configure_args() {
  # 白名单 = avox Apple minsize 名单 + avoxkit 增量。
  # 增量: libmp3lame、mjpeg/png 编码器、targa 解码器、
  # mp3/wav/ipod muxer (m4a 只含音轨时按扩展名选 muxer)。
  local decoders="h264,hevc,dovi_rpudec,aac,mp3,opus,ac3,pcm_alaw,pcm_mulaw,pcm_s16le,pcm_s24le,mpeg1video,mpeg2video,mpeg4,h263,flv,wmv1,wmv2,wmv3,vc1,rv10,rv20,rv30,rv40,cook,sipr,atrac3,wmav1,wmav2,wmapro,pcm_s16be,vp8,vp9,av1,theora,mjpeg,mjpegb,dvvideo,prores,msmpeg4v1,msmpeg4v2,msmpeg4v3,vorbis,flac,dca,eac3,mp2,amrnb,amrwb,adpcm_ms,adpcm_ima_wav,adpcm_g726,adpcm_g726le,alac,ape,aac_latm,pcm_dvd,pcm_bluray,dsd_lsbf,dsd_msbf,mlp,truehd,pgssub,movtext,ass,ssa,subrip,srt,webvtt,dvbsub,dvdsub,text,h261,h263i,h263p,vp6,vp6a,vp6f,svq1,svq3,cinepak,indeo3,indeo4,indeo5,qtrle,rpza,smc,cscd,tscc,tscc2,truemotion1,truemotion2,fraps,utvideo,lagarith,hap,magicyuv,ffv1,huffyuv,ffvhuff,msrle,msvideo1,mszh,zmbv,flashsv,flashsv2,dnxhd,cfhd,cllc,hq_hqa,hqx,cavs,avs,vvc,rawvideo,bitpacked,v210,v210x,yuv4,png,apng,gif,webp,bmp,targa,mp1,gsm,gsm_ms,nellymoser,speex,ilbc,wavpack,tta,shorten,tak,als,mpc7,mpc8,qdm2,qdmc,on2avc,imc,mace3,mace6,twinvq,truespeech,atrac1,atrac3p,atrac9,dss_sp,wmavoice,wmalossless,xma1,xma2,evrc,qcelp,g728,g729,mp3on4,siren,comfortnoise,aptx,aptx_hd,sbc,s302m,dolby_e"
  local demuxers="mov,matroska,flv,live_flv,mpegts,hls,avi,asf,aac,mp3,ogg,wav,rtsp,sdp,ac3,rm,mpegps,mpegvideo,flac,ape,amr,dsf,srt,ass,webvtt,microdvd,sami,subviewer,subviewer1,realtext,pjs,mpl2,jacosub,vplayer,stl,vobsub,sup,aiff,caf,w64,au,tta,wv,shorten,tak,mpc,mpc8,dts,eac3,xwma,ivf,swf,image2,image2pipe,rawvideo,concat"
  local parsers="h264,hevc,aac,opus,ac3,mpegaudio,mpegvideo,mpeg4video,vc1,vp8,vp9,av1,vorbis,flac,dca,aac_latm,amr,mjpeg"

  local -a args=(
    --prefix="$PREFIX"
    --enable-static --disable-shared --enable-pic
    --disable-autodetect
    --disable-programs --disable-doc --disable-avdevice --disable-avfilter --disable-swscale
    --disable-iconv --disable-lzma --disable-bzlib --disable-sdl2 --disable-x86asm
    --disable-everything
    --disable-gpl
    --enable-libmp3lame
    --enable-videotoolbox --enable-securetransport --enable-zlib
    --enable-hwaccel=h264_videotoolbox
    --enable-hwaccel=hevc_videotoolbox
    --enable-hwaccel=vp9_videotoolbox
    --enable-hwaccel=av1_videotoolbox
    --pkg-config-flags=--static
    --enable-protocol=file,http,https,tcp,udp,rtp,rtmp,rtmps,tls,srtp,crypto,data,pipe,httpproxy
    --enable-demuxer="$demuxers"
    --enable-muxer=mp4,mov,flv,mpegts,matroska,adts,mp3,wav,ipod
    --enable-decoder="$decoders"
    --enable-encoder=h264_videotoolbox,hevc_videotoolbox,aac,libmp3lame,mjpeg,png
    --enable-parser="$parsers"
    --enable-bsf=h264_mp4toannexb,hevc_mp4toannexb,aac_adtstoasc,extract_extradata
  )

  local extra_cflags=""
  local extra_ldflags=""
  local dav1d
  if dav1d=$(dav1d_lib); then
    args+=(--enable-libdav1d)
    extra_cflags="-I$(dirname "$(dirname "$dav1d")")/include"
    extra_ldflags="-L$(dirname "$dav1d")"
    # decoder 列表里加 libdav1d
    local i
    for i in "${!args[@]}"; do
      case "${args[$i]}" in
        --enable-decoder=*) args[$i]="${args[$i]},libdav1d" ;;
      esac
    done
  fi

  if [ -n "$DEPS_PREFIX" ]; then
    extra_cflags="${extra_cflags:+$extra_cflags }-I$DEPS_PREFIX/include"
    extra_ldflags="${extra_ldflags:+$extra_ldflags }-L$DEPS_PREFIX/lib"
  fi
  [ -n "$extra_cflags" ] && args+=(--extra-cflags="$extra_cflags")
  [ -n "$extra_ldflags" ] && args+=(--extra-ldflags="$extra_ldflags")

  printf '%s\n' "${args[@]}"
}

copy_static_dep() {
  local lib=$1 dest
  [ -f "$lib" ] || return 0
  dest="$PREFIX/lib/$(basename "$lib")"
  [ "$lib" = "$dest" ] && return 0
  cp -f "$lib" "$dest"
  echo "dep+ $(basename "$lib")"
}

collect_deps() {
  info "收集静态依赖到 $PREFIX/lib"
  # LGPL 渠道: 清掉历史 GPL 软编静态库, 防止最终链接误带 x264/x265
  rm -f "$PREFIX/lib/libx264.a" "$PREFIX/lib/libx265.a"
  local lib
  lib=$(lame_lib 2>/dev/null || true); [ -n "$lib" ] && copy_static_dep "$lib"
  if lame_needs_mpg123; then
    lib=$(mpg123_lib 2>/dev/null || true); [ -n "$lib" ] && copy_static_dep "$lib"
  fi
  lib=$(dav1d_lib 2>/dev/null || true); [ -n "$lib" ] && copy_static_dep "$lib"
  if [ -n "$(find "$PREFIX" -name '*.dylib' -print -quit)" ]; then
    die "kit 里出现 dylib, 会带出构建机路径: $PREFIX"
  fi
}

need_symbol() {
  local lib=$1 sym=$2
  # grep -q 提前退出会让 nm 收到 SIGPIPE; pipefail 下必须局部关掉
  if ! (set +o pipefail; nm "$lib" 2>/dev/null | grep -q "[[:space:]]_${sym}$"); then
    die "$(basename "$lib") 缺符号 $sym"
  fi
}

link_kit_probe() {
  command -v clang >/dev/null || die "缺 clang, 无法做静态链接自检"
  local lib_dir=${1:-"$PREFIX/lib"}
  local include_dir
  include_dir=$(cd "$lib_dir/../include" && pwd)
  local tmp
  tmp=$(mktemp -d)
  local -a libs=(
    "$lib_dir/libavformat.a"
    "$lib_dir/libavcodec.a"
    "$lib_dir/libswresample.a"
    "$lib_dir/libavutil.a"
  )
  local f
  for f in libdav1d.a libmp3lame.a libmpg123.a; do
    [ -f "$lib_dir/$f" ] && libs+=("$lib_dir/$f")
  done
  local -a frameworks=(
    -framework VideoToolbox
    -framework CoreMedia
    -framework CoreVideo
    -framework AudioToolbox
    -framework Security
    -framework CoreFoundation
    -framework CoreServices
    -framework IOKit
  )
  if ! clang -I"$include_dir" "$SCRIPT_DIR/kit_probe.c" \
      "${libs[@]}" "${frameworks[@]}" \
      -lz -lc++ -lm -lpthread -ldl -o "$tmp/kit_probe" >"$tmp/build.log" 2>&1; then
    cat "$tmp/build.log" >&2
    rm -rf "$tmp"
    die "kit 静态链接失败 (常见原因: lame 的 mpg123_* 未解析)"
  fi
  if ! "$tmp/kit_probe" >"$tmp/run.log" 2>&1; then
    cat "$tmp/run.log" >&2
    rm -rf "$tmp"
    die "kit 运行时组件自检失败"
  fi
  sed 's/^/  /' "$tmp/run.log"
  rm -rf "$tmp"
  info "静态链接 + 组件自检通过"
}

verify_prefix() {
  local dir=${1:-"$PREFIX/lib"}
  local avcodec="$dir/libavcodec.a"
  local avformat="$dir/libavformat.a"
  local version_header="$dir/../include/libavutil/ffversion.h"

  [ -f "$avcodec" ] || die "找不到 $avcodec"
  [ -f "$avformat" ] || die "找不到 $avformat"

  local expected actual
  expected=$(avox_ffmpeg_version) || die "找不到 avox ffmpeg 头"
  actual=$(awk -F'"' '/FFMPEG_VERSION/ {print $2}' "$version_header" | sed 's/^n//')
  [ "$expected" = "$actual" ] || die "产物版本 n$actual, avox 是 n$expected"

  local f
  for f in "$dir"/*.a; do
    # 直接扫二进制; 不要用 strings | grep -q (grep 提前退出会触发 SIGPIPE)
    if grep -a -qE -- "$NONFREE_MARKS" "$f"; then
      die "$(basename "$f") 含 nonfree/fdk-aac, 任何渠道不可分发"
    fi
  done
  info "nonfree 检查通过"

  grep -a -q -- "--disable-gpl" "$avcodec" || die "libavcodec.a 缺 --disable-gpl"
  grep -a -q -- "--enable-libmp3lame" "$avcodec" || die "libavcodec.a 缺 --enable-libmp3lame"
  if grep -a -qE -- "--enable-gpl|--enable-libx264|--enable-libx265" "$avcodec"; then
    die "libavcodec.a 含 GPL/x264/x265 标记, 不是 LGPL 渠道"
  fi
  info "LGPL configure 标记通过"

  need_symbol "$avcodec" ff_libmp3lame_encoder
  need_symbol "$avcodec" ff_mjpeg_encoder
  need_symbol "$avcodec" ff_png_encoder
  need_symbol "$avcodec" ff_targa_decoder
  need_symbol "$avcodec" ff_h264_videotoolbox_encoder
  need_symbol "$avcodec" ff_hevc_videotoolbox_encoder
  need_symbol "$avformat" ff_mp3_muxer
  need_symbol "$avformat" ff_wav_muxer
  need_symbol "$avformat" ff_ipod_muxer
  info "必需编解码器/muxer 符号通过"

  link_kit_probe "$dir"
  echo "✅ kit 校验通过: n$actual, $dir"
}

main() {
  case "${1:-}" in
    --check-version) check_version; return ;;
    --check-deps) setup_deps_env; check_deps; return ;;
    --verify) verify_prefix "${2:-$PREFIX/lib}"; return ;;
  esac

  [ -f "$SRC_DIR/configure" ] || die "ffmpeg 源码树不对: $SRC_DIR"
  check_version
  setup_deps_env
  check_deps
  info "构建 kit -> $PREFIX"
  # macOS 自带 bash 3.2 没有 mapfile, 用 while-read 兼容
  CONFIGURE_ARGS=()
  while IFS= read -r line; do
    CONFIGURE_ARGS+=("$line")
  done < <(configure_args)
  # 出树构建, 不在 ffmpeg 源码仓写构建产物
  BUILD_DIR=${BUILD_DIR:-"$REPO_ROOT/third_party/ffmpeg/build-macos-kit"}
  mkdir -p "$BUILD_DIR"
  cd "$BUILD_DIR"
  if ! "$SRC_DIR/configure" "${CONFIGURE_ARGS[@]}"; then
    echo "⚠️  configure 失败, 去掉 --enable-securetransport 重试"
    local -a retry=()
    local a
    for a in "${CONFIGURE_ARGS[@]}"; do
      [ "$a" = "--enable-securetransport" ] || retry+=("$a")
    done
    "$SRC_DIR/configure" "${retry[@]}"
  fi
  make -j"$JOBS"
  make install
  rm -f "$PREFIX/COPYING.GPLv3"
  for f in COPYING.LGPLv2.1 COPYING.LGPLv3; do
    [ -f "$SRC_DIR/$f" ] && cp -f "$SRC_DIR/$f" "$PREFIX/$f"
  done
  collect_deps
  verify_prefix "$PREFIX/lib"
}

main "$@"
