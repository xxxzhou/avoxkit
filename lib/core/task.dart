import 'dart:math' as math;

import 'package:path/path.dart' as p;

import '../native/ak_events.dart';
import './i18n.dart';

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

  /// 提交时解析后的参数; 批量组重试按每个任务自己的 kind/params 重提
  Map<String, dynamic>? params;
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

  /// 提交时在全局 FIFO 中的位置(1 起); 之后由 store 按 id 前缀动态推算
  int? queuePosition;

  /// 100ms 一格的峰值(0-100); 长任务会成对降采样并同步放大 bucketMs
  final List<int> wavePeaks = <int>[];
  int waveBucketMs = 100;
  int waveStartMs = 0;

  bool get hasWave => wavePeaks.isNotEmpty;

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
        return I18n.tr('排队中');
      case 'running':
        return I18n.tr('处理中');
      case 'done':
        return I18n.tr('已完成');
      case 'failed':
        return I18n.tr('失败');
      case 'cancelled':
        return I18n.tr('已取消');
      default:
        return state;
    }
  }

  String get stageLabel {
    switch (stage) {
      case 'opening':
        return I18n.tr('打开文件');
      case 'subtitle_extract':
        return I18n.tr('读取字幕轨');
      case 'decode':
        return I18n.tr('解码图片');
      case 'decode_mask':
        return I18n.tr('读取涂抹区域');
      case 'detect':
        return I18n.tr('识别水印');
      case 'inpaint':
        return I18n.tr('修复中');
      case 'encode':
        return I18n.tr('写入图片');
      case 'recording':
        return switch (kind) {
          'extract' => I18n.tr('提取中'),
          'remux' => I18n.tr('封装中'),
          'subtitle' => I18n.tr('识别中'),
          'trim' => I18n.tr('截取中'),
          _ => I18n.tr('转码中'),
        };
      case 'closing':
        return I18n.tr('收尾');
      default:
        return switch (kind) {
          'subtitle' => I18n.tr('字幕处理'),
          'image' => I18n.tr('图像修复'),
          _ => I18n.tr('处理中'),
        };
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
        if (event.queuePosition != null) {
          queuePosition = event.queuePosition;
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
      case 'wave':
        _applyWave(event);
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

  void _applyWave(AkEvent event) {
    final peaks = event.peaks;
    if (peaks == null || peaks.isEmpty) {
      return;
    }
    if (wavePeaks.isEmpty) {
      // 截取任务的进度已经映射成I18n.tr("片段内相对时间"), 波形也从 0 起算
      waveStartMs = kind == 'trim' ? 0 : (event.ptsMs ?? 0);
      waveBucketMs = event.bucketMs ?? 100;
    }
    wavePeaks.addAll(peaks);
    // 长片控制内存: 成对取最大值, 时间分辨率同步减半
    while (wavePeaks.length > 6000) {
      final length = wavePeaks.length;
      final compacted = <int>[];
      for (var i = 0; i + 1 < length; i += 2) {
        compacted.add(math.max(wavePeaks[i], wavePeaks[i + 1]));
      }
      if (length.isOdd) {
        compacted.add(wavePeaks.last);
      }
      wavePeaks
        ..clear()
        ..addAll(compacted);
      waveBucketMs *= 2;
    }
  }
}
