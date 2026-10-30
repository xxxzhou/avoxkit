#include "ak_cursor.hpp"

#include <chrono>
#include <cstring>
#include <filesystem>

#include <nlohmann/json.hpp>

#include "avox/AvoxCapture.h"
#include "avox/AvoxImage.h"

#ifdef _WIN32
#include <windows.h>
#endif

namespace ak {
namespace {

constexpr int kSampleIntervalMs = 4;  // 240Hz

#pragma pack(push, 1)
struct CursorRecord {
  uint32_t clockMs;
  int32_t x;
  int32_t y;
  uint16_t flags;
  uint16_t shapeId;
};
#pragma pack(pop)

static_assert(sizeof(CursorRecord) == 16, "cursor.bin record must be 16 bytes");

uint64_t hash_pixels(const uint8_t* data, size_t size, int w, int h, int hx,
                     int hy) {
  uint64_t hash = 1469598103934665603ull;
  for (size_t i = 0; i < size; i++) {
    hash ^= data[i];
    hash *= 1099511628211ull;
  }
  hash ^= (uint64_t)w * 31u + (uint64_t)h;
  hash *= 1099511628211ull;
  hash ^= (uint64_t)(hx + 1000) * 17u + (uint64_t)(hy + 1000);
  return hash;
}

#ifdef _WIN32

void apply_mask_alpha(HDC dc, HBITMAP mask, int w, int h,
                      std::vector<uint8_t>* bgra) {
  if (!mask) {
    for (int i = 0; i < w * h; i++) {
      (*bgra)[i * 4 + 3] = 255;
    }
    return;
  }
  const int stride = ((w + 31) / 32) * 4;
  std::vector<uint8_t> bits((size_t)stride * h);
  BITMAPINFO bi = {};
  bi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  bi.bmiHeader.biWidth = w;
  bi.bmiHeader.biHeight = -h;
  bi.bmiHeader.biPlanes = 1;
  bi.bmiHeader.biBitCount = 1;
  bi.bmiHeader.biCompression = BI_RGB;
  if (GetDIBits(dc, mask, 0, h, bits.data(), &bi, DIB_RGB_COLORS) != h) {
    for (int i = 0; i < w * h; i++) {
      (*bgra)[i * 4 + 3] = 255;
    }
    return;
  }
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      const uint8_t byte = bits[(size_t)y * stride + (x >> 3)];
      const bool transparent = ((byte >> (7 - (x & 7))) & 1) != 0;
      (*bgra)[((size_t)y * w + x) * 4 + 3] = transparent ? 0 : 255;
    }
  }
}

bool capture_cursor_pixels(HCURSOR cur, const ICONINFO& ii, int w, int h,
                           std::vector<uint8_t>* bgra) {
  bgra->assign((size_t)w * h * 4, 0);
  BITMAPINFO bi = {};
  bi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  bi.bmiHeader.biWidth = w;
  bi.bmiHeader.biHeight = -h;
  bi.bmiHeader.biPlanes = 1;
  bi.bmiHeader.biBitCount = 32;
  bi.bmiHeader.biCompression = BI_RGB;
  void* bits = nullptr;
  HDC dc = CreateCompatibleDC(nullptr);
  if (!dc) {
    return false;
  }
  HBITMAP dib = CreateDIBSection(dc, &bi, DIB_RGB_COLORS, &bits, nullptr, 0);
  if (!dib || !bits) {
    if (dib) {
      DeleteObject(dib);
    }
    DeleteDC(dc);
    return false;
  }
  bool ok = false;
  if (ii.hbmColor) {
    const int lines =
        GetDIBits(dc, ii.hbmColor, 0, h, bits, &bi, DIB_RGB_COLORS);
    ok = lines == h;
  }
  if (!ok) {
    HGDIOBJ old = SelectObject(dc, dib);
    std::memset(bits, 0, (size_t)w * h * 4);
    ok = DrawIconEx(dc, 0, 0, cur, w, h, 0, nullptr, DI_NORMAL) != FALSE;
    SelectObject(dc, old);
  }
  if (ok) {
    std::memcpy(bgra->data(), bits, (size_t)w * h * 4);
    bool hasAlpha = false;
    for (int i = 0; i < w * h; i++) {
      if ((*bgra)[(size_t)i * 4 + 3] != 0) {
        hasAlpha = true;
        break;
      }
    }
    if (!hasAlpha) {
      apply_mask_alpha(dc, ii.hbmMask, w, h, bgra);
    }
  }
  DeleteObject(dib);
  DeleteDC(dc);
  return ok;
}

#endif

}  // namespace

CursorTelemetry::~CursorTelemetry() { stop(); }

