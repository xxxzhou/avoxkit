# avoxkit 出厂 ffmpeg 构建脚本 (Windows/MSYS2)
#
# 改自 avox `script/ffmpeg/build_ffmpeg.py`(同源 AGPL)。与 avox 版的差异:
#   1. 产物落本仓 third_party/ffmpeg/<flavor>, 不写 avox 3rdparty, 不碰 avox 仓;
#   2. 编码器白名单加 libmp3lame, muxer 加 mp3/wav (avox 缺口#1, 架构文档 §5);
#   3. --verify 只扫 nonfree 标记 —— gpl 是本仓合法渠道(AGPL-3.0),
#      但含 nonfree/fdk-aac 的产物任何渠道不可分发 (AGENTS.md 红线)。
#
# flavor:
#   kit  出厂默认: avox minsize 白名单 + gpl(x264/x265) + libmp3lame
#   gpl  全量 gpl + libmp3lame (排查兼容性用, 体积大)
#
# 白名单沿用 avox 踩坑结论, 勿凭记忆改组件名:
#   解码器名是 flv 不是 flv1; parser 无 mp3(走 mpegaudio); demuxer 是 mpegps
#   不是 mpeg; 各 --enable-xxx= 段拼接的字符串末尾必须带逗号。
#   深坑清单见 avox 脚本文件头注释。
#
# 依赖 (MSYS2 mingw64, 缺则先装, 可用 --check-deps 自检):
#   C:/msys64/usr/bin/pacman.exe -S --needed mingw-w64-x86_64-libx264 \
#       mingw-w64-x86_64-x265 mingw-w64-x86_64-lame mingw-w64-x86_64-vulkan-headers
#   (lame 包提供 libmp3lame; 没有名为 libmp3lame 的包; x264 元包勿装)
#
# 环境变量: MSYS2_INSTALL_DIR(默认 C:\msys64), FFMPEG_SRC(源码树, 默认仓旁 ../ffmpeg)
#
# 用法:
#   python script/ffmpeg/build_ffmpeg.py                       # kit flavor
#   python script/ffmpeg/build_ffmpeg.py --flavor gpl
#   python script/ffmpeg/build_ffmpeg.py --check-deps
#   python script/ffmpeg/build_ffmpeg.py --verify third_party/ffmpeg/kit/bin

import argparse
import glob
import os
import shutil
import subprocess
import sys

MSYS2_INSTALL_DIR = os.environ.get("MSYS2_INSTALL_DIR", "C:\\msys64")
AVOXKIT_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DEFAULT_SRC = os.environ.get("FFMPEG_SRC") or os.path.join(
    os.path.dirname(AVOXKIT_ROOT), "ffmpeg")
bash_path = os.path.join(MSYS2_INSTALL_DIR, "usr", "bin", "bash.exe")
objdump_path = os.path.join(MSYS2_INSTALL_DIR, "mingw64", "bin", "objdump.exe")

NONFREE_MARKS = (b"--enable-nonfree", b"--enable-libfdk-aac")

COMMON_OPTIONS = [
    "--disable-static",
    "--enable-shared",
    "--enable-version3",
    "--disable-programs",
    "--disable-doc",
    "--disable-avdevice",
    "--disable-avfilter",
    "--disable-swscale",
    "--disable-iconv",
    "--disable-lzma",
    "--disable-bzlib",
    "--disable-sdl2",
    "--disable-x86asm",        # 免装 nasm
    "--enable-zlib",
    "--enable-schannel",
    "--enable-vulkan",
]

# ---- kit 白名单 (avox minsize 名单 + 本仓增量) ----
KIT_DECODERS = ("h264,hevc,aac,mp3,opus,ac3,pcm_alaw,pcm_mulaw,pcm_s16le,pcm_s24le,"
                "mpeg1video,mpeg2video,mpeg4,h263,flv,"
                "wmv1,wmv2,wmv3,vc1,"
                "rv10,rv20,rv30,rv40,"
                "cook,sipr,atrac3,"
                "wmav1,wmav2,wmapro,"
                "pcm_s16be,"
                "vp8,vp9,av1,theora,mjpeg,mjpegb,dvvideo,prores,"
                "msmpeg4v1,msmpeg4v2,msmpeg4v3,"
                "vorbis,flac,dca,eac3,mp2,amrnb,amrwb,"
                "mlp,truehd,"
                "adpcm_ms,adpcm_ima_wav,adpcm_g726,adpcm_g726le,"
                "alac,ape,aac_latm,"
                "pcm_dvd,pcm_bluray,dsd_lsbf,dsd_msbf,"
                "pgssub,"
                "movtext,ass,ssa,subrip,srt,webvtt,dvbsub,dvdsub,text,"
                "h261,h263i,h263p,vp6,vp6a,vp6f,svq1,svq3,"
                "cinepak,indeo3,indeo4,indeo5,qtrle,rpza,smc,"
                "cscd,tscc,tscc2,truemotion1,truemotion2,"
                "fraps,utvideo,lagarith,hap,magicyuv,ffv1,huffyuv,ffvhuff,"
                "msrle,msvideo1,mszh,zmbv,flashsv,flashsv2,"
                "dnxhd,cfhd,cllc,hq_hqa,hqx,"
                "cavs,avs,vvc,"
                "rawvideo,bitpacked,v210,v210x,yuv4,"
                "png,apng,gif,webp,bmp,"
                "mp1,gsm,gsm_ms,nellymoser,speex,ilbc,"
                "wavpack,tta,shorten,tak,als,mpc7,mpc8,"
                "qdm2,qdmc,on2avc,imc,mace3,mace6,twinvq,truespeech,"
                "atrac1,atrac3p,atrac9,dss_sp,wmavoice,wmalossless,xma1,xma2,"
                "evrc,qcelp,g728,g729,mp3on4,siren,comfortnoise,"
                "aptx,aptx_hd,sbc,s302m,dolby_e,")
