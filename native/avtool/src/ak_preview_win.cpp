#include "ak_preview.hpp"

#include <mutex>
#include <string>
#include <thread>

#include "ak_internal.hpp"

#ifdef _WIN32
#include <windows.h>
#endif

namespace ak {
namespace {

bool (*g_attach)(int64_t, void*) = nullptr;
void (*g_detach)(int64_t) = nullptr;

#ifdef _WIN32

constexpr wchar_t kPreviewClass[] = L"avoxkit_preview";
constexpr UINT kMsgRequest = WM_APP + 0x5A;

enum ReqCode : int {
  kReqOpen = 1,
  kReqBind = 2,
  kReqUnbind = 3,
  kReqRect = 4,
  kReqClose = 5,
  kReqAttach = 6,
  kReqQuit = 7,
};

struct Request {
  ReqCode code;
  int64_t task_id = 0;
  double x = 0, y = 0, w = 0, h = 0;
};

HWND g_host = nullptr;
HWND g_msg = nullptr;    // message-only 请求入口(预览线程)
HWND g_video = nullptr;  // 预览子窗(预览线程所有)
int64_t g_owner = 0;
int g_last_w = 0;
int g_last_h = 0;
std::mutex g_mtx;  // 只护 host/owner 状态读写; 窗口操作只在预览线程

void resize_avox_children(HWND parent, int w, int h) {
  // avox 在我们窗内自建交换链子窗, 其 WM_SIZE 处理未启用, 宿主负责拉动
  HWND child = nullptr;
  while ((child = FindWindowExW(parent, child, nullptr, nullptr)) != nullptr) {
    SetWindowPos(child, nullptr, 0, 0, w, h, SWP_NOZORDER | SWP_NOACTIVATE);
  }
}

// 有帧才显示: 后建者在上, 压过 Flutter 视图子窗
void show_video() {
  if (!g_video) {
    return;
  }
  SetWindowPos(g_video, HWND_TOP, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
  ShowWindow(g_video, SW_SHOWNOACTIVATE);
}

void hide_video() {
  if (g_video) {
    ShowWindow(g_video, SW_HIDE);
  }
}

void release_owner() {
  hide_video();
  if (g_owner != 0 && g_detach) {
    g_detach(g_owner);
  }
  g_owner = 0;
}

void handle_request(Request* req) {
  std::lock_guard<std::mutex> lock(g_mtx);
  switch (req->code) {
    case kReqOpen: {
      if (!g_host) {
        break;
      }
      if (!g_video) {
        WNDCLASSEXW wc = {};
        wc.cbSize = sizeof(wc);
        wc.lpfnWndProc = DefWindowProcW;
        wc.hInstance = GetModuleHandleW(nullptr);
        wc.lpszClassName = kPreviewClass;
        wc.hbrBackground = CreateSolidBrush(RGB(0, 0, 0));
        RegisterClassExW(&wc);
        g_video = CreateWindowExW(WS_EX_NOPARENTNOTIFY, kPreviewClass, L"",
                                  WS_CHILD | WS_CLIPSIBLINGS, 0, 0, 0, 0,
                                  g_host, nullptr, GetModuleHandleW(nullptr),
                                  nullptr);
        if (!g_video) {
          log(LogLevel::warn, "preview: create window failed");
          break;
        }
      }
      g_last_w = 0;
      g_last_h = 0;
      hide_video();
      log(LogLevel::info, "preview window opened");
      break;
    }
    case kReqBind: {
      if (!g_video) {
        break;
      }
      if (g_owner != 0 && g_owner != req->task_id) {
        // 换任务: 先让旧任务交还渲染面
        release_owner();
      }
      g_owner = req->task_id;
      // 只有录制中的任务能接管; 排队/终态保持隐藏, 露出 Flutter 占位
      if (g_attach && g_attach(req->task_id, g_video)) {
        show_video();
      } else {
        hide_video();
      }
      log(LogLevel::info, "preview bind, task=" + std::to_string(req->task_id));
      break;
    }
    case kReqUnbind: {
      if (g_owner == 0) {
        break;
      }
      const int64_t old = g_owner;
      release_owner();
      g_last_w = 0;
      g_last_h = 0;
      log(LogLevel::info, "preview unbind, task=" + std::to_string(old));
      break;
    }
    case kReqRect: {
      if (!g_video) {
        break;
      }
      const int width = static_cast<int>(req->w);
      const int height = static_cast<int>(req->h);
      if (width <= 0 || height <= 0) {
        break;
      }
      if (width != g_last_w || height != g_last_h) {
        MoveWindow(g_video, static_cast<int>(req->x), static_cast<int>(req->y),
                   width, height, TRUE);
        resize_avox_children(g_video, width, height);
        g_last_w = width;
        g_last_h = height;
        // 交换链尺寸由 avox 呈现线程 updateSize 自适应, 这里不重建 surface
      } else {
        SetWindowPos(g_video, nullptr, static_cast<int>(req->x),
                     static_cast<int>(req->y), 0, 0,
                     SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
      }
      break;
    }
    case kReqClose: {
      if (g_owner != 0) {
        const int64_t old = g_owner;
        release_owner();
        log(LogLevel::info,
            "preview close, task=" + std::to_string(old));
      } else {
        hide_video();
      }
      g_last_w = 0;
      g_last_h = 0;
      break;
    }
    case kReqAttach: {
      // 任务已进入 recording(onReady 的 setOffSurface 之后), 直接挂面
      if (g_video && g_owner == req->task_id && g_attach) {
        if (g_attach(req->task_id, g_video)) {
          show_video();
        }
      }
      break;
    }
    case kReqQuit: {
      release_owner();
      if (g_video) {
        DestroyWindow(g_video);
        g_video = nullptr;
      }
      PostQuitMessage(0);
      break;
    }
  }
}

LRESULT CALLBACK msg_proc(HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam) {
  if (msg == kMsgRequest) {
    handle_request(reinterpret_cast<Request*>(lparam));
    return 0;
  }
  return DefWindowProcW(hwnd, msg, wparam, lparam);
}

void preview_thread_main() {
  WNDCLASSEXW wc = {};
  wc.cbSize = sizeof(wc);
  wc.lpfnWndProc = msg_proc;
  wc.hInstance = GetModuleHandleW(nullptr);
  wc.lpszClassName = L"avoxkit_preview_msg";
  RegisterClassExW(&wc);
  g_msg = CreateWindowExW(0, L"avoxkit_preview_msg", L"", 0, 0, 0, 0, 0,
                          HWND_MESSAGE, nullptr, GetModuleHandleW(nullptr),
                          nullptr);
  MSG msg;
  while (GetMessageW(&msg, nullptr, 0, 0) > 0) {
    TranslateMessage(&msg);
    DispatchMessageW(&msg);
  }
  UnregisterClassW(L"avoxkit_preview_msg", GetModuleHandleW(nullptr));
}

void post_request(Request* req) {
  if (!g_msg) {
    delete req;
    return;
  }
  PostMessageW(g_msg, kMsgRequest, 0, reinterpret_cast<LPARAM>(req));
}

std::thread& preview_thread() {
  static std::thread t;
  return t;
}

#endif  // _WIN32

}  // namespace

void preview_set_hooks(bool (*attach)(int64_t, void*),
                       void (*detach)(int64_t)) {
  g_attach = attach;
  g_detach = detach;
}

void preview_set_host(void* host_hwnd) {
#ifdef _WIN32
  std::lock_guard<std::mutex> lock(g_mtx);
  if (g_host || !host_hwnd) {
    return;
  }
  g_host = static_cast<HWND>(host_hwnd);
  preview_thread() = std::thread(preview_thread_main);
#else
  (void)host_hwnd;
#endif
}

void* preview_host() {
#ifdef _WIN32
  std::lock_guard<std::mutex> lock(g_mtx);
  return static_cast<void*>(g_host);
#else
  return nullptr;
#endif
}

bool preview_open_window() {
#ifdef _WIN32
  std::lock_guard<std::mutex> lock(g_mtx);
  if (!g_msg) {
    return false;
  }
  post_request(new Request{kReqOpen});
  return true;
#else
  return false;
#endif
}

void preview_bind_task(int64_t task_id) {
#ifdef _WIN32
  auto* req = new Request{kReqBind};
  req->task_id = task_id;
  post_request(req);
#else
  (void)task_id;
#endif
}

void preview_unbind_task() {
#ifdef _WIN32
  post_request(new Request{kReqUnbind});
#endif
}

void preview_rect(double x, double y, double w, double h) {
#ifdef _WIN32
  auto* req = new Request{kReqRect};
  req->x = x;
  req->y = y;
  req->w = w;
  req->h = h;
  post_request(req);
#else
  (void)x;
  (void)y;
  (void)w;
  (void)h;
#endif
}

void preview_close_window() {
#ifdef _WIN32
  post_request(new Request{kReqClose});
#endif
}

void preview_request_attach(int64_t task_id) {
#ifdef _WIN32
  auto* req = new Request{kReqAttach};
  req->task_id = task_id;
  post_request(req);
#else
  (void)task_id;
#endif
}

void preview_shutdown() {
#ifdef _WIN32
  {
    std::lock_guard<std::mutex> lock(g_mtx);
    if (!g_msg) {
      return;
    }
  }
  post_request(new Request{kReqQuit});
  if (preview_thread().joinable()) {
    preview_thread().join();
    preview_thread() = {};
  }
  std::lock_guard<std::mutex> lock(g_mtx);
  g_host = nullptr;
  g_msg = nullptr;
  UnregisterClassW(kPreviewClass, GetModuleHandleW(nullptr));
#endif
}

}  // namespace ak
