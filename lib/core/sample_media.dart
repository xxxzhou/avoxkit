import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'app_paths.dart';

/// 内置示例片段: App 是本地工具, 新装没有素材; 审核员/新用户点一下就能跑通
/// 转换/截取/提音频的完整链路。
class SampleMedia {
  static const asset = 'assets/sample/avoxkit-demo.mp4';
  static const fileName = 'avoxkit-demo.mp4';

  static String? _cached;

  static Future<String> materialize() async {
    final cached = _cached;
    if (cached != null && File(cached).existsSync()) {
      return cached;
    }
    final dir = await AppPaths.sampleDir();
    final file = File(p.join(dir, fileName));
    if (!file.existsSync() || file.lengthSync() == 0) {
      final data = await rootBundle.load(asset);
      await file.writeAsBytes(data.buffer.asUint8List(), flush: true);
    }
    _cached = file.path;
    return file.path;
  }
}
