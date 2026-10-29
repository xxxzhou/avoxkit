import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../core/clip_plan.dart';
import '../../core/media_frames.dart';
import '../../core/media_index.dart';
import '../tokens.dart';
import 'filmstrip.dart';
import 'time_viewport.dart';

/// 截取时间线: 缩略图条 + 时间尺 + 音频包络 + 关键帧刻度 + 入出点区间。
///
/// 不是播放器时间线: 没有连续播放/播放头, 只负责"看形状、取舍区间"。
/// 滚轮缩放, 拖空白处平移, 双击回到全片; 起点自动吸附到关键帧,
/// 因为引擎按关键帧定位, 这样界面显示的就是产物真实起点。
/// 悬停/拖动时通过 onScrub 告诉页面"现在该显示哪一刻的画面"。
class AkTrimTimeline extends StatefulWidget {
  const AkTrimTimeline({
    super.key,
    required this.durationMs,
    required this.startMs,
    required this.endMs,
    required this.onChanged,
    this.index,
    this.frames = const [],
    this.frameWidth = 0,
    this.frameHeight = 0,
    this.stripNote,
    this.onScrub,
    this.onFramesNeeded,
    this.enabled = true,
    this.height = 150,
  });

  final int durationMs;
  final int startMs;
  final int endMs;
  final ValueChanged<(int, int)> onChanged;
  final MediaIndex? index;

  /// 整片缩略图(按时间铺开); 空则只显示 stripNote
  final List<MediaFrame> frames;

  /// 引擎返回的实际输出宽高(已含旋转语义); 决定缩略图格子的宽高比
  final int frameWidth;
  final int frameHeight;
  final String? stripNote;

  /// 指针所在/正在拖动的时刻; null 表示离开时间线
  final ValueChanged<int?>? onScrub;

  /// 首次布局或宽度变化时告诉页面该抓多少张缩略图
  final ValueChanged<int>? onFramesNeeded;
  final bool enabled;
  final double height;

  @override
  State<AkTrimTimeline> createState() => _AkTrimTimelineState();
}

enum _DragMode { none, start, end, band, pan }

class _AkTrimTimelineState extends State<AkTrimTimeline> {
  late final TimeViewport _viewport = TimeViewport(
    durationMs: widget.durationMs,
  );
  double _width = 0;
  double? _hoverX;
  double _grabOffsetMs = 0;
  _DragMode _drag = _DragMode.none;
  _DragMode _pendingMode = _DragMode.none;
  int? _lastScrubMs;
  int _lastFrameRequest = 0;

  @override
  void didUpdateWidget(covariant AkTrimTimeline oldWidget) {
    super.didUpdateWidget(oldWidget);
    _viewport.durationMs = widget.durationMs;
    if (_viewport.viewEnd <= _viewport.viewStart) {
      _viewport.reset();
    }
  }

  double get _span => _viewport.span;

  double _xForMs(double ms) => _viewport.xForMs(ms, _width);

  double _msForX(double x) => _viewport.msForX(x, _width);

  int _snapStart(int ms, int endMs) {
    final latest = math.max(0, endMs - kMinClipMs);
    var value = ms.clamp(0, latest);
    final keyframes = widget.index?.keyframesMs ?? const <int>[];
    if (keyframes.isNotEmpty) {
      value = snapClipStart(value, keyframes).clamp(0, latest);
    }
    return value;
  }

  void _emitScrub(int? ms) {
    final value = ms?.clamp(0, widget.durationMs).toInt();
    if (value == _lastScrubMs) {
      return;
    }
    _lastScrubMs = value;
    widget.onScrub?.call(value);
  }

