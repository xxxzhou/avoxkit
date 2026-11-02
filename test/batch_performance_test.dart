import 'dart:async';

import 'package:avoxkit/core/engine.dart';
import 'package:avoxkit/core/task_store.dart';
import 'package:avoxkit/native/ak_events.dart';
import 'package:avoxkit/ui/pages/tasks_page.dart';
import 'package:avoxkit/ui/widgets/group_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 只满足 TaskStore 的最小假引擎; 提交返回自增 id, 事件流可空转
class _FakeEngine implements TaskEngine {
  final _events = StreamController<AkEvent>.broadcast();
  final submitted = <Map<String, dynamic>>[];
  int _nextId = 1;

  @override
  Stream<AkEvent> get events => _events.stream;

  @override
  int submit(Map<String, dynamic> task) {
    submitted.add(task);
    return _nextId++;
  }

  @override
  int cancel(int taskId) => 0;

  @override
  Future<void> openLogFolder() async {}

  @override
  Future<void> openFolder(String path) async {}
}

void main() {
  test('批量提交合并通知: 1000 次提交只重建一次', () async {
    final engine = _FakeEngine();
    final store = TaskStore(engine);
    var notifications = 0;
    store.addListener(() => notifications++);

    store.beginBatch();
    for (var i = 0; i < 1000; i++) {
      store.submitResolved(
        kind: 'transcode',
        input: 'C:/in/$i.mkv',
        output: 'C:/out/$i.mp4',
        params: const {},
      );
    }
    store.endBatch();

    expect(engine.submitted, hasLength(1000));
    expect(notifications, 1);

    await store.flush();
    store.dispose();
  });

  testWidgets('任务页 1000 个散装任务可渲染可滚动', (tester) async {
    final engine = _FakeEngine();
    final store = TaskStore(engine);
    store.beginBatch();
    for (var i = 0; i < 1000; i++) {
      store.submitResolved(
        kind: 'transcode',
        input: 'C:/in/$i.mkv',
        output: 'C:/out/$i.mp4',
        params: const {},
      );
    }
    store.endBatch();

    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: TasksPage(taskStore: store))),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);

    await tester.drag(find.byType(ListView).first, const Offset(0, -3000));
    await tester.pump();
    expect(tester.takeException(), isNull);

    await store.flush();
    store.dispose();
  });

  testWidgets('1000 项批量组默认折叠, 展开后组内虚拟滚动', (tester) async {
    final engine = _FakeEngine();
    final store = TaskStore(engine);
    final group = store.createGroup(
      title: 'media',
      root: 'C:/media',
      kind: 'transcode',
      toolLabel: '转换',
      outputPolicy: 'sidecar',
    );
    store.beginBatch();
    for (var i = 0; i < 1000; i++) {
      store.submitResolved(
        kind: 'transcode',
        input: 'C:/media/$i.mkv',
        output: 'C:/media/$i.out.mp4',
        params: const {},
        groupId: group.id,
      );
    }
    store.endBatch();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AkGroupCard(group: group, taskStore: store, showTasks: true),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('展开 1000 项任务'), findsOneWidget);
    expect(find.text('0.mkv'), findsNothing);

    await tester.tap(find.text('展开 1000 项任务'));
    await tester.pump();
    expect(find.text('收起'), findsOneWidget);
    expect(find.byType(ListView), findsOneWidget);

    await tester.drag(find.byType(ListView), const Offset(0, -500));
    await tester.pump();
    expect(tester.takeException(), isNull);

    await store.flush();
    store.dispose();
  });
}
