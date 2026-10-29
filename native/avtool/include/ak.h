#pragma once

#include <stdint.h>

// ak_* ABI v1 的唯一公开头。字符串一律 UTF-8; 返回值由本模块分配, 调用方用
// ak_free_string / ak_event_free 释放。

#ifdef _WIN32
#ifdef AVOXKIT_NATIVE_EXPORTS
#define AK_API __declspec(dllexport)
#else
#define AK_API __declspec(dllimport)
#endif
#else
#define AK_API __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

#define AK_ABI_MAJOR 1
#define AK_ABI_MINOR 6

typedef void (*ak_event_cb)(const char* event_json, void* user);

typedef enum ak_error {
  AK_OK = 0,
  AK_E_INVALID_ARG = -1,
  AK_E_BAD_JSON = -2,
  AK_E_ALREADY_INIT = -3,
  AK_E_NOT_INIT = -4,
  AK_E_FFMPEG_MISMATCH = -5,
  AK_E_ENGINE_MISMATCH = -6,
  AK_E_UNSUPPORTED_KIND = -7,
  AK_E_BAD_SOURCE = -8,
  AK_E_BAD_OUTPUT = -9,
  AK_E_NOT_FOUND = -10,
  AK_E_TASK_NOT_RUNNING = -11,
  AK_E_NOT_IMPLEMENTED = -12,
  AK_E_MODEL_MISSING = -13,
  AK_E_NO_SUBTITLE = -14,
  AK_E_STT_UNAVAILABLE = -15,
  AK_E_INPAINT_UNAVAILABLE = -16,
  AK_E_INPAINT_FAILED = -17,
  AK_E_INTERNAL = -99
} ak_error;

AK_API uint32_t ak_abi_version(void);
AK_API const char* ak_version_json(void);
AK_API int32_t ak_init(const char* config_json);
AK_API void ak_shutdown(void);
AK_API int32_t ak_set_event_cb(ak_event_cb cb, void* user);
AK_API void ak_event_free(const char* event_json);
AK_API int64_t ak_task_submit(const char* task_json);
AK_API int32_t ak_task_cancel(int64_t task_id);
AK_API int32_t ak_task_remove(int64_t task_id);
AK_API const char* ak_probe(const char* uri);
// 只读媒体索引: 音频包络峰值 + 视频关键帧时间(毫秒, 相对片头)。
// buckets 为目标峰值数量(64-4000), 返回 {ok,duration_ms,bucket_ms,has_audio,peaks,keyframes_ms}
AK_API const char* ak_media_index(const char* uri, int32_t buckets);
// 抓参考帧: request_json = {count|times_ms, width, quality};
// 返回 {ok,duration_ms,has_video,width,height,frames:[{ms,image}]}, image 为 JPEG base64。
// 按时间 backward seek, 返回实际解到的帧时间; 不写临时文件。
AK_API const char* ak_media_frames(const char* uri, const char* request_json);
AK_API const char* ak_capabilities_json(void);
AK_API int32_t ak_encoder_probe(const char* codec);
// 只检测水印(不修复): request_json = {threshold, model}; 返回
// {ok,width,height,found,boxes:[{x,y,w,h}],detect_ms}。阻塞调用, 调用方自己丢后台线程。
AK_API const char* ak_image_detect(const char* uri, const char* request_json);
AK_API void ak_free_string(const char* s);

// 原生窗口直显预览(Windows): 窗口生命周期归页面, 任务绑定归当前可见任务;
// 只有录制中的任务才显示原生窗, 排队/终态保持隐藏。其余平台 not_implemented。
AK_API int32_t ak_preview_set_host(void* host_hwnd);
AK_API int32_t ak_preview_open(void);
AK_API int32_t ak_preview_bind(int64_t task_id);
AK_API int32_t ak_preview_unbind(void);
AK_API int32_t ak_preview_rect(double x, double y, double w, double h);
AK_API int32_t ak_preview_close(void);

#ifdef __cplusplus
}
#endif
