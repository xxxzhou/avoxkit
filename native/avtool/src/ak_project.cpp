// 录屏工程: 打开 session 目录、改场景/时间线、导出成片(方案 §9.1 / §7.3)。
// 导出不进通用任务队列: Task 只收单源 file, 工程导出是"视频 + 两轨 WAV"多输入;
// 这里单开线程, 事件沿用统一 JSON 通道(kind=project_state/project_error)。
#include "ak_internal.hpp"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include <nlohmann/json.hpp>

#include "avox/Avox.hpp"
#include "avox/AvoxCapture.h"
#include "avox/AvoxImage.h"

#include "ak_media_audio.hpp"

namespace {

using nlohmann::json;
using namespace std::chrono_literals;

std::mutex g_projMtx;
int64_t g_nextProjectId = 1;
int64_t g_nextExportId = 1;

json read_json_file(const std::string& path) {
  std::ifstream in(path, std::ios::binary);
  if (!in.is_open()) {
    return json();
  }
  return json::parse(in, nullptr, false);
}

bool write_json_file(const std::string& path, const json& value) {
  std::FILE* f = nullptr;
#ifdef _WIN32
  if (fopen_s(&f, path.c_str(), "wb") != 0 || !f) {
    return false;
  }
#else
  f = std::fopen(path.c_str(), "wb");
  if (!f) {
    return false;
  }
#endif
  const std::string text = value.dump(2);
  const bool ok = std::fwrite(text.data(), 1, text.size(), f) == text.size();
  std::fclose(f);
  return ok;
}

void merge_json(json& dst, const json& patch) {
  if (!dst.is_object() || !patch.is_object()) {
    dst = patch;
    return;
  }
  for (auto it = patch.begin(); it != patch.end(); ++it) {
    if (dst.contains(it.key()) && dst[it.key()].is_object() &&
        it.value().is_object()) {
      merge_json(dst[it.key()], it.value());
    } else {
      dst[it.key()] = it.value();
    }
  }
}

int32_t even_dim(int32_t value) { return value > 2 ? (value & ~1) : value; }

json default_project(const std::string& videoName, int32_t width,
                     int32_t height) {
  int32_t outW = 1920;
  int32_t outH = 1080;
  if (width > 0 && height > 0) {
    if (height > width) {
      outW = 1080;
      outH = 1920;
    } else if (std::abs(width - height) < width / 100) {
      outW = 1080;
      outH = 1080;
    }
  }
  return {
      {"version", 2},
      {"source", {{"video", videoName}, {"session", "session.json"}}},
      {"scene",
       {{"outputWidth", outW},
        {"outputHeight", outH},
        {"padding", 0.06},
        {"radius", 0.02},
        {"shadow",
         {{"radius", 0.03}, {"alpha", 0.45}, {"offsetX", 0.0},
          {"offsetY", 0.012}}},
        {"background",
         {{"mode", "gradient"},
          {"color", {0.09, 0.10, 0.14}},
          {"color2", {0.16, 0.18, 0.26}}}},
        {"cursorScale", 0.03}}},
      {"timeline",
       {{"cuts", json::array()},
        {"speed", json::array()},
        {"zoom",
         {{"mode", "auto"},
          {"maxZoom", 2.0},
          {"segments", json::array()}}}}},
      {"audio", json::array()}};
}

struct ExportJob {
  int64_t id = 0;
  int64_t projectId = 0;
  std::atomic<int> state{1};  // 1 running, 2 done, 3 failed, 4 cancelled
  std::atomic<int> pct{0};
  std::atomic<bool> cancel{false};
  std::mutex mtx;
  std::string stage = "video";
  std::string outPath;
  std::string error;
  std::string warning;
  std::thread thread;
};

struct Project {
  int64_t id = 0;
  std::string dir;
  std::string videoPath;
  std::string cursorMode = "baked";
  int64_t videoPts0Ms = 0;
  int64_t durationMs = 0;
  int32_t width = 0;
  int32_t height = 0;
  json project;
  json session;
  std::vector<ak::AudioTrackSpec> audio;
  std::shared_ptr<ExportJob> job;
};

std::map<int64_t, std::shared_ptr<Project>> g_projects;

struct JobData {
  int64_t projectId = 0;
  int64_t exportId = 0;
  std::string dir;
  std::string videoPath;
  std::string outPath;
  int64_t videoPts0Ms = 0;
  int64_t durationMs = 0;
  int64_t startMs = 0;
  int64_t endMs = 0;
  int32_t outW = 1920;
  int32_t outH = 1080;
  double outFps = 30.0;
  int32_t quality = 60;
  int32_t bitrateKbps = 0;
  std::string codec = "h264";
  bool overwrite = false;
  bool useCursor = true;
  json project;
  json session;
  std::vector<ak::AudioTrackSpec> audio;
  std::string cursorMode;
};

void post_state(const JobData& data, const std::shared_ptr<ExportJob>& job,
                const char* state) {
  int pct = 0;
  std::string stage;
  {
    std::lock_guard<std::mutex> lock(job->mtx);
    pct = job->pct.load();
    stage = job->stage;
  }
  json ev = {{"type", "event"},
             {"kind", "project_state"},
             {"project_id", data.projectId},
             {"export_id", data.exportId},
             {"state", state},
             {"stage", stage},
             {"pct", pct},
             {"out_path", data.outPath}};
  ak::event_post(ev.dump());
}

void set_stage(const JobData& data, const std::shared_ptr<ExportJob>& job,
               const std::string& stage, int pct, bool force) {
  static thread_local auto last = std::chrono::steady_clock::now();
  {
    std::lock_guard<std::mutex> lock(job->mtx);
    job->stage = stage;
    job->pct = std::max(0, std::min(100, pct));
  }
  const auto now = std::chrono::steady_clock::now();
  if (!force && now - last < 200ms) {
    return;
  }
  last = now;
  post_state(data, job, "running");
}

struct CursorSample {
  int64_t t = 0;
  int32_t x = 0;
  int32_t y = 0;
  int32_t shape = 0;
  int32_t visible = 0;
};

struct Click {
  int64_t t = 0;
  int32_t x = 0;
  int32_t y = 0;
};

struct ShapeInfo {
  int id = 0;
  std::string file;
  int width = 0;
  int height = 0;
  int hotspotX = 0;
  int hotspotY = 0;
};

std::vector<CursorSample> load_cursor_bin(const std::string& path) {
  std::vector<CursorSample> out;
  std::ifstream in(path, std::ios::binary);
  if (!in.is_open()) {
    return out;
  }
#pragma pack(push, 1)
  struct Rec {
    uint32_t clockMs;
    int32_t x;
    int32_t y;
    uint16_t flags;
    uint16_t shapeId;
  };
#pragma pack(pop)
  Rec rec = {};
  while (in.read(reinterpret_cast<char*>(&rec), sizeof(rec))) {
    CursorSample sample;
    sample.t = (int64_t)rec.clockMs;
    sample.x = rec.x;
    sample.y = rec.y;
    sample.shape = (int32_t)rec.shapeId;
    sample.visible = (rec.flags & 1) ? 1 : 0;
    out.push_back(sample);
  }
  return out;
}

class RecorderObserver : public avox::IRecorderOb {
 public:
  void onStateChange(avox::RecorderState pre,
                     avox::RecorderState state) override {
    // close() 会立即置 completed, 真正排空结束看 onComplete; 提前返回会删掉
    // 渲染线程仍在使用的 recorder/scene(实测段错误)
    if (state == avox::RecorderState::failed) {
      failed = true;
      done = true;
    }
  }
  void onProgress(const avox::RecorderProgress& progress) override {
    if (progress.currentTimeMs >= 0) {
      current = progress.currentTimeMs;
      if (first < 0) {
        first = progress.currentTimeMs;
      }
    }
  }
  void onIoError(avox::AVError error, const char* msg) override {
    failed = true;
    done = true;
    std::lock_guard<std::mutex> lock(mtx);
    errorText = msg ? msg : "io error";
  }
  void onEncodeError(avox::TrackType, avox::EncodeResult) override {
    failed = true;
    done = true;
    std::lock_guard<std::mutex> lock(mtx);
    errorText = "encode error";
  }
  void onComplete() override { done = true; }

