import 'package:avoxkit/core/task.dart';
import 'package:avoxkit/core/task_store.dart';
import 'package:flutter_test/flutter_test.dart';

TaskItem task(int id, String state) => TaskItem(id: id, kind: 'transcode')
  ..state = state;

void main() {
  group('pickPreviewTask', () {
    test('优先正在运行的任务', () {
      final picked = TaskStore.pickPreviewTask([
        task(1, 'done'),
        task(2, 'running'),
        task(3, 'queued'),
      ]);
      expect(picked?.id, 2);
    });

    test('没有运行项时退回最早排队项', () {
      final picked = TaskStore.pickPreviewTask([
        task(1, 'done'),
        task(2, 'queued'),
        task(3, 'queued'),
      ]);
      expect(picked?.id, 2);
    });

    test('全部结束保留最后一路占位', () {
      final picked = TaskStore.pickPreviewTask([
        task(1, 'done'),
        task(2, 'done'),
      ]);
      expect(picked?.id, 2);
    });

    test('空组没有预览目标', () {
      expect(TaskStore.pickPreviewTask([]), isNull);
    });
  });
}
