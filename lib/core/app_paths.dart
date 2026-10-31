import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// MAS builds compile with `--dart-define=AVOXKIT_SANDBOX=1`. In a sandbox the
/// powerbox only grants the file/folder the user picked, so writing next to the
/// source (or to a sibling folder) is denied; suggested outputs go to the app
/// container instead.
const bool kSandboxed = bool.fromEnvironment('AVOXKIT_SANDBOX');

class AppPaths {
  static String? _outputRoot;

  static Future<void> init() async {
    if (!kSandboxed) {
      return;
    }
    final docs = await getApplicationDocumentsDirectory();
    _outputRoot = p.join(docs.path, 'Avoxkit');
    await Directory(_outputRoot!).create(recursive: true);
  }

  static String? get sandboxOutputRoot => _outputRoot;

  /// 示例片段落盘目录; 沙盒内外都放在 Documents 下, 沙盒里即容器 Documents。
  static Future<String> sampleDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = p.join(docs.path, 'Avoxkit', 'Samples');
    await Directory(dir).create(recursive: true);
    return dir;
  }

  /// Suggested path for a single-file output.
  static String suggested(String input, String fileName) {
    if (kSandboxed) {
      return p.join(_outputRoot ?? Directory.systemTemp.path, fileName);
    }
    return p.join(p.dirname(input), fileName);
  }

  /// Suggested batch output root.
  static String suggestedBatchRoot(String inputFolder, String rootTag) {
    if (kSandboxed) {
      return p.join(_outputRoot ?? Directory.systemTemp.path, rootTag);
    }
    return p.join(p.dirname(inputFolder), '${p.basename(inputFolder)}-$rootTag');
  }
}