  std::atomic<bool> done{false};
  std::atomic<bool> failed{false};
  std::atomic<int64_t> current{-1};
  std::atomic<int64_t> first{-1};
  std::mutex mtx;
  std::string errorText;
};

// 一个导出任务的资源与阶段; 析构只做幂等清理
class ExportRunner {
 public:
  ExportRunner(JobData data, std::shared_ptr<ExportJob> job)
      : data_(std::move(data)), job_(std::move(job)) {}
  ~ExportRunner() { cleanup(); }

  void run() {
    std::string error;
    bool ok = false;
    do {
      if (job_->cancel) {
        break;
      }
      if (!build_scene(&error)) {
        break;
      }
      if (!open_recorder(&error)) {
        break;
      }
      if (!encode_video(&error)) {
        break;
      }
      if (job_->cancel) {
        break;
      }
      mix_audio();
      if (!mux_output(&error)) {
        break;
      }
      ok = true;
    } while (false);

    cleanup();
    if (job_->cancel) {
      job_->state = 4;
      {
        std::lock_guard<std::mutex> lock(job_->mtx);
        job_->stage = "cancelled";
      }
      post_state(data_, job_, "cancelled");
      std::error_code ec;
      std::filesystem::remove(data_.outPath, ec);
      return;
    }
    if (!ok) {
      job_->state = 3;
      {
        std::lock_guard<std::mutex> lock(job_->mtx);
        job_->stage = "failed";
        job_->error = error;
      }
      json ev = {{"type", "event"},
                 {"kind", "project_error"},
                 {"project_id", data_.projectId},
                 {"export_id", data_.exportId},
                 {"code", "export_failed"},
                 {"message", error}};
      ak::event_post(ev.dump());
      post_state(data_, job_, "failed");
      return;
    }
    job_->state = 2;
    job_->pct = 100;
    {
      std::lock_guard<std::mutex> lock(job_->mtx);
      job_->stage = "done";
    }
    post_state(data_, job_, "done");
  }

