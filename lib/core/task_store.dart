import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../native/ak_events.dart';
import 'after_complete.dart';
import 'engine.dart';
import 'i18n.dart';
import 'review_prompt.dart';
import 'task.dart';
import 'task_group.dart';

class TaskStore extends ChangeNotifier {
  TaskStore(this.engine) {
    _subscription = engine.events.listen(_onEvent);
  }

  final TaskEngine engine;

  /// 完整引擎: 预览等能力只有真引擎提供, 测试注入假引擎时为 null
  Engine? get fullEngine => engine is Engine ? engine as Engine : null;
  final Map<int, TaskItem> _tasks = {};
  final Map<int, TaskGroup> _groups = {};
  int _nextGroupId = 1;
  late final StreamSubscription<AkEvent> _subscription;

  /// 批量提交期间合并通知, 结束只刷一次; 避免 1000 次提交触发 1000 次重建
  int _batchDepth = 0;
  bool _notifyPending = false;

  /// 恢复的历史任务/组 id 加此偏移, 避免与引擎重启后从 1 起的原生 id 冲突
  static const restoredIdOffset = 1000000;

  /// 全部正常完成后的动作; 会话级, 默认无
  AfterCompleteAction afterComplete = AfterCompleteAction.none;

  /// 关机命令已发出时的 60 秒撤销提示
  String? shutdownNotice;

  Timer? _saveTimer;
  String? _filePath;

  List<TaskItem> get tasks {
    final values = _tasks.values.toList();
    values.sort((a, b) => b.id.compareTo(a.id));
    return values;
  }

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

  /// 批量组的预览目标: 正在跑的那一路, 否则退回最早排队的占位
  TaskItem? previewTaskOfGroup(int? groupId) {
    if (groupId == null) {
      return null;
    }
    return pickPreviewTask(tasksOfGroup(groupId));
  }

  static TaskItem? pickPreviewTask(List<TaskItem> tasks) {
    for (final task in tasks) {
      if (task.state == 'running') {
        return task;
      }
    }
    for (final task in tasks) {
      if (task.state == 'queued') {
        return task;
      }
    }
    return tasks.isEmpty ? null : tasks.last;
  }

