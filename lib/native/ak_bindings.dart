import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

typedef AkNativeEventCallback = Void Function(Pointer<Utf8>, Pointer<Void>);

typedef _AkAbiVersionC = Uint32 Function();
typedef _AkAbiVersionDart = int Function();

typedef _AkStringVoidC = Pointer<Utf8> Function();
typedef _AkStringVoidDart = Pointer<Utf8> Function();

typedef _AkInitC = Int32 Function(Pointer<Utf8>);
typedef _AkInitDart = int Function(Pointer<Utf8>);

typedef _AkShutdownC = Void Function();
typedef _AkShutdownDart = void Function();

typedef _AkSetEventCbC = Int32 Function(
  Pointer<NativeFunction<AkNativeEventCallback>>,
  Pointer<Void>,
);
typedef _AkSetEventCbDart = int Function(
  Pointer<NativeFunction<AkNativeEventCallback>>,
  Pointer<Void>,
);

typedef _AkEventFreeC = Void Function(Pointer<Utf8>);
typedef _AkEventFreeDart = void Function(Pointer<Utf8>);

typedef _AkTaskSubmitC = Int64 Function(Pointer<Utf8>);
typedef _AkTaskSubmitDart = int Function(Pointer<Utf8>);

typedef _AkTaskIdC = Int32 Function(Int64);
typedef _AkTaskIdDart = int Function(int);

typedef _AkProbeC = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _AkProbeDart = Pointer<Utf8> Function(Pointer<Utf8>);

typedef _AkMediaIndexC = Pointer<Utf8> Function(Pointer<Utf8>, Int32);
typedef _AkMediaIndexDart = Pointer<Utf8> Function(Pointer<Utf8>, int);

typedef _AkMediaFramesC = Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _AkMediaFramesDart = Pointer<Utf8> Function(
  Pointer<Utf8>,
  Pointer<Utf8>,
);

typedef _AkEncoderProbeC = Int32 Function(Pointer<Utf8>);
typedef _AkEncoderProbeDart = int Function(Pointer<Utf8>);

typedef _AkImageDetectC = Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _AkImageDetectDart = Pointer<Utf8> Function(
  Pointer<Utf8>,
  Pointer<Utf8>,
);

typedef _AkPreviewOpenC = Int32 Function();
typedef _AkPreviewOpenDart = int Function();

typedef _AkPreviewBindC = Int32 Function(Int64);
typedef _AkPreviewBindDart = int Function(int);

typedef _AkPreviewUnbindC = Int32 Function();
typedef _AkPreviewUnbindDart = int Function();

typedef _AkPreviewRectC = Int32 Function(Double, Double, Double, Double);
typedef _AkPreviewRectDart = int Function(double, double, double, double);

typedef _AkPreviewCloseC = Int32 Function();
typedef _AkPreviewCloseDart = int Function();

// 录屏会话(ABI 1.7)
typedef _AkStringVoidRC = Pointer<Utf8> Function();
typedef _AkStringVoidRD = Pointer<Utf8> Function();

typedef _AkCaptureStartC = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _AkCaptureStartD = Pointer<Utf8> Function(Pointer<Utf8>);

typedef _AkCaptureIdC = Pointer<Utf8> Function(Int64);
typedef _AkCaptureIdD = Pointer<Utf8> Function(int);

typedef _AkCaptureIdRcC = Int32 Function(Int64);
typedef _AkCaptureIdRcD = int Function(int);

// 录屏工程(ABI 1.8)
typedef _AkProjectSetC = Pointer<Utf8> Function(Int64, Pointer<Utf8>);
typedef _AkProjectSetDart = Pointer<Utf8> Function(int, Pointer<Utf8>);

typedef _AkProjectCloseC = Void Function(Int64);
typedef _AkProjectCloseDart = void Function(int);

class AkBindingsException implements Exception {
  AkBindingsException(this.message);
  final String message;
  @override
  String toString() => message;
}

class AkBindings {
  AkBindings._(this._lib);

  factory AkBindings.open([String? path]) {
    try {
      return AkBindings._(DynamicLibrary.open(path ?? _defaultLibraryPath()));
    } catch (error) {
      throw AkBindingsException(
        '无法加载 avoxkit_native.dll。请确认它和 avox.dll、ffmpeg DLL 在 '
        'exe 同目录。原始错误: $error',
      );
    }
  }

  /// isolate 里也走绝对路径, 不依赖工作目录
  static String _defaultLibraryPath() {
    if (Platform.isWindows) {
      final candidate = p.join(
        p.dirname(Platform.resolvedExecutable),
        'avoxkit_native.dll',
      );
      if (File(candidate).existsSync()) {
        return candidate;
      }
    }
    return 'avoxkit_native.dll';
  }

  final DynamicLibrary _lib;