 private:
  bool build_scene(std::string* error) {
    scene_ = avox::createEditorScene();
    if (!scene_) {
      *error = "cannot create editor scene";
      return false;
    }
    json scene = data_.project.value("scene", json::object());
    if (!scene.is_object()) {
      scene = json::object();
    }
    avox::SceneStyle style = {};
    style.padding = scene.value("padding", 0.06f);
    style.cornerRadius = scene.value("radius", 0.02f);
    const json shadow = scene.value("shadow", json::object());
    if (shadow.is_object()) {
      style.shadowRadius = shadow.value("radius", 0.03f);
      style.shadowAlpha = shadow.value("alpha", 0.45f);
      style.shadowOffsetX = shadow.value("offsetX", 0.0f);
      style.shadowOffsetY = shadow.value("offsetY", 0.012f);
    }
    style.cursorScale = scene.value("cursorScale", 0.03f);
    json bg = scene.value("background", json::object());
    if (!bg.is_object()) {
      bg = json::object();
    }
    json c1 = bg.value("color", json::array({0.09, 0.10, 0.14}));
    json c2 = bg.value("color2", c1);
    if (c1.is_array() && c1.size() >= 3) {
      for (int i = 0; i < 3; i++) {
        style.bgColorTop[i] = c1[i].get<float>();
        style.bgColorBottom[i] = c2.is_array() && c2.size() >= 3
                                     ? c2[i].get<float>()
                                     : c1[i].get<float>();
      }
    }
    scene_->setStyle(style);
    scene_->setCanvas(data_.outW, data_.outH);

    // 场景时间与文件 pts 同一时基: 采集 muxer 写的是会话时钟(未归零),
    // 光标/点击也存会话时钟; 裁剪导出按请求起点平移(引擎归零与否 v1 近似)
    const int64_t shift = data_.startMs;
    json timeline = data_.project.value("timeline", json::object());
    if (!timeline.is_object()) {
      timeline = json::object();
    }
    json zoom = timeline.value("zoom", json::object());
    if (!zoom.is_object()) {
      zoom = json::object();
    }
    const json segments = zoom.value("segments", json());
    if (segments.is_array() && !segments.empty()) {
      std::vector<avox::SceneCameraSegment> out;
      for (const auto& s : segments) {
        const json rect = s.value("rect", json());
        if (!rect.is_array() || rect.size() < 4) {
          continue;
        }
        avox::SceneCameraSegment seg = {};
        seg.t0 = s.value("t0", (int64_t)0) - shift;
        seg.t1 = s.value("t1", (int64_t)0) - shift;
        seg.x = rect[0].get<float>();
        seg.y = rect[1].get<float>();
        seg.w = rect[2].get<float>();
        seg.h = rect[3].get<float>();
        seg.easeIn = s.value("easeIn", 0);
        seg.easeOut = s.value("easeOut", 0);
        seg.follow = s.value("follow", 0) ? 1 : 0;
        if (seg.w < 2.0f || seg.h < 2.0f) {
          continue;
        }
        if (seg.t1 <= seg.t0) {
          seg.t1 = 0;
        }
        out.push_back(seg);
      }
      if (!out.empty()) {
        scene_->setSegments(out.data(), (int32_t)out.size());
      }
    }

    std::vector<Click> clicks;
    const json events = read_json_file(data_.dir + "/events.json");
    if (events.is_object() && events["clicks"].is_array()) {
      for (const auto& c : events["clicks"]) {
        if (!c.value("inside", true)) {
          continue;
        }
        Click click;
        click.t = c.value("t", (int64_t)0) - shift;
        click.x = c.value("x", 0);
        click.y = c.value("y", 0);
        clicks.push_back(click);
      }
    }
    if (!clicks.empty()) {
      std::vector<avox::SceneClick> out;
      out.reserve(clicks.size());
      for (const auto& c : clicks) {
        avox::SceneClick click = {};
        click.t = c.t;
        click.x = c.x;
        click.y = c.y;
        click.strength = 0.6f;
        out.push_back(click);
      }
      scene_->setClicks(out.data(), (int32_t)out.size());
    }

    if (!data_.useCursor ||
        (data_.cursorMode != "disabled" && data_.cursorMode != "absent")) {
      return true;
    }
    std::vector<CursorSample> samples =
        load_cursor_bin(data_.dir + "/cursor.bin");
    if (samples.empty()) {
      return true;
    }
    std::vector<avox::SceneCursorSample> out;
    out.reserve(samples.size());
    for (const auto& s : samples) {
      avox::SceneCursorSample sample = {};
      sample.t = s.t - shift;
      sample.x = s.x;
      sample.y = s.y;
      sample.shape = s.shape > 0 ? s.shape - 1 : 0;
      sample.visible = s.visible;
      out.push_back(sample);
    }
    scene_->setCursorTrack(out.data(), (int32_t)out.size());

    const json shapesJson = read_json_file(data_.dir + "/shapes.json");
    std::map<int, ShapeInfo> shapes;
    if (shapesJson.is_object() && shapesJson["shapes"].is_array()) {
      for (const auto& s : shapesJson["shapes"]) {
        ShapeInfo info;
        info.id = s.value("id", 0);
        info.file = s.value("file", std::string());
        info.width = s.value("width", 0);
        info.height = s.value("height", 0);
        info.hotspotX = s.value("hotspotX", 0);
        info.hotspotY = s.value("hotspotY", 0);
        if (info.id > 0 && !info.file.empty()) {
          shapes[info.id] = info;
        }
      }
    }
    if (shapes.empty()) {
      return true;
    }
    const int cols = 8;
    const int rows = 8;
    const int cell = 128;
    avox::IImageBuffer* atlas = avox::createImageBuffer();
    if (!atlas) {
      return true;
    }
    avox::ImageFormat atlasFormat = {};
    atlasFormat.width = cols * cell;
    atlasFormat.height = rows * cell;
    atlasFormat.imageType = avox::ImageType::rgba8;
    atlas->setImageFormat(atlasFormat);
    uint8_t* atlasPixels = atlas->getPointer();
    if (!atlasPixels ||
        atlas->getBufferSize() < atlasFormat.width * atlasFormat.height * 4) {
      delete atlas;
      return true;
    }
    std::memset(atlasPixels, 0,
                (size_t)atlasFormat.width * atlasFormat.height * 4);
    for (const auto& entry : shapes) {
      const int id = entry.first;
      if (id > cols * rows) {
        break;
      }
      avox::IImageBuffer* src = avox::createImageBuffer();
      if (!src) {
        continue;
      }
      const std::string path = data_.dir + "/" + entry.second.file;
      if (!avox::loadImagePath(path.c_str(), src)) {
        delete src;
        continue;
      }
      const avox::ImageFormat sf = src->getImageFormat();
      const uint8_t* sp = src->getPointer();
      const int sw = sf.width;
      const int sh = sf.height;
      const int pitch = sf.rowPitch > 0 ? sf.rowPitch : sw * 4;
      if (sw > 0 && sh > 0 && sp) {
        const int cx = ((id - 1) % cols) * cell;
        const int cy = ((id - 1) / cols) * cell;
        for (int dy = 0; dy < cell; dy++) {
          const int sy = std::min(sh - 1, dy * sh / cell);
          for (int dx = 0; dx < cell; dx++) {
            const int sx = std::min(sw - 1, dx * sw / cell);
            const uint8_t* p = sp + (size_t)sy * pitch + (size_t)sx * 4;
            uint8_t* d = atlasPixels +
                         ((size_t)(cy + dy) * atlasFormat.width + cx + dx) * 4;
            if (sf.imageType == avox::ImageType::bgra8) {
              d[0] = p[2];
              d[1] = p[1];
              d[2] = p[0];
              d[3] = p[3];
            } else if (sf.imageType == avox::ImageType::rgba8) {
              d[0] = p[0];
              d[1] = p[1];
              d[2] = p[2];
              d[3] = p[3];
            }
          }
        }
      }
      delete src;
    }
    scene_->setCursorAtlas(atlas, cols, rows);
    delete atlas;
    return true;
  }

