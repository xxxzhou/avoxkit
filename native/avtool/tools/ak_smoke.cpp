#include "ak.h"

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <mutex>
#include <string>
#include <thread>

#include <nlohmann/json.hpp>

#ifdef _WIN32
#include <windows.h>
#endif

namespace {

std::mutex g_wait_mtx;
std::condition_variable g_wait_cv;
bool g_terminal = false;
std::atomic<bool> g_cancelled{false};
std::atomic<bool> g_failed{false};
std::atomic<int> g_terminal_count{0};
std::atomic<int> g_expected{1};

void reset_wait(int expected) {
  {
    std::lock_guard<std::mutex> lock(g_wait_mtx);
    g_terminal = false;
  }
  g_terminal_count.store(0);
  g_cancelled.store(false);
  g_failed.store(false);
  g_expected.store(expected);
}

void usage() {
  std::printf(
      "ak_smoke <command> [args]\n"
      "  version\n"
      "  init [work_dir]\n"
      "  caps [work_dir]\n"
      "  probe <file> [work_dir]\n"
      "  transcode <in> <out> <work_dir> [--hardware off|auto|on]\n"
      "            [--codec h264|hevc] [--quality N] [--cancel-ms N]\n"
      "            [--trans-mode all|audio_copy|video_copy]\n"
      "            [--audio-codec aac|mp3] [--container mp4|mov|mkv]\n"
      "            [--width N --height N] [--overwrite]\n"
      "  queue <in> <out_dir> <work_dir> <count> [--hardware off|auto|on]\n"
      "  remux <in> <out> <work_dir> [--overwrite]\n"
      "  extract <in> <out> <work_dir> [--codec aac|mp3|copy]\n"
      "            [--bitrate N] [--overwrite]\n");
}

void print_json(const char* label, const char* json) {
  if (!json) {
    std::printf("%s: <null>\n", label);
    return;
  }
  std::printf("%s: %s\n", label, json);
  ak_free_string(json);
}

std::string default_work_dir() {
  const auto path = std::filesystem::temp_directory_path() / "avoxkit-smoke";
  return path.u8string();
}

int init_engine(const std::string& work_dir) {
  nlohmann::json config;
  config["work_dir"] = work_dir;
  config["log_level"] = "debug";
  const std::string text = config.dump();
  const int32_t rc = ak_init(text.c_str());
  std::printf("ak_init(%s): %d\n", work_dir.c_str(), rc);
  return rc;
}

void on_event(const char* event_json, void*) {
  const std::string text = event_json ? event_json : "";
  std::printf("[event] %s\n", text.c_str());

  bool terminal = false;
  try {
    const auto event = nlohmann::json::parse(text);
    const std::string type = event.value("type", "");
    if (type == "done") {
      terminal = true;
    } else if (type == "error") {
      terminal = true;
      g_failed.store(true);
    } else if (type == "state" && event.value("state", "") == "cancelled") {
      terminal = true;
      g_cancelled.store(true);
    }
  } catch (const std::exception&) {
  }

  if (terminal) {
    const int count = g_terminal_count.fetch_add(1) + 1;
    if (count >= g_expected.load()) {
      {
        std::lock_guard<std::mutex> lock(g_wait_mtx);
        g_terminal = true;
      }
      g_wait_cv.notify_all();
    }
  }
  ak_event_free(event_json);
}

nlohmann::json make_task(const std::string& input, const std::string& output,
                         const std::string& hardware,
                         const std::string& codec, int32_t quality,
                         bool overwrite, const std::string& trans_mode,
                         int32_t width, int32_t height,
                         const std::string& audio_codec = "aac",
                         const std::string& container = "mp4") {
  nlohmann::json task;
  task["schema"] = 1;
  task["kind"] = "transcode";
  task["sources"] = nlohmann::json::array(
      {{{"kind", "file"}, {"uri", input}}});
  task["outputs"] = nlohmann::json::array(
      {{{"role", "primary"}, {"path", output}}});
  nlohmann::json video = {{"codec", codec},
                          {"hardware", hardware},
                          {"rate_mode", "quality"},
                          {"quality", quality}};
  if (width > 0 && height > 0) {
    video["width"] = width;
    video["height"] = height;
  }
  task["params"] = {
      {"container", container},
      {"overwrite", overwrite},
      {"video", video},
      {"audio", {{"codec", audio_codec}, {"bitrate_kbps", -1}}}};
  if (!trans_mode.empty()) {
    task["params"]["trans_mode"] = trans_mode;
  }
  return task;
}

nlohmann::json make_shell(const std::string& kind, const std::string& input,
                          const std::string& output, bool overwrite) {
  nlohmann::json task;
  task["schema"] = 1;
  task["kind"] = kind;
  task["sources"] = nlohmann::json::array(
      {{{"kind", "file"}, {"uri", input}}});
  task["outputs"] = nlohmann::json::array(
      {{{"role", "primary"}, {"path", output}}});
  task["params"] = {{"overwrite", overwrite}};
  return task;
}

// 走同一套 init/等待/回收; remux 与 extract 的差异只在任务 JSON
int run_one(nlohmann::json task, const std::string& output,
            const std::string& work_dir) {
  if (init_engine(work_dir) != 0) {
    return 1;
  }
  ak_set_event_cb(on_event, nullptr);
  reset_wait(1);

  const std::string text = task.dump();
  std::printf("task: %s\n", text.c_str());
  const int64_t task_id = ak_task_submit(text.c_str());
  std::printf("task_id=%lld\n", static_cast<long long>(task_id));
  if (task_id < 0) {
    ak_shutdown();
    return 1;
  }

  {
    std::unique_lock<std::mutex> lock(g_wait_mtx);
    g_wait_cv.wait_for(lock, std::chrono::minutes(10),
                       [] { return g_terminal; });
  }

  if (!g_cancelled && !g_failed) {
    print_json("output probe", ak_probe(output.c_str()));
  }

  ak_shutdown();
  return (g_terminal && !g_failed) ? 0 : 1;
}

int run_transcode(const std::string& input, const std::string& output,
                  const std::string& work_dir, const std::string& hardware,
                  const std::string& codec, int32_t quality, int cancel_ms,
                  bool overwrite, const std::string& trans_mode, int32_t width,
                  int32_t height, const std::string& audio_codec = "aac",
                  const std::string& container = "mp4") {
  if (init_engine(work_dir) != 0) {
    return 1;
  }
  ak_set_event_cb(on_event, nullptr);
  reset_wait(1);

  const std::string task_text =
      make_task(input, output, hardware, codec, quality, overwrite, trans_mode,
                width, height, audio_codec, container)
          .dump();
  const int64_t task_id = ak_task_submit(task_text.c_str());
  std::printf("task_id=%lld\n", static_cast<long long>(task_id));
  if (task_id < 0) {
    ak_shutdown();
    return 1;
  }

  std::thread canceller;
  if (cancel_ms > 0) {
    canceller = std::thread([task_id, cancel_ms] {
      std::this_thread::sleep_for(std::chrono::milliseconds(cancel_ms));
      const int32_t rc = ak_task_cancel(task_id);
      std::printf("cancel rc=%d\n", rc);
    });
  }

  {
    std::unique_lock<std::mutex> lock(g_wait_mtx);
    g_wait_cv.wait_for(lock, std::chrono::minutes(10),
                       [] { return g_terminal; });
  }
  if (canceller.joinable()) {
    canceller.join();
  }

  if (!g_cancelled && !g_failed) {
    print_json("output probe", ak_probe(output.c_str()));
  }

  ak_shutdown();
  if (g_cancelled) {
    return cancel_ms > 0 ? 0 : 1;
  }
  return (g_terminal && !g_failed) ? 0 : 1;
}

int run_queue(const std::string& input, const std::string& out_dir,
              const std::string& work_dir, int count,
              const std::string& hardware) {
  if (count <= 0) {
    return 1;
  }
  if (init_engine(work_dir) != 0) {
    return 1;
  }
  ak_set_event_cb(on_event, nullptr);
  reset_wait(count);

  std::error_code ec;
  const auto dir = std::filesystem::u8path(out_dir);
  std::filesystem::create_directories(dir, ec);
  for (int i = 0; i < count; ++i) {
    const auto output = dir / ("out_" + std::to_string(i) + ".mp4");
    std::filesystem::remove(output, ec);
    const std::string text =
        make_task(input, output.u8string(), hardware, "h264", 60, false, "", 0,
                  0)
            .dump();
    const int64_t task_id = ak_task_submit(text.c_str());
    std::printf("task_id=%lld\n", static_cast<long long>(task_id));
    if (task_id < 0) {
      ak_shutdown();
      return 1;
    }
  }

  {
    std::unique_lock<std::mutex> lock(g_wait_mtx);
    g_wait_cv.wait_for(lock, std::chrono::minutes(20),
                       [] { return g_terminal; });
  }
  ak_shutdown();
  return (g_terminal && !g_failed.load()) ? 0 : 1;
}

}  // namespace

