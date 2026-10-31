/* avoxkit ffmpeg kit 链接/运行时自检: 静态链一遍, 再确认关键组件已注册。 */
#include <stdio.h>
#include <string.h>

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/avutil.h>

static int failed = 0;

static void check(int ok, const char *what) {
  printf("%s %s\n", ok ? "ok  " : "FAIL", what);
  if (!ok) failed = 1;
}

static void check_encoder(const char *name) {
  char label[96];
  snprintf(label, sizeof(label), "encoder %s", name);
  check(avcodec_find_encoder_by_name(name) != NULL, label);
}

static void check_decoder(const char *name) {
  char label[96];
  snprintf(label, sizeof(label), "decoder %s", name);
  check(avcodec_find_decoder_by_name(name) != NULL, label);
}

static void check_muxer(const char *name) {
  char label[96];
  snprintf(label, sizeof(label), "muxer %s", name);
  check(av_guess_format(name, NULL, NULL) != NULL, label);
}

int main(void) {
  printf("av_version %s\n", av_version_info());
  check(strstr(avcodec_configuration(), "--enable-libmp3lame") != NULL,
        "config --enable-libmp3lame");
  check(strstr(avcodec_configuration(), "--disable-gpl") != NULL,
        "config --disable-gpl");
  check(strstr(avcodec_configuration(), "--enable-gpl") == NULL,
        "config no --enable-gpl");

  check_encoder("libmp3lame");
  check(avcodec_find_encoder_by_name("libx264") == NULL, "no libx264");
  check(avcodec_find_encoder_by_name("libx265") == NULL, "no libx265");
  check_encoder("h264_videotoolbox");
  check_encoder("hevc_videotoolbox");
  check_encoder("mjpeg");
  check_encoder("png");

  check_decoder("h264");
  check_decoder("hevc");
  check_decoder("aac");
  check_decoder("mp3");
  check_decoder("targa");

  check_muxer("mp4");
  check_muxer("matroska");
  check_muxer("mp3");
  check_muxer("wav");
  check_muxer("ipod");

  return failed;
}
