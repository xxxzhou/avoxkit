#include "ak_internal.hpp"

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
