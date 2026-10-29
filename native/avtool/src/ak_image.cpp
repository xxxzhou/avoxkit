#include "ak_internal.hpp"

#include <algorithm>
#include <filesystem>
#include <memory>
#include <mutex>
#include <string>

#include <nlohmann/json.hpp>

#include "avox/Avox.hpp"
#include "avox/AvoxImage.h"
#include "avox/AvoxVision.h"

namespace ak {
namespace {

using nlohmann::json;

// avox_cv 的 IWatermarkRemoval 不是线程安全的(共用预处理缓冲), 检测与任务
// 推理用同一把锁串行化; 模型只 open 一次, 之后切模型才重开。
struct ImageState {
  std::mutex mtx;
  avox::IWatermarkRemoval* remover = nullptr;
  std::string opened_model;
};

ImageState& image_state() {
  static ImageState state;
  return state;
}

bool model_file_ready(const char* relative, std::string& missing) {
  const std::string path = avox::getModelFilePath(relative);
  std::error_code ec;
  if (path.empty()) {
    missing = relative;
    return false;
  }
  const auto file = std::filesystem::u8path(path);
  if (!std::filesystem::exists(file, ec) || ec ||
      std::filesystem::file_size(file, ec) == 0 || ec) {
    missing = relative;
    return false;
  }
  return true;
}

std::unique_ptr<avox::IImageBuffer> load_image(const std::string& path) {
  std::unique_ptr<avox::IImageBuffer> buffer(avox::createImageBuffer());
  if (!buffer || !avox::loadImagePath(path.c_str(), buffer.get())) {
    return nullptr;
  }
  return buffer;
}

// 手绘 mask 理论上与源图同尺寸; 尺寸不一致时缩到源图, r8 走最近邻避免
// 依赖插件缩放对单通道的支持。
std::unique_ptr<avox::IImageBuffer> fit_mask(avox::IImageBuffer* mask,
                                             int32_t width, int32_t height) {
  const avox::ImageFormat format = mask->getImageFormat();
  if (format.width == width && format.height == height) {
    return nullptr;
  }
  std::unique_ptr<avox::IImageBuffer> scaled(avox::createImageBuffer());
  if (!scaled) {
    return nullptr;
  }
  if (format.imageType == avox::ImageType::r8) {
    avox::ImageFormat target{};
    target.width = width;
    target.height = height;
    target.rowPitch = width;
    target.imageType = avox::ImageType::r8;
    scaled->setImageFormat(target);
    const uint8_t* src = mask->getPointer();
    uint8_t* dst = scaled->getPointer();
    if (!src || !dst) {
      return nullptr;
    }
    for (int32_t y = 0; y < height; y++) {
      const int32_t sy = static_cast<int32_t>(
          static_cast<int64_t>(y) * format.height / height);
      for (int32_t x = 0; x < width; x++) {
        const int32_t sx = static_cast<int32_t>(
            static_cast<int64_t>(x) * format.width / width);
        dst[y * width + x] = src[sy * format.width + sx];
      }
    }
    return scaled;
  }
  if (!avox::resizeImage(mask, scaled.get(), width, height)) {
    return nullptr;
  }
  return scaled;
}

int32_t open_remover(const ImageOptions& options,
                     avox::IWatermarkRemoval** out, std::string& detail) {
  std::string missing;
  if (!image_models_ready(options.model, missing)) {
    detail = missing;
    return AK_E_MODEL_MISSING;
  }
  auto& state = image_state();
  if (!state.remover) {
    state.remover = avox::createWatermarkRemoval();
    if (!state.remover) {
      detail = "avox_cv plugin is not loaded";
      return AK_E_INPAINT_UNAVAILABLE;
    }
  }
  if (state.opened_model != options.model) {
    const avox::InpaintMode mode = options.model == "aotgan"
                                       ? avox::InpaintMode::aotgan
                                       : avox::InpaintMode::lama;
    state.remover->setInpaintMode(mode);
    state.remover->setModelLevel(avox::ModelLevel::base);
    // 本仓默认软解/软编, 推理同样先走 CPU; 显卡加速要等打包一并带上 DML 依赖
    state.remover->setUseGPU(false);
    if (!state.remover->open()) {
      state.opened_model.clear();
      detail = "inpaint model failed to load";
      return AK_E_INPAINT_FAILED;
    }
    state.opened_model = options.model;
  }
  *out = state.remover;
  return AK_OK;
}

const char* code_for(int32_t code) {
  switch (code) {
    case AK_E_MODEL_MISSING:
      return "model_missing";
    case AK_E_INPAINT_UNAVAILABLE:
      return "inpaint_unavailable";
    case AK_E_INPAINT_FAILED:
      return "inpaint_failed";
    default:
      return "image_failed";
  }
}

}  // namespace

bool image_plugin_available() {
  static std::atomic<int> cached{-1};
  if (cached.load() >= 0) {
    return cached.load() == 1;
  }
  avox::IWatermarkRemoval* probe = avox::createWatermarkRemoval();
  const bool available = probe != nullptr;
  delete probe;
  cached.store(available ? 1 : 0);
  return available;
}

bool image_models_ready(const std::string& model, std::string& missing) {
  if (model == "aotgan") {
    if (!model_file_ready("inpaint/aotgan-onnx-float/aotgan.onnx", missing)) {
      return false;
    }
  } else if (!model_file_ready("inpaint/lama_base.onnx", missing)) {
    return false;
  }
  // avox 的 open 总会加载检测模型(手绘 mask 也一样), 两个都要在
  return model_file_ready("inpaint/yolo26m-seg_watermark.onnx", missing);
}

ImageRunResult image_repair(const std::string& input, const std::string& temp,
                            const ImageOptions& options,
                            const ImageCallbacks& callbacks) {
  ImageRunResult result;
  const auto cancelled = [&] {
    return callbacks.cancelled && callbacks.cancelled(callbacks.ctx);
  };
  const auto stage = [&](const char* name) {
    if (callbacks.stage) {
      callbacks.stage(callbacks.ctx, name);
    }
  };
  if (cancelled()) {
    result.cancelled = true;
    return result;
  }

  auto& state = image_state();
  std::lock_guard<std::mutex> lock(state.mtx);

  avox::IWatermarkRemoval* remover = nullptr;
  std::string detail;
  int32_t code = open_remover(options, &remover, detail);
  if (code != AK_OK) {
    result.code = code_for(code);
    result.message = code == AK_E_MODEL_MISSING
                         ? "image repair model is not downloaded"
                         : "image repair is not available";
    result.detail = detail;
    return result;
  }
  remover->setMaskDilate(options.dilate);
  remover->setDetectThreshold(options.threshold);

  stage("decode");
  std::unique_ptr<avox::IImageBuffer> source = load_image(input);
  if (!source) {
    result.code = "image_decode_failed";
    result.message = "Cannot decode image";
    result.detail = input;
    return result;
  }
  const avox::ImageFormat source_format = source->getImageFormat();

  std::unique_ptr<avox::IImageBuffer> mask;
  if (options.mode == "mask") {
    stage("decode_mask");
    mask = load_image(options.mask_path);
    if (!mask) {
      result.code = "mask_load_failed";
      result.message = "Cannot read the mask image";
      result.detail = options.mask_path;
      return result;
    }
    std::unique_ptr<avox::IImageBuffer> fitted =
        fit_mask(mask.get(), source_format.width, source_format.height);
    if (fitted) {
      mask = std::move(fitted);
    }
  } else {
    stage("detect");
    mask.reset(avox::createImageBuffer());
    if (!mask || !remover->detect(source.get(), mask.get())) {
      result.code = "no_watermark";
      result.message = "No watermark detected";
      result.detail = "try the manual mask mode";
      return result;
    }
    result.watermarks = remover->getWatermarkCount();
  }

  if (cancelled()) {
    result.cancelled = true;
    return result;
  }
  stage("inpaint");
  std::unique_ptr<avox::IImageBuffer> output(avox::createImageBuffer());
  if (!output || !remover->inpaint(source.get(), mask.get(), output.get())) {
    result.code = "inpaint_failed";
    result.message = "Image inpainting failed";
    result.detail.clear();
    return result;
  }

  if (cancelled()) {
    result.cancelled = true;
    return result;
  }
  stage("encode");
  if (!avox::saveImagePath(temp.c_str(), output.get())) {
    result.code = "image_encode_failed";
    result.message = "Cannot write the repaired image";
    result.detail = temp;
    return result;
  }
  result.ok = true;
  return result;
}

std::string image_detect_json(const std::string& uri,
                              const std::string& request_json) {
  json reply;
  reply["ok"] = false;
  if (!is_ready()) {
    reply["code"] = "not_initialized";
    reply["message"] = "engine is not initialized";
    return reply.dump();
  }

  ImageOptions options;
  if (!request_json.empty()) {
    json request = json::parse(request_json, nullptr, false);
    if (request.is_discarded() || !request.is_object()) {
      reply["code"] = "bad_json";
      reply["message"] = "request must be a JSON object";
      return reply.dump();
    }
    options.model = request.value("model", options.model);
    options.threshold =
        std::max(0.0f, std::min(1.0f,
                               request.value("threshold", options.threshold)));
    if (options.model != "lama" && options.model != "aotgan") {
      reply["code"] = "bad_json";
      reply["message"] = "unsupported model: " + options.model;
      return reply.dump();
    }
  }

  auto& state = image_state();
  std::lock_guard<std::mutex> lock(state.mtx);
  avox::IWatermarkRemoval* remover = nullptr;
  std::string detail;
  const int32_t code = open_remover(options, &remover, detail);
  if (code != AK_OK) {
    reply["code"] = code_for(code);
    reply["message"] = code == AK_E_MODEL_MISSING
                           ? "image repair model is not downloaded"
                           : "image repair is not available";
    reply["detail"] = detail;
    return reply.dump();
  }
  remover->setDetectThreshold(options.threshold);

  std::unique_ptr<avox::IImageBuffer> source = load_image(uri);
  if (!source) {
    reply["code"] = "image_decode_failed";
    reply["message"] = "Cannot decode image";
    reply["detail"] = uri;
    return reply.dump();
  }
  const avox::ImageFormat format = source->getImageFormat();
  std::unique_ptr<avox::IImageBuffer> mask(avox::createImageBuffer());
  const int64_t started = now_ms();
  const bool found = mask && remover->detect(source.get(), mask.get());
  const int64_t elapsed = now_ms() - started;

  json boxes = json::array();
  if (found) {
    const int count = remover->getWatermarkCount();
    for (int i = 0; i < count; i++) {
      float x = 0, y = 0, w = 0, h = 0;
      if (!remover->getWatermarkBBox(i, &x, &y, &w, &h)) {
        continue;
      }
      boxes.push_back({{"x", x}, {"y", y}, {"w", w}, {"h", h}});
    }
  }
  reply["ok"] = true;
  reply["width"] = format.width;
  reply["height"] = format.height;
  reply["found"] = found;
  reply["boxes"] = std::move(boxes);
  reply["detect_ms"] = elapsed;
  return reply.dump();
}

}  // namespace ak