  (int, int) _rangeFromDrag(double x) {
    final duration = widget.durationMs;
    switch (_drag) {
      case _DragMode.start:
        final start = _snapStart(_msForX(x).round(), widget.endMs);
        return (start, widget.endMs);
      case _DragMode.end:
        final end = _msForX(x)
            .round()
            .clamp(widget.startMs + kMinClipMs, duration);
        return (widget.startMs, end);
      case _DragMode.band:
        final length = widget.endMs - widget.startMs;
        final maxStart = math.max(0, duration - length);
        final raw = (_msForX(x) - _grabOffsetMs).round().clamp(0, maxStart);
        final start = _snapStart(raw, widget.endMs);
        final clamped = math.min(start, maxStart);
        return (clamped, math.min(clamped + length, duration));
      case _DragMode.pan:
      case _DragMode.none:
        return (widget.startMs, widget.endMs);
    }
  }

  // 拖动时给页面一个"当前该看哪一帧"的时刻
  int _dragTime(int start, int end) {
    return switch (_drag) {
      _DragMode.start => start,
      _DragMode.end => end,
      _DragMode.band => start,
      _DragMode.pan || _DragMode.none => _msForX(_hoverX ?? 0).round(),
    };
  }

  _DragMode _hitTest(double x) {
    final startX = _xForMs(widget.startMs.toDouble());
    final endX = _xForMs(widget.endMs.toDouble());
    final ds = (x - startX).abs();
    final de = (x - endX).abs();
    const hit = 12.0;
    if (ds <= hit && ds <= de) {
      return _DragMode.start;
    }
    if (de <= hit) {
      return _DragMode.end;
    }
    if (x > startX && x < endX) {
      return _DragMode.band;
    }
    return _DragMode.pan;
  }

  // 命中判定必须在 pointer down 时做: 手势识别器要等 slop 才回调
  // onPanStart, 那时指针已偏出 12px 手柄区, 会被误判成拖选区。
  void _onDragDown(DragDownDetails details) {
    if (!widget.enabled || widget.durationMs <= 0) {
      return;
    }
    _pendingMode = _hitTest(details.localPosition.dx);
    _grabOffsetMs = _msForX(details.localPosition.dx) - widget.startMs;
  }

  void _onDragStart(DragStartDetails details) {
    if (!widget.enabled || widget.durationMs <= 0) {
      return;
    }
    _drag = _pendingMode;
    setState(() {});
  }

  void _onDragUpdate(DragUpdateDetails details) {
    if (!widget.enabled || widget.durationMs <= 0) {
      return;
    }
    final x = details.localPosition.dx.clamp(0.0, _width);
    if (_drag == _DragMode.pan) {
      final deltaMs = -details.delta.dx / math.max(1, _width) * _span;
      _panBy(deltaMs);
      _emitScrub(_msForX(x).round());
      return;
    }
    final (start, end) = _rangeFromDrag(x);
    if (start != widget.startMs || end != widget.endMs) {
      widget.onChanged((start, end));
    }
    _emitScrub(_dragTime(start, end));
  }

  void _panBy(double deltaMs) {
    _viewport.panBy(deltaMs);
    setState(() {});
    if (_hoverX != null) {
      _emitScrub(_msForX(_hoverX!).round());
    }
  }

  void _zoomAt(double x, double factor) {
    _viewport.zoomAt(x, factor, _width);
    setState(() {});
    if (_hoverX != null) {
      _emitScrub(_msForX(_hoverX!).round());
    }
  }

  void _onSignal(PointerSignalEvent event) {
    if (!widget.enabled || event is! PointerScrollEvent) {
      return;
    }
    _zoomAt(event.localPosition.dx, event.scrollDelta.dy >= 0 ? 1.25 : 0.8);
  }

  void _onDoubleTap() {
    _viewport.reset();
    setState(() {});
    if (_hoverX != null) {
      _emitScrub(_msForX(_hoverX!).round());
    }
  }

