// 内嵌字幕导出无头测试: 直接走 ak_task_submit(kind=subtitle, mode=auto)。
// 用法: ak_subtitle_test <带字幕轨的媒体> <work_dir> <out_dir>
#include "ak.h"

#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <mutex>
#include <string>

#include <nlohmann/json.hpp>

namespace {
using json = nlohmann::json;
namespace fs = std::filesystem;

std::mutex g_mtx;
std::condition_variable g_cv;
bool g_finished = false;
bool g_failed = false;
std::string g_error;

void on_event(const char* event_json, void*) {
  const json j = json::parse(event_json ? event_json : "{}", nullptr, false);
  if (j.is_object()) {
    std::lock_guard<std::mutex> lock(g_mtx);
    const std::string type = j.value("type", "");
    if (type == "done") {
      g_finished = true;
      g_cv.notify_all();
    } else if (type == "error") {
      g_finished = true;
      g_failed = true;
      g_error = j.value("code", "") + ": " + j.value("message", "");
      g_cv.notify_all();
    }
  }
  ak_event_free(event_json);
}

bool wait_done(int timeout_ms) {
  std::unique_lock<std::mutex> lock(g_mtx);
  return g_cv.wait_for(lock, std::chrono::milliseconds(timeout_ms),
                       [] { return g_finished; });
}

int g_checks = 0;
int g_failures = 0;

void check(bool ok, const std::string& label) {
  ++g_checks;
  std::printf("  %s %s\n", ok ? "ok  " : "FAIL", label.c_str());
  if (!ok) {
    ++g_failures;
  }
}
}  // namespace

int main(int argc, char** argv) {
  if (argc < 4) {
    std::printf("usage: ak_subtitle_test <media> <work_dir> <out_dir>\n");
    return 2;
  }
  const std::string input = argv[1];
  const fs::path work_dir = fs::u8path(argv[2]);
  const fs::path out_dir = fs::u8path(argv[3]);
  std::error_code ec;
  fs::create_directories(work_dir, ec);
  fs::create_directories(out_dir, ec);
  if (!fs::exists(fs::u8path(input), ec)) {
    std::printf("input not found: %s\n", input.c_str());
    return 2;
  }

  json config = {{"work_dir", work_dir.u8string()}, {"log_level", "info"}};
  if (ak_init(config.dump().c_str()) != 0) {
    std::printf("ak_init failed\n");
    return 1;
  }
  ak_set_event_cb(on_event, nullptr);

  const char* raw = ak_probe(input.c_str());
  const json probe = json::parse(raw ? raw : "{}", nullptr, false);
  if (raw) {
    ak_free_string(raw);
  }
  check(probe.value("ok", false), "源文件可探测");
  if (!probe.value("ok", false)) {
    ak_shutdown();
    return 1;
  }

  int32_t text_index = -1;
  if (probe.contains("subtitles") && probe["subtitles"].is_array()) {
    for (const auto& track : probe["subtitles"]) {
      check(track.contains("text"), "字幕轨带 text 标记");
      if (track.value("text", false)) {
        text_index = track.value("index", -1);
        break;
      }
    }
  }
  if (text_index < 0) {
    std::printf("  skip 源没有文本字幕轨\n");
    ak_shutdown();
    return 0;
  }

  const fs::path out = out_dir / "subtitle_auto.srt";
  fs::remove(out, ec);
  json task = {
      {"schema", 1},
      {"kind", "subtitle"},
      {"sources", json::array({{{"kind", "file"}, {"uri", input}}})},
      {"outputs", json::array({{{"role", "primary"}, {"path", out.u8string()}}})},
      {"params",
       {{"overwrite", true},
        {"subtitle", {{"mode", "auto"}, {"allow_asr", false}}}}}};
  const int64_t id = ak_task_submit(task.dump().c_str());
  check(id > 0, "提交字幕任务");
  if (id > 0) {
    check(wait_done(60000), "任务在超时前结束");
    check(g_finished && !g_failed, "任务成功");
    if (g_failed) {
      std::printf("       error: %s\n", g_error.c_str());
    }
  }

  if (fs::exists(out, ec)) {
    std::ifstream in(out, std::ios::binary);
    const std::string content((std::istreambuf_iterator<char>(in)),
                              std::istreambuf_iterator<char>());
    check(!content.empty(), "SRT 非空");
    check(content.find("1\n") == 0, "SRT 从序号 1 开始");
    check(content.find("-->") != std::string::npos, "SRT 有时间轴");
    check(content.find("Dialogue:") == std::string::npos,
          "没有 ASS 字段前缀");
  } else {
    check(false, "SRT 产物存在");
  }

  ak_shutdown();
  std::printf("\n%d checks, %d failed\n", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
