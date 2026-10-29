import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../tokens.dart';

/// 整片音频包络: 每格代表 bucketMs 的峰值(0-100), 已处理部分高亮。
class AkWaveform extends StatelessWidget {
  const AkWaveform({
    super.key,
    required this.peaks,
    this.bucketMs = 100,
    this.startMs = 0,
    this.totalMs,
    this.currentMs,
    this.height = 96,
  });

  final List<int> peaks;
  final int bucketMs;
  final int startMs;
  final int? totalMs;
  final int? currentMs;
  final double height;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(
        painter: _WavePainter(
          peaks: peaks,
          startMs: startMs,
          totalMs: totalMs,
          currentMs: currentMs,
        ),
      ),
    );
  }
}

class _WavePainter extends CustomPainter {
  _WavePainter({
    required this.peaks,
    required this.startMs,
    required this.totalMs,
    required this.currentMs,
  });

  final List<int> peaks;
  final int startMs;
  final int? totalMs;
  final int? currentMs;

  @override
  void paint(Canvas canvas, Size size) {
    if (peaks.isEmpty || size.width <= 0 || size.height <= 0) {
      return;
    }
    final slot = size.width / peaks.length;
    final barWidth = math.max(1.0, slot * 0.55);
    final mid = size.height / 2;
    final processed = _processedCount();
    final donePaint = Paint()..color = AkColors.accent;
    final restPaint = Paint()..color = AkColors.surfaceHi;
    for (var i = 0; i < peaks.length; i++) {
      final amplitude =
          (peaks[i].clamp(0, 100) / 100.0) * (size.height - 4);
      final top = mid - amplitude / 2;
      final rect = Rect.fromLTWH(
        i * slot + (slot - barWidth) / 2,
        top,
        barWidth,
        math.max(1.0, amplitude),
      );
      canvas.drawRect(rect, i < processed ? donePaint : restPaint);
    }
    if (processed > 0 && processed < peaks.length) {
      final x = processed * slot;
      canvas.drawRect(
        Rect.fromLTWH(x, 0, 1, size.height),
        Paint()..color = AkColors.accent.withValues(alpha: 0.7),
      );
    }
  }

  int _processedCount() {
    final total = totalMs;
    final current = currentMs;
    if (total == null || total <= 0 || current == null) {
      return peaks.length;
    }
    final ratio = ((current - startMs) / total).clamp(0.0, 1.0);
    return (ratio * peaks.length).round().clamp(0, peaks.length);
  }

  @override
  bool shouldRepaint(covariant _WavePainter oldDelegate) {
    // peaks 在 TaskItem 里原地追加, 身份比较无效; 事件驱动的重建就是重绘信号
    return true;
  }
}