  bool open_recorder(std::string* error) {
    const std::string ext = std::filesystem::path(data_.outPath).extension().string();
    tempVideo_ = data_.dir + "/.avoxkit-export-video.mkv";
    tempAudio_ = data_.dir + "/.avoxkit-export-audio.m4a";
    tempOut_ = data_.dir + "/.avoxkit-export-out" + (ext.empty() ? ".mp4" : ext);
    std::error_code ec;
    std::filesystem::remove(tempVideo_, ec);
    std::filesystem::remove(tempAudio_, ec);
    std::filesystem::remove(tempOut_, ec);

    rec_ = avox::createRecorder(true);
    if (!rec_) {
      *error = "cannot create recorder";
      return false;
    }
    rec_->setMuxerType(avox::MuxerType::ffmpeg);
    rec_->setVideoCodec(data_.codec == "hevc" ? avox::VCodecId::h265
                                              : avox::VCodecId::h264);
    rec_->setAudioCodec(avox::ACodecId::none);
    avox::VideoDesc desc = {};
    desc.width = data_.outW;
    desc.height = data_.outH;
    desc.fps = data_.outFps;
    rec_->setVideoDesc(desc);
    avox::VideoEncodeParam param = {};
    param.rateMode = avox::EncodeRateMode::quality;
    param.quality = data_.quality;
    param.bitrateKbps = data_.bitrateKbps;
    param.usage = avox::EncodeUsage::record;
    rec_->setVideoEncodeParam(param);
    if (avox::IOption* option = rec_->getOption()) {
      option->setBool("rec.hard.encode", false);
      if (data_.startMs > 0 && data_.durationMs > 0) {
        double frac = (double)data_.startMs / (double)data_.durationMs;
        frac = std::max(0.0, std::min(0.9, frac));
        if (frac > 0.0005) {
          option->setNumber("io.startFrac", frac);
        }
      }
    }
    render_ = rec_->getSurfaceRender();
    if (!render_ || !avox::attachEditorScene(render_, scene_)) {
      *error = "cannot attach editor scene";
      return false;
    }
    sceneAttached_ = true;
    avox::addRecorderOb(rec_, &observer_);
    observerAdded_ = true;
    if (!rec_->open(data_.videoPath.c_str(), tempVideo_.c_str())) {
      *error = "cannot open source video";
      return false;
    }
    opened_ = true;
    return true;
  }

