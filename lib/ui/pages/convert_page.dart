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
  final FolderSource _folder = FolderSource(
    extensions: const ['mkv', 'mp4', 'mov', 'avi', 'ts', 'flv', 'webm', 'wmv', 'm4v'],
    skipStemSuffixes: const ['converted'],
    rootTag: 'converted',
  );

  String? _inputPath;
  String? _outputPath;
  Map<String, dynamic>? _media;
  String? _probeError;
  bool _probing = false;

  String _codec = 'h264';
  double _quality = 60;
  bool _hardware = false;
  int? _lastTaskId;
  int? _lastGroupId;
  bool _submitting = false;

  @override
  void dispose() {
    _folder.dispose();
    super.dispose();
  }

  BatchPlan? _plan() => _folder.hasFolder
      ? _folder.planFor(extension: 'mp4', sidecarSuffix: '.converted')
      : null;

  Future<void> _pickInput() async {
    final file = await openFile(acceptedTypeGroups: const [_videoTypes]);
    if (file == null) {
      return;
    }
    final path = file.path;
    _folder.clear();
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
      final params = TaskStore.transcodeParams(
        codec: _codec,
        quality: _quality.round(),
        hardware: _hardware,
      );
      final group = widget.taskStore.createGroup(
        title: p.basename(_folder.root!),
        root: _folder.root!,
        kind: 'transcode',
        toolLabel: '格式转换',
        outputPolicy: _folder.policy.name,
        params: params,
        skipped: plan.skippedExisting,
      );
      final failures = submitBatch(
        store: widget.taskStore,
        groupId: group.id,
        plan: plan,
        submitOne: (input, output, groupId) => widget.taskStore.submit(
          input: input,
          output: output,
          codec: _codec,
          quality: _quality.round(),
          hardware: _hardware,
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
                title: '格式转换',
                description: '把一个或一整个文件夹的视频转成 H.264 / H.265。'
                    '文件只在本机处理。',
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
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(_folder.hasFolder ? '文件夹' : '源文件', style: AkText.panelTitle),
              const Spacer(),
              if (_inputPath != null && !_folder.hasFolder)
                TextButton(
                  onPressed: _pickInput,
                  child: const Text('重新选择'),
                ),
            ],
          ),
          const SizedBox(height: 16),
          if (_folder.hasFolder)
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
            _folder.hasFolder
                ? '同目录批量时默认跳过上次的 .converted 产物；输出已存在也会跳过。'
                : '支持 mkv / mp4 / mov / avi / ts / flv / webm / wmv。'
                    '输出默认放在源文件旁边。',
            style: AkText.micro,
          ),
          const SizedBox(height: 20),
          if (_lastGroupId != null)
            AkGroupCard(
              group: widget.taskStore.groupById(_lastGroupId)!,
              taskStore: widget.taskStore,
            )
          else
            AkLatestTask(
              taskStore: widget.taskStore,
              taskId: _lastTaskId,
            ),
        ],
      ),
    );
  }

  Widget _buildOptionsPanel(BatchPlan? plan) {
    final hardwareEnabled = widget.engine.hardwareAvailable;
    final folderMode = _folder.hasFolder;
    final canSubmit =
        !_submitting && (!folderMode || (plan?.pending.isNotEmpty ?? false));
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
                  : '开始转换',
            ),
          ),
        ],
      ),
    );
  }
}
