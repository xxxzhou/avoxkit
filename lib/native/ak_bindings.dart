import 'dart:ffi';

import 'package:ffi/ffi.dart';

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
    Pointer<NativeFunction<AkNativeEventCallback>>, Pointer<Void>);
typedef _AkSetEventCbDart = int Function(
    Pointer<NativeFunction<AkNativeEventCallback>>, Pointer<Void>);

typedef _AkEventFreeC = Void Function(Pointer<Utf8>);
typedef _AkEventFreeDart = void Function(Pointer<Utf8>);

typedef _AkTaskSubmitC = Int64 Function(Pointer<Utf8>);
typedef _AkTaskSubmitDart = int Function(Pointer<Utf8>);

typedef _AkTaskIdC = Int32 Function(Int64);
typedef _AkTaskIdDart = int Function(int);

typedef _AkProbeC = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _AkProbeDart = Pointer<Utf8> Function(Pointer<Utf8>);

typedef _AkEncoderProbeC = Int32 Function(Pointer<Utf8>);
typedef _AkEncoderProbeDart = int Function(Pointer<Utf8>);

class AkBindingsException implements Exception {
  AkBindingsException(this.message);
  final String message;
  @override
  String toString() => message;
}

class AkBindings {
  AkBindings._(this._lib);

  factory AkBindings.open() {
    try {
      return AkBindings._(DynamicLibrary.open('avoxkit_native.dll'));
    } catch (error) {
      throw AkBindingsException(
          '无法加载 avoxkit_native.dll。请确认它和 avox.dll、ffmpeg DLL 在 '
          'exe 同目录。原始错误: $error');
    }
  }

  final DynamicLibrary _lib;

  late final _AkAbiVersionDart _abiVersion =
      _lib.lookupFunction<_AkAbiVersionC, _AkAbiVersionDart>('ak_abi_version');
  late final _AkStringVoidDart _versionJson =
      _lib.lookupFunction<_AkStringVoidC, _AkStringVoidDart>(
          'ak_version_json');
  late final _AkInitDart _init =
      _lib.lookupFunction<_AkInitC, _AkInitDart>('ak_init');
  late final _AkShutdownDart _shutdown =
      _lib.lookupFunction<_AkShutdownC, _AkShutdownDart>('ak_shutdown');
  late final _AkSetEventCbDart _setEventCb =
      _lib.lookupFunction<_AkSetEventCbC, _AkSetEventCbDart>(
          'ak_set_event_cb');
  late final _AkEventFreeDart _eventFree =
      _lib.lookupFunction<_AkEventFreeC, _AkEventFreeDart>('ak_event_free');
  late final _AkTaskSubmitDart _taskSubmit =
      _lib.lookupFunction<_AkTaskSubmitC, _AkTaskSubmitDart>(
          'ak_task_submit');
  late final _AkTaskIdDart _taskCancel =
      _lib.lookupFunction<_AkTaskIdC, _AkTaskIdDart>('ak_task_cancel');
  late final _AkTaskIdDart _taskRemove =
      _lib.lookupFunction<_AkTaskIdC, _AkTaskIdDart>('ak_task_remove');
  late final _AkProbeDart _probe =
      _lib.lookupFunction<_AkProbeC, _AkProbeDart>('ak_probe');
  late final _AkStringVoidDart _capabilities =
      _lib.lookupFunction<_AkStringVoidC, _AkStringVoidDart>(
          'ak_capabilities_json');
  late final _AkEncoderProbeDart _encoderProbe =
      _lib.lookupFunction<_AkEncoderProbeC, _AkEncoderProbeDart>(
          'ak_encoder_probe');
  late final _AkEventFreeDart _freeString =
      _lib.lookupFunction<_AkEventFreeC, _AkEventFreeDart>('ak_free_string');

  int get abiVersion => _abiVersion();

  String versionJson() => _take(_versionJson(), _freeString);

  int init(String configJson) => _withUtf8(configJson, _init);

  void shutdown() => _shutdown();

  int setEventCallback(Pointer<NativeFunction<AkNativeEventCallback>> callback) =>
      _setEventCb(callback, nullptr);

  void eventFree(Pointer<Utf8> pointer) => _eventFree(pointer);

  int submit(String taskJson) => _withUtf8(taskJson, _taskSubmit);

  int cancel(int taskId) => _taskCancel(taskId);

  int remove(int taskId) => _taskRemove(taskId);

  String probe(String uri) {
    final value = _withUtf8Pointer(uri, _probe);
    return _take(value, _freeString);
  }

  String capabilitiesJson() => _take(_capabilities(), _freeString);

  int encoderProbe(String codec) => _withUtf8(codec, _encoderProbe);

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
      String value, Pointer<Utf8> Function(Pointer<Utf8>) call) {
    final pointer = value.toNativeUtf8();
    try {
      return call(pointer);
    } finally {
      malloc.free(pointer);
    }
  }
}
