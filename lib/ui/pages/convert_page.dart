import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../core/batch.dart';
import '../../core/convert_plan.dart';
import '../../core/engine.dart';
import '../../core/folder_scan.dart';
import '../../core/folder_source.dart';
import '../../core/task_store.dart';
import '../tokens.dart';
import '../widgets/folder_card.dart';
import '../widgets/group_card.dart';
import '../widgets/task_visual.dart';
import '../widgets/media_source.dart';
import '../widgets/panel.dart';
import '../widgets/task_summary.dart';

const _videoTypes = XTypeGroup(
  label: '视频',
  extensions: ['mkv', 'mp4', 'mov', 'avi', 'ts', 'flv', 'webm', 'wmv', 'm4v'],
);

class ConvertPage extends StatefulWidget {
  const ConvertPage({
    super.key,
    required this.engine,
    required this.taskStore,
    this.active = true,
  });

  final Engine engine;
  final TaskStore taskStore;

  /// IndexedStack 子页离开视野时原生预览窗必须收起, 否则会悬浮在别的页面上
  final bool active;

  @override
  State<ConvertPage> createState() => _ConvertPageState();
}

class _ConvertPageState extends State<ConvertPage> {
  final FolderSource _folder = FolderSource(
    extensions: const [
      'mkv', 'mp4', 'mov', 'avi', 'ts', 'flv', 'webm', 'wmv', 'm4v', //
    ],
    skipStemSuffixes: const ['converted'],
    rootTag: 'converted',
  );

  String? _inputPath;
  String? _outputPath;
  Map<String, dynamic>? _media;
  String? _probeError;
  bool _probing = false;
  bool _outputAuto = true;

  // 默认全部跟源一致; 改动任何一项才会产生任务
  String _container = 'source';
  String _video = 'source';
  int? _height;
  String _audio = 'source';
  int _audioBitrate = -1;
  double _quality = 60;
  bool _hardware = false;

  int? _lastTaskId;
  int? _lastGroupId;
  bool _submitting = false;
  String? _submitProgress;

  late final bool _h264Available;
  late final bool _h265Available;
  late final bool _aacAvailable;
  late final bool _mp3Available;

  @override
  void initState() {
    super.initState();
    _h264Available = _encoderAvailable('h264');
    _h265Available = _encoderAvailable('hevc');
    _aacAvailable = _encoderAvailable('aac');
    _mp3Available = _encoderAvailable('mp3');
  }

  bool _encoderAvailable(String codec) {
    try {
      return widget.engine.encoderAvailable(codec);
    } catch (_) {
      return false;
    }
  }

  @override
  void dispose() {
    _folder.dispose();
    super.dispose();
  }

  ConvertSettings get _settings => ConvertSettings(
        container: _container,
        video: _video,
        height: _height,
        audio: _audio,
        audioBitrateKbps: _audioBitrate,
        quality: _quality.round(),
        hardware: _hardware,
      );

  SourceMedia? get _source {
    final path = _inputPath;
    final media = _media;
    if (path == null || media == null) {
      return null;
    }
    return SourceMedia.fromProbe(path, media);
  }

  ConversionPlan? get _singlePlan {
    final source = _source;
    if (source == null) {
      return null;
    }
    return buildConversionPlan(
      source: source,
      settings: _settings,
      h264Available: _h264Available,
      h265Available: _h265Available,
      aacAvailable: _aacAvailable,
      mp3Available: _mp3Available,
    );
  }

  String _extensionFor(String path) {
    if (_container != 'source') {
      return _container;
    }
    final ext = p.extension(path).toLowerCase().replaceFirst('.', '');
    return ext.isEmpty ? 'mp4' : ext;
  }

  String _extensionForEntry(FolderEntry entry) => _extensionFor(entry.path);

  BatchPlan? _plan() => _folder.hasFolder
      ? _folder.planFor(
          extensionFrom: _extensionForEntry,
          extensionTag: _container,
          sidecarSuffix: '.converted',
        )
      : null;

