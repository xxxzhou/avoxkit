# 无头测试

不依赖 Flutter 窗口，可在 CI / 远程会话直接跑。

## 1. Flutter 单元测试

```bash
D:/Work/flutter/bin/flutter test
```

覆盖：

- `convert_plan_test.dart`：容器/视频编码/分辨率/音频编码判定矩阵，容器兼容表，
  probe 容器名归一化。
- `batch_test.dart`：sidecar / mirror / flat 命名，逐文件扩展名，已存在跳过。
- `folder_scan_test.dart`：递归、扩展名过滤、数量上限。
- `preview_task_test.dart`：组内预览选路（运行中 → 最早排队 → 最后一路）。
- `subtitle_plan_test.dart`：内嵌/识别分流、默认/中文轨优先、图形字幕拒绝、
  无音轨/无字幕错误、params 映射。
- `model_store_test.dart`：模型清单、分片大小校验、ready 状态、目录自建。

当前：53 项，全过。

## 2. 原生功能集成

构建：

```bash
cmake --build native/avtool/build --config Release \
  --target ak_features_test ak_subtitle_test ak_preview_smoke
```

运行：

```bash
native/avtool/build/bin/Release/ak_features_test.exe <in> <workdir> <outdir>
native/avtool/build/bin/Release/ak_subtitle_test.exe <带字幕轨媒体> <workdir> <outdir>
native/avtool/build/bin/Release/ak_preview_smoke.exe <in> <out.mp4> <workdir>
```

`<in>` 建议用 H.264 + AAC 的 MKV/MP4。`ak_features_test` 会按源编码自适应；
源组合不适合 MP4 直拷时打印 `skip`，不算失败。

生成一条带内嵌 SRT 的测试片（ffmpeg 需在 PATH）：

```bash
ffmpeg -f lavfi -i "testsrc2=size=320x180:rate=15" \
  -f lavfi -i "sine=frequency=440:sample_rate=44100" \
  -i D:/Work/github/avox/assets/video/subtext_test.srt \
  -map 0:v -map 1:a -map 2:s -c:v libx264 -c:a aac -c:s srt -t 10 \
  -y D:/tmp/sub_embedded.mkv
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
| queue 3 | 3 个任务全部完成，`queue_position` 事件 3 条且都在 1..3 |
| 混合 kind | 同组内 remux + video_copy 并发提交，两个产物都正确 |
| 错误路径 | video_copy+缩放/奇数分辨率/width 缺 height → -2；输入不存在 → -8；输出已存在 → -9；不支持的视频编码 → -7 |
| 日志 | 出现 `audio copy mode`、`video copy mode`、`enableSizeChange` |

当前结果（2026-10-28，`avox/assets/video/ass_test.mkv`）：132 checks，0 failed。

`ak_subtitle_test` 覆盖：probe 字幕项的 `text` 标记、auto 模式提交、
任务完成、SRT 非空/序号/时间轴、无 ASS 字段前缀。源没有文本字幕轨时打印
`skip`，退出码 0。当前用 `D:/tmp/sub_embedded.mkv`：9 checks，0 failed。

`ak_preview_smoke` 覆盖：进入 recording 后 bind → unbind → rebind → unbind →
cancel，断言进程不崩、转码线程不停。**必须用长片**（如 45 分钟素材）：短片在
第一次 unbind 前就转完，重绑分支不会执行，测试会失去意义。当前用
`D:/tmp/s10e19.mp4` 跑，退出码 0，日志可见 `surface attached` / `detached` /
`already running`。

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

### 2.5 ASR 冒烟（可选，需先下载模型）

模型是运行时资源，不进仓库。手工验证时：

1. 把 `model.int8.onnx` / `tokens.txt` / `silero_vad.onnx` 放到
   `<workdir>/models/stt/sense-voice/`（或 app 的 models 目录）；
2. 提交 `kind=subtitle`、`params.subtitle.mode=asr` 的任务；
3. `avox/assets/video/sherpa.mp4` 实测生成 12 条中/日文 SRT。

App 首次点“开始识别”会自动下载同一组文件并校验 sha256，不识别不下载。

## 3. 一次跑完

```bash
D:/Work/flutter/bin/flutter test && \
native/avtool/build/bin/Release/ak_features_test.exe \
  D:/Work/github/avox/assets/video/ass_test.mkv D:/tmp/ak_f_work D:/tmp/ak_f_out && \
native/avtool/build/bin/Release/ak_subtitle_test.exe \
  D:/tmp/sub_embedded.mkv D:/tmp/ak_s_work D:/tmp/ak_s_out && \
native/avtool/build/bin/Release/ak_preview_smoke.exe \
  D:/tmp/s10e19.mp4 D:/tmp/ak_p_out.mp4 D:/tmp/ak_p_work
```

注意：

- 测试会覆盖输出目录里的同名文件；用独立临时目录最稳。
- 预览测试要留一个长片；没有长片时至少跑 `ak_features_test` 和 Flutter 单测。
- 日志断言读 `<workdir>/logs/*.log`，工作目录必须可写。
