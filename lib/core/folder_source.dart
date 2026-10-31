import 'package:flutter/foundation.dart';

import 'app_paths.dart';
import 'batch.dart';
import 'folder_scan.dart';

/// 一个工具页的文件夹输入: 扫描、递归、输出策略与展开计划
class FolderSource extends ChangeNotifier {
  FolderSource({
    required this.extensions,
    required this.skipStemSuffixes,
    required this.rootTag,
    this.policy = OutputPolicy.mirror,
  });

  final List<String> extensions;
  final List<String> skipStemSuffixes;

  /// 默认输出根目录的后缀, 如 converted / audio / remux
  final String rootTag;

  String? root;
  FolderScanResult? scan;
  bool scanning = false;
  bool recursive = true;
  OutputPolicy policy;
  String? outputRoot;

  BatchPlan? _cached;
  String? _cacheKey;

  bool get hasFolder => root != null;

  Future<void> pick(String path) async {
    root = path;
    scan = null;
    outputRoot ??= suggestRoot(path);
    notifyListeners();
    await rescan();
  }

  Future<void> rescan() async {
    final current = root;
    if (current == null) {
      return;
    }
    scanning = true;
    notifyListeners();
    final result = await scanFolder(
      FolderScanRequest(
        root: current,
        extensions: extensions,
        recursive: recursive,
        skipStemSuffixes: skipStemSuffixes,
      ),
    );
    if (root != current) {
      return;
    }
    scan = result;
    scanning = false;
    _invalidate();
    notifyListeners();
  }

  Future<void> setRecursive(bool value) async {
    if (recursive == value) {
      return;
    }
    recursive = value;
    await rescan();
  }

  void setPolicy(OutputPolicy value) {
    if (policy == value) {
      return;
    }
    policy = value;
    if (value != OutputPolicy.sidecar &&
        (outputRoot == null || outputRoot!.isEmpty)) {
      outputRoot = suggestRoot(root ?? '');
    }
    _invalidate();
    notifyListeners();
  }

  void setOutputRoot(String path) {
    outputRoot = path;
    _invalidate();
    notifyListeners();
  }

  void clear() {
    root = null;
    scan = null;
    scanning = false;
    outputRoot = null;
    _invalidate();
    notifyListeners();
  }

  String suggestRoot(String folder) {
    if (folder.isEmpty) {
      return '';
    }
    return AppPaths.suggestedBatchRoot(folder, rootTag);
  }

  /// 按工具的扩展名/命名规则展开; 结果按参数缓存, 避免拖动滑块时反复查磁盘
  BatchPlan? planFor({
    String? extension,
    String Function(FolderEntry entry)? extensionFrom,
    String? extensionTag,
    required String sidecarSuffix,
    bool skipExisting = true,
  }) {
    final entries = scan?.entries;
    if (entries == null || entries.isEmpty) {
      return null;
    }
    final key = '${identityHashCode(entries)}|${extension ?? ''}|'
        '${extensionTag ?? ''}|$sidecarSuffix|'
        '${policy.name}|$outputRoot|$skipExisting';
    if (key == _cacheKey) {
      return _cached;
    }
    _cached = planBatch(
      entries: entries,
      namer: BatchNamer(
        policy: policy,
        extension: extension,
        extensionOf: extensionFrom,
        outputRoot: policy == OutputPolicy.sidecar
            ? null
            : (outputRoot ?? suggestRoot(root ?? '')),
        sidecarSuffix: sidecarSuffix,
      ),
      skipExisting: skipExisting,
    );
    _cacheKey = key;
    return _cached;
  }

  void _invalidate() {
    _cacheKey = null;
    _cached = null;
  }
}
