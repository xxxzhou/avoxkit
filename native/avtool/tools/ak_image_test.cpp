// 图像修复无头测试: ak_image_detect + kind=image(mask/auto)。
// 依赖 LaMa + YOLO 模型; 模型不在时只验证能力探测后跳过。
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <memory>
#include <mutex>
#include <string>

#ifdef _WIN32
#include <windows.h>
#else
#include <unistd.h>
#endif

#include <nlohmann/json.hpp>

#include "ak.h"
#include "avox/Avox.hpp"
#include "avox/AvoxImage.h"

namespace {

using nlohmann::json;

long current_pid() {
#ifdef _WIN32
  return static_cast<long>(::GetCurrentProcessId());
#else
  return static_cast<long>(::getpid());
#endif
}

struct Wait {
  std::mutex mtx;
  std::condition_variable cv;
  bool expecting = false;
  bool finished = false;
  bool ok = false;
  std::string code;
  std::string message;
};

void on_event(const char* text, void* user) {
  auto* wait = static_cast<Wait*>(user);
  const json event = json::parse(text, nullptr, false);
  if (event.is_discarded() || !event.is_object()) {
    return;
  }
  std::lock_guard<std::mutex> lock(wait->mtx);
  if (!wait->expecting) {
    return;
  }
  const std::string type = event.value("type", "");
  if (type == "done") {
    wait->finished = true;
    wait->ok = true;
    wait->cv.notify_all();
  } else if (type == "error") {
    wait->finished = true;
    wait->ok = false;
    wait->code = event.value("code", "");
    wait->message = event.value("message", "");
    wait->cv.notify_all();
  }
}

bool wait_finished(Wait& wait, int seconds) {
  std::unique_lock<std::mutex> lock(wait.mtx);
  return wait.cv.wait_for(lock, std::chrono::seconds(seconds),
                          [&] { return wait.finished; });
}

void begin(Wait& wait) {
  std::lock_guard<std::mutex> lock(wait.mtx);
  wait.expecting = true;
  wait.finished = false;
  wait.ok = false;
  wait.code.clear();
  wait.message.clear();
}

void end(Wait& wait) {
  std::lock_guard<std::mutex> lock(wait.mtx);
  wait.expecting = false;
}

int64_t submit(const std::string& input, const std::string& output,
               const json& image_params) {
  const json task = {{"schema", 1},
                     {"kind", "image"},
                     {"sources", json::array({{{"kind", "file"}, {"uri", input}}})},
                     {"outputs", json::array({{{"role", "primary"}, {"path", output}}})},
                     {"params", {{"image", image_params}}}};
  return ak_task_submit(task.dump().c_str());
}

bool png_file(const std::string& path) {
  std::ifstream file(std::filesystem::u8path(path), std::ios::binary);
  unsigned char header[8] = {};
  file.read(reinterpret_cast<char*>(header), sizeof(header));
  return file.gcount() == 8 && header[0] == 0x89 && header[1] == 0x50 &&
         header[2] == 0x4E && header[3] == 0x47;
}

bool image_file(const std::string& path, int32_t* width, int32_t* height) {
  std::unique_ptr<avox::IImageBuffer> buffer(avox::createImageBuffer());
  if (!buffer || !avox::loadImagePath(path.c_str(), buffer.get())) {
    return false;
  }
  const avox::ImageFormat format = buffer->getImageFormat();
  if (width) *width = format.width;
  if (height) *height = format.height;
  return true;
}

}  // namespace

