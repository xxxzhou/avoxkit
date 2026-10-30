import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../core/clip_plan.dart';
import '../../core/engine.dart';
import '../../core/media_frame_source.dart';
import '../../core/media_index.dart';
import '../../core/task_store.dart';
import '../tokens.dart';
import '../widgets/frame_preview.dart';
import '../widgets/media_source.dart';
import '../widgets/panel.dart';
import '../widgets/task_summary.dart';
import '../widgets/trim_timeline.dart';

const _videoTypes = XTypeGroup(
  label: '视频',
  extensions: ['mkv', 'mp4', 'mov', 'avi', 'ts', 'flv', 'webm', 'wmv', 'm4v'],
);

class ClipPage extends StatefulWidget {
  const ClipPage({super.key, required this.engine, required this.taskStore});

  final Engine engine;
  final TaskStore taskStore;

  @override
  State<ClipPage> createState() => _ClipPageState();
}

class _ClipPageState extends State<ClipPage> {
  final TextEditingController _startCtrl = TextEditingController();
  final TextEditingController _endCtrl = TextEditingController();
  final FocusNode _startFocus = FocusNode();
  final FocusNode _endFocus = FocusNode();

  String? _inputPath;
  String? _outputPath;
  Map<String, dynamic>? _media;
  String? _probeError;
  bool _probing = false;

  MediaFrameSource? _source;
  int _stripCount = 12;
  Timer? _stripTimer;
  int? _scrubMs;
  bool _activeAtEnd = false;

  int _durationMs = 0;
  int _startMs = 0;
  int _endMs = 0;
  String? _snapNotice;

  String _container = 'source';
  double _quality = 60;
  bool _outputAuto = true;

