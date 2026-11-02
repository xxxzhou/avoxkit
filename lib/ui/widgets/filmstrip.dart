import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/media_frames.dart';

/// 缩略图条: 把已抓到的帧按时间铺在条上, 随视口缩放/平移。
/// 只画图; 选中压暗与边框交给父级 painter, 嵌进不同时间线时样式保持一致。
/// 格子宽高比用引擎返回的输出宽高(frameWidth/frameHeight, 已含旋转语义),
/// 未拿到时按 16:9 兜底。
class AkFilmstrip extends StatelessWidget {
  const AkFilmstrip({
    super.key,
    required this.frames,
    required this.durationMs,
    required this.viewStart,
    required this.viewEnd,
    this.frameWidth = 0,
    this.frameHeight = 0,
  });

  final List<MediaFrame> frames;
  final int durationMs;
  final double viewStart;
  final double viewEnd;

  /// 引擎实际输出尺寸; 0 表示未知
  final int frameWidth;
  final int frameHeight;

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
          // 一格 = 一个采样间隔; 放大后单张不再拉伸, 保持引擎输出的
          // 显示宽高比, 露出的空隙就是I18n.tr("这里没有采样帧"), 不假装有连续画面。
          final cellPx = durationMs / frames.length / span * width;
          final aspect = frameWidth > 0 && frameHeight > 0
              ? frameWidth / frameHeight
              : 16 / 9;
          final naturalPx = height * aspect;
          final drawPx = math.max(1.0, math.min(cellPx, naturalPx));
          // 宽度不够自然宽时, 高度跟着收, 格子与图同比例, 不裁切。
          final drawHeight = math.min(height, drawPx / aspect);
          final top = (height - drawHeight) / 2;
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
                top: top,
                width: drawPx,
                height: drawHeight,
                child: Image.memory(
                  frame.bytes,
                  fit: BoxFit.contain,
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
