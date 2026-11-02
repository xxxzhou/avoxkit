import 'package:flutter/material.dart';

import '../../core/task.dart';
import '../../core/task_group.dart';
import '../../core/task_store.dart';
import '../tokens.dart';
import 'panel.dart';
import '../../core/i18n.dart';

/// 批量组的进度卡; 工具页用紧凑版, 任务页展开子任务。
/// 子任务超过阈值时默认折叠, 展开后走组内虚拟滚动。
class AkGroupCard extends StatefulWidget {
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
  State<AkGroupCard> createState() => _AkGroupCardState();
}

class _AkGroupCardState extends State<AkGroupCard> {
  static const _collapseThreshold = 20;

  bool _expanded = false;

  TaskGroup get group => widget.group;
  TaskStore get taskStore => widget.taskStore;

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
        final interrupted =
            tasks.where((task) => task.state == 'interrupted').length;
        final active = tasks.where((task) => task.isActive).length;
        final finished = done + failed + cancelled + interrupted;
        final progress = tasks.isEmpty ? 0.0 : finished / tasks.length;
        final color = active > 0
            ? AkColors.accent
            : (failed > 0 && done == 0 ? AkColors.danger : AkColors.state);
        final summary = [
          I18n.tr('完成 $done'),
          I18n.tr('失败 $failed'),
          I18n.tr('进行中 $running'),
          if (queued > 0) I18n.tr('排队 $queued'),
          if (interrupted > 0) I18n.tr('中断 $interrupted'),
          if (group.skipped > 0) I18n.tr('跳过 ${group.skipped}'),
        ].join(' · ');
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
                      '${group.toolLabel} · ${group.title}',
                      style: AkText.body.copyWith(color: AkColors.textStrong),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (active > 0)
                    TextButton(
                      onPressed: () => taskStore.cancelGroup(group.id),
                      child: const T('取消整组'),
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
              T(summary, style: AkText.micro),
              if (interrupted > 0) ...[
                const SizedBox(height: 8),
                OutlinedButton(
                  onPressed: () {
                    final requeued =
                        taskStore.requeueGroupInterrupted(group.id);
                    if (requeued == 0) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: T('没有可重新排队的中断项')),
                      );
                    }
                  },
                  child: const T('重新排队中断项'),
                ),
              ],
              if (failed > 0) ...[
                const SizedBox(height: 8),
                OutlinedButton(
                  onPressed: () {
                    final retried = taskStore.retryGroupFailed(group.id);
                    if (retried == 0) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: T('没有可重试的任务')),
                      );
                    }
                  },
                  child: const T('重试失败项'),
                ),
              ],
              if (widget.showTasks && tasks.isNotEmpty) ...[
                const SizedBox(height: 12),
                const Divider(height: 1),
                const SizedBox(height: 8),
                if (tasks.length > _collapseThreshold && !_expanded)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      onPressed: () => setState(() => _expanded = true),
                      child: T('展开 ${tasks.length} 项任务'),
                    ),
                  )
                else if (tasks.length > _collapseThreshold)
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        height: 320,
                        child: ListView.builder(
                          itemCount: tasks.length,
                          itemBuilder: (context, index) =>
                              _taskRow(tasks[index]),
                        ),
                      ),
                      TextButton(
                        onPressed: () => setState(() => _expanded = false),
                        child: const T('收起'),
                      ),
                    ],
                  )
                else
                  for (final task in tasks) _taskRow(task),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _taskRow(TaskItem task) {
    return InkWell(
      onTap: widget.onOpenTask == null
          ? null
          : () => widget.onOpenTask!(task.id),
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
        child: Row(
          children: [
            StateDot(
              color: switch (task.state) {
                'done' => AkColors.state,
                'failed' => AkColors.danger,
                'cancelled' => AkColors.faint,
                'interrupted' => AkColors.faint,
                'running' => AkColors.accent,
                _ => AkColors.muted,
              },
              size: 6,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: T(
                task.title,
                style: AkText.micro,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Text(
              task.state == 'failed'
                  ? (task.errorCode ?? I18n.tr('失败'))
                  : task.state == 'queued'
                      ? I18n.tr('前面 ${taskStore.queueAhead(task)} 个')
                      : task.stateLabel,
              style: AkText.micro,
            ),
            if (widget.onOpenTask != null)
              const Icon(Icons.chevron_right, size: 14, color: AkColors.faint),
          ],
        ),
      ),
    );
  }
}
