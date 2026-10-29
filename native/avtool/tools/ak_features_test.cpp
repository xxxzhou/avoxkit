// 无头功能集成测试: 同一进程内跑转换/封装/直拷/提取/队列/错误路径。
// 用法: ak_features_test <源文件> <work_dir> <输出目录>
#include "ak.h"

#include <algorithm>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include <nlohmann/json.hpp>

namespace {

using json = nlohmann::json;
namespace fs = std::filesystem;

struct EventState {
  int expected = 1;
  int terminal = 0;
  bool finished = false;
  bool failed = false;
  std::vector<int64_t> done_ids;
  std::vector<int64_t> error_ids;
  std::vector<int> queue_positions;
  std::string last_error;
};

std::mutex g_mtx;
std::condition_variable g_cv;
EventState g_events;
int g_checks = 0;
int g_failures = 0;

void check(bool ok, const std::string& label) {
  ++g_checks;
  if (ok) {
    std::printf("  ok   %s\n", label.c_str());
  } else {
    ++g_failures;
    std::printf("  FAIL %s\n", label.c_str());
  }
}

void skip(const std::string& label, const std::string& why) {
  std::printf("  skip %s (%s)\n", label.c_str(), why.c_str());
}

void reset_events(int expected) {
  std::lock_guard<std::mutex> lock(g_mtx);
  g_events = EventState{};
  g_events.expected = expected;
}

void on_event(const char* event_json, void*) {
  const json j =
      json::parse(event_json ? event_json : "{}", nullptr, false);
  if (j.is_object()) {
    std::lock_guard<std::mutex> lock(g_mtx);
    const std::string type = j.value("type", "");
    if (type == "state") {
      const std::string state = j.value("state", "");
      if (state == "queued" && j.contains("queue_position") &&
          j["queue_position"].is_number()) {
        g_events.queue_positions.push_back(
            j["queue_position"].get<int>());
      }
      if (state == "cancelled") {
        ++g_events.terminal;
      }
    } else if (type == "done") {
      ++g_events.terminal;
      g_events.done_ids.push_back(j.value("task_id", int64_t{0}));
    } else if (type == "error") {
      ++g_events.terminal;
      g_events.failed = true;
      g_events.error_ids.push_back(j.value("task_id", int64_t{0}));
      g_events.last_error =
          j.value("code", "") + ": " + j.value("message", "");
    }
    if (g_events.terminal >= g_events.expected) {
      g_events.finished = true;
      g_cv.notify_all();
    }
  }
  ak_event_free(event_json);
}

bool wait_finished(int timeout_ms) {
  std::unique_lock<std::mutex> lock(g_mtx);
  return g_cv.wait_for(lock, std::chrono::milliseconds(timeout_ms),
                       [] { return g_events.finished; });
}

json probe(const std::string& path) {
  const char* raw = ak_probe(path.c_str());
  json j = json::parse(raw ? raw : "{}", nullptr, false);
  if (raw) {
    ak_free_string(raw);
  }
  return j.is_object() ? j : json::object();
}

json first_track(const json& media, const char* role) {
  if (!media.contains(role) || !media[role].is_array() ||
      media[role].empty() || !media[role][0].is_object()) {
    return json::object();
  }
  return media[role][0];
}

std::string codec_of(const json& track) {
  const std::string codec = track.value("codec", "");
  if (codec == "h265" || codec == "hevc") {
    return "hevc";
  }
  if (codec == "avc") {
    return "h264";
  }
  return codec;
}

json make_task(const std::string& kind, const std::string& input,
               const std::string& output, json params) {
  json task;
  task["schema"] = 1;
  task["kind"] = kind;
  task["sources"] =
      json::array({{{"kind", "file"}, {"uri", input}}});
  task["outputs"] =
      json::array({{{"role", "primary"}, {"path", output}}});
  task["params"] = std::move(params);
  return task;
}

json transcode_params(const std::string& video_codec, int32_t width,
                      int32_t height, const std::string& trans_mode,
                      const std::string& audio_codec, int32_t audio_kbps) {
  json params = {
      {"container", "mp4"},
      {"overwrite", true},
      {"trans_mode", trans_mode},
      {"video",
       {{"codec", video_codec},
        {"hardware", "off"},
        {"rate_mode", "quality"},
        {"quality", 60}}},
      {"audio", {{"codec", audio_codec}, {"bitrate_kbps", audio_kbps}}}};
  if (width > 0 && height > 0) {
    params["video"]["width"] = width;
    params["video"]["height"] = height;
  }
  return params;
}

struct Expect {
  std::string video;  // empty=忽略, "none"=必须无视频
  int width = 0;
  int height = 0;
  std::string audio;  // empty=忽略, "none"=必须无音频
  int duration_tolerance_ms = 2500;
};

// .mp4 必须是标准 MP4 品牌; 非 AAC 音频曾被整体改写成 qt 容器,
// 播放器会把 mp3 轨当未知(无声音)
void check_mp4_brand(const std::string& path, const std::string& name) {
  std::ifstream in(path, std::ios::binary);
  char hdr[12] = {};
  in.read(hdr, sizeof(hdr));
  const std::string brand =
      in.gcount() == static_cast<std::streamsize>(sizeof(hdr))
          ? std::string(hdr + 8, 4)
          : std::string();
  check(!brand.empty() && brand != "qt  ", name + " 容器品牌非 qt");
}

// .mka 走 matroska 音频容器(EBML magic); FFmpeg muxer 扩展表没有 mka,
// 引擎要自己映射, 否则会退回同名 .mkv 或打开失败
void check_matroska(const std::string& path, const std::string& name) {
  std::ifstream in(path, std::ios::binary);
  unsigned char hdr[4] = {};
  in.read(reinterpret_cast<char*>(hdr), sizeof(hdr));
  check(in.gcount() == static_cast<std::streamsize>(sizeof(hdr)) &&
            hdr[0] == 0x1A && hdr[1] == 0x45 && hdr[2] == 0xDF &&
            hdr[3] == 0xA3,
        name + " 是 matroska 容器");
}

void check_output(const std::string& path, const std::string& name,
                  const Expect& expect, int64_t source_duration_ms) {
  const json media = probe(path);
  const bool ok = media.value("ok", false);
  check(ok, name + " 产物可探测");
  if (!ok) {
    return;
  }
  const json video = first_track(media, "video");
  const json audio = first_track(media, "audio");
  if (expect.video == "none") {
    check(video.empty(), name + " 无视频轨");
  } else if (!expect.video.empty()) {
    check(!video.empty(), name + " 有视频轨");
    if (!video.empty()) {
      check(codec_of(video) == expect.video,
            name + " 视频编码=" + expect.video);
      if (expect.width > 0) {
        check(video.value("width", 0) == expect.width,
              name + " 宽=" + std::to_string(expect.width));
      }
      if (expect.height > 0) {
        check(video.value("height", 0) == expect.height,
              name + " 高=" + std::to_string(expect.height));
      }
    }
  }
  if (expect.audio == "none") {
    check(audio.empty(), name + " 无音频轨");
  } else if (!expect.audio.empty()) {
    check(!audio.empty(), name + " 有音频轨");
    if (!audio.empty()) {
      check(codec_of(audio) == expect.audio,
            name + " 音频编码=" + expect.audio);
    }
  }
  if (source_duration_ms > 0) {
    const int64_t duration = media.value("duration_ms", int64_t{0});
    check(duration >= source_duration_ms - expect.duration_tolerance_ms &&
              duration <= source_duration_ms + expect.duration_tolerance_ms,
          name + " 时长≈源");
  }
}

bool run_task(const std::string& name, const json& task) {
  reset_events(1);
  const std::string text = task.dump();
  const int64_t id = ak_task_submit(text.c_str());
  if (id <= 0) {
    check(false, name + " 提交成功 (rc=" + std::to_string(id) + ")");
    return false;
  }
  if (!wait_finished(180000)) {
    check(false, name + " 在超时前结束");
    return false;
  }
  const bool ok = g_events.terminal == 1 && !g_events.failed;
  check(ok, name + " 完成");
  if (g_events.failed) {
    std::printf("       error: %s\n", g_events.last_error.c_str());
  }
  return ok;
}

int64_t expect_submit_error(const std::string& name, const json& task,
                            int32_t expected) {
  reset_events(1);
  const int64_t id = ak_task_submit(task.dump().c_str());
  check(id == expected, name + " 返回 " + std::to_string(expected) +
                            " (实际 " + std::to_string(id) + ")");
  return id;
}

std::string read_logs(const fs::path& work_dir) {
  std::string all;
  std::error_code ec;
  const fs::path logs = work_dir / "logs";
  if (!fs::is_directory(logs, ec)) {
    return all;
  }
  for (const auto& entry : fs::directory_iterator(logs, ec)) {
    if (ec || !entry.is_regular_file() ||
        entry.path().extension() != ".log") {
      continue;
    }
    std::ifstream in(entry.path(), std::ios::binary);
    all.append(std::istreambuf_iterator<char>(in),
               std::istreambuf_iterator<char>());
  }
  return all;
}

}  // namespace

