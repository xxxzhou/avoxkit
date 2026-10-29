#include "ak_internal.hpp"

#include <algorithm>
#include <atomic>
#include <cctype>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <deque>
#include <filesystem>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_map>
#include <utility>
#include <vector>

#include <nlohmann/json.hpp>

#include "ak_preview.hpp"
#include "avox/Avox.hpp"
#include "avox/AvoxAudio.h"
#include "avox/AvoxBase.h"
#include "avox/AvoxLayer.h"
#include "avox/AvoxMuxer.h"
#include "avox/AvoxSubtitle.h"

#ifdef _WIN32
#include <windows.h>
#endif

namespace ak {
using namespace avox;

namespace {

using nlohmann::json;

enum TaskState : int {
  kQueued = 0,
  kStarting = 1,
  kRunning = 2,
  kDraining = 3,
  kTerminal = 4,
};

std::atomic<uint64_t> g_event_seq{0};

uint64_t next_seq() { return ++g_event_seq; }

// 波形峰值: tap 线程只做降采样, 每 5 个 100ms 块批量投一次事件
class WaveTap : public IAudioTapOb {
 public:
  WaveTap(int64_t task_id, int64_t run_id, std::string group_id,
          std::string kind, std::atomic<int64_t>* decoded_ms,
          std::atomic<int64_t>* decoded_base_ms)
      : task_id_(task_id),
        run_id_(run_id),
        group_id_(std::move(group_id)),
        kind_(std::move(kind)),
        decoded_ms_(decoded_ms),
        decoded_base_ms_(decoded_base_ms) {}

  void onFrame(const AvoxData& raw, int64_t pts) override {
    // 截取的出点用解码侧 pts 判断, 比源读取位置(KB 级预读)准得多。
    // 不同容器给的是绝对 pts 或落点相对 pts, 记下首帧做基准自己归一。
    if (decoded_ms_) {
      if (decoded_base_ms_) {
        int64_t expected = -1;
        decoded_base_ms_->compare_exchange_strong(expected, pts);
      }
      decoded_ms_->store(pts);
    }
    if (!raw.data || raw.size < 2) {
      return;
    }
    const int16_t* samples = reinterpret_cast<const int16_t*>(raw.data);
    const int count = raw.size / 2;
    int peak = 0;
    for (int i = 0; i < count; ++i) {
      const int value = samples[i] < 0 ? -static_cast<int>(samples[i])
                                       : static_cast<int>(samples[i]);
      if (value > peak) {
        peak = value;
      }
    }
    const int pct = static_cast<int>(
        std::sqrt(std::min(peak, 32767) / 32767.0) * 100.0);
    std::vector<int> batch;
    int64_t batch_pts = 0;
    {
      std::lock_guard<std::mutex> lock(mtx_);
      if (batch_.empty()) {
        batch_pts_ = pts;
      }
      batch_.push_back(pct);
      if (batch_.size() < 5) {
        return;
      }
      batch_pts = batch_pts_;
      batch.swap(batch_);
    }
    post(batch_pts, batch);
  }

  // 收尾排空未满批; tap 线程已 join 后调用
  void flush() {
    std::vector<int> batch;
    int64_t pts = 0;
    {
      std::lock_guard<std::mutex> lock(mtx_);
      if (batch_.empty()) {
        return;
      }
      pts = batch_pts_;
      batch.swap(batch_);
    }
    post(pts, batch);
  }

 private:
  void post(int64_t pts, const std::vector<int>& peaks) {
    json j;
    j["v"] = 1;
    j["seq"] = next_seq();
    j["ts_ms"] = now_ms();
    j["task_id"] = task_id_;
    j["run_id"] = run_id_;
    j["group_id"] = group_id_.empty() ? json(nullptr) : json(group_id_);
    j["kind"] = kind_;
    j["type"] = "wave";
    j["bucket_ms"] = 100;
    j["pts_ms"] = pts;
    j["peaks"] = peaks;
    event_post(j.dump());
  }

  const int64_t task_id_;
  const int64_t run_id_;
  const std::string group_id_;
  const std::string kind_;
  std::atomic<int64_t>* decoded_ms_ = nullptr;
  std::atomic<int64_t>* decoded_base_ms_ = nullptr;
  std::mutex mtx_;
  std::vector<int> batch_;
  int64_t batch_pts_ = 0;
};

// 识别回调只收最终段; 文本在回调内拷贝, 不跨线程持有引擎指针
class AsrCollector : public IAudioSttOb {
 public:
  struct Cue {
    int64_t start_ms = 0;
    int64_t end_ms = 0;
    std::string text;
  };

  void onResult(const SttResult& result, const char* text) override {
    if (!text || text[0] == '\0' || !result.isFinal) {
      return;
    }
    Cue cue;
    cue.start_ms = result.startPts;
    cue.end_ms = result.endPts;
    if (cue.end_ms <= cue.start_ms) {
      cue.end_ms = cue.start_ms + 1;
    }
    cue.text = text;
    std::lock_guard<std::mutex> lock(mtx_);
    cues_.push_back(std::move(cue));
  }

  std::vector<Cue> take() {
    std::lock_guard<std::mutex> lock(mtx_);
    return std::move(cues_);
  }

 private:
  std::mutex mtx_;
  std::vector<Cue> cues_;
};

// tap 输出与 STT 输入同为 16k/mono/S16, 直接喂识别器
class AsrTap : public IAudioTapOb {
 public:
  explicit AsrTap(IAudioStt* stt) : stt_(stt) {}
  void onFrame(const AvoxData& raw, int64_t pts) override {
    if (stt_) {
      stt_->recognize(raw, pts);
    }
  }

 private:
  IAudioStt* stt_ = nullptr;
};

class RecorderObserver;

struct Task {
  int64_t id = 0;
  int64_t run_id = 1;
  std::string kind;
  std::string group_id;
  std::string input;
  std::string output;
  std::string temp;
  // ASR 的音频旁路产物; 与 SRT 输出分开, 完成后删除
  std::string media_temp;
  std::string subtitle_mode;  // embedded | asr
  int32_t subtitle_index = -1;

  // 图像修复(去水印)
  ImageOptions image;

  VCodecId vcodec = VCodecId::h264;
  ACodecId acodec = ACodecId::aac;
  TransMode trans_mode = TransMode::TranscodeAll;
  EncodeRateMode rate_mode = EncodeRateMode::quality;
  int32_t quality = 60;
  int32_t bitrate_kbps = 0;
  int32_t audio_bitrate_kbps = -1;
  int32_t audio_sample_rate = 0;
  int32_t audio_channels = 0;
  int32_t out_width = 0;
  int32_t out_height = 0;
  bool audio_copy = false;
  bool hardware = false;
  bool overwrite = false;

  // 片段截取: 只走 seek 起点 + 到点关录制, 不另建 kind 流水线
  bool trim = false;
  int64_t trim_start_ms = 0;
  int64_t trim_end_ms = 0;
  int64_t source_duration_ms = 0;
  std::atomic<int64_t> progress_ms{-1};
  // 解码侧音频 pts(原始)与首帧基准; 截取出点用, 无音轨时保持 -1
  std::atomic<int64_t> decoded_ms{-1};
  std::atomic<int64_t> decoded_base_ms{-1};

  std::atomic<int> state{kQueued};
  std::mutex mtx;
  std::condition_variable cv;
  bool cancel_requested = false;
  bool finished = false;
  bool drained = false;
  bool completed_ok = false;
  std::string error_code;
  std::string error_message;
  std::string error_detail;
  std::atomic<int64_t> total_ms{-1};
  std::atomic<int64_t> last_emit_ms{0};
  std::atomic<bool> terminal_emitted{false};

