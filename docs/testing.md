# 无头测试

内部测试文档。命令中的 `<flutter-sdk>`、`<avox-repo>`、`<tmp>` 按本机环境替换。

不依赖 Flutter 窗口，可在 CI / 远程会话直接跑。

## 1. Flutter 单元测试

```bash
<flutter-sdk>/bin/flutter test
```

覆盖：

- `convert_plan_test.dart`：容器/视频编码/分辨率/音频编码判定矩阵，容器兼容表，
  probe 容器名归一化。
- `batch_test.dart`：sidecar / mirror / flat 命名，逐文件扩展名，已存在跳过。
- `folder_scan_test.dart`：递归、扩展名过滤、数量上限。
- `preview_task_test.dart`：组内预览选路（运行中 → 最早排队 → 最后一路）。
- `task_event_test.dart`：任务事件白名单（录屏/工程导出事件不建任务）。
- `subtitle_plan_test.dart`：内嵌/识别分流、默认/中文轨优先、图形字幕拒绝、
  无音轨/无字幕错误、params 映射。
- `model_store_test.dart`：模型清单、分片大小校验、ready 状态、目录自建。
- `image_plan_test.dart`：输出扩展名回退、`-repaired` 命名、自动/手绘参数、
  检测结果解析、图像修复模型清单。
- `clip_plan_test.dart`：时间文本解析/格式化、关键帧吸附、区间校验、trim 参数。
- `trim_timeline_test.dart`：拖手柄/拖选区/抬起补点/未知片长不响应/悬停与拖动
  的 scrub 时刻/按宽度请求缩略图张数。
- `filmstrip_test.dart`：格子按引擎输出宽高比排版（竖拍上下留白不裁切、横拍
  16:9、输出尺寸未知按 16:9 兜底）。
- `time_viewport_test.dart`：ms↔px 映射、以指针为锚缩放、平移夹取、1 秒最短视口、
  刻度间隔、片长变化重置。
- `media_frames_test.dart`：抓帧结果解析与坏数据跳过、无视频轨、最近帧选择、
  缩略图张数夹在 6-24。
- `task_visual_test.dart`：预览模式选择（视频重编→画面，仅音频重编→波形，
  直拷/无 PCM→进度）。
- `task_summary_test.dart`：产物路径双击复制、单击不复制。

当前用例数与结果以实际运行输出为准。

## 2. 原生功能集成

构建：

```bash
cmake --build native/avtool/build --config Release \
  --target ak_features_test ak_subtitle_test ak_image_test \
          ak_preview_smoke ak_preview_restart
```

运行：

```bash
native/avtool/build/bin/Release/ak_features_test.exe <in> <workdir> <outdir>
native/avtool/build/bin/Release/ak_subtitle_test.exe <带字幕轨媒体> <workdir> <outdir>
native/avtool/build/bin/Release/ak_image_test.exe <图片> <模型根>
native/avtool/build/bin/Release/ak_preview_smoke.exe <in> <out.mp4> <workdir>
native/avtool/build/bin/Release/ak_preview_restart.exe <in> <out_a> <out_b> [workdir]
```

`ak_image_test` 的模型根目录形如 `<avox-repo>/../avox_model/assets/models`
（内含 `inpaint/lama_base.onnx` 与 `inpaint/yolo26m-seg_watermark.onnx`）。
模型不在时只验证 capabilities 后打印 `SKIP`；模型就位时覆盖：插件/模型装载、
`ak_image_detect` 返回尺寸与框、手绘 mask 任务产出可解码 PNG 且尺寸不变、
自动模式有结果或明确返回 `no_watermark`。

`<in>` 建议用 H.264 + AAC 的 MKV/MP4。`ak_features_test` 会按源编码自适应；
源组合不适合 MP4 直拷时打印 `skip`，不算失败。

生成一条带内嵌 SRT 的测试片（ffmpeg 需在 PATH）：

```bash
ffmpeg -f lavfi -i "testsrc2=size=320x180:rate=15" \
  -f lavfi -i "sine=frequency=440:sample_rate=44100" \
  -i <avox-repo>/assets/video/subtext_test.srt \
  -map 0:v -map 1:a -map 2:s -c:v libx264 -c:a aac -c:s srt -t 10 \
  -y <tmp>/sub_embedded.mkv
```

`ak_features_test` 覆盖：

