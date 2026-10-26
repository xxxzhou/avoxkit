import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../core/engine.dart';
import '../../core/task.dart';
import '../../core/task_store.dart';
import '../tokens.dart';
import '../widgets/panel.dart';

const _videoTypes = XTypeGroup(
  label: '视频',
  extensions: ['mkv', 'mp4', 'mov', 'avi', 'ts', 'flv', 'webm', 'wmv', 'm4v'],
);

const _mp4Type = XTypeGroup(label: 'MP4', extensions: ['mp4']);

class ConvertPage extends StatefulWidget {
  const ConvertPage({
    super.key,
    required this.engine,
    required this.taskStore,
  });

  final Engine engine;
  final TaskStore taskStore;

  @override
  State<ConvertPage> createState() => _ConvertPageState();
}

class _ConvertPageState extends State<ConvertPage> {
  String? _inputPath;
  String? _outputPath;
  Map<String, dynamic>? _media;
  String? _probeError;
  bool _probing = false;

  String _codec = 'h264';
  double _quality = 60;
  bool _hardware = false;
  int? _lastTaskId;
  bool _submitting = false;

  Future<void> _pickInput() async {
    final file = await openFile(acceptedTypeGroups: const [_videoTypes]);
    if (file == null) {
      return;
    }
    final path = file.path;
    final suggestedOutput = p.join(
      p.dirname(path),
      '${p.basenameWithoutExtension(path)}.converted.mp4',
    );
    setState(() {
      _inputPath = path;
      _outputPath = suggestedOutput;
      _media = null;
      _probeError = null;
      _probing = true;
    });
    try {
      final media = widget.engine.probe(path);
      if (!mounted) {
        return;
      }
      setState(() {
        _media = media;
        _probing = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _probeError = error is EngineException ? error.message : '$error';
        _probing = false;
      });
    }
  }

  Future<void> _pickOutput() async {
    final name = _inputPath == null
        ? 'output.mp4'
        : '${p.basenameWithoutExtension(_inputPath!)}.converted.mp4';
    final location = await getSaveLocation(
      suggestedName: name,
      acceptedTypeGroups: const [_mp4Type],
    );
    if (location == null) {
      return;
    }
    setState(() => _outputPath = location.path);
  }

  Future<void> _submit() async {
    final input = _inputPath;
    final output = _outputPath;
    if (input == null) {
      _snack('先选择一个视频文件');
      return;
    }
    if (output == null || output.isEmpty) {
      _snack('先选择输出位置');
      return;
    }
    if (!File(input).existsSync()) {
      _snack('输入文件不存在');
      return;
    }
    setState(() => _submitting = true);
    try {
      final id = widget.taskStore.submit(
        input: input,
        output: output,
        codec: _codec,
        quality: _quality.round(),
        hardware: _hardware,
      );
      if (!mounted) {
        return;
      }
      setState(() => _lastTaskId = id);
      _snack('已加入队列 · 任务 #$id');
    } catch (error) {
      if (!mounted) {
        return;
      }
      final message = error is EngineException ? error.message : '$error';
      _snack(message);
    } finally {
      if (mounted) {
        setState(() => _submitting = false);
      }
    }
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(32, 32, 32, 40),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const PageHeader(
            title: '格式转换',
            description: '把一个视频转成 H.264 / H.265。文件只在本机处理。',
          ),
          const SizedBox(height: 24),
          LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= 980;
              final left = _buildSourcePanel();
              final right = _buildOptionsPanel();
              if (wide) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 3, child: left),
                    const SizedBox(width: 24),
                    Expanded(flex: 2, child: right),
                  ],
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  left,
                  const SizedBox(height: 24),
                  right,
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildSourcePanel() {
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('源文件', style: AkText.panelTitle),
              const Spacer(),
              if (_inputPath != null)
                TextButton(
                  onPressed: _pickInput,
                  child: const Text('重新选择'),
                ),
            ],
          ),
          const SizedBox(height: 16),
          if (_inputPath == null)
            _DropLikeButton(onTap: _pickInput)
          else
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  p.basename(_inputPath!),
                  style: AkText.body.copyWith(
                    color: AkColors.textStrong,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                Text(
                  p.dirname(_inputPath!),
                  style: AkText.micro,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 20),
                if (_probing)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: LinearProgressIndicator(minHeight: 2),
                  )
                else if (_probeError != null)
                  Text(
                    _probeError!,
                    style: AkText.body.copyWith(color: AkColors.danger),
                  )
                else if (_media != null)
                  _MediaInfo(media: _media!),
              ],
            ),
          const SizedBox(height: 20),
          const Divider(height: 1),
          const SizedBox(height: 16),
          Text(
            '支持 mkv / mp4 / mov / avi / ts / flv / webm / wmv。'
            '输出默认放在源文件旁边。',
            style: AkText.micro,
          ),
          const SizedBox(height: 20),
          _LatestTask(
            taskStore: widget.taskStore,
            taskId: _lastTaskId,
          ),
        ],
      ),
    );
  }

  Widget _buildOptionsPanel() {
    final hardwareEnabled = widget.engine.hardwareAvailable;
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('输出设置', style: AkText.panelTitle),
          const SizedBox(height: 20),
          Text('视频编码', style: AkText.label),
          const SizedBox(height: 8),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'h264', label: Text('H.264')),
              ButtonSegment(value: 'hevc', label: Text('H.265')),
            ],
            selected: {_codec},
            showSelectedIcon: false,
            onSelectionChanged: (values) {
              setState(() => _codec = values.first);
            },
            style: ButtonStyle(
              visualDensity: VisualDensity.compact,
              textStyle: WidgetStateProperty.all(
                const TextStyle(fontSize: 12),
              ),
            ),
          ),
          const SizedBox(height: 24),
          Row(
            children: [
              Text('质量', style: AkText.label),
              const Spacer(),
              Text(
                _quality.round().toString(),
                style: AkText.mono.copyWith(color: AkColors.textStrong),
              ),
            ],
          ),
          Slider(
            value: _quality,
            min: 0,
            max: 100,
            divisions: 20,
            onChanged: (value) => setState(() => _quality = value),
          ),
          Text('数值越大越清晰、文件越大', style: AkText.micro),
          const SizedBox(height: 12),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('硬件编码', style: AkText.label),
            subtitle: Text(
              !hardwareEnabled
                  ? '本机未检测到可用硬编，将使用软件编码'
                  : _hardware
                  ? '更快，画质与体积略逊软编；失败时自动回退'
                  : '默认软编：画质与体积更可控，速度较慢',
              style: AkText.micro,
            ),
            value: _hardware && hardwareEnabled,
            onChanged: hardwareEnabled
                ? (value) => setState(() => _hardware = value)
                : null,
          ),
          const SizedBox(height: 16),
          Text('输出文件', style: AkText.label),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Text(
                  _outputPath == null ? '尚未选择' : p.basename(_outputPath!),
                  style: AkText.body.copyWith(
                    color: _outputPath == null
                        ? AkColors.faint
                        : AkColors.text,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: _pickOutput,
                child: const Text('选择'),
              ),
            ],
          ),
          if (_outputPath != null) ...[
            const SizedBox(height: 4),
            Text(
              p.dirname(_outputPath!),
              style: AkText.micro,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          const SizedBox(height: 28),
          FilledButton(
            onPressed: _submitting ? null : _submit,
            child: Text(_submitting ? '提交中…' : '开始转换'),
          ),
        ],
      ),
    );
  }
}

