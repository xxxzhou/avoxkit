import 'dart:io';

import 'package:avoxkit/ui/widgets/media_source.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('拖入路径取第一个扩展名匹配的普通文件', () async {
    final dir = await Directory.systemTemp.createTemp('avoxkit_drop');
    addTearDown(() => dir.delete(recursive: true));
    final txt = File('${dir.path}/a.txt')..writeAsStringSync('x');
    final mp4 = File('${dir.path}/b.mp4')..writeAsStringSync('x');
    final mkv = File('${dir.path}/c.MKV')..writeAsStringSync('x');

    // 目录与不支持的文件跳过; 扩展名大小写不敏感
    expect(
      AkSourcePicker.firstAcceptedFile(
        [dir.path, txt.path, mp4.path, mkv.path],
        kVideoExtensions,
      ),
      mp4.path,
    );
    expect(
      AkSourcePicker.firstAcceptedFile([mkv.path], kVideoExtensions),
      mkv.path,
    );
    expect(
      AkSourcePicker.firstAcceptedFile([txt.path], kVideoExtensions),
      isNull,
    );
    expect(
      AkSourcePicker.firstAcceptedFile([dir.path], kVideoExtensions),
      isNull,
    );
  });
}