| 场景 | 关键断言 |
|---|---|
| capabilities / encoders | h264 / hevc / aac / mp3 编码器探测，features 标志 |
| probe | 视频/音频轨、分辨率、时长 |
| remux | 产物容器 MP4、编码/分辨率与源一致、时长≈源 |
| transcode audio_copy + 缩放 | 目标编码/320×180、音频仍为源编码、日志 `audio copy mode` + `enableSizeChange` |
| transcode video_copy + 音频重编 | 视频编码/分辨率与源一致、音频目标编码、日志 `video copy mode` |
| transcode all + 缩放 | 目标视频编码/320×180、音频 AAC |
| extract aac / mp3 / copy | 无视频轨、音频编码正确、时长≈源 |
| media index | 时长/关键帧/包络可读, 有音轨时包络非空 |
| media frames | 4 帧/单点抓帧、JPEG 前缀、实际帧时间递增、按请求宽度输出、无视频轨字段 |
| trim | 产物可探测、编码正确、时长≈片段(±1.5s) |
| trim 错误路径 | 反向区间 / 起点超出片长 / 起点超过 90% → -2 |
| queue 3 | 3 个任务全部完成，`queue_position` 事件 3 条且都在 1..3 |
| 混合 kind | 同组内 remux + video_copy 并发提交，两个产物都正确 |
| 错误路径 | video_copy+缩放/奇数分辨率/width 缺 height → -2；输入不存在 → -8；输出已存在 → -9；不支持的视频编码 → -7 |
| 日志 | 出现 `audio copy mode`、`video copy mode`、`enableSizeChange` |

参考结果（2026-10-28，`<avox-repo>/assets/video/ass_test.mkv`）：170 checks，0 failed。

`ak_subtitle_test` 覆盖：probe 字幕项的 `text` 标记、auto 模式提交、
任务完成、SRT 非空/序号/时间轴、无 ASS 字段前缀。源没有文本字幕轨时打印
`skip`，退出码 0。参考结果：9 checks，0 failed。

`ak_preview_smoke` 覆盖：提交后立刻 bind（早于录制器 onReady）→ 进入 recording
后 bind → unbind → rebind → unbind → cancel，断言进程不崩、转码线程不停。
**必须用长片**（如 45 分钟素材）：短片在第一次 unbind 前就转完，重绑分支不会
执行，测试会失去意义。测试时用 `<tmp>/s10e19.mp4` 跑，退出码 0，日志可见
`surface attached` / `detached` / `already running`。

早绑这次必须被拒绝：日志里第一次 bind 之后不能出现 `surface attached`，且
recording 之后的 `create win32 window` 要晚于 `use empty surface`（录制器
onStart 的 setOffSurface）。若早绑被接受，面会被随后的 setOffSurface 拆掉，
onReady 重挂又因同句柄被短路，第二个任务起预览永久黑屏。

`ak_preview_restart` 覆盖「录制中取消 → 再启动」：A 任务录制中抓两帧确认
在动，取消后立即提交 B 并重绑（含 unbound/close/open/bind 的控件重建时序），
再连抓三帧确认仍在动，同时枚举预览窗子窗断言没有被旧任务残留的引擎窗盖住。
也必须用长片。2026-10-28 复现到的问题：`close_recorder` 在任务线程调
`setOffSurface`，引擎 `Window::close()` 跨线程 `DestroyWindow` 失败且无回退，
取消任务的渲染子窗留在原处（且位于新窗之上），预览定格在最后一帧。修复在
avox `Window::close()`：销毁失败时先摘 `GWLP_USERDATA` 再向创建线程投递
`WM_CLOSE`。

### 2.1 多声道音频（5.1）回归

音频编码按 `[ch][frameSamples]` 平面逐声道攒帧，串道或整轨无声音都属于引擎级事故。
生成一条带 5.1 测试音的短片（需要系统 ffmpeg）：

```bash
ffmpeg -f lavfi -i "testsrc2=size=320x180:rate=15:duration=6" \
  -f lavfi -i "aevalsrc=sin(2*PI*300*t)|sin(2*PI*500*t)|sin(2*PI*700*t)|0|sin(2*PI*1100*t)|sin(2*PI*1300*t):s=48000:d=6:c=5.1" \
  -map 0:v -map 1:a -c:v libx264 -preset ultrafast -c:a ac3 -b:a 640k -shortest \
  -y m51.mkv
native/avtool/build/bin/Release/ak_smoke.exe transcode m51.mkv out.mp4 work --overwrite
```