  bool encode_video(std::string* error) {
    for (int i = 0; i < 500 && !observer_.done && !observer_.failed; i++) {
      if (rec_->getState() == avox::RecorderState::recording) {
        break;
      }
      std::this_thread::sleep_for(20ms);
    }
    if (observer_.failed) {
      std::lock_guard<std::mutex> lock(observer_.mtx);
      *error = observer_.errorText.empty() ? "video encode failed"
                                           : observer_.errorText;
      return false;
    }
    int64_t span = data_.endMs > data_.startMs
                       ? data_.endMs - data_.startMs
                       : data_.durationMs - data_.startMs;
    if (span <= 0) {
      span = data_.durationMs;
    }
    bool closed = false;
    while (!observer_.done && !observer_.failed) {
      if (job_->cancel) {
        rec_->close();
        closed = true;
        break;
      }
      const int64_t cur = observer_.current.load();
      if (cur >= 0 && span > 0) {
        const int64_t first = observer_.first.load();
        const int64_t base = first >= 0 ? first : cur;
        const int64_t elapsed = cur - base;
        const int pct = (int)std::min<int64_t>(78, elapsed * 78 / span);
        set_stage(data_, job_, "video", pct, false);
        if (data_.endMs > data_.startMs && elapsed >= span) {
          rec_->close();
          closed = true;
          break;
        }
      }
      std::this_thread::sleep_for(20ms);
    }
    if (!closed && !observer_.done && !job_->cancel) {
      rec_->close();
    }
    for (int i = 0; i < 750 && !observer_.done; i++) {
      std::this_thread::sleep_for(20ms);
    }
    if (observer_.failed) {
      std::lock_guard<std::mutex> lock(observer_.mtx);
      *error = observer_.errorText.empty() ? "video encode failed"
                                           : observer_.errorText;
      return false;
    }
    if (!observer_.done) {
      *error = "video drain timeout";
      return false;
    }
    if (job_->cancel) {
      return false;
    }
    if (!std::filesystem::exists(tempVideo_)) {
      *error = "video output missing";
      return false;
    }
    return true;
  }

