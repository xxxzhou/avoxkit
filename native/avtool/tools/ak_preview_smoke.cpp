// 预览生命周期隔离测试: 不走 Flutter/UIA, 直接用宿主窗验证
// bind -> unbind -> bind 时 setSurface/setOffSurface 不会带崩转码线程。
#include "ak.h"

#include <atomic>
#include <chrono>
#include <cstdio>
#include <mutex>
#include <string>
#include <thread>

#include <nlohmann/json.hpp>

#ifdef _WIN32
#include <windows.h>
#endif

namespace {

std::mutex g_mtx;
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
  wc.lpszClassName = L"ak_preview_smoke_host";
  RegisterClassExW(&wc);
  HWND hwnd = CreateWindowExW(0, wc.lpszClassName, L"", WS_OVERLAPPEDWINDOW,
                              0, 0, 640, 480, nullptr, nullptr,
                              GetModuleHandleW(nullptr), nullptr);
  g_host.store(hwnd);
  MSG msg;
  while (GetMessageW(&msg, nullptr, 0, 0) > 0) {
    TranslateMessage(&msg);
    DispatchMessageW(&msg);
  }
  UnregisterClassW(wc.lpszClassName, GetModuleHandleW(nullptr));
}

void wait_ms(int ms) {
  std::this_thread::sleep_for(std::chrono::milliseconds(ms));
}

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

}  // namespace

int main(int argc, char** argv) {
  if (argc < 4) {
    std::printf("usage: ak_preview_smoke <in> <out> <work_dir>\n");
    return 2;
  }
  const std::string input = argv[1];
  const std::string output = argv[2];
  const std::string work_dir = argv[3];

  nlohmann::json config;
  config["work_dir"] = work_dir;
  config["log_level"] = "info";
  if (ak_init(config.dump().c_str()) != 0) {
    std::printf("init failed\n");
    return 1;
  }
  ak_set_event_cb(on_event, nullptr);

  std::thread host(host_thread);
  wait_ms(200);
  HWND hwnd = g_host.load();
  if (!hwnd) {
    std::printf("host window failed\n");
    return 1;
  }
  ak_preview_set_host(hwnd);
  wait_ms(100);

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
        {"quality", 60}}},
      {"audio", {{"codec", "aac"}, {"bitrate_kbps", -1}}}};
  const int64_t id = ak_task_submit(task.dump().c_str());
  std::printf("task_id=%lld\n", static_cast<long long>(id));
  if (id < 0) {
    return 1;
  }
  // 应用在任务 running 后立刻绑定, 早于录制器 onReady 的 setOffSurface;
  // 复现同一时序, 防止再出现"第二次任务预览全黑"
  std::printf("early bind\n");
  ak_preview_open();
  ak_preview_bind(id);
  if (!wait_for(g_recording, 15000)) {
    std::printf("task never reached recording\n");
    return 1;
  }

  std::printf("bind\n");
  ak_preview_open();
  if (ak_preview_bind(id) != AK_OK) {
    std::printf("bind failed\n");
  }
  wait_ms(2500);
  std::printf("unbind\n");
  ak_preview_unbind();
  wait_ms(2500);
  std::printf("rebind\n");
  ak_preview_bind(id);
  wait_ms(2500);
  std::printf("unbind again\n");
  ak_preview_unbind();
  wait_ms(1500);

  std::printf("cancel\n");
  ak_task_cancel(id);
  wait_for(g_terminal, 15000);
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
