import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 工具页实现此接口即可获得预设能力; 值的键名由页面自定,
/// 预设机制只存取不解释其含义
abstract class ToolPresetHost {
  /// 工具内唯一; 出厂/用户预设按它分组
  String get presetToolId;

  Map<String, dynamic> capturePresetValues();

  void applyPresetValues(Map<String, dynamic> values);
}

class ToolPreset {
  const ToolPreset({
    required this.toolId,
    required this.name,
    required this.values,
    this.builtin = false,
  });

  final String toolId;
  final String name;
  final Map<String, dynamic> values;

  /// 出厂预设来自代码, 不可删除或覆盖
  final bool builtin;

  Map<String, dynamic> toJson() => {
        'tool_id': toolId,
        'name': name,
        'values': values,
      };
}

/// 出厂预设: 与各页快捷设置同语义, 能力回退在应用时按本机探测处理
const builtinPresets = <ToolPreset>[
  ToolPreset(
    toolId: 'convert',
    name: '仅换容器 MP4',
    builtin: true,
    values: {
      'container': 'mp4',
      'video': 'source',
      'audio': 'source',
      'audio_bitrate_kbps': -1,
      'quality': 60,
      'hardware': false,
    },
  ),
  ToolPreset(
    toolId: 'convert',
    name: 'H.265 · 1080p',
    builtin: true,
    values: {
      'container': 'mp4',
      'video': 'h265',
      'height': 1080,
      'audio': 'source',
      'audio_bitrate_kbps': -1,
      'quality': 60,
      'hardware': false,
    },
  ),
  ToolPreset(
    toolId: 'convert',
    name: 'H.264 · 1080p',
    builtin: true,
    values: {
      'container': 'mp4',
      'video': 'h264',
      'height': 1080,
      'audio': 'source',
      'audio_bitrate_kbps': -1,
      'quality': 60,
      'hardware': false,
    },
  ),
  ToolPreset(
    toolId: 'convert',
    name: '微信 25MB',
    builtin: true,
    values: {
      'container': 'mp4',
      'video': 'h264',
      'audio': 'source',
      'audio_bitrate_kbps': -1,
      'quality': 60,
      'hardware': false,
      'target_size_mb': 25,
    },
  ),
  ToolPreset(
    toolId: 'extract',
    name: '原始音轨',
    builtin: true,
    values: {'format': 'copy', 'bitrate_kbps': 192},
  ),
  ToolPreset(
    toolId: 'extract',
    name: 'M4A · 192',
    builtin: true,
    values: {'format': 'm4a', 'bitrate_kbps': 192},
  ),
  ToolPreset(
    toolId: 'extract',
    name: 'MP3 · 192',
    builtin: true,
    values: {'format': 'mp3', 'bitrate_kbps': 192},
  ),
];

/// 用户预设落盘应用数据目录; 出厂预设不入盘。
/// [storageDir] 供测试/便携形态注入, 默认走 path_provider。
class PresetStore extends ChangeNotifier {
  PresetStore({List<ToolPreset>? builtin, this.storageDir})
      : _builtin = List.unmodifiable(builtin ?? builtinPresets);

  final List<ToolPreset> _builtin;
  final List<ToolPreset> _user = [];
  final String? storageDir;
  Timer? _saveTimer;
  String? _filePath;

  static final PresetStore instance = PresetStore();

  List<ToolPreset> presetsFor(String toolId) => [
        ..._builtin.where((preset) => preset.toolId == toolId),
        ..._user.where((preset) => preset.toolId == toolId),
      ];

  ToolPreset? byName(String toolId, String name) {
    for (final preset in presetsFor(toolId)) {
      if (preset.name == name) {
        return preset;
      }
    }
    return null;
  }

  /// 同名覆盖用户预设; 与出厂预设重名返回 false
  bool save({
    required String toolId,
    required String name,
    required Map<String, dynamic> values,
  }) {
    if (_builtin
        .any((preset) => preset.toolId == toolId && preset.name == name)) {
      return false;
    }
    _user.removeWhere(
      (preset) => preset.toolId == toolId && preset.name == name,
    );
    _user.insert(
      0,
      ToolPreset(
        toolId: toolId,
        name: name,
        values: Map<String, dynamic>.of(values),
      ),
    );
    _scheduleSave();
    notifyListeners();
    return true;
  }

  /// 只能删除用户预设; 返回是否删除
  bool delete(ToolPreset preset) {
    if (preset.builtin || !_user.contains(preset)) {
      return false;
    }
    _user.remove(preset);
    _scheduleSave();
    notifyListeners();
    return true;
  }

  Future<void> restore() async {
    try {
      final dir = storageDir != null
          ? Directory(storageDir!)
          : await getApplicationSupportDirectory();
      final file = File(p.join(dir.path, 'presets.json'));
      _filePath = file.path;
      if (!file.existsSync()) {
        return;
      }
      final data = jsonDecode(await file.readAsString());
      if (data is! Map || data['schema'] != 1 || data['presets'] is! List) {
        return;
      }
      _user
        ..clear()
        ..addAll([
          for (final raw in data['presets'] as List)
            if (raw is Map &&
                raw['tool_id'] is String &&
                raw['name'] is String &&
                raw['values'] is Map)
              ToolPreset(
                toolId: raw['tool_id'] as String,
                name: raw['name'] as String,
                values: Map<String, dynamic>.from(raw['values'] as Map),
              ),
        ]);
      notifyListeners();
    } catch (_) {
      // 恢复失败按只有出厂预设继续
    }
  }

  /// 立即落盘并取消排程; dispose 与测试收尾都走这里
  Future<void> flush() {
    _saveTimer?.cancel();
    _saveTimer = null;
    return _saveNow();
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 400), () {
      unawaited(_saveNow());
    });
  }

  Future<void> _saveNow() async {
    final path = _filePath;
    if (path == null) {
      return;
    }
    try {
      final tmp = '$path.tmp';
      await File(tmp).writeAsString(
        jsonEncode({'schema': 1, 'presets': [for (final preset in _user) preset.toJson()]}),
      );
      await File(tmp).rename(path);
    } catch (_) {
      // 落盘失败只影响下次启动
    }
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    unawaited(_saveNow());
    super.dispose();
  }
}