bool CursorTelemetry::start(const std::string& dir,
                            avox::ICaptureSession* session,
                            const avox::CaptureGeometry& geo, void* host_hwnd,
                            bool enabled) {
  stop();
  dir_ = dir;
  session_ = session;
  geoX_ = geo.x;
  geoY_ = geo.y;
  geoW_ = geo.width;
  geoH_ = geo.height;
  host_ = host_hwnd;
  enabled_ = enabled;
  shapes_.clear();
  shapeByHandle_.clear();
  shapeByHash_.clear();
  clicks_.clear();
  jumps_.clear();
  pauses_.clear();
  lastShape_ = 0;
  lastVisible_ = false;
  lastT_ = -1;
  lastLeft_ = lastRight_ = lastMiddle_ = false;
  std::error_code ec;
  std::filesystem::create_directories(dir_ + "/shapes", ec);
  bin_ = std::fopen((dir_ + "/cursor.bin").c_str(), "wb");
  if (!bin_) {
    return false;
  }
  if (enabled_) {
    running_ = true;
    thread_ = std::thread([this] { run(); });
  }
  return true;
}

void CursorTelemetry::stop() {
  running_ = false;
  if (thread_.joinable()) {
    thread_.join();
  }
  if (bin_) {
    std::fclose(bin_);
    bin_ = nullptr;
  }
  if (session_) {
    using json = nlohmann::json;
    json shapes = {{"shapes", json::array()}};
    for (const auto& s : shapes_) {
      shapes["shapes"].push_back(
          {{"id", s.id}, {"file", s.file}, {"width", s.width},
           {"height", s.height}, {"hotspotX", s.hotspotX},
           {"hotspotY", s.hotspotY}, {"dpi", s.dpi}, {"type", "other"},
           {"animated", false}});
    }
    json events = {{"clicks", json::array()},
                   {"jumps", json::array()},
                   {"pauses", json::array()}};
    for (const auto& c : clicks_) {
      events["clicks"].push_back({{"t", c.t}, {"x", c.x}, {"y", c.y},
                                  {"inside", c.inside}, {"button", c.button}});
    }
    for (const auto& j : jumps_) {
      events["jumps"].push_back({{"t", j.t}, {"x", j.x}, {"y", j.y}});
    }
    for (const auto& p : pauses_) {
      events["pauses"].push_back({{"t", p.t}, {"action", p.action}});
    }
    auto write = [](const std::string& path, const json& value) {
      std::FILE* f = nullptr;
      if (fopen_s(&f, path.c_str(), "wb") == 0 && f) {
        const std::string text = value.dump(2);
        std::fwrite(text.data(), 1, text.size(), f);
        std::fclose(f);
      }
    };
    write(dir_ + "/shapes.json", shapes);
    write(dir_ + "/events.json", events);
  }
  session_ = nullptr;
}

void CursorTelemetry::markPause() {
  if (!enabled_) {
    return;
  }
  const int64_t t = session_ ? session_->getClockMs() : -1;
  std::lock_guard<std::mutex> lock(mtx_);
  pauses_.push_back({t, "pause"});
}

void CursorTelemetry::markResume() {
  if (!enabled_) {
    return;
  }
  const int64_t t = session_ ? session_->getClockMs() : -1;
  std::lock_guard<std::mutex> lock(mtx_);
  pauses_.push_back({t, "resume"});
}

void CursorTelemetry::run() {
#ifdef _WIN32
  using clock = std::chrono::steady_clock;
  auto next = clock::now();
  while (running_) {
    if (session_ && session_->getState() == avox::CaptureState::recording &&
        bin_) {
      POINT pt = {};
      CURSORINFO ci = {};
      ci.cbSize = sizeof(ci);
      if (GetCursorPos(&pt) && GetCursorInfo(&ci)) {
        const int64_t t = session_->getClockMs();
        if (t >= 0) {
          const int32_t x = pt.x - geoX_;
          const int32_t y = pt.y - geoY_;
          bool overHost = false;
          if (host_) {
            RECT r = {};
            if (GetWindowRect((HWND)host_, &r)) {
              POINT q = {pt.x, pt.y};
              overHost = PtInRect(&r, q) != FALSE;
            }
          }
          const bool inside =
              !overHost && x >= 0 && y >= 0 && x < geoW_ && y < geoH_;
          const bool visible = (ci.flags & CURSOR_SHOWING) != 0;
          int shapeId = lastShape_;
          if (ci.hCursor) {
            auto it = shapeByHandle_.find(ci.hCursor);
            if (it != shapeByHandle_.end()) {
              shapeId = it->second;
            } else {
              int id = 0;
              if (write_shape(ci.hCursor, &id)) {
                shapeByHandle_[ci.hCursor] = id;
                shapeId = id;
              }
            }
          }
          const bool left = (GetAsyncKeyState(VK_LBUTTON) & 0x8000) != 0;
          const bool right = (GetAsyncKeyState(VK_RBUTTON) & 0x8000) != 0;
          const bool middle = (GetAsyncKeyState(VK_MBUTTON) & 0x8000) != 0;
          if (left && !lastLeft_) {
            std::lock_guard<std::mutex> lock(mtx_);
            clicks_.push_back({t, x, y, inside ? 1 : 0, "left"});
          }
          if (right && !lastRight_) {
            std::lock_guard<std::mutex> lock(mtx_);
            clicks_.push_back({t, x, y, inside ? 1 : 0, "right"});
          }
          if (middle && !lastMiddle_) {
            std::lock_guard<std::mutex> lock(mtx_);
            clicks_.push_back({t, x, y, inside ? 1 : 0, "middle"});
          }
          if (lastT_ >= 0 && t > lastT_ && t - lastT_ < 50) {
            const int64_t dx = x - lastX_;
            const int64_t dy = y - lastY_;
            if (dx * dx + dy * dy > 250 * 250) {
              std::lock_guard<std::mutex> lock(mtx_);
              jumps_.push_back({t, x, y});
            }
          }
          CursorRecord rec = {};
          rec.clockMs = (uint32_t)std::min<int64_t>(t, 0xFFFFFFFFll);
          rec.x = x;
          rec.y = y;
          rec.flags = (uint16_t)((visible ? 1 : 0) | (inside ? 2 : 0) |
                                 (left ? 4 : 0) | (right ? 8 : 0) |
                                 (middle ? 16 : 0));
          rec.shapeId = (uint16_t)shapeId;
          std::fwrite(&rec, sizeof(rec), 1, bin_);
          lastShape_ = shapeId;
          lastVisible_ = visible;
          lastX_ = x;
          lastY_ = y;
          lastT_ = t;
          lastLeft_ = left;
          lastRight_ = right;
          lastMiddle_ = middle;
        }
      }
    }
    next += std::chrono::milliseconds(kSampleIntervalMs);
    std::this_thread::sleep_until(next);
  }
#endif
}

