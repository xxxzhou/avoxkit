// 录屏整链无头测试: 采集 -> finalize -> 工程导出。
// 用法: ak_capture_test <work_dir> [seconds] [--audio] [--fps=N] [--region=WxH]
// 采集走 WGC 默认道; 抽 screen.mkv 帧看亮度即可判黑帧(上传 box 的 front/back 必须有效)。
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <string>
#include <thread>

#include <nlohmann/json.hpp>

#ifdef _WIN32
#include <windows.h>
#endif

#include "ak.h"

namespace {

using json = nlohmann::json;
using namespace std::chrono_literals;

std::string take_free(const char* value) {
  std::string out = value ? value : "";
  ak_free_string(value);
  return out;
}

}  // namespace

int main(int argc, char** argv) {
  setvbuf(stdout, nullptr, _IONBF, 0);
  setvbuf(stderr, nullptr, _IONBF, 0);
  std::fprintf(stderr, "step: args\n");
  const std::string root = argc > 1 ? argv[1] : "D:/tmp/ak_capture_test";
  const int seconds = argc > 2 ? std::max(2, std::atoi(argv[2])) : 4;
  bool audio = false;
  double fps = 30.0;
  int regionW = 0;
  int regionH = 0;
  for (int i = 3; i < argc; i++) {
    const std::string arg = argv[i];
    audio = audio || arg == "--audio";
    if (arg.rfind("--fps=", 0) == 0) {
      fps = std::atof(arg.c_str() + 6);
    }
    if (arg.rfind("--region=", 0) == 0) {
      // 区域从显示器左上起, 与 UI 的自定义区域一致
      if (std::sscanf(arg.c_str() + 9, "%dx%d", &regionW, &regionH) != 2) {
        regionW = 0;
        regionH = 0;
      }
    }
  }
  const std::string work = root + "/work";
  const std::string config = json({{"work_dir", work},
                                   {"log_level", "info"}})
                                 .dump();
  const int init = ak_init(config.c_str());
  if (init != AK_OK) {
    std::printf("init failed: %d\n", init);
    return 1;
  }
  std::fprintf(stderr, "step: init ok\n");
  json devices = json::parse(take_free(ak_capture_devices_json()));
  std::printf("devices: %s\n", devices.dump(2).c_str());
  if (!devices["monitors"].is_array() || devices["monitors"].empty()) {
    std::printf("no monitor\n");
    ak_shutdown();
    return 1;
  }
  json monitor = devices["monitors"][0];
  for (const auto& m : devices["monitors"]) {
    if (m.value("primary", false)) {
      monitor = m;
      break;
    }
  }
  const std::string outDir = root + "/capture";
  json request = {{"out_dir", outDir},
                  {"monitor_id", monitor["id"]},
                  {"fps", fps},
                  {"cursor", false},
                  {"mic", audio},
                  {"loop", audio},
                  {"region_w", regionW},
                  {"region_h", regionH}};
  json start = json::parse(take_free(ak_capture_start(request.dump().c_str())));
  std::printf("start: %s\n", start.dump(2).c_str());
  if (start.value("ok", false) != true) {
    ak_shutdown();
    return 1;
  }
  const int64_t session = start["session_id"];
  for (int i = 0; i < seconds; i++) {
    std::this_thread::sleep_for(1s);
    json status = json::parse(take_free(ak_capture_status(session)));
    std::printf("status %d: %s\n", i + 1, status.dump().c_str());
  }
  json stop = json::parse(take_free(ak_capture_stop(session)));
  std::fprintf(stderr, "step: stop returned\n");
  std::printf("stop: %s\n", stop.dump(2).c_str());
  if (!stop.value("ok", false)) {
    ak_shutdown();
    return 1;
  }
  const std::string dir = stop.value("dir", "");
  std::fprintf(stderr, "step: finalize\n");
  json fin = json::parse(
      take_free(ak_capture_finalize(json({{"dir", dir}}).dump().c_str())));
  std::printf("finalize: %s\n", fin.dump(2).c_str());
  if (!fin.value("ok", false)) {
    ak_shutdown();
    return 1;
  }
  if (fin.contains("capture")) {
    const std::string capture = fin["capture"].get<std::string>();
    std::fprintf(stderr, "step: probe capture\n");
    std::printf("probe capture: %s\n",
                take_free(ak_probe(capture.c_str())).c_str());
  }
  // 回归: 点击事件的 inside 历史版本是 0/1 数字, 新版本是 bool, 两种都要能读
  {
    nlohmann::json events = {
        {"clicks", nlohmann::json::array({{{"t", 1000},
                                            {"x", 100},
                                            {"y", 100},
                                            {"inside", 1},
                                            {"button", "left"}},
                                           {{"t", 2000},
                                            {"x", 200},
                                            {"y", 200},
                                            {"inside", true},
                                            {"button", "left"}}})},
        {"jumps", nlohmann::json::array()},
        {"pauses", nlohmann::json::array()}};
    std::ofstream(dir + "/events.json") << events.dump(2);
  }
  std::fprintf(stderr, "step: project open\n");
  json opened = json::parse(take_free(ak_project_open(
      json({{"dir", dir}}).dump().c_str())));
  std::fprintf(stderr, "step: project opened\n");
  std::printf("project open: %s\n", opened.dump(2).c_str());
  if (!opened.value("ok", false)) {
    ak_shutdown();
    return 1;
  }
  const int64_t project = opened["project_id"];
  const std::string exportPath = root + "/export.mp4";
  std::remove(exportPath.c_str());
  json exportReq = {{"out_path", exportPath},
                    {"overwrite", true},
                    {"width", 1280},
                    {"height", 720},
                    {"fps", 30.0},
                    {"quality", 60}};
  json exportStart = json::parse(
      take_free(ak_project_export(project, exportReq.dump().c_str())));
  std::fprintf(stderr, "step: export started\n");
  std::printf("export start: %s\n", exportStart.dump(2).c_str());
  if (!exportStart.value("ok", false)) {
    ak_project_close(project);
    ak_shutdown();
    return 1;
  }
  for (int i = 0; i < 120; i++) {
    std::this_thread::sleep_for(500ms);
    json status = json::parse(take_free(ak_project_status(project)));
    std::printf("export: %s\n", status.dump().c_str());
    const std::string state = status.value("state", "");
    if (state == "done" || state == "failed" || state == "cancelled") {
      break;
    }
  }
  ak_project_close(project);
  ak_shutdown();
  return 0;
}
