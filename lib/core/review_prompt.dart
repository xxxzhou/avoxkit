import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 成功任务满 3 次后请求一次评分；只请求一次，计数落盘。
/// 评分是新品进同类关键词前排的前提，但启动即弹会被低分反噬。
class ReviewPrompt {
  static const _channel = MethodChannel('dev.avox.avoxkit/review');
  static int _successes = 0;
  static bool _requested = false;
  static File? _file;

  static Future<void> load() async {
    try {
      final dir = await getApplicationSupportDirectory();
      _file = File(p.join(dir.path, 'review.json'));
      if (_file!.existsSync()) {
        final json = jsonDecode(await _file!.readAsString());
        if (json is Map) {
          _successes = (json['successes'] as num?)?.toInt() ?? 0;
          _requested = json['requested'] == true;
        }
      }
    } catch (_) {
      // 读不到就从 0 开始
    }
  }

  static Future<void> onTaskDone() async {
    if (_requested) {
      return;
    }
    _successes++;
    final requested = _successes >= 3;
    if (requested) {
      _requested = true;
    }
    final file = _file;
    if (file != null) {
      try {
        await file.parent.create(recursive: true);
        await file.writeAsString(
          jsonEncode({'successes': _successes, 'requested': _requested}),
          flush: true,
        );
      } catch (_) {
        // 写不进去只影响下次启动
      }
    }
    if (requested) {
      try {
        await _channel.invokeMethod('request');
      } catch (_) {
        // 非 MAS / 测试环境没有这个 channel
      }
    }
  }
}
