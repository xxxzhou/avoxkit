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
import '../widgets/task_visual.dart';
import '../../core/i18n.dart';

final _videoTypes = XTypeGroup(
  label: I18n.tr('视频'),
  extensions: ['mkv', 'mp4', 'mov', 'avi', 'ts', 'flv', 'webm', 'wmv', 'm4v'],
);

class ExtractPage extends StatefulWidget {
  const ExtractPage({
    super.key,
    required this.engine,
    required this.taskStore,
    this.active = true,
  });

  final Engine engine;
  final TaskStore taskStore;

  /// 页面不可见时收起原生预览窗, 否则它会盖住别的页并吃掉点击
  final bool active;

  @override
  State<ExtractPage> createState() => _ExtractPageState();
}

class _ExtractPageState extends State<ExtractPage> {
  final FolderSource _folder = FolderSource(
    extensions: const ['mkv', 'mp4', 'mov', 'avi', 'ts', 'flv', 'webm', 'wmv', 'm4v'],
    skipStemSuffixes: const [],
    rootTag: 'audio',
    policy: OutputPolicy.sidecar,
  );

  String? _inputPath;
  String? _outputPath;
  Map<String, dynamic>? _media;
  String? _probeError;
  bool _probing = false;
  bool _outputAuto = true;

  // 默认直拷: I18n.tr("提取音频")多数只是要原轨, 重编码一条 143 分钟的音轨要几分钟
  String _format = 'copy';
  int _bitrate = 192;
  int? _lastTaskId;
  int? _lastGroupId;
  bool _submitting = false;

  @override
  void dispose() {
    _folder.dispose();
    super.dispose();
  }

  Map<String, dynamic>? get _audioTrack =>
      AkMediaInfo.firstTrack(_media?['audio']);

  String get _targetExtension => _format == 'mp3' ? 'mp3' : 'm4a';

  String get _abiCodec => _format == 'copy'
      ? 'copy'
      : (_format == 'mp3' ? 'mp3' : 'aac');

  BatchPlan? _plan() => _folder.hasFolder
      ? _folder.planFor(extension: _targetExtension, sidecarSuffix: '')
      : null;

  String get _outputExtension {
    if (_format == 'mp3') {
      return 'mp3';
    }
    if (_format == 'copy') {
      return switch (_audioTrack?['codec']) {
        'mp3' => 'mp3',
        'aac' => 'm4a',
        // EAC3/DTS/TrueHD 等用 matroska 音频容器; 写 mkv 会和源文件同名
        _ => 'mka',
      };
    }
    return 'm4a';
  }

  String _suggestedOutput(String input) {
    final dir = p.dirname(input);
    final stem = p.basenameWithoutExtension(input);
    final ext = _outputExtension;
    var path = p.join(dir, '$stem.$ext');
    // 直拷的扩展名可能与源相同, 不能把源文件当输出(会报已存在)
    if (p.equals(path, input)) {
      path = p.join(dir, '$stem.extracted.$ext');
    }
    // 同名文件已存在时自动加序号; 用户仍可在I18n.tr("输出文件")里改名
    final outStem = p.basenameWithoutExtension(path);
    if (File(path).existsSync()) {
      for (var i = 1; i < 100; i++) {
        final candidate = p.join(dir, '$outStem ($i).$ext');
        if (!File(candidate).existsSync()) {
          return candidate;
        }
      }
    }
    return path;
  }

