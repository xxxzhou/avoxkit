import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../core/engine.dart';
import '../../native/ak_bindings.dart';
import '../tokens.dart';
import '../widgets/panel.dart';
import '../../core/i18n.dart';

/// 录屏页(录屏与自动缩放方案 §9.4 v1): 显示器/区域/音频/帧率选择与起停控制。
/// 只暴露引擎真实行为: 多输入=多文件(视频 mkv + 每路音频 wav), 不合成;
/// 录制中系统光标默认关闭(后期遥测重画), 可在开关里保留。
class RecordPage extends StatefulWidget {
  const RecordPage({super.key, required this.engine});

  final Engine engine;

  @override
  State<RecordPage> createState() => _RecordPageState();
}

class _RecordPageState extends State<RecordPage> {
  List<Map<String, dynamic>> _monitors = [];
  bool _hasMic = false;
  bool _hasLoop = false;
  String? _monitorId;
  double _fps = 60;
  bool _cursor = false;
  bool _mic = true;
  bool _loop = true;
  bool _fullScreen = true;
  final _regionW = TextEditingController();
  final _regionH = TextEditingController();
  final _outDir = TextEditingController();

  int? _sessionId;
  String _state = 'idle';
  int _clockMs = -1;
  double _fpsActual = 0;
  int _frames = 0;
  int _dropped = 0;
  String _geometry = '';
  Timer? _poll;
  String? _lastResult;
  String? _error;
  String? _sessionDir;
  int? _projectId;
  Timer? _exportTimer;
  bool _finalizing = false;
  bool _exporting = false;
  int _exportPct = 0;
  String _exportStage = '';
  String? _exportOut;

  @override
  void initState() {
    super.initState();
    // Windows 用 USERPROFILE; macOS/Linux 只有 HOME。空字符串会退化成相对
    // 路径 Videos/...，Finder 启动时 cwd=/ 建目录失败，音频 WAV 打不开。
    final home = Platform.environment['USERPROFILE'] ??
        Platform.environment['HOME'] ??
        '';
    _outDir.text = p.join(home, 'Videos', 'Avoxkit 录屏');
    _loadDevices();
  }

  @override
  void dispose() {
    _poll?.cancel();
    _exportTimer?.cancel();
    if (_projectId != null) {
      widget.engine.bindings.projectClose(_projectId!);
    }
    _regionW.dispose();
    _regionH.dispose();
    _outDir.dispose();
    super.dispose();
  }

