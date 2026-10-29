import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/batch.dart';
import '../../core/engine.dart';
import '../../core/folder_source.dart';
import '../../core/image_plan.dart';
import '../../core/model_store.dart';
import '../../core/task.dart';
import '../../core/task_store.dart';
import '../tokens.dart';
import '../widgets/folder_card.dart';
import '../widgets/group_card.dart';
import '../widgets/media_source.dart';
import '../widgets/panel.dart';
import '../widgets/task_summary.dart';

const _imageTypes = XTypeGroup(
  label: '图片',
  extensions: ['jpg', 'jpeg', 'png', 'bmp', 'webp'],
);

enum _RepairMode { auto, mask }

enum _OutputFormat { keep, png, jpg }

class _Stroke {
  _Stroke(this.radius);
  final double radius;
  final List<Offset> points = [];
}

class RepairPage extends StatefulWidget {
  const RepairPage({
    super.key,
    required this.engine,
    required this.taskStore,
  });

  final Engine engine;
  final TaskStore taskStore;

  @override
  State<RepairPage> createState() => _RepairPageState();
}

class _RepairPageState extends State<RepairPage> {
  final FolderSource _folder = FolderSource(
    extensions: imageExtensions,
    skipStemSuffixes: const [],
    rootTag: 'repaired',
    policy: OutputPolicy.sidecar,
  );

  late final InpaintModel _model;

  String? _inputPath;
  String? _outputPath;
  String? _resultPath;
  Uint8List? _inputBytes;
  Uint8List? _resultBytes;
  int _imageWidth = 0;
  int _imageHeight = 0;
  bool _loadingImage = false;
  String? _imageError;

  _RepairMode _mode = _RepairMode.auto;
  _OutputFormat _format = _OutputFormat.keep;
  final List<_Stroke> _strokes = [];
  double _brush = 0.05;

  ImageDetectResult? _detect;
  bool _detecting = false;

  int? _lastTaskId;
  int? _lastGroupId;
  bool _submitting = false;
  String? _submitProgress;
  bool _showOriginal = false;

  @override
  void initState() {
    super.initState();
    _model = InpaintModel(root: widget.engine.modelsDir ?? '');
    _model.addListener(_onModelChanged);
    _model.check();
    widget.taskStore.addListener(_onTaskStoreChanged);
  }

