import 'package:avoxkit/core/convert_plan.dart';
import 'package:flutter_test/flutter_test.dart';

SourceMedia media({
  String container = 'mkv',
  String video = 'h264',
  int? width = 1920,
  int? height = 1080,
  String audio = 'aac',
  bool hasVideo = true,
  bool hasAudio = true,
}) =>
    SourceMedia(
      container: container,
      videoCodec: video,
      width: width,
      height: height,
      audioCodec: audio,
      hasVideo: hasVideo,
      hasAudio: hasAudio,
    );

ConversionPlan plan(
  SourceMedia source,
  ConvertSettings settings, {
  bool h264 = true,
  bool h265 = true,
}) =>
    buildConversionPlan(
      source: source,
      settings: settings,
      h264Available: h264,
      h265Available: h265,
      aacAvailable: true,
      mp3Available: true,
    );

void main() {
  group('container only', () {
    test('同容器同编码 → 无需转换', () {
      final p = plan(media(container: 'mp4'), const ConvertSettings());
      expect(p.noop, isTrue);
      expect(p.canSubmit, isFalse);
    });

    test('MKV → MP4 且编码不变 → 直接封装', () {
      final p = plan(media(), const ConvertSettings(container: 'mp4'));
      expect(p.kind, 'remux');
      expect(p.transMode, isNull);
      expect(p.params, {'container': 'mp4'});
      expect(p.detail, contains('视频 H.264 直拷'));
      expect(p.detail, contains('音频 AAC 直拷'));
    });

    test('显式选中同编码同分辨率 → 仍直接封装', () {
      final p = plan(
        media(container: 'mp4'),
        const ConvertSettings(video: 'h264', height: 1080),
      );
      expect(p.noop, isTrue);
    });
  });

  group('video', () {
    test('H.264 → H.265 → 视频转码 + 音频直拷', () {
      final p = plan(
        media(container: 'mp4'),
        const ConvertSettings(video: 'h265'),
      );
      expect(p.kind, 'transcode');
      expect(p.transMode, 'audio_copy');
      expect((p.params['video'] as Map)['codec'], 'hevc');
      expect((p.params['audio'] as Map)['codec'], 'aac');
      expect((p.params['video'] as Map).containsKey('width'), isFalse);
    });

    test('改分辨率 → 用源编码重编并写入偶数宽高', () {
      final p = plan(
        media(container: 'mp4'),
        const ConvertSettings(height: 720),
      );
      expect(p.kind, 'transcode');
      expect(p.transMode, 'audio_copy');
      final video = p.params['video'] as Map;
      expect(video['codec'], 'h264');
      expect(video['width'], 1280);
      expect(video['height'], 720);
    });

    test('目标分辨率等于源 → 不缩放', () {
      final p = plan(
        media(container: 'mkv'),
        const ConvertSettings(container: 'mp4', height: 1080),
      );
      expect(p.kind, 'remux');
    });

    test('源编码无法重编 → 回退 H.264 并提示', () {
      final p = plan(
        media(container: 'mkv', video: 'vp9'),
        const ConvertSettings(container: 'mp4'),
      );
      expect(p.kind, 'transcode');
      expect((p.params['video'] as Map)['codec'], 'h264');
      expect(p.warnings.join(), contains('改用 H.264'));
    });

    test('H.265 编码器不可用 → 回退 H.264', () {
      final p = plan(
        media(container: 'mp4'),
        const ConvertSettings(video: 'h265'),
        h265: false,
      );
      expect(p.kind, 'transcode');
      expect((p.params['video'] as Map)['codec'], 'h264');
      expect(p.warnings.join(), contains('H.265'));
    });

    test('放大分辨率给出提示', () {
      final p = plan(
        media(container: 'mp4', height: 720),
        const ConvertSettings(height: 1080),
      );
      expect(p.warnings.join(), contains('放大'));
    });
  });

  group('audio', () {
    test('只改音频编码 → 视频直拷 + 音频转码', () {
      final p = plan(
        media(container: 'mp4'),
        const ConvertSettings(audio: 'mp3'),
      );
      expect(p.kind, 'transcode');
      expect(p.transMode, 'video_copy');
      expect((p.params['video'] as Map)['codec'], 'h264');
      expect((p.params['audio'] as Map)['codec'], 'mp3');
    });

    test('容器装不下源音频 → 转 AAC 并提示', () {
      final p = plan(
        media(container: 'mkv', audio: 'dts'),
        const ConvertSettings(container: 'mp4'),
      );
      expect(p.kind, 'transcode');
      expect(p.transMode, 'video_copy');
      expect((p.params['audio'] as Map)['codec'], 'aac');
      expect(p.warnings.join(), contains('DTS'));
    });

    test('视频和音频都变 → 全部重编', () {
      final p = plan(
        media(container: 'mp4'),
        const ConvertSettings(video: 'h265', audio: 'mp3'),
      );
      expect(p.kind, 'transcode');
      expect(p.transMode, 'all');
    });

    test('没有视频轨且只换容器 → 仍可封装', () {
      final p = plan(
        media(
          container: 'mkv',
          hasVideo: false,
          video: '',
          width: null,
          height: null,
          audio: 'aac',
        ),
        const ConvertSettings(container: 'mp4'),
      );
      expect(p.kind, 'remux');
    });

    test('没有视频轨且要重编音频 → 提示走提取音频', () {
      final p = plan(
        media(
          container: 'mkv',
          hasVideo: false,
          video: '',
          width: null,
          height: null,
          audio: 'mp3',
        ),
        const ConvertSettings(audio: 'aac'),
      );
      expect(p.error, isNotNull);
      expect(p.error, contains('提取音频'));
    });
  });

  group('container matrix', () {
    test('MP4 不接受 VP9 视频直拷', () {
      expect(containerStoresVideo('mp4', 'vp9'), isFalse);
      expect(containerStoresVideo('mkv', 'vp9'), isTrue);
      expect(containerStoresVideo('webm', 'vp9'), isTrue);
    });

    test('MP4 不接受 DTS 音频直拷', () {
      expect(containerStoresAudio('mp4', 'dts'), isFalse);
      expect(containerStoresAudio('mkv', 'dts'), isTrue);
    });

    test('MP4 保留 HEVC / E-AC-3 时提示 Windows 播放器兼容性', () {
      final p = plan(
        media(container: 'mkv', video: 'hevc', audio: 'eac3'),
        const ConvertSettings(container: 'mp4'),
      );
      expect(p.kind, 'remux');
      expect(p.warnings.join(), contains('H.265'));
      expect(p.warnings.join(), contains('E-AC-3'));
    });

    test('改成 H.264 / AAC 后不再提示播放器兼容性', () {
      final p = plan(
        media(container: 'mkv', video: 'hevc', audio: 'eac3'),
        const ConvertSettings(container: 'mp4', video: 'h264', audio: 'aac'),
      );
      expect(p.kind, 'transcode');
      expect(p.warnings.join(), isNot(contains('H.265')));
      expect(p.warnings.join(), isNot(contains('E-AC-3')));
    });
  });

  test('probe 容器名归一化', () {
    expect(normalizeContainer('a.mkv', 'matroska,webm'), 'mkv');
    expect(normalizeContainer('a.webm', 'matroska,webm'), 'webm');
    expect(normalizeContainer('a.mp4', 'mov,mp4,m4a,3gp,3g2,mj2'), 'mp4');
    expect(normalizeContainer('a.mov', 'mov,mp4,m4a,3gp,3g2,mj2'), 'mov');
  });
}
