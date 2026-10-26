/// 文件夹 fan-out 归组: 组元数据只在 Dart 侧, shim 只看到具体文件任务
class TaskGroup {
  TaskGroup({
    required this.id,
    required this.title,
    required this.root,
    required this.kind,
    required this.toolLabel,
    required this.outputPolicy,
    this.params = const {},
    this.skipped = 0,
  });

  final int id;
  final String title;
  final String root;
  final String kind;
  final String toolLabel;
  final String outputPolicy;

  /// 组内任务共用的 params(重试失败项时原样复用)
  final Map<String, dynamic> params;
  final DateTime createdAt = DateTime.now();
  final List<int> taskIds = [];

  /// 提交前因输出已存在而跳过的数量
  int skipped;
}