产物应探测到 6 声道 AAC；解成 wav 后逐声道做 FFT，峰值应分别是
300 / 500 / 700 / 静音 / 1100 / 1300 Hz。再查包时长：

```bash
ffprobe -v error -select_streams a:0 -show_entries packet=duration_time \
  -of csv=p=0 out.mp4 | sort | uniq -c
```

48 kHz 下应只有 `0.021` / `0.022`（1024 样本）；出现 `0.001` / `0.011` /
`0.032` 说明时间戳被输入块 pts 带抖了，播放器会周期性补/丢样本。
`ak_features_test` 末尾的「音频编码无 send_frame 失败」也在守同一条链路。

### 2.2 MP3 音频（含 MOV 容器）回归

libmp3lame 只收平面格式、最多 2 声道、采样率只有固定档位；而 EAC3 5.1 解出来是
6 声道 `flt`。引擎必须在下混/换格式之后才开编码器，否则 `avcodec_open2` 直接
EINVAL，任务仍然「完成」但产物没有音轨。

```bash
native/avtool/build/bin/Release/ak_smoke.exe transcode m51.mkv out.mov work \
  --audio-codec mp3 --container mov --overwrite
ffprobe -v error -show_entries stream=codec_type,codec_name,channels,sample_rate \
  -of default=noprint_wrappers=1 out.mov
```

断言：有 `mp3` 音轨、2 声道、48 kHz、时长≈源；包时长只有 `0.024`（1152 样本）。
解码后与 `ffmpeg -ac 2` 的源做 10 ms 包络相关，应 >0.9 且没有静音缺口。

MP4 + MP3 必须落标准 MP4：非 AAC 音频曾被整体改道 mov，产物扩展名是 `.mp4`
但 `ftyp` 是 `qt  `，音频用 QuickTime 的 `.mp3` sample entry 且没有 esds，
爱奇艺等播放器会当成没有音轨。断言 `head -c 12 out.mp4` 的 brand 不是 `qt  `、
音频 sample entry 为 `mp4a`（带 esds）；`ak_features_test` 的 video_copy 用例
已加这条品牌检查。

### 2.3 直拷/封装的首个 GOP 回归

本地文件出包比 muxer open 快，开录前先到的包曾整段丢掉，直拷产物从第二个 GOP
才开始（前 10 秒只有声音）。另外首包 dts 缺失时会与下一帧撞车，按 dts 合并
slice 会把下一帧并进 IDR，开头整段解不出来。

```bash
# 取一条 10 秒 GOP 的 HEVC 源前 40 秒，做视频直拷 + MP3
ffmpeg -i src.mkv -map 0:v:0 -map 0:a:0 -t 40 -c copy head.mkv
native/avtool/build/bin/Release/ak_smoke.exe transcode head.mkv out.mkv work \
  --trans-mode video_copy --audio-codec mp3 --container mkv --overwrite
ffprobe -v error -select_streams v:0 \
  -show_entries packet=pts_time,flags -of csv=p=0 out.mkv | head -3
```

断言：第一包 `0.000000,K__`；与源做同区间 `psnr` 应为 `inf`（逐位一致）；
日志无 `non monotonically increasing dts` / `muxer is not recording` /
`av_interleaved_write_frame non-fatal`。remux 与 `--trans-mode video_copy` 共用
这条链路，`ak_features_test` 的 remux / video_copy 用例同时覆盖。

### 2.4 帧序与片尾回归

两个独立事故都表现为「产物不对」：

- **画面来回抖**：`copyBufHost` 原地复用环槽 `VideoFrame`，编码线程 `dequeue`
  后在锁外读取时被下一帧覆写，画面内容和 pts 串帧。B 帧流上表现为某帧内容跳到
  4 帧后（P 帧显示位）再跳回，暗场慢镜头最明显。
- **片尾少一截**：关源前不排空解码器（重排/帧级线程扣住的尾帧），编码器
  `drain` 出的包又被 `close()` 提前置 `bReady=false` 塞进 pending 清掉。

```bash
native/avtool/build/bin/Release/ak_smoke.exe transcode in.mkv out.mkv work \
  --codec h264 --width 1280 --height 720 --hardware off \
  --trans-mode audio_copy --container mkv --overwrite
```

