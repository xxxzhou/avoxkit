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
#define AK_ABI_MINOR 9

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
  AK_E_CAPTURE_BUSY = -20,
  AK_E_CAPTURE_DEVICE = -21,
  AK_E_CAPTURE_STATE = -22,
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

// ---- 屏幕录制(录屏会话, ABI 1.7): 引擎 ICaptureSession 的 C 包装 ----
// 多输入=多文件(视频 mkv + 每路音频 wav), 不合成; 区域=显示器左上原点的
// 物理像素; 事件走统一 JSON 通道(kind=capture_state/capture_error)。
// 返回的 JSON 由 ak_free_string 释放。
// 显示器/麦克风/回环枚举: {monitors:[{id,name,x,y,w,h,primary}],
// mics:[{id,name}], loops:[{id,name}]}
AK_API const char* ak_capture_devices_json(void);
// json={out_dir, monitor_id, fps, cursor, mic, loop, region_w, region_h}
// region 0=整屏; -> {session_id}; 录制中再 start 返回 capture_busy
AK_API const char* ak_capture_start(const char* request_json);
// -> {state, clock_ms, fps, frames, missed, dropped, elapsed_ms, bytes,
//     geometry:{x,y,w,h}}
AK_API const char* ak_capture_status(int64_t session_id);
AK_API int32_t ak_capture_pause(int64_t session_id);
AK_API int32_t ak_capture_resume(int64_t session_id);
// 停止会话(回填 WAV 头/写 session.json), 不做混音转封装, 返回很快;
// 会话状态只在本进程内, 必须由创建会话的线程/isolate 调用。
// -> {dir, videos:[], audios:[]}
AK_API const char* ak_capture_stop(int64_t session_id);
// 收尾已停止的会话目录(只读文件, 可在任意 isolate 调): 混音+remux 出
// capture.mkv 并写 project.json; json={dir}; -> {dir, capture, project,
// duration_ms, audio_tracks, videos:[], audios:[], audio?, audio_error?}
AK_API const char* ak_capture_finalize(const char* request_json);

// ---- 录屏工程(ABI 1.8): 场景包装 + 裁剪 + 导出 ----
// 打开 session 目录(读 session.json/project.json/cursor.bin/events.json/shapes.json)
// json={dir}; -> {project_id, dir, video, duration_ms, width, height, cursor_mode}
AK_API const char* ak_project_open(const char* request_json);
// 深合并 project.json(场景/时间线/音频增益); -> {project}
AK_API const char* ak_project_set(int64_t project_id, const char* patch_json);
// json={out_path, overwrite, start_ms, end_ms, codec, width, height, fps,
//       quality, bitrate_kbps, cursor}; -> {export_id}; 事件 kind=project_state
AK_API const char* ak_project_export(int64_t project_id, const char* request_json);
// -> {state, pct, stage, out_path, error?, warning?}
AK_API const char* ak_project_status(int64_t project_id);
AK_API void ak_project_close(int64_t project_id);

#ifdef __cplusplus
}
#endif
