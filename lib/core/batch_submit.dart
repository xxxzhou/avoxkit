import 'batch.dart';
import 'task_store.dart';

/// 把展开后的文件逐个提交; 单个被拒不影响整组
int submitBatch({
  required TaskStore store,
  required int groupId,
  required BatchPlan plan,
  required int Function(String input, String output, int groupId) submitOne,
}) {
  var failures = 0;
  for (final item in plan.pending) {
    try {
      submitOne(item.entry.path, item.output, groupId);
    } catch (_) {
      failures++;
    }
  }
  return failures;
}