  Future<void> _loadDevices() async {
    try {
      final json = jsonDecode(
        widget.engine.bindings.captureDevicesJson(),
      ) as Map<String, dynamic>;
      final monitors = (json['monitors'] as List? ?? [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      setState(() {
        _monitors = monitors;
        _hasMic = ((json['mics'] as List?) ?? []).isNotEmpty;
        _hasLoop = ((json['loops'] as List?) ?? []).isNotEmpty;
        if (_monitorId == null && monitors.isNotEmpty) {
          final primary = monitors.firstWhere(
            (m) => m['primary'] == true,
            orElse: () => monitors.first,
          );
          _monitorId = primary['id'] as String?;
        }
        if (!_mic && _hasMic) {
          _mic = true;
        }
      });
    } catch (error) {
      setState(() => _error = '枚举采集设备失败: $error');
    }
  }

  // 静态入口: 实例方法里创建的闭包会把 State(含 Timer) 一起捕获,
  // Isolate.run 发送时报 "object is unsendable"。
  static Future<String> _finalizeInIsolate(String request) =>
      Isolate.run(() => _captureFinalize(request));

  static String _captureFinalize(String request) =>
      AkBindings.open().captureFinalize(request);

  void _startPolling() {
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(milliseconds: 500), (_) {
      final id = _sessionId;
      if (id == null) {
        return;
      }
      try {
        final json = jsonDecode(
          widget.engine.bindings.captureStatus(id),
        ) as Map<String, dynamic>;
        if (json['ok'] != true) {
          // 会话已消失(被关闭/收尾): 界面回到就绪, 不再显示停止按钮
          if (json['code'] == -10) {
            _poll?.cancel();
            setState(() {
              _sessionId = null;
              _state = 'stopped';
            });
          }
          return;
        }
        setState(() {
          _state = json['state'] as String? ?? _state;
          _clockMs = (json['clock_ms'] as num?)?.toInt() ?? -1;
          _fpsActual = (json['fps'] as num?)?.toDouble() ?? 0;
          _frames = (json['frames'] as num?)?.toInt() ?? 0;
          _dropped = (json['dropped'] as num?)?.toInt() ?? 0;
          final geo = json['geometry'] as Map? ?? {};
          final gw = (geo['w'] as num?)?.toInt() ?? 0;
          final gh = (geo['h'] as num?)?.toInt() ?? 0;
          if (gw > 0 && gh > 0) {
            _geometry = '$gw×$gh';
          }
        });
      } catch (_) {
        // 单次轮询失败忽略, 下个周期重试
      }
    });
  }

  Future<void> _start() async {
    if (_finalizing) {
      return;
    }
    final monitor = _monitorId;
    if (monitor == null) {
      setState(() => _error = I18n.tr('没有可用的显示器采集设备'));
      return;
    }
    if (_outDir.text.trim().isEmpty) {
      setState(() => _error = I18n.tr('请选择输出目录'));
      return;
    }
    int regionW = 0;
    int regionH = 0;
    if (!_fullScreen) {
      regionW = int.tryParse(_regionW.text.trim()) ?? 0;
      regionH = int.tryParse(_regionH.text.trim()) ?? 0;
      if (regionW < 2 || regionH < 2 || regionW % 2 != 0 || regionH % 2 != 0) {
        setState(() => _error = I18n.tr('自定义区域须为大于 1 的偶数像素（宽×高）'));
        return;
      }
    }
    final request = jsonEncode({
      'out_dir': _outDir.text.trim(),
      'monitor_id': monitor,
      'fps': _fps,
      'cursor': _cursor,
      'mic': _mic && _hasMic,
      'loop': _loop && _hasLoop,
      'region_w': regionW,
      'region_h': regionH,
    });
    try {
      final json = jsonDecode(
        widget.engine.bindings.captureStart(request),
      ) as Map<String, dynamic>;
      if (json['ok'] != true) {
        setState(() => _error = '录制启动失败（代码 ${json['code']}）');
        return;
      }
      setState(() {
        _sessionId = (json['session_id'] as num).toInt();
        _state = 'starting';
        _error = null;
        _lastResult = null;
        _geometry = '';
      });
      _startPolling();
    } catch (error) {
      setState(() => _error = '录制启动失败: $error');
    }
  }

  Future<void> _pauseResume() async {
    final id = _sessionId;
    if (id == null) {
      return;
    }
    try {
      if (_state == 'recording') {
        widget.engine.bindings.capturePause(id);
      } else if (_state == 'paused') {
        widget.engine.bindings.captureResume(id);
      }
    } catch (error) {
      setState(() => _error = '$error');
    }
  }

  Future<void> _stop() async {
    final id = _sessionId;
    if (id == null) {
      return;
    }
    _poll?.cancel();
    setState(() {
      _state = 'stopping';
      _error = null;
      _lastResult = null;
    });
    // 会话状态跟着创建它的 isolate, stop 只回填/关文件, 必须留在主 isolate;
    // 混音+remux 只读文件, 放后台 isolate 才不卡长录制的 UI。
    Map<String, dynamic> stopped;
    try {
      stopped = jsonDecode(
        widget.engine.bindings.captureStop(id),
      ) as Map<String, dynamic>;
    } catch (error) {
      // 保留会话 id 和轮询, 让用户能再点一次停止
      setState(() {
        _state = 'recording';
        _error = '停止录制失败: $error';
      });
      _startPolling();
      return;
    }
    if (stopped['ok'] != true) {
      setState(() {
        _state = 'recording';
        _error = '停止录制失败（代码 ${stopped['code']}）；录制可能仍在继续，'
            '可再点一次停止';
      });
      _startPolling();
      return;
    }
    final dir = stopped['dir'] as String?;
    setState(() {
      _sessionId = null;
      _state = 'finalizing';
      _finalizing = true;
    });
    if (dir == null) {
      setState(() {
        _finalizing = false;
        _state = 'stopped';
      });
      return;
    }
    final request = jsonEncode({'dir': dir, 'via': 'isolate'});
    Map<String, dynamic> fin;
    try {
      fin =
          jsonDecode(await _finalizeInIsolate(request)) as Map<String, dynamic>;
    } catch (error) {
      fin = {'ok': false, 'error': '$error'};
    }
    if (fin['ok'] != true) {
      // 后台 isolate 打不开库/未初始化时退回主 isolate; finalize 只读文件可重入
      final reason = '${fin['error'] ?? '代码 ${fin['code']}'}';
      try {
        fin = jsonDecode(
          widget.engine.bindings.captureFinalize(
            jsonEncode({'dir': dir, 'via': 'host', 'isolate_error': reason}),
          ),
        ) as Map<String, dynamic>;
      } catch (_) {
        fin = {'ok': false, 'error': reason};
      }
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _finalizing = false;
      _state = 'stopped';
      final ok = fin['ok'] == true;
      _sessionDir = ok ? dir : null;
      _projectId = null;
      _exportOut = null;
      final durationMs = (fin['duration_ms'] as num?)?.toInt() ?? 0;
      final videos = (stopped['videos'] as List? ?? [])
          .whereType<String>()
          .toList();
      final audios = (stopped['audios'] as List? ?? [])
          .whereType<String>()
          .toList();
      final buffer = StringBuffer('输出目录: $dir');
      if (durationMs > 0) {
        buffer.write('\n时长: ${(durationMs / 1000).toStringAsFixed(1)} 秒');
      }
      final capture = fin['capture'] as String?;
      if (capture != null) {
        buffer.write('\n成片预览: $capture');
      }
      final project = fin['project'] as String?;
      if (project != null) {
        buffer.write('\n工程: $project');
      }
      if (audios.isNotEmpty) {
        buffer.write('\n音频: ${audios.join('\n')}');
      }
      if (videos.isNotEmpty) {
        buffer.write('\n原始视频: ${videos.join('\n')}');
      }
      _lastResult = buffer.toString();
      if (!ok) {
        final reason = fin['error'] ?? '代码 ${fin['code']}';
        _error = '整理成片失败（素材已保存）: $reason';
      }
    });
  }