断言：

- `ffprobe -count_frames` 产物帧数 == 源帧数（片尾不丢）；
- 包 pts 无 >50ms 空洞、无重复（源自身的不连续除外）；
- 逐帧内容对位：解码后第 i 帧应等于源第 i-1 帧（产物起点 +0.083s）。个别帧
  跳到 +4 帧即环槽复用竞态复发。

日志里 `video encoder drain, sent:N` 的 N 应等于源帧数；`sent` 小于源帧数说明
`AMediaSource::onComplete` 没有排空解码器。

### 2.4.1 片段截取与媒体索引

```bash
# 30 秒、2 秒 GOP 的源
ffmpeg -f lavfi -i "testsrc2=size=640x360:rate=30:duration=30" \
  -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=30" \
  -map 0:v -map 1:a -c:v libx264 -preset ultrafast -g 60 -keyint_min 60 \
  -sc_threshold 0 -c:a aac -shortest -y trim_src.mp4

native/avtool/build/bin/Release/ak_smoke.exe index trim_src.mp4 300
native/avtool/build/bin/Release/ak_smoke.exe frames trim_src.mp4 <tmp>/strip 8 320
native/avtool/build/bin/Release/ak_smoke.exe trim trim_src.mp4 out.mp4 work 10000 16000
```

断言：

- `index` 返回 `duration_ms≈30000`，`keyframes_ms` 为 `0,2000,…,28000`，
  `peaks` 长度≈300 且非全零。
- `frames` 写出 8 张 320px 宽的 JPEG，`ms` 递增且落在片长内；打开首图应看到
  对应的测试画面（不是纯黑/错色）。4K/HDR/10bit 源各抓一张做抽查。
- `trim` 的首个 wave 事件 `pts_ms≈10000`（起点落在关键帧）；产物时长应≈6 秒。
- 终点受解码/封装排队影响有约 ±0.5 秒误差，验收容差按 ±1.5 秒；
  文案不能写“帧精确”。
- 反向区间、起点超出片长、起点超过片长 90%（`io.startFrac` 上限）在提交时
  返回 `-2`。
- **10-bit 源首帧必须是真实画面**，不能是纯绿：`yuv420p10le` 源全零 YUV 按
  limited range 会解成深绿，历史上是输入层上传晚于 submit、首帧消费建图暂存
  导致的。用 10-bit HEVC/H.264 各截一段，`frames <clip> <dir> 1 320 --times 0`
  抽首帧目检；首帧应与源同一时刻的画面一致。

### 2.4.2 竖拍与只读链路（avox IMediaReader）

probe/index/能力探测走 avox `IMediaReader`/`AvoxRuntime`（v1 仅本地文件）；
`ak_frames` 走 `IMediaReader::grabFrame`（VK 出图），不再直连 libav。

```bash
ffmpeg -f lavfi -i "testsrc2=size=640x360:rate=30:duration=6" \
  -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=6" \
  -map 0:v -map 1:a -c:v libx264 -preset ultrafast -g 60 -c:a aac -y portrait_src.mp4
ffmpeg -display_rotation 90 -i portrait_src.mp4 -c copy -y portrait.mp4

native/avtool/build/bin/Release/ak_smoke.exe probe portrait.mp4
native/avtool/build/bin/Release/ak_smoke.exe index portrait.mp4 300
native/avtool/build/bin/Release/ak_smoke.exe frames portrait.mp4 <tmp>/strip_p 6 320
MSYS_NO_PATHCONV=1 native/avtool/build/bin/Release/ak_smoke.exe \
  probe "http://127.0.0.1:9/a.mp4"
```

断言：

- `probe`：video 仍报编码方向 640×360，另带 `rotation`（90/270，诊断字段，
  UI 不消费、不参与布局）。
- `index`：峰值/关键帧正常，旋转不影响索引。
- `frames`：输出 320×569（显示方向），画面正立；时间线 `AkFilmstrip` 按
  该宽高排版（见 `filmstrip_test.dart`），预览窗口保持 16:9 黑边。
- 网络 URI 打开即回 `ok:false, code=unsupported`（"v1 supports local files only"）。
- `caps` 含 `"vulkan"` 字段；无 Vulkan 时 `frames` 回
  `reason=render_unavailable`，UI 显示「Vulkan 组件未启用，缩略图/画面预览不可用」
  （`MediaFrames.unavailableHint` → 时间线 stripNote / 画面参考 emptyText）。
  像素格式不支持同理走 `unsupported_pix_fmt`，不回退 CPU 解码。