int main(int argc, char** argv) {
  if (argc < 4) {
    std::printf("usage: ak_features_test <in> <work_dir> <out_dir>\n");
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
  for (const char* name :
       {"remux.mp4", "audio_copy.mp4", "video_copy.mp4", "all.mp4",
        "extract.m4a", "extract.mp3", "extract_copy.m4a", "queue_0.mp4",
        "queue_1.mp4", "queue_2.mp4", "mixed_remux.mp4",
        "mixed_copy.mp4", "exists.mp4", "bad.mp4", "trim.mp4"}) {
    fs::remove(out_dir / name, ec);
  }

  json config = {{"work_dir", work_dir.u8string()}, {"log_level", "info"}};
  if (ak_init(config.dump().c_str()) != 0) {
    std::printf("ak_init failed\n");
    return 1;
  }
  ak_set_event_cb(on_event, nullptr);

  const bool hevc_ok = ak_encoder_probe("hevc") == 1;
  const bool aac_ok = ak_encoder_probe("aac") == 1;
  const bool mp3_ok = ak_encoder_probe("mp3") == 1;
  const std::string target_vcodec = hevc_ok ? "hevc" : "h264";

  std::printf("\n[capabilities]\n");
  check(ak_encoder_probe("h264") == 1, "H.264 编码器可用");
  check(hevc_ok, "H.265 编码器可用");
  check(aac_ok, "AAC 编码器可用");
  check(mp3_ok, "MP3 编码器可用");
  const char* caps = ak_capabilities_json();
  const json cap_json =
      json::parse(caps ? caps : "{}", nullptr, false);
  if (caps) {
    ak_free_string(caps);
  }
  check(cap_json.contains("features") && cap_json["features"].is_object(),
        "capabilities 可读");
  if (cap_json.contains("features") && cap_json["features"].is_object()) {
    check(cap_json["features"].value("probe", false), "features.probe=true");
    check(cap_json["features"].value("transcode", false),
          "features.transcode=true");
    check(cap_json["features"].value("remux", false), "features.remux=true");
    check(cap_json["features"].value("extract", false),
          "features.extract=true");
    check(cap_json["features"].value("subtitle", false),
          "features.subtitle=true");
    check(cap_json["features"].value("trim", false), "features.trim=true");
    check(cap_json["features"].value("media_index", false),
          "features.media_index=true");
    check(cap_json["features"].value("media_frames", false),
          "features.media_frames=true");
  }

  std::printf("\n[probe]\n");
  const json source = probe(input);
  const bool source_ok = source.value("ok", false);
  check(source_ok, "源文件可探测");
  if (!source_ok) {
    ak_shutdown();
    return 1;
  }
  const json src_v = first_track(source, "video");
  const json src_a = first_track(source, "audio");
  const std::string src_vcodec = codec_of(src_v);
  const std::string src_acodec = codec_of(src_a);
  const int32_t src_w = src_v.value("width", 0);
  const int32_t src_h = src_v.value("height", 0);
  const int64_t src_duration = source.value("duration_ms", int64_t{0});
  check(!src_v.empty(), "源有视频轨");
  check(!src_a.empty(), "源有音频轨");
  check(src_w > 0 && src_h > 0, "源分辨率可读");
  check(src_duration > 0, "源时长可读");
  std::printf("       source: %s %dx%d + %s, %lldms\n",
              src_vcodec.c_str(), src_w, src_h, src_acodec.c_str(),
              static_cast<long long>(src_duration));

  const bool mp4_compatible =
      (src_vcodec == "h264" || src_vcodec == "hevc") &&
      (src_acodec == "aac" || src_acodec == "mp3");

  std::printf("\n[media index]\n");
  {
    const char* raw = ak_media_index(input.c_str(), 300);
    const json idx = json::parse(raw ? raw : "{}", nullptr, false);
    if (raw) {
      ak_free_string(raw);
    }
    check(idx.value("ok", false), "media index 可读");
    check(idx.value("duration_ms", int64_t{0}) > 0, "media index 时长可读");
    check(idx.contains("keyframes_ms") && idx["keyframes_ms"].is_array() &&
              !idx["keyframes_ms"].empty(),
          "media index 有关键帧");
    check(idx.contains("peaks") && idx["peaks"].is_array(),
          "media index 有包络字段");
    if (idx.value("has_audio", false)) {
      check(idx["peaks"].is_array() && !idx["peaks"].empty(),
            "media index 音频包络非空");
    } else {
      skip("media index 音频包络", "源无音轨");
    }
  }

  std::printf("\n[media frames]\n");
  {
    const json request = {{"count", 4}, {"width", 160}, {"quality", 70}};
    const std::string request_text = request.dump();
    const char* raw = ak_media_frames(input.c_str(), request_text.c_str());
    const json frames = json::parse(raw ? raw : "{}", nullptr, false);
    if (raw) {
      ak_free_string(raw);
    }
    check(frames.value("ok", false), "media frames 可读");
    check(frames.value("has_video", false), "media frames 识别视频轨");
    check(frames.value("width", 0) == 160, "media frames 按请求宽度输出");
    check(frames.value("height", 0) > 0, "media frames 有输出高度");
    const json list = frames.contains("frames") ? frames["frames"] : json();
    check(list.is_array() && list.size() == 4, "media frames 返回 4 帧");
    if (list.is_array()) {
      bool ordered = true;
      int64_t last_ms = -1;
      for (const auto& item : list) {
        const std::string image = item.value("image", "");
        check(image.rfind("/9j/", 0) == 0, "media frames 是 JPEG");
        if (item.value("ms", int64_t{-1}) < last_ms) {
          ordered = false;
        }
        last_ms = item.value("ms", int64_t{-1});
      }
      check(ordered, "media frames 时间递增");
      check(last_ms > 0, "media frames 带实际帧时间");
    }

    const json single = {{"times_ms", {1200}}, {"width", 200}};
    const std::string single_text = single.dump();
    const char* one_raw = ak_media_frames(input.c_str(), single_text.c_str());
    const json one = json::parse(one_raw ? one_raw : "{}", nullptr, false);
    if (one_raw) {
      ak_free_string(one_raw);
    }
    check(one.value("ok", false) && one.contains("frames") &&
              one["frames"].is_array() && one["frames"].size() == 1,
          "media frames 单点抓帧");
  }

  std::printf("\n[remux]\n");
  if (mp4_compatible) {
    const fs::path path = out_dir / "remux.mp4";
    if (run_task("remux", make_task("remux", input, path.u8string(),
                                    {{"container", "mp4"},
                                     {"overwrite", true}}))) {
      check_output(path.u8string(), "remux",
                   {src_vcodec, src_w, src_h, src_acodec}, src_duration);
    }
  } else {
    skip("remux", "源编码组合不适合 MP4 直拷");
  }

  std::printf("\n[transcode: 视频重编 + 音频直拷 + 缩放]\n");
  {
    const fs::path path = out_dir / "audio_copy.mp4";
    if (run_task(
            "audio_copy",
            make_task("transcode", input, path.u8string(),
                      transcode_params(target_vcodec, 320, 180,
                                       "audio_copy", src_acodec, -1)))) {
      check_output(path.u8string(), "audio_copy",
                   {target_vcodec, 320, 180, src_acodec}, src_duration);
    }
  }

  std::printf("\n[transcode: 视频直拷 + 音频重编]\n");
  if (mp3_ok) {
    const fs::path path = out_dir / "video_copy.mp4";
    if (run_task("video_copy",
                 make_task("transcode", input, path.u8string(),
                           transcode_params("h264", 0, 0, "video_copy",
                                            "mp3", 192)))) {
      check_output(path.u8string(), "video_copy",
                   {src_vcodec, src_w, src_h, "mp3"}, src_duration);
      check_mp4_brand(path.u8string(), "video_copy");
    }
  } else {
    skip("video_copy", "MP3 编码器不可用");
  }

  std::printf("\n[transcode: 全部重编 + 缩放]\n");
  {
    const fs::path path = out_dir / "all.mp4";
    if (run_task("all",
                 make_task("transcode", input, path.u8string(),
                           transcode_params(target_vcodec, 320, 180, "all",
                                            "aac", -1)))) {
      check_output(path.u8string(), "all",
                   {target_vcodec, 320, 180, "aac"}, src_duration);
    }
  }

  std::printf("\n[extract]\n");
  if (aac_ok) {
    const fs::path path = out_dir / "extract.m4a";
    if (run_task("extract aac",
                 make_task("extract", input, path.u8string(),
                           {{"overwrite", true},
                            {"extract", {{"target", "audio"}}},
                            {"audio",
                             {{"codec", "aac"}, {"bitrate_kbps", 128}}}}))) {
      check_output(path.u8string(), "extract aac",
                   {"none", 0, 0, "aac"}, src_duration);
    }
  } else {
    skip("extract aac", "AAC 编码器不可用");
  }
  if (mp3_ok) {
    const fs::path path = out_dir / "extract.mp3";
    if (run_task("extract mp3",
                 make_task("extract", input, path.u8string(),
                           {{"overwrite", true},
                            {"extract", {{"target", "audio"}}},
                            {"audio",
                             {{"codec", "mp3"}, {"bitrate_kbps", 192}}}}))) {
      check_output(path.u8string(), "extract mp3",
                   {"none", 0, 0, "mp3"}, src_duration);
    }
  } else {
    skip("extract mp3", "MP3 编码器不可用");
  }
  {
    const fs::path path = out_dir / "extract_copy.m4a";
    if (run_task("extract copy",
                 make_task("extract", input, path.u8string(),
                           {{"overwrite", true},
                            {"extract", {{"target", "audio"}}},
                            {"audio",
                             {{"codec", "copy"}, {"bitrate_kbps", -1}}}}))) {
      check_output(path.u8string(), "extract copy",
                   {"none", 0, 0, src_acodec}, src_duration);
    }
  }
  {
    const fs::path path = out_dir / "extract_copy.mka";
    if (run_task("extract copy mka",
                 make_task("extract", input, path.u8string(),
                           {{"overwrite", true},
                            {"extract", {{"target", "audio"}}},
                            {"audio",
                             {{"codec", "copy"}, {"bitrate_kbps", -1}}}}))) {
      check_output(path.u8string(), "extract copy mka",
                   {"none", 0, 0, src_acodec}, src_duration);
      check_matroska(path.u8string(), "extract copy mka");
    }
  }

  std::printf("\n[trim]\n");
  {
    const int64_t start = src_duration > 14000 ? 8000 : src_duration / 4;
    const int64_t end = std::min<int64_t>(src_duration, start + 6000);
    const int64_t span = end - start;
    const fs::path path = out_dir / "trim.mp4";
    const json task = make_task(
        "trim", input, path.u8string(),
        {{"container", "mp4"},
         {"overwrite", true},
         {"video",
          {{"codec", target_vcodec},
           {"hardware", "off"},
           {"rate_mode", "quality"},
           {"quality", 60}}},
         {"audio", {{"codec", "aac"}, {"bitrate_kbps", -1}}},
         {"trim", {{"start_ms", start}, {"end_ms", end}}}});
    if (run_task("trim", task)) {
      Expect expect{target_vcodec, 0, 0, "aac", 1500};
      check_output(path.u8string(), "trim", expect, span);
    }

    std::printf("\n[trim 错误路径]\n");
    auto invalid = task;
    invalid["outputs"][0]["path"] = (out_dir / "bad.mp4").u8string();
    invalid["params"]["trim"]["end_ms"] = start;
    expect_submit_error("trim 反向区间", invalid, -2);
    auto past = task;
    past["outputs"][0]["path"] = (out_dir / "bad.mp4").u8string();
    past["params"]["trim"]["start_ms"] = src_duration + 1000;
    past["params"]["trim"]["end_ms"] = src_duration + 2000;
    expect_submit_error("trim 起点超出片长", past, -2);
    auto tail = task;
    tail["outputs"][0]["path"] = (out_dir / "bad.mp4").u8string();
    tail["params"]["trim"]["start_ms"] = src_duration * 91 / 100;
    tail["params"]["trim"]["end_ms"] = src_duration;
    expect_submit_error("trim 起点超过片长 90%", tail, -2);
  }

  std::printf("\n[queue: 3 个转码任务]\n");
  {
    reset_events(3);
    int submitted = 0;
    for (int i = 0; i < 3; ++i) {
      const fs::path path = out_dir / ("queue_" + std::to_string(i) + ".mp4");
      const json task =
          make_task("transcode", input, path.u8string(),
                    transcode_params("h264", 320, 180, "all", "aac", -1));
      const int64_t id = ak_task_submit(task.dump().c_str());
      check(id > 0, "queue 提交 #" + std::to_string(i));
      if (id > 0) {
        ++submitted;
      }
    }
    check(submitted == 3, "queue 提交 3 个");
    const bool finished = wait_finished(300000);
    check(finished, "queue 全部结束");
    check(g_events.terminal == 3 && !g_events.failed,
          "queue 三个任务都完成");
    check(g_events.queue_positions.size() == 3,
          "queue_position 事件 = 3");
    for (const int pos : g_events.queue_positions) {
      check(pos >= 1 && pos <= 3, "queue_position 在 1..3");
    }
    for (int i = 0; i < 3; ++i) {
      check_output(
          (out_dir / ("queue_" + std::to_string(i) + ".mp4")).u8string(),
          "queue #" + std::to_string(i), {"h264", 320, 180, "aac"},
          src_duration);
    }
  }

  std::printf("\n[queue: 混合 kind]\n");
  if (mp4_compatible) {
    reset_events(2);
    const fs::path remux_path = out_dir / "mixed_remux.mp4";
    const fs::path copy_path = out_dir / "mixed_copy.mp4";
    const int64_t a = ak_task_submit(
        make_task("remux", input, remux_path.u8string(),
                  {{"container", "mp4"}, {"overwrite", true}})
            .dump()
            .c_str());
    const int64_t b = ak_task_submit(
        make_task("transcode", input, copy_path.u8string(),
                  transcode_params("h264", 0, 0, "video_copy",
                                   mp3_ok ? "mp3" : "aac", -1))
            .dump()
            .c_str());
    check(a > 0 && b > 0, "混合组提交 remux + video_copy");
    check(wait_finished(240000), "混合组全部结束");
    check(g_events.terminal == 2 && !g_events.failed,
          "混合组两个任务都完成");
    check_output(remux_path.u8string(), "mixed remux",
                 {src_vcodec, src_w, src_h, src_acodec}, src_duration);
    check_output(copy_path.u8string(), "mixed video_copy",
                 {src_vcodec, src_w, src_h, mp3_ok ? "mp3" : "aac"},
                 src_duration);
  } else {
    skip("混合 kind", "源编码组合不适合 MP4 直拷");
  }

  std::printf("\n[错误路径]\n");
  {
    json bad = make_task("transcode", input,
                         (out_dir / "bad.mp4").u8string(),
                         transcode_params("h264", 320, 180, "video_copy",
                                          "aac", -1));
    expect_submit_error("video_copy + 缩放", bad, AK_E_BAD_JSON);
  }
  {
    json bad = make_task("transcode", input,
                         (out_dir / "bad.mp4").u8string(),
                         transcode_params("h264", 320, 181, "all", "aac",
                                          -1));
    expect_submit_error("奇数分辨率", bad, AK_E_BAD_JSON);
  }
  {
    json bad = make_task("transcode", input,
                         (out_dir / "bad.mp4").u8string(),
                         transcode_params("h264", 0, 0, "all", "aac", -1));
    bad["params"]["video"]["width"] = 320;
    expect_submit_error("只给宽不给高", bad, AK_E_BAD_JSON);
  }
  {
    const json bad = make_task(
        "transcode", (out_dir / "missing.mkv").u8string(),
        (out_dir / "bad.mp4").u8string(),
        transcode_params("h264", 0, 0, "all", "aac", -1));
    expect_submit_error("输入不存在", bad, AK_E_BAD_SOURCE);
  }
  {
    const fs::path exists = out_dir / "exists.mp4";
    std::ofstream(exists, std::ios::binary) << "x";
    json bad = make_task("transcode", input, exists.u8string(),
                         transcode_params("h264", 0, 0, "all", "aac", -1));
    bad["params"]["overwrite"] = false;
    expect_submit_error("输出已存在", bad, AK_E_BAD_OUTPUT);
  }
  {
    const json bad = make_task(
        "transcode", input, (out_dir / "bad.mp4").u8string(),
        transcode_params("vp9", 0, 0, "all", "aac", -1));
    expect_submit_error("不支持的视频编码", bad, AK_E_UNSUPPORTED_KIND);
  }

  ak_shutdown();
  std::this_thread::sleep_for(std::chrono::milliseconds(300));

  std::printf("\n[引擎路径]\n");
  const std::string logs = read_logs(work_dir);
  check(logs.find("audio copy mode") != std::string::npos,
        "日志出现 audio copy mode");
  check(logs.find("video copy mode") != std::string::npos,
        "日志出现 video copy mode");
  check(logs.find("enableSizeChange") != std::string::npos,
        "日志出现 enableSizeChange");
  // 多声道/平面格式曾按字节切片导致 send_frame 全失败(产物无音轨)
  check(logs.find("send_frame failed") == std::string::npos,
        "音频编码无 send_frame 失败");

  std::printf("\n%d checks, %d failed\n", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
