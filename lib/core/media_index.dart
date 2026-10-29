import 'dart:convert';

import '../native/ak_bindings.dart';

/// 时间线的只读素材: 音频包络 + 视频关键帧。失败/无音轨时对应字段为空,
/// 时间线退化为纯刻度, 不影响截取。
class MediaIndex {
  const MediaIndex({
    required this.durationMs,
    required this.bucketMs,
    required this.peaks,
    required this.keyframesMs,
    required this.hasAudio,
  });

  factory MediaIndex.fromJson(Map<String, dynamic> json) {
    return MediaIndex(
      durationMs: (json['duration_ms'] as num?)?.toInt() ?? 0,
      bucketMs: (json['bucket_ms'] as num?)?.toInt() ?? 0,
      peaks: _ints(json['peaks']),
      keyframesMs: _ints(json['keyframes_ms']),
      hasAudio: json['has_audio'] == true,
    );
  }

  final int durationMs;
  final int bucketMs;
  final List<int> peaks;
  final List<int> keyframesMs;
  final bool hasAudio;

  bool get hasWave => peaks.isNotEmpty;

  static List<int> _ints(dynamic value) {
    if (value is! List) {
      return const [];
    }
    return value.whereType<num>().map((item) => item.toInt()).toList();
  }
}

/// 在 isolate 里建独立 FFI 句柄解码音频; 不碰任务队列, 失败只丢时间线内容。
MediaIndex? scanMediaIndex(String path, int buckets) {
  try {
    final bindings = AkBindings.open();
    final value = jsonDecode(bindings.mediaIndex(path, buckets));
    if (value is Map<String, dynamic> && value['ok'] == true) {
      return MediaIndex.fromJson(value);
    }
  } catch (_) {
    // 索引是增强项, 不阻塞选片与截取
  }
  return null;
}
