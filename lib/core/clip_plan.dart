/// 片段截取的纯逻辑: 时间文本、关键帧吸附、区间校验与任务参数。
/// 与 UI/引擎解耦, 单测直接覆盖。
library;

/// 最短片段; 引擎侧是 40ms, UI 留出两帧余量
const int kMinClipMs = 100;

/// 引擎用 io.startFrac 定位, 上限 90%; 起点超过它会被静默拉回, 产物开头多一截。
const int kClipStartLimitPercent = 90;

int clipStartLimitMs(int sourceDurationMs) =>
    sourceDurationMs * kClipStartLimitPercent ~/ 100;

String formatTimestamp(
  int ms, {
  bool withMillis = true,
  bool forceHours = false,
}) {
  var value = ms < 0 ? 0 : ms;
  final hours = value ~/ 3600000;
  value -= hours * 3600000;
  final minutes = value ~/ 60000;
  value -= minutes * 60000;
  final seconds = value ~/ 1000;
  final millis = value - seconds * 1000;
  final tail = withMillis ? '.${millis.toString().padLeft(3, '0')}' : '';
  if (hours > 0 || forceHours) {
    return '$hours:${minutes.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')}$tail';
  }
  return '${minutes.toString().padLeft(2, '0')}:'
      '${seconds.toString().padLeft(2, '0')}$tail';
}

/// 接受 `hh:mm:ss.mmm` / `mm:ss` / `ss.mmm`; 逗号也当小数点(SRT 习惯)。
int? parseTimestamp(String text) {
  final raw = text.trim().replaceAll(',', '.');
  if (raw.isEmpty) {
    return null;
  }
  final parts = raw.split(':');
  if (parts.length > 3) {
    return null;
  }
  var total = 0.0;
  for (final part in parts) {
    final value = double.tryParse(part.trim());
    if (value == null || value.isNaN || value.isInfinite || value < 0) {
      return null;
    }
    total = total * 60 + value;
  }
  return (total * 1000).round();
}

/// 片段时长的人话: 6.0 秒 / 1 分 05 秒 / 1 小时 02 分
String prettyClipDuration(int ms) {
  if (ms < 1000) {
    return '$ms 毫秒';
  }
  if (ms < 60000) {
    final seconds = ms / 1000;
    return '${seconds.toStringAsFixed(seconds >= 10 ? 0 : 1)} 秒';
  }
  final minutes = ms ~/ 60000;
  final seconds = (ms % 60000) ~/ 1000;
  if (minutes < 60) {
    return seconds == 0
        ? '$minutes 分'
        : '$minutes 分 ${seconds.toString().padLeft(2, '0')} 秒';
  }
  final hours = minutes ~/ 60;
  final rest = minutes % 60;
  return rest == 0
      ? '$hours 小时'
      : '$hours 小时 ${rest.toString().padLeft(2, '0')} 分';
}

/// 起点吸附到目标前最近关键帧; 没有关键帧时原样返回。
/// 截取的起点由引擎按 io.startFrac 定位, 只能落在关键帧上, 先吸附能让
/// 界面显示的时间就是产物的真实起点。
int snapClipStart(int ms, List<int> keyframesMs) {
  if (keyframesMs.isEmpty || keyframesMs.first > ms) {
    return ms;
  }
  var best = keyframesMs.first;
  for (final keyframe in keyframesMs) {
    if (keyframe <= ms) {
      best = keyframe;
    } else {
      break;
    }
  }
  return best;
}

class ClipPlan {
  const ClipPlan({
    required this.startMs,
    required this.endMs,
    required this.sourceDurationMs,
    this.error,
    this.warnings = const [],
  });

  final int startMs;
  final int endMs;
  final int sourceDurationMs;
  final String? error;
  final List<String> warnings;

  bool get ok => error == null;
  int get durationMs => endMs - startMs;

  Map<String, dynamic> params({
    required String container,
    required String videoCodec,
    required int quality,
    bool hasAudio = true,
    bool overwrite = false,
  }) {
    return {
      'overwrite': overwrite,
      'container': container,
      'video': {
        'codec': videoCodec,
        'hardware': 'off',
        'rate_mode': 'quality',
        'quality': quality,
      },
      'audio': {'codec': hasAudio ? 'aac' : 'none', 'bitrate_kbps': -1},
      'trim': {'start_ms': startMs, 'end_ms': endMs},
    };
  }
}

ClipPlan buildClipPlan({
  required int sourceDurationMs,
  required int startMs,
  required int endMs,
}) {
  if (sourceDurationMs <= 0) {
    return const ClipPlan(
      startMs: 0,
      endMs: 0,
      sourceDurationMs: 0,
      error: '还在读取媒体信息',
    );
  }
  final start = startMs.clamp(0, sourceDurationMs);
  final end = endMs.clamp(start, sourceDurationMs);
  final warnings = <String>[];
  if (endMs > sourceDurationMs) {
    warnings.add('结束点超出片长，已按片尾处理');
  }
  if (startMs < 0) {
    warnings.add('开始点不能小于 0');
  }
  if (end - start < kMinClipMs) {
    return ClipPlan(
      startMs: start,
      endMs: end,
      sourceDurationMs: sourceDurationMs,
      error: end - start <= 0 ? '开始点必须早于结束点' : '片段太短，至少 0.1 秒',
      warnings: warnings,
    );
  }
  if (start > clipStartLimitMs(sourceDurationMs)) {
    return ClipPlan(
      startMs: start,
      endMs: end,
      sourceDurationMs: sourceDurationMs,
      error:
          '起点不能超过片长的 $kClipStartLimitPercent%（当前引擎限制），'
          '请把开始点提前',
      warnings: warnings,
    );
  }
  return ClipPlan(
    startMs: start,
    endMs: end,
    sourceDurationMs: sourceDurationMs,
    warnings: warnings,
  );
}
