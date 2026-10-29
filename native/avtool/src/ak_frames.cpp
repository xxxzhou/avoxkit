// 抓帧: 只读 demux + 视频解码, 按时间 backward seek 到关键帧再向前解一帧。
// 采样缩放直接在 YUV 平面上做, 不落 RGBA 全尺寸中间图; 编码复用 avox 的
// stb JPEG 出口, 返回 base64, 调用方不需要临时文件。
// TODO(avox P2): 这是本仓最后一块直连 libav 的实现; 等 avox grabFrame
// (SurfaceRenderVk 出图) 落地后整体切换, 并从 CMake 摘掉 avformat/avcodec。
#include "ak_internal.hpp"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include <nlohmann/json.hpp>

#include "avox/AvoxImage.h"

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/avutil.h>
#include <libavutil/display.h>
#include <libavutil/error.h>
#include <libavutil/mathematics.h>
#include <libavutil/pixdesc.h>
}

namespace ak {
namespace {

using nlohmann::json;

struct Request {
  int32_t count = 12;
  int32_t width = 320;
  int32_t quality = 75;
  std::vector<int64_t> times;
};

std::string frames_error(const std::string& code, const std::string& message) {
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

int32_t clamped(int32_t value, int32_t lo, int32_t hi) {
  return value < lo ? lo : (value > hi ? hi : value);
}

Request parse_request(const std::string& text) {
  Request request;
  if (text.empty()) {
    return request;
  }
  const json j = json::parse(text, nullptr, false);
  if (!j.is_object()) {
    return request;
  }
  if (j.contains("count") && j["count"].is_number()) {
    request.count = clamped(j["count"].get<int32_t>(), 1, 48);
  }
  if (j.contains("width") && j["width"].is_number()) {
    request.width = clamped(j["width"].get<int32_t>(), 48, 1280);
  }
  if (j.contains("quality") && j["quality"].is_number()) {
    request.quality = clamped(j["quality"].get<int32_t>(), 30, 95);
  }
  if (j.contains("times_ms") && j["times_ms"].is_array()) {
    for (const auto& item : j["times_ms"]) {
      if (!item.is_number() || request.times.size() >= 64) {
        break;
      }
      request.times.push_back(std::max<int64_t>(0, item.get<int64_t>()));
    }
  }
  return request;
}

int64_t pts_to_ms(int64_t pts, AVRational time_base, int64_t origin) {
  if (pts == AV_NOPTS_VALUE || time_base.num <= 0 || time_base.den <= 0) {
    return -1;
  }
  return av_rescale_q(pts - origin, time_base, AVRational{1, 1000});
}

// 手机竖拍常见: 编码分辨率是横的, 靠 display matrix 声明播放时要转
int rotation_degrees(const AVStream* stream) {
  if (!stream || !stream->codecpar) {
    return 0;
  }
  const AVPacketSideData* side = av_packet_side_data_get(
      stream->codecpar->coded_side_data, stream->codecpar->nb_coded_side_data,
      AV_PKT_DATA_DISPLAYMATRIX);
  if (!side || side->size < 9 * sizeof(int32_t)) {
    return 0;
  }
  // ffmpeg 里 theta = -get(); theta=90 对应 transpose=clock
  const double theta =
      -av_display_rotation_get(reinterpret_cast<const int32_t*>(side->data));
  if (std::isnan(theta)) {
    return 0;
  }
  int degrees = static_cast<int>(std::lround(theta / 90.0)) * 90;
  degrees %= 360;
  if (degrees < 0) {
    degrees += 360;
  }
  return degrees;
}

struct Matrix {
  float rv;
  float gu;
  float gv;
  float bu;
};

Matrix matrix_for(AVColorSpace space, int src_height) {
  if (space == AVCOL_SPC_BT709) {
    return {1.5748f, -0.1873f, -0.4681f, 1.8556f};
  }
  if (space == AVCOL_SPC_BT2020_NCL || space == AVCOL_SPC_BT2020_CL) {
    return {1.4746f, -0.164553f, -0.571353f, 1.8814f};
  }
  if (space == AVCOL_SPC_BT470BG || space == AVCOL_SPC_SMPTE170M) {
    return {1.402f, -0.344136f, -0.714136f, 1.772f};
  }
  // 没标矩阵时按分辨率猜: >576 行基本是 HD 以上
  return src_height > 576 ? Matrix{1.5748f, -0.1873f, -0.4681f, 1.8556f}
                          : Matrix{1.402f, -0.344136f, -0.714136f, 1.772f};
}

// 按像素描述符取分量: 8bit 直读, >8bit 读 16 位容器再落到 8bit
inline int read_component(const AVFrame* frame,
                          const AVComponentDescriptor& comp, int x, int y) {
  const uint8_t* p = frame->data[comp.plane] +
                     static_cast<size_t>(y) * frame->linesize[comp.plane] +
                     static_cast<size_t>(x) * comp.step + comp.offset;
  if (comp.depth <= 8) {
    return *p;
  }
  int value = *reinterpret_cast<const uint16_t*>(p) >> comp.shift;
  return value >> (comp.depth - 8);
}

struct Sampler {
  const AVFrame* frame = nullptr;
  const AVPixFmtDescriptor* desc = nullptr;
  Matrix matrix{};
  bool limited = true;
  int src_w = 0;
  int src_h = 0;
  int chroma_w = 0;
  int chroma_h = 0;

  float luma(float sx, float sy) const {
    sx = std::min(std::max(sx, 0.0f), static_cast<float>(src_w - 1));
    sy = std::min(std::max(sy, 0.0f), static_cast<float>(src_h - 1));
    const int x0 = static_cast<int>(sx);
    const int y0 = static_cast<int>(sy);
    const int x1 = std::min(x0 + 1, src_w - 1);
    const int y1 = std::min(y0 + 1, src_h - 1);
    const float fx = sx - x0;
    const float fy = sy - y0;
    const auto& comp = desc->comp[0];
    const float a = read_component(frame, comp, x0, y0);
    const float b = read_component(frame, comp, x1, y0);
    const float c = read_component(frame, comp, x0, y1);
    const float d = read_component(frame, comp, x1, y1);
    return (a + (b - a) * fx) * (1.0f - fy) + (c + (d - c) * fx) * fy;
  }

  int chroma_index(float value, int limit) const {
    const int index = static_cast<int>(value) >> desc->log2_chroma_w;
    return std::min(std::max(index, 0), limit - 1);
  }
};

bool frame_to_rgba(const AVFrame* frame, int rotation, int out_width,
                   std::vector<uint8_t>* rgba, int* out_height) {
  if (!frame || !frame->data[0] || frame->width <= 0 || frame->height <= 0) {
    return false;
  }
  const AVPixFmtDescriptor* desc = av_pix_fmt_desc_get(
      static_cast<AVPixelFormat>(frame->format));
  if (!desc || desc->nb_components < 1 || (desc->flags & AV_PIX_FMT_FLAG_RGB)) {
    return false;
  }
  const bool has_chroma = desc->nb_components >= 3;
  const int swap = (rotation == 90 || rotation == 270) ? 1 : 0;
  const int disp_w = swap ? frame->height : frame->width;
  const int disp_h = swap ? frame->width : frame->height;

  out_width = clamped(out_width, 48, 1280);
  const int height = std::max(
      1, static_cast<int>(std::lround(static_cast<double>(out_width) * disp_h /
                                      disp_w)));
  rgba->resize(static_cast<size_t>(out_width) * height * 4);

  Sampler sampler;
  sampler.frame = frame;
  sampler.desc = desc;
  sampler.src_w = frame->width;
  sampler.src_h = frame->height;
  sampler.chroma_w = std::max(1, (frame->width + 1) >> desc->log2_chroma_w);
  sampler.chroma_h = std::max(1, (frame->height + 1) >> desc->log2_chroma_h);
  sampler.matrix = matrix_for(frame->colorspace, frame->height);
  sampler.limited = frame->color_range != AVCOL_RANGE_JPEG;
  const float y_scale = sampler.limited ? 255.0f / 219.0f : 1.0f;
  const float y_offset = sampler.limited ? -16.0f : 0.0f;
  const float c_scale = sampler.limited ? 255.0f / 224.0f : 1.0f;

  const auto& comp_u = desc->comp[1];
  const auto& comp_v = desc->comp[2];
  for (int y = 0; y < height; ++y) {
    const float v = (y + 0.5f) / height;
    for (int x = 0; x < out_width; ++x) {
      const float u = (x + 0.5f) / out_width;
      float sx = u * frame->width;
      float sy = v * frame->height;
      switch (rotation) {
        case 90:
          sx = v * frame->width;
          sy = (1.0f - u) * frame->height;
          break;
        case 180:
          sx = (1.0f - u) * frame->width;
          sy = (1.0f - v) * frame->height;
          break;
        case 270:
          sx = (1.0f - v) * frame->width;
          sy = u * frame->height;
          break;
        default:
          break;
      }
      const float y8 = (sampler.luma(sx, sy) + y_offset) * y_scale;
      float u8 = 0.0f;
      float v8 = 0.0f;
      if (has_chroma) {
        const int cx = sampler.chroma_index(sx, sampler.chroma_w);
        const int cy = sampler.chroma_index(sy, sampler.chroma_h);
        u8 = (read_component(frame, comp_u, cx, cy) - 128.0f) * c_scale;
        v8 = (read_component(frame, comp_v, cx, cy) - 128.0f) * c_scale;
      }
      const float r = y8 + sampler.matrix.rv * v8;
      const float g = y8 + sampler.matrix.gu * u8 + sampler.matrix.gv * v8;
      const float b = y8 + sampler.matrix.bu * u8;
      uint8_t* p = rgba->data() + (static_cast<size_t>(y) * out_width + x) * 4;
      p[0] = static_cast<uint8_t>(std::min(255.0f, std::max(0.0f, r + 0.5f)));
      p[1] = static_cast<uint8_t>(std::min(255.0f, std::max(0.0f, g + 0.5f)));
      p[2] = static_cast<uint8_t>(std::min(255.0f, std::max(0.0f, b + 0.5f)));
      p[3] = 255;
    }
  }
  *out_height = height;
  return true;
}

bool encode_jpeg_base64(const std::vector<uint8_t>& rgba, int width, int height,
                        int quality, std::string* out) {
  std::unique_ptr<avox::IImageBuffer> buffer(avox::createImageBuffer());
  if (!buffer) {
    return false;
  }
  avox::ImageFormat format;
  format.width = width;
  format.height = height;
  format.imageType = avox::ImageType::rgba8;
  buffer->setImageFormat(format);
  if (rgba.size() != static_cast<size_t>(width) * height * 4 ||
      !buffer->getPointer()) {
    return false;
  }
  std::memcpy(buffer->getPointer(), rgba.data(), rgba.size());
  avox::IEncodeConfig config;
  config.encodeType = avox::IEncodeType::jpg;
  config.quality = quality;
  // avox 的 getImageBase64 用进程级 static 缓冲; 缩略图和精确帧会在两个
  // isolate 里并发编码, 取串和拷贝都必须在锁内, 否则会读到半截 base64。
  static std::mutex encode_mutex;
  {
    std::lock_guard<std::mutex> lock(encode_mutex);
    const char* base64 = avox::getImageBase64(buffer.get(), config);
    if (!base64) {
      return false;
    }
    out->assign(base64);
  }
  return true;
}

int find_video_stream(const AVFormatContext* format) {
  int best = -1;
  for (unsigned i = 0; i < format->nb_streams; ++i) {
    const AVStream* stream = format->streams[i];
    if (!stream || !stream->codecpar ||
        stream->codecpar->codec_type != AVMEDIA_TYPE_VIDEO) {
      continue;
    }
    // 音频文件封面也是 video 轨, 不能拿来当画面
    if ((stream->disposition & AV_DISPOSITION_ATTACHED_PIC) != 0) {
      continue;
    }
    if (stream->codecpar->width <= 0 || stream->codecpar->height <= 0) {
      continue;
    }
    if (best < 0) {
      best = static_cast<int>(i);
    }
  }
  return best;
}

}  // namespace

std::string media_frames_json(const std::string& uri,
                              const std::string& request_text) {
  if (uri.empty()) {
    return frames_error("bad_source", "uri is empty");
  }
  const Request request = parse_request(request_text);

  AVFormatContext* format = nullptr;
  int ret = avformat_open_input(&format, uri.c_str(), nullptr, nullptr);
  if (ret < 0 || !format) {
    return frames_error("input_open_failed", ffmpeg_error(ret));
  }
  ret = avformat_find_stream_info(format, nullptr);
  if (ret < 0) {
    const std::string message = ffmpeg_error(ret);
    avformat_close_input(&format);
    return frames_error("input_open_failed", message);
  }

  json result;
  result["ok"] = true;
  int64_t duration_ms = 0;
  if (format->duration != AV_NOPTS_VALUE) {
    duration_ms = format->duration / (AV_TIME_BASE / 1000);
  }
  result["duration_ms"] = duration_ms;

  const int video_index = find_video_stream(format);
  if (video_index < 0) {
    result["has_video"] = false;
    result["frames"] = json::array();
    result["width"] = 0;
    result["height"] = 0;
    avformat_close_input(&format);
    return result.dump();
  }
  result["has_video"] = true;

  AVStream* stream = format->streams[video_index];
  const AVCodec* decoder = avcodec_find_decoder(stream->codecpar->codec_id);
  AVCodecContext* codec = decoder ? avcodec_alloc_context3(decoder) : nullptr;
  if (!codec || avcodec_parameters_to_context(codec, stream->codecpar) < 0 ||
      avcodec_open2(codec, decoder, nullptr) < 0) {
    if (codec) {
      avcodec_free_context(&codec);
    }
    avformat_close_input(&format);
    return frames_error("decode_failed", "no decoder for this video stream");
  }
  codec->pkt_timebase = stream->time_base;

  const int rotation = rotation_degrees(stream);
  const int64_t origin =
      stream->start_time != AV_NOPTS_VALUE ? stream->start_time : 0;

  std::vector<int64_t> targets = request.times;
  if (targets.empty()) {
    const int64_t span = std::max<int64_t>(1, duration_ms);
    for (int32_t i = 0; i < request.count; ++i) {
      // 每格取中点, 缩略图条首尾都能代表自己的时间段
      targets.push_back(span * (2 * i + 1) / (2 * request.count));
    }
  }

  AVPacket* packet = av_packet_alloc();
  AVFrame* frame = av_frame_alloc();
  AVFrame* chosen = av_frame_alloc();
  std::vector<uint8_t> rgba;
  json frames = json::array();
  int out_width = 0;
  int out_height = 0;
  std::string failed_code;
  std::string failed_message;

  for (size_t index = 0; index < targets.size(); ++index) {
    int64_t target_ms = std::max<int64_t>(0, targets[index]);
    if (duration_ms > 0) {
      target_ms = std::min(target_ms, duration_ms - 1);
    }
    const int64_t target_ts =
        origin + av_rescale_q(target_ms, AVRational{1, 1000}, stream->time_base);
    const int seek_ret =
        av_seek_frame(format, video_index, target_ts, AVSEEK_FLAG_BACKWARD);
    if (seek_ret < 0 && index > 0) {
      continue;
    }
    avcodec_flush_buffers(codec);
    av_frame_unref(chosen);

    const int64_t started = now_ms();
    int decoded = 0;
    bool got = false;
    int64_t chosen_ms = target_ms;
    while (!got && decoded < 600 && now_ms() - started < 4000) {
      const int read_ret = av_read_frame(format, packet);
      if (read_ret < 0) {
        break;
      }
      if (packet->stream_index != video_index) {
        av_packet_unref(packet);
        continue;
      }
      if (avcodec_send_packet(codec, packet) < 0) {
        av_packet_unref(packet);
        continue;
      }
      av_packet_unref(packet);
      while (avcodec_receive_frame(codec, frame) >= 0) {
        ++decoded;
        const int64_t pts = frame->best_effort_timestamp != AV_NOPTS_VALUE
                                ? frame->best_effort_timestamp
                                : frame->pts;
        int64_t ms = pts_to_ms(pts, stream->time_base, origin);
        if (ms < 0) {
          ms = target_ms;
        }
        av_frame_unref(chosen);
        av_frame_ref(chosen, frame);
        chosen_ms = ms;
        if (ms >= target_ms) {
          got = true;
        }
        av_frame_unref(frame);
        if (got) {
          break;
        }
      }
    }
    if (!chosen->data[0]) {
      continue;
    }
    int height = 0;
    if (!frame_to_rgba(chosen, rotation, request.width, &rgba, &height)) {
      failed_code = "unsupported_pix_fmt";
      const char* name = av_get_pix_fmt_name(
          static_cast<AVPixelFormat>(chosen->format));
      failed_message = name ? name : "unknown";
      continue;
    }
    std::string base64;
    if (!encode_jpeg_base64(rgba, request.width, height, request.quality,
                            &base64)) {
      failed_code = "encode_failed";
      failed_message = "jpeg encode failed";
      continue;
    }
    out_width = request.width;
    out_height = height;
    frames.push_back({{"ms", chosen_ms}, {"image", std::move(base64)}});
  }

  av_frame_free(&frame);
  av_frame_free(&chosen);
  av_packet_free(&packet);
  avcodec_free_context(&codec);
  avformat_close_input(&format);

  result["width"] = out_width;
  result["height"] = out_height;
  result["frames"] = std::move(frames);
  if (result["frames"].empty() && !failed_code.empty()) {
    result["reason"] = failed_code;
    result["message"] = failed_message;
  }
  return result.dump();
}

}  // namespace ak

extern "C" const char* ak_media_frames(const char* uri,
                                       const char* request_json) {
  if (!uri || !*uri) {
    return ak::dup_cstr(
        "{\"ok\":false,\"code\":\"bad_source\",\"message\":\"uri is empty\"}");
  }
  return ak::dup_cstr(ak::media_frames_json(uri, request_json ? request_json : ""));
}
