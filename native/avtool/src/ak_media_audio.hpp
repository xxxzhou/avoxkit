#pragma once

#include <cstdint>
#include <string>
#include <vector>

namespace ak {

// 录屏 finalize / 工程导出共用的音频与媒体小工具。
// WAV 走自解析: 出厂 kit 没开 pcm_f32le 解码器, 而 WASAPI 回环常落 float32。

struct AudioTrackSpec {
  std::string id;
  std::string path;
  int64_t startMs = -1;   // 首包会话时钟, -1 = 本轨缺席
  double gainDb = 0.0;
  bool mute = false;
};

struct MediaProbe {
  bool ok = false;
  int64_t durationMs = 0;
  int32_t width = 0;
  int32_t height = 0;
  double fps = 0.0;
  std::string error;
};

bool probe_media(const std::string& path, MediaProbe* out);

struct MixResult {
  bool ok = false;
  bool no_audio = false;
  std::string path;
  int64_t durationMs = 0;
  std::string error;
};

// 多路 WAV → 48k 立体声 AAC(m4a); 区间是源文件时间(ms), [startMs,endMs)
MixResult mix_wavs_to_aac(const std::vector<AudioTrackSpec>& tracks,
                          int64_t videoPts0Ms, int64_t startMs,
                          int64_t endMs, const std::string& outPath);

struct RemuxResult {
  bool ok = false;
  std::string error;
};

// 视频/音频流直拷进目标容器; audioPath 可空; mp4 加 faststart, HEVC 打 hvc1
RemuxResult remux_streams(const std::string& videoPath,
                          const std::string& audioPath,
                          const std::string& outPath);

// 原子替换: 目标存在时覆盖(Windows MoveFileEx)
bool replace_file(const std::string& from, const std::string& to,
                  std::string* error);

}  // namespace ak
