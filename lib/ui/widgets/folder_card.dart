import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../../core/batch.dart';
import '../../core/folder_source.dart';
import '../tokens.dart';
import 'panel.dart';
import '../../core/i18n.dart';

/// 工具页的文件夹输入卡: 路径、递归、匹配数量与展开计划
class FolderCard extends StatelessWidget {
  const FolderCard({
    super.key,
    required this.source,
    required this.plan,
    required this.onPickAnother,
    this.noun = '视频',
  });

  final FolderSource source;
  final BatchPlan? plan;
  final VoidCallback onPickAnother;

  /// 匹配项的称呼; 图像页传「图片」
  final String noun;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: source,
      builder: (context, _) {
        final scan = source.scan;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: T(
                    source.root!,
                    style: AkText.body.copyWith(
                      color: AkColors.textStrong,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: onPickAnother,
                  child: const T('换一个'),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Switch(
                  value: source.recursive,
                  onChanged: source.scanning ? null : source.setRecursive,
                ),
                const SizedBox(width: 8),
                T('包含子文件夹', style: AkText.body),
              ],
            ),
            if (source.scanning)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 10),
                child: LinearProgressIndicator(minHeight: 2),
              )
            else if (scan != null) ...[
              if (scan.error != null)
                T(
                  scan.error!,
                  style: AkText.body.copyWith(color: AkColors.danger),
                )
              else if (scan.count == 0)
                T('没有找到匹配的$noun。',
                  style: AkText.body.copyWith(color: AkColors.muted),
                )
              else ...[
                LabeledRow(
                  label: I18n.tr('匹配'),
                  value: '${scan.count} 个$noun · ${formatSize(scan.totalBytes)}',
                ),
                if (plan != null)
                  LabeledRow(
                    label: I18n.tr('待处理'),
                    value: '${plan!.count} 个'
                        '${plan!.skippedExisting > 0 ? ' · ${plan!.skippedExisting} 个已存在将跳过' : ''}',
                  ),
                if (scan.truncated)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: T('文件数超过上限（5000），已停止扫描，请缩小范围。',
                      style: AkText.micro.copyWith(color: AkColors.danger),
                    ),
                  ),
              ],
            ],
            const SizedBox(height: 12),
            T('扫描结果在提交时固定；之后文件夹里新增的文件不会自动加入。',
              style: AkText.micro,
            ),
          ],
        );
      },
    );
  }
}

/// 文件夹模式的输出位置(源文件旁 / 保留结构 / 平铺)
class OutputPolicyPicker extends StatelessWidget {
  const OutputPolicyPicker({super.key, required this.source});

  final FolderSource source;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: source,
      builder: (context, _) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            T('输出位置', style: AkText.label),
            const SizedBox(height: 8),
            SegmentedButton<OutputPolicy>(
              segments: const [
                ButtonSegment(
                  value: OutputPolicy.sidecar,
                  label: T('源文件旁'),
                ),
                ButtonSegment(
                  value: OutputPolicy.mirror,
                  label: T('保留结构'),
                ),
                ButtonSegment(value: OutputPolicy.flat, label: T('平铺')),
              ],
              selected: {source.policy},
              showSelectedIcon: false,
              onSelectionChanged: (values) => source.setPolicy(values.first),
            ),
            if (source.policy != OutputPolicy.sidecar) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: T(
                      (source.outputRoot == null || source.outputRoot!.isEmpty)
                          ? I18n.tr('尚未选择输出目录')
                          : source.outputRoot!,
                      style: AkText.micro,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: () async {
                      final path = await getDirectoryPath();
                      if (path != null) {
                        source.setOutputRoot(path);
                      }
                    },
                    child: const T('选择'),
                  ),
                ],
              ),
            ],
          ],
        );
      },
    );
  }
}

String formatSize(int bytes) {
  if (bytes >= 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
  if (bytes >= 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  if (bytes >= 1024) {
    return '${(bytes / 1024).toStringAsFixed(0)} KB';
  }
  return '$bytes B';
}