  std::mutex recorder_mtx;
  IRecorder* recorder = nullptr;
  bool close_called = false;
  std::shared_ptr<RecorderObserver> observer;
  std::shared_ptr<WaveTap> wave;
  void* preview_hwnd = nullptr;
  // 录制器真正进入 recording 后才允许接管预览面: state=kRunning 在 open
  // 阶段就置了, 此时 onStart 还会 setOffSurface, 先挂面会被拆掉
  std::atomic<bool> recording{false};
};

json base_event(const Task& task, const char* type) {
  json j;
  j["v"] = 1;
  j["seq"] = next_seq();
  j["ts_ms"] = now_ms();
  j["task_id"] = task.id;
  j["run_id"] = task.run_id;
  j["group_id"] = task.group_id.empty() ? json(nullptr) : json(task.group_id);
  j["kind"] = task.kind;
  j["type"] = type;
  return j;
}

void emit_state(const Task& task, const char* state, const char* stage,
                int64_t queue_position = 0) {
  if (task.terminal_emitted.load()) {
    return;
  }
  json j = base_event(task, "state");
  j["state"] = state;
  if (stage && *stage) {
    j["stage"] = stage;
  }
  if (queue_position > 0) {
    j["queue_position"] = queue_position;
  }
  event_post(j.dump());
}

void emit_progress(Task& task, int64_t current_ms, int64_t total_ms) {
  if (task.terminal_emitted.load() || task.cancel_requested) {
    return;
  }
  json j = base_event(task, "progress");
  j["current_ms"] = current_ms;
  if (total_ms > 0) {
    j["total_ms"] = total_ms;
    double pct = static_cast<double>(current_ms) * 100.0 /
                 static_cast<double>(total_ms);
    pct = std::max(0.0, std::min(100.0, pct));
    j["pct"] = pct;
  }
  event_post(j.dump());
}

const char* category_for(const std::string& code) {
  if (code == "bad_source" || code == "input_not_found" ||
      code == "input_open_failed" || code == "input_corrupt") {
    return "input";
  }
  if (code == "output_exists" || code == "output_not_writable" ||
      code == "output_finalize_failed" || code == "bad_output") {
    return "output";
  }
  if (code == "decode_failed" || code == "encode_failed" ||
      code == "mux_failed" || code == "audio_missing") {
    return "codec";
  }
  if (code == "cancelled") {
    return "cancel";
  }
  if (code == "no_subtitle_track" || code == "no_subtitle_text" ||
      code == "bitmap_subtitle" || code == "no_speech" ||
      code == "subtitle_export_failed" || code == "subtitle_write_failed") {
    return "subtitle";
  }
  if (code == "no_watermark" || code == "mask_load_failed" ||
      code == "image_decode_failed" || code == "image_encode_failed" ||
      code == "inpaint_failed") {
    return "image";
  }
  if (code == "engine_mismatch" || code == "ffmpeg_mismatch" ||
      code == "model_missing" || code == "stt_unavailable" ||
      code == "inpaint_unavailable") {
    return "environment";
  }
  return "internal";
}

bool retryable_for(const std::string& code) {
  return code == "output_finalize_failed" || code == "internal" ||
         code == "cancelled" || code == "drain_timeout" ||
         code == "subtitle_export_failed" || code == "subtitle_write_failed" ||
         code == "inpaint_failed" || code == "image_encode_failed";
}

const char* hint_for(const std::string& code) {
  if (code == "bad_source" || code == "input_not_found" ||
      code == "input_open_failed") {
    return "choose_file";
  }
  if (code == "output_exists" || code == "output_not_writable" ||
      code == "bad_output" || code == "output_finalize_failed") {
    return "choose_output";
  }
  if (code == "internal" || code == "encode_failed" ||
      code == "decode_failed" || code == "audio_missing") {
    return "open_log_dir";
  }
  if (code == "model_missing") {
    return "download_model";
  }
  if (code == "inpaint_unavailable") {
    return "download_model";
  }
  if (code == "no_watermark" || code == "mask_load_failed" ||
      code == "image_decode_failed") {
    return "use_mask";
  }
  if (code == "bitmap_subtitle" || code == "no_subtitle_track" ||
      code == "no_subtitle_text") {
    return "use_asr";
  }
  return "retry";
}

// 音频编码器打不开时引擎只记一条日志, 录制器照常收尾; 没音轨的产物不能报成功
bool output_has_audio(const std::string& path) {
  const char* raw = ak_probe(path.c_str());
  if (!raw) {
    return true;
  }
  json j = json::parse(raw, nullptr, false);
  ak_free_string(raw);
  if (j.is_discarded() || !j.contains("audio") || !j["audio"].is_array()) {
    return true;  // 探测失败不冒判失败
  }
  return !j["audio"].empty();
}

void emit_error(Task& task, const char* code, const char* message,
                const char* detail) {
  bool expected = false;
  if (!task.terminal_emitted.compare_exchange_strong(expected, true)) {
    return;
  }
  task.state.store(kTerminal);
  json j = base_event(task, "error");
  j["code"] = code ? code : "internal";
  j["category"] = category_for(code ? code : "internal");
  j["retryable"] = retryable_for(code ? code : "internal");
  j["message"] = message ? message : "Task failed";
  if (detail && *detail) {
    j["detail"] = detail;
  }
  j["hint"] = hint_for(code ? code : "internal");
  event_post(j.dump());
}

void emit_done(Task& task) {
  bool expected = false;
  if (!task.terminal_emitted.compare_exchange_strong(expected, true)) {
    return;
  }
  task.state.store(kTerminal);
  json j = base_event(task, "done");
  j["outputs"] = json::array({{{"role", "primary"}, {"path", task.output}}});
  const int64_t total = task.total_ms.load();
  j["duration_ms"] = total > 0 ? total : 0;
  if (task.trim) {
    j["trim"] = {{"start_ms", task.trim_start_ms},
                 {"end_ms", task.trim_end_ms}};
  }
  event_post(j.dump());
}

void emit_cancelled(Task& task) {
  bool expected = false;
  if (!task.terminal_emitted.compare_exchange_strong(expected, true)) {
    return;
  }
  task.state.store(kTerminal);
  json j = base_event(task, "state");
  j["state"] = "cancelled";
  event_post(j.dump());
}

class RecorderObserver : public IRecorderOb {
 public:
  explicit RecorderObserver(std::weak_ptr<Task> task) : task_(std::move(task)) {}

  void onStateChange(RecorderState, RecorderState state) override {
    auto task = task_.lock();
    if (!task) {
      return;
    }
    if (state == RecorderState::recording) {
      task->state.store(kRunning);
      task->recording.store(true);
      emit_state(*task, "running", "recording");
      // onReady 的 setOffSurface 已落位, 此时直接挂面即可
      preview_request_attach(task->id);
    } else if (state == RecorderState::completed) {
      task->recording.store(false);
      std::lock_guard<std::mutex> lock(task->mtx);
      task->drained = true;
      task->cv.notify_all();
    } else if (state == RecorderState::failed) {
      task->recording.store(false);
      std::lock_guard<std::mutex> lock(task->mtx);
      if (task->error_code.empty()) {
        task->error_code = "internal";
        task->error_message = "Recorder failed";
      }
      task->drained = true;
      task->finished = true;
      task->cv.notify_all();
    }
  }

  void onProgress(const RecorderProgress& progress) override {
    auto task = task_.lock();
    if (!task || progress.currentTimeMs < 0) {
      return;
    }
    // 截取监控每 40ms 读一次, 不能等 200ms 的节流。
    // startFrac 定位后引擎的 currentTimeMs 已相对落点, 不再减 trim_start。
    task->progress_ms.store(progress.currentTimeMs);
    const int64_t now = now_ms();
    int64_t last = task->last_emit_ms.load();
    if (now - last < 200) {
      return;
    }
    if (!task->last_emit_ms.compare_exchange_strong(last, now)) {
      return;
    }
    if (task->trim) {
      const int64_t span = task->trim_end_ms - task->trim_start_ms;
      const int64_t decoded = task->decoded_ms.load();
      const int64_t base = task->decoded_base_ms.load();
      int64_t current = (decoded != -1 && base != -1)
                            ? decoded - base
                            : progress.currentTimeMs;
      if (current < 0) {
        current = 0;
      }
      if (current > span) {
        current = span;
      }
      task->total_ms.store(span);
      emit_progress(*task, current, span);
      return;
    }
    if (progress.totalTimeMs > 0) {
      task->total_ms.store(progress.totalTimeMs);
    }
    emit_progress(*task, progress.currentTimeMs, progress.totalTimeMs);
  }

  void onIoError(AVError error, const char* message) override {
    auto task = task_.lock();
    if (!task) {
      return;
    }
    std::lock_guard<std::mutex> lock(task->mtx);
    if (task->error_code.empty()) {
      const bool opening = task->state.load() == kStarting ||
                           task->state.load() == kQueued;
      task->error_code = opening ? "input_open_failed" : "decode_failed";
      task->error_message = opening ? "Cannot open input" : "Decode failed";
      task->error_detail =
          message && *message
              ? message
              : ("AVError " + std::to_string(static_cast<int>(error)));
    }
    task->finished = true;
    task->cv.notify_all();
  }

