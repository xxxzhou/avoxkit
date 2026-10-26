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
#define AK_ABI_MINOR 0

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
AK_API const char* ak_capabilities_json(void);
AK_API int32_t ak_encoder_probe(const char* codec);
AK_API void ak_free_string(const char* s);

#ifdef __cplusplus
}
#endif
