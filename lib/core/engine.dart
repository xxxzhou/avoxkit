import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../native/ak_bindings.dart';
import '../native/ak_events.dart';
import 'image_plan.dart';
import 'media_frames.dart';
import 'media_index.dart';

class EngineException implements Exception {
  EngineException(this.code, this.message);
  final String code;
  final String message;
  @override
  String toString() => '$code: $message';
}

class Engine {
  Engine(this.bindings);

  final AkBindings bindings;
  final StreamController<AkEvent> _controller = StreamController.broadcast();

  NativeCallable<AkNativeEventCallback>? _callable;
  bool ready = false;
  int abi = 0;
  String? workDir;
  String? modelsDir;
  Map<String, dynamic> version = {};
  Map<String, dynamic> capabilities = {};
  String? errorCode;
  String? errorMessage;
  String? errorDetail;

  Stream<AkEvent> get events => _controller.stream;

  String get logDir {
    final paths = version['paths'];
    if (paths is Map && paths['log_dir'] is String) {
      return paths['log_dir'] as String;
    }
    return workDir == null ? '' : p.join(workDir!, 'logs');
  }

  Future<void> openLogFolder() async {
    final dir = logDir;
    if (dir.isEmpty) {
      return;
    }
    try {
      await Directory(dir).create(recursive: true);
    } catch (_) {
      // 目录建不出来也仍尝试打开
    }
    await openFolder(dir);
  }

  Future<void> openFolder(String path) async {
    if (path.isEmpty) {
      return;
    }
    try {
      if (Platform.isWindows) {
        await Process.start('explorer.exe', [
          path,
        ], mode: ProcessStartMode.detached);
      } else if (Platform.isMacOS) {
        await Process.start('open', [path], mode: ProcessStartMode.detached);
      } else {
        await Process.start('xdg-open', [
          path,
        ], mode: ProcessStartMode.detached);
      }
    } catch (_) {
      // 打不开目录不影响主流程
    }
  }

  Future<void> init() async {
    try {
      abi = bindings.abiVersion;
      if ((abi >> 16) != 1) {
        errorCode = 'abi_mismatch';
        errorMessage = 'native ABI 不匹配';
        errorDetail = 'shim ABI=0x${abi.toRadixString(16)}，期望 1.x';
        return;
      }

      final workDir = await _workDir();
      this.workDir = workDir;
      final config = jsonEncode({
        'work_dir': workDir,
        if (modelsDir != null) 'models_dir': modelsDir,
        'log_level': 'info',
      });
      final code = bindings.init(config);
      if (code != 0) {
        errorCode = codeName(code);
        errorMessage = codeMessage(code);
        return;
      }

      _callable = NativeCallable<AkNativeEventCallback>.listener(
        _onNativeEvent,
      );
      bindings.setEventCallback(_callable!.nativeFunction);

      version = _decode(bindings.versionJson());
      capabilities = _decode(bindings.capabilitiesJson());
      ready = true;
    } catch (error, stack) {
      errorCode = 'startup_exception';
      errorMessage = error.toString();
      errorDetail = stack.toString();
    }
  }

  Future<String> _workDir() async {
    try {
      final support = await getApplicationSupportDirectory();
      final models = Directory(p.join(support.path, 'models'));
      await models.create(recursive: true);
      modelsDir = models.path;
      final dir = Directory(p.join(support.path, 'work'));
      await dir.create(recursive: true);
      return dir.path;
    } catch (_) {
      final base = Directory(p.join(Directory.systemTemp.path, 'avoxkit'));
      final models = Directory(p.join(base.path, 'models'));
      await models.create(recursive: true);
      modelsDir = models.path;
      final dir = Directory(p.join(base.path, 'work'));
      await dir.create(recursive: true);
      return dir.path;
    }
  }

  void _onNativeEvent(Pointer<Utf8> pointer, Pointer<Void> user) {
    final text = pointer.toDartString();
    bindings.eventFree(pointer);
    try {
      final json = jsonDecode(text);
      if (json is Map<String, dynamic>) {
        _controller.add(AkEvent.fromJson(json));
      }
    } catch (error) {
      // 事件解析失败不阻塞任务; 记录到 stderr 便于排查
      stderr.writeln('bad ak event: $error\n$text');
    }
  }

  Map<String, dynamic> _decode(String text) {
    if (text.isEmpty) {
      return <String, dynamic>{};
    }
    final value = jsonDecode(text);
    return value is Map<String, dynamic> ? value : <String, dynamic>{};
  }

  Map<String, dynamic> probe(String path) {
    final result = _decode(bindings.probe(path));
    if (result['ok'] != true) {
      throw EngineException(
        result['code'] as String? ?? 'probe_failed',
        result['message'] as String? ?? '无法读取媒体信息',
      );
    }
    return result;
  }

  int submit(Map<String, dynamic> task) {
    final id = bindings.submit(jsonEncode(task));
    if (id < 0) {
      throw EngineException(codeName(id), codeMessage(id));
    }
    return id;
  }

  int cancel(int taskId) => bindings.cancel(taskId);