  /// 单 worker FIFO: 前面还有几个未完成任务(含正在跑的那个)
  int queueAhead(TaskItem task) {
    var ahead = 0;
    for (final other in _tasks.values) {
      if (other.id >= task.id) {
        continue;
      }
      if (other.state == 'queued' || other.state == 'running') {
        ahead++;
      }
    }
    return ahead;
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
          kind: task.kind,
          input: task.input!,
          output: task.output!,
          params: task.params ?? group.params,
          groupId: groupId,
        );
        retried++;
      } catch (_) {
        // 仍被拒就保持失败态
      }
    }
    return retried;
  }

  /// 中断任务按原 spec 重提为全新任务; 原中断行移除, 组归属不变
  int requeueTask(int taskId) {
    final task = _tasks[taskId];
    if (task == null ||
        task.state != 'interrupted' ||
        task.input == null ||
        task.output == null) {
      return 0;
    }
    try {
      _submit(
        kind: task.kind,
        input: task.input!,
        output: task.output!,
        params: task.params ?? groupById(task.groupId)?.params ?? const {},
        groupId: task.groupId,
      );
    } catch (_) {
      // 引擎拒绝(如输出路径非法)就保持中断态
      return 0;
    }
    _tasks.remove(taskId);
    groupById(task.groupId)?.taskIds.remove(taskId);
    return taskId;
  }

  /// 组内中断项整体重新排队; 返回成功重提的数量
  int requeueGroupInterrupted(int groupId) {
    var requeued = 0;
    for (final id in List<int>.from(groupById(groupId)?.taskIds ?? const [])) {
      if (requeueTask(id) > 0) {
        requeued++;
      }
    }
    return requeued;
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

  /// 转换页按逐文件判定结果提交; kind/params 已由 ConversionPlan 解析
  int submitResolved({
    required String kind,
    required String input,
    required String output,
    required Map<String, dynamic> params,
    int? groupId,
  }) {
    return _submit(
      kind: kind,
      input: input,
      output: output,
      params: params,
      groupId: groupId,
    );
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
    item.params ??= params;
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

  /// 任务事件白名单: 录屏/工程导出也走同一回调, 但 type=event 且没有 task_id
  static const Set<String> taskEventTypes = {
    'state',
    'progress',
    'wave',
    'error',
    'done',
  };

  static bool isTaskEvent(AkEvent event) =>
      event.taskId > 0 && taskEventTypes.contains(event.type);

  void _onEvent(AkEvent event) {
    // 不过滤会凭空多出一个永远排队的「任务 #0」
    if (!isTaskEvent(event)) {
      return;
    }
    final hadActive = _tasks.values.any((task) => task.isActive);
    final item = _tasks.putIfAbsent(
      event.taskId,
      () => TaskItem(
        id: event.taskId,
        kind: event.kind ?? 'transcode',
      ),
    );
    final wasDone = item.state == 'done';
    item.apply(event);
    if (!wasDone && item.state == 'done') {
      ReviewPrompt.onTaskDone();
    }
    if (event.type == 'done') {
      _checkTargetSize(item);
    }
    if (AfterCompleteRunner.shouldFire(
      hadActive: hadActive,
      hasActive: _tasks.values.any((task) => task.isActive),
      lastState: item.state,
    )) {
      unawaited(_runAfterComplete());
    }
    notifyListeners();
  }

  /// 目标体积任务完成后校对实际体积, 偏差超过 10% 时在任务里提示
  void _checkTargetSize(TaskItem task) {
    final target = task.params?['target_size_bytes'];
    final output = task.output;
    if (target is! int || output == null || !File(output).existsSync()) {
      return;
    }
    final actual = File(output).lengthSync();
    final deviation = (actual - target) / target;
    if (deviation.abs() <= 0.1) {
      return;
    }
    final percent = (deviation * 100).round();
    final size = (actual / (1024 * 1024)).toStringAsFixed(1);
    task.hint = percent > 0
        ? I18n.tr('实际体积 $size MB，比目标大 $percent%')
        : I18n.tr('实际体积 $size MB，比目标小 ${-percent}%');
  }

  /// 恢复上次会话的任务与组; 未完成态一律按中断处理, 不假装续跑
  Future<void> restore() async {
    try {
      final support = await getApplicationSupportDirectory();
      final file = File(p.join(support.path, 'tasks.json'));
      _filePath = file.path;
      if (!file.existsSync()) {
        return;
      }
      final data = jsonDecode(await file.readAsString());
      if (data is Map) {
        _restoreSnapshot(Map<String, dynamic>.from(data));
        notifyListeners();
      }
    } catch (_) {
      // 恢复失败按空白会话继续
    }
  }

  void _restoreSnapshot(Map<String, dynamic> data) {
    final parsed = parseSnapshot(data);
    if (parsed == null) {
      return;
    }
    _tasks
      ..clear()
      ..addAll(parsed.tasks);
    _groups
      ..clear()
      ..addAll(parsed.groups);
    if (parsed.nextGroupId > _nextGroupId) {
      _nextGroupId = parsed.nextGroupId;
    }
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 400), () {
      unawaited(_saveNow());
    });
  }

  Future<void> _saveNow() async {
    final path = _filePath;
    if (path == null) {
      return;
    }
    try {
      final tmp = '$path.tmp';
      await File(tmp).writeAsString(
        jsonEncode(snapshotOf(_tasks.values, _groups.values)),
      );
      await File(tmp).rename(path);
    } catch (_) {
      // 落盘失败只影响下次启动的恢复
    }
  }

  @override
  void notifyListeners() {
    if (_batchDepth > 0) {
      _notifyPending = true;
      _scheduleSave();
      return;
    }
    super.notifyListeners();
    _scheduleSave();
  }

  /// 批量提交成组使用: begin → 逐个提交 → end, 期间通知合并为一次
  void beginBatch() {
    _batchDepth++;
  }

  void endBatch() {
    if (_batchDepth == 0) {
      return;
    }
    _batchDepth--;
    if (_batchDepth == 0 && _notifyPending) {
      _notifyPending = false;
      super.notifyListeners();
      _scheduleSave();
    }
  }

  /// 会话快照: 未完成任务统一写成 interrupted, 波形等运行期数据不入盘
  static Map<String, dynamic> snapshotOf(
    Iterable<TaskItem> tasks,
    Iterable<TaskGroup> groups,
  ) {
    String persistedState(String state) =>
        state == 'queued' || state == 'running' ? 'interrupted' : state;
    return {
      'schema': 1,
      'groups': [
        for (final group in groups)
          {
            'id': group.id,
            'title': group.title,
            'root': group.root,
            'kind': group.kind,
            'tool_label': group.toolLabel,
            'output_policy': group.outputPolicy,
            'params': group.params,
            'skipped': group.skipped,
            'task_ids': List<int>.from(group.taskIds),
          },
      ],
      'tasks': [
        for (final task in tasks)
          {
            'id': task.id,
            'kind': task.kind,
            'input': task.input,
            'output': task.output,
            'group_id': task.groupId,
            'params': task.params,
            'state': persistedState(task.state),
            'stage': task.stage,
            'progress': task.progress,
            'error_code': task.errorCode,
            'error_message': task.errorMessage,
            'error_detail': task.errorDetail,
            'hint': task.hint,
            'created_at': task.createdAt.toIso8601String(),
          },
      ],
    };
  }

  /// 解析磁盘快照: id 加偏移重建; 格式不可用时返回 null
  static ({
    Map<int, TaskItem> tasks,
    Map<int, TaskGroup> groups,
    int nextGroupId,
  })? parseSnapshot(Map<String, dynamic> data) {
    if (data['schema'] != 1) {
      return null;
    }
    final groups = <int, TaskGroup>{};
    var nextGroupId = 1;
    for (final raw in (data['groups'] as List? ?? const [])) {
      if (raw is! Map) {
        continue;
      }
      final id = raw['id'];
      if (id is! int) {
        continue;
      }
      final restoredId = restoredIdOffset + id;
      final group = TaskGroup(
        id: restoredId,
        title: raw['title'] is String ? raw['title'] as String : I18n.tr('批量组'),
        root: raw['root'] is String ? raw['root'] as String : '',
        kind: raw['kind'] is String ? raw['kind'] as String : 'transcode',
        toolLabel:
            raw['tool_label'] is String ? raw['tool_label'] as String : I18n.tr('批量'),
        outputPolicy: raw['output_policy'] is String
            ? raw['output_policy'] as String
            : 'sibling',
        params: raw['params'] is Map
            ? Map<String, dynamic>.from(raw['params'] as Map)
            : const {},
        skipped: raw['skipped'] is int ? raw['skipped'] as int : 0,
      );
      group.taskIds.addAll([
        for (final taskId in (raw['task_ids'] as List? ?? const []))
          if (taskId is int) restoredIdOffset + taskId,
      ]);
      groups[restoredId] = group;
      if (restoredId >= nextGroupId) {
        nextGroupId = restoredId + 1;
      }
    }
    final tasks = <int, TaskItem>{};
    for (final raw in (data['tasks'] as List? ?? const [])) {
      if (raw is! Map) {
        continue;
      }
      final id = raw['id'];
      if (id is! int || id <= 0) {
        continue;
      }
      final restoredId = restoredIdOffset + id;
      final task = TaskItem(
        id: restoredId,
        kind: raw['kind'] is String ? raw['kind'] as String : 'transcode',
        input: raw['input'] is String ? raw['input'] as String : null,
        output: raw['output'] is String ? raw['output'] as String : null,
        groupId: raw['group_id'] is int
            ? restoredIdOffset + (raw['group_id'] as int)
            : null,
      );
      task.params =
          raw['params'] is Map ? Map<String, dynamic>.from(raw['params'] as Map) : null;
      final state = raw['state'];
      task.state = state is String && state != 'queued' && state != 'running'
          ? state
          : 'interrupted';
      if (raw['stage'] is String) {
        task.stage = raw['stage'] as String;
      }
      if (raw['progress'] is num) {
        task.progress = (raw['progress'] as num).toDouble();
      }
      if (raw['error_code'] is String) {
        task.errorCode = raw['error_code'] as String;
      }
      if (raw['error_message'] is String) {
        task.errorMessage = raw['error_message'] as String;
      }
      if (raw['error_detail'] is String) {
        task.errorDetail = raw['error_detail'] as String;
      }
      if (raw['hint'] is String) {
        task.hint = raw['hint'] as String;
      }
      tasks[restoredId] = task;
    }
    return (tasks: tasks, groups: groups, nextGroupId: nextGroupId);
  }

  void setAfterComplete(AfterCompleteAction action) {
    if (afterComplete == action) {
      return;
    }
    afterComplete = action;
    notifyListeners();
  }

  Future<void> cancelShutdown() async {
    shutdownNotice = null;
    notifyListeners();
    try {
      await Process.run('shutdown', ['/a']);
    } catch (_) {
      // 撤销失败就等系统超时, 无副作用
    }
  }

  Future<void> _runAfterComplete() async {
    final action = afterComplete;
    if (action == AfterCompleteAction.none) {
      return;
    }
    // 引擎先落盘再置 done; 这里再把队列快照写完才动手
    await flush();
    final done = _tasks.values.where((task) => task.state == 'done').length;
    final failed =
        _tasks.values.where((task) => task.state == 'failed').length;
    await AfterCompleteRunner.run(
      action,
      done: done,
      failed: failed,
      onShutdownScheduled: () {
        shutdownNotice = I18n.tr('将在 60 秒后关机');
        notifyListeners();
      },
    );
  }

  /// 立即落盘队列快照并取消排程
  Future<void> flush() {
    _saveTimer?.cancel();
    _saveTimer = null;
    return _saveNow();
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    unawaited(_saveNow());
    _subscription.cancel();
    super.dispose();
  }
}
