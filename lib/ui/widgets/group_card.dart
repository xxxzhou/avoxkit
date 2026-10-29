import 'package:flutter/material.dart';

import '../../core/task_group.dart';
import '../../core/task_store.dart';
import '../tokens.dart';
import 'panel.dart';

/// 批量组的进度卡; 工具页用紧凑版, 任务页展开子任务
class AkGroupCard extends StatelessWidget {
  const AkGroupCard({
    super.key,
    required this.group,
    required this.taskStore,
    this.showTasks = false,
    this.onOpenTask,
  });

  final TaskGroup group;
  final TaskStore taskStore;
  final bool showTasks;

  /// 任务页传入; 工具页的紧凑卡不挂跳转
  final void Function(int taskId)? onOpenTask;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: taskStore,
      builder: (context, _) {
        final tasks = taskStore.tasksOfGroup(group.id);
        final done = tasks.where((task) => task.state == 'done').length;
        final failed = tasks.where((task) => task.state == 'failed').length;
        final cancelled =
            tasks.where((task) => task.state == 'cancelled').length;
        final queued = tasks.where((task) => task.state == 'queued').length;
        final running = tasks.where((task) => task.state == 'running').length;
        final active = tasks.where((task) => task.isActive).length;
        final finished = done + failed + cancelled;
        final progress = tasks.isEmpty ? 0.0 : finished / tasks.length;
        final color = active > 0
            ? AkColors.accent
            : (failed > 0 && done == 0 ? AkColors.danger : AkColors.state);
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
                    child: Text(
                      '${group.toolLabel} · ${group.title}',
                      style: AkText.body.copyWith(color: AkColors.textStrong),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (active > 0)
                    TextButton(
                      onPressed: () => taskStore.cancelGroup(group.id),
                      child: const Text('取消整组'),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: progress,
                  minHeight: 4,
                  backgroundColor: AkColors.surfaceHi,
                  color: color,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '完成 $done · 失败 $failed · 进行中 $running'
                '${queued > 0 ? ' · 排队 $queued' : ''}'
                '${group.skipped > 0 ? ' · 跳过 ${group.skipped}' : ''}',
                style: AkText.micro,
              ),
              if (failed > 0) ...[
                const SizedBox(height: 8),
                OutlinedButton(
                  onPressed: () {
                    final retried = taskStore.retryGroupFailed(group.id);
                    if (retried == 0) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('没有可重试的任务')),
                      );
                    }
                  },
                  child: const Text('重试失败项'),
                ),
              ],
              if (showTasks && tasks.isNotEmpty) ...[
                const SizedBox(height: 12),
                const Divider(height: 1),
                const SizedBox(height: 8),
                for (final task in tasks)
                  InkWell(
                    onTap: onOpenTask == null
                        ? null
                        : () => onOpenTask!(task.id),
                    borderRadius: BorderRadius.circular(4),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          vertical: 4, horizontal: 4),
                      child: Row(
                        children: [
                          StateDot(
                            color: switch (task.state) {
                              'done' => AkColors.state,
                              'failed' => AkColors.danger,
                              'cancelled' => AkColors.faint,
                              'running' => AkColors.accent,
                              _ => AkColors.muted,
                            },
                            size: 6,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              task.title,
                              style: AkText.micro,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          Text(
                            task.state == 'failed'
                                ? (task.errorCode ?? '失败')
                                : task.state == 'queued'
                                    ? '前面 ${taskStore.queueAhead(task)} 个'
                                    : task.stateLabel,
                            style: AkText.micro,
                          ),
                          if (onOpenTask != null)
                            const Icon(Icons.chevron_right,
                                size: 14, color: AkColors.faint),
                        ],
                      ),
                    ),
                  ),
              ],
            ],
          ),
        );
      },
    );
  }
}
