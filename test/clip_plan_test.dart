import 'package:avoxkit/core/clip_plan.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('时间文本', () {
    test('格式化', () {
      expect(formatTimestamp(0), '00:00.000');
      expect(formatTimestamp(61234), '01:01.234');
      expect(formatTimestamp(3723004), '1:02:03.004');
      expect(formatTimestamp(65000, withMillis: false), '01:05');
      expect(formatTimestamp(0, forceHours: true), '0:00:00.000');
    });

    test('解析常见写法', () {
      expect(parseTimestamp('83.5'), 83500);
      expect(parseTimestamp('01:23.5'), 83500);
      expect(parseTimestamp('1:02:03.004'), 3723004);
      expect(parseTimestamp(' 00:01:23,500 '), 83500);
      expect(parseTimestamp(''), isNull);
      expect(parseTimestamp('abc'), isNull);
      expect(parseTimestamp('1:2:3:4'), isNull);
      expect(parseTimestamp('-1'), isNull);
    });
  });

  group('片段时长', () {
    test('人话', () {
      expect(prettyClipDuration(500), '500 毫秒');
      expect(prettyClipDuration(6000), '6.0 秒');
      expect(prettyClipDuration(15000), '15 秒');
      expect(prettyClipDuration(65000), '1 分 05 秒');
      expect(prettyClipDuration(3600000), '1 小时');
    });
  });

  group('关键帧吸附', () {
    const keys = [0, 2000, 4000, 6000];
    test('吸到目标前最近关键帧', () {
      expect(snapClipStart(3900, keys), 2000);
      expect(snapClipStart(4000, keys), 4000);
      expect(snapClipStart(5999, keys), 4000);
    });

    test('没有关键帧或早于首帧时原样返回', () {
      expect(snapClipStart(3900, const []), 3900);
      expect(snapClipStart(0, const [100, 200]), 0);
    });
  });

  group('截取区间', () {
    test('正常区间', () {
      final plan = buildClipPlan(
        sourceDurationMs: 30000,
        startMs: 10000,
        endMs: 16000,
      );
      expect(plan.ok, isTrue);
      expect(plan.durationMs, 6000);
      expect(plan.warnings, isEmpty);
    });

    test('结束点超出片长按片尾处理', () {
      final plan = buildClipPlan(
        sourceDurationMs: 30000,
        startMs: 20000,
        endMs: 40000,
      );
      expect(plan.ok, isTrue);
      expect(plan.endMs, 30000);
      expect(plan.warnings, isNotEmpty);
    });

    test('太短和反向区间都拒绝', () {
      expect(
        buildClipPlan(
          sourceDurationMs: 30000,
          startMs: 1000,
          endMs: 1050,
        ).error,
        contains('太短'),
      );
      expect(
        buildClipPlan(
          sourceDurationMs: 30000,
          startMs: 5000,
          endMs: 4000,
        ).error,
        contains('早于'),
      );
    });

    test('还没读到片长', () {
      final plan = buildClipPlan(sourceDurationMs: 0, startMs: 0, endMs: 0);
      expect(plan.ok, isFalse);
      expect(plan.error, contains('读取'));
    });

    test('起点超过片长 90% 拒绝', () {
      final plan = buildClipPlan(
        sourceDurationMs: 30000,
        startMs: 28000,
        endMs: 30000,
      );
      expect(plan.ok, isFalse);
      expect(plan.error, contains('90%'));
      // 90% 整仍允许
      expect(
        buildClipPlan(sourceDurationMs: 30000, startMs: 27000, endMs: 30000).ok,
        isTrue,
      );
    });

    test('任务参数与引擎约定一致', () {
      final plan = buildClipPlan(
        sourceDurationMs: 30000,
        startMs: 10000,
        endMs: 16000,
      );
      final params = plan.params(
        container: 'mp4',
        videoCodec: 'h264',
        quality: 60,
      );
      expect(params['trim'], {'start_ms': 10000, 'end_ms': 16000});
      expect(params['container'], 'mp4');
      expect(params['video']['codec'], 'h264');
      expect(params['video']['hardware'], 'off');
      expect(params['audio']['codec'], 'aac');
      expect(
        plan.params(
          container: 'mkv',
          videoCodec: 'hevc',
          quality: 60,
          hasAudio: false,
        )['audio']['codec'],
        'none',
      );
    });
  });
}
