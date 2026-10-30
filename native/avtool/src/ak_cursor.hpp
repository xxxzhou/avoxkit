#pragma once

#include <atomic>
#include <cstdint>
#include <cstdio>
#include <map>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace avox {
class ICaptureSession;
struct CaptureGeometry;
}

namespace ak {

// 光标遥测: 240Hz 采样 → cursor.bin(定长) + shapes.json + events.json。
// 只在引擎确认未把系统光标烧进画面(cursorMode=disabled/absent)时启用。
class CursorTelemetry {
 public:
  CursorTelemetry() = default;
  ~CursorTelemetry();
  CursorTelemetry(const CursorTelemetry&) = delete;
  CursorTelemetry& operator=(const CursorTelemetry&) = delete;

  bool start(const std::string& dir, avox::ICaptureSession* session,
             const avox::CaptureGeometry& geo, void* host_hwnd, bool enabled);
  void stop();
  void markPause();
  void markResume();

 private:
  struct Shape {
    int id = 0;
    int width = 0;
    int height = 0;
    int hotspotX = 0;
    int hotspotY = 0;
    int dpi = 96;
    std::string file;
  };
  struct Click {
    int64_t t = 0;
    int32_t x = 0;
    int32_t y = 0;
    int32_t inside = 0;
    std::string button;
  };
  struct Jump {
    int64_t t = 0;
    int32_t x = 0;
    int32_t y = 0;
  };
  struct PauseMark {
    int64_t t = 0;
    std::string action;
  };

  void run();
  bool write_shape(void* cursor, int* id);

  std::string dir_;
  avox::ICaptureSession* session_ = nullptr;
  int32_t geoX_ = 0;
  int32_t geoY_ = 0;
  int32_t geoW_ = 0;
  int32_t geoH_ = 0;
  void* host_ = nullptr;
  bool enabled_ = false;
  std::atomic<bool> running_{false};
  std::thread thread_;
  FILE* bin_ = nullptr;
  std::mutex mtx_;
  std::vector<Shape> shapes_;
  std::map<void*, int> shapeByHandle_;
  std::map<uint64_t, int> shapeByHash_;
  std::vector<Click> clicks_;
  std::vector<Jump> jumps_;
  std::vector<PauseMark> pauses_;
  int lastShape_ = 0;
  bool lastVisible_ = false;
  int32_t lastX_ = 0;
  int32_t lastY_ = 0;
  int64_t lastT_ = -1;
  bool lastLeft_ = false;
  bool lastRight_ = false;
  bool lastMiddle_ = false;
};

}  // namespace ak