参考结果（2026-10-30）：以上全部符合；横拍 strip 8×(320×180)，
trim 10000–16000 产物 5972ms（±1.5s 容差内）。

### 2.5 ASR 冒烟（可选，需先下载模型）

模型是运行时资源，不进仓库。手工验证时：

1. 把 `model.int8.onnx` / `tokens.txt` / `silero_vad.onnx` 放到
   `<workdir>/models/stt/sense-voice/`（或 app 的 models 目录）；
2. 提交 `kind=subtitle`、`params.subtitle.mode=asr` 的任务；
3. `<avox-repo>/assets/video/sherpa.mp4` 实测生成 12 条中/日文 SRT。

App 首次点“开始识别”会自动下载同一组文件并校验 sha256，不识别不下载。

### 2.6 图像修复（去水印）回归

模型不进仓库，先把 `lama_base.onnx` 与 `yolo26m-seg_watermark.onnx` 放到
`<models>/inpaint/`（App 首次使用会自动下载到同一位置）。

```bash
native/avtool/build/bin/Release/ak_image_test.exe \
  <avox-repo>/assets/images/godot/avox_godot_play_win.png \
  <avox-repo>/../avox_model/assets/models
```

断言：插件装载后 `image_plugin=1 image_inpaint=1`；`ak_image_detect` 返回
`ok=true` 且宽高与源图一致；手绘 mask 任务产出可解码 PNG 且尺寸不变；自动模式
要么产出结果，要么明确失败 `no_watermark`（样图没有训练目标时属正常）。
首次加载模型约数秒，测试整体应在 1 分钟内结束。

UI 侧回归：

1. 选一张图，模型未下载时按钮显示“下载模型并开始修复”；下载完成后状态变为
   “图像修复模型已就绪”。
2. 自动识别点“识别水印”，预览图出现金色框；直接点“开始修复”也能出结果。
3. 手动涂抹涂一块区域，点“修复涂抹区域”，完成后预览切到结果，可“看原图”对比。
4. 选文件夹批量，确认输出名带 `-repaired`、重跑覆盖同名输出；任务组可取消/重试。
5. 关掉应用再启动，模型仍在，不需要重新下载。

### 2.7 干净启动（打包回归）

从 Explorer 双击 `dist/avoxkit-windows-x64/avoxkit.exe`，不应出现
「无法加载 avoxkit_native.dll」(error 126)。开发机的 Git/VS 环境会把
`mingw64/bin` 塞进 PATH，缺 MinGW 运行时也能启动；普通双击才暴露问题：
kit 的 x264/x265 经 `libstdc++-6.dll` 依赖 `libgcc_s_seh-1.dll`。

### 2.8 录屏整链（采集 → finalize → 工程导出）

```bash
cmake --build native/avtool/build --config Release --target ak_capture_test
native/avtool/build/bin/Release/ak_capture_test.exe <tmp>/ak_cap 5
native/avtool/build/bin/Release/ak_capture_test.exe <tmp>/ak_cap_audio 5 --audio
native/avtool/build/bin/Release/ak_capture_test.exe <tmp>/ak_cap_region 3 --region=640x360
```

覆盖：

- 显示器采集（30fps）→ `screen.mkv`；`ak_capture_stop` 只落盘（WAV 头/
  `session.json` + 光标遥测），随后 `ak_capture_finalize` 出 `capture.mkv`
  （视频 + 混音 AAC）与 `project.json`。
- UI 侧 stop 必须留在主 isolate（会话状态跟着创建它的 isolate），finalize
  可放后台 isolate；后台 isolate 打不开原生库时自动退回主 isolate。
- 工程导出：1280×720 H.264 MP4，帧率跟源（引擎按解码帧推进，请求里的
  `fps` 只是提示）；背景渐变/留白/圆角/阴影；
  关闭“录下系统光标”时按遥测轨迹重绘光标。
- 点击事件 `inside` 两种写法都要能读：旧遥测写 0/1，新遥测写 bool；
  测试工具会注入一条数字、一条 bool 再导出（回归 nlohmann `type_error` 崩溃）。
