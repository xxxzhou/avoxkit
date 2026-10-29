import 'package:avoxkit/core/task.dart';
import 'package:avoxkit/ui/widgets/task_visual.dart';
import 'package:flutter_test/flutter_test.dart';

TaskItem task(String kind, {String? transMode, bool wave = false}) {
  final item = TaskItem(id: 1, kind: kind, input: 'in.mkv')
    ..state = 'running';
  if (transMode != null) {
    item.params = {'trans_mode': transMode};
  }
  if (wave) {
    item.wavePeaks.addAll([10, 40, 80]);
  }
  return item;
}

void main() {
  test('视频重编显示画面', () {
    expect(taskVisualMode(task('transcode', transMode: 'all')),
        TaskVisualMode.video);
    expect(taskVisualMode(task('transcode', transMode: 'audio_copy')),
        TaskVisualMode.video);
  });

  test('仅音频重编显示波形', () {
    expect(
        taskVisualMode(task('transcode', transMode: 'video_copy', wave: true)),
        TaskVisualMode.audio);
    expect(taskVisualMode(task('extract', wave: true)), TaskVisualMode.audio);
  });

  test('只换容器/无 PCM 只显示进度', () {
    expect(taskVisualMode(task('remux')), TaskVisualMode.progress);
    expect(taskVisualMode(task('transcode', transMode: 'video_copy')),
        TaskVisualMode.progress);
    expect(taskVisualMode(task('extract')), TaskVisualMode.progress);
    expect(taskVisualMode(task('subtitle')), TaskVisualMode.progress);
  });
}
