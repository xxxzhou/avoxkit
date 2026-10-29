import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/media_frames.dart';

/// 缩略图条: 把已抓到的帧按时间铺在条上, 随视口缩放/平移。
/// 只画图; 选中压暗与边框交给父级 painter, 嵌进不同时间线时样式保持一致。
class AkFilmstrip extends StatelessWidget {
  const AkFilmstrip({
    super.key,
    required this.frames,
    required this.durationMs,
    required this.viewStart,
    required this.viewEnd,
  });

  final List<MediaFrame> frames;
  final int durationMs;
  final double viewStart;
  final double viewEnd;

  @override
  Widget build(BuildContext context) {
    if (frames.isEmpty || durationMs <= 0) {
      return const SizedBox.expand();
    }
    return ClipRect(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final height = constraints.maxHeight;
          if (width <= 0 || height <= 0) {
            return const SizedBox.shrink();
          }
          final span = math.max(1.0, viewEnd - viewStart);
          // 一格 = 一个采样间隔; 放大后单张不再拉伸, 保持 16:9 自然宽度,
          // 露出的空隙就是"这里没有采样帧", 不假装有连续画面。
          final cellPx = durationMs / frames.length / span * width;
          final naturalPx = height * 16 / 9;
          final drawPx = math.max(1.0, math.min(cellPx, naturalPx));
          final children = <Widget>[];
          for (final frame in frames) {
            final center = (frame.ms - viewStart) / span * width;
            final left = center - cellPx / 2 + (cellPx - drawPx) / 2;
            if (left + drawPx < 0 || left > width) {
              continue;
            }
            children.add(
              Positioned(
                key: ValueKey(frame.ms),
                left: left,
                top: 0,
                width: drawPx,
                height: height,
                child: Image.memory(
                  frame.bytes,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  filterQuality: FilterQuality.low,
                ),
              ),
            );
          }
          return Stack(fit: StackFit.expand, children: children);
        },
      ),
    );
  }
}
