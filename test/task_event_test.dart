import 'package:avoxkit/core/task_store.dart';
import 'package:avoxkit/native/ak_events.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('isTaskEvent', () {
    test('带 task_id 的任务事件收下', () {
      for (final type in ['state', 'progress', 'wave', 'error', 'done']) {
        final event = AkEvent.fromJson({'type': type, 'task_id': 3});
        expect(TaskStore.isTaskEvent(event), isTrue, reason: type);
      }
    });

    test('录屏/工程导出事件不建任务', () {
      final events = [
        {
          'type': 'event',
          'kind': 'capture_state',
          'session_id': 1,
          'from': 'idle',
          'to': 'recording',
        },
        {
          'type': 'event',
          'kind': 'capture_error',
          'session_id': 1,
          'track': 'video',
          'code': -1,
          'message': 'failed',
        },
        {
          'type': 'event',
          'kind': 'project_state',
          'project_id': 1,
          'export_id': 2,
          'state': 'running',
        },
        {
          'type': 'event',
          'kind': 'project_error',
          'project_id': 1,
          'export_id': 2,
          'code': 'export_failed',
        },
      ];
      for (final json in events) {
        final event = AkEvent.fromJson(json);
        expect(event.taskId, 0);
        expect(
          TaskStore.isTaskEvent(event),
          isFalse,
          reason: '${json['kind']}',
        );
      }
    });

    test('缺 task_id 的任务事件也不收', () {
      final event = AkEvent.fromJson({'type': 'state', 'state': 'queued'});
      expect(TaskStore.isTaskEvent(event), isFalse);
    });
  });
}
