// 复现「取消后再启动, 预览画面不动」: 第一个任务录制中取消, 第二个任务
// 重新绑定同一预览窗, 采样子窗内容判断是否还在刷新。
#include "ak.h"

#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <string>
#include <thread>
#include <vector>

#include <nlohmann/json.hpp>

#ifdef _WIN32
#include <windows.h>
#endif

namespace {

std::atomic<bool> g_recording{false};
std::atomic<bool> g_terminal{false};

void on_event(const char* event_json, void*) {
  const std::string text = event_json ? event_json : "";
  try {
    const auto event = nlohmann::json::parse(text);
    const std::string type = event.value("type", "");
    if (type == "state" && event.value("stage", "") == "recording") {
      g_recording.store(true);
    }
    if (type == "done" || type == "error" ||
        (type == "state" && event.value("state", "") == "cancelled")) {
      g_terminal.store(true);
    }
  } catch (const std::exception&) {
  }
  ak_event_free(event_json);
}

std::atomic<HWND> g_host{nullptr};

LRESULT CALLBACK host_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
  return DefWindowProcW(hwnd, msg, wp, lp);
}

void host_thread() {
  WNDCLASSEXW wc = {};
  wc.cbSize = sizeof(wc);
  wc.lpfnWndProc = host_proc;
  wc.hInstance = GetModuleHandleW(nullptr);
  wc.lpszClassName = L"ak_preview_restart_host";
  RegisterClassExW(&wc);
  HWND hwnd = CreateWindowExW(0, wc.lpszClassName, L"preview restart",
                              WS_OVERLAPPEDWINDOW | WS_VISIBLE, 40, 40, 800,
                              600, nullptr, nullptr, GetModuleHandleW(nullptr),
                              nullptr);
  g_host.store(hwnd);
  MSG msg;
  while (GetMessageW(&msg, nullptr, 0, 0) > 0) {
    TranslateMessage(&msg);
    DispatchMessageW(&msg);
  }
  UnregisterClassW(wc.lpszClassName, GetModuleHandleW(nullptr));
}

void wait_ms(int ms) { std::this_thread::sleep_for(std::chrono::milliseconds(ms)); }

bool wait_for(const std::atomic<bool>& flag, int timeout_ms) {
  const auto deadline =
      std::chrono::steady_clock::now() + std::chrono::milliseconds(timeout_ms);
  while (std::chrono::steady_clock::now() < deadline) {
    if (flag.load()) {
      return true;
    }
    wait_ms(50);
  }
  return flag.load();
}

HWND find_preview(HWND host) {
  HWND found = nullptr;
  HWND child = nullptr;
  while ((child = FindWindowExW(host, child, L"avoxkit_preview", nullptr)) !=
         nullptr) {
    found = child;
  }
  return found;
}

// 预览窗里最上层那个引擎子窗, 也就是当前真正上屏的那块
HWND top_engine_child(HWND preview) {
  return preview ? GetWindow(preview, GW_CHILD) : nullptr;
}

uint64_t capture_hash(HWND hwnd, int* out_w, int* out_h, int* out_lit) {
  *out_w = *out_h = *out_lit = 0;
  if (!hwnd) {
    return 0;
  }
  RECT rc;
  if (!GetClientRect(hwnd, &rc)) {
    return 0;
  }
  const int w = rc.right - rc.left;
  const int h = rc.bottom - rc.top;
  if (w <= 0 || h <= 0) {
    return 0;
  }
  // Vulkan 子窗不在 GDI 重定向面里, PrintWindow 只会拿到窗口类背景;
  // 从桌面 DC 抓合成后的实际像素
  HDC screen = GetDC(nullptr);
  POINT origin = {0, 0};
  ClientToScreen(hwnd, &origin);
  HDC mem = CreateCompatibleDC(screen);
  HBITMAP bmp = CreateCompatibleBitmap(screen, w, h);
  HGDIOBJ old = SelectObject(mem, bmp);
  const BOOL ok = BitBlt(mem, 0, 0, w, h, screen, origin.x, origin.y, SRCCOPY);
  BITMAPINFO bi = {};
  bi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  bi.bmiHeader.biWidth = w;
  bi.bmiHeader.biHeight = -h;
  bi.bmiHeader.biPlanes = 1;
  bi.bmiHeader.biBitCount = 32;
  bi.bmiHeader.biCompression = BI_RGB;
  std::vector<uint32_t> pixels(static_cast<size_t>(w) * h);
  const int lines = GetDIBits(mem, bmp, 0, h, pixels.data(), &bi, DIB_RGB_COLORS);
  SelectObject(mem, old);
  DeleteObject(bmp);
  DeleteDC(mem);
  ReleaseDC(nullptr, screen);
  if (!ok || lines != h) {
    return 0;
  }
  uint64_t hash = 1469598103934665603ull;
  int lit = 0;
  for (size_t i = 0; i < pixels.size(); i += 7) {
    const uint32_t px = pixels[i];
    if ((px & 0x00FFFFFFu) != 0) {
      lit++;
    }
    hash ^= px;
    hash *= 1099511628211ull;
  }
  *out_w = w;
  *out_h = h;
  *out_lit = lit;
  return hash;
}

