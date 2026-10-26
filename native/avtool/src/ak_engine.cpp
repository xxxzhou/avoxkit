#include "ak_internal.hpp"

#include <cstring>
#include <filesystem>
#include <set>
#include <string>
#include <vector>

#include <nlohmann/json.hpp>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/avutil.h>
}

#include "avox/AvoxBase.h"
#include "avox/AvoxLog.h"
#include "avox/AvoxVersion.h"

namespace ak {
namespace {

int32_t self_check(std::string& detail) {
  const char* config = avcodec_configuration();
  if (!config) {
    detail = "avcodec_configuration() returned null";
    return AK_E_FFMPEG_MISMATCH;
  }
  if (!std::strstr(config, "--enable-libmp3lame")) {
    detail = "running avcodec was not built with --enable-libmp3lame";
    return AK_E_FFMPEG_MISMATCH;
  }
  if (!avcodec_find_encoder_by_name("libmp3lame")) {
    detail = "libmp3lame encoder is not registered";
    return AK_E_FFMPEG_MISMATCH;
  }
  if (!avcodec_find_encoder_by_name("aac")) {
    detail = "aac encoder is not registered";
    return AK_E_FFMPEG_MISMATCH;
  }
  if ((avformat_version() >> 16) != 63) {
    detail = "avformat major version mismatch (expected 63)";
    return AK_E_FFMPEG_MISMATCH;
  }
  return AK_OK;
}

bool parse_config(const char* text, Config& out, int32_t& code,
                  std::string& error) {
  try {
    const auto j = nlohmann::json::parse(text ? text : "");
    if (!j.is_object()) {
      code = AK_E_BAD_JSON;
      error = "config must be a JSON object";
      return false;
    }
    if (!j.contains("work_dir") || !j["work_dir"].is_string() ||
        j["work_dir"].get<std::string>().empty()) {
      code = AK_E_INVALID_ARG;
      error = "config.work_dir is required";
      return false;
    }
    out.work_dir = j["work_dir"].get<std::string>();
    if (j.contains("models_dir") && j["models_dir"].is_string()) {
      out.models_dir = j["models_dir"].get<std::string>();
    }
    if (j.contains("log_level") && j["log_level"].is_string()) {
      out.log_level = j["log_level"].get<std::string>();
    }
    return true;
  } catch (const std::exception& e) {
    code = AK_E_BAD_JSON;
    error = e.what();
    return false;
  }
}

std::string date_stamp() {
  std::string iso = now_iso8601();
  std::string digits;
  for (char c : iso) {
    if (c >= '0' && c <= '9' && digits.size() < 8) {
      digits.push_back(c);
    }
  }
  return digits;
}

}  // namespace

Engine& engine() {
  static Engine instance;
  return instance;
}

bool is_ready() { return engine().status.load() == 1; }

int32_t init_engine(const char* config_json) {
  int expected = 0;
  if (!engine().status.compare_exchange_strong(expected, 1)) {
    return expected == 1 ? AK_E_ALREADY_INIT : AK_E_NOT_INIT;
  }

  Config config;
  int32_t code = AK_OK;
  std::string error;
  if (!parse_config(config_json, config, code, error)) {
    engine().status.store(0);
    return code;
  }

  std::error_code ec;
  const auto root = std::filesystem::u8path(config.work_dir);
  std::filesystem::create_directories(root, ec);
  if (ec) {
    engine().status.store(0);
    return AK_E_INVALID_ARG;
  }
  const auto logs = root / "logs";
  std::filesystem::create_directories(logs, ec);
  if (ec) {
    engine().status.store(0);
    return AK_E_INVALID_ARG;
  }

  {
    std::lock_guard<std::mutex> lock(engine().mtx);
    engine().config = config;
    engine().log_dir = logs.u8string();
  }
  const auto log_path = logs / ("avoxkit-" + date_stamp() + ".log");
  log_set_file(log_path.u8string(), config.log_level);

  avox::setLogAction(avox_log_bridge);
  avox::logMsg(avox::LogLevel::info, "avox log bridge attached");

  std::string detail;
  const int32_t check = self_check(detail);
  if (check != AK_OK) {
    log(LogLevel::error, "self-check failed: " + detail);
    avox::restoreLogObserver();
    log_close();
    engine().status.store(0);
    return check;
  }

  event_start();
  task_start();

  engine().init_ms = now_ms();
  engine().version_json = make_version_json();
  engine().capabilities_json = make_capabilities_json();

  log(LogLevel::info,
      "ak init ok, work_dir=" + config.work_dir + ", log_dir=" +
          engine().log_dir);
  return AK_OK;
}

void shutdown_engine() {
  int expected = 1;
  if (!engine().status.compare_exchange_strong(expected, 2)) {
    return;
  }
  log(LogLevel::info, "shutdown begin");
  task_stop();
  log(LogLevel::info, "shutdown: task_stop done");
  event_stop();
  log(LogLevel::info, "shutdown: event_stop done");
  log(LogLevel::info, "ak shutdown");
  // avox 的日志走异步队列; 先排空, 否则桥接日志会在关文件后落到 stdout
  avox::flushLog();
  log(LogLevel::info, "shutdown: flushLog done");
  avox::restoreLogObserver();
  log(LogLevel::info, "shutdown: restoreLogObserver done");
  log_close();
  engine().status.store(0);
}

std::string make_version_json() {
  nlohmann::json j;
  j["abi"] = ((AK_ABI_MAJOR << 16) | AK_ABI_MINOR);
  j["shim"] = {{"version", "0.1.0"}, {"build", __DATE__ " " __TIME__}};

  const char* run_dir = avox::getAvoxRunDir();
  j["avox"] = {{"commit", AVOX_COMMIT_HASH},
               {"version", AVOX_COMMIT_VERSION},
               {"build_time", AVOX_BUILD_TIME},
               {"dll_dir", run_dir ? run_dir : ""}};

  const char* config = avcodec_configuration();
  j["ffmpeg"] = {
      {"version", av_version_info()},
      {"avcodec", avcodec_version()},
      {"avformat", avformat_version()},
      {"avutil", avutil_version()},
      {"config_fnv1a", fnv1a_hex(config ? config : "")},
      {"has_libmp3lame", config && std::strstr(config, "--enable-libmp3lame")}};

#if defined(_WIN32)
  j["platform"] = "windows-x64";
#elif defined(__APPLE__)
  j["platform"] = "macos";
#else
  j["platform"] = "linux";
#endif

  std::string work_dir;
  std::string log_dir;
  {
    std::lock_guard<std::mutex> lock(engine().mtx);
    work_dir = engine().config.work_dir;
    log_dir = engine().log_dir;
  }
  j["paths"] = {{"work_dir", work_dir}, {"log_dir", log_dir}};
  return j.dump();
}

std::string make_capabilities_json() {
  const auto has_encoder = [](const char* name) {
    return avcodec_find_encoder_by_name(name) != nullptr;
  };
  const auto has_muxer = [](const char* name) {
    return av_guess_format(name, nullptr, nullptr) != nullptr;
  };

  std::set<std::string> protocols_in;
  std::set<std::string> protocols_out;
  void* opaque = nullptr;
  while (const char* name = avio_enum_protocols(&opaque, 0)) {
    protocols_in.insert(name);
  }
  opaque = nullptr;
  while (const char* name = avio_enum_protocols(&opaque, 1)) {
    protocols_out.insert(name);
  }

  const char* config = avcodec_configuration();
  nlohmann::json j;
  j["probed_at_ms"] = now_ms();
  j["ffmpeg"] = {
      {"version", av_version_info()},
      {"config_fnv1a", fnv1a_hex(config ? config : "")},
      {"has_libmp3lame", config && std::strstr(config, "--enable-libmp3lame")}};
  j["encoders"] = {
      {"h264",
       {{"software", has_encoder("libx264")},
        {"hardware_mf", has_encoder("h264_mf")},
        {"verified", false}}},
      {"hevc",
       {{"software", has_encoder("libx265")},
        {"hardware_mf", has_encoder("hevc_mf")},
        {"verified", false}}},
      {"audio",
       {{"aac", has_encoder("aac")}, {"mp3", has_encoder("libmp3lame")}}}};
  j["containers"] = {{"mp4", has_muxer("mp4")},
                     {"matroska", has_muxer("matroska")},
                     {"mp3", has_muxer("mp3")},
                     {"wav", has_muxer("wav")}};
  j["protocols_in"] = protocols_in;
  j["protocols_out"] = protocols_out;
  j["features"] = {{"probe", true},
                   {"transcode", true},
                   {"remux", false},
                   {"extract", false},
                   {"analyze", false},
                   {"image", false},
                   {"batch", false}};
  return j.dump();
}

int32_t encoder_probe_impl(const std::string& codec) {
  const auto has = [](const char* name) {
    return avcodec_find_encoder_by_name(name) != nullptr;
  };
  if (codec == "h264" || codec == "avc") {
    return (has("h264_mf") || has("libx264")) ? 1 : 0;
  }
  if (codec == "hevc" || codec == "h265") {
    return (has("hevc_mf") || has("libx265")) ? 1 : 0;
  }
  if (codec == "aac") {
    return has("aac") ? 1 : 0;
  }
  if (codec == "mp3") {
    return has("libmp3lame") ? 1 : 0;
  }
  return 0;
}

}  // namespace ak

extern "C" int32_t ak_init(const char* config_json) {
  return ak::init_engine(config_json);
}

extern "C" void ak_shutdown(void) { ak::shutdown_engine(); }

extern "C" const char* ak_capabilities_json(void) {
  if (!ak::is_ready()) {
    return ak::dup_cstr("{\"ok\":false,\"code\":\"not_initialized\"}");
  }
  std::string json;
  {
    std::lock_guard<std::mutex> lock(ak::engine().mtx);
    json = ak::engine().capabilities_json;
  }
  return ak::dup_cstr(json);
}

extern "C" int32_t ak_encoder_probe(const char* codec) {
  if (!ak::is_ready() || !codec) {
    return 0;
  }
  return ak::encoder_probe_impl(codec);
}