int main(int argc, char** argv) {
#ifdef _WIN32
  SetConsoleOutputCP(CP_UTF8);
  SetConsoleCP(CP_UTF8);
#endif
  if (argc < 2) {
    usage();
    return 1;
  }

  const std::string command = argv[1];

  if (command == "version") {
    std::printf("abi: %u.%u (0x%08x)\n", AK_ABI_MAJOR, AK_ABI_MINOR,
                ak_abi_version());
    print_json("version", ak_version_json());
    return 0;
  }

  if (command == "init" || command == "caps") {
    const std::string work_dir = argc > 2 ? argv[2] : default_work_dir();
    if (init_engine(work_dir) != 0) {
      return 1;
    }
    if (command == "init") {
      print_json("version", ak_version_json());
    }
    print_json("capabilities", ak_capabilities_json());
    ak_shutdown();
    return 0;
  }

  if (command == "probe") {
    if (argc < 3) {
      usage();
      return 1;
    }
    const std::string work_dir = argc > 3 ? argv[3] : default_work_dir();
    if (init_engine(work_dir) != 0) {
      return 1;
    }
    print_json("probe", ak_probe(argv[2]));
    ak_shutdown();
    return 0;
  }

  if (command == "transcode") {
    if (argc < 5) {
      usage();
      return 1;
    }
    std::string input = argv[2];
    std::string output = argv[3];
    std::string work_dir = argv[4];
    std::string hardware = "off";
    std::string codec = "h264";
    int32_t quality = 60;
    int cancel_ms = 0;
    bool overwrite = false;
    std::string trans_mode;
    std::string audio_codec = "aac";
    std::string container = "mp4";
    int32_t width = 0;
    int32_t height = 0;

    for (int i = 5; i < argc; ++i) {
      const std::string arg = argv[i];
      if (arg == "--hardware" && i + 1 < argc) {
        hardware = argv[++i];
      } else if (arg == "--codec" && i + 1 < argc) {
        codec = argv[++i];
      } else if (arg == "--audio-codec" && i + 1 < argc) {
        audio_codec = argv[++i];
      } else if (arg == "--container" && i + 1 < argc) {
        container = argv[++i];
      } else if (arg == "--quality" && i + 1 < argc) {
        quality = std::atoi(argv[++i]);
      } else if (arg == "--cancel-ms" && i + 1 < argc) {
        cancel_ms = std::atoi(argv[++i]);
      } else if (arg == "--trans-mode" && i + 1 < argc) {
        trans_mode = argv[++i];
      } else if (arg == "--width" && i + 1 < argc) {
        width = std::atoi(argv[++i]);
      } else if (arg == "--height" && i + 1 < argc) {
        height = std::atoi(argv[++i]);
      } else if (arg == "--overwrite") {
        overwrite = true;
      }
    }
    return run_transcode(input, output, work_dir, hardware, codec, quality,
                         cancel_ms, overwrite, trans_mode, width, height,
                         audio_codec, container);
  }

  if (command == "queue") {
    if (argc < 6) {
      usage();
      return 1;
    }
    const std::string input = argv[2];
    const std::string out_dir = argv[3];
    const std::string work_dir = argv[4];
    const int count = std::atoi(argv[5]);
    std::string hardware = "off";
    for (int i = 6; i < argc; ++i) {
      const std::string arg = argv[i];
      if (arg == "--hardware" && i + 1 < argc) {
        hardware = argv[++i];
      }
    }
    return run_queue(input, out_dir, work_dir, count, hardware);
  }

  if (command == "remux") {
    if (argc < 5) {
      usage();
      return 1;
    }
    bool overwrite = false;
    for (int i = 5; i < argc; ++i) {
      if (std::string(argv[i]) == "--overwrite") {
        overwrite = true;
      }
    }
    return run_one(make_shell("remux", argv[2], argv[3], overwrite), argv[3],
                   argv[4]);
  }

  if (command == "extract") {
    if (argc < 5) {
      usage();
      return 1;
    }
    std::string codec = "aac";
    int bitrate = -1;
    bool overwrite = false;
    for (int i = 5; i < argc; ++i) {
      const std::string arg = argv[i];
      if (arg == "--codec" && i + 1 < argc) {
        codec = argv[++i];
      } else if (arg == "--bitrate" && i + 1 < argc) {
        bitrate = std::atoi(argv[++i]);
      } else if (arg == "--overwrite") {
        overwrite = true;
      }
    }
    auto task = make_shell("extract", argv[2], argv[3], overwrite);
    task["params"]["audio"] = {{"codec", codec}, {"bitrate_kbps", bitrate}};
    return run_one(task, argv[3], argv[4]);
  }

  usage();
  return 1;
}
