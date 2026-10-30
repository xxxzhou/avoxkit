import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';

import 'core/compat_options.dart';
import 'core/engine.dart';
import 'core/task_store.dart';
import 'native/ak_bindings.dart';
import 'ui/shell.dart';
import 'ui/tokens.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await CompatOptions.load();
  late final Engine engine;
  try {
    engine = Engine(AkBindings.open());
    await engine.init();
  } catch (error, stack) {
    runApp(_BindingLoadError(error, stack));
    return;
  }
  runApp(AvoxkitApp(engine: engine));
}

class _BindingLoadError extends StatelessWidget {
  const _BindingLoadError(this.error, this.stack);

  final Object error;
  final StackTrace stack;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: akTheme(),
      home: Scaffold(
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620),
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('无法加载原生模块', style: AkText.pageTitle),
                  const SizedBox(height: 12),
                  Text(
                    '$error',
                    style: AkText.body.copyWith(color: AkColors.danger),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    stack.toString(),
                    style: AkText.mono.copyWith(fontSize: 11),
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 20),
                  Text(
                    '请先构建 native/avtool，并确认 avoxkit_native.dll、'
                    'avox.dll 与 ffmpeg DLL 都在 avoxkit.exe 同目录。',
                    style: AkText.body.copyWith(color: AkColors.muted),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class AvoxkitApp extends StatefulWidget {
  const AvoxkitApp({super.key, required this.engine});

  final Engine engine;

  @override
  State<AvoxkitApp> createState() => _AvoxkitAppState();
}

class _AvoxkitAppState extends State<AvoxkitApp> {
  TaskStore? _taskStore;
  AppLifecycleListener? _lifecycle;

  @override
  void initState() {
    super.initState();
    if (widget.engine.ready) {
      _taskStore = TaskStore(widget.engine);
      _lifecycle = AppLifecycleListener(
        onExitRequested: () async {
          widget.engine.shutdown();
          return AppExitResponse.exit;
        },
      );
    }
  }

  @override
  void dispose() {
    _lifecycle?.dispose();
    _taskStore?.dispose();
    widget.engine.shutdown();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ready = widget.engine.ready && _taskStore != null;
    return MaterialApp(
      title: 'Avoxkit',
      debugShowCheckedModeBanner: false,
      theme: akTheme(),
      builder: (context, child) {
        return ValueListenableBuilder<bool>(
          valueListenable: CompatOptions.disableAccessibility,
          builder: (context, disabled, _) {
            final content = child ?? const SizedBox.shrink();
            // 关掉语义树可规避 Flutter Windows 无障碍桥的启动期崩溃
            return disabled ? ExcludeSemantics(child: content) : content;
          },
        );
      },
      home: ready
          ? AppShell(engine: widget.engine, taskStore: _taskStore!)
          : _StartupError(engine: widget.engine),
    );
  }
}

class _StartupError extends StatelessWidget {
  const _StartupError({required this.engine});

  final Engine engine;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('无法启动引擎', style: AkText.pageTitle),
                const SizedBox(height: 12),
                Text(
                  engine.errorMessage ?? '未知错误',
                  style: AkText.body.copyWith(color: AkColors.danger),
                ),
                if (engine.errorCode != null) ...[
                  const SizedBox(height: 8),
                  Text(engine.errorCode!, style: AkText.mono),
                ],
                if (engine.errorDetail != null) ...[
                  const SizedBox(height: 16),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: AkColors.bgDeep,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      engine.errorDetail!,
                      style: AkText.mono.copyWith(fontSize: 11),
                    ),
                  ),
                ],
                const SizedBox(height: 20),
                Text(
                  '请确认 avoxkit_native.dll、avox.dll 与 ffmpeg DLL 都在 '
                  'avoxkit.exe 同目录；如果刚替换过 DLL，请重启应用。',
                  style: AkText.body.copyWith(color: AkColors.muted),
                ),
                if (engine.workDir != null) ...[
                  const SizedBox(height: 20),
                  OutlinedButton(
                    onPressed: engine.openLogFolder,
                    child: const Text('打开日志目录'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
