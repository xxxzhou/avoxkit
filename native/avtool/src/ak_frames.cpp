// 抓帧 shim: IMediaReader::grabFrame 出图 + avox JPEG 编码, 不直链 libav。
// 目标时间生成(count/等距)与 JSON 组装留在本层; 方向由渲染层统一保证,
// width/height 取回调图像的实际 ImageFormat(不是请求宽/probe 预算)。
#include "ak_internal.hpp"

#include <algorithm>
#include <memory>
#include <mutex>
#include <string>
#include <utility>
#include <vector>

#include <nlohmann/json.hpp>

#include "ak_reader.hpp"
#include "avox/AvoxImage.h"
#include "avox/AvoxMedia.h"

namespace ak {
namespace {

using nlohmann::json;

struct Request {
  int32_t count = 12;
  int32_t width = 320;
  int32_t quality = 75;
  std::vector<int64_t> times;
};

std::string frames_error(const std::string& code, const std::string& message) {
  json j;
  j["ok"] = false;
  j["code"] = code;
  j["message"] = message;
  return j.dump();
}

int32_t clamped(int32_t value, int32_t lo, int32_t hi) {
  return value < lo ? lo : (value > hi ? hi : value);
}

Request parse_request(const std::string& text) {
  Request request;
  if (text.empty()) {
    return request;
  }
  const json j = json::parse(text, nullptr, false);
  if (!j.is_object()) {
    return request;
  }
  if (j.contains("count") && j["count"].is_number()) {
    request.count = clamped(j["count"].get<int32_t>(), 1, 48);
  }
  if (j.contains("width") && j["width"].is_number()) {
    request.width = clamped(j["width"].get<int32_t>(), 48, 1280);
  }
  if (j.contains("quality") && j["quality"].is_number()) {
    request.quality = clamped(j["quality"].get<int32_t>(), 30, 95);
  }
  if (j.contains("times_ms") && j["times_ms"].is_array()) {
    for (const auto& item : j["times_ms"]) {
      if (!item.is_number() || request.times.size() >= 64) {
        break;
      }
      request.times.push_back(std::max<int64_t>(0, item.get<int64_t>()));
    }
  }
  return request;
}

// 单帧回调: 当场编码 JPEG(reader 的图像只在回调内有效)
class FrameShim : public avox::IMediaReaderOb {
 public:
  bool ready = false;
  bool frameOk = false;
  int32_t frameWidth = 0;
  int32_t frameHeight = 0;
  int64_t frameMs = 0;
  std::string frameJpeg;
  std::string encodeError;
  int32_t quality = 75;

  avox::MediaOp errorOp = avox::MediaOp::open;
  avox::MediaError errorCode = avox::MediaError::none;
  std::string errorMessage;

  void onReady() override { ready = true; }

  void onFrame(const avox::MediaFrameInfo& info,
               avox::IImageBuffer* image) override {
    if (!image) {
      return;
    }
    const avox::ImageFormat format = image->getImageFormat();
    avox::IEncodeConfig config = {};
    config.encodeType = avox::IEncodeType::jpg;
    config.quality = quality;
    // avox 的 getImageBase64 用进程级 static 缓冲; 缩略图与精确帧会在两个
    // isolate 里并发编码, 取串和拷贝都必须在锁内, 否则会读到半截 base64。
    static std::mutex encodeMutex;
    {
      std::lock_guard<std::mutex> lock(encodeMutex);
      const char* base64 = avox::getImageBase64(image, config);
      if (!base64) {
        encodeError = "jpeg encode failed";
        return;
      }
      frameJpeg.assign(base64);
    }
    frameWidth = format.width;
    frameHeight = format.height;
    frameMs = info.actualMs;
    frameOk = true;
  }

