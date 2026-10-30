import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 兼容性开关: Flutter Windows 无障碍桥在启动期被 UIA 客户端查询时可能崩溃
/// (flutter/flutter#175041), 关闭语义树可规避; 默认保持无障碍可用。
class CompatOptions {
  static final ValueNotifier<bool> disableAccessibility = ValueNotifier(false);

  static String? _path;

  static Future<void> load() async {
    final envForced = Platform.environment['AVOXKIT_DISABLE_A11Y'] == '1';
    try {
      final support = await getApplicationSupportDirectory();
      final file = File(p.join(support.path, 'compat.json'));
      _path = file.path;
      if (file.existsSync()) {
        final json = jsonDecode(await file.readAsString());
        if (json is Map && json['disable_accessibility'] is bool) {
          disableAccessibility.value = json['disable_accessibility'] as bool;
        }
      }
    } catch (_) {
      // 读不到就用默认值
    }
    if (envForced) {
      disableAccessibility.value = true;
    }
  }

  static Future<void> setDisableAccessibility(bool value) async {
    disableAccessibility.value = value;
    final path = _path;
    if (path == null) {
      return;
    }
    try {
      await File(path).writeAsString(
        jsonEncode({'disable_accessibility': value}),
      );
    } catch (_) {
      // 写不进去只影响下次启动
    }
  }
}