  // 原生窗口直显预览; 仅 Windows runner 交过主窗句柄后可用, 其余口失败静默
  bool previewOpen() {
    try {
      return bindings.previewOpen() == 0;
    } catch (_) {
      return false;
    }
  }

  void previewBind(int taskId) {
    try {
      bindings.previewBind(taskId);
    } catch (_) {
      // 预览是增强, 不是功能前提
    }
  }

  void previewUnbind() {
    try {
      bindings.previewUnbind();
    } catch (_) {
      // 同上
    }
  }

  void previewRect(double x, double y, double w, double h) {
    try {
      bindings.previewRect(x, y, w, h);
    } catch (_) {
      // 同上
    }
  }

  void previewClose() {
    try {
      bindings.previewClose();
    } catch (_) {
      // 同上
    }
  }

  bool encoderAvailable(String codec) => bindings.encoderProbe(codec) == 1;

  /// 音频包络 + 关键帧。解码走 isolate, 不阻塞 UI; 失败返回 null。
  Future<MediaIndex?> mediaIndex(String path, {int buckets = 1200}) async {
    if (!featureEnabled('media_index')) {
      return null;
    }
    try {
      return await Isolate.run(() => scanMediaIndex(path, buckets));
    } catch (_) {
      return null;
    }
  }

  /// 参考帧/缩略图。抓帧走 isolate, 失败返回 null(界面退化成只画波形)。
  Future<MediaFrames?> mediaFrames(
    String path, {
    int count = 12,
    List<int>? timesMs,
    int width = 320,
    int quality = 75,
  }) async {
    if (!featureEnabled('media_frames')) {
      return null;
    }
    try {
      return await Isolate.run(
        () => scanMediaFrames(
          path,
          count: count,
          timesMs: timesMs,
          width: width,
          quality: quality,
        ),
      );
    } catch (_) {
      return null;
    }
  }

  bool get trimAvailable => featureEnabled('trim');

  bool get imageAvailable => featureEnabled('image');

  bool get imageInpaintAvailable => featureEnabled('image_inpaint');

  /// 水印检测。模型首次加载要几秒, 走 isolate; 失败带 code 返回给页面。
  Future<ImageDetectResult> imageDetect(
    String path, {
    double threshold = 0.2,
    String model = 'lama',
  }) async {
    if (!imageAvailable) {
      return const ImageDetectResult(
        ok: false,
        code: 'inpaint_unavailable',
        message: '图像修复组件不可用',
      );
    }
    try {
      return await Isolate.run(
        () => scanImageDetection(path, threshold: threshold, model: model),
      );
    } catch (error) {
      return ImageDetectResult(ok: false, code: 'internal', message: '$error');
    }
  }

  bool featureEnabled(String feature) {
    final features = capabilities['features'];
    return features is Map && features[feature] == true;
  }

  bool get hardwareAvailable {
    final encoders = capabilities['encoders'];
    if (encoders is! Map) {
      return false;
    }
    final h264 = encoders['h264'];
    return h264 is Map && h264['hardware_mf'] == true;
  }

  void shutdown() {
    if (!ready) {
      return;
    }
    ready = false;
    bindings.shutdown();
    _callable?.close();
    _callable = null;
    if (!_controller.isClosed) {
      _controller.close();
    }
  }

  static String codeName(int code) {
    switch (code) {
      case 0:
        return 'ok';
      case -1:
        return 'invalid_argument';
      case -2:
        return 'bad_json';
      case -3:
        return 'already_init';
      case -4:
        return 'not_initialized';
      case -5:
        return 'ffmpeg_mismatch';
      case -6:
        return 'engine_mismatch';
      case -7:
        return 'unsupported_kind';
      case -8:
        return 'bad_source';
      case -9:
        return 'bad_output';
      case -10:
        return 'not_found';
      case -11:
        return 'task_not_running';
      case -12:
        return 'not_implemented';
      case -13:
        return 'model_missing';
      case -14:
        return 'no_subtitle';
      case -15:
        return 'stt_unavailable';
      case -16:
        return 'inpaint_unavailable';
      case -17:
        return 'inpaint_failed';
      default:
        return 'internal';
    }
  }

  static String codeMessage(int code) {
    switch (code) {
      case -1:
        return '参数不合法';
      case -2:
        return '任务参数解析失败';
      case -3:
        return '引擎已初始化';
      case -4:
        return '引擎未初始化';
      case -5:
        return 'ffmpeg 版本/配置不匹配，请确认使用随包 DLL';
      case -6:
        return 'avox 引擎版本不匹配';
      case -7:
        return '当前版本不支持这个任务类型';
      case -8:
        return '输入文件不存在或不可读';
      case -9:
        return '输出路径不可写或已存在';
      case -10:
        return '任务不存在';
      case -11:
        return '任务已结束，不能再操作';
      case -12:
        return '功能尚未实现';
      case -13:
        return '语音识别模型未下载';
      case -14:
        return '没有可提取的字幕轨';
      case -15:
        return '语音识别插件不可用';
      case -16:
        return '图像修复组件不可用';
      case -17:
        return '图像修复失败';
      default:
        return '内部错误，请查看日志';
    }
  }
}
