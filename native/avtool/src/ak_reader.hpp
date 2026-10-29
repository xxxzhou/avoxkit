#pragma once

// IMediaReader 的同步 shim: avox v1 回调在调用线程派发, 直接把结果存进本对象。
// ak_probe/ak_index 每次调用建一个 reader, open → 工作 → close。

#include <string>
#include <vector>

#include "avox/AvoxMedia.h"

namespace ak {

class ReaderShim : public avox::IMediaReaderOb {
 public:
  bool ready = false;

  avox::MediaOp errorOp = avox::MediaOp::open;
  avox::MediaError errorCode = avox::MediaError::none;
  std::string errorMessage;

  // index 结果拷贝(onIndexDone 的 peaks/keyframesMs 指针只在回调内有效)
  int64_t durationMs = 0;
  int32_t bucketMs = 0;
  bool hasAudio = false;
  bool waveAvailable = false;
  std::vector<float> peaks;
  std::vector<int64_t> keyframes;

  void onStateChange(avox::MediaReaderState, avox::MediaReaderState) override {}
  void onReady() override { ready = true; }
  void onIndexProgress(int32_t) override {}
  void onIndexDone(const avox::MediaIndexResult& result) override {
    durationMs = result.durationMs;
    bucketMs = result.bucketMs;
    hasAudio = result.hasAudio;
    waveAvailable = result.waveAvailable;
    peaks.clear();
    if (result.peaks && result.peakCount > 0) {
      peaks.assign(result.peaks, result.peaks + result.peakCount);
    }
    keyframes.clear();
    if (result.keyframesMs && result.keyframeCount > 0) {
      keyframes.assign(result.keyframesMs,
                       result.keyframesMs + result.keyframeCount);
    }
  }
  void onFrame(const avox::MediaFrameInfo&, avox::IImageBuffer*) override {}
  void onError(avox::MediaOp op, avox::MediaError code,
               const char* message) override {
    errorOp = op;
    errorCode = code;
    errorMessage = message ? message : "";
  }
  void onClose() override {}
};

// open 一次并等结果; 返回 false 时错误在 shim 里(含请求被拒的 lastError)。
inline bool openReader(avox::IMediaReader& reader, ReaderShim& shim,
                       const char* uri) {
  shim.ready = false;
  shim.errorCode = avox::MediaError::none;
  shim.errorMessage.clear();
  reader.setObserver(&shim);
  if (!reader.open(uri)) {
    shim.errorCode = reader.lastError();
    const char* message = reader.lastErrorMessage();
    shim.errorMessage = message ? message : "";
    return false;
  }
  return shim.ready;
}

// MediaError → ak JSON code; fallback 用于未细分错误
inline const char* media_error_code(avox::MediaError code,
                                    const char* fallback) {
  switch (code) {
    case avox::MediaError::inputOpenFailed:
    case avox::MediaError::findStreamInfoFailed:
      return "input_open_failed";
    case avox::MediaError::noVideo:
      return "no_video";
    case avox::MediaError::decoderMissing:
    case avox::MediaError::decodeFailed:
      return "decode_failed";
    case avox::MediaError::seekFailed:
      return "seek_failed";
    case avox::MediaError::unsupported:
      return "unsupported";
    case avox::MediaError::unsupportedPixFmt:
      return "unsupported_pix_fmt";
    case avox::MediaError::renderUnavailable:
      return "render_unavailable";
    case avox::MediaError::cancelled:
      return "cancelled";
    case avox::MediaError::invalidState:
    case avox::MediaError::invalidArgument:
      return "invalid_argument";
    case avox::MediaError::timeout:
      return "timeout";
    default:
      return fallback;
  }
}

}  // namespace ak
