import 'package:avoxkit/core/after_complete.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AfterCompleteRunner.shouldFire', () {
    test('空闲沿 + 正常完成才触发', () {
      expect(
        AfterCompleteRunner.shouldFire(
          hadActive: true,
          hasActive: false,
          lastState: 'done',
        ),
        isTrue,
      );
    });

    test('手动取消/失败收尾/队列仍有活跃任务都不触发', () {
      expect(
        AfterCompleteRunner.shouldFire(
          hadActive: true,
          hasActive: false,
          lastState: 'cancelled',
        ),
        isFalse,
        reason: '用户主动取消, 不该关机',
      );
      expect(
        AfterCompleteRunner.shouldFire(
          hadActive: true,
          hasActive: false,
          lastState: 'failed',
        ),
        isFalse,
        reason: '失败收尾, 用户需要看到错误',
      );
      expect(
        AfterCompleteRunner.shouldFire(
          hadActive: true,
          hasActive: true,
          lastState: 'done',
        ),
        isFalse,
        reason: '队列还没排空',
      );
      expect(
        AfterCompleteRunner.shouldFire(
          hadActive: false,
          hasActive: false,
          lastState: 'done',
        ),
        isFalse,
        reason: '本就没有活跃任务, 不是空闲沿',
      );
    });
  });

  group('命令拼装', () {
    test('关机 60 秒延迟; 睡眠即休眠', () {
      expect(AfterCompleteRunner.shutdownCommand(), [
        'shutdown',
        '/s',
        '/t',
        '60',
      ]);
      expect(AfterCompleteRunner.sleepCommand(), ['shutdown', '/h']);
    });

    test('通知命令带 -EncodedCommand, 解码含统计文案', () {
      final command = AfterCompleteRunner.notifyCommand(done: 3, failed: 1);
      expect(command[0], 'powershell');
      expect(command.contains('-EncodedCommand'), isTrue);
      final script = AfterCompleteRunner.decodeCommandScript(command);
      expect(script, contains('成功 3 · 失败 1'));
      expect(script, contains('Avoxkit'));
    });
  });
}
