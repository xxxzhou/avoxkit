// 录屏会话 shim: 引擎 ICaptureSession 的 C 包装(录屏与自动缩放方案 §9.1 v1)。
// 多输入=多文件; 进程同时只允许一个活跃会话(引擎设备占用语义已保证同源互斥,
// 这里再限一个, UI 侧简单)。状态/错误经统一 JSON 事件通道派发, 状态用轮询。
#include "ak_internal.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <ctime>
#include <filesystem>
#include <fstream>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include <nlohmann/json.hpp>

#include "avox/Avox.hpp"
#include "avox/AvoxCapture.h"

#include "ak_cursor.hpp"
#include "ak_media_audio.hpp"
#include "ak_preview.hpp"

#ifdef _WIN32
#include <windows.h>
#ifndef WDA_EXCLUDEFROMCAPTURE
#define WDA_EXCLUDEFROMCAPTURE 0x00000011
#endif
#elif defined(__APPLE__)
#include <CoreGraphics/CoreGraphics.h>
#endif

namespace {

using nlohmann::json;

std::mutex g_capMtx;
int64_t g_nextSessionId = 1;
avox::ICaptureSession* g_session = nullptr;
int64_t g_sessionId = 0;
std::string g_outDir;
std::string g_sessionDir;
std::unique_ptr<ak::CursorTelemetry> g_cursor;

#ifdef _WIN32
HWND g_wdaHost = nullptr;
DWORD g_prevAffinity = WDA_NONE;
bool g_wdaApplied = false;
#endif

const char* state_str(avox::CaptureState s) {
  return avox::getCaptureStateStr(s);
}

// macOS 的屏幕/音频管理器注册在 mac_capture / ios 名下; 写死 Windows 枚举
// 会让 devices_json 三项全空, 录屏 start 也找不到显示器(-21)。
avox::VDeviceSdk capture_video_sdk() {
#ifdef __APPLE__
  return avox::VDeviceSdk::mac_capture;
#else
  return avox::VDeviceSdk::win_capture;
#endif
}

avox::ADeviceSdk capture_audio_sdk() {
#ifdef __APPLE__
  return avox::ADeviceSdk::ios;
#else
  return avox::ADeviceSdk::wasapi;
#endif
}

bool is_mic_device(avox::IAudioSource* dev) {
  if (!dev) {
    return false;
  }
  const auto kind = dev->getDeviceKind();
  if (kind == avox::ADeviceKind::mic) {
    return true;
  }
#ifdef __APPLE__
  // avox 的 IOSAudioSource 没标 deviceKind; 该管理器只暴露麦克风
  return kind == avox::ADeviceKind::none;
#else
  return false;
#endif
}

class CaptureOb : public avox::ICaptureSessionOb {
 public:
  void onCaptureState(avox::CaptureState pre,
                      avox::CaptureState cur) override {
    json ev = {{"type", "event"},
               {"kind", "capture_state"},
               {"session_id", sessionId.load()},
               {"from", state_str(pre)},
               {"to", state_str(cur)}};
    ak::event_post(ev.dump());
  }
  void onCaptureError(const char* id, avox::AVError err,
                      const char* msg) override {
    json ev = {{"type", "event"},
               {"kind", "capture_error"},
               {"session_id", sessionId.load()},
               {"track", id ? id : ""},
               {"code", (int32_t)err},
               {"message", msg ? msg : ""}};
    ak::event_post(ev.dump());
  }
  std::atomic<int64_t> sessionId{0};
};

CaptureOb g_ob;

// 进程 DPI 感知: 区域坐标是物理像素, 一次性声明(已声明则失败忽略)
void ensure_dpi_aware() {
#ifdef _WIN32
  static const bool done = []() {
    using SetCtxFn = BOOL(WINAPI*)(DPI_AWARENESS_CONTEXT);
    auto setCtx = (SetCtxFn)GetProcAddress(GetModuleHandleW(L"user32.dll"),
                                           "SetProcessDpiAwarenessContext");
    if (setCtx) {
      setCtx(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    }
    return true;
  }();
  (void)done;
#endif
}

// 引擎设备 id("\\.\DISPLAY1") → 显示器矩形(物理像素)与主屏标记
struct MonitorRect {
  std::string id;
  long x = 0;
  long y = 0;
  long w = 0;
  long h = 0;
  bool primary = false;
};

std::vector<MonitorRect> enum_monitors() {
  std::vector<MonitorRect> out;
#ifdef _WIN32
  EnumDisplayMonitors(
      nullptr, nullptr,
      [](HMONITOR hmon, HDC, LPRECT, LPARAM lparam) -> BOOL {
        auto* list = (std::vector<MonitorRect>*)lparam;
        MONITORINFOEXW mi = {};
        mi.cbSize = sizeof(mi);
        if (!GetMonitorInfoW(hmon, &mi)) {
          return TRUE;
        }
        MonitorRect m;
        char id[64] = {};
        WideCharToMultiByte(CP_UTF8, 0, mi.szDevice, -1, id, sizeof(id),
                            nullptr, nullptr);
        m.id = id;
        m.x = mi.rcMonitor.left;
        m.y = mi.rcMonitor.top;
        m.w = mi.rcMonitor.right - mi.rcMonitor.left;
        m.h = mi.rcMonitor.bottom - mi.rcMonitor.top;
        m.primary = (mi.dwFlags & MONITORINFOF_PRIMARY) != 0;
        list->push_back(m);
        return TRUE;
      },
      (LPARAM)&out);
#elif defined(__APPLE__)
  // 与 avox MacCapture 的 DISPLAY<CGDirectDisplayID> 对齐; region 用物理像素
  uint32_t count = 0;
  if (CGGetActiveDisplayList(0, nullptr, &count) == kCGErrorSuccess &&
      count > 0) {
    std::vector<CGDirectDisplayID> ids(count);
    if (CGGetActiveDisplayList(count, ids.data(), &count) == kCGErrorSuccess) {
      for (CGDirectDisplayID id : ids) {
        const CGRect bounds = CGDisplayBounds(id);
        const int32_t pw = (int32_t)CGDisplayPixelsWide(id);
        const int32_t ph = (int32_t)CGDisplayPixelsHigh(id);
        const double sx =
            bounds.size.width > 0 ? pw / bounds.size.width : 1.0;
        const double sy =
            bounds.size.height > 0 ? ph / bounds.size.height : 1.0;
        MonitorRect m;
        m.id = "DISPLAY" + std::to_string((unsigned)id);
        m.x = (long)std::llround(bounds.origin.x * sx);
        m.y = (long)std::llround(bounds.origin.y * sy);
        m.w = pw;
        m.h = ph;
        m.primary = CGDisplayIsMain(id) != 0;
        out.push_back(m);
      }
    }
  }
#endif
  return out;
}

bool add_audio(avox::ICaptureSession* session, avox::IAudioManager* mgr,
               bool mic) {
  if (!mgr || !session) {
    return false;
  }
  const auto kind = mic ? avox::ADeviceKind::mic : avox::ADeviceKind::loopback;
  const char* trackId = mic ? "mic" : "sys";
  for (int32_t i = 0; i < mgr->getDeviceCount(); i++) {
    avox::IAudioSource* dev = mgr->getDevice(i);
    if (!dev) {
      continue;
    }
    const bool match =
        mic ? is_mic_device(dev) : dev->getDeviceKind() == kind;
    if (match) {
      return session->addAudioInput({dev, trackId});
    }
  }
  return false;
}

std::string make_session_dir(const std::string& root) {
  std::error_code ec;
  std::filesystem::create_directories(root, ec);
  const std::time_t now = std::time(nullptr);
  std::tm tm = {};
#ifdef _WIN32
  localtime_s(&tm, &now);
#else
  localtime_r(&now, &tm);
#endif
  char stamp[32] = {};
  std::strftime(stamp, sizeof(stamp), "%Y-%m-%d-%H%M%S", &tm);
  const std::string base = root + "/" + stamp;
  std::string dir = base;
  for (int i = 2; std::filesystem::exists(dir); i++) {
    dir = base + "-" + std::to_string(i);
  }
  std::filesystem::create_directories(dir, ec);
  return dir;
}

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

void apply_wda(bool enable) {
#ifdef _WIN32
  if (enable) {
    HWND host = static_cast<HWND>(ak::preview_host());
    if (!host) {
      return;
    }
    DWORD cur = 0;
    if (GetWindowDisplayAffinity(host, &cur)) {
      g_prevAffinity = cur;
    }
    if (SetWindowDisplayAffinity(host, WDA_EXCLUDEFROMCAPTURE)) {
      g_wdaHost = host;
      g_wdaApplied = true;
      ak::log(ak::LogLevel::info, "capture: WDA exclude on");
    } else {
      ak::log(ak::LogLevel::warn, "capture: WDA exclude failed");
    }
  } else if (g_wdaApplied && g_wdaHost) {
    SetWindowDisplayAffinity(g_wdaHost, g_prevAffinity);
    g_wdaApplied = false;
    g_wdaHost = nullptr;
    ak::log(ak::LogLevel::info, "capture: WDA restored");
  }
#endif
}

struct CaptureMeta {
  std::string videoPath;
  int64_t videoPts0Ms = 0;
  int64_t durationMs = 0;
  int32_t width = 0;
  int32_t height = 0;
  std::string cursorMode = "baked";
  std::vector<ak::AudioTrackSpec> audio;
};

bool load_capture_meta(const std::string& dir, CaptureMeta* meta,
                       std::string* error) {
  json session = read_json_file(dir + "/session.json");
  if (session.is_discarded() || !session.is_object()) {
    session = read_json_file(dir + "/session.draft.json");
  }
  if (session.is_discarded() || !session.is_object()) {
    *error = "session.json missing";
    return false;
  }
  meta->videoPts0Ms =
      session.value("clock", json::object()).value("videoPts0Ms", (int64_t)0);
  meta->cursorMode = session.value("cursorMode", std::string("baked"));
  json chosen;
  const auto& videos = session["videos"];
  if (videos.is_array() && !videos.empty()) {
    for (const auto& v : videos) {
      if (v.value("id", std::string()) == "screen") {
        chosen = v;
        break;
      }
    }
    if (chosen.is_null()) {
      chosen = videos.front();
    }
  }
  if (chosen.is_null() || !chosen.contains("path")) {
    *error = "session has no video";
    return false;
  }
  std::string path = chosen.value("path", std::string());
  if (std::filesystem::path(path).is_relative()) {
    path = dir + "/" + path;
  }
  meta->videoPath = path;
  ak::MediaProbe probe;
  if (ak::probe_media(path, &probe)) {
    meta->durationMs = probe.durationMs;
    meta->width = probe.width;
    meta->height = probe.height;
  } else {
    meta->width = chosen.value("width", 0);
    meta->height = chosen.value("height", 0);
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
  return true;
}

bool write_default_project(const std::string& dir, const CaptureMeta& meta,
                           std::string* error) {
  const std::string path = dir + "/project.json";
  if (std::filesystem::exists(path)) {
    return true;
  }
  int32_t outW = 1920;
  int32_t outH = 1080;
  if (meta.width > 0 && meta.height > 0) {
    if (meta.height > meta.width) {
      outW = 1080;
      outH = 1920;
    } else if (std::abs(meta.width - meta.height) < meta.width / 100) {
      outW = 1080;
      outH = 1080;
    }
  }
  json audio = json::array();
  for (const auto& a : meta.audio) {
    if (a.id.empty()) {
      continue;
    }
    audio.push_back({{"id", a.id},
                     {"gainDb", a.id == "sys" ? -3.0 : 0.0},
                     {"mute", false}});
  }
  std::string videoName = "capture.mkv";
  if (!std::filesystem::exists(dir + "/capture.mkv")) {
    videoName = std::filesystem::path(meta.videoPath).filename().string();
  }
  json project = {
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
      {"audio", audio}};
  if (!write_json_file(path, project)) {
    if (error) {
      *error = "cannot write project.json";
    }
    return false;
  }
  return true;
}

bool finalize_capture(const std::string& dir, json* out, std::string* error) {
  CaptureMeta meta;
  if (!load_capture_meta(dir, &meta, error)) {
    return false;
  }
  if (meta.durationMs <= 0) {
    *error = "video duration unknown";
    return false;
  }
  std::error_code ec;
  const std::string audioTmp = dir + "/.avoxkit-audio.m4a";
  std::filesystem::remove(audioTmp, ec);
  std::string audioPath;
  std::string audioError;
  ak::MixResult mix =
      ak::mix_wavs_to_aac(meta.audio, meta.videoPts0Ms, 0, meta.durationMs,
                          audioTmp);
  if (mix.ok && !mix.no_audio) {
    audioPath = audioTmp;
  } else if (!mix.ok) {
    audioError = mix.error;
  }
  const std::string capturePath = dir + "/capture.mkv";
  const std::string temp = dir + "/capture.avoxkit-part.mkv";
  ak::RemuxResult remux = ak::remux_streams(meta.videoPath, audioPath, temp);
  if (!remux.ok) {
    *error = remux.error;
    std::filesystem::remove(temp, ec);
    std::filesystem::remove(audioTmp, ec);
    return false;
  }
  std::string moveError;
  if (!ak::replace_file(temp, capturePath, &moveError)) {
    *error = "cannot finalize capture.mkv: " + moveError;
    std::filesystem::remove(temp, ec);
    std::filesystem::remove(audioTmp, ec);
    return false;
  }
  std::filesystem::remove(audioTmp, ec);
  write_default_project(dir, meta, nullptr);
  *out = {{"capture", capturePath},
          {"project", dir + "/project.json"},
          {"duration_ms", meta.durationMs},
          {"audio_tracks", (int)meta.audio.size()}};
  if (!audioError.empty()) {
    (*out)["audio_error"] = audioError;
  }
  if (mix.ok && mix.no_audio) {
    (*out)["audio"] = "none";
  }
  return true;
}

void scan_outputs(const std::string& dir, std::vector<std::string>* videos,
                  std::vector<std::string>* audios) {
  std::error_code ec;
  for (const auto& entry :
       std::filesystem::recursive_directory_iterator(dir, ec)) {
    if (!entry.is_regular_file()) {
      continue;
    }
    const auto path = entry.path();
    if (path.filename().string().find(".avoxkit-") != std::string::npos) {
      continue;
    }
    std::string ext = path.extension().string();
    std::transform(ext.begin(), ext.end(), ext.begin(), ::tolower);
    if (ext == ".mkv" || ext == ".mp4") {
      videos->push_back(path.generic_string());
    } else if (ext == ".wav") {
      audios->push_back(path.generic_string());
    }
  }
}

}  // namespace

extern "C" const char* ak_capture_devices_json(void) {
  ensure_dpi_aware();
  if (!ak::is_ready()) {
    return ak::dup_cstr("{\"ok\":false,\"code\":-4}");
  }
  json out = {{"ok", true},
              {"monitors", json::array()},
              {"mics", json::array()},
              {"loops", json::array()}};
  auto monitors = enum_monitors();
  avox::IVideoManager* vmgr =
      avox::getVideoManager(capture_video_sdk());
  if (vmgr) {
    for (int32_t i = 0; i < vmgr->getDeviceCount(); i++) {
      avox::IVideoSource* dev = vmgr->getDevice(i);
      if (!dev || dev->getDeviceKind() != avox::VDeviceKind::monitor) {
        continue;
      }
      json m = {{"id", dev->getDeviceId()}, {"name", dev->getDeviceName()}};
      for (const auto& r : monitors) {
        if (r.id == dev->getDeviceId()) {
          m["x"] = r.x;
          m["y"] = r.y;
          m["w"] = r.w;
          m["h"] = r.h;
          m["primary"] = r.primary;
        }
      }
      out["monitors"].push_back(m);
    }
  }
  avox::IAudioManager* amgr = avox::getAudioManager(capture_audio_sdk());
  if (amgr) {
    for (int32_t i = 0; i < amgr->getDeviceCount(); i++) {
      avox::IAudioSource* dev = amgr->getDevice(i);
      if (!dev) {
        continue;
      }
      json a = {{"id", dev->getDeviceId()}, {"name", dev->getDeviceName()}};
      if (is_mic_device(dev)) {
        out["mics"].push_back(a);
      } else if (dev->getDeviceKind() == avox::ADeviceKind::loopback) {
        out["loops"].push_back(a);
      }
    }
  }
  return ak::dup_cstr(out.dump());
}

extern "C" const char* ak_capture_start(const char* request_json) {
  ensure_dpi_aware();
  if (!ak::is_ready()) {
    return ak::dup_cstr("{\"ok\":false,\"code\":-4}");
  }
  std::lock_guard<std::mutex> lock(g_capMtx);
  if (g_session) {
    return ak::dup_cstr("{\"ok\":false,\"code\":-20}");
  }
  json req = json::parse(request_json ? request_json : "{}", nullptr, false);
  if (req.is_discarded()) {
    return ak::dup_cstr("{\"ok\":false,\"code\":-2}");
  }
  std::string outDir = req.value("out_dir", "");
  std::string monitorId = req.value("monitor_id", "");
  if (outDir.empty() || monitorId.empty()) {
    return ak::dup_cstr("{\"ok\":false,\"code\":-1}");
  }
  const double fps = req.value("fps", 60.0);
  const bool cursor = req.value("cursor", false);
  const bool wantMic = req.value("mic", false);
  const bool wantLoop = req.value("loop", false);
  const int32_t regionW = req.value("region_w", 0);
  const int32_t regionH = req.value("region_h", 0);
  // 显示器设备 + 物理 rect(区域=显示器左上原点的物理像素)
  avox::IVideoManager* vmgr = avox::getVideoManager(capture_video_sdk());
  avox::IVideoSource* monitor = nullptr;
  MonitorRect rect;
  if (vmgr) {
    for (int32_t i = 0; i < vmgr->getDeviceCount(); i++) {
      avox::IVideoSource* dev = vmgr->getDevice(i);
      if (dev && dev->getDeviceKind() == avox::VDeviceKind::monitor &&
          monitorId == dev->getDeviceId()) {
        monitor = dev;
        for (const auto& r : enum_monitors()) {
          if (r.id == monitorId) {
            rect = r;
          }
        }
        break;
      }
    }
  }
  if (!monitor) {
    return ak::dup_cstr("{\"ok\":false,\"code\":-21}");
  }

  const std::string sessionDir = make_session_dir(outDir);
  avox::ICaptureSession* session = avox::createCaptureSession();
  if (!session) {
    std::error_code ec;
    std::filesystem::remove_all(sessionDir, ec);
    return ak::dup_cstr("{\"ok\":false,\"code\":-99}");
  }
  avox::CaptureConfig cfg = {};
  cfg.video.fps = fps;
  cfg.video.captureCursor = cursor;
  cfg.video.border = false;
  cfg.video.regionX = rect.x;
  cfg.video.regionY = rect.y;
  cfg.video.regionW = regionW > 1 ? regionW : rect.w;
  cfg.video.regionH = regionH > 1 ? regionH : rect.h;
  cfg.videoCodec = avox::VCodecId::h264;
  session->setConfig(cfg);
  session->setObserver(&g_ob);
  if (!session->addVideoInput({monitor, "screen", cfg.video})) {
    delete session;
    std::error_code ec;
    std::filesystem::remove_all(sessionDir, ec);
    return ak::dup_cstr("{\"ok\":false,\"code\":-21}");
  }
  avox::IAudioManager* amgr = avox::getAudioManager(capture_audio_sdk());
  if (wantMic && !add_audio(session, amgr, true)) {
    ak::log(ak::LogLevel::warn, "capture: mic unavailable, skip");
  }
  if (wantLoop && !add_audio(session, amgr, false)) {
    ak::log(ak::LogLevel::warn, "capture: loopback unavailable, skip");
  }
  apply_wda(true);
  const int64_t id = g_nextSessionId++;
  g_ob.sessionId = id;
  if (!session->start(sessionDir.c_str())) {
    apply_wda(false);
    delete session;
    std::error_code ec;
    std::filesystem::remove_all(sessionDir, ec);
    return ak::dup_cstr("{\"ok\":false,\"code\":-99}");
  }
  auto cursorTelemetry = std::make_unique<ak::CursorTelemetry>();
  avox::CaptureGeometry geo = {};
  session->getCaptureGeometry(&geo);
  cursorTelemetry->start(sessionDir, session, geo, ak::preview_host(), !cursor);
  g_session = session;
  g_sessionId = id;
  g_outDir = outDir;
  g_sessionDir = sessionDir;
  g_cursor = std::move(cursorTelemetry);
  return ak::dup_cstr(
      json({{"ok", true}, {"session_id", id}, {"dir", sessionDir}}).dump());
}

extern "C" const char* ak_capture_status(int64_t session_id) {
  std::lock_guard<std::mutex> lock(g_capMtx);
  if (!g_session || session_id != g_sessionId) {
    return ak::dup_cstr("{\"ok\":false,\"code\":-10}");
  }
  avox::CaptureStats st = g_session->getStats();
  avox::CaptureGeometry geo = {};
  g_session->getCaptureGeometry(&geo);
  json out = {
      {"ok", true},
      {"state", state_str(g_session->getState())},
      {"clock_ms", g_session->getClockMs()},
      {"fps", st.achievedFps},
      {"frames", st.pushedFrames},
      {"missed", st.missedTicks},
      {"dropped", st.droppedBySize + st.droppedByFpsGate + st.encoderDropped},
      {"elapsed_ms", st.elapsedMs},
      {"bytes", st.bytesWritten},
      {"dir", g_sessionDir},
      {"geometry",
       {{"x", geo.x}, {"y", geo.y}, {"w", geo.width}, {"h", geo.height}}}};
  return ak::dup_cstr(out.dump());
}

extern "C" int32_t ak_capture_pause(int64_t session_id) {
  std::lock_guard<std::mutex> lock(g_capMtx);
  if (!g_session || session_id != g_sessionId) {
    return AK_E_NOT_FOUND;
  }
  if (g_cursor) {
    g_cursor->markPause();
  }
  g_session->pause();
  return AK_OK;
}

extern "C" int32_t ak_capture_resume(int64_t session_id) {
  std::lock_guard<std::mutex> lock(g_capMtx);
  if (!g_session || session_id != g_sessionId) {
    return AK_E_NOT_FOUND;
  }
  g_session->resume();
  if (g_cursor) {
    g_cursor->markResume();
  }
  return AK_OK;
}

extern "C" const char* ak_capture_stop(int64_t session_id) {
  avox::ICaptureSession* session = nullptr;
  std::string dir;
  std::unique_ptr<ak::CursorTelemetry> cursor;
  {
    std::lock_guard<std::mutex> lock(g_capMtx);
    // 失败分支记下现场: 跨 isolate 加载会得到另一份静态变量, 这里能看出来
    ak::log(ak::LogLevel::info,
            "capture: stop enter id=" + std::to_string(session_id) +
                " active=" + std::to_string(g_sessionId) +
                " has_session=" + (g_session ? "1" : "0"));
    if (!g_session || session_id != g_sessionId) {
      return ak::dup_cstr("{\"ok\":false,\"code\":-10}");
    }
    session = g_session;
    g_session = nullptr;
    g_sessionId = 0;
    dir = g_sessionDir;
    g_sessionDir.clear();
    cursor = std::move(g_cursor);
    apply_wda(false);
  }
  if (cursor) {
    cursor->stop();
  }
  session->stop();
  delete session;
  json out = {{"ok", true}, {"dir", dir}};
  json videos = json::array();
  json audios = json::array();
  std::vector<std::string> videoFiles;
  std::vector<std::string> audioFiles;
  scan_outputs(dir, &videoFiles, &audioFiles);
  for (const auto& path : videoFiles) {
    videos.push_back(path);
  }
  for (const auto& path : audioFiles) {
    audios.push_back(path);
  }
  out["videos"] = videos;
  out["audios"] = audios;
  ak::log(ak::LogLevel::info, "capture: stop done dir=" + dir);
  return ak::dup_cstr(out.dump());
}

extern "C" const char* ak_capture_finalize(const char* request_json) {
  if (!ak::is_ready()) {
    return ak::dup_cstr("{\"ok\":false,\"code\":-4}");
  }
  json req = json::parse(request_json ? request_json : "{}", nullptr, false);
  if (req.is_discarded()) {
    return ak::dup_cstr("{\"ok\":false,\"code\":-2}");
  }
  const std::string dir = req.value("dir", std::string());
  if (dir.empty()) {
    return ak::dup_cstr("{\"ok\":false,\"code\":-1}");
  }
  ak::log(ak::LogLevel::info,
          "capture: finalize enter dir=" + dir +
              " via=" + req.value("via", std::string("host")));
  if (req.contains("isolate_error")) {
    std::string text = req.value("isolate_error", std::string());
    if (text.size() > 300) {
      text.resize(300);
    }
    ak::log(ak::LogLevel::warn, "capture: isolate load failed: " + text);
  }
  json finalized;
  std::string finalizeError;
  if (!finalize_capture(dir, &finalized, &finalizeError)) {
    ak::log(ak::LogLevel::warn, "capture: finalize failed: " + finalizeError);
    json out = {{"ok", false}, {"code", (int32_t)AK_E_BAD_SOURCE},
                {"dir", dir}, {"error", finalizeError}};
    return ak::dup_cstr(out.dump());
  }
  json out = {{"ok", true}, {"dir", dir}};
  out.update(finalized);
  json videos = json::array();
  json audios = json::array();
  std::vector<std::string> videoFiles;
  std::vector<std::string> audioFiles;
  scan_outputs(dir, &videoFiles, &audioFiles);
  for (const auto& path : videoFiles) {
    videos.push_back(path);
  }
  for (const auto& path : audioFiles) {
    audios.push_back(path);
  }
  out["videos"] = videos;
  out["audios"] = audios;
  ak::log(ak::LogLevel::info,
          "capture: finalize done duration_ms=" +
              std::to_string(finalized.value("duration_ms", (int64_t)0)));
  return ak::dup_cstr(out.dump());
}

namespace ak {
// 退出期收尾: 不 finalize(有界优先), 产物与 draft 留给下次打开目录
void capture_shutdown() {
  avox::ICaptureSession* session = nullptr;
  std::unique_ptr<CursorTelemetry> cursor;
  {
    std::lock_guard<std::mutex> lock(g_capMtx);
    session = g_session;
    g_session = nullptr;
    g_sessionId = 0;
    cursor = std::move(g_cursor);
    apply_wda(false);
  }
  if (cursor) {
    cursor->stop();
  }
  if (session) {
    session->stop();
    delete session;
  }
}
}  // namespace ak
