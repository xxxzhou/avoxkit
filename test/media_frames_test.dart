import 'dart:convert';
import 'dart:typed_data';

import 'package:avoxkit/core/media_frames.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('缩略图张数跟着宽度走并夹在 6-24', () {
    expect(filmstripCount(280), 6);
    expect(filmstripCount(600), 8);
    expect(filmstripCount(1600), 21);
    expect(filmstripCount(3000), 24);
  });

  test('解析抓帧结果并跳过坏数据', () {
    final frames = MediaFrames.fromJson({
      'width': 160,
      'height': 90,
      'has_video': true,
      'frames': [
        {
          'ms': 1000,
          'image': base64Encode([1, 2, 3]),
        },
        {'ms': 2000, 'image': ''},
        {'ms': 3000},
        {
          'ms': 4000,
          'image': base64Encode([4, 5]),
        },
      ],
    });
    expect(frames.width, 160);
    expect(frames.height, 90);
    expect(frames.hasVideo, isTrue);
    expect(frames.frames.length, 2);
    expect(frames.frames.first.ms, 1000);
    expect(frames.frames.first.bytes, Uint8List.fromList([1, 2, 3]));
    expect(frames.frames.last.bytes, Uint8List.fromList([4, 5]));
  });

  test('无视频轨时结果为空但仍算成功', () {
    final frames = MediaFrames.fromJson({
      'width': 0,
      'height': 0,
      'has_video': false,
      'frames': <dynamic>[],
    });
    expect(frames.hasVideo, isFalse);
    expect(frames.isEmpty, isTrue);
  });

  test('最近帧: 等距取先出现的, 空列表返回 null', () {
    final first = MediaFrame(ms: 1000, bytes: Uint8List(0));
    final second = MediaFrame(ms: 2000, bytes: Uint8List(0));
    expect(nearestFrame([first, second], 1200)?.ms, 1000);
    expect(nearestFrame([first, second], 1600)?.ms, 2000);
    expect(nearestFrame([first, second], 1500)?.ms, 1000);
    expect(nearestFrame(const [], 1500), isNull);
  });
}
