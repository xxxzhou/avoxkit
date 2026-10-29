#include "ak_internal.hpp"

#include <string>

#include <nlohmann/json.hpp>

#include "avox/AvoxSubtitle.h"

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/avutil.h>
#include <libavutil/dict.h>
#include <libavutil/error.h>
#include <libavutil/pixdesc.h>
#include <libavutil/samplefmt.h>
}

namespace ak {
namespace {

std::string error_json(const char* code, const std::string& message) {
  nlohmann::json j;
  j["ok"] = false;
  j["code"] = code;
  j["message"] = message;
  return j.dump();
}

std::string ffmpeg_error(int ret) {
  char buf[AV_ERROR_MAX_STRING_SIZE] = {};
  av_strerror(ret, buf, sizeof(buf));
  return buf;
}

}  // namespace

std::string probe_uri_json(const std::string& uri) {
  AVFormatContext* format = nullptr;
  int ret = avformat_open_input(&format, uri.c_str(), nullptr, nullptr);
  if (ret < 0 || !format) {
    return error_json("input_open_failed", ffmpeg_error(ret));
  }

  ret = avformat_find_stream_info(format, nullptr);
  if (ret < 0) {
    const std::string message = ffmpeg_error(ret);
    avformat_close_input(&format);
    return error_json("input_open_failed", message);
  }

  nlohmann::json j;
  j["ok"] = true;
  j["uri"] = uri;
  j["format"] =
      (format->iformat && format->iformat->name) ? format->iformat->name : "";
  j["duration_ms"] =
      format->duration != AV_NOPTS_VALUE
          ? format->duration / (AV_TIME_BASE / 1000)
          : 0;
  j["bit_rate"] = format->bit_rate;
  j["can_seek"] =
      format->pb && (format->pb->seekable & AVIO_SEEKABLE_NORMAL) != 0;

  nlohmann::json video = nlohmann::json::array();
  nlohmann::json audio = nlohmann::json::array();
  nlohmann::json subtitles = nlohmann::json::array();

  for (unsigned i = 0; i < format->nb_streams; ++i) {
    const AVStream* stream = format->streams[i];
    const AVCodecParameters* par = stream ? stream->codecpar : nullptr;
    if (!par) {
      continue;
    }

    nlohmann::json track;
    track["index"] = static_cast<int>(i);
    track["codec"] = avcodec_get_name(par->codec_id);
    const AVDictionaryEntry* lang =
        av_dict_get(stream->metadata, "language", nullptr, 0);
    if (lang && lang->value) {
      track["language"] = lang->value;
    }
    const AVDictionaryEntry* title =
        av_dict_get(stream->metadata, "title", nullptr, 0);
    if (title && title->value) {
      track["title"] = title->value;
    }

    if (par->codec_type == AVMEDIA_TYPE_VIDEO) {
      track["width"] = par->width;
      track["height"] = par->height;
      double fps = 0.0;
      if (stream->avg_frame_rate.den > 0) {
        fps = av_q2d(stream->avg_frame_rate);
      } else if (stream->r_frame_rate.den > 0) {
        fps = av_q2d(stream->r_frame_rate);
      }
      track["fps"] = fps;
      const char* pix = av_get_pix_fmt_name(
          static_cast<AVPixelFormat>(par->format));
      track["pix_fmt"] = pix ? pix : "";
      video.push_back(std::move(track));
    } else if (par->codec_type == AVMEDIA_TYPE_AUDIO) {
      track["channels"] = par->ch_layout.nb_channels;
      track["sample_rate"] = par->sample_rate;
      track["bit_rate"] = par->bit_rate;
      const char* sample = av_get_sample_fmt_name(
          static_cast<AVSampleFormat>(par->format));
      track["sample_fmt"] = sample ? sample : "";
      audio.push_back(std::move(track));
    } else if (par->codec_type == AVMEDIA_TYPE_SUBTITLE) {
      track["text"] = avox::isTextSubtitleCodec(avcodec_get_name(par->codec_id));
      track["default"] =
          (stream->disposition & AV_DISPOSITION_DEFAULT) != 0;
      track["forced"] = (stream->disposition & AV_DISPOSITION_FORCED) != 0;
      subtitles.push_back(std::move(track));
    }
  }

  j["video"] = std::move(video);
  j["audio"] = std::move(audio);
  j["subtitles"] = std::move(subtitles);

  avformat_close_input(&format);
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
