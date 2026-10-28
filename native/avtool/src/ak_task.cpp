#include "ak_internal.hpp"

#include <algorithm>
#include <atomic>
#include <cctype>
#include <chrono>
#include <condition_variable>
#include <deque>
#include <filesystem>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

#include <nlohmann/json.hpp>

#include "avox/AvoxBase.h"
#include "avox/AvoxMuxer.h"

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

class RecorderObserver;

struct Task {
  int64_t id = 0;
  int64_t run_id = 1;
  std::string kind;
  std::string group_id;
  std::string input;
  std::string output;
  std::string temp;

  VCodecId vcodec = VCodecId::h264;
  ACodecId acodec = ACodecId::aac;
  EncodeRateMode rate_mode = EncodeRateMode::quality;
  int32_t quality = 60;
  int32_t bitrate_kbps = 0;
  int32_t audio_bitrate_kbps = -1;
  int32_t audio_sample_rate = 0;
  int32_t audio_channels = 0;
  bool audio_copy = false;
  bool hardware = false;
  bool overwrite = false;

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

void emit_state(const Task& task, const char* state, const char* stage) {
  if (task.terminal_emitted.load()) {
    return;
  }
  json j = base_event(task, "state");
  j["state"] = state;
  if (stage && *stage) {
    j["stage"] = stage;
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
  if (code == "engine_mismatch" || code == "ffmpeg_mismatch") {
    return "environment";
  }
  return "internal";
}

bool retryable_for(const std::string& code) {
  return code == "output_finalize_failed" || code == "internal" ||
         code == "cancelled" || code == "drain_timeout";
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
      emit_state(*task, "running", "recording");
    } else if (state == RecorderState::completed) {
      std::lock_guard<std::mutex> lock(task->mtx);
      task->drained = true;
      task->cv.notify_all();
    } else if (state == RecorderState::failed) {
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
    const int64_t now = now_ms();
    int64_t last = task->last_emit_ms.load();
    if (now - last < 200) {
      return;
    }
    if (!task->last_emit_ms.compare_exchange_strong(last, now)) {
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
  if (kind != "transcode" && kind != "remux" && kind != "extract") {
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

  std::error_code ec;
  auto input_path = std::filesystem::u8path(input);
  if (!std::filesystem::exists(input_path, ec) || ec ||
      !std::filesystem::is_regular_file(input_path, ec)) {
    code = AK_E_BAD_SOURCE;
    error = "input file not found: " + input;
    return nullptr;
  }
  if (kind == "extract") {
    if (acodec == ACodecId::none) {
      code = AK_E_BAD_JSON;
      error = "extract requires an audio codec";
      return nullptr;
    }
    // 提交前拦掉无音轨, 比开完再失败的报错清楚; 顺带取源音频规格
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
  auto output_path = std::filesystem::u8path(output);
  if (output_path.extension().empty()) {
    if (kind == "extract") {
      output_path += (acodec == ACodecId::mp3 && !audio_copy) ? ".mp3" : ".m4a";
    } else {
      output_path += (container == "matroska" || container == "mkv") ? ".mkv"
                                                                     : ".mp4";
    }
  }
  ec.clear();
  auto absolute_output = std::filesystem::absolute(output_path, ec);
  if (!ec) {
    output_path = absolute_output;
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
  task->vcodec = vcodec;
  task->acodec = acodec;
  task->rate_mode = rate_mode;
  task->quality = quality;
  task->bitrate_kbps = bitrate_kbps;
  task->audio_bitrate_kbps = audio_bitrate;
  task->audio_sample_rate = audio_sample_rate;
  task->audio_channels = audio_channels;
  task->audio_copy = audio_copy;
  task->hardware = hardware;
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
    {
      std::lock_guard<std::mutex> lock(mtx_);
      if (!running_ || stopping_) {
        code = AK_E_NOT_INIT;
        return 0;
      }
      task->id = next_id_++;
      tasks_[task->id] = task;
      queue_.push_back(task);
      cv_.notify_one();
      log(LogLevel::info, "task queued id=" + std::to_string(task->id) +
                              " kind=" + task->kind + " input=" +
                              task->input);
    }
    emit_state(*task, "queued", nullptr);
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
      task.recorder->close();
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
    // 让引擎回调线程离开 dispatch 后再析构; delete 会 join 其内部线程
    std::this_thread::sleep_for(std::chrono::milliseconds(20));
    delete task.recorder;
    task.recorder = nullptr;
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
    } else if (task->kind == "transcode") {
      recorder->setVideoCodec(task->vcodec);
      recorder->setAudioCodec(task->acodec);
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

    std::unique_lock<std::mutex> lock(task->mtx);
    task->cv.wait(lock,
                  [&] { return task->finished || task->cancel_requested; });

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
          (task->kind == "transcode" || task->kind == "extract") &&
          task->acodec != ACodecId::none && !task->audio_copy;
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

void task_start() { TaskRuntime::instance().start(); }

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
