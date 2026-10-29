import 'package:flutter/material.dart';

import '../../core/media_frame_source.dart';
import '../tokens.dart';

/// 参考画面卡: 给定时刻, 先显示缓存里最近的一帧, 精确帧到了再换。
/// 共享给截取/抽帧/去水印/字幕预览, 各页面不再自己写取帧与占位逻辑。
class AkFramePreview extends StatefulWidget {
  const AkFramePreview({
    super.key,
    required this.source,
    required this.timeMs,
    this.label,
    this.timeLabel,
    this.width = 320,
    this.aspectRatio = 16 / 9,
    this.emptyText = '这个文件没有画面',
  });

  final MediaFrameSource source;
  final int timeMs;

  /// 左上角角色, 如 "入点"/"出点"/"参考"
  final String? label;

  /// 已格式化的时间; 由页面决定精度
  final String? timeLabel;

  /// 请求帧的像素宽度: 预览 320, 去水印底图可传 960
  final int width;
  final double aspectRatio;
  final String emptyText;

  @override
  State<AkFramePreview> createState() => _AkFramePreviewState();
}

class _AkFramePreviewState extends State<AkFramePreview> {
  @override
  void initState() {
    super.initState();
    _request();
  }

  @override
  void didUpdateWidget(covariant AkFramePreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.timeMs != widget.timeMs ||
        oldWidget.width != widget.width ||
        oldWidget.source != widget.source) {
      _request();
    }
  }

  void _request() => widget.source.request(widget.timeMs, width: widget.width);

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: widget.aspectRatio,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: AkColors.bgDeep,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: AkColors.border),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(5),
          child: ListenableBuilder(
            listenable: widget.source,
            builder: (context, _) {
              final frame = widget.source.nearest(widget.timeMs);
              return Stack(
                fit: StackFit.expand,
                children: [
                  if (frame != null)
                    Image.memory(
                      frame.bytes,
                      fit: BoxFit.contain,
                      gaplessPlayback: true,
                      filterQuality: FilterQuality.medium,
                    )
                  else
                    Center(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(
                          widget.emptyText,
                          style: AkText.micro,
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                  Positioned(
                    left: 8,
                    right: 8,
                    bottom: 8,
                    child: Row(
                      children: [
                        if (widget.label != null)
                          _badge(widget.label!, accent: true),
                        if (widget.label != null && widget.timeLabel != null)
                          const SizedBox(width: 6),
                        if (widget.timeLabel != null)
                          _badge(widget.timeLabel!, accent: false),
                        const Spacer(),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _badge(String text, {required bool accent}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: AkColors.bgDeep.withValues(alpha: 0.78),
        borderRadius: BorderRadius.circular(3),
        border: Border.all(
          color: accent
              ? AkColors.accent.withValues(alpha: 0.45)
              : AkColors.border,
        ),
      ),
      child: Text(
        text,
        style: AkText.micro.copyWith(
          color: accent ? AkColors.accent : AkColors.textStrong,
          fontFamily: 'JetBrains Mono',
        ),
      ),
    );
  }
}
