#pragma once

#include <cstdint>

namespace ak {

// 原生窗口直显预览(Windows 先行)。所有窗口操作都跑在 shim 自带的预览线程上
// (该线程泵消息): Dart/引擎线程只投递请求, 绝不跨线程触碰窗口 —— 否则
// SendMessage 到不泵消息的线程会永久挂死(2026-10-27 实证)。

// Runner 启动时交主窗 HWND; 不交则预览口返回未实现, UI 自己退化。
void preview_set_host(void* host_hwnd);
// 录屏 WDA 复用同一主窗句柄; 未交返回 nullptr
void* preview_host();

// 窗口生命周期归页面; 任务绑定归当前可见任务。bind 只对录制中的任务生效,
// 其余状态窗口保持隐藏, UI 占位可见。
bool preview_open_window();
void preview_bind_task(int64_t task_id);
void preview_unbind_task();
void preview_rect(double x, double y, double w, double h);
void preview_close_window();

// 任务开始录制时请求接管渲染面(预览线程上执行 setSurface)。
void preview_request_attach(int64_t task_id);

void preview_shutdown();

// ak_task 注入: attach/detach 在预览线程上回调。attach 返回是否真正接上。
// 摘视口只切回离屏输出, 呈现线程继续跑, 处理不停。
void preview_set_hooks(bool (*attach)(int64_t task_id, void* hwnd),
                       void (*detach)(int64_t task_id));

}  // namespace ak