  void mix_audio() {
    set_stage(data_, job_, "audio", 80, true);
    const int64_t end =
        data_.endMs > data_.startMs ? data_.endMs : data_.durationMs;
    ak::MixResult mix = ak::mix_wavs_to_aac(
        data_.audio, data_.videoPts0Ms, data_.startMs, end, tempAudio_);
    if (mix.ok && !mix.no_audio) {
      hasAudio_ = true;
    } else if (!mix.ok) {
      std::lock_guard<std::mutex> lock(job_->mtx);
      job_->warning = mix.error;
    }
    set_stage(data_, job_, "audio", 90, true);
  }

  bool mux_output(std::string* error) {
    set_stage(data_, job_, "mux", 92, true);
    std::error_code ec;
    const auto size = std::filesystem::file_size(tempVideo_, ec);
    ak::log(ak::LogLevel::info,
            "export temp video: " + tempVideo_ + " size=" +
                std::to_string(ec ? -1 : (int64_t)size));
    ak::MediaProbe probe;
    const bool probed = ak::probe_media(tempVideo_, &probe);
    ak::log(ak::LogLevel::info,
            "export temp probe: " + std::string(probed ? "ok" : probe.error) +
                " duration=" + std::to_string(probe.durationMs));
    ak::RemuxResult remux =
        ak::remux_streams(tempVideo_, hasAudio_ ? tempAudio_ : std::string(),
                          tempOut_);
    if (!remux.ok) {
      *error = remux.error;
      return false;
    }
    std::string moveError;
    if (!ak::replace_file(tempOut_, data_.outPath, &moveError)) {
      *error = "cannot finalize output: " + moveError;
      return false;
    }
    set_stage(data_, job_, "mux", 100, true);
    return true;
  }

  void cleanup() {
    if (rec_) {
      if (opened_) {
        // 失败/超时路径也要等排空结束: close 立即置 completed, 渲染线程
        // 可能还在读 scene, 直接 detach/destroy 会崩
        rec_->close();
        for (int i = 0; i < 500 && !observer_.done && !observer_.failed; i++) {
          std::this_thread::sleep_for(20ms);
        }
      }
      avox::removeRecorderOb(rec_, &observer_);
      observerAdded_ = false;
      if (sceneAttached_ && render_) {
        avox::detachEditorScene(render_);
        sceneAttached_ = false;
      }
      delete rec_;
      rec_ = nullptr;
    }
    if (scene_) {
      avox::destroyEditorScene(scene_);
      scene_ = nullptr;
    }
    std::error_code ec;
    std::filesystem::remove(tempVideo_, ec);
    std::filesystem::remove(tempAudio_, ec);
    std::filesystem::remove(tempOut_, ec);
  }

  JobData data_;
  std::shared_ptr<ExportJob> job_;
  avox::IEditorScene* scene_ = nullptr;
  avox::IRecorder* rec_ = nullptr;
  avox::ISurfaceRender* render_ = nullptr;
  bool sceneAttached_ = false;
  bool observerAdded_ = false;
  bool opened_ = false;
  bool hasAudio_ = false;
  RecorderObserver observer_;
  std::string tempVideo_;
  std::string tempAudio_;
  std::string tempOut_;
};

const char* job_state_name(int state) {
  switch (state) {
    case 1:
      return "running";
    case 2:
      return "done";
    case 3:
      return "failed";
    case 4:
      return "cancelled";
    default:
      return "idle";
  }
}

}  // namespace

