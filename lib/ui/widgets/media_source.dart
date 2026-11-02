import 'package:flutter/material.dart';

import '../tokens.dart';
import 'panel.dart';
import '../../core/i18n.dart';

/// 选片入口: 两个按钮, 不再占一大块虚线框
class AkSourcePicker extends StatelessWidget {
  const AkSourcePicker({
    super.key,
    required this.onFile,
    required this.onFolder,
    this.onSample,
    this.hint,
  });

  final VoidCallback onFile;
  final VoidCallback onFolder;

  /// 空库首次打开时审核/新用户没有素材, 给一条能立刻跑通的示例
  final VoidCallback? onSample;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            FilledButton.icon(
              onPressed: onFile,
              icon: const Icon(Icons.insert_drive_file_outlined, size: 18),
              label: const T('打开文件'),
            ),
            const SizedBox(width: 10),
            OutlinedButton.icon(
              onPressed: onFolder,
              icon: const Icon(Icons.folder_open_outlined, size: 18),
              label: const T('打开文件夹'),
            ),
            if (onSample != null) ...[
              const SizedBox(width: 10),
              TextButton.icon(
                onPressed: onSample,
                icon: const Icon(Icons.auto_awesome_outlined, size: 17),
                label: const T('试用示例'),
              ),
            ],
          ],
        ),
        if (hint != null) ...[
          const SizedBox(height: 8),
          T(hint!, style: AkText.micro),
        ],
      ],
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
        LabeledRow(label: I18n.tr('时长'), value: formatDuration(duration)),
        LabeledRow(
          label: I18n.tr('视频'),
          value: video == null
              ? I18n.tr('无')
              : '${_upper(video['codec'])} · ${video['width']}×${video['height']}'
                  '${_fps(video['fps'])}',
        ),
        LabeledRow(
          label: I18n.tr('音频'),
          value: audio == null
              ? I18n.tr('无')
              : '${_upper(audio['codec'])} · ${audio['channels']} 声道 · '
                  '${audio['sample_rate']} Hz',
        ),
        LabeledRow(label: I18n.tr('容器'), value: '${media['format'] ?? '未知'}'),
      ],
    );
  }

  static String _upper(dynamic value) =>
      value == null ? I18n.tr('未知') : value.toString().toUpperCase();

  static String _fps(dynamic value) {
    if (value is num && value > 0) {
      return ' · ${value.toStringAsFixed(value % 1 == 0 ? 0 : 2)} fps';
    }
    return '';
  }
}
