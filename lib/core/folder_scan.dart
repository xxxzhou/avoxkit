import 'dart:io';
import 'dart:isolate';

/// 文件夹展开的输入: 只做纯文件系统工作, 可放进 isolate
class FolderScanRequest {
  const FolderScanRequest({
    required this.root,
    required this.extensions,
    this.recursive = true,
    this.maxItems = 5000,
    this.maxDepth = 32,
    this.skipStemSuffixes = const [],
  });

  final String root;

  /// 不带点的扩展名, 大小写不敏感
  final List<String> extensions;
  final bool recursive;
  final int maxItems;
  final int maxDepth;

  /// 跳过本工具上次的产物, 如 `converted` / `remux`
  final List<String> skipStemSuffixes;
}

class FolderEntry {
  const FolderEntry({
    required this.path,
    required this.relative,
    required this.size,
  });

  final String path;
  final String relative;
  final int size;
}

class FolderScanResult {
  const FolderScanResult({
    required this.root,
    required this.entries,
    required this.skipped,
    required this.truncated,
    this.error,
  });

  final String root;
  final List<FolderEntry> entries;
  final int skipped;
  final bool truncated;
  final String? error;

  int get count => entries.length;
  int get totalBytes => entries.fold(0, (sum, entry) => sum + entry.size);
}

const _skipDirs = {
  '.git',
  '.svn',
  '.hg',
  'system volume information',
  r'$recycle.bin',
};

Future<FolderScanResult> scanFolder(FolderScanRequest request) {
  return Isolate.run(() => scanFolderSync(request));
}

/// 同步实现; 只在后台 isolate 调, 避免 UI 卡顿
FolderScanResult scanFolderSync(FolderScanRequest request) {
  final root = Directory(request.root);
  if (!root.existsSync()) {
    return FolderScanResult(
      root: request.root,
      entries: const [],
      skipped: 0,
      truncated: false,
      error: '目录不存在',
    );
  }

  final extensions = request.extensions
      .map((value) => value.toLowerCase().replaceFirst('.', ''))
      .toSet();
  final seen = <String>{};
  final entries = <FolderEntry>[];
  var skipped = 0;
  var truncated = false;

  void walk(Directory dir, int depth) {
    if (truncated) {
      return;
    }
    List<FileSystemEntity> children;
    try {
      children = dir.listSync(followLinks: false);
    } catch (_) {
      skipped++;
      return;
    }
    for (final child in children) {
      if (truncated) {
        return;
      }
      final name = _basename(child.path);
      if (name.startsWith('.')) {
        skipped++;
        continue;
      }
      if (child is Link) {
        skipped++;
        continue;
      }
      if (child is Directory) {
        if (_skipDirs.contains(name.toLowerCase())) {
          skipped++;
          continue;
        }
        if (request.recursive && depth < request.maxDepth) {
          walk(child, depth + 1);
        }
        continue;
      }
      if (child is! File) {
        continue;
      }
      if (_skipTemp(name)) {
        skipped++;
        continue;
      }
      final ext = _extension(name);
      if (!extensions.contains(ext)) {
        skipped++;
        continue;
      }
      final stem = name.substring(0, name.length - ext.length - 1);
      if (request.skipStemSuffixes.any(
        (suffix) => stem.toLowerCase().endsWith('.$suffix'),
      )) {
        skipped++;
        continue;
      }
      // Windows 路径去重不区分大小写
      final key = child.path.toLowerCase();
      if (!seen.add(key)) {
        skipped++;
        continue;
      }
      int size = 0;
      try {
        size = child.lengthSync();
      } catch (_) {
        skipped++;
        continue;
      }
      entries.add(
        FolderEntry(
          path: child.path,
          relative: _relative(root.path, child.path),
          size: size,
        ),
      );
      if (entries.length >= request.maxItems) {
        truncated = true;
        return;
      }
    }
  }

  walk(root, 0);
  entries.sort((a, b) => naturalCompare(a.relative, b.relative));
  return FolderScanResult(
    root: request.root,
    entries: entries,
    skipped: skipped,
    truncated: truncated,
  );
}

String _basename(String path) {
  final index = path.lastIndexOf(RegExp(r'[\\/]'));
  return index < 0 ? path : path.substring(index + 1);
}

String _extension(String name) {
  final index = name.lastIndexOf('.');
  return index <= 0 ? '' : name.substring(index + 1).toLowerCase();
}

bool _skipTemp(String name) => name.contains('.avoxkit-part');

String _relative(String root, String path) {
  var base = root;
  if (!base.endsWith(r'\') && !base.endsWith('/')) {
    base += Platform.isWindows ? r'\' : '/';
  }
  if (path.toLowerCase().startsWith(base.toLowerCase())) {
    return path.substring(base.length);
  }
  return _basename(path);
}

/// 数字感知排序: 第2集 排在 第10集 前面
int naturalCompare(String a, String b) {
  var i = 0;
  var j = 0;
  while (i < a.length && j < b.length) {
    final ca = a.codeUnitAt(i);
    final cb = b.codeUnitAt(j);
    final da = _isDigit(ca);
    final db = _isDigit(cb);
    if (da && db) {
      var ei = i;
      while (ei < a.length && _isDigit(a.codeUnitAt(ei))) {
        ei++;
      }
      var ej = j;
      while (ej < b.length && _isDigit(b.codeUnitAt(ej))) {
        ej++;
      }
      final na = int.parse(a.substring(i, ei));
      final nb = int.parse(b.substring(j, ej));
      if (na != nb) {
        return na.compareTo(nb);
      }
      i = ei;
      j = ej;
      continue;
    }
    final lowerA = _lower(ca);
    final lowerB = _lower(cb);
    if (lowerA != lowerB) {
      return lowerA.compareTo(lowerB);
    }
    i++;
    j++;
  }
  final rest = (a.length - i).compareTo(b.length - j);
  return rest != 0 ? rest : a.compareTo(b);
}

bool _isDigit(int code) => code >= 0x30 && code <= 0x39;

int _lower(int code) => code >= 0x41 && code <= 0x5a ? code + 0x20 : code;