class _DropLikeButton extends StatelessWidget {
  const _DropLikeButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 36, horizontal: 20),
        decoration: BoxDecoration(
          color: AkColors.bgDeep,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AkColors.border),
        ),
        child: Column(
          children: [
            const Icon(Icons.add, color: AkColors.accent, size: 24),
            const SizedBox(height: 10),
            Text('选择视频文件', style: AkText.body),
            const SizedBox(height: 4),
            Text('文件不会离开本机', style: AkText.micro),
          ],
        ),
      ),
    );
  }
}

class _MediaInfo extends StatelessWidget {
  const _MediaInfo({required this.media});

  final Map<String, dynamic> media;

  @override
  Widget build(BuildContext context) {
    final video = _first(media['video']);
    final audio = _first(media['audio']);
    final duration = (media['duration_ms'] as num?)?.toInt() ?? 0;
    return Column(
      children: [
        LabeledRow(label: '时长', value: _duration(duration)),
        LabeledRow(
          label: '视频',
          value: video == null
              ? '无'
              : '${_upper(video['codec'])} · ${video['width']}×${video['height']}'
                  '${_fps(video['fps'])}',
        ),
        LabeledRow(
          label: '音频',
          value: audio == null
              ? '无'
              : '${_upper(audio['codec'])} · ${audio['channels']} 声道 · '
                  '${audio['sample_rate']} Hz',
        ),
        LabeledRow(
          label: '容器',
          value: '${media['format'] ?? '未知'}',
        ),
      ],
    );
  }

  static Map<String, dynamic>? _first(dynamic value) {
    if (value is List && value.isNotEmpty && value.first is Map) {
      return (value.first as Map).cast<String, dynamic>();
    }
    return null;
  }

  static String _upper(dynamic value) =>
      value == null ? '未知' : value.toString().toUpperCase();

  static String _fps(dynamic value) {
    if (value is num && value > 0) {
      return ' · ${value.toStringAsFixed(value % 1 == 0 ? 0 : 2)} fps';
    }
    return '';
  }

  static String _duration(int ms) {
    final total = (ms / 1000).round();
    final minutes = total ~/ 60;
    final seconds = total % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }
}

class _LatestTask extends StatelessWidget {
  const _LatestTask({required this.taskStore, this.taskId});

  final TaskStore taskStore;
  final int? taskId;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: taskStore,
      builder: (context, _) {
        final task = taskStore.taskById(taskId) ?? taskStore.latest;
        if (task == null) {
          return const SizedBox.shrink();
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('最近任务', style: AkText.label),
            const SizedBox(height: 10),
            _TaskSummary(task: task, taskStore: taskStore),
          ],
        );
      },
    );
  }
}

class _TaskSummary extends StatelessWidget {
  const _TaskSummary({required this.task, required this.taskStore});

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
                child: Text(
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
                  child: Text(task.cancelRequested ? '取消中…' : '取消'),
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
          if (task.state == 'failed') ...[
            const SizedBox(height: 8),
            Text(
              task.errorMessage ?? '任务失败',
              style: AkText.body.copyWith(color: AkColors.danger),
            ),
            if (task.errorCode != null)
              Text(task.errorCode!, style: AkText.micro),
          ],
          if (task.state == 'done' && task.output != null) ...[
            const SizedBox(height: 8),
            Text(
              task.output!,
              style: AkText.micro,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }
}