  @override
  void dispose() {
    widget.taskStore.removeListener(_onTaskStoreChanged);
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

  void _onTaskStoreChanged() {
    if (!mounted) {
      return;
    }
    final task = widget.taskStore.taskById(_lastTaskId);
    if (task != null &&
        task.state == 'done' &&
        task.output != null &&
        task.output != _resultPath) {
      _loadResult(task.output!);
      return;
    }
    setState(() {});
  }

  Future<void> _loadResult(String path) async {
    try {
      final bytes = await File(path).readAsBytes();
      if (!mounted) {
        return;
      }
      setState(() {
        _resultPath = path;
        _resultBytes = bytes;
        _showOriginal = false;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _resultPath = path;
        _resultBytes = null;
      });
    }
  }

  bool get _imageRepairAvailable {
    final features = widget.engine.capabilities['features'];
    if (features is! Map) {
      return true;
    }
    return features['image'] != false;
  }

  String? get _formatExtension => switch (_format) {
        _OutputFormat.keep => null,
        _OutputFormat.png => '.png',
        _OutputFormat.jpg => '.jpg',
      };

  BatchPlan? _plan() => _folder.hasFolder
      ? _folder.planFor(
          extensionFrom: (entry) {
            if (_format == _OutputFormat.keep) {
              return imageOutputExtension(entry.path).substring(1);
            }
            return _format == _OutputFormat.png ? 'png' : 'jpg';
          },
          extensionTag: 'image',
          sidecarSuffix: '-repaired',
          // 输出是派生文件(源名 + -repaired), 重跑直接覆盖上次结果
          skipExisting: false,
        )
      : null;

  Future<void> _pickInput() async {
    final file = await openFile(acceptedTypeGroups: const [_imageTypes]);
    if (file == null) {
      return;
    }
    _folder.clear();
    await _selectImage(file.path);
  }

  Future<void> _pickFolder() async {
    final path = await getDirectoryPath();
    if (path == null) {
      return;
    }
    setState(() {
      _inputPath = null;
      _outputPath = null;
      _resultPath = null;
      _inputBytes = null;
      _resultBytes = null;
      _imageWidth = 0;
      _imageHeight = 0;
      _imageError = null;
      _strokes.clear();
      _detect = null;
      _lastTaskId = null;
      _lastGroupId = null;
      _mode = _RepairMode.auto;
      _showOriginal = false;
    });
    await _folder.pick(path);
  }

  Future<void> _selectImage(String path) async {
    setState(() {
      _inputPath = path;
      _outputPath = suggestImageOutput(path, extension: _formatExtension);
      _resultPath = null;
      _inputBytes = null;
      _resultBytes = null;
      _imageWidth = 0;
      _imageHeight = 0;
      _imageError = null;
      _loadingImage = true;
      _strokes.clear();
      _detect = null;
      _lastTaskId = null;
      _lastGroupId = null;
      _showOriginal = false;
    });
    try {
      final bytes = await File(path).readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final width = frame.image.width;
      final height = frame.image.height;
      frame.image.dispose();
      codec.dispose();
      if (!mounted || _inputPath != path) {
        return;
      }
      setState(() {
        _inputBytes = bytes;
        _imageWidth = width;
        _imageHeight = height;
        _loadingImage = false;
      });
    } catch (error) {
      if (!mounted || _inputPath != path) {
        return;
      }
      setState(() {
        _loadingImage = false;
        _imageError = '无法预览这张图片（$error）。自动修复仍可尝试。';
      });
    }
  }

  Future<void> _pickOutput() async {
    final input = _inputPath;
    if (input == null) {
      return;
    }
    final ext = (_formatExtension ?? imageOutputExtension(input)).replaceFirst(
      '.',
      '',
    );
    final location = await getSaveLocation(
      suggestedName: p.basename(suggestImageOutput(input, extension: ext)),
      acceptedTypeGroups: [
        XTypeGroup(label: ext.toUpperCase(), extensions: [ext]),
      ],
    );
    if (location == null) {
      return;
    }
    setState(() {
      _outputPath = p.setExtension(location.path, '.$ext');
    });
  }

  void _setFormat(_OutputFormat value) {
    if (_format == value) {
      return;
    }
    setState(() {
      _format = value;
      final input = _inputPath;
      if (input != null) {
        _outputPath = suggestImageOutput(input, extension: _formatExtension);
      }
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

  Future<void> _detectWatermark() async {
    final input = _inputPath;
    if (input == null || _detecting || _model.busy) {
      return;
    }
    if (!_model.ready) {
      _snack('先下载图像修复模型');
      return;
    }
    setState(() {
      _detecting = true;
      _detect = null;
    });
    final result = await widget.engine.imageDetect(input);
    if (!mounted) {
      return;
    }
    setState(() {
      _detecting = false;
      _detect = result.ok ? result : null;
    });
    if (!result.ok) {
      _snack(_detectError(result));
      return;
    }
    if (result.found && result.boxes.isNotEmpty) {
      _snack('识别到 ${result.boxes.length} 处可疑水印');
    } else {
      _snack('没有识别到水印，可以改用手动涂抹');
    }
  }

  String _detectError(ImageDetectResult result) {
    switch (result.code) {
      case 'model_missing':
        return '图像修复模型未下载';
      case 'inpaint_unavailable':
        return '图像修复组件不可用';
      case 'image_decode_failed':
        return '无法读取这张图片';
      default:
        return result.message ?? '水印识别失败';
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
      _snack('先选择一张图片');
      return;
    }
    if (output == null || output.isEmpty) {
      _snack('先选择输出位置');
      return;
    }
    if (!File(input).existsSync()) {
      _snack('输入图片不存在');
      return;
    }
    if (!_imageRepairAvailable) {
      _snack('图像修复组件未随包提供');
      return;
    }
    if (_mode == _RepairMode.mask && _strokes.isEmpty) {
      _snack('先在图片上涂抹要修复的区域');
      return;
    }
    if (_mode == _RepairMode.mask && (_imageWidth <= 0 || _imageHeight <= 0)) {
      _snack('这张图片无法预览，改用手动涂抹不可用');
      return;
    }
    setState(() {
      _submitting = true;
      _submitProgress = null;
    });
    try {
      if (!_model.ready) {
        setState(() => _submitProgress = '正在下载图像修复模型…');
        await _downloadModel();
        if (!mounted || !_model.ready) {
          return;
        }
      }
      String? maskPath;
      if (_mode == _RepairMode.mask) {
        setState(() => _submitProgress = '正在生成涂抹区域…');
        maskPath = await _writeMask();
        if (maskPath == null) {
          _snack('涂抹区域生成失败，请重试');
          return;
        }
      }
      final params = imageRepairParams(
        mode: _mode == _RepairMode.mask ? 'mask' : 'auto',
        maskPath: maskPath,
        // 派生输出: 重跑覆盖上一次的 -repaired 文件
        overwrite: true,
      );
      final id = widget.taskStore.submitResolved(
        kind: 'image',
        input: input,
        output: output,
        params: params,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _lastTaskId = id;
        _lastGroupId = null;
        _resultPath = null;
        _resultBytes = null;
        _showOriginal = false;
      });
      _snack('已加入队列 · 任务 #$id');
    } catch (error) {
      if (!mounted) {
        return;
      }
      _snack(error is EngineException ? error.message : '$error');
    } finally {
      if (mounted) {
        setState(() {
          _submitting = false;
          _submitProgress = null;
        });
      }
    }
  }

  Future<void> _submitFolder() async {
    final plan = _plan();
    if (plan == null || plan.pending.isEmpty) {
      _snack('当前没有可处理的图片');
      return;
    }
    if (!_imageRepairAvailable) {
      _snack('图像修复组件未随包提供');
      return;
    }
    setState(() {
      _submitting = true;
      _submitProgress = '正在准备…';
    });
    try {
      if (!_model.ready) {
        setState(() => _submitProgress = '正在下载图像修复模型…');
        await _downloadModel();
        if (!mounted || !_model.ready) {
          return;
        }
      }
      final params = imageRepairParams(mode: 'auto', overwrite: true);
      final group = widget.taskStore.createGroup(
        title: p.basename(_folder.root!),
        root: _folder.root!,
        kind: 'image',
        toolLabel: '图像修复',
        outputPolicy: _folder.policy.name,
        params: params,
        skipped: plan.skippedExisting,
      );
      var submitted = 0;
      var rejected = 0;
      for (final item in plan.pending) {
        try {
          widget.taskStore.submitResolved(
            kind: 'image',
            input: item.entry.path,
            output: item.output,
            params: params,
            groupId: group.id,
          );
          submitted++;
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
      _snack(
        '已提交 $submitted 张图片'
        '${rejected > 0 ? ' · 被拒 $rejected' : ''}'
        '${plan.skippedExisting > 0 ? ' · 跳过 ${plan.skippedExisting}' : ''}',
      );
    } finally {
      if (mounted) {
        setState(() {
          _submitting = false;
          _submitProgress = null;
        });
      }
    }
  }

  /// 涂抹按图片像素坐标生成黑白 mask: 白=修复, 黑=保留。
  /// 超大图先缩到 4096 长边, 由原生侧再缩回原尺寸, 避免 toImage 爆内存。
  Future<String?> _writeMask() async {
    if (_imageWidth <= 0 || _imageHeight <= 0 || _strokes.isEmpty) {
      return null;
    }
    final longest = math.max(_imageWidth, _imageHeight);
    final scale = longest > 4096 ? 4096 / longest : 1.0;
    final width = math.max(1, (_imageWidth * scale).round());
    final height = math.max(1, (_imageHeight * scale).round());
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(
      recorder,
      Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    );
    canvas.drawRect(
      Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      Paint()..color = const Color(0xFF000000),
    );
    final round = Paint()
      ..color = const Color(0xFFFFFFFF)
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;
    final dot = Paint()
      ..color = const Color(0xFFFFFFFF)
      ..isAntiAlias = true;
    for (final stroke in _strokes) {
      final radius = stroke.radius * width;
      final points = stroke.points
          .map((point) => Offset(point.dx * width, point.dy * height))
          .toList();
      if (points.isEmpty) {
        continue;
      }
      if (points.length == 1) {
        canvas.drawCircle(points.first, radius, dot);
        continue;
      }
      final path = Path()..moveTo(points.first.dx, points.first.dy);
      for (final point in points.skip(1)) {
        path.lineTo(point.dx, point.dy);
      }
      round.strokeWidth = radius * 2;
      canvas.drawPath(path, round);
    }
    final picture = recorder.endRecording();
    final image = await picture.toImage(width, height);
    picture.dispose();
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    if (data == null) {
      return null;
    }
    final dir = await getTemporaryDirectory();
    final file = File(
      p.join(
        dir.path,
        'avoxkit-mask-${DateTime.now().microsecondsSinceEpoch}.png',
      ),
    );
    await file.writeAsBytes(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      flush: true,
    );
    return file.path;
  }

  void _panStart(Offset local, Size size) {
    if (size.width <= 0 || size.height <= 0) {
      return;
    }
    final stroke = _Stroke(_brush);
    stroke.points.add(_normalize(local, size));
    setState(() {
      _strokes.add(stroke);
      _resultPath = null;
      _resultBytes = null;
      _showOriginal = false;
    });
  }

  void _panUpdate(Offset local, Size size) {
    if (_strokes.isEmpty || size.width <= 0 || size.height <= 0) {
      return;
    }
    final point = _normalize(local, size);
    final last = _strokes.last.points.last;
    if ((point - last).distance < 0.0015) {
      return;
    }
    setState(() => _strokes.last.points.add(point));
  }

  Offset _normalize(Offset local, Size size) {
    return Offset(
      (local.dx / size.width).clamp(0.0, 1.0),
      (local.dy / size.height).clamp(0.0, 1.0),
    );
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
                title: '图像修复',
                description: '自动识别并去除图片里的水印、台标和文字，也可以手动涂抹要修复的区域。'
                    '本地处理，文件不上传。',
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
              Text(folderMode ? '文件夹' : '图片', style: AkText.panelTitle),
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
                  noun: '图片',
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: _pickInput,
                    child: const Text('改成处理单张图片'),
                  ),
                ),
              ],
            )
          else if (_inputPath == null)
            AkSourcePicker(
              onFile: _pickInput,
              onFolder: _pickFolder,
              hint: 'JPG / PNG / BMP / WebP，也可以整个文件夹批量处理',
            )
          else
            _buildSinglePreview(),
          const SizedBox(height: 20),
          const Divider(height: 1),
          const SizedBox(height: 16),
          Text(
            folderMode
                ? '批量按自动识别处理：每张图独立找水印，识别不到就跳过。'
                    '输出默认放在源文件旁，文件名加 -repaired；重跑会覆盖同名结果。'
                : '自动识别适合水印位置不固定的图；手动涂抹适合已知位置的台标或文字。'
                    '重跑会覆盖同名的 -repaired 文件。',
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

  Widget _buildSinglePreview() {
    final task = widget.taskStore.taskById(_lastTaskId);
    final running = task != null && task.isActive;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
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
        const SizedBox(height: 16),
        Row(
          children: [
            Text(
              _mode == _RepairMode.auto ? '自动识别' : '手动涂抹',
              style: AkText.label,
            ),
            if (_resultBytes != null) ...[
              const SizedBox(width: 12),
              TextButton(
                onPressed: () => setState(() => _showOriginal = !_showOriginal),
                child: Text(_showOriginal ? '看修复后' : '看原图'),
              ),
            ],
          ],
        ),
        const SizedBox(height: 12),
        _imagePreview(task),
        if (_mode == _RepairMode.auto) ...[
          const SizedBox(height: 10),
          Row(
            children: [
              OutlinedButton.icon(
                onPressed: _detecting || _model.busy ? null : _detectWatermark,
                icon: _detecting
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.search, size: 17),
                label: Text(_detecting ? '识别中…' : '识别水印'),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  _detect == null
                      ? '也可以直接修复，任务里会自动识别。'
                      : _detect!.boxes.isEmpty
                      ? '没有识别到水印，试试手动涂抹。'
                      : '识别到 ${_detect!.boxes.length} 处可疑水印。',
                  style: AkText.micro,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ] else ...[
          const SizedBox(height: 10),
          Row(
            children: [
              Text('笔刷', style: AkText.label),
              Expanded(
                child: Slider(
                  value: _brush,
                  min: 0.01,
                  max: 0.2,
                  onChanged: (value) => setState(() => _brush = value),
                ),
              ),
              Text('${(_brush * 100).round()}%', style: AkText.mono),
            ],
          ),
          Row(
            children: [
              TextButton.icon(
                onPressed: _strokes.isEmpty
                    ? null
                    : () => setState(() => _strokes.removeLast()),
                icon: const Icon(Icons.undo, size: 16),
                label: const Text('撤销'),
              ),
              TextButton.icon(
                onPressed: _strokes.isEmpty
                    ? null
                    : () => setState(() => _strokes.clear()),
                icon: const Icon(Icons.layers_clear_outlined, size: 16),
                label: const Text('清空'),
              ),
            ],
          ),
        ],
        if (_imageError != null) ...[
          const SizedBox(height: 8),
          Text(
            _imageError!,
            style: AkText.body.copyWith(color: AkColors.danger),
          ),
        ],
        if (running) ...[
          const SizedBox(height: 8),
          Text(
            '${task.stageLabel}…',
            style: AkText.micro.copyWith(color: AkColors.accent),
          ),
        ] else if (task != null && task.state == 'failed') ...[
          const SizedBox(height: 8),
          Text(
            task.errorMessage ?? '修复失败',
            style: AkText.body.copyWith(color: AkColors.danger),
          ),
        ],
        const SizedBox(height: 12),
        TextButton(
          onPressed: _pickFolder,
          child: const Text('改成处理整个文件夹'),
        ),
      ],
    );
  }

  Widget _imagePreview(TaskItem? task) {
    final bytes = _showOriginal ? _inputBytes : (_resultBytes ?? _inputBytes);
    final aspect = _imageWidth > 0 && _imageHeight > 0
        ? _imageWidth / _imageHeight
        : 16 / 9;
    final editable = _mode == _RepairMode.mask && !_showOriginal;
    return Container(
      height: 420,
      decoration: BoxDecoration(
        color: AkColors.bgDeep,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AkColors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          if (bytes != null && _imageWidth > 0 && _imageHeight > 0)
            Center(
              child: AspectRatio(
                aspectRatio: aspect,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Image.memory(
                      bytes,
                      fit: BoxFit.contain,
                      gaplessPlayback: true,
                      filterQuality: FilterQuality.medium,
                    ),
                    if (!_showOriginal)
                      LayoutBuilder(
                        builder: (context, constraints) {
                          final size = constraints.biggest;
                          final painter = _MaskPainter(
                            strokes: editable ? _strokes : const [],
                            boxes: _mode == _RepairMode.auto
                                ? (_detect?.boxes ?? const [])
                                : const [],
                            showBoxes: _mode == _RepairMode.auto,
                            sourceWidth: _imageWidth.toDouble(),
                            sourceHeight: _imageHeight.toDouble(),
                          );
                          final canvas = CustomPaint(painter: painter);
                          if (!editable) {
                            return IgnorePointer(child: canvas);
                          }
                          return MouseRegion(
                            cursor: SystemMouseCursors.precise,
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onPanStart: (details) =>
                                  _panStart(details.localPosition, size),
                              onPanUpdate: (details) =>
                                  _panUpdate(details.localPosition, size),
                              child: canvas,
                            ),
                          );
                        },
                      ),
                  ],
                ),
              ),
            )
          else if (_loadingImage)
            const Center(child: CircularProgressIndicator())
          else
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.image_not_supported_outlined,
                    size: 28,
                    color: AkColors.faint,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    _imageError ?? '预览加载中…',
                    style: AkText.body.copyWith(color: AkColors.muted),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          if (_resultBytes != null && !_showOriginal)
            Positioned(
              left: 12,
              top: 12,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: AkColors.accent.withValues(alpha: 0.92),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Text(
                  '修复后',
                  style: TextStyle(
                    fontSize: 11,
                    color: AkColors.accentInk,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          if (_resultBytes == null &&
              !_loadingImage &&
              _mode == _RepairMode.mask &&
              _strokes.isEmpty &&
              _imageWidth > 0)
            Positioned(
              left: 12,
              right: 12,
              bottom: 12,
              child: Text(
                '在图片上按住拖动，涂出要移除的区域',
                style: AkText.micro.copyWith(color: AkColors.muted),
                textAlign: TextAlign.center,
              ),
            ),
          if (task != null && task.isActive && _resultBytes == null)
            Positioned(
              left: 12,
              right: 12,
              bottom: 12,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: task.progress <= 0 ? null : task.progress,
                  minHeight: 2,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildOptionsPanel(BatchPlan? plan) {
    final folderMode = _folder.hasFolder;
    final task = widget.taskStore.taskById(_lastTaskId);
    final canSubmit = !_submitting &&
        !_model.busy &&
        (folderMode
            ? (plan?.pending.isNotEmpty ?? false) && _lastGroupId == null
            : _inputPath != null &&
                _outputPath != null &&
                (task == null || !task.isActive));
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('修复方式', style: AkText.panelTitle),
          const SizedBox(height: 12),
          if (folderMode)
            Text(
              '批量统一用自动识别；单张涂抹区域不套用到整个文件夹。',
              style: AkText.body.copyWith(color: AkColors.muted),
            )
          else
            SegmentedButton<_RepairMode>(
              segments: const [
                ButtonSegment(
                  value: _RepairMode.auto,
                  label: Text('自动识别水印'),
                ),
                ButtonSegment(
                  value: _RepairMode.mask,
                  label: Text('手动涂抹'),
                ),
              ],
              selected: {_mode},
              showSelectedIcon: false,
              onSelectionChanged: (values) => setState(() {
                _mode = values.first;
                _strokes.clear();
                _detect = null;
                _resultPath = null;
                _resultBytes = null;
                _showOriginal = false;
              }),
            ),
          const SizedBox(height: 20),
          Text('输出格式', style: AkText.label),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: AkColors.bgDeep,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: AkColors.border),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<_OutputFormat>(
                value: _format,
                isExpanded: true,
                dropdownColor: AkColors.bgDeep,
                items: const [
                  DropdownMenuItem(
                    value: _OutputFormat.keep,
                    child: Text('保持原格式'),
                  ),
                  DropdownMenuItem(
                    value: _OutputFormat.png,
                    child: Text('PNG'),
                  ),
                  DropdownMenuItem(
                    value: _OutputFormat.jpg,
                    child: Text('JPG'),
                  ),
                ],
                onChanged: (value) {
                  if (value != null) {
                    _setFormat(value);
                  }
                },
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            _format == _OutputFormat.keep
                ? 'JPG 会轻微损失画质；需要继续编辑建议 PNG。'
                : '统一转成 ${_format.name.toUpperCase()}。',
            style: AkText.micro,
          ),
          if (!folderMode) ...[
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
                  onPressed: _inputPath == null ? null : _pickOutput,
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
          ] else ...[
            const SizedBox(height: 20),
            OutputPolicyPicker(source: _folder),
          ],
          if (!_model.ready || _model.busy) ...[
            const SizedBox(height: 20),
            _modelCard(),
          ] else ...[
            const SizedBox(height: 20),
            _modelReadyCard(),
          ],
          if (_submitProgress != null) ...[
            const SizedBox(height: 16),
            Text(_submitProgress!, style: AkText.micro),
          ],
          const SizedBox(height: 28),
          FilledButton(
            onPressed: canSubmit ? _submit : null,
            child: Text(
              _submitting
                  ? '提交中…'
                  : folderMode
                  ? (_lastGroupId != null
                        ? '已提交'
                        : plan == null || plan.pending.isEmpty
                        ? '没有可处理的图片'
                        : '开始修复 ${plan.count} 张图片')
                  : !_model.ready
                  ? '下载模型并开始修复'
                  : _mode == _RepairMode.mask
                  ? '修复涂抹区域'
                  : '开始修复',
            ),
          ),
        ],
      ),
    );
  }

  Widget _modelReadyCard() {
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
            child: Text('图像修复模型已就绪', style: AkText.micro),
          ),
          Text(InpaintModel.license, style: AkText.micro),
        ],
      ),
    );
  }

  Widget _modelCard() {
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
                  child: Text('正在下载图像修复模型', style: AkText.body),
                ),
                Text('$pct%', style: AkText.mono),
              ],
            ),
            const SizedBox(height: 8),
            LinearProgressIndicator(
              value: _model.progress <= 0 ? null : _model.progress,
              minHeight: 3,
            ),
            const SizedBox(height: 4),
            Text(InpaintModel.license, style: AkText.micro),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: _model.cancel,
                child: const Text('取消下载'),
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
          Text('图像修复模型未下载', style: AkText.body),
          const SizedBox(height: 4),
          Text(
            '首次修复才下载，${InpaintModel.downloadSizeLabel}，不随安装包分发。',
            style: AkText.micro,
          ),
          const SizedBox(height: 2),
          Text(InpaintModel.license, style: AkText.micro),
          if (_model.error != null) ...[
            const SizedBox(height: 8),
            Text(
              _model.error!,
              style: AkText.micro.copyWith(color: AkColors.danger),
            ),
          ],
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: _downloadModel,
            child: const Text('下载模型'),
          ),
        ],
      ),
    );
  }
}

