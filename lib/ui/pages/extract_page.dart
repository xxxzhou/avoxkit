import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../core/engine.dart';
import '../../core/task_store.dart';
import '../tokens.dart';
import '../widgets/media_source.dart';
import '../widgets/panel.dart';
import '../widgets/task_summary.dart';

const _videoTypes = XTypeGroup(
  label: '视频',
  extensions: ['mkv', 'mp4', 'mov', 'avi', 'ts', 'flv', 'webm', 'wmv', 'm4v'],
);

class ExtractPage extends StatefulWidget {
  const ExtractPage({
    super.key,
    required this.engine,
    required this.taskStore,
  });

  final Engine engine;
  final TaskStore taskStore;

  @override
  State<ExtractPage> createState() => _ExtractPageState();
}

class _ExtractPageState extends State<ExtractPage> {
  String? _inputPath;
  String? _outputPath;
  Map<String, dynamic>? _media;
  String? _probeError;
  bool _probing = false;
  bool _outputAuto = true;

  String _format = 'm4a';
  int _bitrate = 192;
  int? _lastTaskId;
  bool _submitting = false;

  Map<String, dynamic>? get _audioTrack =>
      AkMediaInfo.firstTrack(_media?['audio']);

  String get _outputExtension {
    if (_format == 'mp3') {
      return 'mp3';
    }
    if (_format == 'copy') {
      return switch (_audioTrack?['codec']) {
        'mp3' => 'mp3',
        'aac' => 'm4a',
        _ => 'mkv',
      };
    }
    return 'm4a';
  }

  String _suggestedOutput(String input) {
    return p.join(
      p.dirname(input),
      '${p.basenameWithoutExtension(input)}.$_outputExtension',
    );
  }

  Future<void> _pickInput() async {
    final file = await openFile(acceptedTypeGroups: const [_videoTypes]);
    if (file == null) {
      return;
    }
    final path = file.path;
    setState(() {
      _inputPath = path;
      _outputPath = _suggestedOutput(path);
      _outputAuto = true;
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

  Future<void> _pickOutput() async {
    final location = await getSaveLocation(
      suggestedName: _outputPath == null
          ? 'audio.$_outputExtension'
          : p.basename(_outputPath!),
      acceptedTypeGroups: [
        XTypeGroup(label: _outputExtension.toUpperCase(), extensions: [
          _outputExtension,
        ]),
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
      final id = widget.taskStore.submitExtract(
        input: input,
        output: output,
        // UI 的 M4A 对应 AAC 编码, ABI 只认 aac/mp3/copy
        codec: _format == 'm4a' ? 'aac' : _format,
        bitrateKbps: _format == 'copy' ? -1 : _bitrate,
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
      _snack(error is EngineException ? error.message : '$error');
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
            title: '提取音频',
            description: '把视频里的音轨单独导出。文件只在本机处理。',
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
                children: [left, const SizedBox(height: 24), right],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildSourcePanel() {
    final hasAudio = _audioTrack != null;
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
            AkSourcePicker(onTap: _pickInput, title: '选择带音轨的视频')
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
                else if (_media != null) ...[
                  AkMediaInfo(media: _media!),
                  if (!hasAudio) ...[
                    const SizedBox(height: 12),
                    Text(
                      '这个文件没有音轨，无法提取。',
                      style: AkText.body.copyWith(color: AkColors.danger),
                    ),
                  ],
                ],
              ],
            ),
          const SizedBox(height: 20),
          const Divider(height: 1),
          const SizedBox(height: 16),
          Text(
            '输出默认放在源文件旁边；导出 mp3 需要重新编码，其余格式可原样封装。',
            style: AkText.micro,
          ),
          const SizedBox(height: 20),
          AkLatestTask(taskStore: widget.taskStore, taskId: _lastTaskId),
        ],
      ),
    );
  }

  Widget _buildOptionsPanel() {
    final hasAudio = _audioTrack != null;
    final audioCodec = _audioTrack?['codec'];
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('输出设置', style: AkText.panelTitle),
          const SizedBox(height: 20),
          Text('音频格式', style: AkText.label),
          const SizedBox(height: 8),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'm4a', label: Text('M4A')),
              ButtonSegment(value: 'mp3', label: Text('MP3')),
              ButtonSegment(value: 'copy', label: Text('原始音轨')),
            ],
            selected: {_format},
            showSelectedIcon: false,
            onSelectionChanged: (values) => _selectFormat(values.first),
          ),
          const SizedBox(height: 8),
          Text(
            _format == 'copy'
                ? '不重新编码，速度最快；目标容器不支持时会自动转码。'
                : 'AAC 兼容性好；MP3 通用性最强。',
            style: AkText.micro,
          ),
          if (_format != 'copy') ...[
            const SizedBox(height: 20),
            Row(
              children: [
                Text('码率', style: AkText.label),
                const Spacer(),
                Text(
                  '$_bitrate kbps',
                  style: AkText.mono.copyWith(color: AkColors.textStrong),
                ),
              ],
            ),
            const SizedBox(height: 4),
            SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 128, label: Text('128')),
                ButtonSegment(value: 192, label: Text('192')),
                ButtonSegment(value: 256, label: Text('256')),
                ButtonSegment(value: 320, label: Text('320')),
              ],
              selected: {_bitrate},
              showSelectedIcon: false,
              onSelectionChanged: (values) =>
                  setState(() => _bitrate = values.first),
            ),
          ],
          if (_format == 'copy' && audioCodec is String) ...[
            const SizedBox(height: 12),
            Text('源音轨：${audioCodec.toUpperCase()}', style: AkText.micro),
          ],
          const SizedBox(height: 20),
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
            onPressed: (_submitting || !hasAudio) ? null : _submit,
            child: Text(_submitting ? '提交中…' : '开始提取'),
          ),
        ],
      ),
    );
  }
}
