import 'dart:convert';
import 'dart:io';

import 'i18n.dart';

/// 队列全部结束后的动作; 挂在队列层, 所有工具共享。
/// 会话级选择, 不落盘——重启后回到 none, 避免残留关机指令。
enum AfterCompleteAction {
  none('无'),
  notify('通知'),
  sleep('睡眠'),
  shutdown('关机');

  const AfterCompleteAction(this.label);

  final String label;
}

/// 完成后动作的判定与平台执行; 命令拼装独立成静态方法便于测试
class AfterCompleteRunner {
  /// 队列从有活跃任务到空闲, 且最后归位的是正常完成才触发;
  /// 手动取消或以失败收尾都不动手
  static bool shouldFire({
    required bool hadActive,
    required bool hasActive,
    required String lastState,
  }) {
    return hadActive && !hasActive && lastState == 'done';
  }

  static List<String> shutdownCommand() => ['shutdown', '/s', '/t', '60'];

  /// Windows 命令行的"睡眠"即休眠: 可断电、恢复后回到原状态
  static List<String> sleepCommand() => ['shutdown', '/h'];

  /// 通知=系统弹窗; -EncodedCommand 绕开 shell 引号转义
  static List<String> notifyCommand({required int done, required int failed}) {
    final message = I18n.tr('成功 $done · 失败 $failed').replaceAll("'", "''");
    final title = I18n.tr('Avoxkit 任务完成').replaceAll("'", "''");
    final script = 'Add-Type -AssemblyName PresentationFramework;'
        "[System.Windows.MessageBox]::Show("
        "'$message', '$title')";
    return [
      'powershell',
      '-NoProfile',
      '-WindowStyle',
      'Hidden',
      '-EncodedCommand',
      _utf16leBase64(script),
    ];
  }

  static String _utf16leBase64(String text) {
    final bytes = <int>[];
    for (final unit in text.codeUnits) {
      bytes..add(unit & 0xff)..add((unit >> 8) & 0xff);
    }
    return base64Encode(bytes);
  }

  /// 供测试解码校验弹窗文案
  static String decodeCommandScript(List<String> command) {
    final bytes = base64Decode(command.last);
    final units = <int>[
      for (var i = 0; i + 1 < bytes.length; i += 2)
        bytes[i] | (bytes[i + 1] << 8),
    ];
    return String.fromCharCodes(units);
  }

  /// [onShutdownScheduled] 在关机命令发出后回调, UI 挂 60 秒撤销入口
  static Future<void> run(
    AfterCompleteAction action, {
    required int done,
    required int failed,
    void Function()? onShutdownScheduled,
  }) async {
    switch (action) {
      case AfterCompleteAction.none:
        return;
      case AfterCompleteAction.notify:
        await _spawn(notifyCommand(done: done, failed: failed));
        return;
      case AfterCompleteAction.sleep:
        await _spawn(sleepCommand());
        return;
      case AfterCompleteAction.shutdown:
        await _spawn(shutdownCommand());
        onShutdownScheduled?.call();
        return;
    }
  }

  static Future<void> _spawn(List<String> command) async {
    try {
      await Process.start(
        command.first,
        command.sublist(1),
        // detached: 系统命令独立存活, 关机倒计时不受应用退出影响
        mode: ProcessStartMode.detached,
      );
    } catch (_) {
      // 执行失败不打扰; 队列产物不受影响
    }
  }
}
