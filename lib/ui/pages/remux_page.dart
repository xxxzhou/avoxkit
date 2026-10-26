import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../core/batch.dart';
import '../../core/batch_submit.dart';
import '../../core/engine.dart';
import '../../core/folder_source.dart';
import '../../core/task_store.dart';
import '../tokens.dart';
import '../widgets/folder_card.dart';
import '../widgets/group_card.dart';
import '../widgets/media_source.dart';
import '../widgets/panel.dart';
import '../widgets/task_summary.dart';

const _videoTypes = XTypeGroup(
  label: '视频',
  extensions: [
    'mkv', 'mp4', 'mov', 'avi', 'ts', 'flv', 'webm', 'wmv', 'm4v', //
  ],
);

class RemuxPage extends StatefulWidget {
  const RemuxPage({
    super.key,
    required this.engine,
    required this.taskStore,
  });

  final Engine engine;
  final TaskStore taskStore;

  @override
  State<RemuxPage> createState() => _RemuxPageState();
}

class _RemuxPageState extends State<RemuxPage> {
  final FolderSource _folder = FolderSource(
    extensions: const ['mkv', 'mp4', 'mov', 'avi', 'ts', 'flv', 'webm', 'wmv', 'm4v'],
    skipStemSuffixes: const ['remux'],
    rootTag: 'remux',
  );

  String? _inputPath;
  String? _outputPath;
  Map<String, dynamic>? _media;
  String? _probeError;
  bool _probing = false;
  bool _outputAuto = true;

  String _format = 'mp4';
  int? _lastTaskId;
  int? _lastGroupId;
  bool _submitting = false;

  @override
  void dispose() {
    _folder.dispose();
    super.dispose();
  }

  BatchPlan? _plan() => _folder.hasFolder
      ? _folder.planFor(extension: _format, sidecarSuffix: '.remux')
      : null;

  String _suggestedOutput(String input) {
    return p.join(
      p.dirname(input),
      '${p.basenameWithoutExtension(input)}.remux.$_format',
    );
  }