bool CursorTelemetry::write_shape(void* cursor, int* id) {
#ifdef _WIN32
  HCURSOR cur = (HCURSOR)cursor;
  ICONINFO ii = {};
  if (!GetIconInfo(cur, &ii)) {
    return false;
  }
  BITMAP bm = {};
  HBITMAP sizeBitmap = ii.hbmColor ? ii.hbmColor : ii.hbmMask;
  if (!sizeBitmap || !GetObject(sizeBitmap, sizeof(bm), &bm)) {
    if (ii.hbmMask) {
      DeleteObject(ii.hbmMask);
    }
    if (ii.hbmColor) {
      DeleteObject(ii.hbmColor);
    }
    return false;
  }
  const int w = bm.bmWidth;
  // 单色光标掩码含 AND/XOR 两平面, 高度是图标两倍
  const int h = ii.hbmColor ? bm.bmHeight : (bm.bmHeight / 2);
  std::vector<uint8_t> pixels;
  const bool ok = capture_cursor_pixels(cur, ii, w, h, &pixels);
  const uint64_t hash =
      hash_pixels(pixels.data(), pixels.size(), w, h, ii.xHotspot, ii.yHotspot);
  auto found = shapeByHash_.find(hash);
  if (found != shapeByHash_.end()) {
    *id = found->second;
    if (ii.hbmMask) {
      DeleteObject(ii.hbmMask);
    }
    if (ii.hbmColor) {
      DeleteObject(ii.hbmColor);
    }
    return *id > 0;
  }
  if (!ok) {
    if (ii.hbmMask) {
      DeleteObject(ii.hbmMask);
    }
    if (ii.hbmColor) {
      DeleteObject(ii.hbmColor);
    }
    return false;
  }
  const int newId = (int)shapes_.size() + 1;
  char name[64] = {};
  std::snprintf(name, sizeof(name), "shapes/%04d.png", newId);
  avox::IImageBuffer* buf = avox::createImageBuffer();
  bool saved = false;
  if (buf) {
    avox::ImageFormat fmt = {};
    fmt.width = w;
    fmt.height = h;
    fmt.rowPitch = w * 4;
    fmt.imageType = avox::ImageType::bgra8;
    buf->setImageFormat(fmt);
    if (buf->getBufferSize() >= (int32_t)pixels.size()) {
      std::memcpy(buf->getPointer(), pixels.data(), pixels.size());
      saved = avox::saveImagePath((dir_ + "/" + name).c_str(), buf);
    }
    delete buf;
  }
  if (saved) {
    Shape shape;
    shape.id = newId;
    shape.width = w;
    shape.height = h;
    shape.hotspotX = ii.xHotspot;
    shape.hotspotY = ii.yHotspot;
    shape.file = name;
    int dpi = 96;
    if (host_) {
      using Fn = UINT(WINAPI*)(HWND);
      auto fn = reinterpret_cast<Fn>(GetProcAddress(
          GetModuleHandleW(L"user32.dll"), "GetDpiForWindow"));
      if (fn) {
        dpi = (int)fn((HWND)host_);
      }
    }
    shape.dpi = dpi;
    shapes_.push_back(shape);
    shapeByHash_[hash] = newId;
    *id = newId;
  }
  if (ii.hbmMask) {
    DeleteObject(ii.hbmMask);
  }
  if (ii.hbmColor) {
    DeleteObject(ii.hbmColor);
  }
  return saved;
#else
  (void)cursor;
  (void)id;
  return false;
#endif
}

}  // namespace ak
