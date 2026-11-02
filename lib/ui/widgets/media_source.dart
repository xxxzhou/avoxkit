import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../tokens.dart';
import 'panel.dart';
import '../../core/i18n.dart';

const kVideoExtensions = [
  'mkv', 'mp4', 'mov', 'avi', 'ts', 'flv', 'webm', 'wmv', 'm4v', //
];

/// 选片入口: 按钮 + 拖入支持; 拖入逻辑与具体工具无关
class AkSourcePicker extends StatefulWidget {
  const AkSourcePicker({
    super.key,
    required this.onFile,
    required this.onFolder,
    this.onSample,
    this.onDroppedFile,
    this.onDroppedFolder,
    this.extensions = kVideoExtensions,
    this.hint,
  });

  final VoidCallback onFile;
  final VoidCallback onFolder;

  /// 空库首次打开时审核/新用户没有素材, 给一条能立刻跑通的示例
  final VoidCallback? onSample;

  /// 拖入时把第一个符合扩展名的文件交给页面; 为 null 表示此页不收拖拽
  final ValueChanged<String>? onDroppedFile;
  final ValueChanged<String>? onDroppedFolder;
  final List<String> extensions;
  final String? hint;

  /// 从拖入路径里挑第一个可接受的普通文件; 无匹配返回 null
  static String? firstAcceptedFile(
    List<String> paths,
    List<String> extensions,
  ) {
    for (final path in paths) {
      if (!FileSystemEntity.isFileSync(path)) {
        continue;
      }
      final ext = p.extension(path).toLowerCase().replaceFirst('.', '');
      if (extensions.contains(ext)) {
        return path;
      }
    }
    return null;
  }

  @override
  State<AkSourcePicker> createState() => _AkSourcePickerState();
}

class _AkSourcePickerState extends State<AkSourcePicker> {
  bool _hover = false;

  bool get _acceptsDrop =>
      widget.onDroppedFile != null || widget.onDroppedFolder != null;

  void _handleDrop(List<String> paths) {
    String? folder;
    for (final path in paths) {
      if (FileSystemEntity.isDirectorySync(path)) {
        folder = path;
        break;
      }
    }
    if (folder != null && widget.onDroppedFolder != null) {
      widget.onDroppedFolder!(folder);
      return;
    }
    final file =
        AkSourcePicker.firstAcceptedFile(paths, widget.extensions);
    if (file != null && widget.onDroppedFile != null) {
      widget.onDroppedFile!(file);
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: T('拖入的内容不支持')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final content = AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: _hover ? AkColors.accent : Colors.transparent,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              FilledButton.icon(
                onPressed: widget.onFile,
                icon: const Icon(Icons.insert_drive_file_outlined, size: 18),
                label: const T('打开文件'),
              ),
              const SizedBox(width: 10),
              OutlinedButton.icon(
                onPressed: widget.onFolder,
                icon: const Icon(Icons.folder_open_outlined, size: 18),
                label: const T('打开文件夹'),
              ),
              if (widget.onSample != null) ...[
                const SizedBox(width: 10),
                TextButton.icon(
                  onPressed: widget.onSample,
                  icon: const Icon(Icons.auto_awesome_outlined, size: 17),
                  label: const T('试用示例'),
                ),
              ],
            ],
          ),
          if (widget.hint != null) ...[
            const SizedBox(height: 8),
            T(widget.hint!, style: AkText.micro),
          ],
          if (_acceptsDrop) ...[
            SizedBox(height: widget.hint != null ? 4 : 8),
            const T('也可以把文件或文件夹直接拖进来', style: AkText.micro),
          ],
        ],
      ),
    );
    if (!_acceptsDrop) {
      return content;
    }
    return DropTarget(
      onDragEntered: (_) => setState(() => _hover = true),
      onDragExited: (_) => setState(() => _hover = false),
      onDragDone: (details) {
        setState(() => _hover = false);
        _handleDrop([for (final file in details.files) file.path]);
      },
      child: content,
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
