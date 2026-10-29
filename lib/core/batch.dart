import 'dart:io';

import 'package:path/path.dart' as p;

import 'folder_scan.dart';

/// §15.4 的三种输出策略
enum OutputPolicy { sidecar, mirror, flat }

extension OutputPolicyLabel on OutputPolicy {
  String get label => switch (this) {
        OutputPolicy.sidecar => '源文件旁',
        OutputPolicy.mirror => '输出目录（保留子目录）',
        OutputPolicy.flat => '输出目录（平铺）',
      };
}

class BatchItem {
  const BatchItem({
    required this.entry,
    required this.output,
    required this.exists,
  });

  final FolderEntry entry;
  final String output;
  final bool exists;
}

class BatchPlan {
  const BatchPlan({
    required this.pending,
    required this.skippedExisting,
  });

  final List<BatchItem> pending;
  final int skippedExisting;

  int get count => pending.length;
  int get totalBytes =>
      pending.fold(0, (sum, item) => sum + item.entry.size);
}

/// 生成输出路径并处理同名冲突
class BatchNamer {
  BatchNamer({
    required this.policy,
    String? extension,
    this.extensionOf,
    this.outputRoot,
    this.sidecarSuffix = '',
  }) : extension = extension ?? '' {
    assert(this.extension.isNotEmpty || extensionOf != null);
  }

  final OutputPolicy policy;
  final String extension;

  /// 逐文件扩展名(转换页容器跟随源文件); 未提供时用 extension
  final String Function(FolderEntry entry)? extensionOf;
  final String? outputRoot;
  final String sidecarSuffix;
  final Set<String> _used = {};

  String _extensionFor(FolderEntry entry) {
    final value = extensionOf?.call(entry) ?? extension;
    return value.toLowerCase().replaceFirst('.', '');
  }

  String pathFor(FolderEntry entry, String input) {
    final ext = _extensionFor(entry);
    final stem = p.basenameWithoutExtension(input);
    String candidate;
    switch (policy) {
      case OutputPolicy.sidecar:
        candidate = p.join(
          p.dirname(input),
          '$stem$sidecarSuffix.$ext',
        );
        if (_samePath(candidate, input)) {
          candidate = p.join(
            p.dirname(input),
            '$stem.out.$ext',
          );
        }
      case OutputPolicy.mirror:
        final relativeDir = p.dirname(entry.relative);
        candidate = p.join(
          outputRoot!,
          relativeDir == '.' ? '' : relativeDir,
          '$stem$sidecarSuffix.$ext',
        );
      case OutputPolicy.flat:
        candidate = p.join(
          outputRoot!,
          '$stem$sidecarSuffix.$ext',
        );
    }
    return _dedupe(candidate, ext);
  }

  String _dedupe(String candidate, String extension) {
    var result = candidate;
    var index = 2;
    while (!_used.add(result.toLowerCase())) {
      result = p.join(
        p.dirname(candidate),
        '${p.basenameWithoutExtension(candidate)} ($index).$extension',
      );
      index++;
    }
    return result;
  }
}

BatchPlan planBatch({
  required List<FolderEntry> entries,
  required BatchNamer namer,
  bool skipExisting = true,
}) {
  final pending = <BatchItem>[];
  var skippedExisting = 0;
  for (final entry in entries) {
    final output = namer.pathFor(entry, entry.path);
    final exists = File(output).existsSync();
    if (skipExisting && exists) {
      skippedExisting++;
      continue;
    }
    pending.add(BatchItem(entry: entry, output: output, exists: exists));
  }
  return BatchPlan(pending: pending, skippedExisting: skippedExisting);
}

bool _samePath(String a, String b) =>
    p.canonicalize(a).toLowerCase() == p.canonicalize(b).toLowerCase();