  void onEncodeError(TrackType, EncodeResult error) override {
    auto task = task_.lock();
    if (!task) {
      return;
    }
    std::lock_guard<std::mutex> lock(task->mtx);
    if (task->error_code.empty()) {
      task->error_code = "encode_failed";
      task->error_message = "Encode failed";
      task->error_detail =
          "EncodeResult " + std::to_string(static_cast<int>(error));
    }
    task->finished = true;
    task->cv.notify_all();
  }

  void onComplete() override {
    auto task = task_.lock();
    if (!task) {
      return;
    }
    std::lock_guard<std::mutex> lock(task->mtx);
    task->completed_ok = true;
    task->drained = true;
    task->finished = true;
    task->cv.notify_all();
  }

 private:
  std::weak_ptr<Task> task_;
};

std::string jstr(const json& j, const char* key, const std::string& fallback) {
  if (j.contains(key) && j[key].is_string()) {
    return j[key].get<std::string>();
  }
  return fallback;
}

int32_t jint(const json& j, const char* key, int32_t fallback) {
  if (j.contains(key) && j[key].is_number_integer()) {
    return j[key].get<int32_t>();
  }
  return fallback;
}

int64_t jint64(const json& j, const char* key, int64_t fallback) {
  if (j.contains(key) && j[key].is_number_integer()) {
    return j[key].get<int64_t>();
  }
  return fallback;
}

bool jbool(const json& j, const char* key, bool fallback) {
  if (j.contains(key) && j[key].is_boolean()) {
    return j[key].get<bool>();
  }
  return fallback;
}

// libmp3lame 只收 8/11.025/12/16/22.05/24/32/44.1/48 kHz
int32_t mp3_sample_rate(int32_t rate) {
  switch (rate) {
    case 8000:
    case 11025:
    case 12000:
    case 16000:
    case 22050:
    case 24000:
    case 32000:
    case 44100:
    case 48000:
      return rate;
    default:
      return rate > 44100 ? 48000 : 44100;
  }
}

std::filesystem::path canonical_path(const std::filesystem::path& path) {
  std::error_code ec;
  auto canonical = std::filesystem::weakly_canonical(path, ec);
  if (!ec) {
    return canonical;
  }
  ec.clear();
  auto absolute = std::filesystem::absolute(path, ec);
  return ec ? path : absolute;
}

bool same_path(const std::filesystem::path& a,
               const std::filesystem::path& b) {
  std::string left = canonical_path(a).u8string();
  std::string right = canonical_path(b).u8string();
#ifdef _WIN32
  std::transform(left.begin(), left.end(), left.begin(),
                 [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
  std::transform(right.begin(), right.end(), right.begin(),
                 [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
#endif
  return left == right;
}

std::wstring utf8_to_wide(const std::string& value) {
#ifdef _WIN32
  if (value.empty()) {
    return {};
  }
  const int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                         value.data(),
                                         static_cast<int>(value.size()),
                                         nullptr, 0);
  if (length <= 0) {
    return {};
  }
  std::wstring result(static_cast<size_t>(length), L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                      static_cast<int>(value.size()), result.data(), length);
  return result;
#else
  (void)value;
  return {};
#endif
}

std::shared_ptr<Task> parse_task(const std::string& text, int32_t& code,
                                 std::string& error) {
  json root;
  try {
    root = json::parse(text);
  } catch (const std::exception& e) {
    code = AK_E_BAD_JSON;
    error = e.what();
    return nullptr;
  }
  if (!root.is_object()) {
    code = AK_E_BAD_JSON;
    error = "task must be a JSON object";
    return nullptr;
  }

  const std::string kind = jstr(root, "kind", "");
  if (kind != "transcode" && kind != "remux" && kind != "extract" &&
      kind != "subtitle" && kind != "trim" && kind != "image") {
    code = kind.empty() ? AK_E_BAD_JSON : AK_E_UNSUPPORTED_KIND;
    error = "unsupported kind: " + kind;
    return nullptr;
  }
  std::string group_id;
  if (root.contains("group_id")) {
    if (root["group_id"].is_string()) {
      group_id = root["group_id"].get<std::string>();
    } else if (root["group_id"].is_number_integer()) {
      group_id = std::to_string(root["group_id"].get<int64_t>());
    }
  }

  json params = json::object();
  if (root.contains("params") && root["params"].is_object()) {
    params = root["params"];
  }

  json source = json::object();
  if (root.contains("sources") && root["sources"].is_array() &&
      !root["sources"].empty() && root["sources"][0].is_object()) {
    source = root["sources"][0];
  } else if (root.contains("source") && root["source"].is_object()) {
    source = root["source"];
  }
  const std::string source_kind = jstr(source, "kind", "file");
  if (source_kind != "file") {
    code = AK_E_BAD_SOURCE;
    error = "only file sources are supported in M1";
    return nullptr;
  }
  const std::string input = jstr(source, "uri", "");
  if (input.empty()) {
    code = AK_E_BAD_SOURCE;
    error = "source.uri is required";
    return nullptr;
  }

  std::string output;
  if (root.contains("outputs") && root["outputs"].is_array() &&
      !root["outputs"].empty() && root["outputs"][0].is_object()) {
    output = jstr(root["outputs"][0], "path", "");
  }
  if (output.empty()) {
    output = jstr(root, "output", "");
  }
  if (output.empty()) {
    output = jstr(params, "output", "");
  }
  if (output.empty()) {
    code = AK_E_BAD_OUTPUT;
    error = "output path is required";
    return nullptr;
  }

  json video = json::object();
  if (params.contains("video") && params["video"].is_object()) {
    video = params["video"];
  } else if (root.contains("video") && root["video"].is_object()) {
    video = root["video"];
  }
  json audio = json::object();
  if (params.contains("audio") && params["audio"].is_object()) {
    audio = params["audio"];
  } else if (root.contains("audio") && root["audio"].is_object()) {
    audio = root["audio"];
  }

  VCodecId vcodec = VCodecId::h264;
  const std::string video_codec = jstr(video, "codec", "h264");
  if (video_codec == "h264" || video_codec == "avc") {
    vcodec = VCodecId::h264;
  } else if (video_codec == "hevc" || video_codec == "h265") {
    vcodec = VCodecId::h265;
  } else {
    code = AK_E_UNSUPPORTED_KIND;
    error = "unsupported video codec: " + video_codec;
    return nullptr;
  }

  ACodecId acodec = ACodecId::aac;
  bool audio_copy = false;
  const std::string audio_codec = jstr(audio, "codec", "aac");
  if (audio_codec == "aac") {
    acodec = ACodecId::aac;
  } else if (audio_codec == "mp3") {
    acodec = ACodecId::mp3;
  } else if (audio_codec == "none") {
    acodec = ACodecId::none;
  } else if (audio_codec == "copy" && kind == "extract") {
    audio_copy = true;
  } else {
    code = AK_E_UNSUPPORTED_KIND;
    error = "unsupported audio codec: " + audio_codec;
    return nullptr;
  }

  EncodeRateMode rate_mode = EncodeRateMode::quality;
  const std::string rate = jstr(video, "rate_mode", "quality");
  if (rate == "vbr") {
    rate_mode = EncodeRateMode::vbr;
  } else if (rate == "cbr") {
    rate_mode = EncodeRateMode::cbr;
  } else if (rate != "quality") {
    code = AK_E_BAD_JSON;
    error = "unsupported rate_mode: " + rate;
    return nullptr;
  }

  // 默认软编: 画质和体积最可控; 硬编需调用方显式 opt-in
  const std::string hardware_mode = jstr(video, "hardware", "off");
  bool hardware = false;
  if (hardware_mode == "off" || hardware_mode == "disabled") {
    hardware = false;
  } else if (hardware_mode != "auto" && hardware_mode != "on") {
    code = AK_E_BAD_JSON;
    error = "unsupported hardware mode: " + hardware_mode;
    return nullptr;
  }

  int32_t quality = jint(video, "quality", 60);
  quality = std::max(0, std::min(100, quality));
  int32_t bitrate_kbps = std::max(0, jint(video, "bitrate_kbps", 0));
  int32_t audio_bitrate = jint(audio, "bitrate_kbps", -1);
  audio_bitrate = std::max(-1, std::min(1024, audio_bitrate));
  int32_t audio_sample_rate = 0;
  int32_t audio_channels = 0;
  const bool overwrite = jbool(params, "overwrite", false);
  const std::string container = jstr(params, "container", "mp4");

  std::string subtitle_mode = "auto";
  int32_t subtitle_index = -1;
  bool subtitle_allow_asr = true;
  if (kind == "subtitle") {
    json subtitle = json::object();
    if (params.contains("subtitle") && params["subtitle"].is_object()) {
      subtitle = params["subtitle"];
    }
    subtitle_mode = jstr(subtitle, "mode", "auto");
    if (subtitle_mode != "auto" && subtitle_mode != "embedded" &&
        subtitle_mode != "asr") {
      code = AK_E_BAD_JSON;
      error = "unsupported subtitle mode: " + subtitle_mode;
      return nullptr;
    }
    subtitle_index = jint(subtitle, "stream_index", -1);
    subtitle_allow_asr = jbool(subtitle, "allow_asr", true);
  }

  TransMode trans_mode = TransMode::TranscodeAll;
  const std::string trans = jstr(params, "trans_mode", "all");
  if (trans == "all") {
    trans_mode = TransMode::TranscodeAll;
  } else if (trans == "audio_copy") {
    trans_mode = TransMode::AudioCopy;
  } else if (trans == "video_copy") {
    trans_mode = TransMode::VideoCopy;
  } else {
    code = AK_E_BAD_JSON;
    error = "unsupported trans_mode: " + trans;
    return nullptr;
  }

  int32_t out_width = std::max(0, jint(video, "width", 0));
  int32_t out_height = std::max(0, jint(video, "height", 0));
  if ((out_width == 0) != (out_height == 0)) {
    code = AK_E_BAD_JSON;
    error = "video width and height must be set together";
    return nullptr;
  }
  if (out_width > 0) {
    if (out_width < 2 || out_height < 2 || (out_width & 1) || (out_height & 1)) {
      code = AK_E_BAD_JSON;
      error = "video width/height must be even and >= 2";
      return nullptr;
    }
    if (trans_mode == TransMode::VideoCopy) {
      code = AK_E_BAD_JSON;
      error = "video_copy cannot change resolution";
      return nullptr;
    }
  }
  if (trans_mode == TransMode::AudioCopy && acodec == ACodecId::none) {
    code = AK_E_BAD_JSON;
    error = "audio_copy requires an audio codec";
    return nullptr;
  }

  std::error_code ec;
  auto input_path = std::filesystem::u8path(input);
  if (!std::filesystem::exists(input_path, ec) || ec ||
      !std::filesystem::is_regular_file(input_path, ec)) {
    code = AK_E_BAD_SOURCE;
    error = "input file not found: " + input;
    return nullptr;
  }
  int64_t trim_start_ms = 0;
  int64_t trim_end_ms = 0;
  int64_t source_duration_ms = 0;
  if (kind == "trim") {
    json trim = json::object();
    if (params.contains("trim") && params["trim"].is_object()) {
      trim = params["trim"];
    }
    trim_start_ms = jint64(trim, "start_ms", -1);
    trim_end_ms = jint64(trim, "end_ms", -1);
    if (trim_start_ms < 0 || trim_end_ms <= trim_start_ms) {
      code = AK_E_BAD_JSON;
      error = "trim.start_ms/end_ms required and end must be after start";
      return nullptr;
    }
    const json probe = json::parse(probe_uri_json(input), nullptr, false);
    if (!probe.is_object() || !probe.value("ok", false)) {
      code = AK_E_BAD_SOURCE;
      error = "cannot probe input for trim";
      return nullptr;
    }
    source_duration_ms = probe.value("duration_ms", int64_t{0});
    if (source_duration_ms <= 0) {
      code = AK_E_BAD_SOURCE;
      error = "cannot trim a source with unknown duration";
      return nullptr;
    }
    if (trim_start_ms >= source_duration_ms) {
      code = AK_E_BAD_JSON;
      error = "trim.start_ms is past the end of the source";
      return nullptr;
    }
    // io.startFrac 内部把比例钳到 0.9; 超出的起点会被静默拉回, 不如直接拒绝
    if (trim_start_ms * 10 > source_duration_ms * 9) {
      code = AK_E_BAD_JSON;
      error = "trim.start_ms must be within the first 90% of the source";
      return nullptr;
    }
    if (trim_end_ms > source_duration_ms) {
      trim_end_ms = source_duration_ms;
    }
    if (trim_end_ms - trim_start_ms < 40) {
      code = AK_E_BAD_JSON;
      error = "trim range is too short";
      return nullptr;
    }
    // 源没音轨时关掉音频编码, 否则产物无音轨会被当成编码失败
    if (!probe.contains("audio") || !probe["audio"].is_array() ||
        probe["audio"].empty()) {
      acodec = ACodecId::none;
    }
  }
  if (kind == "extract") {
    if (acodec == ACodecId::none) {
      code = AK_E_BAD_JSON;
      error = "extract requires an audio codec";
      return nullptr;
    }    // 提交前拦掉无音轨, 比开完再失败的报错清楚; 顺带取源音频规格
    const json probe = json::parse(probe_uri_json(input), nullptr, false);
    if (probe.is_object() && probe.value("ok", false)) {
      if (!probe.contains("audio") || !probe["audio"].is_array() ||
          probe["audio"].empty()) {
        code = AK_E_BAD_SOURCE;
        error = "input has no audio track";
        return nullptr;
      }
      const json& track = probe["audio"][0];
      if (track.contains("sample_rate") && track["sample_rate"].is_number()) {
        audio_sample_rate = track["sample_rate"].get<int32_t>();
      }
      if (track.contains("channels") && track["channels"].is_number()) {
        audio_channels = track["channels"].get<int32_t>();
      }
    }
  }
  if (kind == "subtitle") {
    const json probe = json::parse(probe_uri_json(input), nullptr, false);
    if (!probe.is_object() || !probe.value("ok", false)) {
      code = AK_E_BAD_SOURCE;
      error = "cannot probe input for subtitle tracks";
      return nullptr;
    }    const json tracks = probe.value("subtitles", json::array());
    const auto text_track = [](const json& track) {
      return track.value("text", false);
    };
    int32_t chosen = -1;
    if (subtitle_mode != "asr") {
      if (subtitle_index >= 0) {
        for (const auto& track : tracks) {
          if (track.value("index", -1) == subtitle_index) {
            if (!text_track(track)) {
              code = AK_E_NO_SUBTITLE;
              error = "selected subtitle track is bitmap, not text";
              return nullptr;
            }
            chosen = subtitle_index;
            break;
          }
        }
        if (chosen < 0) {
          code = AK_E_NO_SUBTITLE;
          error = "subtitle track not found";
          return nullptr;
        }
      } else {
        // 先找默认文本轨, 再退回第一条文本轨
        for (const auto& track : tracks) {
          if (text_track(track) && track.value("default", false)) {
            chosen = track.value("index", -1);
            break;
          }
        }
        if (chosen < 0) {
          for (const auto& track : tracks) {
            if (text_track(track)) {
              chosen = track.value("index", -1);
              break;
            }
          }
        }
      }
    }
    if (chosen >= 0) {
      subtitle_mode = "embedded";
      subtitle_index = chosen;
    } else if (subtitle_mode == "asr" ||
               (subtitle_mode == "auto" && subtitle_allow_asr)) {
      subtitle_mode = "asr";
      if (!probe.contains("audio") || !probe["audio"].is_array() ||
          probe["audio"].empty()) {
        code = AK_E_BAD_SOURCE;
        error = "input has no audio track for speech recognition";
        return nullptr;
      }
      const auto model_exists = [](const char* rel) {
        const std::string path = avox::getModelFilePath(rel);
        std::error_code model_ec;
        return !path.empty() &&
               std::filesystem::exists(std::filesystem::u8path(path),
                                       model_ec) &&
               !model_ec;
      };
      if (!model_exists("stt/sense-voice/model.int8.onnx") ||
          !model_exists("stt/sense-voice/tokens.txt") ||
          !model_exists("stt/sense-voice/silero_vad.onnx")) {
        code = AK_E_MODEL_MISSING;
        error = "speech recognition model is not downloaded";
        return nullptr;
      }
    } else {
      code = AK_E_NO_SUBTITLE;
      error = "input has no text subtitle track";
      return nullptr;
    }
  }
  ImageOptions image;
  if (kind == "image") {
    json image_params = json::object();
    if (params.contains("image") && params["image"].is_object()) {
      image_params = params["image"];
    } else {
      image_params = params;
    }
    image.mode = jstr(image_params, "mode", "auto");
    if (image.mode != "auto" && image.mode != "mask") {
      code = AK_E_BAD_JSON;
      error = "unsupported image mode: " + image.mode;
      return nullptr;
    }
    image.model = jstr(image_params, "model", "lama");
    if (image.model != "lama" && image.model != "aotgan") {
      code = AK_E_BAD_JSON;
      error = "unsupported inpaint model: " + image.model;
      return nullptr;
    }
    image.dilate = std::max(0, std::min(64, jint(image_params, "dilate", 20)));
    if (image_params.contains("threshold") &&
        image_params["threshold"].is_number()) {
      image.threshold = std::max(
          0.0f, std::min(1.0f, image_params["threshold"].get<float>()));
    }
    if (image.mode == "mask") {
      image.mask_path = jstr(image_params, "mask_path", "");
      if (image.mask_path.empty()) {
        code = AK_E_BAD_JSON;
        error = "image.mask_path is required in mask mode";
        return nullptr;
      }
      const auto mask_file = std::filesystem::u8path(image.mask_path);
      if (!std::filesystem::exists(mask_file, ec) || ec) {
        code = AK_E_BAD_SOURCE;
        error = "mask image not found: " + image.mask_path;
        return nullptr;
      }
    }
    std::string missing;
    if (!image_models_ready(image.model, missing)) {
      code = AK_E_MODEL_MISSING;
      error = "image repair model is not downloaded: " + missing;
      return nullptr;
    }
  }
  auto output_path = std::filesystem::u8path(output);
  if (output_path.extension().empty()) {
    if (kind == "extract") {
      output_path += (acodec == ACodecId::mp3 && !audio_copy) ? ".mp3" : ".m4a";
    } else if (kind == "subtitle") {
      output_path += ".srt";
    } else if (kind == "image") {
      output_path += ".png";
    } else {
      output_path += (container == "matroska" || container == "mkv") ? ".mkv"
                                                                     : ".mp4";
    }
  }
  if (kind == "image") {
    std::string ext = output_path.extension().u8string();
    std::transform(ext.begin(), ext.end(), ext.begin(),
                   [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    if (ext != ".png" && ext != ".jpg" && ext != ".jpeg" && ext != ".bmp" &&
        ext != ".tga") {
      code = AK_E_BAD_OUTPUT;
      error = "unsupported image output extension: " + ext;
      return nullptr;
    }
  }
  ec.clear();
  auto absolute_output = std::filesystem::absolute(output_path, ec);
  if (!ec) {
    output_path = absolute_output;
  }
  std::string media_temp;
  if (kind == "subtitle" && subtitle_mode == "asr") {
    media_temp = (output_path.parent_path() /
                  (output_path.stem().u8string() + ".avoxkit-asr.m4a"))
                     .u8string();
  }
  if (std::filesystem::exists(output_path, ec) &&
      std::filesystem::is_directory(output_path, ec)) {
    code = AK_E_BAD_OUTPUT;
    error = "output path is a directory";
    return nullptr;
  }
  const auto parent = output_path.parent_path();
  if (!parent.empty() &&
      !std::filesystem::is_directory(parent, ec)) {
    code = AK_E_BAD_OUTPUT;
    error = "output directory does not exist";
    return nullptr;
  }
  if (!overwrite && std::filesystem::exists(output_path, ec)) {
    code = AK_E_BAD_OUTPUT;
    error = "output already exists";
    return nullptr;
  }
  if (same_path(input_path, output_path)) {
    code = AK_E_BAD_OUTPUT;
    error = "input and output must differ";
    return nullptr;
  }

  std::filesystem::path temp_path =
      output_path.parent_path() /
      (output_path.stem().u8string() + ".avoxkit-part" +
       output_path.extension().u8string());

  auto task = std::make_shared<Task>();
  task->kind = kind;
  task->group_id = group_id;
  task->input = input_path.u8string();
  task->output = output_path.u8string();
  task->temp = temp_path.u8string();
  task->media_temp = media_temp;
  task->subtitle_mode = subtitle_mode;
  task->subtitle_index = subtitle_index;
  task->image = image;
  task->vcodec = vcodec;
  task->acodec = acodec;
  task->trans_mode = trans_mode;
  task->out_width = out_width;
  task->out_height = out_height;
  task->rate_mode = rate_mode;
  task->quality = quality;
  task->bitrate_kbps = bitrate_kbps;
  task->audio_bitrate_kbps = audio_bitrate;
  task->audio_sample_rate = audio_sample_rate;
  task->audio_channels = audio_channels;
  task->audio_copy = audio_copy;
  task->hardware = hardware;
  task->trim = kind == "trim";
  task->trim_start_ms = trim_start_ms;
  task->trim_end_ms = trim_end_ms;
  task->source_duration_ms = source_duration_ms;
  task->overwrite = overwrite;
  task->observer = std::make_shared<RecorderObserver>(task);
  return task;
}

}  // namespace

class TaskRuntime {
 public:
  ~TaskRuntime() { stop(); }

  static TaskRuntime& instance() {
    static TaskRuntime runtime;
    return runtime;
  }

  void start() {
    std::lock_guard<std::mutex> lock(mtx_);
    if (running_) {
      return;
    }
    running_ = true;
    stopping_ = false;
    worker_ = std::thread([this] { worker(); });
  }

  void stop() {
    log(LogLevel::info, "task runtime stop begin");
    {
      std::lock_guard<std::mutex> lock(mtx_);
      if (!running_) {
        log(LogLevel::info, "task runtime stop: not running");
        return;
      }
      stopping_ = true;
    }

    std::vector<std::shared_ptr<Task>> snapshot;
    {
      std::lock_guard<std::mutex> lock(mtx_);
      snapshot.reserve(tasks_.size());
      for (auto& entry : tasks_) {
        snapshot.push_back(entry.second);
      }
    }
    for (auto& task : snapshot) {
      {
        std::lock_guard<std::mutex> lock(task->mtx);
        task->cancel_requested = true;
      }
      close_recorder(*task);
      emit_cancelled(*task);
      task->cv.notify_all();
    }
    cv_.notify_all();
    if (worker_.joinable()) {
      worker_.join();
    }
    std::lock_guard<std::mutex> lock(mtx_);
    queue_.clear();
    tasks_.clear();
    running_ = false;
    stopping_ = false;
    log(LogLevel::info, "task runtime stop done");
  }

  int64_t submit(const std::string& text, int32_t& code) {
    std::string error;
    auto task = parse_task(text, code, error);
    if (!task) {
      log(LogLevel::warn,
          std::string("task rejected: ") + error + " (" +
              error_name(code) + ")");
      return 0;
    }
    int64_t queue_position = 0;
    {
      std::lock_guard<std::mutex> lock(mtx_);
      if (!running_ || stopping_) {
        code = AK_E_NOT_INIT;
        return 0;
      }
      task->id = next_id_++;
      tasks_[task->id] = task;
      queue_.push_back(task);
      queue_position = static_cast<int64_t>(queue_.size());
      cv_.notify_one();
      log(LogLevel::info, "task queued id=" + std::to_string(task->id) +
                              " kind=" + task->kind + " input=" +
                              task->input);
    }
    emit_state(*task, "queued", nullptr, queue_position);
    return task->id;
  }

  int32_t cancel(int64_t id) {
    std::shared_ptr<Task> task;
    {
      std::lock_guard<std::mutex> lock(mtx_);
      auto it = tasks_.find(id);
      if (it == tasks_.end()) {
        return AK_E_NOT_FOUND;
      }
      task = it->second;
    }
    {
      std::lock_guard<std::mutex> lock(task->mtx);
      if (task->terminal_emitted.load()) {
        return AK_E_TASK_NOT_RUNNING;
      }
      if (task->cancel_requested) {
        return AK_OK;
      }
      task->cancel_requested = true;
    }
    close_recorder(*task);
    emit_cancelled(*task);
    task->cv.notify_all();
    log(LogLevel::info, "task cancel requested id=" + std::to_string(id));
    return AK_OK;
  }

  int32_t remove(int64_t id) {
    std::lock_guard<std::mutex> lock(mtx_);
    auto it = tasks_.find(id);
    if (it == tasks_.end()) {
      return AK_E_NOT_FOUND;
    }
    auto task = it->second;
    if (task->state.load() != kQueued) {
      return AK_E_TASK_NOT_RUNNING;
    }
    queue_.erase(std::remove(queue_.begin(), queue_.end(), task),
                 queue_.end());
    tasks_.erase(it);
    return AK_OK;
  }

  // 预览窗接管渲染面: 只切 surface, 呈现线程由 WindowRender 在拿到窗口时自启
  bool attach_preview(int64_t id, void* hwnd) {
    std::shared_ptr<Task> task;
    {
      std::lock_guard<std::mutex> lock(mtx_);
      auto it = tasks_.find(id);
      if (it == tasks_.end()) {
        return false;
      }
      task = it->second;
    }
    if (task->state.load() != kRunning || !task->recording.load()) {
      return false;
    }
    std::lock_guard<std::mutex> lock(task->recorder_mtx);
    if (!task->recorder || task->close_called) {
      return false;
    }
    ISurfaceRender* sr = task->recorder->getSurfaceRender();
    if (!sr) {
      return false;
    }
    // 同窗重绑不再碰 surface; 尺寸变化由呈现线程自己的 updateSize 处理
    if (task->preview_hwnd != hwnd) {
      sr->setSurface(hwnd);
      task->preview_hwnd = hwnd;
    }
    log(LogLevel::info, "preview surface attached, task=" + std::to_string(id));
    return true;
  }

  // 摘视口: 只把输出切回离屏 CPU, 呈现线程继续消费, 处理不受影响
  void detach_preview(int64_t id) {
    std::shared_ptr<Task> task;
    {
      std::lock_guard<std::mutex> lock(mtx_);
      auto it = tasks_.find(id);
      if (it == tasks_.end()) {
        return;
      }
      task = it->second;
    }
    if (task->state.load() != kRunning) {
      return;
    }
    std::lock_guard<std::mutex> lock(task->recorder_mtx);
    if (!task->recorder || task->close_called) {
      return;
    }
    if (ISurfaceRender* sr = task->recorder->getSurfaceRender()) {
      sr->setOffSurface(task->hardware ? YuvType::nv12 : YuvType::yuv420P);
      task->preview_hwnd = nullptr;
      log(LogLevel::info, "preview surface detached, task=" + std::to_string(id));
    }
  }

  // 波形只覆盖音频重新编码的任务; 直拷/封装没有 PCM
  void attach_wave(Task& task) {
    if (task.kind != "transcode" && task.kind != "extract" &&
        task.kind != "trim") {
      return;
    }
    if (task.kind == "extract" && task.audio_copy) {
      return;
    }
    IAudioRender* render = task.recorder ? task.recorder->getAudioRender()
                                         : nullptr;
    if (!render) {
      return;
    }
    auto tap = std::make_shared<WaveTap>(task.id, task.run_id, task.group_id,
                                         task.kind, &task.decoded_ms,
                                         &task.decoded_base_ms);
    addAudioTapOb(render, tap.get());
    AudioDesc out;
    out.channels = 1;
    out.format = AudioFormat::AVOX_AUDIO_S16;
    out.sampleRate = 16000;
    // 离线转码必须阻塞反压, 否则 tap 跟不上解码会丢掉大部分波形
    render->setTapBlock(true);
    render->openTap(out, 100);
    task.wave = std::move(tap);
  }

  // tap 线程停止后调用; remove 后再 flush, 避免收尾块丢失
  void drop_wave(Task& task) {
    if (!task.wave) {
      return;
    }
    if (task.recorder) {
      if (IAudioRender* render = task.recorder->getAudioRender()) {
        removeAudioTapOb(render, task.wave.get());
      }
    }
    task.wave->flush();
    task.wave.reset();
  }

 private:
  void worker() {
    for (;;) {
      std::shared_ptr<Task> task;
      {
        std::unique_lock<std::mutex> lock(mtx_);
        cv_.wait(lock, [this] { return stopping_ || !queue_.empty(); });
        if (stopping_) {
          std::deque<std::shared_ptr<Task>> pending;
          pending.swap(queue_);
          lock.unlock();
          for (auto& item : pending) {
            std::lock_guard<std::mutex> task_lock(item->mtx);
            item->cancel_requested = true;
            emit_cancelled(*item);
          }
          return;
        }
        task = queue_.front();
        queue_.pop_front();
      }
      if (task->cancel_requested) {
        emit_cancelled(*task);
        continue;
      }
      run_task(task);
    }
  }

  void close_recorder(Task& task) {
    std::lock_guard<std::mutex> lock(task.recorder_mtx);
    if (task.recorder && !task.close_called) {
      task.close_called = true;
      task.recording.store(false);
      // 先摘窗口再关源, 防 tick 撞上交换链销毁; 呈现线程随 recorder 析构停止
      if (ISurfaceRender* sr = task.recorder->getSurfaceRender()) {
        sr->setOffSurface(task.hardware ? YuvType::nv12 : YuvType::yuv420P);
      }
      task.recorder->close();
      task.preview_hwnd = nullptr;
      drop_wave(task);
    }
  }

  void cleanup_recorder(Task& task) {
    std::lock_guard<std::mutex> lock(task.recorder_mtx);
    if (!task.recorder) {
      return;
    }
    if (task.observer) {
      removeRecorderOb(task.recorder, task.observer.get());
    }
    drop_wave(task);
    // 让引擎回调线程离开 dispatch 后再析构; delete 会 join 其内部线程
    std::this_thread::sleep_for(std::chrono::milliseconds(20));
    delete task.recorder;
    task.recorder = nullptr;
    task.preview_hwnd = nullptr;
    task.close_called = false;
  }

  bool rename_output(Task& task, std::string& error) {
#ifdef _WIN32
    const auto from = utf8_to_wide(task.temp);
    const auto to = utf8_to_wide(task.output);
    if (from.empty() || to.empty()) {
      error = "path conversion failed";
      return false;
    }
    DWORD flags = MOVEFILE_WRITE_THROUGH;
    if (task.overwrite) {
      flags |= MOVEFILE_REPLACE_EXISTING;
    }
    if (!MoveFileExW(from.c_str(), to.c_str(), flags)) {
      error = "MoveFileExW failed, error=" +
              std::to_string(static_cast<unsigned long>(GetLastError()));
      return false;
    }
    return true;
#else
    std::error_code ec;
    std::filesystem::rename(std::filesystem::u8path(task.temp),
                            std::filesystem::u8path(task.output), ec);
    if (ec) {
      error = ec.message();
      return false;
    }
    return true;
#endif
  }

  void run_subtitle_embedded(Task& task) {
    task.state.store(kRunning);
    emit_state(task, "running", "subtitle_extract");
    const int32_t rc = avox::exportSubtitleTrack(
        task.input.c_str(), task.subtitle_index, task.temp.c_str());
    std::error_code ec;
    if (task.cancel_requested) {
      std::filesystem::remove(std::filesystem::u8path(task.temp), ec);
      emit_cancelled(task);
      return;
    }
    if (rc != 0) {
      std::filesystem::remove(std::filesystem::u8path(task.temp), ec);
      const char* code = "subtitle_export_failed";
      const char* message = "Subtitle export failed";
      switch (rc) {
        case -1:
          code = "input_open_failed";
          message = "Cannot open input";
          break;
        case -2:
          code = "no_subtitle_track";
          message = "Subtitle track not found";
          break;
        case -3:
          code = "bitmap_subtitle";
          message = "Bitmap subtitle cannot be exported as text";
          break;
        case -4:
          code = "decode_failed";
          message = "Subtitle decode failed";
          break;
        case -5:
          code = "subtitle_write_failed";
          message = "Cannot write subtitle file";
          break;
        case -6:
          code = "no_subtitle_text";
          message = "Subtitle track has no text";
          break;
        default:
          break;
      }
      emit_error(task, code, message, std::to_string(rc).c_str());
      return;
    }
    std::string move_error;
    if (!rename_output(task, move_error)) {
      emit_error(task, "output_finalize_failed", "Cannot finalize output",
                 move_error.c_str());
      return;
    }
    emit_done(task);
    log(LogLevel::info, "subtitle export done id=" + std::to_string(task.id) +
                            " output=" + task.output);
  }

  void run_subtitle_asr(Task& task) {
    std::error_code ec;
    std::filesystem::remove(std::filesystem::u8path(task.temp), ec);
    std::filesystem::remove(std::filesystem::u8path(task.media_temp), ec);

    IRecorder* recorder = createRecorder(true);
    if (!recorder) {
      emit_error(task, "internal", "Cannot create recorder", "");
      return;
    }
    {
      std::lock_guard<std::mutex> lock(task.recorder_mtx);
      task.recorder = recorder;
    }
    recorder->setMuxerType(MuxerType::ffmpeg);
    recorder->setVideoCodec(VCodecId::none);
    recorder->setAudioCodec(ACodecId::aac);
    AudioDesc encode_desc;
    encode_desc.channels = 1;
    encode_desc.sampleRate = 16000;
    encode_desc.format = AudioFormat::AVOX_AUDIO_FLTP;
    recorder->setAudioDesc(encode_desc);
    AudioEncodeParam audio_param;
    audio_param.bitrateKbps = 48;
    recorder->setAudioEncodeParam(audio_param);
    addRecorderOb(recorder, task.observer.get());

    if (!recorder->open(task.input.c_str(), task.media_temp.c_str())) {
      cleanup_recorder(task);
      std::filesystem::remove(std::filesystem::u8path(task.media_temp), ec);
      if (task.cancel_requested) {
        emit_cancelled(task);
      } else {
        emit_error(task, "input_open_failed", "Cannot open input",
                   task.input.c_str());
      }
      return;
    }
    task.state.store(kRunning);
    emit_state(task, "running", "recording");

    IAudioRender* render = recorder->getAudioRender();
    IAudioStt* stt = createAudioStt(AudioSttType::sherpa);
    if (!render || !stt) {
      if (stt) {
        delete stt;
      }
      close_recorder(task);
      cleanup_recorder(task);
      std::filesystem::remove(std::filesystem::u8path(task.media_temp), ec);
      emit_error(task, "stt_unavailable", "Speech recognition plugin unavailable",
                 "");
      return;
    }

    auto collector = std::make_shared<AsrCollector>();
    auto tap = std::make_shared<AsrTap>(stt);
    stt->setRecognizerType(RecognizerType::offline);
    AudioDesc tap_desc;
    tap_desc.channels = 1;
    tap_desc.sampleRate = 16000;
    tap_desc.format = AudioFormat::AVOX_AUDIO_S16;
    stt->setAudioDesc(tap_desc);
    addAudioSttOb(stt, collector.get());
    stt->start();
    addAudioTapOb(render, tap.get());
    render->setTapBlock(true);
    render->openTap(tap_desc, 100);

    {
      std::unique_lock<std::mutex> lock(task.mtx);
      task.cv.wait(lock,
                   [&] { return task.finished || task.cancel_requested; });
    }

    removeAudioTapOb(render, tap.get());
    stt->stop();
    removeAudioSttOb(stt, collector.get());
    delete stt;

    if (task.cancel_requested) {
      close_recorder(task);
      cleanup_recorder(task);
      std::filesystem::remove(std::filesystem::u8path(task.media_temp), ec);
      emit_cancelled(task);
      return;
    }

    if (!task.completed_ok) {
      const std::string error_code =
          task.error_code.empty() ? "internal" : task.error_code;
      const std::string error_message = task.error_message.empty()
                                            ? "Speech recognition failed"
                                            : task.error_message;
      const std::string error_detail = task.error_detail;
      cleanup_recorder(task);
      std::filesystem::remove(std::filesystem::u8path(task.media_temp), ec);
      emit_error(task, error_code.c_str(), error_message.c_str(),
                 error_detail.c_str());
      return;
    }

    const auto cues = collector->take();
    ISrtWriter* writer = createSrtWriter();
    int32_t count = 0;
    bool written = false;
    if (writer && writer->open(task.temp.c_str())) {
      for (const auto& cue : cues) {
        if (writer->add(cue.start_ms, cue.end_ms, cue.text.c_str())) {
          ++count;
        }
      }
      written = count > 0 && writer->close();
    }
    delete writer;

    cleanup_recorder(task);
    std::filesystem::remove(std::filesystem::u8path(task.media_temp), ec);
    if (!written) {
      std::filesystem::remove(std::filesystem::u8path(task.temp), ec);
      emit_error(task, "no_speech",
                 "No speech recognized in this file",
                 std::to_string(cues.size()).c_str());
      return;
    }
    std::string move_error;
    if (!rename_output(task, move_error)) {
      emit_error(task, "output_finalize_failed", "Cannot finalize output",
                 move_error.c_str());
      return;
    }
    log(LogLevel::info, "subtitle asr done id=" + std::to_string(task.id) +
                            " cues=" + std::to_string(count) + " output=" +
                            task.output);
    emit_done(task);
  }

  void run_subtitle(Task& task) {
    if (task.subtitle_mode == "asr") {
      run_subtitle_asr(task);
    } else {
      run_subtitle_embedded(task);
    }
  }

  static void image_stage(void* ctx, const char* name) {
    auto* task = static_cast<Task*>(ctx);
    emit_state(*task, "running", name);
  }

  static bool image_cancelled(void* ctx) {
    auto* task = static_cast<Task*>(ctx);
    return task->cancel_requested;
  }

  void run_image(Task& task) {
    const int64_t started = now_ms();
    task.state.store(kRunning);
    ImageCallbacks callbacks;
    callbacks.ctx = &task;
    callbacks.stage = &TaskRuntime::image_stage;
    callbacks.cancelled = &TaskRuntime::image_cancelled;
    const ImageRunResult result =
        image_repair(task.input, task.temp, task.image, callbacks);

    std::error_code ec;
    if (result.cancelled || task.cancel_requested) {
      std::filesystem::remove(std::filesystem::u8path(task.temp), ec);
      emit_cancelled(task);
      return;
    }
    if (!result.ok) {
      std::filesystem::remove(std::filesystem::u8path(task.temp), ec);
      emit_error(task,
                 result.code.empty() ? "image_failed" : result.code.c_str(),
                 result.message.empty() ? "Image repair failed"
                                        : result.message.c_str(),
                 result.detail.c_str());
      log(LogLevel::warn, "image task failed id=" + std::to_string(task.id) +
                              " code=" + result.code);
      return;
    }
    task.total_ms.store(std::max<int64_t>(0, now_ms() - started));
    std::string move_error;
    if (!rename_output(task, move_error)) {
      std::filesystem::remove(std::filesystem::u8path(task.temp), ec);
      emit_error(task, "output_finalize_failed", "Cannot finalize output",
                 move_error.c_str());
      return;
    }
    log(LogLevel::info, "image task done id=" + std::to_string(task.id) +
                            " watermarks=" + std::to_string(result.watermarks) +
                            " output=" + task.output);
    emit_done(task);
  }

  void run_task(std::shared_ptr<Task> task) {
    task->state.store(kStarting);
    emit_state(*task, "running", "opening");
    log(LogLevel::info, "task start id=" + std::to_string(task->id));

    std::error_code ec;
    if (!task->overwrite &&
        std::filesystem::exists(std::filesystem::u8path(task->output), ec)) {
      emit_error(*task, "output_exists", "Output already exists",
                 task->output.c_str());
      return;
    }
    std::filesystem::remove(std::filesystem::u8path(task->temp), ec);
    if (!task->media_temp.empty()) {
      std::filesystem::remove(std::filesystem::u8path(task->media_temp), ec);
    }
    if (task->kind == "subtitle") {
      run_subtitle(*task);
      return;
    }
    if (task->kind == "image") {
      run_image(*task);
      return;
    }

    const bool bTranscode = task->kind != "remux";
    IRecorder* recorder = createRecorder(bTranscode);
    if (!recorder) {
      emit_error(*task, "internal", "Cannot create recorder", "");
      return;
    }
    {
      std::lock_guard<std::mutex> lock(task->recorder_mtx);
      task->recorder = recorder;
    }

    recorder->setMuxerType(MuxerType::ffmpeg);
    if (task->kind == "extract") {
      // 丢视频轨; copy 走直拷(容器不收时引擎自动回退重编)
      recorder->setVideoCodec(VCodecId::none);
      if (task->audio_copy) {
        recorder->setTransMode(TransMode::AudioCopy);
      } else {
        recorder->setAudioCodec(task->acodec);
        // 引擎默认按源格式(flt)开 mp3 编码器会失败, 显式声明成它支持的计划
        if (task->acodec == ACodecId::mp3) {
          const int32_t channels =
              task->audio_channels > 0 ? task->audio_channels : 2;
          AudioDesc desc;
          desc.channels = static_cast<uint16_t>(std::min(channels, 2));
          desc.sampleRate =
              mp3_sample_rate(task->audio_sample_rate > 0
                                  ? task->audio_sample_rate
                                  : 44100);
          desc.format = AudioFormat::AVOX_AUDIO_FLTP;
          recorder->setAudioDesc(desc);
        }
        AudioEncodeParam audio_param;
        audio_param.bitrateKbps = task->audio_bitrate_kbps;
        recorder->setAudioEncodeParam(audio_param);
      }
    } else if (task->kind == "transcode" || task->kind == "trim") {
      recorder->setVideoCodec(task->vcodec);
      recorder->setAudioCodec(task->acodec);
      if (task->trans_mode != TransMode::TranscodeAll) {
        recorder->setTransMode(task->trans_mode);
      }
      if (task->out_width > 0 && task->out_height > 0) {
        VideoDesc desc;
        desc.width = task->out_width;
        desc.height = task->out_height;
        recorder->setVideoDesc(desc);
      }
      VideoEncodeParam video_param;
      video_param.rateMode = task->rate_mode;
      video_param.quality = task->quality;
      video_param.bitrateKbps = task->bitrate_kbps;
      video_param.usage = EncodeUsage::record;
      recorder->setVideoEncodeParam(video_param);
      AudioEncodeParam audio_param;
      audio_param.bitrateKbps = task->audio_bitrate_kbps;
      recorder->setAudioEncodeParam(audio_param);
      if (IOption* option = recorder->getOption()) {
        option->setBool("rec.hard.encode", task->hardware);
      }
    }
    // 截取的起点必须在开录前定位: 开录后再 seek 会把片头帧先写进产物。
    // startFrac 落目标前最近关键帧, 与时间线展示的关键帧对齐。
    if (task->trim && task->source_duration_ms > 0 &&
        task->trim_start_ms > 0) {
      double frac = static_cast<double>(task->trim_start_ms) /
                    static_cast<double>(task->source_duration_ms);
      frac = std::max(0.0, std::min(0.9, frac));
      if (frac > 0.0005) {
        if (IOption* option = recorder->getOption()) {
          option->setNumber("io.startFrac", frac);
        }
      }
    }
    addRecorderOb(recorder, task->observer.get());

    const bool opened = recorder->open(task->input.c_str(), task->temp.c_str());
    if (!opened) {
      if (task->cancel_requested) {
        emit_cancelled(*task);
        cleanup_recorder(*task);
        std::filesystem::remove(std::filesystem::u8path(task->temp), ec);
        return;
      }
      emit_error(*task, "input_open_failed", "Cannot open input",
                 task->input.c_str());
      cleanup_recorder(*task);
      std::filesystem::remove(std::filesystem::u8path(task->temp), ec);
      return;
    }
    task->state.store(kRunning);
    {
      std::lock_guard<std::mutex> lock(task->recorder_mtx);
      attach_wave(*task);
    }

    std::unique_lock<std::mutex> lock(task->mtx);
    while (!task->finished && !task->cancel_requested) {
      // 到出点主动关录制: close 走非 completed 分支清队, 不会把终点后的
      // 排队帧补进产物; 关闭后 onComplete 才置 finished。
      bool reached = false;
      if (task->trim) {
        const int64_t decoded = task->decoded_ms.load();
        const int64_t base = task->decoded_base_ms.load();
        if (decoded != -1 && base != -1) {
          // 解码出的音频位置相对首帧; 再往后编码队列还有少量在途数据,
          // 终点会有一小段偏差, 不承诺帧精确。
          const int64_t span = task->trim_end_ms - task->trim_start_ms;
          reached = decoded - base >= span;
        } else {
          const int64_t span = task->trim_end_ms - task->trim_start_ms;
          reached = task->progress_ms.load() >= span;
        }
      }
      if (reached) {
        lock.unlock();
        close_recorder(*task);
        lock.lock();
        task->cv.wait_for(
            lock, std::chrono::seconds(10),
            [&] { return task->finished || task->cancel_requested; });
        if (!task->finished && !task->cancel_requested) {
          if (task->error_code.empty()) {
            task->error_code = "trim_close_timeout";
            task->error_message = "Cannot stop trim at the requested end";
          }
          task->finished = true;
        }
        break;
      }
      // 5ms 轮询: 转码常跑到 30x 实时, 40ms 就会多录一秒
      task->cv.wait_for(lock, std::chrono::milliseconds(5));
    }

    if (task->cancel_requested) {
      lock.unlock();
      emit_cancelled(*task);
      close_recorder(*task);
      {
        std::unique_lock<std::mutex> wait_lock(task->mtx);
        task->cv.wait_for(wait_lock, std::chrono::seconds(5),
                          [&] { return task->drained; });
      }
      cleanup_recorder(*task);
      std::filesystem::remove(std::filesystem::u8path(task->temp), ec);
      log(LogLevel::info, "task cancelled id=" + std::to_string(task->id));
      return;
    }

    const bool completed = task->completed_ok;
    const std::string error_code = task->error_code;
    const std::string error_message = task->error_message;
    const std::string error_detail = task->error_detail;
    lock.unlock();

    cleanup_recorder(*task);

    if (completed) {
      const bool encodesAudio =
          (task->kind == "transcode" || task->kind == "extract" ||
           task->kind == "trim") &&
          task->acodec != ACodecId::none &&
          task->trans_mode != TransMode::AudioCopy && !task->audio_copy;
      if (encodesAudio && !output_has_audio(task->temp)) {
        std::filesystem::remove(std::filesystem::u8path(task->temp), ec);
        emit_error(*task, "audio_missing", "Audio track missing in output",
                   "audio encoder failed; check codec/channel support");
        log(LogLevel::error, "task failed id=" + std::to_string(task->id) +
                                 " code=audio_missing");
        return;
      }
      std::string move_error;
      if (rename_output(*task, move_error)) {
        emit_done(*task);
        log(LogLevel::info, "task done id=" + std::to_string(task->id) +
                                " output=" + task->output);
      } else {
        emit_error(*task, "output_finalize_failed",
                   "Cannot finalize output", move_error.c_str());
      }
      return;
    }

    std::filesystem::remove(std::filesystem::u8path(task->temp), ec);
    emit_error(*task, error_code.empty() ? "internal" : error_code.c_str(),
               error_message.empty() ? "Task failed" : error_message.c_str(),
               error_detail.c_str());
    log(LogLevel::warn, "task failed id=" + std::to_string(task->id) +
                            " code=" + error_code);
  }

  std::mutex mtx_;
  std::condition_variable cv_;
  std::deque<std::shared_ptr<Task>> queue_;
  std::unordered_map<int64_t, std::shared_ptr<Task>> tasks_;
  std::thread worker_;
  bool running_ = false;
  bool stopping_ = false;
  int64_t next_id_ = 1;
};

void task_start() {
  preview_set_hooks(
      [](int64_t id, void* hwnd) -> bool {
        return TaskRuntime::instance().attach_preview(id, hwnd);
      },
      [](int64_t id) { TaskRuntime::instance().detach_preview(id); });
  TaskRuntime::instance().start();
}

void task_stop() { TaskRuntime::instance().stop(); }

}  // namespace ak

extern "C" int64_t ak_task_submit(const char* task_json) {
  if (!ak::is_ready()) {
    return AK_E_NOT_INIT;
  }
  if (!task_json) {
    return AK_E_INVALID_ARG;
  }
  int32_t code = AK_OK;
  const int64_t id = ak::TaskRuntime::instance().submit(task_json, code);
  return id > 0 ? id : code;
}

extern "C" int32_t ak_task_cancel(int64_t task_id) {
  if (!ak::is_ready()) {
    return AK_E_NOT_INIT;
  }
  return ak::TaskRuntime::instance().cancel(task_id);
}

extern "C" int32_t ak_task_remove(int64_t task_id) {
  if (!ak::is_ready()) {
    return AK_E_NOT_INIT;
  }
  return ak::TaskRuntime::instance().remove(task_id);
}
