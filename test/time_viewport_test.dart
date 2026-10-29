import 'package:avoxkit/ui/widgets/time_viewport.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('满幅时 ms 与像素一一对应', () {
    final viewport = TimeViewport(durationMs: 10000);
    expect(viewport.isFull, isTrue);
    expect(viewport.xForMs(5000, 400), closeTo(200, 0.001));
    expect(viewport.msForX(200, 400), closeTo(5000, 0.001));
    expect(viewport.msForX(0, 400), closeTo(0, 0.001));
    expect(viewport.msForX(400, 400), closeTo(10000, 0.001));
  });

  test('以指针为锚缩放时锚点时间不动', () {
    final viewport = TimeViewport(durationMs: 10000);
    viewport.zoomAt(100, 0.5, 400);
    expect(viewport.span, closeTo(5000, 0.001));
    expect(viewport.msForX(100, 400), closeTo(2500, 1));
    viewport.zoomAt(100, 2.0, 400);
    expect(viewport.isFull, isTrue);
  });

  test('平移夹在片长内', () {
    final viewport = TimeViewport(durationMs: 10000);
    viewport.zoomAt(200, 0.5, 400);
    viewport.panBy(-3000);
    expect(viewport.viewStart, 0);
    expect(viewport.viewEnd, closeTo(viewport.span, 0.001));
    viewport.panBy(99999);
    expect(viewport.viewEnd, closeTo(10000, 0.001));
    expect(viewport.viewStart, closeTo(10000 - viewport.span, 0.001));
  });

  test('最短视口 1 秒', () {
    final viewport = TimeViewport(durationMs: 30000);
    for (var i = 0; i < 40; i++) {
      viewport.zoomAt(300, 0.8, 600);
    }
    expect(viewport.span, closeTo(1000, 0.001));
  });

  test('刻度间隔保证标签至少隔 64px', () {
    expect(TimeViewport.intervalForSpan(30000, 600), 5000);
    expect(TimeViewport.intervalForSpan(10000, 600), 2000);
    expect(TimeViewport.intervalForSpan(3600000, 600), 600000);
  });

  test('片长变化时回到全片', () {
    final viewport = TimeViewport(durationMs: 10000);
    viewport.zoomAt(200, 0.5, 400);
    viewport.durationMs = 20000;
    expect(viewport.isFull, isTrue);
    expect(viewport.viewStart, 0);
    expect(viewport.viewEnd, 20000);
  });
}
