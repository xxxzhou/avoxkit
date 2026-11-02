import 'package:avoxkit/core/task.dart';
import 'package:avoxkit/core/task_group.dart';
import 'package:avoxkit/core/task_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TaskStore 快照', () {
    test('终态任务字段原样往返', () {
      final failed = TaskItem(
        id: 3,
        kind: 'transcode',
        input: 'C:/media/a.mp4',
        output: 'C:/media/a.conv.mp4',
      )
        ..state = 'failed'
        ..progress = 0.4
        ..errorCode = 'E_OPEN'
        ..errorMessage = '打不开文件'
        ..errorDetail = 'avox: open failed';
      final done = TaskItem(id: 4, kind: 'remux', input: 'C:/b.mkv')
        ..state = 'done'
        ..output = 'C:/b.mp4';

      final parsed = TaskStore.parseSnapshot(
        TaskStore.snapshotOf([failed, done], const []),
      )!;

      final restoredFailed = parsed.tasks[TaskStore.restoredIdOffset + 3]!;
      expect(restoredFailed.state, 'failed');
      expect(restoredFailed.input, 'C:/media/a.mp4');
      expect(restoredFailed.output, 'C:/media/a.conv.mp4');
      expect(restoredFailed.progress, 0.4);
      expect(restoredFailed.errorCode, 'E_OPEN');
      expect(restoredFailed.errorMessage, '打不开文件');
      expect(restoredFailed.isTerminal, isTrue);

      final restoredDone = parsed.tasks[TaskStore.restoredIdOffset + 4]!;
      expect(restoredDone.state, 'done');
      expect(restoredDone.output, 'C:/b.mp4');
    });

    test('排队/运行中恢复为中断, id 加偏移', () {
      final running = TaskItem(
        id: 1,
        kind: 'extract',
        input: 'C:/media/a.mp4',
        output: 'C:/media/a.m4a',
      )
        ..state = 'running'
        ..progress = 0.7
        ..params = const {'overwrite': false};
      final queued = TaskItem(id: 2, kind: 'transcode')..state = 'queued';

      final parsed = TaskStore.parseSnapshot(
        TaskStore.snapshotOf([running, queued], const []),
      )!;

      final restored = parsed.tasks[TaskStore.restoredIdOffset + 1]!;
      expect(restored.state, 'interrupted');
      expect(restored.isActive, isFalse);
      expect(restored.progress, 0.7);
      expect(restored.params, const {'overwrite': false});
      expect(parsed.tasks[TaskStore.restoredIdOffset + 2]!.state, 'interrupted');
      expect(parsed.tasks.containsKey(1), isFalse);
    });

    test('组与任务归属按偏移重建, nextGroupId 续号', () {
      final group = TaskGroup(
        id: 7,
        title: 'C:/media',
        root: 'C:/media',
        kind: 'transcode',
        toolLabel: '转换',
        outputPolicy: 'mirror',
        params: const {'container': 'mp4'},
        skipped: 2,
      )..taskIds.addAll([1, 2]);
      final task = TaskItem(
        id: 1,
        kind: 'transcode',
        input: 'C:/media/a.mkv',
        output: 'C:/out/a.mp4',
        groupId: 7,
      );

      final parsed = TaskStore.parseSnapshot(
        TaskStore.snapshotOf([task], [group]),
      )!;

      final restoredGroup =
          parsed.groups[TaskStore.restoredIdOffset + 7]!;
      expect(restoredGroup.title, 'C:/media');
      expect(restoredGroup.outputPolicy, 'mirror');
      expect(restoredGroup.params, const {'container': 'mp4'});
      expect(restoredGroup.skipped, 2);
      expect(
        restoredGroup.taskIds,
        [
          TaskStore.restoredIdOffset + 1,
          TaskStore.restoredIdOffset + 2,
        ],
      );
      expect(
        parsed.tasks[TaskStore.restoredIdOffset + 1]!.groupId,
        TaskStore.restoredIdOffset + 7,
      );
      expect(parsed.nextGroupId, TaskStore.restoredIdOffset + 8);
    });

    test('schema 不认识的快照返回 null', () {
      expect(TaskStore.parseSnapshot({'schema': 99}), isNull);
    });
  });
}
