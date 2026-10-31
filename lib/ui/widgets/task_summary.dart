import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/task.dart';
import '../../core/task_store.dart';
import '../tokens.dart';
import 'panel.dart';
import '../../core/i18n.dart';

/// 工具页底部的单任务回执: 进度 / 取消 / 错误 / 产物路径。
/// 只认本页提交的任务; 退回全局最新会把别的工具的任务显示在这里。
class AkLatestTask extends StatelessWidget {
  const AkLatestTask({super.key, required this.taskStore, this.taskId});

  final TaskStore taskStore;
  final int? taskId;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: taskStore,
      builder: (context, _) {
        final task = taskStore.taskById(taskId);
        if (task == null) {
          return const SizedBox.shrink();
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            T('最近任务', style: AkText.label),
            const SizedBox(height: 10),
            AkTaskSummary(task: task, taskStore: taskStore),
          ],
        );
      },
    );
  }
}

class AkTaskSummary extends StatelessWidget {
  const AkTaskSummary({
    super.key,
    required this.task,
    required this.taskStore,
  });

  final TaskItem task;
  final TaskStore taskStore;

  @override
  Widget build(BuildContext context) {
    final color = switch (task.state) {
      'done' => AkColors.state,
      'failed' => AkColors.danger,
      'cancelled' => AkColors.faint,
      'running' => AkColors.accent,
      _ => AkColors.muted,
    };
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AkColors.surfaceAlt,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              StateDot(color: color),
              const SizedBox(width: 8),
              Expanded(
                child: T(
                  '${task.stateLabel} · ${task.title}',
                  style: AkText.body.copyWith(color: AkColors.textStrong),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (task.isActive)
                TextButton(
                  onPressed: task.cancelRequested
                      ? null
                      : () => taskStore.cancel(task.id),
                  child: T(task.cancelRequested ? I18n.tr('取消中…') : I18n.tr('取消')),
                ),
            ],
          ),
          if (task.isActive) ...[
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: task.progress == 0 ? null : task.progress,
                minHeight: 4,
                backgroundColor: AkColors.surfaceHi,
                color: AkColors.accent,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                T(
                  task.stage != null ? task.stageLabel : I18n.tr('等待中'),
                  style: AkText.micro,
                ),
                const Spacer(),
                T(
                  '${(task.progress * 100).round()}%',
                  style: AkText.mono.copyWith(fontSize: 11),
                ),
              ],
            ),
          ],
          if (task.state == 'failed') ...[
            const SizedBox(height: 8),
            T(
              task.errorMessage ?? I18n.tr('任务失败'),
              style: AkText.body.copyWith(color: AkColors.danger),
            ),
            if (task.errorCode != null)
              T(task.errorCode!, style: AkText.micro),
          ],
          if (task.state == 'done' && task.output != null) ...[
            const SizedBox(height: 8),
            AkOutputPath(path: task.output!),
          ],
        ],
      ),
    );
  }
}

/// 产物路径: 双击整行复制, 悬停给手型和提示(单击太容易误触)
class AkOutputPath extends StatelessWidget {
  const AkOutputPath({super.key, required this.path});

  final String path;

  Future<void> _copy(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: path));
    if (!context.mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: T('已复制路径到剪贴板'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: I18n.tr('双击复制路径'),
      waitDuration: const Duration(milliseconds: 400),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onDoubleTap: () => _copy(context),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: T(
              path,
              style: AkText.micro,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
      ),
    );
  }
}
