// 录屏收尾/工程导出小件: 全部走 avox 公共接口, 不再直连 libav。
// 混音/封装 = avox IMediaComposer; 探测 = IMediaReader; 原子替换 = 平台 API。
#include "ak_media_audio.hpp"

#include <filesystem>
#include <memory>
#include <system_error>
#include <vector>

#include "ak_reader.hpp"
#include "avox/AvoxCapture.h"
#include "avox/AvoxMedia.h"

#ifdef _WIN32
#include <windows.h>
#endif

namespace ak {
namespace {

std::unique_ptr<avox::IMediaComposer> makeComposer() {
  return std::unique_ptr<avox::IMediaComposer>(avox::createMediaComposer());
}

}  // namespace

bool probe_media(const std::string& path, MediaProbe* out) {
  if (!out) {
    return false;
  }
  *out = {};
  std::unique_ptr<avox::IMediaReader> reader(avox::createMediaReader());
  if (!reader) {
    out->error = "media reader unavailable";
    return false;
  }
  ReaderShim shim;
  if (!openReader(*reader, shim, path.c_str())) {
    out->error =
        shim.errorMessage.empty() ? "open failed" : shim.errorMessage;
    return false;
  }
  avox::ISourceInfo* info = reader->getSourceInfo();
  out->durationMs = info ? info->durationMs() : 0;
  if (info && info->videoSize() > 0) {
    const avox::VTrackDesc desc = info->getVideoDesc(0);
    out->width = desc.desc.width;
    out->height = desc.desc.height;
    out->fps = desc.desc.fps;
  }
  reader->close();
  out->ok = out->durationMs > 0;
  if (!out->ok) {
    out->error = "duration unknown";
  }
  return out->ok;
}

MixResult mix_wavs_to_aac(const std::vector<AudioTrackSpec>& tracks,
                          int64_t videoPts0Ms, int64_t startMs, int64_t endMs,
                          const std::string& outPath) {
  MixResult result;
  result.path = outPath;
  std::unique_ptr<avox::IMediaComposer> composer = makeComposer();
  if (!composer) {
    result.error = "media composer unavailable";
    return result;
  }
  composer->reset();
  for (const auto& track : tracks) {
    composer->addAudioTrack(track.path.empty() ? nullptr : track.path.c_str(),
                            track.startMs, (float)track.gainDb, track.mute);
  }
  const avox::MediaMixStatus status =
      composer->mixAudio(videoPts0Ms, startMs, endMs, outPath.c_str());
  switch (status) {
    case avox::MediaMixStatus::ok:
      result.ok = true;
      result.durationMs = endMs > startMs ? endMs - startMs : 0;
      break;
    case avox::MediaMixStatus::noAudio:
      result.ok = true;
      result.no_audio = true;
      break;
    default:
      result.error = composer->getLastError();
      break;
  }
  return result;
}

RemuxResult remux_streams(const std::string& videoPath,
                          const std::string& audioPath,
                          const std::string& outPath) {
  RemuxResult result;
  std::unique_ptr<avox::IMediaComposer> composer = makeComposer();
  if (!composer) {
    result.error = "media composer unavailable";
    return result;
  }
  composer->reset();
  result.ok =
      composer->remux(videoPath.c_str(),
                      audioPath.empty() ? nullptr : audioPath.c_str(),
                      outPath.c_str());
  if (!result.ok) {
    result.error = composer->getLastError();
  }
  return result;
}

bool replace_file(const std::string& from, const std::string& to,
                  std::string* error) {
#ifdef _WIN32
  std::wstring wfrom;
  std::wstring wto;
  const int nf = MultiByteToWideChar(CP_UTF8, 0, from.c_str(), -1, nullptr, 0);
  const int nt = MultiByteToWideChar(CP_UTF8, 0, to.c_str(), -1, nullptr, 0);
  if (nf > 0 && nt > 0) {
    wfrom.resize(nf);
    wto.resize(nt);
    MultiByteToWideChar(CP_UTF8, 0, from.c_str(), -1, wfrom.data(), nf);
    MultiByteToWideChar(CP_UTF8, 0, to.c_str(), -1, wto.data(), nt);
    if (MoveFileExW(wfrom.c_str(), wto.c_str(),
                    MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH |
                        MOVEFILE_COPY_ALLOWED)) {
      return true;
    }
    if (error) {
      *error = "MoveFileEx failed";
    }
    return false;
  }
#endif
  std::error_code ec;
  std::filesystem::rename(from, to, ec);
  if (ec) {
    if (error) {
      *error = ec.message();
    }
    return false;
  }
  return true;
}

}  // namespace ak