- `--audio` 且系统正在播放声音时落 `audio/sys.wav`，混音后进成片；
  系统静音时 WASAPI 回环不产包，成片无音轨属预期。
- 画面必须有内容：抽 `screen.mkv` 一帧看平均亮度，纯黑说明采集坏了。
  WGC 帧到 NT 共享纹理必须是 GPU 直拷（`CopySubresourceRegion`）；
  `D3D11_BOX` 的 `front/back` 必须写成 0/1，漏掉就是空盒，拷贝静默
  拷 0 字节、整段录屏全黑（2026-10-30 实际踩过，CPU 读回是当时的错误绕路）。
- 自定义区域（`--region=WxH`，从显示器左上起）：`screen.mkv` 尺寸等于区域，
  内容非黑；区域 box 与全画面共用同一段拷贝代码，回归时两条都要跑。

检查产物：

```bash
ffprobe -v error -show_entries stream=index,codec_type,codec_name,width,height,sample_rate,channels -of json <tmp>/ak_cap/export.mp4
ffmpeg -ss 1 -i <tmp>/ak_cap/export.mp4 -frames:v 1 <tmp>/frame.png
```

2026-10-30 参考结果（2560×1440 采集 → 1280×720 导出）：WGC + GPU 直拷
2560×1440@60 实测 59.9fps、5s 289 帧、丢弃 0，`screen.mkv` 抽帧亮度 42.1，
导出成片抽帧亮度 38.7（亮度随屏显内容变化，非 0 即通过）；区域 640×360@30
实测 29.97fps、丢弃 0、抽帧亮度 40.0（导出 37.4）；背景、圆角、阴影与
内容区边界逐像素核对一致；光标置于 (1280,720) 后导出画面中心可见重绘光标；
回环播放正弦波时 `sys.wav` 为 `pcm_f32le` 48k 立体声，混音 AAC 成片 max -35.6 dB。

环境注意：

- 本机 AMD 驱动上 WGC 采屏正常，不需要切 GDI；曾经的「IDD 虚拟屏 WGC 恒黑」
  是误判（实为空 box 导致拷贝 0 字节），不要按该结论改采集后端。
- 场景层 shader 必须随包部署：缺 `assets/glsl/scene.comp.spv` 时场景层静默
  禁用，尺寸守卫会把导出帧全丢（表现为导出成功但没有画面）。
- 远程桌面/虚拟屏下注入鼠标点击不可靠（光标位置被外部环境改写），本环境
  未验证点击事件与涟漪；光标轨迹重绘已验证。

#### 崩溃定位（`flutter_windows.dll+0x3C16A`）

这是 Flutter Windows 引擎的无障碍桥缺陷，不是采集/GPU 链的问题：

- 偏移符号化为 `flutter::AccessibilityBridge::CreateRemoveReparentedNodesUpdate
  + 0xBA`（`accessibility_bridge.cc:229`）。用 SDK 自带
  `bin/cache/artifacts/engine/windows-x64-release/flutter_windows.dll.pdb`
  即可按 RVA 还原。
- 触发条件：UIA/MSAA 客户端（远程桌面、自动化工具、读屏）在**启动后约 4 秒内**
  枚举一次界面。桥首次提交拿到的是不完整语义树，把任意节点立成原生根；
  之后一次 re-parent 更新里该节点 `parent()` 为空，release 下 `assert` 被编译掉，
  `parent()->id()` 直接崩。空闲或启动 5 秒后再枚举不会触发。
- 上游状态（2026-10-30）：flutter/flutter#175041 仍 open，PR #190903 未合入；
  3.47.9 stable 与 master 的该函数都还没补空指针判断。
- 规避：关于 → 兼容性 → 「关闭无障碍支持」（`ExcludeSemantics` 包住整棵树，
  实测可避免崩溃；代价是读屏不可用），或设 `AVOXKIT_DISABLE_A11Y=1`。
  开关写 `<appSupport>/compat.json`，默认关闭（保持无障碍可用）。
- 在 runner 里拦 `WM_GETOBJECT` 无效（社区已实测，桥仍会建起来），不要走这条路。
- `ak_engine.cpp` 的崩溃钩子会把异常模块/偏移和栈上落在模块内的返回地址
  一起写日志，下次崩溃先看 `crash stack:` 行。

## 3. macOS（arm64）

