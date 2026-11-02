import 'package:flutter/material.dart';

import '../../core/task.dart';
import '../../core/task_store.dart';
import '../tokens.dart';
import '../widgets/group_card.dart';
import '../widgets/panel.dart';
import 'task_detail_page.dart';
import '../../core/i18n.dart';

class TasksPage extends StatelessWidget {
  const TasksPage({super.key, required this.taskStore});

  final TaskStore taskStore;

  void _openTask(BuildContext context, int taskId) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TaskDetailPage(taskStore: taskStore, taskId: taskId),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 32, 32, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PageHeader(
            title: I18n.tr('任务'),
            description: I18n.tr('批量组与单文件任务；失败项可以重试。'),
          ),
          const SizedBox(height: 24),
          Expanded(
            child: ListenableBuilder(
              listenable: taskStore,
              builder: (context, _) {
                final groups = taskStore.groups;
                final loose = taskStore.tasks
                    .where((task) => task.groupId == null)
                    .toList();
                if (groups.isEmpty && loose.isEmpty) {
                  return const _EmptyTasks();
                }
                return ListView(
                  padding: const EdgeInsets.only(bottom: 40),
                  children: [
                    for (final group in groups)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: AkGroupCard(
                          group: group,
                          taskStore: taskStore,
                          showTasks: true,
                          onOpenTask: (taskId) =>
                              _openTask(context, taskId),
                        ),
                      ),
                    for (final task in loose)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: _TaskCard(
                          task: task,
                          taskStore: taskStore,
                          onOpenTask: () => _openTask(context, task.id),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyTasks extends StatelessWidget {
  const _EmptyTasks();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.list_alt, color: AkColors.faint, size: 32),
          const SizedBox(height: 12),
          T('还没有任务', style: AkText.body.copyWith(color: AkColors.muted)),
          const SizedBox(height: 4),
          T('在“转换”“截取片段”或“提取字幕”里选一个文件开始', style: AkText.micro),
        ],
      ),
    );
  }
}

class _TaskCard extends StatelessWidget {
  const _TaskCard({
    required this.task,
    required this.taskStore,
    required this.onOpenTask,
  });

  final TaskItem task;
  final TaskStore taskStore;
  final VoidCallback onOpenTask;

  @override
  Widget build(BuildContext context) {
    final color = _stateColor(task.state);
    return InkWell(
      onTap: onOpenTask,
      borderRadius: BorderRadius.circular(8),
      child: Panel(
        padding: const EdgeInsets.all(20),
        color: AkColors.surface,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                StateDot(color: color),
                const SizedBox(width: 10),
                Expanded(
                  child: T(
                    task.title,
                    style: AkText.body.copyWith(
                      color: AkColors.textStrong,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 12),
                T(
                  '#${task.id} · ${task.stateLabel}',
                  style: AkText.micro,
                ),
                const SizedBox(width: 2),
                const Icon(Icons.chevron_right,
                    size: 16, color: AkColors.faint),
                if (task.isActive) ...[
                  const SizedBox(width: 4),
                  TextButton(
                    onPressed: task.cancelRequested
                        ? null
                        : () => taskStore.cancel(task.id),
                    child: T(task.cancelRequested ? I18n.tr('取消中…') : I18n.tr('取消')),
                  ),
                ],
              ],
            ),
            if (task.input != null) ...[
              const SizedBox(height: 6),
              T(
                task.input!,
                style: AkText.micro,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
            if (task.state == 'queued') ...[
              const SizedBox(height: 14),
              T(
                _queueLabel(taskStore.queueAhead(task)),
                style: AkText.micro,
              ),
            ] else if (task.isActive) ...[
              const SizedBox(height: 14),
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
            if (task.state == 'done' && task.output != null) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  const Icon(Icons.check_circle_outline,
                      size: 14, color: AkColors.state),
                  const SizedBox(width: 6),
                  Expanded(
                    child: T(
                      task.output!,
                      style: AkText.micro,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ],
            if (task.state == 'failed') ...[
              const SizedBox(height: 12),
              T(
                task.errorMessage ?? I18n.tr('任务失败'),
                style: AkText.body.copyWith(color: AkColors.danger),
              ),
              if (task.errorCode != null || task.errorDetail != null) ...[
                const SizedBox(height: 4),
                T(
                  [task.errorCode, task.errorDetail]
                      .whereType<String>()
                      .where((value) => value.isNotEmpty)
                      .join(' · '),
                  style: AkText.micro,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              TextButton(
                onPressed: taskStore.engine.openLogFolder,
                child: const T('打开日志目录'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  static String _queueLabel(int ahead) {
    return ahead > 0 ? '排队中 · 前面还有 $ahead 个任务' : I18n.tr('排队中 · 即将开始');
  }

  static Color _stateColor(String state) {
    switch (state) {
      case 'done':
        return AkColors.state;
      case 'failed':
        return AkColors.danger;
      case 'cancelled':
        return AkColors.faint;
      case 'running':
        return AkColors.accent;
      default:
        return AkColors.muted;
    }
  }
}
