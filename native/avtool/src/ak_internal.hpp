#pragma once

#include <atomic>
#include <cstdint>
#include <mutex>
#include <string>

#include "ak.h"

namespace ak {

enum class LogLevel : int { debug = 0, info = 1, warn = 2, error = 3 };

struct Config {
  std::string work_dir;
  std::string models_dir;
  std::string log_level = "info";
};

struct Engine {
  // 0=uninitialized, 1=ready, 2=shutting_down
  std::atomic<int> status{0};
  std::mutex mtx;
  Config config;
  std::string log_dir;
  std::string version_json;
  std::string capabilities_json;
  int64_t init_ms = 0;
};

Engine& engine();
bool is_ready();
int32_t init_engine(const char* config_json);
void shutdown_engine();

std::string make_version_json();
std::string make_capabilities_json();
int32_t encoder_probe_impl(const std::string& codec);

// event
void event_start();
void event_stop();
void event_post(const std::string& json);
int32_t event_set_callback(ak_event_cb cb, void* user);

// task runtime
void task_start();
void task_stop();

// log
void log(LogLevel level, const std::string& msg);
void log_set_file(const std::string& path, const std::string& level);
void log_close();
void avox_log_bridge(int32_t level, const char* message);

// util
std::string now_iso8601();
int64_t now_ms();
std::string fnv1a_hex(const std::string& value);
char* dup_cstr(const std::string& value);
const char* error_name(int32_t code);

}  // namespace ak
