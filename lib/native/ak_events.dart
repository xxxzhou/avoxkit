class AkEvent {
  AkEvent({
    required this.type,
    required this.taskId,
    this.kind,
    this.state,
    this.stage,
    this.pct,
    this.currentMs,
    this.totalMs,
    this.code,
    this.message,
    this.detail,
    this.hint,
    this.output,
    this.queuePosition,
    this.ptsMs,
    this.bucketMs,
    this.peaks,
  });

  factory AkEvent.fromJson(Map<String, dynamic> json) {
    String? output;
    final outputs = json['outputs'];
    if (outputs is List && outputs.isNotEmpty && outputs.first is Map) {
      final first = outputs.first as Map;
      final path = first['path'];
      if (path is String) {
        output = path;
      }
    }
    List<int>? peaks;
    final rawPeaks = json['peaks'];
    if (rawPeaks is List) {
      peaks = rawPeaks.whereType<num>().map((value) => value.toInt()).toList();
    }
    return AkEvent(
      type: json['type'] as String? ?? 'unknown',
      taskId: (json['task_id'] as num?)?.toInt() ?? 0,
      kind: json['kind'] as String?,
      state: json['state'] as String?,
      stage: json['stage'] as String?,
      pct: (json['pct'] as num?)?.toDouble(),
      currentMs: (json['current_ms'] as num?)?.toInt(),
      totalMs: (json['total_ms'] as num?)?.toInt(),
      code: json['code'] as String?,
      message: json['message'] as String?,
      detail: json['detail'] as String?,
      hint: json['hint'] as String?,
      output: output,
      queuePosition: (json['queue_position'] as num?)?.toInt(),
      ptsMs: (json['pts_ms'] as num?)?.toInt(),
      bucketMs: (json['bucket_ms'] as num?)?.toInt(),
      peaks: peaks,
    );
  }

  final String type;
  final int taskId;
  final String? kind;
  final String? state;
  final String? stage;
  final double? pct;
  final int? currentMs;
  final int? totalMs;
  final String? code;
  final String? message;
  final String? detail;
  final String? hint;
  final String? output;
  final int? queuePosition;
  final int? ptsMs;
  final int? bucketMs;
  final List<int>? peaks;

  bool get isTerminal =>
      type == 'done' ||
      type == 'error' ||
      (type == 'state' && state == 'cancelled');
}