  MouseCursor get _cursor {
    if (!widget.enabled) {
      return SystemMouseCursors.basic;
    }
    if (_drag == _DragMode.pan) {
      return SystemMouseCursors.grabbing;
    }
    final x = _hoverX;
    if (x != null) {
      final mode = _hitTest(x);
      if (mode == _DragMode.start || mode == _DragMode.end) {
        return SystemMouseCursors.resizeLeftRight;
      }
      if (mode == _DragMode.band) {
        return SystemMouseCursors.grab;
      }
    }
    return SystemMouseCursors.basic;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _width = constraints.maxWidth;
        final wantFrames = filmstripCount(constraints.maxWidth);
        if (wantFrames != _lastFrameRequest) {
          _lastFrameRequest = wantFrames;
          final callback = widget.onFramesNeeded;
          if (callback != null) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) {
                callback(wantFrames);
              }
            });
          }
        }
        return MouseRegion(
          cursor: _cursor,
          onHover: (event) {
            final x = event.localPosition.dx;
            if (_hoverX == null || (x - _hoverX!).abs() >= 1) {
              setState(() => _hoverX = x);
              _emitScrub(_msForX(x).round());
            }
          },
          onExit: (_) {
            setState(() => _hoverX = null);
            _emitScrub(null);
          },
          child: Listener(
            onPointerSignal: _onSignal,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onDoubleTap: _onDoubleTap,
              onPanDown: _onDragDown,
              onPanStart: _onDragStart,
              onPanUpdate: _onDragUpdate,
              onPanEnd: (details) {
                // 快速拖动时最后一个 update 可能早于手指抬起位置, 以抬起点补一次
                if (widget.enabled &&
                    widget.durationMs > 0 &&
                    _drag != _DragMode.pan &&
                    _drag != _DragMode.none) {
                  final x = details.localPosition.dx.clamp(0.0, _width);
                  final (start, end) = _rangeFromDrag(x);
                  if (start != widget.startMs || end != widget.endMs) {
                    widget.onChanged((start, end));
                  }
                  _emitScrub(_dragTime(start, end));
                }
                setState(() => _drag = _DragMode.none);
              },
              child: SizedBox(
                height: widget.height,
                width: double.infinity,
                child: Stack(
                  children: [
                    Positioned(
                      left: 0,
                      right: 0,
                      top: _TimelinePainter.rulerH,
                      height: _TimelinePainter.stripH,
                      child: ColoredBox(
                        color: AkColors.bgDeep,
                        child: AkFilmstrip(
                          frames: widget.frames,
                          frameWidth: widget.frameWidth,
                          frameHeight: widget.frameHeight,
                          durationMs: widget.durationMs,
                          viewStart: _viewport.viewStart,
                          viewEnd: _viewport.viewEnd,
                        ),
                      ),
                    ),
                    Positioned.fill(
                      child: IgnorePointer(
                        child: CustomPaint(
                          painter: _TimelinePainter(
                            durationMs: widget.durationMs,
                            viewStart: _viewport.viewStart,
                            viewEnd: _viewport.viewEnd,
                            startMs: widget.startMs,
                            endMs: widget.endMs,
                            index: widget.index,
                            hoverX: _hoverX,
                            enabled: widget.enabled,
                            drag: _drag,
                            hasFrames: widget.frames.isNotEmpty,
                            stripNote: widget.stripNote,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _TimelinePainter extends CustomPainter {
  _TimelinePainter({
    required this.durationMs,
    required this.viewStart,
    required this.viewEnd,
    required this.startMs,
    required this.endMs,
    required this.index,
    required this.hoverX,
    required this.enabled,
    required this.drag,
    required this.hasFrames,
    required this.stripNote,
  });

  final int durationMs;
  final double viewStart;
  final double viewEnd;
  final int startMs;
  final int endMs;
  final MediaIndex? index;
  final double? hoverX;
  final bool enabled;
  final _DragMode drag;
  final bool hasFrames;
  final String? stripNote;

  static const double rulerH = 22;
  static const double stripH = 46;
  static const double _pillH = 18;
  static const double _padBottom = 6;

  static const double _stripBottom = rulerH + stripH;
  static const double _waveTop = _stripBottom + 1;

  double get _span => math.max(1, viewEnd - viewStart);

  double _x(double ms, double width) => (ms - viewStart) / _span * width;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) {
      return;
    }
    final width = size.width;
    final waveTop = _waveTop;
    final pillTop = size.height - _padBottom - _pillH;
    final waveBottom = pillTop - 2;
    if (waveBottom <= waveTop) {
      return;
    }
    final startX = _x(startMs.toDouble(), width).clamp(0.0, width);
    final endX = _x(endMs.toDouble(), width).clamp(0.0, width);

    _paintBackground(canvas, size, waveTop, waveBottom, startX, endX);
    _paintWave(canvas, width, waveTop, waveBottom, startX, endX);
    _paintKeyframes(canvas, width, waveBottom);
    _paintRuler(canvas, width);
    _paintHandles(canvas, waveBottom, startX, endX);
    _paintHover(canvas, size, waveBottom);
    _paintPills(canvas, size, startX, endX);
  }

  void _paintBackground(
    Canvas canvas,
    Size size,
    double waveTop,
    double waveBottom,
    double startX,
    double endX,
  ) {
    // 条底色由 Stack 里的 ColoredBox 提供, 这里只铺波形区; 半透明层画在图上
    canvas.drawRect(
      Rect.fromLTRB(0, waveTop, size.width, waveBottom),
      Paint()..color = AkColors.bgDeep,
    );
    if (!hasFrames) {
      final painter = _text(stripNote ?? '无画面预览', AkColors.faint, 10);
      painter.paint(
        canvas,
        Offset(
          (size.width - painter.width) / 2,
          rulerH + (stripH - painter.height) / 2,
        ),
      );
    }
    // 选中区间压暗外侧; 不裁剪数据, 只做视觉聚焦
    final scrim = Paint()..color = Colors.black.withValues(alpha: 0.34);
    if (startX > 0) {
      canvas.drawRect(Rect.fromLTRB(0, rulerH, startX, waveBottom), scrim);
    }
    if (endX < size.width) {
      canvas.drawRect(
        Rect.fromLTRB(endX, rulerH, size.width, waveBottom),
        scrim,
      );
    }
    canvas.drawRect(
      Rect.fromLTRB(startX, rulerH, endX, _stripBottom),
      Paint()..color = AkColors.accent.withValues(alpha: 0.05),
    );
    final band = Paint()..color = AkColors.accent.withValues(alpha: 0.08);
    canvas.drawRect(Rect.fromLTRB(startX, waveTop, endX, waveBottom), band);
    final line = Paint()..color = AkColors.accent.withValues(alpha: 0.42);
    canvas.drawRect(
      Rect.fromLTWH(startX, rulerH, math.max(0.5, endX - startX), 1),
      line,
    );
    canvas.drawRect(
      Rect.fromLTWH(startX, waveBottom - 1, math.max(0.5, endX - startX), 1),
      line,
    );
    final hairline = Paint()..color = AkColors.border;
    canvas.drawRect(Rect.fromLTWH(0, _stripBottom, size.width, 1), hairline);
    canvas.drawRect(Rect.fromLTWH(0, size.height - 1, size.width, 1), hairline);
  }

  void _paintWave(
    Canvas canvas,
    double width,
    double waveTop,
    double waveBottom,
    double startX,
    double endX,
  ) {
    final mid = (waveTop + waveBottom) / 2;
    final amplitude = (waveBottom - waveTop) / 2 - 3;
    canvas.drawRect(
      Rect.fromLTWH(0, mid, width, 1),
      Paint()..color = AkColors.border,
    );
    final data = index;
    if (data == null || data.peaks.isEmpty) {
      return;
    }
    final peaks = data.peaks;
    final count = peaks.length;
    final dataDuration = data.durationMs > 0
        ? data.durationMs
        : math.max(1, durationMs);
    final insidePaint = Paint()..color = AkColors.accent;
    final outsidePaint = Paint()..color = AkColors.surfaceHi;
    for (var x = 0; x < width; x += 1) {
      final ms0 = viewStart + x / width * _span;
      final ms1 = viewStart + (x + 1) / width * _span;
      var i0 = (ms0 / dataDuration * count).floor();
      var i1 = (ms1 / dataDuration * count).ceil();
      if (i0 < 0) {
        i0 = 0;
      }
      if (i1 > count) {
        i1 = count;
      }
      if (i1 <= i0) {
        i1 = math.min(count, i0 + 1);
      }
      if (i0 >= count) {
        break;
      }
      var peak = 0;
      for (var i = i0; i < i1; i++) {
        if (peaks[i] > peak) {
          peak = peaks[i];
        }
      }
      final height = math.max(1.0, peak / 100 * amplitude);
      final inside = x >= startX && x <= endX;
      canvas.drawRect(
        Rect.fromLTWH(x.toDouble(), mid - height, 1, height * 2),
        inside ? insidePaint : outsidePaint,
      );
    }
  }

  void _paintKeyframes(Canvas canvas, double width, double waveBottom) {
    final keyframes = index?.keyframesMs ?? const <int>[];
    if (keyframes.isEmpty) {
      return;
    }
    final step = math.max(
      1,
      (keyframes.length * 4 / math.max(1, width)).ceil(),
    );
    final paint = Paint()..color = AkColors.state.withValues(alpha: 0.5);
    for (var i = 0; i < keyframes.length; i += step) {
      final x = _x(keyframes[i].toDouble(), width);
      if (x < 0 || x > width) {
        continue;
      }
      canvas.drawRect(Rect.fromLTWH(x, waveBottom - 5, 1, 4), paint);
    }
  }

  void _paintRuler(Canvas canvas, double width) {
    final interval = TimeViewport.intervalForSpan(_span, width);
    final tickPaint = Paint()..color = AkColors.border;
    final first = (viewStart / interval).ceil() * interval;
    var lastLabelRight = -1000.0;
    for (var ms = first; ms <= viewEnd.ceil(); ms += interval) {
      final x = _x(ms.toDouble(), width);
      if (x < 0 || x > width) {
        continue;
      }
      canvas.drawRect(Rect.fromLTWH(x, 0, 1, 5), tickPaint);
      final text = _tickLabel(ms, interval);
      final painter = _text(text, AkColors.faint, 10);
      final left = x + 3;
      if (left + painter.width <= width && left >= lastLabelRight + 8) {
        painter.paint(canvas, Offset(left, 6));
        lastLabelRight = left + painter.width;
      }
    }
  }

  String _tickLabel(int ms, int interval) {
    if (interval >= 1000) {
      final hours = ms ~/ 3600000;
      final minutes = (ms % 3600000) ~/ 60000;
      final seconds = (ms % 60000) ~/ 1000;
      if (hours > 0) {
        return '$hours:${minutes.toString().padLeft(2, '0')}:'
            '${seconds.toString().padLeft(2, '0')}';
      }
      return '$minutes:${seconds.toString().padLeft(2, '0')}';
    }
    final value = ms / 1000;
    return interval >= 500
        ? value.toStringAsFixed(1)
        : value.toStringAsFixed(2);
  }

  void _paintHandles(
    Canvas canvas,
    double waveBottom,
    double startX,
    double endX,
  ) {
    final active = drag == _DragMode.start
        ? startX
        : drag == _DragMode.end
        ? endX
        : null;
    _handle(canvas, startX, waveBottom, active == startX);
    _handle(canvas, endX, waveBottom, active == endX);
  }

  void _handle(Canvas canvas, double x, double bottom, bool active) {
    final color = enabled ? AkColors.accent : AkColors.faint;
    canvas.drawRect(
      Rect.fromLTWH(x - 1, rulerH, 2, bottom - rulerH),
      Paint()..color = color,
    );
    final size = active ? 18.0 : 14.0;
    final center = rulerH + stripH / 2;
    final grip = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset(x, center), width: size, height: size),
      const Radius.circular(4),
    );
    canvas.drawRRect(grip, Paint()..color = AkColors.bgDeep);
    canvas.drawRRect(
      grip,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = color,
    );
    canvas.drawRect(
      Rect.fromCenter(center: Offset(x, center), width: 2, height: size - 6),
      Paint()..color = color,
    );
  }

  void _paintHover(Canvas canvas, Size size, double waveBottom) {
    final x = hoverX;
    if (x == null || !enabled || x < 0 || x > size.width) {
      return;
    }
    canvas.drawRect(
      Rect.fromLTWH(x, rulerH, 1, waveBottom - rulerH),
      Paint()..color = AkColors.text.withValues(alpha: 0.32),
    );
    final ms = (viewStart + x / size.width * _span).round();
    final painter = _text(formatTimestamp(ms), AkColors.textStrong, 10);
    final left = (x + 6 + painter.width > size.width)
        ? x - 6 - painter.width
        : x + 6;
    final top = rulerH + 4;
    final bg = RRect.fromRectAndRadius(
      Rect.fromLTWH(left - 4, top - 2, painter.width + 8, painter.height + 4),
      const Radius.circular(3),
    );
    canvas.drawRRect(bg, Paint()..color = AkColors.surfaceHi);
    painter.paint(canvas, Offset(left, top));
  }

  void _paintPills(Canvas canvas, Size size, double startX, double endX) {
    final top = size.height - _padBottom - _pillH;
    final withMs = _span < 20 * 60 * 1000;
    final startLabel = formatTimestamp(startMs, withMillis: withMs);
    final endLabel = formatTimestamp(endMs, withMillis: withMs);
    final startText = _text(startLabel, AkColors.accent, 10);
    final endText = _text(endLabel, AkColors.accent, 10);
    final startLeft = startX + 2;
    final endLeft = endX - 2 - endText.width;
    if (startLeft + startText.width + 8 < endLeft) {
      _pill(canvas, startText, startLeft, top);
      _pill(canvas, endText, endLeft, top);
      return;
    }
    final joined = _text('$startLabel – $endLabel', AkColors.accent, 10);
    var left = (startX + endX - joined.width) / 2;
    left = left.clamp(2.0, math.max(2.0, size.width - joined.width - 2));
    _pill(canvas, joined, left, top);
  }

  void _pill(Canvas canvas, TextPainter painter, double left, double top) {
    final bg = RRect.fromRectAndRadius(
      Rect.fromLTWH(left - 4, top, painter.width + 8, _pillH - 2),
      const Radius.circular(3),
    );
    canvas.drawRRect(bg, Paint()..color = AkColors.bgDeep);
    canvas.drawRRect(
      bg,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = AkColors.accent.withValues(alpha: 0.35),
    );
    painter.paint(canvas, Offset(left, top + 1));
  }

  TextPainter _text(String value, Color color, double size) {
    return TextPainter(
      text: TextSpan(
        text: value,
        style: TextStyle(
          color: color,
          fontSize: size,
          fontFamily: 'JetBrains Mono',
          height: 1.2,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
  }

  @override
  bool shouldRepaint(covariant _TimelinePainter oldDelegate) {
    return oldDelegate.durationMs != durationMs ||
        oldDelegate.viewStart != viewStart ||
        oldDelegate.viewEnd != viewEnd ||
        oldDelegate.startMs != startMs ||
        oldDelegate.endMs != endMs ||
        oldDelegate.index != index ||
        oldDelegate.hoverX != hoverX ||
        oldDelegate.enabled != enabled ||
        oldDelegate.drag != drag ||
        oldDelegate.hasFrames != hasFrames ||
        oldDelegate.stripNote != stripNote;
  }
}