  int? _lastTaskId;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _startFocus.addListener(_onStartFocus);
    _endFocus.addListener(_onEndFocus);
  }

  @override
  void dispose() {
    _startFocus.removeListener(_onStartFocus);
    _endFocus.removeListener(_onEndFocus);
    _stripTimer?.cancel();
    _source?.removeListener(_onSourceChanged);
    _source?.dispose();
    _startCtrl.dispose();
    _endCtrl.dispose();
    _startFocus.dispose();
    _endFocus.dispose();
    super.dispose();
  }

  void _onStartFocus() {
    if (!_startFocus.hasFocus) {
      _commitStart();
    }
  }

  void _onEndFocus() {
    if (!_endFocus.hasFocus) {
      _commitEnd();
    }
  }

  List<int> get _keyframes => _index?.keyframesMs ?? const [];

  MediaIndex? get _index => _source?.index;
  bool get _indexing => _source?.indexLoading ?? false;

  int get _activeMs => _scrubMs ?? (_activeAtEnd ? _endMs : _startMs);
  String get _activeLabel =>
      _scrubMs != null ? '参考' : (_activeAtEnd ? '出点' : '入点');

  int get _sourceDurationMs => _durationMs;

  String get _sourceExt {
    final ext = p
        .extension(_inputPath ?? '')
        .toLowerCase()
        .replaceFirst('.', '');
    return const {'mp4', 'mkv', 'mov'}.contains(ext) ? ext : 'mp4';
  }

  String get _outputExt => _container == 'source' ? _sourceExt : _container;

  String get _videoCodec {
    final video = AkMediaInfo.firstTrack(_media?['video']);
    final codec = '${video?['codec'] ?? ''}'.toLowerCase();
    return codec == 'hevc' || codec == 'h265' ? 'hevc' : 'h264';
  }

  bool get _hasAudio {
    final audio = _media?['audio'];
    return audio is List && audio.isNotEmpty;
  }

  bool get _hasVideo {
    final video = _media?['video'];
    return video is List && video.isNotEmpty;
  }

  String? get _stripNote {
    final source = _source;
    if (source == null || _durationMs <= 0) {
      return null;
    }
    if (source.stripLoading && source.strip == null) {
      return '缩略图载入中…';
    }
    return source.framesHint ?? '无画面预览';
  }

  String get _activeHint {
    if (_scrubMs != null) {
      return '跟随指针，查看任意时刻';
    }
    return _activeAtEnd ? '产物到这一帧结束（半秒内偏差）' : '产物从这一帧开始';
  }

  ClipPlan get _plan => buildClipPlan(
    sourceDurationMs: _sourceDurationMs,
    startMs: _startMs,
    endMs: _endMs,
  );

  String _suggestedOutput(String input) => p.join(
    p.dirname(input),
    '${p.basenameWithoutExtension(input)}.clip.$_outputExt',
  );

  Future<void> _pickInput() async {
    final file = await openFile(acceptedTypeGroups: const [_videoTypes]);
    if (file == null) {
      return;
    }
    final path = file.path;
    _source?.removeListener(_onSourceChanged);
    _source?.dispose();
    _source = null;
    setState(() {
      _inputPath = path;
      _container = 'source';
      _outputAuto = true;
      _outputPath = _suggestedOutput(path);
      _media = null;
      _probeError = null;
      _probing = true;
      _durationMs = 0;
      _startMs = 0;
      _endMs = 0;
      _snapNotice = null;
      _scrubMs = null;
      _activeAtEnd = false;
      _lastTaskId = null;
    });
    _syncFields(force: true);
    await _probe(path);
  }

  Future<void> _probe(String path) async {
    try {
      final media = widget.engine.probe(path);
      if (!mounted || _inputPath != path) {
        return;
      }
      final duration = (media['duration_ms'] as num?)?.toInt() ?? 0;
      setState(() {
        _media = media;
        _probing = false;
        _durationMs = duration;
        _startMs = 0;
        _endMs = duration;
      });
      _syncFields(force: true);
      _createSource(path, duration);
    } catch (error) {
      if (!mounted || _inputPath != path) {
        return;
      }
      setState(() {
        _probeError = error is EngineException ? error.message : '$error';
        _probing = false;
      });
    }
  }

  Future<void> _createSource(String path, int duration) async {
    final source = MediaFrameSource(
      engine: widget.engine,
      path: path,
      durationMs: duration,
    );
    source.addListener(_onSourceChanged);
    _source = source;
    source.loadStrip(count: _stripCount);
    await source.loadIndex();
    if (!mounted || _source != source) {
      return;
    }
    // 索引回来得晚时, 把用户已经选好的起点补吸附一次
    final keyframes = source.index?.keyframesMs ?? const <int>[];
    if (keyframes.isNotEmpty && _startMs > 0) {
      final snapped = snapClipStart(_startMs, keyframes);
      if (snapped != _startMs && snapped < _endMs - kMinClipMs) {
        _startMs = snapped;
        _syncFields(force: true);
      }
    }
    setState(() {});
  }

  void _onSourceChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  void _onFramesNeeded(int count) {
    if (count == _stripCount && _source?.strip != null) {
      return;
    }
    _stripCount = count;
    // 窗口拖动时宽度会连续变化, 等停稳再抓
    _stripTimer?.cancel();
    _stripTimer = Timer(const Duration(milliseconds: 220), () {
      _source?.loadStrip(count: _stripCount);
    });
  }

  void _syncFields({bool force = false}) {
    if (force || !_startFocus.hasFocus) {
      _startCtrl.text = formatTimestamp(_startMs);
    }
    if (force || !_endFocus.hasFocus) {
      _endCtrl.text = formatTimestamp(_endMs);
    }
  }

  void _applyRange(int start, int end, {bool snapStart = true}) {
    final duration = _sourceDurationMs;
    if (duration <= 0) {
      return;
    }
    var s = start.clamp(0, duration).toInt();
    var e = end.clamp(0, duration).toInt();
    if (snapStart) {
      s = snapClipStart(s, _keyframes).clamp(0, duration).toInt();
    }
    if (e < s + kMinClipMs) {
      e = math.min(duration, s + kMinClipMs);
      if (e < s + kMinClipMs) {
        s = math.max(0, e - kMinClipMs);
      }
    }
    if (s != _startMs) {
      _activeAtEnd = false;
    } else if (e != _endMs) {
      _activeAtEnd = true;
    }
    setState(() {
      _startMs = s;
      _endMs = e;
      _snapNotice = null;
    });
    _syncFields();
  }

  void _commitStart() {
    if (_sourceDurationMs <= 0) {
      return;
    }
    final parsed = parseTimestamp(_startCtrl.text);
    if (parsed == null) {
      _snack('开始时间格式不对，用 00:01:23.500 或 83.5');
      _syncFields(force: true);
      return;
    }
    final latest = math.max(0, _endMs - kMinClipMs);
    var start = parsed.clamp(0, latest).toInt();
    final snapped = snapClipStart(start, _keyframes);
    final didSnap = snapped != start && snapped <= latest;
    if (didSnap) {
      start = snapped;
    }
    setState(() {
      _startMs = start;
      _scrubMs = null;
      _activeAtEnd = false;
      _snapNotice = didSnap ? '起点已对齐到关键帧 ${formatTimestamp(start)}' : null;
    });
    _syncFields(force: true);
  }

  void _commitEnd() {
    if (_sourceDurationMs <= 0) {
      return;
    }
    final parsed = parseTimestamp(_endCtrl.text);
    if (parsed == null) {
      _snack('结束时间格式不对，用 00:01:23.500 或 83.5');
      _syncFields(force: true);
      return;
    }
    final end = parsed
        .clamp(
          math.min(_sourceDurationMs, _startMs + kMinClipMs),
          _sourceDurationMs,
        )
        .toInt();
    setState(() {
      _endMs = end;
      _scrubMs = null;
      _activeAtEnd = true;
    });
    _syncFields(force: true);
  }

  void _selectContainer(String value) {
    setState(() {
      _container = value;
      if (_outputAuto && _inputPath != null) {
        _outputPath = _suggestedOutput(_inputPath!);
      } else if (_outputPath != null) {
        _outputPath = p.setExtension(_outputPath!, '.$_outputExt');
      }
    });
  }

  Future<void> _pickOutput() async {
    final input = _inputPath;
    if (input == null) {
      return;
    }
    final ext = _outputExt;
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

  Future<void> _submit() async {
    if (_submitting) {
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
    final plan = _plan;
    if (!plan.ok) {
      _snack(plan.error!);
      return;
    }
    final ext = _outputExt;
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
        kind: 'trim',
        input: input,
        output: fixedOutput,
        params: plan.params(
          container: ext,
          videoCodec: _videoCodec,
          quality: _quality.round(),
          hasAudio: _hasAudio,
        ),
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
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final plan = _plan;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(32, 32, 32, 40),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const PageHeader(
            title: '截取片段',
            description:
                '从视频里取出一段单独保存。拖动时间线上的两个手柄选择起止点，'
                '滚轮缩放、拖空白处平移。文件只在本机处理。',
          ),
          const SizedBox(height: 24),
          LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= 980;
              final left = _buildSourcePanel(plan);
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
  }

  Widget _buildSourcePanel(ClipPlan plan) {
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('源文件', style: AkText.panelTitle),
              const Spacer(),
              if (_inputPath != null)
                TextButton(onPressed: _pickInput, child: const Text('重新选择')),
            ],
          ),
          const SizedBox(height: 16),
          if (_inputPath == null)
            _singlePicker()
          else ...[
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
            const SizedBox(height: 22),
            const Divider(height: 1),
            const SizedBox(height: 16),
            Row(
              children: [
                Text('时间线', style: AkText.label),
                const Spacer(),
                TextButton(
                  onPressed: _durationMs > 0
                      ? () => _applyRange(0, _durationMs)
                      : null,
                  child: const Text('整段'),
                ),
              ],
            ),
            const SizedBox(height: 6),
            _buildFrameReference(),
            AkTrimTimeline(
              durationMs: _durationMs,
              startMs: _startMs,
              endMs: _endMs,
              index: _index,
              frames: _source?.strip?.frames ?? const [],
              frameWidth: _source?.strip?.width ?? 0,
              frameHeight: _source?.strip?.height ?? 0,
              stripNote: _stripNote,
              enabled: _durationMs > 0 && _probeError == null,
              onChanged: (range) {
                final (start, end) = range;
                _applyRange(start, end);
              },
              onScrub: (ms) {
                if (ms != _scrubMs) {
                  setState(() => _scrubMs = ms);
                }
              },
              onFramesNeeded: _onFramesNeeded,
            ),
            const SizedBox(height: 8),
            Text(_timelineHint(), style: AkText.micro),
          ],
          const SizedBox(height: 20),
          const Divider(height: 1),
          const SizedBox(height: 16),
          Text(
            '起点会落在关键帧上；终点按时间截断，可能有半秒内偏差。'
            '片段会重新编码，输出默认放在源文件旁边。',
            style: AkText.micro,
          ),
          const SizedBox(height: 20),
          AkLatestTask(taskStore: widget.taskStore, taskId: _lastTaskId),
        ],
      ),
    );
  }

  Widget _buildFrameReference() {
    final source = _source;
    if (source == null) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: SizedBox(
        height: 124,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 220,
              child: AkFramePreview(
                source: source,
                timeMs: _activeMs,
                label: _activeLabel,
                timeLabel: formatTimestamp(_activeMs),
                emptyText: !_hasVideo
                    ? '这个文件没有画面'
                    : (source.framesHint ?? '正在读取画面…'),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('画面参考', style: AkText.label),
                  const SizedBox(height: 2),
                  Text(
                    formatTimestamp(_activeMs),
                    style: AkText.mono.copyWith(
                      color: AkColors.textStrong,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(_activeHint, style: AkText.micro),
                  const Spacer(),
                  Text('拖动入点/出点或悬停时间线，画面会跟着变。', style: AkText.micro),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _singlePicker() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FilledButton.icon(
          onPressed: _pickInput,
          icon: const Icon(Icons.insert_drive_file_outlined, size: 18),
          label: const Text('打开文件'),
        ),
        const SizedBox(height: 8),
        Text(
          '支持 mkv / mp4 / mov / avi / ts / webm 等；截取只处理单个文件。',
          style: AkText.micro,
        ),
      ],
    );
  }

  String _timelineHint() {
    if (_durationMs <= 0) {
      return '选择文件后这里会显示缩略图、音频包络与关键帧。';
    }
    if (_indexing) {
      return '正在读取波形与关键帧…（不影响选时间）';
    }
    final index = _index;
    if (index == null) {
      return '无法读取波形与关键帧，时间线只显示刻度。';
    }
    final wave = index.hasWave ? '音频包络' : '无音频包络';
    final keys = index.keyframesMs.isEmpty
        ? '未读到关键帧'
        : '${index.keyframesMs.length} 个关键帧';
    final strip = _source?.strip?.frames.isNotEmpty ?? false
        ? '缩略图条按整片均匀采样 · '
        : '';
    return '$strip$wave · $keys · 滚轮缩放，拖空白处平移，双击回到全片';
  }

  Widget _buildOptionsPanel(ClipPlan plan) {
    final canSubmit =
        !_submitting && _inputPath != null && _probeError == null && plan.ok;
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('截取范围', style: AkText.panelTitle),
          const SizedBox(height: 14),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TextField(
                  controller: _startCtrl,
                  focusNode: _startFocus,
                  style: AkText.mono.copyWith(color: AkColors.textStrong),
                  decoration: const InputDecoration(
                    labelText: '开始',
                    hintText: '00:00:00.000',
                    counterText: '',
                  ),
                  onSubmitted: (_) => _commitStart(),
                ),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8, vertical: 14),
                child: Text('→', style: AkText.body),
              ),
              Expanded(
                child: TextField(
                  controller: _endCtrl,
                  focusNode: _endFocus,
                  style: AkText.mono.copyWith(color: AkColors.textStrong),
                  decoration: const InputDecoration(
                    labelText: '结束',
                    hintText: '00:00:30.000',
                    counterText: '',
                  ),
                  onSubmitted: (_) => _commitEnd(),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Text(
                '片段时长 ${prettyClipDuration(math.max(0, _endMs - _startMs))}',
                style: AkText.micro,
              ),
              const Spacer(),
              Text(
                '全片 ${formatTimestamp(_durationMs, withMillis: false)}',
                style: AkText.micro,
              ),
            ],
          ),
          if (_snapNotice != null) ...[
            const SizedBox(height: 6),
            Text(
              _snapNotice!,
              style: AkText.micro.copyWith(color: AkColors.accent),
            ),
          ],
          const SizedBox(height: 22),
          const Divider(height: 1),
          const SizedBox(height: 18),
          Text('输出', style: AkText.panelTitle),
          const SizedBox(height: 14),
          Text('容器', style: AkText.label),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _chip(
                '同源',
                _container == 'source',
                () => _selectContainer('source'),
              ),
              _chip('MP4', _container == 'mp4', () => _selectContainer('mp4')),
              _chip('MKV', _container == 'mkv', () => _selectContainer('mkv')),
              _chip('MOV', _container == 'mov', () => _selectContainer('mov')),
            ],
          ),
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
          Text(
            '视频 ${_videoCodec == 'hevc' ? 'H.265' : 'H.264'} + 音频 AAC；'
            '数值越大越清晰、文件越大',
            style: AkText.micro,
          ),
          const SizedBox(height: 18),
          Text('输出文件', style: AkText.label),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Text(
                  _outputPath == null ? '尚未选择' : p.basename(_outputPath!),
                  style: AkText.body.copyWith(
                    color: _outputPath == null ? AkColors.faint : AkColors.text,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton(onPressed: _pickOutput, child: const Text('选择')),
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
          const SizedBox(height: 20),
          _buildDecision(plan),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: canSubmit ? _submit : null,
            child: Text(
              _submitting
                  ? '提交中…'
                  : _inputPath == null
                  ? '先选择视频文件'
                  : plan.ok
                  ? '开始截取'
                  : '当前范围无法截取',
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDecision(ClipPlan plan) {
    if (_inputPath == null) {
      return _decisionBox(
        color: AkColors.muted,
        icon: Icons.crop_free,
        title: '等待选择视频',
        detail: '选一个文件后，这里是将保存的片段。',
      );
    }
    if (_probing) {
      return _decisionBox(
        color: AkColors.muted,
        icon: Icons.hourglass_empty,
        title: '正在读取媒体信息',
        detail: '拿到时长后就能拖动时间线。',
      );
    }
    if (_probeError != null) {
      return _decisionBox(
        color: AkColors.danger,
        icon: Icons.error_outline,
        title: '无法读取这个文件',
        detail: _probeError!,
      );
    }
    if (_durationMs <= 0) {
      return _decisionBox(
        color: AkColors.danger,
        icon: Icons.error_outline,
        title: '无法确定片长',
        detail: '这个来源没有可用时长，不能按时间截取。',
      );
    }
    if (plan.error != null) {
      return _decisionBox(
        color: AkColors.danger,
        icon: Icons.error_outline,
        title: plan.error!,
        detail: '拖动时间线或直接改上面的时间。',
        warnings: plan.warnings,
      );
    }
    return _decisionBox(
      color: AkColors.accent,
      icon: Icons.content_cut,
      title:
          '${formatTimestamp(plan.startMs)} → ${formatTimestamp(plan.endMs)}',
      detail:
          '${prettyClipDuration(plan.durationMs)} · ${_outputExt.toUpperCase()} · '
          '${_videoCodec == 'hevc' ? 'H.265' : 'H.264'} + AAC',
      note: '重新编码；起点对齐关键帧，终点可能有半秒内偏差。',
      warnings: plan.warnings,
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

  Widget _chip(String label, bool selected, VoidCallback onTap) {
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      showCheckmark: false,
      visualDensity: VisualDensity.compact,
      labelStyle: AkText.micro.copyWith(
        color: selected ? AkColors.accentInk : AkColors.text,
      ),
      selectedColor: AkColors.accent,
      backgroundColor: AkColors.surfaceAlt,
      side: BorderSide(color: selected ? AkColors.accent : AkColors.border),
      onSelected: (_) => onTap(),
    );
  }
}