  Future<void> _export() async {
    final dir = _sessionDir;
    if (dir == null || _exporting) {
      return;
    }
    final location = await getSaveLocation(
      suggestedName: '录屏-${DateTime.now().millisecondsSinceEpoch}.mp4',
      acceptedTypeGroups: const [
        XTypeGroup(label: 'MP4', extensions: ['mp4']),
      ],
    );
    if (location == null) {
      return;
    }
    setState(() {
      _exporting = true;
      _exportPct = 0;
      _exportStage = I18n.tr('准备');
      _exportOut = null;
      _error = null;
    });
    try {
      final open = jsonDecode(
        widget.engine.bindings.projectOpen(jsonEncode({'dir': dir})),
      ) as Map<String, dynamic>;
      if (open['ok'] != true) {
        throw Exception('打开工程失败（${open['code']}）');
      }
      final projectId = (open['project_id'] as num).toInt();
      _projectId = projectId;
      final start = jsonDecode(
        widget.engine.bindings.projectExport(
          projectId,
          jsonEncode({
            'out_path': location.path,
            'overwrite': true,
            // 输出帧率跟源(引擎按解码帧推进), 这里不传 fps 避免假承诺
            'quality': 65,
          }),
        ),
      ) as Map<String, dynamic>;
      if (start['ok'] != true) {
        throw Exception('导出启动失败（${start['code']}）');
      }
      _exportTimer?.cancel();
      _exportTimer = Timer.periodic(const Duration(milliseconds: 500), (timer) {
        final id = _projectId;
        if (id == null) {
          timer.cancel();
          return;
        }
        try {
          final status = jsonDecode(
            widget.engine.bindings.projectStatus(id),
          ) as Map<String, dynamic>;
          if (status['ok'] != true) {
            return;
          }
          final state = status['state'] as String? ?? 'running';
          if (!mounted) {
            timer.cancel();
            return;
          }
          setState(() {
            _exportPct = (status['pct'] as num?)?.toInt() ?? 0;
            _exportStage = status['stage'] as String? ?? '';
          });
          if (state == 'done' || state == 'failed' || state == 'cancelled') {
            timer.cancel();
            widget.engine.bindings.projectClose(id);
            _projectId = null;
            if (!mounted) {
              return;
            }
            setState(() {
              _exporting = false;
              if (state == 'done') {
                _exportOut = location.path;
              } else {
                final message = status['error'] ?? '';
                _error = state == 'cancelled' ? I18n.tr('导出已取消') : '导出失败: $message';
              }
            });
          }
        } catch (error) {
          timer.cancel();
          setState(() {
            _exporting = false;
            _error = '导出状态读取失败: $error';
          });
        }
      });
    } catch (error) {
      final id = _projectId;
      if (id != null) {
        widget.engine.bindings.projectClose(id);
        _projectId = null;
      }
      setState(() {
        _exporting = false;
        _error = '$error';
      });
    }
  }

