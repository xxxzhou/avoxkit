import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../core/task.dart';
import '../../core/task_store.dart';
import '../tokens.dart';
import '../widgets/live_preview.dart';
import '../widgets/panel.dart';
import '../widgets/waveform.dart';
import '../../core/i18n.dart';

/// 任务详情: 当前可见任务接管 ISurfaceRender/AudioTap, 离开页面即交还
class TaskDetailPage extends StatelessWidget {
  const TaskDetailPage({
    super.key,
    required this.taskStore,
    required this.taskId,
  });

  final TaskStore taskStore;
  final int taskId;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AkColors.bg,
      body: SafeArea(
        child: ListenableBuilder(
          listenable: taskStore,
          builder: (context, _) {
            final task = taskStore.taskById(taskId);
            if (task == null) {
              return _Missing(
                onBack: () => Navigator.of(context).maybePop(),
              );
            }
            final ahead = taskStore.queueAhead(task);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Header(
                  task: task,
                  onBack: () => Navigator.of(context).maybePop(),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(32, 20, 32, 40),
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 880),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _status(task, ahead),
                            const SizedBox(height: 16),
                            _visual(task, ahead),
                            const SizedBox(height: 16),
                            _meta(task),
                            if (task.state == 'failed') ...[
                              const SizedBox(height: 16),
                              _failure(task),
                            ],
                            const SizedBox(height: 16),
                            _actions(context, task),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _visual(TaskItem task, int ahead) {
    switch (task.kind) {
      case 'transcode':
      case 'trim':
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: AkLivePreview(
                  engine: taskStore.engine,
                  taskId: task.id,
                  active: task.isActive,
                  placeholder: _placeholder(_hint(task, ahead)),
                ),
              ),
            ),
            if (task.hasWave) ...[
              const SizedBox(height: 16),
              _wave(task),
            ],
          ],
        );
      case 'extract':
        if (task.hasWave) {
          return _wave(task, height: 150);
        }
        return _placeholderBox(
          icon: Icons.graphic_eq,
          text: _hint(task, ahead),
          height: 160,
        );
      case 'subtitle':
        return _placeholderBox(
          icon: Icons.subtitles_outlined,
          text: _hint(task, ahead),
          height: 140,
        );
      case 'image':
        return _placeholderBox(
          icon: Icons.auto_fix_high_outlined,
          text: _hint(task, ahead),
          height: 140,
        );
      default:
        return _placeholderBox(
          icon: Icons.layers_outlined,
          text: I18n.tr('直接封装只换容器，不重新编码，因此没有画面或波形。'),
          height: 140,
        );
    }
  }

  Widget _wave(TaskItem task, {double height = 88}) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
      decoration: BoxDecoration(
        color: AkColors.surface,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AkWaveform(
            peaks: task.wavePeaks,
            startMs: task.waveStartMs,
            totalMs: task.totalMs,
            currentMs: task.state == 'done' ? task.totalMs : task.currentMs,
            height: height,
          ),
          const SizedBox(height: 8),
          T('音频包络 · ${task.waveBucketMs}ms/格', style: AkText.micro),
        ],
      ),
    );
  }

  Widget _placeholderBox({
    required IconData icon,
    required String text,
    required double height,
  }) {
    return Container(
      height: height,
      decoration: BoxDecoration(
        color: AkColors.bgDeep,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AkColors.border),
      ),
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 26, color: AkColors.faint),
          const SizedBox(height: 10),
          T(
            text,
            style: AkText.body.copyWith(color: AkColors.muted),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _placeholder(String text) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.movie_outlined, size: 26, color: AkColors.faint),
        const SizedBox(height: 10),
        T(text, style: AkText.body.copyWith(color: AkColors.muted)),
      ],
    );
  }

  Widget _status(TaskItem task, int ahead) {
    final color = _stateColor(task.state);
    return Panel(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              StateDot(color: color),
              const SizedBox(width: 10),
              T(
                task.stateLabel,
                style: AkText.body.copyWith(
                  color: AkColors.textStrong,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (task.state == 'running' && task.stage != null) ...[
                const SizedBox(width: 8),
                T('· ${task.stageLabel}', style: AkText.micro),
              ],
              const Spacer(),
              if (task.state == 'queued')
                T(
                  ahead > 0 ? '前面还有 $ahead 个' : I18n.tr('即将开始'),
                  style: AkText.micro,
                )
              else if (task.state == 'running')
                T(
                  '${(task.progress * 100).round()}%',
                  style: AkText.mono.copyWith(fontSize: 12),
                ),
            ],
          ),
          if (task.state == 'queued') ...[
            const SizedBox(height: 10),
            T('全局队列一次处理一个任务，避免多个编码器抢 GPU。',
              style: AkText.micro,
            ),
          ] else if (task.state == 'running') ...[
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
            const SizedBox(height: 10),
            T(_timeLabel(task), style: AkText.micro),
          ],
        ],
      ),
    );
  }

  Widget _meta(TaskItem task) {
    return Panel(
      padding: const EdgeInsets.all(20),
      color: AkColors.surfaceAlt,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LabeledRow(label: I18n.tr('来源'), value: task.input ?? '—'),
          LabeledRow(label: I18n.tr('输出'), value: task.output ?? '—'),
          LabeledRow(label: I18n.tr('类型'), value: _kindLabel(task.kind)),
          LabeledRow(
            label: I18n.tr('归属'),
            value: task.groupId == null ? I18n.tr('单文件任务') : '批量组 #${task.groupId}',
          ),
          LabeledRow(label: I18n.tr('任务号'), value: '#${task.id}'),
        ],
      ),
    );
  }

  Widget _failure(TaskItem task) {
    return Panel(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          T(
            task.errorMessage ?? I18n.tr('任务失败'),
            style: AkText.body.copyWith(color: AkColors.danger),
          ),
          if (task.errorCode != null) ...[
            const SizedBox(height: 6),
            T('${task.errorCode} · ${task.errorDetail ?? ''}',
                style: AkText.micro),
          ],
          if (task.hint != null) ...[
            const SizedBox(height: 8),
            T(task.hint!, style: AkText.micro),
          ],
          const SizedBox(height: 8),
          TextButton(
            onPressed: taskStore.engine.openLogFolder,
            child: const T('打开日志目录'),
          ),
        ],
      ),
    );
  }

  Widget _actions(BuildContext context, TaskItem task) {
    return Row(
      children: [
        if (task.isActive)
          OutlinedButton.icon(
            onPressed: task.cancelRequested
                ? null
                : () => taskStore.cancel(task.id),
            icon: const Icon(Icons.stop_circle_outlined, size: 16),
            label: T(task.cancelRequested ? I18n.tr('取消中…') : I18n.tr('取消任务')),
          ),
        if (task.state == 'done' && task.output != null) ...[
          const SizedBox(width: 8),
          TextButton.icon(
            onPressed: () =>
                taskStore.engine.openFolder(p.dirname(task.output!)),
            icon: const Icon(Icons.folder_open, size: 16),
            label: const T('打开输出文件夹'),
          ),
        ],
        const Spacer(),
        TextButton(
          onPressed: () => Navigator.of(context).maybePop(),
          child: const T('返回'),
        ),
      ],
    );
  }

  static String _hint(TaskItem task, int ahead) {
    switch (task.state) {
      case 'queued':
        return ahead > 0 ? '排队中 · 前面还有 $ahead 个' : I18n.tr('排队中 · 即将开始');
      case 'running':
        if (task.kind == 'subtitle') {
          return task.stage == 'subtitle_extract'
              ? I18n.tr('正在读取字幕轨…')
              : I18n.tr('正在识别语音…');
        }
        return task.kind == 'extract' ? I18n.tr('等待音频数据…') : I18n.tr('等待首帧…');
      case 'done':
        if (task.kind == 'subtitle') {
          return I18n.tr('任务已结束，字幕文件已生成');
        }
        if (task.kind == 'extract') {
          return I18n.tr('没有波形数据（音频直拷或源无音轨）');
        }
        return I18n.tr('任务已结束，预览已释放');
      case 'failed':
        return I18n.tr('任务失败');
      case 'cancelled':
        return I18n.tr('已取消');
    }
    return '';
  }

  static String _kindLabel(String kind) {
    switch (kind) {
      case 'transcode':
        return I18n.tr('转码');
      case 'extract':
        return I18n.tr('提取音频');
      case 'remux':
        return I18n.tr('封装');
      case 'trim':
        return I18n.tr('截取片段');
      case 'subtitle':
        return I18n.tr('提取字幕');
      case 'image':
        return I18n.tr('图像修复');
    }
    return kind;
  }

  static String _timeLabel(TaskItem task) {
    final current = task.currentMs;
    final total = task.totalMs;
    if (current == null) {
      return I18n.tr('等待进度');
    }
    if (total == null || total <= 0) {
      return '已处理 ${_fmt(current)}';
    }
    return '已处理 ${_fmt(current)} / ${_fmt(total)}';
  }

  static String _fmt(int ms) {
    final totalSeconds = ms ~/ 1000;
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    final seconds = totalSeconds % 60;
    final mmss = '${minutes.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')}';
    return hours > 0 ? '${hours.toString().padLeft(2, '0')}:$mmss' : mmss;
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

class _Header extends StatelessWidget {
  const _Header({required this.task, required this.onBack});

  final TaskItem task;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 16, 32, 16),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AkColors.border)),
      ),
      child: Row(
        children: [
          IconButton(
            onPressed: onBack,
            icon: const Icon(Icons.arrow_back, color: AkColors.muted),
            tooltip: I18n.tr('返回'),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                T(
                  task.title,
                  style: AkText.pageTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                T('${TaskDetailPage._kindLabel(task.kind)} · 任务 #${task.id}'
                  '${task.groupId == null ? '' : ' · 组 #${task.groupId}'}',
                  style: AkText.micro,
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          T(
            task.stateLabel,
            style: AkText.body.copyWith(
              color: TaskDetailPage._stateColor(task.state),
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _Missing extends StatelessWidget {
  const _Missing({required this.onBack});

  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          T('任务不存在', style: AkText.body.copyWith(color: AkColors.muted)),
          const SizedBox(height: 8),
          TextButton(onPressed: onBack, child: const T('返回任务列表')),
        ],
      ),
    );
  }
}
