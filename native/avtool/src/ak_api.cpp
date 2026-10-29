#include "ak_internal.hpp"
#include "ak_preview.hpp"

#include <cstdlib>
#include <mutex>
#include <string>

extern "C" uint32_t ak_abi_version(void) {
  return (AK_ABI_MAJOR << 16) | AK_ABI_MINOR;
}

extern "C" const char* ak_version_json(void) {
  std::string json;
  if (ak::is_ready()) {
    std::lock_guard<std::mutex> lock(ak::engine().mtx);
    json = ak::engine().version_json;
  }
  if (json.empty()) {
    json = ak::make_version_json();
  }
  return ak::dup_cstr(json);
}

extern "C" int32_t ak_set_event_cb(ak_event_cb cb, void* user) {
  return ak::event_set_callback(cb, user);
}

extern "C" void ak_free_string(const char* s) {
  std::free(const_cast<char*>(s));
}

extern "C" int32_t ak_preview_set_host(void* host_hwnd) {
  ak::preview_set_host(host_hwnd);
  return AK_OK;
}

extern "C" int32_t ak_preview_open(void) {
  if (!ak::is_ready()) {
    return AK_E_NOT_INIT;
  }
  if (!ak::preview_open_window()) {
    return AK_E_NOT_IMPLEMENTED;
  }
  return AK_OK;
}

extern "C" int32_t ak_preview_bind(int64_t task_id) {
  ak::preview_bind_task(task_id);
  return AK_OK;
}

extern "C" int32_t ak_preview_unbind(void) {
  ak::preview_unbind_task();
  return AK_OK;
}

extern "C" int32_t ak_preview_rect(double x, double y, double w, double h) {
  ak::preview_rect(x, y, w, h);
  return AK_OK;
}

extern "C" int32_t ak_preview_close(void) {
  ak::preview_close_window();
  return AK_OK;
}

extern "C" const char* ak_image_detect(const char* uri,
                                       const char* request_json) {
  if (!ak::is_ready() || !uri || !*uri) {
    return ak::dup_cstr(
        "{\"ok\":false,\"code\":\"not_initialized\","
        "\"message\":\"engine is not initialized\"}");
  }
  return ak::dup_cstr(
      ak::image_detect_json(uri, request_json ? request_json : ""));
}
