import 'dart:async';

import 'package:flutter/foundation.dart';

import '../native/ak_events.dart';
import 'engine.dart';
import 'task.dart';
import 'task_group.dart';

class TaskStore extends ChangeNotifier {
  TaskStore(this.engine) {
    _subscription = engine.events.listen(_onEvent);
  }

  final Engine engine;
  final Map<int, TaskItem> _tasks = {};
  final Map<int, TaskGroup> _groups = {};
  int _nextGroupId = 1;
  late final StreamSubscription<AkEvent> _subscription;

  List<TaskItem> get tasks {
    final values = _tasks.values.toList();
    values.sort((a, b) => b.id.compareTo(a.id));
    return values;
  }

  TaskItem? get latest => tasks.isEmpty ? null : tasks.first;

  TaskItem? taskById(int? id) => id == null ? null : _tasks[id];

  List<TaskGroup> get groups {
    final values = _groups.values.toList();
    values.sort((a, b) => b.id.compareTo(a.id));
    return values;
  }

  TaskGroup? groupById(int? id) => id == null ? null : _groups[id];

  List<TaskItem> tasksOfGroup(int groupId) {
    final values =
        _tasks.values.where((task) => task.groupId == groupId).toList();
    values.sort((a, b) => a.id.compareTo(b.id));
    return values;
  }

  TaskGroup createGroup({
    required String title,
    required String root,
    required String kind,
    required String toolLabel,
    required String outputPolicy,
    Map<String, dynamic> params = const {},
    int skipped = 0,
  }) {
    final group = TaskGroup(
      id: _nextGroupId++,
      title: title,
      root: root,
      kind: kind,
      toolLabel: toolLabel,
      outputPolicy: outputPolicy,
      params: params,
      skipped: skipped,
    );
    _groups[group.id] = group;
    notifyListeners();
    return group;
  }

  /// 只重试组内失败项; 沿用建组时的 params
  int retryGroupFailed(int groupId) {
    final group = _groups[groupId];
    if (group == null) {
      return 0;
    }
    var retried = 0;
    for (final task in tasksOfGroup(groupId)) {
      if (task.state != 'failed' || task.input == null || task.output == null) {
        continue;
      }
      try {
        _submit(
          kind: group.kind,
          input: task.input!,
          output: task.output!,
          params: group.params,
          groupId: groupId,
        );
        retried++;
      } catch (_) {
        // 仍被拒就保持失败态
      }
    }
    return retried;
  }

  void cancelGroup(int groupId) {
    final group = _groups[groupId];
    if (group == null) {
      return;
    }
    for (final id in List<int>.from(group.taskIds)) {
      cancel(id);
    }
  }

  /// 单文件/批量共用同一份 params, 批量组重试时原样复用
  static Map<String, dynamic> transcodeParams({
    required String codec,
    required int quality,
    required bool hardware,
    bool overwrite = false,
  }) {
    return {
      'container': 'mp4',
      'overwrite': overwrite,
      'video': {
        'codec': codec,
        'hardware': hardware ? 'auto' : 'off',
        'rate_mode': 'quality',
        'quality': quality,
      },
      'audio': {'codec': 'aac', 'bitrate_kbps': -1},
    };
  }

  static Map<String, dynamic> extractParams({
    required String codec,
    int bitrateKbps = -1,
    bool overwrite = false,
  }) {
    return {
      'overwrite': overwrite,
      'extract': {'target': 'audio'},
      'audio': {'codec': codec, 'bitrate_kbps': bitrateKbps},
    };
  }

  static Map<String, dynamic> remuxParams({bool overwrite = false}) {
    return {'overwrite': overwrite};
  }

  int submit({
    required String input,
    required String output,
    required String codec,
    required int quality,
    required bool hardware,
    bool overwrite = false,
    int? groupId,
  }) {
    return _submit(
      kind: 'transcode',
      input: input,
      output: output,
      groupId: groupId,
      params: transcodeParams(
        codec: codec,
        quality: quality,
        hardware: hardware,
        overwrite: overwrite,
      ),
    );
  }

  /// codec: aac | mp3 | copy (copy=原始音轨不重编码)
  int submitExtract({
    required String input,
    required String output,
    required String codec,
    int bitrateKbps = -1,
    bool overwrite = false,
    int? groupId,
  }) {
    return _submit(
      kind: 'extract',
      input: input,
      output: output,
      groupId: groupId,
      params: extractParams(
        codec: codec,
        bitrateKbps: bitrateKbps,
        overwrite: overwrite,
      ),
    );
  }

  int submitRemux({
    required String input,
    required String output,
    bool overwrite = false,
    int? groupId,
  }) {
    return _submit(
      kind: 'remux',
      input: input,
      output: output,
      groupId: groupId,
      params: remuxParams(overwrite: overwrite),
    );
  }

  int _submit({
    required String kind,
    required String input,
    required String output,
    required Map<String, dynamic> params,
    int? groupId,
  }) {
    final group = groupById(groupId);
    final task = <String, dynamic>{
      'schema': 1,
      'kind': kind,
      if (group != null) 'group_id': 'g${group.id}',
      'sources': [
        {'kind': 'file', 'uri': input}
      ],
      'outputs': [
        {'role': 'primary', 'path': output}
      ],
      'params': params,
    };
    final id = engine.submit(task);
    final item = _tasks.putIfAbsent(
      id,
      () => TaskItem(
        id: id,
        kind: kind,
        input: input,
        output: output,
        groupId: groupId,
      ),
    );
    // 事件可能先于 submit 返回到达, 这里补齐展示字段
    item.input ??= input;
    item.output ??= output;
    item.groupId ??= groupId;
    if (group != null && !group.taskIds.contains(id)) {
      group.taskIds.add(id);
    }
    notifyListeners();
    return id;
  }

  void cancel(int taskId) {
    final item = _tasks[taskId];
    if (item != null && item.isActive) {
      item.cancelRequested = true;
      engine.cancel(taskId);
      notifyListeners();
    }
  }

  void _onEvent(AkEvent event) {
    final item = _tasks.putIfAbsent(
      event.taskId,
      () => TaskItem(
        id: event.taskId,
        kind: event.kind ?? 'transcode',
      ),
    );
    item.apply(event);
    notifyListeners();
  }

  @override
  void dispose() {
    _subscription.cancel();
    super.dispose();
  }
}