  late final _AkAbiVersionDart _abiVersion = _lib
      .lookupFunction<_AkAbiVersionC, _AkAbiVersionDart>('ak_abi_version');
  late final _AkStringVoidDart _versionJson = _lib
      .lookupFunction<_AkStringVoidC, _AkStringVoidDart>('ak_version_json');
  late final _AkInitDart _init = _lib.lookupFunction<_AkInitC, _AkInitDart>(
    'ak_init',
  );
  late final _AkShutdownDart _shutdown = _lib
      .lookupFunction<_AkShutdownC, _AkShutdownDart>('ak_shutdown');
  late final _AkSetEventCbDart _setEventCb = _lib
      .lookupFunction<_AkSetEventCbC, _AkSetEventCbDart>('ak_set_event_cb');
  late final _AkEventFreeDart _eventFree = _lib
      .lookupFunction<_AkEventFreeC, _AkEventFreeDart>('ak_event_free');
  late final _AkTaskSubmitDart _taskSubmit = _lib
      .lookupFunction<_AkTaskSubmitC, _AkTaskSubmitDart>('ak_task_submit');
  late final _AkTaskIdDart _taskCancel = _lib
      .lookupFunction<_AkTaskIdC, _AkTaskIdDart>('ak_task_cancel');
  late final _AkTaskIdDart _taskRemove = _lib
      .lookupFunction<_AkTaskIdC, _AkTaskIdDart>('ak_task_remove');
  late final _AkProbeDart _probe = _lib.lookupFunction<_AkProbeC, _AkProbeDart>(
    'ak_probe',
  );
  late final _AkMediaIndexDart _mediaIndex = _lib
      .lookupFunction<_AkMediaIndexC, _AkMediaIndexDart>('ak_media_index');
  late final _AkMediaFramesDart _mediaFrames = _lib
      .lookupFunction<_AkMediaFramesC, _AkMediaFramesDart>('ak_media_frames');
  late final _AkStringVoidDart _capabilities = _lib
      .lookupFunction<_AkStringVoidC, _AkStringVoidDart>(
        'ak_capabilities_json',
      );
  late final _AkEncoderProbeDart _encoderProbe = _lib
      .lookupFunction<_AkEncoderProbeC, _AkEncoderProbeDart>(
        'ak_encoder_probe',
      );
  late final _AkImageDetectDart _imageDetect = _lib
      .lookupFunction<_AkImageDetectC, _AkImageDetectDart>(
        'ak_image_detect',
      );
  late final _AkPreviewOpenDart _previewOpen = _lib
      .lookupFunction<_AkPreviewOpenC, _AkPreviewOpenDart>('ak_preview_open');
  late final _AkPreviewBindDart _previewBind = _lib
      .lookupFunction<_AkPreviewBindC, _AkPreviewBindDart>('ak_preview_bind');
  late final _AkPreviewUnbindDart _previewUnbind = _lib
      .lookupFunction<_AkPreviewUnbindC, _AkPreviewUnbindDart>(
        'ak_preview_unbind',
      );
  late final _AkPreviewRectDart _previewRect = _lib
      .lookupFunction<_AkPreviewRectC, _AkPreviewRectDart>('ak_preview_rect');
  late final _AkPreviewCloseDart _previewClose = _lib
      .lookupFunction<_AkPreviewCloseC, _AkPreviewCloseDart>(
        'ak_preview_close',
      );
  late final _AkEventFreeDart _freeString = _lib
      .lookupFunction<_AkEventFreeC, _AkEventFreeDart>('ak_free_string');

  int get abiVersion => _abiVersion();

  String versionJson() => _take(_versionJson(), _freeString);

  int init(String configJson) => _withUtf8(configJson, _init);

  void shutdown() => _shutdown();

  int setEventCallback(
    Pointer<NativeFunction<AkNativeEventCallback>> callback,
  ) => _setEventCb(callback, nullptr);

  void eventFree(Pointer<Utf8> pointer) => _eventFree(pointer);

  int submit(String taskJson) => _withUtf8(taskJson, _taskSubmit);

  int cancel(int taskId) => _taskCancel(taskId);

  int remove(int taskId) => _taskRemove(taskId);

  String probe(String uri) {
    final value = _withUtf8Pointer(uri, _probe);
    return _take(value, _freeString);
  }

  String mediaIndex(String uri, int buckets) {
    final pointer = uri.toNativeUtf8();
    try {
      return _take(_mediaIndex(pointer, buckets), _freeString);
    } finally {
      malloc.free(pointer);
    }
  }

  String mediaFrames(String uri, String requestJson) {
    final uriPointer = uri.toNativeUtf8();
    final requestPointer = requestJson.toNativeUtf8();
    try {
      return _take(_mediaFrames(uriPointer, requestPointer), _freeString);
    } finally {
      malloc.free(uriPointer);
      malloc.free(requestPointer);
    }
  }

