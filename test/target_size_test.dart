import 'package:avoxkit/core/convert_plan.dart';
import 'package:flutter_test/flutter_test.dart';

SourceMedia media({int durationMs = 60000}) =>
    SourceMedia(
      container: 'mp4',
      videoCodec: 'h264',
      width: 1920,
      height: 1080,
      audioCodec: 'aac',
      hasVideo: true,
      hasAudio: true,
      durationMs: durationMs,
    );

ConversionPlan plan(SourceMedia source, ConvertSettings settings) =>
    buildConversionPlan(
      source: source,
      settings: settings,
      h264Available: true,
      h265Available: true,
      aacAvailable: true,
      mp3Available: true,
    );

void main() {
  group('videoBitrateForTarget', () {
    test('25MB / 60s / 128kbps 音频 → 预留开销后约 3297 kbps', () {
      expect(
        videoBitrateForTarget(
          targetSizeMb: 25,
          durationMs: 60000,
          audioKbps: 128,
        ),
        3297,
      );
    });

    test('时长未知或目标非法 → 0', () {
      expect(
        videoBitrateForTarget(
          targetSizeMb: 25,
          durationMs: 0,
          audioKbps: 128,
        ),
        0,
      );
      expect(
        videoBitrateForTarget(
          targetSizeMb: 0,
          durationMs: 60000,
          audioKbps: 128,
        ),
        0,
      );
    });
  });

  group('buildConversionPlan 目标体积', () {
    test('设置即同源也强制重编, 视频 vbr + 算出码率, 音频确定码率', () {
      final p = plan(media(), const ConvertSettings(targetSizeMb: 25));
      expect(p.kind, 'transcode');
      expect(p.videoMode, 'encode');
      expect(p.audioMode, 'encode');
      expect(p.params['video'], {
        'codec': 'h264',
        'hardware': 'off',
        'rate_mode': 'vbr',
        'bitrate_kbps': 3297,
      });
      expect(p.params['audio'], {'codec': 'aac', 'bitrate_kbps': 128});
      expect(p.params['target_size_bytes'], 25 * 1024 * 1024);
      expect(
        p.warnings.join(),
        contains('目标体积模式下音频转码为'),
      );
    });

    test('时长读不到 → 报错不产生任务', () {
      final p = plan(
        media(durationMs: 0),
        const ConvertSettings(targetSizeMb: 25),
      );
      expect(p.error, isNotNull);
      expect(p.canSubmit, isFalse);
    });

    test('目标太小 → 报错', () {
      final p = plan(
        media(durationMs: 3600000),
        const ConvertSettings(targetSizeMb: 1),
      );
      expect(p.error, isNotNull);
      expect(p.error, contains('目标体积太小'));
    });

    test('纯音频文件 → 报错引导用提取音频', () {
      final source = SourceMedia(
        container: 'mp4',
        videoCodec: '',
        width: null,
        height: null,
        audioCodec: 'aac',
        hasVideo: false,
        hasAudio: true,
        durationMs: 60000,
      );
      final p = plan(source, const ConvertSettings(targetSizeMb: 25));
      expect(p.error, contains('提取音频'));
    });

    test('用户音频码率生效; toJson/fromJson 带目标体积', () {
      final p = plan(
        media(),
        const ConvertSettings(targetSizeMb: 25, audioBitrateKbps: 96),
      );
      expect(p.params['audio'], {'codec': 'aac', 'bitrate_kbps': 96});
      expect(
        videoBitrateForTarget(
          targetSizeMb: 25,
          durationMs: 60000,
          audioKbps: 96,
        ),
        videoBitrateForTarget(
          targetSizeMb: 25,
          durationMs: 60000,
          audioKbps: 96,
        ),
      );

      const settings = ConvertSettings(targetSizeMb: 25);
      final restored = ConvertSettings.fromJson(settings.toJson());
      expect(restored.targetSizeMb, 25);
    });
  });
}
