import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../core/app_paths.dart';
import '../../core/batch.dart';
import '../../core/engine.dart';
import '../../core/folder_source.dart';
import '../../core/model_store.dart';
import '../../core/subtitle_plan.dart';
import '../../core/task_store.dart';
import '../tokens.dart';
import '../widgets/folder_card.dart';
import '../widgets/group_card.dart';
import '../widgets/media_source.dart';
import '../widgets/panel.dart';
import '../widgets/task_summary.dart';
import '../../core/i18n.dart';

final _videoTypes = XTypeGroup(
  label: I18n.tr('视频'),
  extensions: ['mkv', 'mp4', 'mov', 'avi', 'ts', 'flv', 'webm', 'wmv', 'm4v'],
);

class SubtitlePage extends StatefulWidget {
  const SubtitlePage({
    super.key,
    required this.engine,
    required this.taskStore,
  });

  final Engine engine;
  final TaskStore taskStore;

  @override
  State<SubtitlePage> createState() => _SubtitlePageState();
}

class _SubtitlePageState extends State<SubtitlePage> {
  final FolderSource _folder = FolderSource(
    extensions: const [
      'mkv', 'mp4', 'mov', 'avi', 'ts', 'flv', 'webm', 'wmv', 'm4v', //
    ],
    skipStemSuffixes: const [],
    rootTag: 'subtitles',
    policy: OutputPolicy.sidecar,
  );

  late final SttModel _model;

  String? _inputPath;
  String? _outputPath;
  Map<String, dynamic>? _media;
  String? _probeError;
  bool _probing = false;

  bool _allowAsr = true;
  int? _trackIndex;

  int? _lastTaskId;
  int? _lastGroupId;
  bool _submitting = false;
  String? _submitProgress;

  @override
  void initState() {
    super.initState();
    _model = SttModel(root: widget.engine.modelsDir ?? '');
    _model.addListener(_onModelChanged);
    _model.check();
  }

  @override
  void dispose() {
    _model.removeListener(_onModelChanged);
    _model.dispose();
    _folder.dispose();
    super.dispose();
  }

  void _onModelChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  bool get _asrAvailable {
    final features = widget.engine.capabilities['features'];
    if (features is! Map) {
      return true;
    }
    final value = features['asr'];
    return value == null || value == true;
  }

  List<SubtitleTrackInfo> get _tracks =>
      subtitleTracksFromProbe(_media);

  SubtitlePlan? get _singlePlan {
    if (_inputPath == null || _media == null) {
      return null;
    }
    return buildSubtitlePlan(
      media: _media,
      trackIndex: _trackIndex,
      allowAsr: _allowAsr,
      modelReady: _model.ready,
    );
  }

  BatchPlan? _plan() => _folder.hasFolder
      ? _folder.planFor(
          extension: 'srt',
          extensionTag: 'srt',
          sidecarSuffix: '',
        )
      : null;