  Future<void> _reveal(String path) async {
    if (Platform.isMacOS) {
      await Process.run('open', ['-R', path]);
    } else if (Platform.isWindows) {
      await Process.run('explorer.exe', ['/select,', path]);
    } else {
      await Process.run('xdg-open', [p.dirname(path)]);
    }
  }

  Future<void> _pickDir() async {
    final dir = await getDirectoryPath();
    if (dir != null) {
      setState(() => _outDir.text = dir);
    }
  }

  @override
  Widget build(BuildContext context) {
    final active = _sessionId != null;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(32, 32, 32, 40),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PageHeader(
            title: I18n.tr('录屏'),
            description: I18n.tr('把显示器画面连同系统声音/麦克风录成视频文件，' '本地处理，不上传。'),
          ),
          const SizedBox(height: 24),
          Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const T('设置', style: AkText.panelTitle),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 24,
                  runSpacing: 16,
                  crossAxisAlignment: WrapCrossAlignment.end,
                  children: [
                    _dropdown<String>(
                      label: I18n.tr('显示器'),
                      value: _monitorId,
                      items: _monitors
                          .map(
                            (m) => DropdownMenuItem(
                              value: m['id'] as String,
                              child: T(
                                '${m['name'] ?? m['id']}'
                                '（${m['w'] ?? '?'}×${m['h'] ?? '?'}）',
                                style: AkText.body,
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: active
                          ? null
                          : (v) => setState(() => _monitorId = v),
                    ),
                    _dropdown<double>(
                      label: I18n.tr('帧率'),
                      value: _fps,
                      items: const [60.0, 30.0]
                          .map(
                            (v) => DropdownMenuItem(
                              value: v,
                              child: T(
                                '${v.toInt()} fps',
                                style: AkText.body,
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: active
                          ? null
                          : (v) => setState(() => _fps = v ?? 60),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 24,
                  runSpacing: 8,
                  children: [
                    _switch(
                      I18n.tr('录下系统光标'),
                      _cursor,
                      !active,
                      (v) => setState(() => _cursor = v),
                    ),
                    _switch(
                      I18n.tr('麦克风'),
                      _mic && _hasMic,
                      !active && _hasMic,
                      (v) => setState(() => _mic = v),
                    ),
                    _switch(
                      I18n.tr('系统声音'),
                      _loop && _hasLoop,
                      !active && _hasLoop,
                      (v) => setState(() => _loop = v),
                    ),
                  ],
                ),
                if (_mic && !_hasMic)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: T('没有检测到麦克风，音轨将跳过。',
                      style: AkText.body.copyWith(color: AkColors.muted),
                    ),
                  ),
                if (!_hasLoop && Platform.isMacOS)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: T('macOS 暂不支持录制系统声音。',
                      style: AkText.body.copyWith(color: AkColors.muted),
                    ),
                  ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 24,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    _switch(
                      I18n.tr('整个屏幕'),
                      _fullScreen,
                      active,
                      (v) => setState(() => _fullScreen = v),
                    ),
                    if (!_fullScreen)
                      SizedBox(
                        width: 320,
                        child: Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: _regionW,
                                enabled: !active,
                                keyboardType: TextInputType.number,
                                style: AkText.body,
                                decoration: InputDecoration(
                                  isDense: true,
                                  labelText: I18n.tr('宽(px)'),
                                ),
                              ),
                            ),
                            const Padding(
                              padding: EdgeInsets.symmetric(horizontal: 8),
                              child: T('×', style: AkText.body),
                            ),
                            Expanded(
                              child: TextField(
                                controller: _regionH,
                                enabled: !active,
                                keyboardType: TextInputType.number,
                                style: AkText.body,
                                decoration: InputDecoration(
                                  isDense: true,
                                  labelText: I18n.tr('高(px)'),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    if (!_fullScreen)
                      T('从显示器左上角起，偶数像素',
                        style: AkText.body.copyWith(color: AkColors.muted),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _outDir,
                        enabled: !active,
                        style: AkText.body,
                        decoration: InputDecoration(
                          isDense: true,
                          labelText: I18n.tr('输出目录'),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    OutlinedButton(
                      onPressed: active ? null : _pickDir,
                      child: const T('选择…'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          Panel(
            color: AkColors.surfaceAlt,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const T('控制', style: AkText.panelTitle),
                const SizedBox(height: 16),
                Row(
                  children: [
                    FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: active
                            ? AkColors.danger
                            : AkColors.accent,
                        foregroundColor: active
                            ? Colors.white
                            : AkColors.accentInk,
                      ),
                      onPressed: active
                          ? (_state == 'stopping' ? null : _stop)
                          : (_finalizing ? null : _start),
                      icon: Icon(
                        active ? Icons.stop : Icons.fiber_manual_record,
                      ),
                      label: T(active ? I18n.tr('停止录制') : I18n.tr('开始录制')),
                    ),
                    const SizedBox(width: 12),
                    OutlinedButton(
                      onPressed:
                          active &&
                              (_state == 'recording' || _state == 'paused')
                          ? _pauseResume
                          : null,
                      child: T(_state == 'paused' ? I18n.tr('继续') : I18n.tr('暂停')),
                    ),
                    const SizedBox(width: 24),
                    T(
                      _state == 'stopping'
                          ? I18n.tr('状态: 正在停止…')
                          : _finalizing
                          ? I18n.tr('状态: 整理素材中…')
                          : active
                          ? '状态: $_state · 已录 '
                                '${_clockMs < 0 ? 0 : (_clockMs / 1000).toStringAsFixed(1)}s'
                          : I18n.tr('状态: 就绪'),
                      style: AkText.body.copyWith(color: AkColors.muted),
                    ),
                  ],
                ),
                if (active) ...[
                  const SizedBox(height: 12),
                  T('实际 ${_fpsActual.toStringAsFixed(1)} fps · 帧 $_frames · '
                    '丢弃 $_dropped'
                    '${_geometry.isEmpty ? '' : ' · 画面 $_geometry'}',
                    style: AkText.mono,
                  ),
                ],
                if (_lastResult != null) ...[
                  const SizedBox(height: 12),
                  T(_lastResult!, style: AkText.body),
                ],
                if (_sessionDir != null) ...[
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      FilledButton.icon(
                        onPressed: _exporting ? null : _export,
                        icon: const Icon(Icons.movie_creation_outlined),
                        label: T(_exporting ? I18n.tr('导出中…') : I18n.tr('导出成片')),
                      ),
                      if (_exportOut != null) ...[
                        const SizedBox(width: 12),
                        OutlinedButton(
                          onPressed: () => _reveal(_exportOut!),
                          child: const T('打开所在文件夹'),
                        ),
                      ],
                    ],
                  ),
                ],
                if (_exporting) ...[
                  const SizedBox(height: 10),
                  LinearProgressIndicator(value: _exportPct / 100.0),
                  const SizedBox(height: 6),
                  T(
                    '${_exportStage.isEmpty ? '处理中' : _exportStage} · '
                    '$_exportPct%',
                    style: AkText.mono,
                  ),
                ],
                if (_exportOut != null) ...[
                  const SizedBox(height: 8),
                  T('成片: $_exportOut', style: AkText.body),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  T(
                    _error!,
                    style: AkText.body.copyWith(color: AkColors.danger),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _dropdown<V>({
    required String label,
    required V? value,
    required List<DropdownMenuItem<V>> items,
    required ValueChanged<V?>? onChanged,
  }) {
    return SizedBox(
      width: 260,
      child: DropdownButtonFormField<V>(
        key: ValueKey<V?>(value),
        initialValue: value,
        items: items,
        onChanged: onChanged,
        decoration: InputDecoration(isDense: true, labelText: label),
      ),
    );
  }

  Widget _switch(
    String label,
    bool value,
    bool enabled,
    ValueChanged<bool> onChanged,
  ) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Switch(value: value, onChanged: enabled ? onChanged : null),
        const SizedBox(width: 6),
        T(label, style: AkText.body),
      ],
    );
  }
}