KIT_HWACCELS = ("h264_d3d11va,h264_d3d11va2,hevc_d3d11va,hevc_d3d11va2,"
                "vp9_d3d11va,vp9_d3d11va2,av1_d3d11va,av1_d3d11va2,"
                "h264_vulkan,hevc_vulkan,vp9_vulkan,av1_vulkan")
# libmp3lame: 补 avox 缺口#1 (视频转 MP3 / 提取音频出 mp3)
KIT_ENCODERS = "h264_mf,hevc_mf,aac,libx264,libx265,libmp3lame"
KIT_PARSERS = ("h264,hevc,aac,opus,ac3,mpegaudio,mpegvideo,mpeg4video,vc1"
               ",vp8,vp9,av1,vorbis,flac,dca,aac_latm,amr,mjpeg")
KIT_BSF = "h264_mp4toannexb,hevc_mp4toannexb,aac_adtstoasc,extract_extradata"
KIT_PROTOCOLS = "file,http,https,tcp,udp,rtp,rtmp,rtmps,tls,srtp,crypto,data,pipe,httpproxy"
KIT_DEMUXERS = ("mov,matroska,flv,live_flv,mpegts,hls,avi,asf,aac,mp3,ogg,wav,rtsp,sdp,ac3,"
                "rm,mpegps,mpegvideo,"
                "flac,ape,amr,dsf,"
                "srt,ass,webvtt,microdvd,sami,subviewer,subviewer1,realtext,pjs,mpl2,"
                "jacosub,vplayer,stl,vobsub,sup,"
                "aiff,caf,w64,au,tta,wv,shorten,tak,mpc,mpc8,dts,eac3,xwma,"
                "ivf,swf,image2,image2pipe,rawvideo,concat,")
# mp3=音轨出 mp3; wav=无损音频导出兜底 (引擎 WavSave 之外的白名单级兜底);
# ipod=只含音轨的 m4a (avformat 按扩展名选 muxer, 缺它 .m4a 直接猜不出)
KIT_MUXERS = "mp4,mov,flv,mpegts,matroska,adts,mp3,wav,ipod"

FLAVORS = ("kit", "gpl")
PACMAN_PKGS = ("mingw-w64-x86_64-libx264", "mingw-w64-x86_64-x265",
               "mingw-w64-x86_64-lame", "mingw-w64-x86_64-vulkan-headers")
# 注意: 包名是 libx264; 名为 x264 的是元包, 会拖入 ffmpeg/ffms2 全家
SYSTEM_DLLS = {"kernel32.dll", "msvcrt.dll", "user32.dll", "ole32.dll", "oleaut32.dll",
               "advapi32.dll", "ws2_32.dll", "bcrypt.dll", "crypt32.dll", "ncrypt.dll",
               "secur32.dll", "ntdll.dll", "shell32.dll", "gdi32.dll",
               "vulkan-1.dll"}  # GPU 驱动自带, 不随包分发


def build_options(flavor):
    opts = list(COMMON_OPTIONS)
    if flavor == "kit":
        opts += [
            "--disable-everything",
            f"--enable-protocol={KIT_PROTOCOLS}",
            f"--enable-demuxer={KIT_DEMUXERS}",
            f"--enable-muxer={KIT_MUXERS}",
            f"--enable-decoder={KIT_DECODERS}",
            f"--enable-encoder={KIT_ENCODERS}",
            f"--enable-parser={KIT_PARSERS}",
            f"--enable-bsf={KIT_BSF}",
            f"--enable-hwaccel={KIT_HWACCELS}",
        ]
    opts += ["--enable-gpl", "--enable-libx264", "--enable-libx265", "--enable-libmp3lame"]
    return opts


def configure_and_build(src, flavor, jobs, prefix):
    src = os.path.abspath(src)
    if not os.path.isfile(os.path.join(src, "configure")):
        print(f"FFmpeg 源码树不对 (没有 configure): {src}")
        sys.exit(2)
    prefix = os.path.abspath(prefix).replace("\\", "/")
    options = " ".join(build_options(flavor))
    script = (f'export PATH=/mingw64/bin:/usr/bin:$PATH; export MSYSTEM=MINGW64; '
              f'cd "{src.replace(chr(92), "/")}" && ./configure --prefix="{prefix}" {options} '
              f'&& make -j{jobs} && make install -j{jobs}')
    print(f"[{flavor}] configure+make, src={src}, prefix={prefix}")
    result = subprocess.run([bash_path, "-lc", script])
    if result.returncode != 0:
        print(f"构建失败 (exit {result.returncode})")
        sys.exit(result.returncode)
    print(f"ffmpeg-{flavor} 构建完成: {prefix}")
    collect_runtime_deps(prefix)
    print(f"渠道校验: python {os.path.basename(__file__)} --verify \"{prefix}/bin\"")


