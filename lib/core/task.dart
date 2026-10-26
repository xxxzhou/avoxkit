import 'package:path/path.dart' as p;

import '../native/ak_events.dart';

class TaskItem {
  TaskItem({
    required this.id,
    required this.kind,
    this.input,
    this.output,
    this.groupId,
  }) : createdAt = DateTime.now();

  final int id;
  final String kind;
  String? input;
  final DateTime createdAt;

  /// 批量任务所属组; 单文件任务为 null
  int? groupId;

  String state = 'queued';
  String? stage;
  double progress = 0;
  int? currentMs;
  int? totalMs;
  String? output;
  String? errorCode;
  String? errorMessage;
  String? errorDetail;
  String? hint;
  bool cancelRequested = false;

  bool get isTerminal =>
      state == 'done' || state == 'failed' || state == 'cancelled';

  bool get isActive => !isTerminal;

  String get title {
    if (input == null || input!.isEmpty) {
      return '任务 #$id';
    }
    return p.basename(input!);
  }

  String get stateLabel {
    switch (state) {
      case 'queued':
        return '排队中';
      case 'running':
        return '处理中';
      case 'done':
        return '已完成';
      case 'failed':
        return '失败';
      case 'cancelled':
        return '已取消';
      default:
        return state;
    }
  }

  String get stageLabel {
    switch (stage) {
      case 'opening':
        return '打开文件';
      case 'recording':
        return switch (kind) {
          'extract' => '提取中',
          'remux' => '封装中',
          _ => '转码中',
        };
      case 'closing':
        return '收尾';
      default:
        return '处理中';
    }
  }

  void apply(AkEvent event) {
    switch (event.type) {
      case 'state':
        if (event.state != null) {
          state = event.state!;
        }
        if (event.stage != null) {
          stage = event.stage;
        }
        if (state == 'done') {
          progress = 1;
        }
        break;
      case 'progress':
        if (event.pct != null) {
          progress = (event.pct! / 100).clamp(0, 1);
        }
        currentMs = event.currentMs ?? currentMs;
        totalMs = event.totalMs ?? totalMs;
        break;
      case 'error':
        state = 'failed';
        errorCode = event.code;
        errorMessage = event.message;
        errorDetail = event.detail;
        hint = event.hint;
        break;
      case 'done':
        state = 'done';
        progress = 1;
        output = event.output ?? output;
        break;
    }
  }
}