extern "C" const char* ak_project_open(const char* request_json) {
  if (!ak::is_ready()) {
    return ak::dup_cstr("{\"ok\":false,\"code\":-4}");
  }
  json req = json::parse(request_json ? request_json : "{}", nullptr, false);
  if (req.is_discarded()) {
    return ak::dup_cstr("{\"ok\":false,\"code\":-2}");
  }
  std::string dir = req.value("dir", "");
  if (dir.empty()) {
    return ak::dup_cstr("{\"ok\":false,\"code\":-1}");
  }
  json session = read_json_file(dir + "/session.json");
  if (session.is_discarded() || !session.is_object()) {
    return ak::dup_cstr(
        "{\"ok\":false,\"code\":-10,\"error\":\"session.json missing\"}");
  }
  json project = read_json_file(dir + "/project.json");
  if (project.is_discarded() || !project.is_object()) {
    std::string videoName = "capture.mkv";
    if (!std::filesystem::exists(dir + "/capture.mkv")) {
      videoName = "screen.mkv";
    }
    project = default_project(videoName, 0, 0);
    write_json_file(dir + "/project.json", project);
  }
  auto meta = std::make_shared<Project>();
  meta->dir = dir;
  meta->project = project;
  meta->session = session;
  meta->videoPts0Ms =
      session.value("clock", json::object()).value("videoPts0Ms", (int64_t)0);
  meta->cursorMode = session.value("cursorMode", std::string("baked"));
  std::string videoName = "capture.mkv";
  if (project.contains("source") && project["source"].is_object()) {
    videoName = project["source"].value("video", videoName);
  }
  meta->videoPath = dir + "/" + videoName;
  if (!std::filesystem::exists(meta->videoPath)) {
    meta->videoPath = dir + "/screen.mkv";
  }
  ak::MediaProbe probe;
  if (ak::probe_media(meta->videoPath, &probe)) {
    meta->durationMs = probe.durationMs;
    meta->width = probe.width;
    meta->height = probe.height;
  }
  const auto& audios = session["audios"];
  if (audios.is_array()) {
    for (const auto& a : audios) {
      ak::AudioTrackSpec spec;
      spec.id = a.value("id", std::string());
      spec.path = a.value("path", std::string());
      if (std::filesystem::path(spec.path).is_relative()) {
        spec.path = dir + "/" + spec.path;
      }
      spec.startMs = a.value("startMs", (int64_t)-1);
      meta->audio.push_back(spec);
    }
  }
  std::lock_guard<std::mutex> lock(g_projMtx);
  meta->id = g_nextProjectId++;
  g_projects[meta->id] = meta;
  json out = {{"ok", true},
              {"project_id", meta->id},
              {"dir", dir},
              {"video", meta->videoPath},
              {"duration_ms", meta->durationMs},
              {"width", meta->width},
              {"height", meta->height},
              {"cursor_mode", meta->cursorMode},
              {"audio_tracks", (int)meta->audio.size()}};
  return ak::dup_cstr(out.dump());
}

extern "C" const char* ak_project_set(int64_t project_id,
                                      const char* patch_json) {
  json patch = json::parse(patch_json ? patch_json : "{}", nullptr, false);
  if (patch.is_discarded() || !patch.is_object()) {
    return ak::dup_cstr("{\"ok\":false,\"code\":-2}");
  }
  std::lock_guard<std::mutex> lock(g_projMtx);
  auto it = g_projects.find(project_id);
  if (it == g_projects.end()) {
    return ak::dup_cstr("{\"ok\":false,\"code\":-10}");
  }
  merge_json(it->second->project, patch);
  if (!write_json_file(it->second->dir + "/project.json",
                       it->second->project)) {
    return ak::dup_cstr("{\"ok\":false,\"code\":-99}");
  }
  return ak::dup_cstr(
      json({{"ok", true}, {"project", it->second->project}}).dump());
}