  Future<void> _pickInput() async {
    final file = await openFile(acceptedTypeGroups: const [_videoTypes]);
    if (file == null) {
      return;
    }
    final path = file.path;
    _folder.clear();
    setState(() {
      _inputPath = path;
      _outputPath = _suggestedOutput(path);
      _outputAuto = true;
      _media = null;
      _probeError = null;
      _probing = true;
      _lastGroupId = null;
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

  Future<void> _pickFolder() async {
    final path = await getDirectoryPath();
    if (path == null) {
      return;
    }
    setState(() {
      _inputPath = null;
      _outputPath = null;
      _media = null;
      _probeError = null;
      _lastTaskId = null;
      _lastGroupId = null;
    });
    await _folder.pick(path);
  }

  Future<void> _pickOutput() async {
    final location = await getSaveLocation(
      suggestedName: _outputPath == null
          ? 'output.$_format'
          : p.basename(_outputPath!),
      acceptedTypeGroups: [
        XTypeGroup(label: _format.toUpperCase(), extensions: [_format]),
      ],
    );
    if (location == null) {
      return;
    }
    setState(() {
      _outputPath = location.path;
      _outputAuto = false;
    });
  }

  void _selectFormat(String value) {
    setState(() {
      _format = value;
      if (_outputAuto && _inputPath != null) {
        _outputPath = _suggestedOutput(_inputPath!);
      }
    });
  }

  Future<void> _submit() async {
    if (_submitting) {
      return;
    }
    if (_folder.hasFolder) {
      await _submitFolder();
      return;
    }
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
      final id = widget.taskStore.submitRemux(input: input, output: output);
      if (!mounted) {
        return;
      }
      setState(() {
        _lastTaskId = id;
        _lastGroupId = null;
      });
      _snack('已加入队列 · 任务 #$id');
    } catch (error) {
      if (!mounted) {
        return;
      }
      _snack(error is EngineException ? error.message : '$error');
    } finally {
      if (mounted) {
        setState(() => _submitting = false);
      }
    }
  }

  Future<void> _submitFolder() async {
    final plan = _plan();
    if (plan == null || plan.pending.isEmpty) {
      _snack('当前没有可处理的文件');
      return;
    }
    setState(() => _submitting = true);
    try {
      final params = TaskStore.remuxParams();
      final group = widget.taskStore.createGroup(
        title: p.basename(_folder.root!),
        root: _folder.root!,
        kind: 'remux',
        toolLabel: '封装转换',
        outputPolicy: _folder.policy.name,
        params: params,
        skipped: plan.skippedExisting,
      );
      final failures = submitBatch(
        store: widget.taskStore,
        groupId: group.id,
        plan: plan,
        submitOne: (input, output, groupId) => widget.taskStore.submitRemux(
          input: input,
          output: output,
          groupId: groupId,
        ),
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _lastGroupId = group.id;
        _lastTaskId = null;
      });
      _snack(
        failures == 0
            ? '已提交 ${plan.count} 个任务'
            : '已提交 ${plan.count - failures} 个，$failures 个被拒绝',
      );
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
    return ListenableBuilder(
      listenable: _folder,
      builder: (context, _) {
        final plan = _plan();
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(32, 32, 32, 40),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const PageHeader(
                title: '封装转换',
                description: '把一个或一整个文件夹的视频换容器，不重新编码。',
              ),
              const SizedBox(height: 24),
              LayoutBuilder(
                builder: (context, constraints) {
                  final wide = constraints.maxWidth >= 980;
                  final left = _buildSourcePanel();
                  final right = _buildOptionsPanel(plan);
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
                    children: [left, const SizedBox(height: 24), right],
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildSourcePanel() {
    final folderMode = _folder.hasFolder;
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(folderMode ? '文件夹' : '源文件', style: AkText.panelTitle),
              const Spacer(),
              if (_inputPath != null && !folderMode)
                TextButton(
                  onPressed: _pickInput,
                  child: const Text('重新选择'),
                ),
            ],
          ),
          const SizedBox(height: 16),
          if (folderMode)
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                FolderCard(
                  source: _folder,
                  plan: _plan(),
                  onPickAnother: _pickFolder,
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: _pickInput,
                    child: const Text('改成处理单个文件'),
                  ),
                ),
              ],
            )
          else if (_inputPath == null)
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AkSourcePicker(onTap: _pickInput),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: _pickFolder,
                  child: const Text('或处理一个文件夹'),
                ),
              ],
            )
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
                  AkMediaInfo(media: _media!),
                const SizedBox(height: 12),
                TextButton(
                  onPressed: _pickFolder,
                  child: const Text('改成处理整个文件夹'),
                ),
              ],
            ),
          const SizedBox(height: 20),
          const Divider(height: 1),
          const SizedBox(height: 16),
          Text(
            folderMode
                ? '文件夹里的视频逐个直拷；源编码装不进目标容器时该文件失败，组继续。'
                : '封装不重编码，音视频轨道原样搬进新容器。'
                    '源编码不被目标容器支持时会失败，换 MKV 通常最稳。',
            style: AkText.micro,
          ),
          const SizedBox(height: 20),
          if (_lastGroupId != null)
            AkGroupCard(
              group: widget.taskStore.groupById(_lastGroupId)!,
              taskStore: widget.taskStore,
            )
          else
            AkLatestTask(taskStore: widget.taskStore, taskId: _lastTaskId),
        ],
      ),
    );
  }

  Widget _buildOptionsPanel(BatchPlan? plan) {
    final video = AkMediaInfo.firstTrack(_media?['video']);
    final videoCodec = video?['codec'] as String?;
    final mp4Friendly =
        videoCodec == null || videoCodec == 'h264' || videoCodec == 'hevc';
    final folderMode = _folder.hasFolder;
    final canSubmit =
        !_submitting && (!folderMode || (plan?.pending.isNotEmpty ?? false));
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('输出容器', style: AkText.panelTitle),
          const SizedBox(height: 20),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'mp4', label: Text('MP4')),
              ButtonSegment(value: 'mkv', label: Text('MKV')),
            ],
            selected: {_format},
            showSelectedIcon: false,
            onSelectionChanged: (values) => _selectFormat(values.first),
          ),
          const SizedBox(height: 8),
          Text(
            _format == 'mp4'
                ? 'MP4 兼容性最好，适合 H.264 / H.265。'
                : 'MKV 能容纳几乎任何编码。',
            style: AkText.micro,
          ),
          if (_format == 'mp4' && !mp4Friendly) ...[
            const SizedBox(height: 10),
            Text(
              '源视频编码 ${videoCodec.toUpperCase()} 可能装不进 MP4，建议改用 MKV。',
              style: AkText.micro.copyWith(color: AkColors.accent),
            ),
          ],
          const SizedBox(height: 20),
          if (folderMode)
            OutputPolicyPicker(source: _folder)
          else ...[
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
          ],
          const SizedBox(height: 28),
          FilledButton(
            onPressed: canSubmit ? _submit : null,
            child: Text(
              _submitting
                  ? '提交中…'
                  : folderMode
                  ? (_lastGroupId != null
                        ? '已提交 ${plan?.count ?? 0} 个文件'
                        : plan == null || plan.pending.isEmpty
                        ? '没有可处理的文件'
                        : '开始处理 ${plan.count} 个文件')
                  : '开始封装',
            ),
          ),
        ],
      ),
    );
  }
}
