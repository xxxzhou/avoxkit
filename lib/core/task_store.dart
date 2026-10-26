import 'dart:async';

import 'package:flutter/foundation.dart';

import '../native/ak_events.dart';
import 'engine.dart';
import 'task.dart';

class TaskStore extends ChangeNotifier {
  TaskStore(this.engine) {
    _subscription = engine.events.listen(_onEvent);
  }

  final Engine engine;
  final Map<int, TaskItem> _tasks = {};
  late final StreamSubscription<AkEvent> _subscription;

  List<TaskItem> get tasks {
    final values = _tasks.values.toList();
    values.sort((a, b) => b.id.compareTo(a.id));
    return values;
  }

  TaskItem? get latest => tasks.isEmpty ? null : tasks.first;

  TaskItem? taskById(int? id) => id == null ? null : _tasks[id];

  int submit({
    required String input,
    required String output,
    required String codec,
    required int quality,
    required bool hardware,
    bool overwrite = false,
  }) {
    return _submit(
      kind: 'transcode',
      input: input,
      output: output,
      params: {
        'container': 'mp4',
        'overwrite': overwrite,
        'video': {
          'codec': codec,
          'hardware': hardware ? 'auto' : 'off',
          'rate_mode': 'quality',
          'quality': quality,
        },
        'audio': {'codec': 'aac', 'bitrate_kbps': -1},
      },
    );
  }

  /// codec: aac | mp3 | copy (copy=原始音轨不重编码)
  int submitExtract({
    required String input,
    required String output,
    required String codec,
    int bitrateKbps = -1,
    bool overwrite = false,
  }) {
    return _submit(
      kind: 'extract',
      input: input,
      output: output,
      params: {
        'overwrite': overwrite,
        'extract': {'target': 'audio'},
        'audio': {'codec': codec, 'bitrate_kbps': bitrateKbps},
      },
    );
  }

  int submitRemux({
    required String input,
    required String output,
    bool overwrite = false,
  }) {
    return _submit(
      kind: 'remux',
      input: input,
      output: output,
      params: {'overwrite': overwrite},
    );
  }

  int _submit({
    required String kind,
    required String input,
    required String output,
    required Map<String, dynamic> params,
  }) {
    final task = <String, dynamic>{
      'schema': 1,
      'kind': kind,
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
      ),
    );
    // 事件可能先于 submit 返回到达, 这里补齐展示字段
    item.input ??= input;
    item.output ??= output;
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
