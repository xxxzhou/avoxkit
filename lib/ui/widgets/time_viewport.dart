import 'dart:math' as math;

/// 时间轴的视口: ms<->px 映射、以指针为锚的缩放、平移、刻度间隔。
/// 只做换算不碰数据/绘制; 区间尺、单点尺、波形条共用同一套手势语义。
class TimeViewport {
  TimeViewport({int durationMs = 0}) {
    _durationMs = durationMs;
    reset();
  }

  int _durationMs = 0;
  double viewStart = 0;
  double viewEnd = 0;

  int get durationMs => _durationMs;
  set durationMs(int value) {
    if (value != _durationMs) {
      _durationMs = value;
      reset();
    }
  }

  double get span => math.max(1, viewEnd - viewStart);
  bool get isFull => viewStart <= 0.5 && viewEnd >= _durationMs - 0.5;

  void reset() {
    viewStart = 0;
    viewEnd = math.max(0, _durationMs).toDouble();
  }

  double xForMs(double ms, double width) => (ms - viewStart) / span * width;

  double msForX(double x, double width) =>
      viewStart + x / math.max(1, width) * span;

  /// [factor] > 1 拉远, < 1 推近; 锚点下的时间保持不动。
  void zoomAt(double x, double factor, double width) {
    final duration = _durationMs.toDouble();
    if (duration <= 0 || width <= 0) {
      return;
    }
    final anchor = msForX(x, width);
    final minSpan = math.min(duration, 1000.0);
    final next = (span * factor).clamp(minSpan, duration).toDouble();
    var start = anchor - (anchor - viewStart) * next / span;
    start = start.clamp(0.0, math.max(0.0, duration - next)).toDouble();
    viewStart = start;
    viewEnd = start + next;
  }

  void panBy(double deltaMs) {
    final duration = _durationMs.toDouble();
    if (duration <= 0) {
      return;
    }
    final width = span;
    final start = (viewStart + deltaMs)
        .clamp(0.0, math.max(0.0, duration - width))
        .toDouble();
    viewStart = start;
    viewEnd = start + width;
  }

  static const _intervals = <int>[
    100,
    200,
    500,
    1000,
    2000,
    5000,
    10000,
    15000,
    30000,
    60000,
    120000,
    300000,
    600000,
    1800000,
    3600000,
  ];

  /// 刻度间隔: 保证两个标签至少隔 64px。
  int rulerInterval(double width) => intervalForSpan(span, width);

  static int intervalForSpan(double span, double width) =>
      _intervals.firstWhere(
        (value) => value / math.max(1, span) * width >= 64,
        orElse: () => _intervals.last,
      );
}
