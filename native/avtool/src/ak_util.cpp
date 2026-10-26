#include "ak_internal.hpp"

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>

namespace ak {

std::string now_iso8601() {
  using namespace std::chrono;
  const auto now = system_clock::now();
  const auto ms = duration_cast<milliseconds>(now.time_since_epoch()) % 1000;
  const std::time_t t = system_clock::to_time_t(now);
  std::tm tm{};
#ifdef _WIN32
  gmtime_s(&tm, &t);
#else
  gmtime_r(&t, &tm);
#endif
  char buf[64];
  std::snprintf(buf, sizeof(buf), "%04d-%02d-%02dT%02d:%02d:%02d.%03lldZ",
                tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday, tm.tm_hour,
                tm.tm_min, tm.tm_sec, static_cast<long long>(ms.count()));
  return buf;
}

int64_t now_ms() {
  using namespace std::chrono;
  return duration_cast<milliseconds>(system_clock::now().time_since_epoch())
      .count();
}

std::string fnv1a_hex(const std::string& value) {
  uint64_t hash = 1469598103934665603ull;
  for (unsigned char c : value) {
    hash ^= c;
    hash *= 1099511628211ull;
  }
  char buf[17];
  std::snprintf(buf, sizeof(buf), "%016llx", static_cast<unsigned long long>(hash));
  return buf;
}

char* dup_cstr(const std::string& value) {
  char* out = static_cast<char*>(std::malloc(value.size() + 1));
  if (!out) {
    return nullptr;
  }
  std::memcpy(out, value.data(), value.size());
  out[value.size()] = '\0';
  return out;
}

const char* error_name(int32_t code) {
  switch (code) {
    case AK_OK:
      return "ok";
    case AK_E_INVALID_ARG:
      return "invalid_argument";
    case AK_E_BAD_JSON:
      return "bad_json";
    case AK_E_ALREADY_INIT:
      return "already_init";
    case AK_E_NOT_INIT:
      return "not_initialized";
    case AK_E_FFMPEG_MISMATCH:
      return "ffmpeg_mismatch";
    case AK_E_ENGINE_MISMATCH:
      return "engine_mismatch";
    case AK_E_UNSUPPORTED_KIND:
      return "unsupported_kind";
    case AK_E_BAD_SOURCE:
      return "bad_source";
    case AK_E_BAD_OUTPUT:
      return "bad_output";
    case AK_E_NOT_FOUND:
      return "not_found";
    case AK_E_TASK_NOT_RUNNING:
      return "task_not_running";
    case AK_E_NOT_IMPLEMENTED:
      return "not_implemented";
    default:
      return "internal";
  }
}

}  // namespace ak