先按 `docs/macos-porting.md` 准备 avox（`--flavor=agpl`，关闭
`AVOX_ENABLE_WEBRTC/ZLMEDIAKIT`）与 `kit-macos`。工具在
`native/avtool/build/bin/`，没有 `.exe` 后缀。

```bash
cd native/avtool/build/bin
./ak_smoke version
./ak_smoke init <workdir>
./ak_smoke caps <workdir>
./ak_smoke probe <media> <workdir>
./ak_smoke transcode <in> <out> <workdir> --audio-codec mp3 --container mp4 --overwrite
./ak_smoke extract <in> <out.m4a> <workdir> --codec aac --overwrite
./ak_smoke trim <in> <out> <workdir> 10000 16000
./ak_smoke index <in> 300
./ak_smoke frames <in> <out_dir> 8 320
./ak_features_test <in> <workdir> <outdir>
./ak_subtitle_test <带字幕轨媒体> <workdir> <outdir>
./ak_image_test <图片> <模型根>
```

`libvulkan.1.dylib`（MoltenVK）必须和 shim 同目录，否则 `caps.vulkan=false`，
缩放转码 `output_finalize_failed`、`frames` 回 `render_unavailable`。

2026-10-30 参考结果（`ass_test.mkv`、`avox_model/assets/models`）：

- `ak_features_test`：170 checks，0 failed；
- `ak_subtitle_test`：9 checks，0 failed；
- `ak_image_test`：`image_plugin=1 image_inpaint=1`，手绘 mask 产出 160×160 PNG，
  自动模式 `no_watermark`（样图无水印），PASS；
- smoke 的 probe/transcode(MP3)/extract(m4a)/trim/index/frames 全部 exit 0；
- 无音轨源（`avox_electron.mp4`）转码正常完成（源无音轨时跳过
  `audio_missing` 校验）。

### 3.1 GUI 与打包

```bash
./script/build_macos.sh
open dist/avoxkit-macos-arm64/avoxkit.app
```

2026-10-30 实测：启动后引擎就绪、4 个 avox 插件全部发现；转换页选
`ass_test.mkv`，probe 显示 H.264+AAC 30s，改 MP4 直接封装完成，产物
`ffmpeg -i` 为 H.264+AAC 30s；Cmd+Q 退出日志完整、无残留进程、无新崩溃。

录屏整链（同一天，`avoxkit-dev` 自签包）：

- 首次录屏前授予「屏幕与系统录音」+「麦克风」；自签证书固定后重建安装包，
  授权仍然有效，不再弹 TCC 提示；
- 43.8s、60fps、0 dropped，落盘 `screen.mkv`（H.264 1470×956）、
  `audio/mic.wav`（f32 48kHz mono，8,425,472 字节，ffmpeg 时长 43.88s）、
  `capture.mkv`（H.264+AAC）；
- 工程导出到跨卷目录（外置盘）成功（`ffmpeg -i` 为
  H.264 1920×1080 + AAC 48kHz stereo），「打开所在文件夹」在 Finder 中选中
  成片；
- `flutter test` 98 项全部通过。

当前本地/内测包用固定自签证书 `avoxkit-dev`（`CODESIGN_IDENTITY` 可覆盖），
对外分发仍需 Developer ID 签名 + 公证（见 `docs/macos-porting.md` §6.3）。

## 3. 一次跑完

```bash
<flutter-sdk>/bin/flutter test && \
native/avtool/build/bin/Release/ak_features_test.exe \
  <avox-repo>/assets/video/ass_test.mkv <tmp>/ak_f_work <tmp>/ak_f_out && \
native/avtool/build/bin/Release/ak_subtitle_test.exe \
  <tmp>/sub_embedded.mkv <tmp>/ak_s_work <tmp>/ak_s_out && \
native/avtool/build/bin/Release/ak_image_test.exe \
  <avox-repo>/assets/images/godot/avox_godot_play_win.png \
  <avox-repo>/../avox_model/assets/models && \
native/avtool/build/bin/Release/ak_preview_smoke.exe \
  <tmp>/s10e19.mp4 <tmp>/ak_p_out.mp4 <tmp>/ak_p_work
```

注意：

- 测试会覆盖输出目录里的同名文件；用独立临时目录最稳。
- 预览测试要留一个长片；没有长片时至少跑 `ak_features_test` 和 Flutter 单测。
- 日志断言读 `<workdir>/logs/*.log`，工作目录必须可写。
