import 'dart:convert';
import 'dart:typed_data';

import 'package:avoxkit/core/media_frames.dart';
import 'package:avoxkit/ui/widgets/filmstrip.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// 1x1 PNG; 尺寸由 Positioned 的紧约束决定, 不依赖解码结果
final Uint8List _pixel = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA'
  '60e6kgAAAABJRU5ErkJggg==',
);

Widget _harness({required int frameWidth, required int frameHeight}) {
  final frames = List.generate(
    10,
    (i) => MediaFrame(ms: i * 3000, bytes: _pixel),
  );
  return MaterialApp(
    home: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 600,
          height: 150,
          child: AkFilmstrip(
            frames: frames,
            durationMs: 30000,
            viewStart: 0,
            viewEnd: 30000,
            frameWidth: frameWidth,
            frameHeight: frameHeight,
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('竖拍帧按输出宽高比排版, 上下留白不裁切', (tester) async {
    await tester.pumpWidget(_harness(frameWidth: 320, frameHeight: 569));
    await tester.pump();
    // 10 帧 30s 全视口 600px: cellPx=60 < 自然宽 150*320/569≈84.4,
    // 格子 60×106.7 垂直居中, 而不是 150 高的 16:9 cover 裁切
    final size = tester.getSize(find.byType(Image).first);
    expect(size.width, closeTo(60, 0.5));
    expect(size.height, closeTo(60 * 569 / 320, 0.5));
    expect(size.height, lessThan(150));
    expect(tester.getTopLeft(find.byType(Image).first).dy, greaterThan(0));
  });

  testWidgets('横拍帧保持 16:9 格子', (tester) async {
    await tester.pumpWidget(_harness(frameWidth: 640, frameHeight: 360));
    await tester.pump();
    final size = tester.getSize(find.byType(Image).first);
    expect(size.width, closeTo(60, 0.5));
    expect(size.height, closeTo(60 * 360 / 640, 0.5));
  });

  testWidgets('输出尺寸未知时按 16:9 兜底', (tester) async {
    await tester.pumpWidget(_harness(frameWidth: 0, frameHeight: 0));
    await tester.pump();
    final size = tester.getSize(find.byType(Image).first);
    expect(size.width, closeTo(60, 0.5));
    expect(size.height, closeTo(60 * 9 / 16, 0.5));
  });
}
