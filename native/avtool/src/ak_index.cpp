// 只读媒体索引: 一次性 demux + 仅解音频, 给时间线提供包络与关键帧位置。
// 不解视频、不写产物, 与任务队列无关; 调用方(Flutter isolate)可直接阻塞等待。
#include "ak_internal.hpp"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <string>
#include <vector>

#include <nlohmann/json.hpp>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/avutil.h>
#include <libavutil/error.h>
#include <libavutil/mathematics.h>
#include <libavutil/samplefmt.h>
}

namespace ak {
namespace {

using nlohmann::json;

std::string index_error(const std::string& code, const std::string& message) {
  json j;
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

int64_t pts_to_ms(int64_t pts, AVRational time_base, int64_t origin) {
  if (pts == AV_NOPTS_VALUE || time_base.num <= 0 || time_base.den <= 0) {
    return -1;
  }
  return av_rescale_q(pts - origin, time_base, AVRational{1, 1000});
}

template <typename T>
double scan_typed(const uint8_t* data, int count, double scale) {
  const T* samples = reinterpret_cast<const T*>(data);
  double peak = 0;
  for (int i = 0; i < count; ++i) {
    const double value = std::fabs(static_cast<double>(samples[i]) * scale);
    if (value > peak) {
      peak = value;
    }
  }
  return peak;
}

double frame_peak(const AVFrame* frame) {
  const auto format = static_cast<AVSampleFormat>(frame->format);
  const int bytes = av_get_bytes_per_sample(format);
  if (bytes <= 0 || frame->nb_samples <= 0) {
    return 0;
  }
  const int channels = frame->ch_layout.nb_channels;
  if (channels <= 0) {
    return 0;
  }
  const bool planar = av_sample_fmt_is_planar(format) != 0;
  const int planes = planar ? channels : 1;
  double peak = 0;
  for (int plane = 0; plane < planes; ++plane) {
    const uint8_t* data = frame->extended_data[plane];
    if (!data) {
      continue;
    }
    const int count = planar ? frame->nb_samples : frame->nb_samples * channels;
    double value = 0;
    switch (format) {
      case AV_SAMPLE_FMT_U8:
      case AV_SAMPLE_FMT_U8P:
        for (int i = 0; i < count; ++i) {
          const double v = std::fabs((static_cast<int>(data[i]) - 128) / 128.0);
          if (v > value) {
            value = v;
          }
        }
        break;
      case AV_SAMPLE_FMT_S16:
      case AV_SAMPLE_FMT_S16P:
        value = scan_typed<int16_t>(data, count, 1.0 / 32768.0);
        break;
      case AV_SAMPLE_FMT_S32:
      case AV_SAMPLE_FMT_S32P:
        value = scan_typed<int32_t>(data, count, 1.0 / 2147483648.0);
        break;
      case AV_SAMPLE_FMT_FLT:
      case AV_SAMPLE_FMT_FLTP:
        value = scan_typed<float>(data, count, 1.0);
        break;
      case AV_SAMPLE_FMT_DBL:
      case AV_SAMPLE_FMT_DBLP:
        value = scan_typed<double>(data, count, 1.0);
        break;
      default:
        break;
    }
    if (value > peak) {
      peak = value;
    }
  }
  return peak > 1.0 ? 1.0 : peak;
}

}  // namespace

std::string media_index_json(const std::string& uri, int32_t buckets) {
  if (uri.empty()) {
    return index_error("bad_source", "uri is empty");
  }
  if (buckets < 64) {
    buckets = 64;
  } else if (buckets > 4000) {
    buckets = 4000;
  }

  AVFormatContext* format = nullptr;
  int ret = avformat_open_input(&format, uri.c_str(), nullptr, nullptr);
  if (ret < 0 || !format) {
    return index_error("input_open_failed", ffmpeg_error(ret));
  }
  ret = avformat_find_stream_info(format, nullptr);
  if (ret < 0) {
    const std::string message = ffmpeg_error(ret);
    avformat_close_input(&format);
    return index_error("input_open_failed", message);
  }

  const int video_index = av_find_best_stream(
      format, AVMEDIA_TYPE_VIDEO, -1, -1, nullptr, 0);
  const int audio_index = av_find_best_stream(
      format, AVMEDIA_TYPE_AUDIO, -1, -1, nullptr, 0);

  int64_t duration_ms = 0;
  if (format->duration != AV_NOPTS_VALUE) {
    duration_ms = format->duration / (AV_TIME_BASE / 1000);
  }
  if (duration_ms <= 0) {
    for (unsigned i = 0; i < format->nb_streams; ++i) {
      const AVStream* stream = format->streams[i];
      if (stream && stream->duration != AV_NOPTS_VALUE) {
        const int64_t ms =
            av_rescale_q(stream->duration, stream->time_base,
                         AVRational{1, 1000});
        duration_ms = std::max(duration_ms, ms);
      }
    }
  }

  AVStream* video = video_index >= 0 ? format->streams[video_index] : nullptr;
  AVStream* audio = audio_index >= 0 ? format->streams[audio_index] : nullptr;
  const int64_t video_origin =
      video && video->start_time != AV_NOPTS_VALUE ? video->start_time : 0;
  const int64_t audio_origin =
      audio && audio->start_time != AV_NOPTS_VALUE ? audio->start_time : 0;

  std::vector<int> peaks(static_cast<size_t>(buckets), 0);
  std::vector<int64_t> keyframes;

  const AVCodec* decoder = nullptr;
  AVCodecContext* codec = nullptr;
  AVFrame* frame = av_frame_alloc();
  AVPacket* packet = av_packet_alloc();
  if (audio) {
    decoder = avcodec_find_decoder(audio->codecpar->codec_id);
    if (decoder) {
      codec = avcodec_alloc_context3(decoder);
    }
    if (codec && avcodec_parameters_to_context(codec, audio->codecpar) >= 0) {
      codec->pkt_timebase = audio->time_base;
      if (avcodec_open2(codec, decoder, nullptr) < 0) {
        avcodec_free_context(&codec);
      }
    } else if (codec) {
      avcodec_free_context(&codec);
    }
  }

  const bool wave_ok = codec != nullptr;
  int64_t audio_fallback_ms = 0;
  int64_t last_ms = 0;
  const int sample_rate = audio ? audio->codecpar->sample_rate : 0;

  const auto add_peak = [&](int64_t ms, double raw) {
    if (ms < 0) {
      return;
    }
    if (duration_ms > 0) {
      int64_t index = ms * buckets / duration_ms;
      if (index < 0) {
        index = 0;
      }
      if (index >= buckets) {
        index = buckets - 1;
      }
      const int pct = static_cast<int>(std::sqrt(raw) * 100.0);
      if (pct > peaks[static_cast<size_t>(index)]) {
        peaks[static_cast<size_t>(index)] = std::min(pct, 100);
      }
    }
    last_ms = std::max(last_ms, ms);
  };

  while (packet && frame && av_read_frame(format, packet) >= 0) {
    if (video && packet->stream_index == video_index &&
        (packet->flags & AV_PKT_FLAG_KEY) != 0) {
      const int64_t ms =
          pts_to_ms(packet->pts != AV_NOPTS_VALUE ? packet->pts : packet->dts,
                    video->time_base, video_origin);
      if (ms >= 0 &&
          (keyframes.empty() || ms > keyframes.back())) {
        keyframes.push_back(ms);
      }
    } else if (codec && audio && packet->stream_index == audio_index) {
      if (avcodec_send_packet(codec, packet) >= 0) {
        while (avcodec_receive_frame(codec, frame) >= 0) {
          int64_t ms = -1;
          if (frame->best_effort_timestamp != AV_NOPTS_VALUE) {
            ms = pts_to_ms(frame->best_effort_timestamp, audio->time_base,
                           audio_origin);
          }
          if (ms < 0) {
            ms = audio_fallback_ms;
          }
          add_peak(ms, frame_peak(frame));
          if (sample_rate > 0) {
            audio_fallback_ms =
                ms + static_cast<int64_t>(frame->nb_samples) * 1000 /
                         sample_rate;
          }
          av_frame_unref(frame);
        }
      }
    }
    av_packet_unref(packet);
  }

  // 解码器尾帧
  if (codec) {
    avcodec_send_packet(codec, nullptr);
    while (frame && avcodec_receive_frame(codec, frame) >= 0) {
      int64_t ms = -1;
      if (frame->best_effort_timestamp != AV_NOPTS_VALUE) {
        ms = pts_to_ms(frame->best_effort_timestamp, audio->time_base,
                       audio_origin);
      }
      if (ms < 0) {
        ms = audio_fallback_ms;
      }
      add_peak(ms, frame_peak(frame));
      if (sample_rate > 0) {
        audio_fallback_ms =
            ms + static_cast<int64_t>(frame->nb_samples) * 1000 / sample_rate;
      }
      av_frame_unref(frame);
    }
    avcodec_free_context(&codec);
  }
  av_frame_free(&frame);
  av_packet_free(&packet);

  if (duration_ms <= 0) {
    duration_ms = last_ms;
  }
  // 没有音轨时 peaks 全 0, UI 仍可只画关键帧/刻度; 用 audio 字段区分
  int64_t bucket_ms = 0;
  if (duration_ms > 0) {
    bucket_ms = std::max<int64_t>(1, duration_ms / buckets);
  }

  json j;
  j["ok"] = true;
  j["duration_ms"] = duration_ms;
  j["bucket_ms"] = bucket_ms;
  j["has_audio"] = audio != nullptr;
  j["peaks"] = wave_ok ? json(peaks) : json::array();
  j["keyframes_ms"] = keyframes;

  avformat_close_input(&format);
  return j.dump();
}

}  // namespace ak

extern "C" const char* ak_media_index(const char* uri, int32_t buckets) {
  if (!uri || !*uri) {
    return ak::dup_cstr(
        "{\"ok\":false,\"code\":\"bad_source\",\"message\":\"uri is empty\"}");
  }
  return ak::dup_cstr(ak::media_index_json(uri, buckets));
}
