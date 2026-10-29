import 'package:avoxkit/core/media_index.dart';
import 'package:avoxkit/ui/widgets/trim_timeline.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

MediaIndex index300() {
  return MediaIndex(
    durationMs: 30000,
    bucketMs: 100,
    peaks: List<int>.filled(300, 40),
    keyframesMs: const [0, 2000, 4000, 6000, 8000, 10000, 12000, 14000, 16000],
    hasAudio: true,
  );
}

class Harness extends StatefulWidget {
  const Harness({super.key, this.durationMs = 30000});

  final int durationMs;

  @override
  State<Harness> createState() => HarnessState();
}

class HarnessState extends State<Harness> {
  int start = 10000;
  int end = 20000;
  (int, int)? last;
  int? scrub;
  int? frameCount;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 600,
            child: AkTrimTimeline(
              durationMs: widget.durationMs,
              startMs: start,
              endMs: end,
              index: index300(),
              onChanged: (range) {
                setState(() {
                  start = range.$1;
                  end = range.$2;
                  last = range;
                });
              },
              onScrub: (ms) => setState(() => scrub = ms),
              onFramesNeeded: (count) => setState(() => frameCount = count),
            ),
          ),
        ),
      ),
    );
  }
}

void main() {
  testWidgets('拖动起点手柄并吸附到关键帧', (tester) async {
    await tester.pumpWidget(const Harness());
    final state = tester.state<HarnessState>(find.byType(Harness));
    // 600px / 30s: 起点 10s 在 x=200; 拖到 x=300 => 15s, 吸附到 14s
    await tester.dragFrom(const Offset(200, 64), const Offset(100, 0));
    await tester.pumpAndSettle();
    expect(state.last, (14000, 20000));
    expect(state.start, 14000);
  });

  testWidgets('拖动终点手柄不吸附', (tester) async {
    await tester.pumpWidget(const Harness());
    final state = tester.state<HarnessState>(find.byType(Harness));
    // 终点 20s 在 x=400; 拖到 x=500 => 25s
    await tester.dragFrom(const Offset(400, 64), const Offset(100, 0));
    await tester.pumpAndSettle();
    expect(state.last, (10000, 25000));
  });

  testWidgets('拖动选区整体平移且起点吸附', (tester) async {
    await tester.pumpWidget(const Harness());
    final state = tester.state<HarnessState>(find.byType(Harness));
    // 从选区中间 15s 处拖到 18s, 长度 10s; 新起点 13s -> 吸附 12s
    await tester.dragFrom(const Offset(300, 64), const Offset(60, 0));
    await tester.pumpAndSettle();
    expect(state.last, (12000, 22000));
  });

  testWidgets('拖到出点附近会补齐抬起位置', (tester) async {
    await tester.pumpWidget(const Harness());
    final state = tester.state<HarnessState>(find.byType(Harness));
    // 快速把终点拖到 26s; onPanEnd 用抬起点补一次
    await tester.dragFrom(const Offset(400, 64), const Offset(120, 0));
    await tester.pumpAndSettle();
    expect(state.last, (10000, 26000));
  });

  testWidgets('片长未知时不响应拖动', (tester) async {
    await tester.pumpWidget(const Harness(durationMs: 0));
    final state = tester.state<HarnessState>(find.byType(Harness));
    await tester.dragFrom(const Offset(200, 64), const Offset(100, 0));
    await tester.pumpAndSettle();
    expect(state.last, isNull);
  });

  testWidgets('悬停给出指针时刻, 移出清空', (tester) async {
    await tester.pumpWidget(const Harness());
    final state = tester.state<HarnessState>(find.byType(Harness));
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: const Offset(50, 40));
    addTearDown(gesture.removePointer);
    await tester.pump();
    await gesture.moveTo(const Offset(300, 40));
    await tester.pump();
    expect(state.scrub, 15000);
    await gesture.moveTo(const Offset(700, 40));
    await tester.pump();
    expect(state.scrub, isNull);
  });

  testWidgets('拖动起点时 scrub 跟着手柄走', (tester) async {
    await tester.pumpWidget(const Harness());
    final state = tester.state<HarnessState>(find.byType(Harness));
    await tester.dragFrom(const Offset(200, 40), const Offset(100, 0));
    await tester.pumpAndSettle();
    expect(state.scrub, 14000);
  });

  testWidgets('首次布局按宽度请求缩略图张数', (tester) async {
    await tester.pumpWidget(const Harness());
    await tester.pump();
    final state = tester.state<HarnessState>(find.byType(Harness));
    // 600px / 76 => 8 张
    expect(state.frameCount, 8);
  });
}