extern "C" const char* ak_project_export(int64_t project_id,
                                         const char* request_json) {
  json req = json::parse(request_json ? request_json : "{}", nullptr, false);
  if (req.is_discarded()) {
    return ak::dup_cstr("{\"ok\":false,\"code\":-2}");
  }
  std::shared_ptr<Project> project;
  std::shared_ptr<ExportJob> oldJob;
  {
    std::lock_guard<std::mutex> lock(g_projMtx);
    auto it = g_projects.find(project_id);
    if (it == g_projects.end()) {
      return ak::dup_cstr("{\"ok\":false,\"code\":-10}");
    }
    project = it->second;
    if (project->job && project->job->state == 1) {
      return ak::dup_cstr("{\"ok\":false,\"code\":-20}");
    }
    if (project->job && project->job->thread.joinable()) {
      oldJob = project->job;
    }
  }
  if (oldJob && oldJob->thread.joinable()) {
    oldJob->thread.join();
  }
  if (project->durationMs <= 0) {
    return ak::dup_cstr(
        "{\"ok\":false,\"code\":-11,\"error\":\"video duration unknown\"}");
  }
  JobData data;
  data.projectId = project->id;
  data.dir = project->dir;
  data.videoPath = project->videoPath;
  data.videoPts0Ms = project->videoPts0Ms;
  data.durationMs = project->durationMs;
  data.project = project->project;
  data.session = project->session;
  data.audio = project->audio;
  data.cursorMode = project->cursorMode;
  data.outPath = req.value("out_path", project->dir + "/export.mp4");
  if (std::filesystem::path(data.outPath).extension().empty()) {
    data.outPath += ".mp4";
  }
  data.startMs = req.value("start_ms", (int64_t)0);
  data.endMs = req.value("end_ms", (int64_t)0);
  data.startMs = std::max<int64_t>(0, std::min(data.startMs, project->durationMs));
  if (data.endMs > 0) {
    data.endMs = std::min(data.endMs, project->durationMs);
    if (data.endMs <= data.startMs) {
      data.endMs = project->durationMs;
    }
  }
  const json scene = data.project.value("scene", json::object());
  data.outW = even_dim(req.value("width",
                                 scene.value("outputWidth", 1920)));
  data.outH = even_dim(req.value("height",
                                 scene.value("outputHeight", 1080)));
  data.outFps = req.value("fps", 30.0);
  data.quality = req.value("quality", 60);
  data.bitrateKbps = req.value("bitrate_kbps", 0);
  data.codec = req.value("codec", std::string("h264"));
  data.overwrite = req.value("overwrite", false);
  data.useCursor = req.value("cursor", true);
  if (data.outW < 2 || data.outH < 2) {
    return ak::dup_cstr("{\"ok\":false,\"code\":-1}");
  }
  if (!data.overwrite && std::filesystem::exists(data.outPath)) {
    return ak::dup_cstr(
        "{\"ok\":false,\"code\":-12,\"error\":\"output exists\"}");
  }
  auto job = std::make_shared<ExportJob>();
  job->id = g_nextExportId++;
  job->projectId = project->id;
  job->outPath = data.outPath;
  data.exportId = job->id;
  {
    std::lock_guard<std::mutex> lock(g_projMtx);
    project->job = job;
  }
  job->thread = std::thread([data, job]() mutable {
    ExportRunner runner(std::move(data), job);
    runner.run();
  });
  return ak::dup_cstr(
      json({{"ok", true}, {"export_id", job->id}}).dump());
}

extern "C" const char* ak_project_status(int64_t project_id) {
  std::lock_guard<std::mutex> lock(g_projMtx);
  auto it = g_projects.find(project_id);
  if (it == g_projects.end()) {
    return ak::dup_cstr("{\"ok\":false,\"code\":-10}");
  }
  const auto& project = it->second;
  json out = {{"ok", true}, {"state", "idle"}, {"pct", 0}, {"stage", ""}};
  if (project->job) {
    std::lock_guard<std::mutex> jobLock(project->job->mtx);
    out["state"] = job_state_name(project->job->state.load());
    out["pct"] = project->job->pct.load();
    out["stage"] = project->job->stage;
    out["out_path"] = project->job->outPath;
    if (!project->job->error.empty()) {
      out["error"] = project->job->error;
    }
    if (!project->job->warning.empty()) {
      out["warning"] = project->job->warning;
    }
  }
  return ak::dup_cstr(out.dump());
}

extern "C" void ak_project_close(int64_t project_id) {
  std::shared_ptr<ExportJob> job;
  {
    std::lock_guard<std::mutex> lock(g_projMtx);
    auto it = g_projects.find(project_id);
    if (it == g_projects.end()) {
      return;
    }
    job = it->second->job;
    g_projects.erase(it);
  }
  if (job) {
    job->cancel = true;
    if (job->thread.joinable()) {
      job->thread.join();
    }
  }
}

namespace ak {
void project_shutdown() {
  std::vector<std::shared_ptr<ExportJob>> jobs;
  {
    std::lock_guard<std::mutex> lock(g_projMtx);
    for (auto& entry : g_projects) {
      if (entry.second->job) {
        jobs.push_back(entry.second->job);
      }
    }
    g_projects.clear();
  }
  for (auto& job : jobs) {
    job->cancel = true;
    if (job->thread.joinable()) {
      job->thread.join();
    }
  }
}
}  // namespace ak