  String _suggestedOutput(String input) => p.join(
        p.dirname(input),
        '${p.basenameWithoutExtension(input)}.converted.'
        '${_extensionFor(input)}',
      );

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
      _lastTaskId = null;
      _lastGroupId = null;
      _outputAuto = true;
    });
    await _folder.pick(path);
  }

  Future<void> _pickOutput() async {
    final input = _inputPath;
    if (input == null) {
      return;
    }
    final ext = _extensionFor(input);
    final location = await getSaveLocation(
      suggestedName: p.basename(_suggestedOutput(input)),
      acceptedTypeGroups: [
        XTypeGroup(label: ext.toUpperCase(), extensions: [ext]),
      ],
    );
    if (location == null) {
      return;
    }
    setState(() {
      _outputPath = p.setExtension(location.path, '.$ext');
      _outputAuto = false;
    });
  }

  void _refreshOutput() {
    final input = _inputPath;
    if (input == null) {
      return;
    }
    final ext = _extensionFor(input);
    if (_outputAuto) {
      _outputPath = _suggestedOutput(input);
    } else if (_outputPath != null) {
      _outputPath = p.setExtension(_outputPath!, '.$ext');
    }
  }

  void _selectContainer(String value) {
    setState(() {
      _container = value;
      _refreshOutput();
    });
  }

  void _selectVideo(String value) {
    setState(() {
      _video = value;
      if (value == 'source' && _height == null) {
        _hardware = false;
      }
    });
  }

  void _selectAudio(String value) {
    setState(() {
      _audio = value;
      if (value == 'source') {
        _audioBitrate = -1;
      }
    });
  }

  void _applyPreset(String preset) {
    setState(() {
      switch (preset) {
        case 'remux':
          _container = 'mp4';
          _video = 'source';
          _height = null;
          _audio = 'source';
          _audioBitrate = -1;
          _hardware = false;
          break;
        case 'h265':
          _container = 'mp4';
          _video = _h265Available ? 'h265' : 'h264';
          _height = 1080;
          _audio = 'source';
          _audioBitrate = -1;
          _quality = _quality < 50 ? 60 : _quality;
          break;
      }
      _refreshOutput();
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
    final plan = _singlePlan;
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
    if (plan == null) {
      _snack('还在分析源文件，请稍候');
      return;
    }
    if (plan.error != null) {
      _snack(plan.error!);
      return;
    }
    if (plan.noop) {
      _snack(plan.reason);
      return;
    }

    final ext = _extensionFor(input);
    var fixedOutput = output;
    if (p.extension(fixedOutput).toLowerCase() != '.$ext') {
      fixedOutput = p.setExtension(fixedOutput, '.$ext');
    }
    setState(() {
      _outputPath = fixedOutput;
      _submitting = true;
    });
    try {
      final id = widget.taskStore.submitResolved(
        kind: plan.kind!,
        input: input,
        output: fixedOutput,
        params: plan.params,
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
    final settings = _settings;
    if (settings.isIdentity) {
      _snack('输出设置与原文件一致，没有需要处理的文件');
      return;
    }

    setState(() {
      _submitting = true;
      _submitProgress = '正在分析 1/${plan.pending.length}…';
    });

    var skippedNoop = 0;
    var unsupported = 0;
    var probeFailed = 0;
    final resolved = <(BatchItem, ConversionPlan)>[];
    try {
      for (var index = 0; index < plan.pending.length; index++) {
        final item = plan.pending[index];
        if (index % 6 == 0) {
          if (mounted) {
            setState(() {
              _submitProgress =
                  '正在分析 ${index + 1}/${plan.pending.length}…';
            });
          }
          await Future<void>.delayed(Duration.zero);
          if (!mounted) {
            return;
          }
        }
        try {
          final media = widget.engine.probe(item.entry.path);
          final source = SourceMedia.fromProbe(item.entry.path, media);
          final conversion = buildConversionPlan(
            source: source,
            settings: settings,
            h264Available: _h264Available,
            h265Available: _h265Available,
            aacAvailable: _aacAvailable,
            mp3Available: _mp3Available,
          );
          if (conversion.error != null) {
            unsupported++;
            continue;
          }
          if (conversion.noop) {
            skippedNoop++;
            continue;
          }
          resolved.add((item, conversion));
        } catch (_) {
          probeFailed++;
        }
      }

      if (!mounted) {
        return;
      }
      if (resolved.isEmpty) {
        _snack(
          '没有需要处理的文件'
          '${skippedNoop > 0 ? '（无需转换 $skippedNoop 个）' : ''}'
          '${unsupported + probeFailed > 0 ? '（${unsupported + probeFailed} 个无法读取或无法处理）' : ''}',
        );
        return;
      }

      final group = widget.taskStore.createGroup(
        title: p.basename(_folder.root!),
        root: _folder.root!,
        kind: 'convert',
        toolLabel: '转换',
        outputPolicy: _folder.policy.name,
        params: const {},
        skipped: plan.skippedExisting + skippedNoop + unsupported,
      );

      var remux = 0;
      var transcode = 0;
      var rejected = 0;
      for (final (item, conversion) in resolved) {
        try {
          widget.taskStore.submitResolved(
            kind: conversion.kind!,
            input: item.entry.path,
            output: item.output,
            params: conversion.params,
            groupId: group.id,
          );
          if (conversion.kind == 'remux') {
            remux++;
          } else {
            transcode++;
          }
        } catch (_) {
          rejected++;
        }
      }

      setState(() {
        _lastGroupId = group.id;
        _lastTaskId = null;
      });
      final parts = <String>[
        '已提交 ${remux + transcode} 个（封装 $remux · 转码 $transcode）',
        if (skippedNoop > 0) '跳过 $skippedNoop 个无需转换',
        if (unsupported + probeFailed > 0)
          '${unsupported + probeFailed} 个无法读取或无法处理',
        if (rejected > 0) '$rejected 个被拒绝',
      ];
      _snack(parts.join('，'));
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
                title: '转换',
                description: '改容器、编码或分辨率。只改容器时自动直接封装，'
                    '不重新编码。文件只在本机处理。',
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
          if ((_lastTaskId != null || _lastGroupId != null) && widget.active) ...[
            ListenableBuilder(
              listenable: widget.taskStore,
              builder: (context, _) {
                // 批量时盯住组内当前那一路, 换文件自动重绑
                final task = _lastTaskId != null
                    ? widget.taskStore.taskById(_lastTaskId)
                    : widget.taskStore.previewTaskOfGroup(_lastGroupId);
                if (task == null) {
                  return const SizedBox.shrink();
                }
                return AkTaskVisual(engine: widget.engine, task: task);
              },
            ),
            const SizedBox(height: 16),
          ],
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
            AkSourcePicker(onFile: _pickInput, onFolder: _pickFolder)
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
                ? '逐文件判定：只换容器就直拷；编码或分辨率变化时自动转码。'
                    '输出已存在会跳过。'
                : '支持 mkv / mp4 / mov / avi / ts / flv / webm / wmv。'
                    '输出默认放在源文件旁边。',
            style: AkText.micro,
          ),
          const SizedBox(height: 20),
          if (_lastGroupId != null)
            if (widget.taskStore.groupById(_lastGroupId) case final group?)
              AkGroupCard(group: group, taskStore: widget.taskStore)
            else
              const SizedBox.shrink()
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
    final folderMode = _folder.hasFolder;
    final single = _singlePlan;
    final videoEncoding = _video != 'source' ||
        _height != null ||
        single?.videoMode == 'encode';
    final audioEncoding = _audio != 'source' || single?.audioMode == 'encode';
    final canSubmit = !_submitting &&
        (folderMode
            ? !_settings.isIdentity && (plan?.pending.isNotEmpty ?? false)
            : (single?.canSubmit ?? false));

    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text('输出设置', style: AkText.panelTitle),
              const Spacer(),
              Text(
                folderMode ? '逐文件自动判定' : '实时判定',
                style: AkText.micro,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _presetButton('仅换容器 MP4', 'remux'),
              _presetButton('H.265 · 1080p', 'h265'),
            ],
          ),
          const SizedBox(height: 20),
          Text('容器', style: AkText.label),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _choiceChip('同源', _container == 'source',
                  () => _selectContainer('source')),
              _choiceChip(
                  'MP4', _container == 'mp4', () => _selectContainer('mp4')),
              _choiceChip(
                  'MKV', _container == 'mkv', () => _selectContainer('mkv')),
              _choiceChip(
                  'MOV', _container == 'mov', () => _selectContainer('mov')),
            ],
          ),
          const SizedBox(height: 18),
          Text('视频编码', style: AkText.label),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _choiceChip(
                  '同源', _video == 'source', () => _selectVideo('source')),
              _choiceChip(
                'H.264',
                _video == 'h264',
                _h264Available ? () => _selectVideo('h264') : null,
              ),
              _choiceChip(
                'H.265',
                _video == 'h265',
                _h265Available ? () => _selectVideo('h265') : null,
              ),
            ],
          ),
          if (!_h265Available)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('本机未检测到 H.265 编码器，将自动回退 H.264',
                  style: AkText.micro),
            ),
          const SizedBox(height: 18),
          Text('分辨率', style: AkText.label),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _choiceChip('同源', _height == null,
                  () => setState(() => _height = null)),
              for (final height in const [2160, 1440, 1080, 720, 480])
                _choiceChip(
                  '${height}p',
                  _height == height,
                  () => setState(() => _height = height),
                ),
            ],
          ),
          const SizedBox(height: 18),
          Text('音频编码', style: AkText.label),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _choiceChip(
                  '同源', _audio == 'source', () => _selectAudio('source')),
              _choiceChip(
                'AAC',
                _audio == 'aac',
                _aacAvailable ? () => _selectAudio('aac') : null,
              ),
              _choiceChip(
                'MP3',
                _audio == 'mp3',
                _mp3Available ? () => _selectAudio('mp3') : null,
              ),
            ],
          ),
          if (audioEncoding) ...[
            const SizedBox(height: 18),
            Text('音频码率', style: AkText.label),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _choiceChip('自动', _audioBitrate == -1,
                    () => setState(() => _audioBitrate = -1)),
                for (final bitrate in const [128, 192, 256])
                  _choiceChip(
                    '$bitrate kbps',
                    _audioBitrate == bitrate,
                    () => setState(() => _audioBitrate = bitrate),
                  ),
              ],
            ),
          ],
          if (videoEncoding) ...[
            const SizedBox(height: 18),
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
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('硬件编码', style: AkText.label),
              subtitle: Text(
                !widget.engine.hardwareAvailable
                    ? '本机未检测到可用硬编，将使用软件编码'
                    : _hardware
                        ? '更快，画质与体积略逊软编；失败时自动回退'
                        : '默认软编：画质与体积更可控，速度较慢',
                style: AkText.micro,
              ),
              value: _hardware && widget.engine.hardwareAvailable,
              onChanged: widget.engine.hardwareAvailable
                  ? (value) => setState(() => _hardware = value)
                  : null,
            ),
          ],
          const SizedBox(height: 18),
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
          const SizedBox(height: 18),
          _buildDecision(plan, single),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: canSubmit ? _submit : null,
            child: Text(_submitLabel(plan, single)),
          ),
        ],
      ),
    );
  }

  Widget _buildDecision(BatchPlan? batch, ConversionPlan? single) {
    if (_folder.hasFolder) {
      if (_settings.isIdentity) {
        return _decisionBox(
          color: AkColors.muted,
          icon: Icons.check_circle_outline,
          title: '输出设置与原文件一致，无需转换',
          detail: '改容器、编码或分辨率后即可开始。',
        );
      }
      return _decisionBox(
        color: AkColors.state,
        icon: Icons.auto_awesome,
        title: '逐文件自动判定',
        detail: '能直拷就直拷；编码或分辨率变化时自动转码。'
            '提交后会显示封装与转码数量。',
        note: '封装仍需完整读写文件；云盘/机械盘会慢一些。',
      );
    }
    if (single == null) {
      return _decisionBox(
        color: AkColors.muted,
        icon: Icons.hourglass_empty,
        title: '等待文件信息',
        detail: '选择文件后这里会显示将采用封装还是转码。',
      );
    }
    if (single.error != null) {
      return _decisionBox(
        color: AkColors.danger,
        icon: Icons.error_outline,
        title: single.reason,
        detail: single.detail,
        warnings: single.warnings,
      );
    }
    if (single.noop) {
      return _decisionBox(
        color: AkColors.muted,
        icon: Icons.check_circle_outline,
        title: single.reason,
        detail: single.detail,
      );
    }
    final remux = single.kind == 'remux';
    return _decisionBox(
      color: remux ? AkColors.state : AkColors.accent,
      icon: remux ? Icons.layers_outlined : Icons.sync,
      title: single.reason,
      detail: single.detail,
      note: remux
          ? '不重新编码，但仍需完整读写文件；云盘/机械盘会受限于磁盘速度。'
          : null,
      warnings: single.warnings,
    );
  }

  Widget _decisionBox({
    required Color color,
    required IconData icon,
    required String title,
    required String detail,
    String? note,
    List<String> warnings = const [],
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AkColors.surfaceAlt,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: AkText.body.copyWith(
                    color: color == AkColors.muted
                        ? AkColors.textStrong
                        : color,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (detail.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(detail, style: AkText.micro),
                ],
                if (note != null && note.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    note,
                    style: AkText.micro.copyWith(color: AkColors.faint),
                  ),
                ],
                for (final warning in warnings) ...[
                  const SizedBox(height: 4),
                  Text(
                    warning,
                    style: AkText.micro.copyWith(color: AkColors.accent),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _submitLabel(BatchPlan? batch, ConversionPlan? single) {
    if (_submitting) {
      return _submitProgress ?? '处理中…';
    }
    if (_folder.hasFolder) {
      if (_settings.isIdentity) {
        return '无需转换';
      }
      if (batch == null || batch.pending.isEmpty) {
        return '没有可处理的文件';
      }
      return '分析并处理 ${batch.count} 个文件';
    }
    if (single == null) {
      return _probing ? '正在分析源文件…' : '等待文件信息';
    }
    if (single.error != null) {
      return '当前设置无法转换';
    }
    if (single.noop) {
      return '无需转换';
    }
    return single.kind == 'remux' ? '开始封装' : '开始转换';
  }

  Widget _choiceChip(String label, bool selected, VoidCallback? onTap) {
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      showCheckmark: false,
      visualDensity: VisualDensity.compact,
      labelStyle: AkText.micro.copyWith(
        color: onTap == null
            ? AkColors.faint
            : (selected ? AkColors.accentInk : AkColors.text),
      ),
      selectedColor: AkColors.accent,
      backgroundColor: AkColors.surfaceAlt,
      disabledColor: AkColors.surfaceAlt,
      side: BorderSide(
        color: selected ? AkColors.accent : AkColors.border,
      ),
      onSelected: onTap == null ? null : (_) => onTap(),
    );
  }

  Widget _presetButton(String label, String preset) {
    return OutlinedButton(
      onPressed: () => _applyPreset(preset),
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 32),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        textStyle: AkText.micro,
      ),
      child: Text(label),
    );
  }
}