def collect_runtime_deps(prefix):
    """扫 prefix/bin 导入表, 非 Windows 系统 dll 且缺失的从 mingw64/bin 补拷,
    使产物目录自包含 (lame/x265/libstdc++ 等运行时)。"""
    if not os.path.isfile(objdump_path):
        print("WARN: 无 objdump, 跳过运行时依赖收集")
        return
    dest_bin = os.path.join(prefix, "bin")
    copied = [n for n in os.listdir(dest_bin) if n.lower().endswith(".dll")]
    for name in list(copied):
        info = subprocess.run([objdump_path, "-p", os.path.join(dest_bin, name)],
                              capture_output=True, text=True)
        for line in info.stdout.splitlines():
            dep = line.split("DLL Name:")[-1].strip().lower() if "DLL Name:" in line else ""
            if (dep and dep not in SYSTEM_DLLS and dep.endswith(".dll")
                    and dep not in [c.lower() for c in os.listdir(dest_bin)]):
                src_dep = os.path.join(MSYS2_INSTALL_DIR, "mingw64", "bin", dep)
                if os.path.isfile(src_dep):
                    shutil.copy2(src_dep, os.path.join(dest_bin, dep))
                    copied.append(dep)
                    print(f"dep+ {dep}")
                else:
                    print(f"WARN: 依赖 {dep} 不在 mingw64/bin, 需手工补")


def verify_dist(path):
    """只扫 nonfree 标记; gpl 标记是本仓合法渠道, 不算违规。"""
    targets = []
    if os.path.isfile(path):
        targets.append(path)
    else:
        for name in sorted(os.listdir(path)):
            if name.lower().endswith((".dll", ".exe")):
                targets.append(os.path.join(path, name))
    if not targets:
        print(f"目录里没有 dll/exe: {path}")
        sys.exit(2)
    bad = False
    for target in targets:
        with open(target, "rb") as f:
            blob = f.read()
        hits = [mark.decode() for mark in NONFREE_MARKS if mark in blob]
        if hits:
            bad = True
            print(f"❌ {os.path.basename(target)}: {', '.join(hits)}")
        else:
            print(f"✅ {os.path.basename(target)}")
    if bad:
        print("发现 nonfree 标记: 该产物任何渠道不可分发 (AGENTS.md 红线)")
        sys.exit(1)
    print("verify 通过 (无 nonfree)")


def check_deps():
    print(f"MSYS2: {MSYS2_INSTALL_DIR}")
    for name in ("gcc.exe",):
        p = os.path.join(MSYS2_INSTALL_DIR, "mingw64", "bin", name)
        print(f"  {'✅' if os.path.isfile(p) else '❌'} mingw64/bin/{name}")
    pacman = os.path.join(MSYS2_INSTALL_DIR, "usr", "bin", "pacman.exe")
    result = subprocess.run([pacman, "-Q"], capture_output=True, text=True)
    installed = set()
    for line in result.stdout.splitlines():
        parts = line.split()
        if len(parts) == 2:
            installed.add(parts[0])
    for pkg in PACMAN_PKGS:
        mark = "✅" if pkg in installed else "❌"
        print(f"  {mark} {pkg}")
        if pkg not in installed:
            print(f"      补装: {pacman} -S --needed {pkg}")
    print(f"ffmpeg 源码树 (默认): {DEFAULT_SRC}"
          f" {'✅' if os.path.isfile(os.path.join(DEFAULT_SRC, 'configure')) else '❌'}")


def main():
    parser = argparse.ArgumentParser(description="avoxkit 出厂 ffmpeg 构建 (gpl + libmp3lame)")
    parser.add_argument("--flavor", default="kit", choices=FLAVORS)
    parser.add_argument("--src", default=DEFAULT_SRC, help="FFmpeg 源码树")
    parser.add_argument("--prefix", default=None,
                        help="安装树 (默认 <仓>/third_party/ffmpeg/<flavor>)")
    parser.add_argument("--jobs", type=int, default=os.cpu_count() or 4)
    parser.add_argument("--verify", metavar="PATH", help="只跑 nonfree 校验")
    parser.add_argument("--check-deps", action="store_true", help="自检工具链与依赖包")
    args = parser.parse_args()

    if args.verify:
        verify_dist(args.verify)
        return
    if args.check_deps:
        check_deps()
        return
    prefix = args.prefix or os.path.join(AVOXKIT_ROOT, "third_party", "ffmpeg", args.flavor)
    configure_and_build(args.src, args.flavor, args.jobs, prefix)


if __name__ == "__main__":
    main()
