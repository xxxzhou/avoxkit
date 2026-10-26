import 'package:flutter/material.dart';

import '../../core/task.dart';
import '../../core/task_store.dart';
import '../tokens.dart';
import '../widgets/panel.dart';

class TasksPage extends StatelessWidget {
  const TasksPage({super.key, required this.taskStore});

  final TaskStore taskStore;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 32, 32, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const PageHeader(
            title: '任务',
            description: '转换队列和最近完成的任务。',
          ),
          const SizedBox(height: 24),
          Expanded(
            child: ListenableBuilder(
              listenable: taskStore,
              builder: (context, _) {
                final tasks = taskStore.tasks;
                if (tasks.isEmpty) {
                  return const _EmptyTasks();
                }
                return ListView.separated(
                  padding: const EdgeInsets.only(bottom: 40),
                  itemCount: tasks.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 12),
                  itemBuilder: (context, index) => _TaskCard(
                    task: tasks[index],
                    taskStore: taskStore,
                  ),
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
          Text('还没有任务', style: AkText.body.copyWith(color: AkColors.muted)),
          const SizedBox(height: 4),
          Text('在“格式转换”里选一个文件开始', style: AkText.micro),
        ],
      ),
    );
  }
}

class _TaskCard extends StatelessWidget {
  const _TaskCard({required this.task, required this.taskStore});

  final TaskItem task;
  final TaskStore taskStore;

  @override
  Widget build(BuildContext context) {
    final color = _stateColor(task.state);
    return Panel(
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
                child: Text(
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
              Text(
                '#${task.id} · ${task.stateLabel}',
                style: AkText.micro,
              ),
              if (task.isActive) ...[
                const SizedBox(width: 8),
                TextButton(
                  onPressed: task.cancelRequested
                      ? null
                      : () => taskStore.cancel(task.id),
                  child: Text(task.cancelRequested ? '取消中…' : '取消'),
                ),
              ],
            ],
          ),
          if (task.input != null) ...[
            const SizedBox(height: 6),
            Text(
              task.input!,
              style: AkText.micro,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          if (task.isActive) ...[
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
                Text(
                  task.stage != null ? task.stageLabel : '等待中',
                  style: AkText.micro,
                ),
                const Spacer(),
                Text(
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
                  child: Text(
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
            Text(
              task.errorMessage ?? '任务失败',
              style: AkText.body.copyWith(color: AkColors.danger),
            ),
            if (task.errorCode != null || task.errorDetail != null) ...[
              const SizedBox(height: 4),
              Text(
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
              child: const Text('打开日志目录'),
            ),
          ],
        ],
      ),
    );
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