class _MaskPainter extends CustomPainter {
  _MaskPainter({
    required this.strokes,
    required this.boxes,
    required this.showBoxes,
    required this.sourceWidth,
    required this.sourceHeight,
  });

  final List<_Stroke> strokes;
  final List<ImageBox> boxes;
  final bool showBoxes;
  final double sourceWidth;
  final double sourceHeight;

  @override
  void paint(Canvas canvas, Size size) {
    for (final stroke in strokes) {
      final radius = stroke.radius * size.width;
      final points = stroke.points
          .map((point) => Offset(point.dx * size.width, point.dy * size.height))
          .toList();
      if (points.isEmpty) {
        continue;
      }
      final paint = Paint()
        ..color = const Color(0x73E2725B)
        ..isAntiAlias = true;
      if (points.length == 1) {
        canvas.drawCircle(points.first, radius, paint);
        continue;
      }
      paint
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..strokeWidth = radius * 2;
      final path = Path()..moveTo(points.first.dx, points.first.dy);
      for (final point in points.skip(1)) {
        path.lineTo(point.dx, point.dy);
      }
      canvas.drawPath(path, paint);
    }
    if (!showBoxes) {
      return;
    }
    final border = Paint()
      ..color = AkColors.accent.withValues(alpha: 0.9)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    final fill = Paint()..color = AkColors.accent.withValues(alpha: 0.14);
    for (final box in boxes) {
      var rect = Rect.fromLTWH(
        box.x / math.max(1, sourceWidth) * size.width,
        box.y / math.max(1, sourceHeight) * size.height,
        box.w / math.max(1, sourceWidth) * size.width,
        box.h / math.max(1, sourceHeight) * size.height,
      );
      // 小水印框在缩略预览里只有几像素, 撑到可见尺寸再画
      rect = Rect.fromCenter(
        center: rect.center,
        width: math.max(rect.width, 8),
        height: math.max(rect.height, 8),
      );
      canvas.drawRect(rect, fill);
      canvas.drawRect(rect, border);
    }
  }

  @override
  bool shouldRepaint(covariant _MaskPainter oldDelegate) => true;
}
