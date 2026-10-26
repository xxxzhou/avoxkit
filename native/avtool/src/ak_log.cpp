#include "ak_internal.hpp"

#include <cstdio>
#include <filesystem>
#include <fstream>
#include <mutex>

namespace ak {
namespace {

std::mutex g_log_mtx;
std::ofstream g_log_file;
int g_min_level = static_cast<int>(LogLevel::info);

const char* level_name(LogLevel level) {
  switch (level) {
    case LogLevel::debug:
      return "DEBUG";
    case LogLevel::info:
      return "INFO";
    case LogLevel::warn:
      return "WARN";
    case LogLevel::error:
      return "ERROR";
  }
  return "INFO";
}

}  // namespace

void log_set_file(const std::string& path, const std::string& level) {
  if (level == "debug") {
    g_min_level = static_cast<int>(LogLevel::debug);
  } else if (level == "warn") {
    g_min_level = static_cast<int>(LogLevel::warn);
  } else if (level == "error") {
    g_min_level = static_cast<int>(LogLevel::error);
  } else {
    g_min_level = static_cast<int>(LogLevel::info);
  }

  std::lock_guard<std::mutex> lock(g_log_mtx);
  if (g_log_file.is_open()) {
    g_log_file.close();
  }
  std::error_code ec;
  const auto fs_path = std::filesystem::u8path(path);
  std::filesystem::create_directories(fs_path.parent_path(), ec);
  g_log_file.open(fs_path, std::ios::out | std::ios::app);
}

void log(LogLevel level, const std::string& msg) {
  if (static_cast<int>(level) < g_min_level) {
    return;
  }
  const std::string line =
      now_iso8601() + " [" + level_name(level) + "] " + msg + "\n";
  std::lock_guard<std::mutex> lock(g_log_mtx);
  if (g_log_file.is_open()) {
    g_log_file << line;
    g_log_file.flush();
  } else {
    std::fputs(line.c_str(), stderr);
  }
}

void log_close() {
  std::lock_guard<std::mutex> lock(g_log_mtx);
  if (g_log_file.is_open()) {
    g_log_file.flush();
    g_log_file.close();
  }
}

void avox_log_bridge(int32_t level, const char* message) {
  if (!message) {
    return;
  }
  LogLevel mapped = LogLevel::info;
  switch (level) {
    case 1:
      mapped = LogLevel::warn;
      break;
    case 2:
      mapped = LogLevel::error;
      break;
    case 3:
      mapped = LogLevel::debug;
      break;
    default:
      mapped = LogLevel::info;
      break;
  }
  log(mapped, std::string("[avox] ") + message);
}

}  // namespace ak
