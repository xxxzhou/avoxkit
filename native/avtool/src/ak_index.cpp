// 只读媒体索引: avox IMediaReader buildIndex → 音频峰值 + 关键帧 JSON。
// 峰值线性 [0,1] → sqrt(p)*100, 保持 0-100 UI 曲线。
#include "ak_internal.hpp"
#include "ak_reader.hpp"

#include <cmath>
#include <memory>
#include <string>
#include <vector>

#include <nlohmann/json.hpp>

#include "avox/AvoxMedia.h"

namespace ak {
namespace {

using nlohmann::json;

std::string index_error(const char* code, const std::string& message) {
  json j;
  j["ok"] = false;
  j["code"] = code;
  j["message"] = message;
  return j.dump();
}

}  // namespace

std::string media_index_json(const std::string& uri, int32_t buckets) {
  if (uri.empty()) {
    return index_error("bad_source", "uri is empty");
  }
  std::unique_ptr<avox::IMediaReader> reader(avox::createMediaReader());
  if (!reader) {
    return index_error("not_implemented", "media reader unavailable");
  }
  ReaderShim shim;
  if (!openReader(*reader, shim, uri.c_str())) {
    reader->close();
    return index_error(media_error_code(shim.errorCode, "index_failed"),
                       shim.errorMessage);
  }
  avox::MediaIndexOptions options;
  options.buckets = buckets;  // [64,4000] 由 reader 钳位
  if (!reader->buildIndex(options)) {
    const avox::MediaError code = reader->lastError();
    const char* message = reader->lastErrorMessage();
    reader->close();
    return index_error(media_error_code(code, "index_failed"),
                       message ? message : "");
  }
  if (shim.errorCode != avox::MediaError::none) {
    reader->close();
    return index_error(media_error_code(shim.errorCode, "index_failed"),
                       shim.errorMessage);
  }

  json j;
  j["ok"] = true;
  j["duration_ms"] = shim.durationMs;
  j["bucket_ms"] = shim.bucketMs;
  j["has_audio"] = shim.hasAudio;
  json peaks = json::array();
  if (shim.waveAvailable) {
    for (const float peak : shim.peaks) {
      double value = peak;
      if (value < 0) {
        value = 0;
      } else if (value > 1) {
        value = 1;
      }
      int pct = static_cast<int>(std::sqrt(value) * 100.0);
      if (pct > 100) {
        pct = 100;
      }
      peaks.push_back(pct);
    }
  }
  j["peaks"] = std::move(peaks);
  j["keyframes_ms"] = shim.keyframes;

  reader->close();
  return j.dump();
}

}  // namespace ak

extern "C" const char* ak_media_index(const char* uri, int32_t buckets) {
  if (!uri || !*uri) {
    return ak::dup_cstr(
        "{\"ok\":false,\"code\":\"bad_source\",\"message\":\"uri is empty\"}");
  }
  return ak::dup_cstr(ak::media_index_json(uri, buckets));
}
