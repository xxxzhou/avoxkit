import 'package:flutter/material.dart';

import '../tokens.dart';
import 'panel.dart';

/// 无拖拽时也够用的选片入口: 虚线风格的大按钮 + 隐私提示
class AkSourcePicker extends StatelessWidget {
  const AkSourcePicker({
    super.key,
    required this.onTap,
    this.title = '选择视频文件',
    this.hint = '文件不会离开本机',
  });

  final VoidCallback onTap;
  final String title;
  final String hint;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 36, horizontal: 20),
        decoration: BoxDecoration(
          color: AkColors.bgDeep,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AkColors.border),
        ),
        child: Column(
          children: [
            const Icon(Icons.add, color: AkColors.accent, size: 24),
            const SizedBox(height: 10),
            Text(title, style: AkText.body),
            const SizedBox(height: 4),
            Text(hint, style: AkText.micro),
          ],
        ),
      ),
    );
  }
}

/// 探测结果摘要; 三个工具页共用同一套口径
class AkMediaInfo extends StatelessWidget {
  const AkMediaInfo({super.key, required this.media});

  final Map<String, dynamic> media;

  static Map<String, dynamic>? firstTrack(dynamic value) {
    if (value is List && value.isNotEmpty && value.first is Map) {
      return (value.first as Map).cast<String, dynamic>();
    }
    return null;
  }

  static String formatDuration(int ms) {
    final total = (ms / 1000).round();
    final minutes = total ~/ 60;
    final seconds = total % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final video = firstTrack(media['video']);
    final audio = firstTrack(media['audio']);
    final duration = (media['duration_ms'] as num?)?.toInt() ?? 0;
    return Column(
      children: [
        LabeledRow(label: '时长', value: formatDuration(duration)),
        LabeledRow(
          label: '视频',
          value: video == null
              ? '无'
              : '${_upper(video['codec'])} · ${video['width']}×${video['height']}'
                  '${_fps(video['fps'])}',
        ),
        LabeledRow(
          label: '音频',
          value: audio == null
              ? '无'
              : '${_upper(audio['codec'])} · ${audio['channels']} 声道 · '
                  '${audio['sample_rate']} Hz',
        ),
        LabeledRow(label: '容器', value: '${media['format'] ?? '未知'}'),
      ],
    );
  }

  static String _upper(dynamic value) =>
      value == null ? '未知' : value.toString().toUpperCase();

  static String _fps(dynamic value) {
    if (value is num && value > 0) {
      return ' · ${value.toStringAsFixed(value % 1 == 0 ? 0 : 2)} fps';
    }
    return '';
  }
}