void dump_children(const char* tag) {
  HWND host = g_host.load();
  HWND preview = find_preview(host);
  std::printf("%s children:", tag);
  HWND child = preview ? GetWindow(preview, GW_CHILD) : nullptr;
  const auto start = std::chrono::steady_clock::now();
  while (child) {
    wchar_t cls[128] = {};
    GetClassNameW(child, cls, 127);
    RECT rc = {};
    GetWindowRect(child, &rc);
    std::printf(" [%p %ls vis=%d %ldx%ld]", (void*)child, cls,
                IsWindowVisible(child) ? 1 : 0, rc.right - rc.left,
                rc.bottom - rc.top);
    child = GetWindow(child, GW_HWNDNEXT);
  }
  std::printf(" (%lldms)\n",
              (long long)std::chrono::duration_cast<std::chrono::milliseconds>(
                  std::chrono::steady_clock::now() - start)
                  .count());
  std::fflush(stdout);
}

void print_capture(const char* tag) {
  HWND host = g_host.load();
  HWND preview = find_preview(host);
  HWND eng = top_engine_child(preview);
  int w = 0, h = 0, lit = 0;
  const uint64_t hash = capture_hash(eng, &w, &h, &lit);
  std::printf("%s preview=%p engine=%p size=%dx%d lit=%d hash=%016llx\n", tag,
              (void*)preview, (void*)eng, w, h, lit,
              (unsigned long long)hash);
  // 从上层到下层列出预览窗的全部子窗, 确认真正上屏的是哪一个
  HWND child = preview ? GetWindow(preview, GW_CHILD) : nullptr;
  while (child) {
    wchar_t cls[128] = {};
    GetClassNameW(child, cls, 127);
    RECT rc = {};
    GetWindowRect(child, &rc);
    int cw = 0, ch = 0, clit = 0;
    const uint64_t chash = capture_hash(child, &cw, &ch, &clit);
    std::printf("  child=%p class=%ls visible=%d rect=%ld,%ld,%ld,%ld "
                "lit=%d hash=%016llx\n",
                (void*)child, cls, IsWindowVisible(child) ? 1 : 0, rc.left,
                rc.top, rc.right, rc.bottom, clit,
                (unsigned long long)chash);
    child = GetWindow(child, GW_HWNDNEXT);
  }
  std::fflush(stdout);
}

std::string task_json(const std::string& input, const std::string& output) {
  nlohmann::json task;
  task["schema"] = 1;
  task["kind"] = "transcode";
  task["sources"] = nlohmann::json::array({{{"kind", "file"}, {"uri", input}}});
  task["outputs"] =
      nlohmann::json::array({{{"role", "primary"}, {"path", output}}});
  task["params"] = {
      {"container", "mp4"},
      {"overwrite", true},
      {"video",
       {{"codec", "h264"},
        {"hardware", "off"},
        {"rate_mode", "quality"},
        {"quality", 60},
        {"width", 640},
        {"height", 360}}},
      {"audio", {{"codec", "aac"}, {"bitrate_kbps", -1}}}};
  return task.dump();
}

}  // namespace

int main(int argc, char** argv) {
  if (argc < 4) {
    std::printf("usage: ak_preview_restart <in> <out_a> <out_b> [work_dir]\n");
    return 2;
  }
  const std::string input = argv[1];
  const std::string out_a = argv[2];
  const std::string out_b = argv[3];
  const std::string work_dir = argc >= 5 ? argv[4] : "preview_restart_work";

  nlohmann::json config;
  config["work_dir"] = work_dir;
  config["log_level"] = "info";
  if (ak_init(config.dump().c_str()) != 0) {
    std::printf("init failed\n");
    return 1;
  }
  ak_set_event_cb(on_event, nullptr);

  std::thread host(host_thread);
  wait_ms(300);
  HWND hwnd = g_host.load();
  if (!hwnd) {
    std::printf("host window failed\n");
    return 1;
  }
  ak_preview_set_host(hwnd);
  wait_ms(100);
  // 抓屏要求窗口不被遮挡
  SetWindowPos(hwnd, HWND_TOPMOST, 0, 0, 800, 600, SWP_SHOWWINDOW);
  SetForegroundWindow(hwnd);
  wait_ms(200);
  ak_preview_open();
  ak_preview_rect(20, 20, 640, 360);
  wait_ms(100);

  // A: 录制中取消 (应用里预览先绑, 取消时任务还在跑)
  const int64_t id_a = ak_task_submit(task_json(input, out_a).c_str());
  std::printf("task A id=%lld\n", (long long)id_a);
  ak_preview_bind(id_a);
  wait_for(g_recording, 15000);
  wait_ms(1500);
  dump_children("A recording");
  print_capture("A t0");
  wait_ms(700);
  print_capture("A t1");
  std::printf("cancel A\n");
  g_terminal.store(false);
  ak_task_cancel(id_a);
  wait_for(g_terminal, 15000);
  wait_ms(600);
  dump_children("A cancelled");

  // B: 取消后立刻再启动; 应用的预览控件此时会重建(unbind/close/open/bind)
  g_recording.store(false);
  const int64_t id_b = ak_task_submit(task_json(input, out_b).c_str());
  std::printf("task B id=%lld\n", (long long)id_b);
  ak_preview_bind(id_b);
  wait_for(g_recording, 15000);
  wait_ms(200);
  dump_children("B recording");
  ak_preview_unbind();
  ak_preview_close();
  ak_preview_open();
  ak_preview_rect(20, 20, 640, 360);
  ak_preview_bind(id_b);
  wait_ms(300);
  dump_children("B rebound");
  wait_ms(1200);
  print_capture("B t0");
  wait_ms(700);
  print_capture("B t1");
  wait_ms(700);
  print_capture("B t2");

  ak_task_cancel(id_b);
  wait_ms(800);
  ak_preview_close();
  ak_shutdown();

  PostMessageW(hwnd, WM_CLOSE, 0, 0);
  PostMessageW(hwnd, WM_QUIT, 0, 0);
  if (host.joinable()) {
    host.join();
  }
  std::printf("done\n");
  return 0;
}
