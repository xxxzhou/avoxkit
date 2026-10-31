import 'package:flutter/material.dart';

import '../../core/engine.dart';
import '../../core/task.dart';
import '../tokens.dart';
import 'live_preview.dart';
import 'waveform.dart';
import '../../core/i18n.dart';

/// 预览跟I18n.tr("实际在转什么")走: 视频重编→画面, 仅音频重编→波形, 都直拷→进度
enum TaskVisualMode { video, audio, progress }

TaskVisualMode taskVisualMode(TaskItem task) {
  if (task.kind == 'transcode') {
    // video_copy 只搬视频包, 录制器没有可渲染帧; all/audio_copy 都会重编视频
    if (task.params?['trans_mode'] != 'video_copy') {
      return TaskVisualMode.video;
    }
  }
  if (task.hasWave) {
    return TaskVisualMode.audio;
  }
  return TaskVisualMode.progress;
}

class AkTaskVisual extends StatelessWidget {
  const AkTaskVisual({
    super.key,
    required this.engine,
    required this.task,
    this.active = true,
  });

  final Engine engine;
  final TaskItem task;

  /// 页面不可见时收起原生预览窗
  final bool active;

  @override
  Widget build(BuildContext context) {
    switch (taskVisualMode(task)) {
      case TaskVisualMode.video:
        final preview = AkLivePreview(
          engine: engine,
          taskId: task.id,
          // 终态任务不再占着原生窗, 露出占位, 也避免残留最后一帧
          active: active && task.isActive,
          placeholder: T(
            _videoHint,
            style: AkText.body.copyWith(color: AkColors.muted),
          ),
        );
        if (!task.hasWave) {
          return preview;
        }
        // 视频和音频都重编: 画面下面同时显示音频包络
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            preview,
            const SizedBox(height: 12),
            _WaveBox(task: task),
          ],
        );
      case TaskVisualMode.audio:
        if (task.hasWave) {
          return _WaveBox(task: task);
        }
        return _ProgressBox(task: task, note: I18n.tr('等待音频包络…'));
      case TaskVisualMode.progress:
        return _ProgressBox(task: task);
    }
  }

  String get _videoHint => switch (task.state) {
        'queued' => I18n.tr('排队中'),
        'running' => I18n.tr('等待首帧…'),
        'done' => I18n.tr('已完成'),
        'failed' => I18n.tr('任务失败'),
        'cancelled' => I18n.tr('已取消'),
        _ => I18n.tr('等待预览…'),
      };
}

class _WaveBox extends StatelessWidget {
  const _WaveBox({required this.task});

  final TaskItem task;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
      decoration: BoxDecoration(
        color: AkColors.bgDeep,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AkColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AkWaveform(
            peaks: task.wavePeaks,
            startMs: task.waveStartMs,
            totalMs: task.totalMs,
            currentMs: task.isTerminal ? task.totalMs : task.currentMs,
            height: 96,
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              T('音频包络 · ${task.waveBucketMs}ms/格', style: AkText.micro),
              const Spacer(),
              if (task.state == 'running')
                T(
                  '${(task.progress * 100).round()}%',
                  style: AkText.mono.copyWith(fontSize: 11),
                )
              else
                T(task.stateLabel, style: AkText.micro),
            ],
          ),
        ],
      ),
    );
  }
}

class _ProgressBox extends StatelessWidget {
  const _ProgressBox({required this.task, this.note});

  final TaskItem task;
  final String? note;

  @override
  Widget build(BuildContext context) {
    final running = task.state == 'running';
    final label = note ??
        (task.state == 'running'
            ? (task.stage != null ? task.stageLabel : I18n.tr('处理中'))
            : task.stateLabel);
    return Container(
      height: 132,
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
      decoration: BoxDecoration(
        color: AkColors.bgDeep,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AkColors.border),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          T(
            label,
            style: AkText.body.copyWith(color: AkColors.muted),
            textAlign: TextAlign.center,
          ),
          if (running) ...[
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
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                T(
                  '${(task.progress * 100).round()}%',
                  style: AkText.mono.copyWith(fontSize: 11),
                ),
                if (_time(task.currentMs, task.totalMs).isNotEmpty) ...[
                  const SizedBox(width: 8),
                  T(
                    _time(task.currentMs, task.totalMs),
                    style: AkText.micro,
                  ),
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }

  String _time(int? current, int? total) {
    if (current == null || current < 0 || total == null || total <= 0) {
      return '';
    }
    return '${_fmt(current)} / ${_fmt(total)}';
  }

  String _fmt(int ms) {
    final d = Duration(milliseconds: ms);
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(h > 0 ? 2 : 1, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }
}