  void onError(avox::MediaOp op, avox::MediaError code,
               const char* message) override {
    errorOp = op;
    errorCode = code;
    errorMessage = message ? message : "";
  }
};

}  // namespace

std::string media_frames_json(const std::string& uri,
                              const std::string& request_text) {
  if (uri.empty()) {
    return frames_error("bad_source", "uri is empty");
  }
  const Request request = parse_request(request_text);

  json result;
  result["ok"] = true;
  result["duration_ms"] = 0;
  result["has_video"] = false;
  result["frames"] = json::array();
  result["width"] = 0;
  result["height"] = 0;

  std::unique_ptr<avox::IMediaReader> reader(avox::createMediaReader());
  if (!reader) {
    return frames_error("unsupported", "media reader is not built in");
  }
  FrameShim shim;
  shim.quality = request.quality;
  reader->setObserver(&shim);
  if (!reader->open(uri.c_str())) {
    return frames_error(media_error_code(reader->lastError(), "input_open_failed"),
                        reader->lastErrorMessage());
  }
  // sourceInfo 只在 close 前有效, 先把时长/轨数取出来
  avox::ISourceInfo* source = reader->getSourceInfo();
  int64_t duration_ms = source ? source->durationMs() : 0;
  if (duration_ms < 0) {
    duration_ms = 0;
  }
  const bool has_video = source && source->videoSize() > 0;
  result["duration_ms"] = duration_ms;
  result["has_video"] = has_video;
  if (!has_video) {
    reader->close();
    return result.dump();
  }

  std::vector<int64_t> targets = request.times;
  if (targets.empty()) {
    const int64_t span = std::max<int64_t>(1, duration_ms);
    for (int32_t i = 0; i < request.count; ++i) {
      // 每格取中点, 缩略图条首尾都能代表自己的时间段
      targets.push_back(span * (2 * i + 1) / (2 * request.count));
    }
  }

  json frames = json::array();
  int32_t out_width = 0;
  int32_t out_height = 0;
  std::string failed_code;
  std::string failed_message;
  for (size_t index = 0; index < targets.size(); ++index) {
    shim.frameOk = false;
    shim.frameJpeg.clear();
    shim.errorCode = avox::MediaError::none;
    shim.errorMessage.clear();
    avox::MediaFrameRequest frame_request = {};
    frame_request.timeMs = targets[index];
    frame_request.width = request.width;
    if (!reader->grabFrame(frame_request)) {
      // 请求未被接受(状态/参数): 读 lastError, 首帧即失败则不再重试
      failed_code =
          media_error_code(reader->lastError(), "decode_failed");
      const char* message = reader->lastErrorMessage();
      failed_message = message ? message : "";
      if (index == 0) {
        break;
      }
      continue;
    }
    if (!shim.frameOk) {
      failed_code = shim.encodeError.empty()
                        ? media_error_code(shim.errorCode, "decode_failed")
                        : "encode_failed";
      failed_message =
          shim.encodeError.empty() ? shim.errorMessage : shim.encodeError;
      // 结构性失败(VK 不可用/格式不支持/无视频轨)后续帧也不会成功
      if (shim.errorCode == avox::MediaError::renderUnavailable ||
          shim.errorCode == avox::MediaError::unsupportedPixFmt ||
          shim.errorCode == avox::MediaError::noVideo) {
        break;
      }
      continue;
    }
    out_width = shim.frameWidth;
    out_height = shim.frameHeight;
    frames.push_back({{"ms", shim.frameMs}, {"image", std::move(shim.frameJpeg)}});
  }
  reader->close();

  result["width"] = out_width;
  result["height"] = out_height;
  result["frames"] = std::move(frames);
  if (result["frames"].empty() && !failed_code.empty()) {
    result["reason"] = failed_code;
    result["message"] = failed_message;
  }
  return result.dump();
}

}  // namespace ak

extern "C" const char* ak_media_frames(const char* uri,
                                       const char* request_json) {
  if (!uri || !*uri) {
    return ak::dup_cstr(
        "{\"ok\":false,\"code\":\"bad_source\",\"message\":\"uri is empty\"}");
  }
  return ak::dup_cstr(
      ak::media_frames_json(uri, request_json ? request_json : ""));
}
