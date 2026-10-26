import 'dart:io';

import 'package:avoxkit/core/batch.dart';
import 'package:avoxkit/core/folder_scan.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

FolderEntry entry(String relative) => FolderEntry(
      path: p.join('C:/media', relative),
      relative: relative,
      size: 1,
    );

void main() {
  group('BatchNamer', () {
    test('mirror 保留子目录', () {
      final item = entry(p.join('sub', 'a.mkv'));
      final namer = BatchNamer(
        policy: OutputPolicy.mirror,
        extension: 'mp4',
        outputRoot: 'C:/out',
      );
      expect(
        namer.pathFor(item, item.path),
        p.join('C:/out', 'sub', 'a.mp4'),
      );
    });

    test('flat 同名自动加后缀', () {
      final namer = BatchNamer(
        policy: OutputPolicy.flat,
        extension: 'mp4',
        outputRoot: 'C:/out',
      );
      final first = entry(p.join('a', 'x.mkv'));
      final second = entry(p.join('b', 'x.mkv'));
      expect(namer.pathFor(first, first.path), p.join('C:/out', 'x.mp4'));
      expect(
        namer.pathFor(second, second.path),
        p.join('C:/out', 'x (2).mp4'),
      );
    });

    test('sidecar 与输入同路径时改用 .out', () {
      final item = entry('a.mkv');
      final namer = BatchNamer(
        policy: OutputPolicy.sidecar,
        extension: 'mkv',
      );
      expect(
        namer.pathFor(item, item.path),
        p.join('C:/media', 'a.out.mkv'),
      );
    });

    test('sidecar 后缀避免覆盖源文件', () {
      final item = entry('a.mp4');
      final namer = BatchNamer(
        policy: OutputPolicy.sidecar,
        extension: 'mp4',
        sidecarSuffix: '.converted',
      );
      expect(
        namer.pathFor(item, item.path),
        p.join('C:/media', 'a.converted.mp4'),
      );
    });
  });

  group('planBatch', () {
    late Directory root;

    setUp(() {
      root = Directory.systemTemp.createTempSync('avoxkit-batch-');
    });

    tearDown(() {
      root.deleteSync(recursive: true);
    });

    BatchNamer namer() => BatchNamer(
          policy: OutputPolicy.flat,
          extension: 'mp4',
          outputRoot: root.path,
        );

    test('输出已存在时默认跳过', () {
      File(p.join(root.path, 'a.mp4')).writeAsStringSync('x');
      final plan = planBatch(entries: [entry('a.mkv')], namer: namer());
      expect(plan.count, 0);
      expect(plan.skippedExisting, 1);
    });

    test('没有冲突时进入待处理', () {
      final plan = planBatch(entries: [entry('b.mkv')], namer: namer());
      expect(plan.count, 1);
      expect(plan.skippedExisting, 0);
      expect(plan.totalBytes, 1);
    });
  });
}
