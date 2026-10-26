import 'dart:io';

import 'package:avoxkit/core/folder_scan.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  group('naturalCompare', () {
    test('数字按数值比较', () {
      expect(naturalCompare('第2集.mp4', '第10集.mp4'), lessThan(0));
      expect(naturalCompare('a2.mp4', 'a10.mp4'), lessThan(0));
      expect(naturalCompare('a10.mp4', 'a10.mp4'), 0);
    });

    test('扩展名大小写不敏感', () {
      expect(naturalCompare('a.mp4', 'B.mkv'), lessThan(0));
    });
  });

  group('scanFolderSync', () {
    late Directory root;

    setUp(() {
      root = Directory.systemTemp.createTempSync('avoxkit-scan-');
      File(p.join(root.path, 'a.mp4')).writeAsStringSync('a');
      File(p.join(root.path, 'b.MKV')).writeAsStringSync('bb');
      File(p.join(root.path, 'note.txt')).writeAsStringSync('x');
      File(p.join(root.path, '.hidden.mp4')).writeAsStringSync('x');
      File(p.join(root.path, 'c.converted.mp4')).writeAsStringSync('x');
      File(p.join(root.path, 'd.avoxkit-part.mp4')).writeAsStringSync('x');
      final sub = Directory(p.join(root.path, 'sub'))..createSync();
      File(p.join(sub.path, '第10集.mp4')).writeAsStringSync('x');
      File(p.join(sub.path, '第2集.mp4')).writeAsStringSync('x');
    });

    tearDown(() {
      root.deleteSync(recursive: true);
    });

    test('递归扫描并过滤隐藏/临时/非白名单', () {
      final result = scanFolderSync(
        FolderScanRequest(
          root: root.path,
          extensions: const ['mp4', 'mkv'],
          skipStemSuffixes: const ['converted'],
        ),
      );
      final names = result.entries.map((entry) => p.basename(entry.path));
      expect(names, containsAll(<String>['a.mp4', 'b.MKV', '第2集.mp4', '第10集.mp4']));
      expect(names, isNot(contains('note.txt')));
      expect(names, isNot(contains('.hidden.mp4')));
      expect(names, isNot(contains('c.converted.mp4')));
      expect(names, isNot(contains('d.avoxkit-part.mp4')));
      expect(result.skipped, greaterThanOrEqualTo(4));
      expect(result.truncated, isFalse);
    });

    test('相对路径按自然序排列', () {
      final result = scanFolderSync(
        FolderScanRequest(root: root.path, extensions: const ['mp4', 'mkv']),
      );
      final relatives = result.entries.map((entry) => entry.relative).toList();
      final first = relatives.indexOf(p.join('sub', '第2集.mp4'));
      final second = relatives.indexOf(p.join('sub', '第10集.mp4'));
      expect(first, lessThan(second));
    });

    test('关闭递归只扫顶层', () {
      final result = scanFolderSync(
        FolderScanRequest(
          root: root.path,
          extensions: const ['mp4', 'mkv'],
          recursive: false,
        ),
      );
      expect(result.count, 3);
    });

    test('超过上限停止扫描', () {
      final result = scanFolderSync(
        FolderScanRequest(
          root: root.path,
          extensions: const ['mp4', 'mkv'],
          maxItems: 2,
        ),
      );
      expect(result.count, 2);
      expect(result.truncated, isTrue);
    });
  });
}