int main(int argc, char** argv) {
  const std::string input =
      argc > 1 ? argv[1]
               : "D:/Work/github/avox/assets/images/godot/avox_godot_play_win.png";
  const std::string models =
      argc > 2 ? argv[2] : "D:/Work/github/avox_model/assets/models";
  const auto root = std::filesystem::temp_directory_path() /
                    ("avoxkit-image-test-" + std::to_string(current_pid()));
  std::error_code ec;
  std::filesystem::remove_all(root, ec);
  std::filesystem::create_directories(root / "work", ec);

  const json config = {{"work_dir", (root / "work").u8string()},
                       {"models_dir", models},
                       {"log_level", "info"}};
  if (ak_init(config.dump().c_str()) != AK_OK) {
    std::printf("FAIL init\n");
    return 1;
  }

  const bool has_models =
      std::filesystem::exists(std::filesystem::u8path(
          models + "/inpaint/lama_base.onnx")) &&
      std::filesystem::exists(std::filesystem::u8path(
          models + "/inpaint/yolo26m-seg_watermark.onnx"));

  Wait wait;
  ak_set_event_cb(on_event, &wait);

  const char* caps_raw = ak_capabilities_json();
  const json caps = json::parse(caps_raw, nullptr, false);
  ak_free_string(caps_raw);
  const bool plugin = caps.is_object() && caps.contains("features") &&
                      caps["features"].value("image", false);
  std::printf("capabilities: image_plugin=%d image_inpaint=%d\n", plugin,
              caps.is_object() && caps.contains("features") &&
                  caps["features"].value("image_inpaint", false));
  if (!has_models) {
    std::printf("SKIP: inpaint models not found under %s\n", models.c_str());
    ak_shutdown();
    return plugin ? 0 : 1;
  }
  if (!plugin) {
    std::printf("FAIL: avox_cv plugin is not loaded\n");
    ak_shutdown();
    return 1;
  }

  int32_t width = 0;
  int32_t height = 0;
  if (!image_file(input, &width, &height) || width <= 0 || height <= 0) {
    std::printf("FAIL: cannot load input image %s\n", input.c_str());
    ak_shutdown();
    return 1;
  }
  std::printf("input: %dx%d %s\n", width, height, input.c_str());

  const char* detect_raw =
      ak_image_detect(input.c_str(), "{\"threshold\":0.2,\"model\":\"lama\"}");
  const json detect = json::parse(detect_raw, nullptr, false);
  ak_free_string(detect_raw);
  if (detect.is_discarded() || !detect.value("ok", false)) {
    std::printf("FAIL: ak_image_detect: %s\n", detect.dump().c_str());
    ak_shutdown();
    return 1;
  }
  std::printf("detect: found=%d boxes=%zu width=%d height=%d detect_ms=%lld\n",
              detect.value("found", false), detect["boxes"].size(),
              detect.value("width", 0), detect.value("height", 0),
              detect.value("detect_ms", 0LL));
  for (size_t i = 0; i < detect["boxes"].size() && i < 3; i++) {
    std::printf("  box[%zu] %s\n", i, detect["boxes"][i].dump().c_str());
  }

  // 手绘 mask: 中间开一个白框, 保证有可修复区域
  const std::string mask_path = (root / "mask.png").u8string();
  {
    std::unique_ptr<avox::IImageBuffer> mask(avox::createImageBuffer());
    avox::ImageFormat format{};
    format.width = width;
    format.height = height;
    format.rowPitch = width;
    format.imageType = avox::ImageType::r8;
    mask->setImageFormat(format);
    uint8_t* data = mask->getPointer();
    std::memset(data, 0, static_cast<size_t>(width) * height);
    const int32_t left = width / 4;
    const int32_t right = width * 3 / 4;
    const int32_t top = height / 4;
    const int32_t bottom = height * 3 / 4;
    for (int32_t y = top; y < bottom; y++) {
      std::memset(data + static_cast<size_t>(y) * width + left, 255,
                  static_cast<size_t>(right - left));
    }
    if (!avox::saveImagePath(mask_path.c_str(), mask.get())) {
      std::printf("FAIL: cannot write mask\n");
      ak_shutdown();
      return 1;
    }
  }

  const std::string mask_out = (root / "mask-out.png").u8string();
  begin(wait);
  if (submit(input, mask_out,
             {{"mode", "mask"}, {"mask_path", mask_path}, {"model", "lama"}}) <= 0) {
    std::printf("FAIL: submit mask task rejected\n");
    ak_shutdown();
    return 1;
  }
  if (!wait_finished(wait, 300)) {
    std::printf("FAIL: mask task timeout\n");
    ak_shutdown();
    return 1;
  }
  end(wait);
  if (!wait.ok || !png_file(mask_out)) {
    std::printf("FAIL: mask task code=%s message=%s\n", wait.code.c_str(),
                wait.message.c_str());
    ak_shutdown();
    return 1;
  }
  int32_t out_w = 0;
  int32_t out_h = 0;
  if (!image_file(mask_out, &out_w, &out_h) || out_w != width || out_h != height) {
    std::printf("FAIL: mask output invalid %dx%d\n", out_w, out_h);
    ak_shutdown();
    return 1;
  }
  std::printf("mask task: ok %s (%dx%d)\n", mask_out.c_str(), out_w, out_h);

  // 自动模式: 没有水印是合法结果; 有检测结果时必须产出可解码的图
  const std::string auto_out = (root / "auto-out.png").u8string();
  begin(wait);
  if (submit(input, auto_out, {{"mode", "auto"}, {"model", "lama"}}) <= 0) {
    std::printf("FAIL: submit auto task rejected\n");
    ak_shutdown();
    return 1;
  }
  if (!wait_finished(wait, 300)) {
    std::printf("FAIL: auto task timeout\n");
    ak_shutdown();
    return 1;
  }
  end(wait);
  if (wait.ok) {
    int32_t a_w = 0;
    int32_t a_h = 0;
    if (!image_file(auto_out, &a_w, &a_h)) {
      std::printf("FAIL: auto output invalid\n");
      ak_shutdown();
      return 1;
    }
    std::printf("auto task: ok %s (%dx%d)\n", auto_out.c_str(), a_w, a_h);
  } else if (wait.code == "no_watermark") {
    std::printf("auto task: no watermark detected (expected for this sample)\n");
  } else {
    std::printf("FAIL: auto task code=%s message=%s\n", wait.code.c_str(),
                wait.message.c_str());
    ak_shutdown();
    return 1;
  }

  ak_shutdown();
  std::filesystem::remove_all(root, ec);
  std::printf("PASS\n");
  return 0;
}
