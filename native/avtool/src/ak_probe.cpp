// 媒体探测: avox IMediaReader open → ISourceInfo → JSON。
// codec 用引擎返回的原始名; 封面图流由 reader 跳过; 旋转是 avox 内部语义,
// probe 只透出轨上的 rotation 供诊断。
#include "ak_internal.hpp"
#include "ak_reader.hpp"

#include <memory>
#include <string>

#include <nlohmann/json.hpp>

#include "avox/AvoxMedia.h"
#include "avox/AvoxSubtitle.h"

namespace ak {
namespace {

using nlohmann::json;

std::string error_json(const char* code, const std::string& message) {
  json j;
  j["ok"] = false;
  j["code"] = code;
  j["message"] = message;
  return j.dump();
}

}  // namespace

std::string probe_uri_json(const std::string& uri) {
  std::unique_ptr<avox::IMediaReader> reader(avox::createMediaReader());
  if (!reader) {
    return error_json("not_implemented", "media reader unavailable");
  }
  ReaderShim shim;
  if (!openReader(*reader, shim, uri.c_str())) {
    reader->close();
    return error_json(media_error_code(shim.errorCode, "probe_failed"),
                      shim.errorMessage);
  }
  avox::ISourceInfo* info = reader->getSourceInfo();

  json j;
  j["ok"] = true;
  j["uri"] = uri;
  j["format"] = info->formatName();
  j["duration_ms"] = info->durationMs();
  j["bit_rate"] = info->bitRate();
  j["can_seek"] = info->canSeek();

  json video = json::array();
  for (int32_t i = 0; i < info->videoSize(); ++i) {
    const avox::VTrackDesc desc = info->getVideoDesc(i);
    json track;
    track["index"] = desc.trackId;
    track["codec"] = info->getVideoCodecName(i);
    track["width"] = desc.desc.width;
    track["height"] = desc.desc.height;
    track["fps"] = desc.desc.fps;
    track["rotation"] = desc.rotation;
    video.push_back(std::move(track));
  }

  json audio = json::array();
  for (int32_t i = 0; i < info->audioSize(); ++i) {
    const avox::ATrackDesc desc = info->getAudioDesc(i);
    json track;
    track["index"] = desc.trackId;
    track["codec"] = info->getAudioCodecName(i);
    track["channels"] = desc.desc.channels;
    track["sample_rate"] = desc.desc.sampleRate;
    audio.push_back(std::move(track));
  }

  json subtitles = json::array();
  for (int32_t i = 0; i < info->subtitleSize(); ++i) {
    const avox::ISTrackDesc* desc = info->getSubtitleDesc(i);
    if (!desc) {
      continue;
    }
    const char* codec = desc->codecName();
    json track;
    track["index"] = desc->trackId();
    track["codec"] = codec ? codec : "";
    if (desc->lang() && *desc->lang()) {
      track["language"] = desc->lang();
    }
    if (desc->title() && *desc->title()) {
      track["title"] = desc->title();
    }
    track["text"] = avox::isTextSubtitleCodec(codec);
    track["default"] = desc->isDefault();
    track["forced"] = desc->forced();
    subtitles.push_back(std::move(track));
  }

  j["video"] = std::move(video);
  j["audio"] = std::move(audio);
  j["subtitles"] = std::move(subtitles);

  reader->close();
  return j.dump();
}

}  // namespace ak

extern "C" const char* ak_probe(const char* uri) {
  if (!uri || !*uri) {
    return ak::dup_cstr(
        "{\"ok\":false,\"code\":\"bad_source\",\"message\":\"uri is empty\"}");
  }
  ak::log(ak::LogLevel::debug, std::string("probe: ") + uri);
  return ak::dup_cstr(ak::probe_uri_json(uri));
}