  Future<void> _pickInput() async {
    final file = await openFile(acceptedTypeGroups: [_videoTypes]);
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
        if (_outputAuto) {
          _outputPath = _suggestedOutput(path);
        }
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
      if (_format == 'copy') {
        _format = 'm4a';
      }
    });
    await _folder.pick(path);
  }

  Future<void> _pickOutput() async {
    final location = await getSaveLocation(
      suggestedName: _outputPath == null
          ? 'audio.$_outputExtension'
          : p.basename(_outputPath!),
      acceptedTypeGroups: [
        XTypeGroup(
          label: _outputExtension.toUpperCase(),
          extensions: [_outputExtension],
        ),
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
      _snack(I18n.tr('先选择一个视频文件'));
      return;
    }
    if (output == null || output.isEmpty) {
      _snack(I18n.tr('先选择输出位置'));
      return;
    }
    if (!File(input).existsSync()) {
      _snack(I18n.tr('输入文件不存在'));
      return;
    }
    setState(() => _submitting = true);
    try {
      final id = widget.taskStore.submitExtract(
        input: input,
        output: output,
        codec: _abiCodec,
        bitrateKbps: _format == 'copy' ? -1 : _bitrate,
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
      _snack(I18n.tr('当前没有可处理的文件'));
      return;
    }
    setState(() => _submitting = true);
    try {
      final params = TaskStore.extractParams(
        codec: _abiCodec,
        bitrateKbps: _bitrate,
      );
      final group = widget.taskStore.createGroup(
        title: p.basename(_folder.root!),
        root: _folder.root!,
        kind: 'extract',
        toolLabel: I18n.tr('提取音频'),
        outputPolicy: _folder.policy.name,
        params: params,
        skipped: plan.skippedExisting,
      );
      final failures = submitBatch(
        store: widget.taskStore,
        groupId: group.id,
        plan: plan,
        submitOne: (input, output, groupId) => widget.taskStore.submitExtract(
          input: input,
          output: output,
          codec: _abiCodec,
          bitrateKbps: _bitrate,
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
            : '已提交 ${plan.count - failures} 个，$failures 个被拒绝（可能没有音轨）',
      );
    } finally {
      if (mounted) {
        setState(() => _submitting = false);
      }
    }
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: T(message)),
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
              PageHeader(
                title: I18n.tr('提取音频'),
                description: I18n.tr('把一个或一整个文件夹的视频音轨单独导出。' '文件只在本机处理。'),
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
    final hasAudio = _audioTrack != null;
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              T(folderMode ? I18n.tr('文件夹') : I18n.tr('源文件'), style: AkText.panelTitle),
              const Spacer(),
              if (_inputPath != null && !folderMode)
                TextButton(
                  onPressed: _pickInput,
                  child: const T('重新选择'),
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
                    child: const T('改成处理单个文件'),
                  ),
                ),
              ],
            )
          else if (_inputPath == null)
            AkSourcePicker(onFile: _pickInput, onFolder: _pickFolder)
          else
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                T(
                  p.basename(_inputPath!),
                  style: AkText.body.copyWith(
                    color: AkColors.textStrong,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                T(
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
                  T(
                    _probeError!,
                    style: AkText.body.copyWith(color: AkColors.danger),
                  )
                else if (_media != null) ...[
                  AkMediaInfo(media: _media!),
                  if (!hasAudio) ...[
                    const SizedBox(height: 12),
                    T('这个文件没有音轨，无法提取。',
                      style: AkText.body.copyWith(color: AkColors.danger),
                    ),
                  ],
                ],
                const SizedBox(height: 12),
                TextButton(
                  onPressed: _pickFolder,
                  child: const T('改成处理整个文件夹'),
                ),
              ],
            ),
          const SizedBox(height: 20),
          const Divider(height: 1),
          const SizedBox(height: 16),
          T(
            folderMode
                ? I18n.tr('文件夹里没有音轨的视频会在提交时被拒绝，不影响其他文件。')
                : I18n.tr('输出默认放在源文件旁边；原始音轨直拷最快，M4A/MP3 会重新编码。'),
            style: AkText.micro,
          ),
          const SizedBox(height: 20),
          if ((_lastTaskId != null || _lastGroupId != null) && widget.active)
            ListenableBuilder(
              listenable: widget.taskStore,
              builder: (context, _) {
                final task = _lastTaskId != null
                    ? widget.taskStore.taskById(_lastTaskId)
                    : widget.taskStore.previewTaskOfGroup(_lastGroupId);
                if (task == null) {
                  return const SizedBox.shrink();
                }
                return Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: AkTaskVisual(engine: widget.engine, task: task),
                );
              },
            ),
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
    final folderMode = _folder.hasFolder;
    final hasAudio = _audioTrack != null;
    final audioCodec = _audioTrack?['codec'];
    final canSubmit = !_submitting &&
        (!folderMode
            ? hasAudio
            : ((plan?.pending.isNotEmpty ?? false) && _lastGroupId == null));
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          T('输出设置', style: AkText.panelTitle),
          const SizedBox(height: 20),
          T('音频格式', style: AkText.label),
          const SizedBox(height: 8),
          SegmentedButton<String>(
            segments: [
              const ButtonSegment(value: 'm4a', label: T('M4A')),
              const ButtonSegment(value: 'mp3', label: T('MP3')),
              if (!folderMode)
                const ButtonSegment(value: 'copy', label: T('原始音轨')),
            ],
            selected: {_format},
            showSelectedIcon: false,
            onSelectionChanged: (values) => _selectFormat(values.first),
          ),
          const SizedBox(height: 8),
          T(
            folderMode
                ? I18n.tr('批量导出按扩展名生成 M4A 或 MP3；原始音轨需逐文件探测容器，暂不提供。')
                : _format == 'copy'
                ? I18n.tr('不重新编码，速度最快；目标容器不支持时会自动转码。')
                : I18n.tr('AAC 兼容性好；MP3 通用性最强。会按码率重新编码，比直拷慢。'),
            style: AkText.micro,
          ),
          if (_format != 'copy') ...[
            const SizedBox(height: 20),
            Row(
              children: [
                T('码率', style: AkText.label),
                const Spacer(),
                T(
                  '$_bitrate kbps',
                  style: AkText.mono.copyWith(color: AkColors.textStrong),
                ),
              ],
            ),
            const SizedBox(height: 4),
            SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 128, label: T('128')),
                ButtonSegment(value: 192, label: T('192')),
                ButtonSegment(value: 256, label: T('256')),
                ButtonSegment(value: 320, label: T('320')),
              ],
              selected: {_bitrate},
              showSelectedIcon: false,
              onSelectionChanged: (values) =>
                  setState(() => _bitrate = values.first),
            ),
          ],
          if (_format == 'copy' && audioCodec is String) ...[
            const SizedBox(height: 12),
            T('源音轨：${audioCodec.toUpperCase()}', style: AkText.micro),
          ],
          const SizedBox(height: 20),
          if (folderMode)
            OutputPolicyPicker(source: _folder)
          else ...[
            T('输出文件', style: AkText.label),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: T(
                    _outputPath == null ? I18n.tr('尚未选择') : p.basename(_outputPath!),
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
                  child: const T('选择'),
                ),
              ],
            ),
            if (_outputPath != null) ...[
              const SizedBox(height: 4),
              T(
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
            child: T(
              _submitting
                  ? I18n.tr('提交中…')
                  : folderMode
                  ? (_lastGroupId != null
                        ? '已提交 ${plan?.count ?? 0} 个文件'
                        : plan == null || plan.pending.isEmpty
                        ? I18n.tr('没有可处理的文件')
                        : '开始处理 ${plan.count} 个文件')
                  : I18n.tr('开始提取'),
            ),
          ),
        ],
      ),
    );
  }
}