  String capabilitiesJson() => _take(_capabilities(), _freeString);

  int encoderProbe(String codec) => _withUtf8(codec, _encoderProbe);

  String imageDetect(String uri, String requestJson) {
    final uriPointer = uri.toNativeUtf8();
    final requestPointer = requestJson.toNativeUtf8();
    try {
      return _take(_imageDetect(uriPointer, requestPointer), _freeString);
    } finally {
      malloc.free(uriPointer);
      malloc.free(requestPointer);
    }
  }

  int previewOpen() => _previewOpen();

  int previewBind(int taskId) => _previewBind(taskId);

  int previewUnbind() => _previewUnbind();

  int previewRect(double x, double y, double w, double h) =>
      _previewRect(x, y, w, h);

  int previewClose() => _previewClose();

  // ---- 录屏会话 ----
  late final _AkStringVoidRD _captureDevices = _lib
      .lookupFunction<_AkStringVoidRC, _AkStringVoidRD>(
        'ak_capture_devices_json',
      );
  late final _AkCaptureStartD _captureStart = _lib
      .lookupFunction<_AkCaptureStartC, _AkCaptureStartD>('ak_capture_start');
  late final _AkCaptureIdD _captureStatus = _lib
      .lookupFunction<_AkCaptureIdC, _AkCaptureIdD>('ak_capture_status');
  late final _AkCaptureIdRcD _capturePause = _lib
      .lookupFunction<_AkCaptureIdRcC, _AkCaptureIdRcD>('ak_capture_pause');
  late final _AkCaptureIdRcD _captureResume = _lib
      .lookupFunction<_AkCaptureIdRcC, _AkCaptureIdRcD>('ak_capture_resume');
  late final _AkCaptureIdD _captureStop = _lib
      .lookupFunction<_AkCaptureIdC, _AkCaptureIdD>('ak_capture_stop');

  String captureDevicesJson() => _take(_captureDevices(), _freeString);

  String captureStart(String requestJson) {
    final pointer = requestJson.toNativeUtf8();
    try {
      return _take(_captureStart(pointer), _freeString);
    } finally {
      malloc.free(pointer);
    }
  }

  String captureStatus(int sessionId) =>
      _take(_captureStatus(sessionId), _freeString);

  int capturePause(int sessionId) => _capturePause(sessionId);

  int captureResume(int sessionId) => _captureResume(sessionId);

  String captureStop(int sessionId) =>
      _take(_captureStop(sessionId), _freeString);

  // ---- 录屏工程 ----
  late final _AkCaptureStartD _projectOpen = _lib
      .lookupFunction<_AkCaptureStartC, _AkCaptureStartD>('ak_project_open');
  late final _AkProjectSetDart _projectSet = _lib
      .lookupFunction<_AkProjectSetC, _AkProjectSetDart>('ak_project_set');
  late final _AkProjectSetDart _projectExport = _lib
      .lookupFunction<_AkProjectSetC, _AkProjectSetDart>('ak_project_export');
  late final _AkCaptureIdD _projectStatus = _lib
      .lookupFunction<_AkCaptureIdC, _AkCaptureIdD>('ak_project_status');
  late final _AkProjectCloseDart _projectClose = _lib
      .lookupFunction<_AkProjectCloseC, _AkProjectCloseDart>('ak_project_close');

  String projectOpen(String requestJson) {
    final pointer = requestJson.toNativeUtf8();
    try {
      return _take(_projectOpen(pointer), _freeString);
    } finally {
      malloc.free(pointer);
    }
  }

  String projectSet(int projectId, String patchJson) {
    final pointer = patchJson.toNativeUtf8();
    try {
      return _take(_projectSet(projectId, pointer), _freeString);
    } finally {
      malloc.free(pointer);
    }
  }

  String projectExport(int projectId, String requestJson) {
    final pointer = requestJson.toNativeUtf8();
    try {
      return _take(_projectExport(projectId, pointer), _freeString);
    } finally {
      malloc.free(pointer);
    }
  }

  String projectStatus(int projectId) =>
      _take(_projectStatus(projectId), _freeString);

  void projectClose(int projectId) => _projectClose(projectId);

  String _take(Pointer<Utf8> pointer, void Function(Pointer<Utf8>) free) {
    if (pointer == nullptr) {
      return '';
    }
    final value = pointer.toDartString();
    free(pointer);
    return value;
  }

  int _withUtf8(String value, int Function(Pointer<Utf8>) call) {
    final pointer = value.toNativeUtf8();
    try {
      return call(pointer);
    } finally {
      malloc.free(pointer);
    }
  }

  Pointer<Utf8> _withUtf8Pointer(
    String value,
    Pointer<Utf8> Function(Pointer<Utf8>) call,
  ) {
    final pointer = value.toNativeUtf8();
    try {
      return call(pointer);
    } finally {
      malloc.free(pointer);
    }
  }
}
