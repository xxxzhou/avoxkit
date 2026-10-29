import 'dart:convert';
import 'dart:typed_data';

import '../native/ak_bindings.dart';

/// 一帧参考画面: JPEG 字节 + 实际解到的帧时间。
class MediaFrame {
  const MediaFrame({required this.ms, required this.bytes});

  final int ms;
  final Uint8List bytes;
}

/// 一次抓帧的结果。frames 为空不一定失败: 无视频轨/像素格式不支持也会返回空。
class MediaFrames {
  const MediaFrames({
    required this.width,
    required this.height,
    required this.frames,
    this.hasVideo = true,
  });

  factory MediaFrames.fromJson(Map<String, dynamic> json) {
    final frames = <MediaFrame>[];
    final raw = json['frames'];
    if (raw is List) {
      for (final item in raw) {
        if (item is! Map) {
          continue;
        }
        final image = item['image'];
        if (image is! String || image.isEmpty) {
          continue;
        }
        frames.add(
          MediaFrame(
            ms: (item['ms'] as num?)?.toInt() ?? 0,
            bytes: base64Decode(image),
          ),
        );
      }
    }
    return MediaFrames(
      width: (json['width'] as num?)?.toInt() ?? 0,
      height: (json['height'] as num?)?.toInt() ?? 0,
      frames: frames,
      hasVideo: json['has_video'] != false,
    );
  }

  final int width;
  final int height;
  final List<MediaFrame> frames;
  final bool hasVideo;

  bool get isEmpty => frames.isEmpty;
}

/// 缩略图条张数: 每约 76px 一张, 6-24 张, 跟着面板宽度走。
int filmstripCount(double width) => (width / 76).round().clamp(6, 24);

/// 取离 [ms] 最近的一帧; 距离相同时保留先出现的(精确帧先于缩略图)。
MediaFrame? nearestFrame(Iterable<MediaFrame> frames, int ms) {
  MediaFrame? best;
  var bestDelta = 1 << 62;
  for (final frame in frames) {
    final delta = (frame.ms - ms).abs();
    if (delta < bestDelta) {
      bestDelta = delta;
      best = frame;
    }
  }
  return best;
}

/// isolate 入口: 建独立 FFI 句柄抓帧, 失败只丢画面, 不影响选点。
MediaFrames? scanMediaFrames(
  String path, {
  int count = 12,
  List<int>? timesMs,
  int width = 320,
  int quality = 75,
}) {
  try {
    final bindings = AkBindings.open();
    final request = <String, dynamic>{'width': width, 'quality': quality};
    if (timesMs != null && timesMs.isNotEmpty) {
      request['times_ms'] = timesMs;
    } else {
      request['count'] = count;
    }
    final value = jsonDecode(bindings.mediaFrames(path, jsonEncode(request)));
    if (value is Map<String, dynamic> && value['ok'] == true) {
      return MediaFrames.fromJson(value);
    }
  } catch (_) {
    // 抓帧是增强项, 失败退化成只有波形/刻度
  }
  return null;
}