  String _suggestedOutput(String input) => AppPaths.suggested(
        input,
        '${p.basenameWithoutExtension(input)}.srt',
      );

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
      _media = null;
      _probeError = null;
      _probing = true;
      _trackIndex = null;
      _lastTaskId = null;
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
      _trackIndex = null;
      _lastTaskId = null;
      _lastGroupId = null;
    });
    await _folder.pick(path);
  }

  Future<void> _pickOutput() async {
    final input = _inputPath;
    if (input == null) {
      return;
    }
    final location = await getSaveLocation(
      suggestedName: p.basename(_suggestedOutput(input)),
      acceptedTypeGroups: const [
        XTypeGroup(label: 'SRT', extensions: ['srt']),
      ],
    );
    if (location == null) {
      return;
    }
    setState(() {
      _outputPath = p.setExtension(location.path, '.srt');
    });
  }

  Future<void> _downloadModel() async {
    if (_model.busy) {
      return;
    }
    final ok = await _model.download();
    if (!mounted) {
      return;
    }
    if (!ok && _model.error != null) {
      _snack(_model.error!);
    }
  }

  Future<void> _submit() async {
    if (_submitting || _model.busy) {
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
    var plan = _singlePlan;
    if (plan == null) {
      _snack(I18n.tr('还在读取媒体信息，请稍候'));
      return;
    }
    if (plan.error != null) {
      _snack(plan.error!);
      return;
    }
    if (plan.source == SubtitlePlanSource.speech && !_asrAvailable) {
      _snack(I18n.tr('语音识别插件未随包提供，无法生成字幕'));
      return;
    }
    if (plan.needsModel) {
      await _downloadModel();
      if (!mounted || !_model.ready) {
        return;
      }
      plan = _singlePlan;
      if (plan == null || !plan.canSubmit) {
        _snack(plan?.error ?? I18n.tr('模型就绪后仍无法开始，请重新选择文件'));
        return;
      }
    }
    setState(() => _submitting = true);
    try {
      final fixedOutput = p.setExtension(output, '.srt');
      final id = widget.taskStore.submitResolved(
        kind: 'subtitle',
        input: input,
        output: fixedOutput,
        params: plan.params(),
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _outputPath = fixedOutput;
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
    setState(() {
      _submitting = true;
      _submitProgress = '正在分析 0/${plan.count}';
    });
    try {
      final ready = <BatchItem, SubtitlePlan>{};
      var index = 0;
      var needsAsr = 0;
      for (final item in plan.pending) {
        index++;
        if (mounted && index % 3 == 0) {
          setState(() => _submitProgress = '正在分析 $index/${plan.count}');
        }
        try {
          final media = widget.engine.probe(item.entry.path);
          final itemPlan = buildSubtitlePlan(
            media: media,
            allowAsr: _allowAsr,
            modelReady: _model.ready,
          );
          if (!itemPlan.canSubmit && !itemPlan.needsModel) {
            continue;
          }
          if (itemPlan.source == SubtitlePlanSource.speech) {
            needsAsr++;
          }
          ready[item] = itemPlan;
        } catch (_) {
          // 单个文件探测失败不影响整组
        }
      }
      if (ready.isEmpty) {
        _snack(_allowAsr
            ? I18n.tr('没有可处理的文件（可能都没有音轨或字幕轨）')
            : I18n.tr('没有可处理的文件（没有内嵌文本字幕）'));
        return;
      }
      if (needsAsr > 0 && !_asrAvailable) {
        _snack(I18n.tr('语音识别插件未随包提供，无法生成字幕'));
        return;
      }
      if (needsAsr > 0 && !_model.ready) {
        setState(() => _submitProgress = I18n.tr('正在下载语音识别模型…'));
        await _downloadModel();
        if (!mounted || !_model.ready) {
          return;
        }
        // 模型就绪后重算识别项（此前 needsModel 的项已标记可提交）
        for (final entry in ready.entries.toList()) {
          if (entry.value.source == SubtitlePlanSource.speech) {
            ready[entry.key] = buildSubtitlePlan(
              media: widget.engine.probe(entry.key.entry.path),
              allowAsr: _allowAsr,
              modelReady: true,
            );
          }
        }
      }

      final group = widget.taskStore.createGroup(
        title: p.basename(_folder.root!),
        root: _folder.root!,
        kind: 'subtitle',
        toolLabel: I18n.tr('提取字幕'),
        outputPolicy: _folder.policy.name,
        params: {
          'subtitle': {'mode': 'auto', 'allow_asr': _allowAsr},
        },
        skipped: plan.skippedExisting,
      );
      var submitted = 0;
      var embedded = 0;
      var speech = 0;
      var rejected = 0;
      for (final entry in ready.entries) {
        final itemPlan = entry.value;
        if (!itemPlan.canSubmit) {
          continue;
        }
        try {
          widget.taskStore.submitResolved(
            kind: 'subtitle',
            input: entry.key.entry.path,
            output: entry.key.output,
            params: itemPlan.params(),
            groupId: group.id,
          );
          submitted++;
          if (itemPlan.source == SubtitlePlanSource.embedded) {
            embedded++;
          } else {
            speech++;
          }
        } catch (_) {
          rejected++;
        }
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _lastGroupId = group.id;
        _lastTaskId = null;
      });
      _snack('已提交 $submitted 个 · 内嵌 $embedded · 识别 $speech'
          '${rejected > 0 ? ' · 被拒 $rejected' : ''}'
          '${plan.skippedExisting > 0 ? ' · 跳过 ${plan.skippedExisting}' : ''}');
    } finally {
      if (mounted) {
        setState(() {
          _submitting = false;
          _submitProgress = null;
        });
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
                title: I18n.tr('提取字幕'),
                description: I18n.tr('有内嵌字幕轨就原样导出 SRT；没有时可用本地语音识别生成。' '文件不上传，识别模型只在用到时下载。'),
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
            AkSourcePicker(
              onFile: _pickInput,
              onFolder: _pickFolder,
              hint: I18n.tr('内嵌字幕直接导出；没有字幕时语音识别'),
            )
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
                  const SizedBox(height: 16),
                  _trackPicker(),
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
                ? I18n.tr('提交时逐个探测：有文本字幕轨就导出，没有时才按需识别。'
                    '已经存在同名 .srt 的文件会跳过。')
                : I18n.tr('输出默认放在源文件旁边；PGS/DVD 等图形字幕不能直接导出文字。'),
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

  Widget _trackPicker() {
    final tracks = _tracks;
    if (tracks.isEmpty) {
      return T('没有内嵌字幕轨${_allowAsr ? '，将用语音识别生成' : ''}。',
        style: AkText.micro.copyWith(color: AkColors.muted),
      );
    }
    final selected = _trackIndex;
    final value = tracks.any((track) => track.index == selected) ? selected : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        T('字幕轨', style: AkText.label),
        const SizedBox(height: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: AkColors.bgDeep,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: AkColors.border),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<int?>(
              value: value,
              isExpanded: true,
              dropdownColor: AkColors.bgDeep,
              items: [
                const DropdownMenuItem<int?>(
                  value: null,
                  child: T('自动（优先默认 / 中文）'),
                ),
                for (final track in tracks)
                  DropdownMenuItem<int?>(
                    value: track.index,
                    child: T(
                      track.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (next) => setState(() => _trackIndex = next),
            ),
          ),
        ),
        const SizedBox(height: 6),
        T('共 ${tracks.length} 条字幕轨；图形字幕需要语音识别。',
          style: AkText.micro,
        ),
      ],
    );
  }

  Widget _buildOptionsPanel(BatchPlan? plan) {
    final folderMode = _folder.hasFolder;
    final single = _singlePlan;
    final showModel = _allowAsr &&
        (folderMode
            ? (!_model.ready || _model.busy)
            : (single?.source == SubtitlePlanSource.speech || _model.busy));
    final singleReady =
        single != null && single.error == null && single.source != null;
    final canSubmit = !_submitting &&
        !_model.busy &&
        (!folderMode
            ? singleReady
            : ((plan?.pending.isNotEmpty ?? false) && _lastGroupId == null));
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          T('字幕来源', style: AkText.panelTitle),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    T('无内嵌字幕时用语音识别', style: AkText.body),
                    const SizedBox(height: 2),
                    T('本地 SenseVoice，支持中/英/日/韩/粤。',
                      style: AkText.micro,
                    ),
                  ],
                ),
              ),
              Switch(
                value: _allowAsr,
                onChanged: (value) => setState(() => _allowAsr = value),
              ),
            ],
          ),
          if (!folderMode && single != null) ...[
            const SizedBox(height: 12),
            _planNote(single),
          ],
          if (showModel) ...[
            const SizedBox(height: 16),
            _modelCard(),
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
          if (_submitProgress != null) ...[
            const SizedBox(height: 16),
            T(_submitProgress!, style: AkText.micro),
          ],
          const SizedBox(height: 28),
          FilledButton(
            onPressed: canSubmit ? _submit : null,
            child: T(
              _submitting
                  ? I18n.tr('提交中…')
                  : folderMode
                  ? (_lastGroupId != null
                        ? I18n.tr('已提交')
                        : plan == null || plan.pending.isEmpty
                        ? I18n.tr('没有可处理的文件')
                        : '开始处理 ${plan.count} 个文件')
                  : single?.needsModel == true
                  ? I18n.tr('下载模型并开始')
                  : single?.source == SubtitlePlanSource.speech
                  ? I18n.tr('开始识别')
                  : I18n.tr('提取字幕'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _planNote(SubtitlePlan plan) {
    final error = plan.error;
    final text = error ?? plan.reason;
    final color = error != null
        ? AkColors.danger
        : plan.needsModel
        ? AkColors.accent
        : AkColors.muted;
    return T(
      text,
      style: AkText.body.copyWith(color: color),
    );
  }

  Widget _modelCard() {
    if (_model.ready) {
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AkColors.bgDeep,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: AkColors.border),
        ),
        child: Row(
          children: [
            const StateDot(color: AkColors.state),
            const SizedBox(width: 8),
            Expanded(
              child: T('语音识别模型已就绪', style: AkText.micro),
            ),
            T(SttModel.license, style: AkText.micro),
          ],
        ),
      );
    }
    if (_model.busy) {
      final pct = (_model.progress * 100).clamp(0, 100).toStringAsFixed(0);
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AkColors.bgDeep,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: AkColors.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: T('正在下载语音识别模型', style: AkText.body),
                ),
                T('$pct%', style: AkText.mono),
              ],
            ),
            const SizedBox(height: 8),
            LinearProgressIndicator(
              value: _model.progress <= 0 ? null : _model.progress,
              minHeight: 3,
            ),
            const SizedBox(height: 4),
            T(SttModel.license, style: AkText.micro),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: _model.cancel,
                child: const T('取消下载'),
              ),
            ),
          ],
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AkColors.bgDeep,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AkColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          T('语音识别模型未下载', style: AkText.body),
          const SizedBox(height: 4),
          T('首次识别才下载，${SttModel.downloadSizeLabel}，不随安装包分发。',
            style: AkText.micro,
          ),
          const SizedBox(height: 2),
          T(SttModel.license, style: AkText.micro),
          if (_model.error != null) ...[
            const SizedBox(height: 8),
            T(
              _model.error!,
              style: AkText.micro.copyWith(color: AkColors.danger),
            ),
          ],
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: _downloadModel,
            child: const T('下载模型'),
          ),
        ],
      ),
    );
  }
}
