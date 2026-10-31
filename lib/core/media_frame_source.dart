import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'engine.dart';
import 'media_frames.dart';
import 'media_index.dart';

/// 一个源文件的画面与波形缓存。页面/组件只问I18n.tr("这一刻的画面"), 取帧、去抖、
/// 缓存都在这里, 组件里不碰 FFI, 也不会在 build 里发请求。
class MediaFrameSource extends ChangeNotifier {
  MediaFrameSource({
    required this.engine,
    required this.path,
    required this.durationMs,
  });

  final Engine engine;
  final String path;
  final int durationMs;

  static const int _debounceMs = 120;
  static const int _cacheLimit = 12;

  MediaIndex? _index;
  bool _indexLoading = false;
  int _indexToken = 0;

  MediaFrames? _strip;
  bool _stripLoading = false;
  int _stripToken = 0;
  int _stripCount = 0;

  final Map<int, MediaFrame> _exact = {};
  final List<int> _exactOrder = [];

  Timer? _timer;
  int? _pendingMs;
  int _pendingWidth = 320;
  bool _inflight = false;
  bool _disposed = false;

  MediaIndex? get index => _index;
  bool get indexLoading => _indexLoading;
  MediaFrames? get strip => _strip;
  bool get stripLoading => _stripLoading;

  /// 画面预览不可用的人话提示(缩略图为空且原因是 Vulkan/像素格式时)
  String? get framesHint {
    final strip = _strip;
    if (strip == null || strip.frames.isNotEmpty) {
      return null;
    }
    return strip.unavailableHint;
  }

  Future<void> loadIndex() async {
    final token = ++_indexToken;
    _indexLoading = true;
    _notify();
    final result = await engine.mediaIndex(path, buckets: 1400);
    if (_disposed || token != _indexToken) {
      return;
    }
    _index = result;
    _indexLoading = false;
    _notify();
  }

  Future<void> loadStrip({int count = 12, int width = 192}) async {
    if (count == _stripCount && (_stripLoading || _strip != null)) {
      return;
    }
    _stripCount = count;
    final token = ++_stripToken;
    _stripLoading = true;
    _notify();
    final result = await engine.mediaFrames(
      path,
      count: count,
      width: width,
      quality: 72,
    );
    if (_disposed || token != _stripToken) {
      return;
    }
    if (result != null && result.hasVideo) {
      _strip = result;
    }
    _stripLoading = false;
    _notify();
  }

  /// 请求某一时刻的精确帧。多次调用只保留最后一次, 停 120ms 才真正抓。
  void request(int ms, {int width = 320}) {
    if (_disposed || durationMs <= 0) {
      return;
    }
    final clamped = ms.clamp(0, math.max(0, durationMs - 1)).toInt();
    _pendingMs = clamped;
    _pendingWidth = width;
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: _debounceMs), _pump);
  }

  /// 精确帧和缩略图条里取离当前最近的一帧; 两者都随时间远离自然让位。
  MediaFrame? nearest(int ms) {
    final candidates = <MediaFrame>[
      ..._exact.values,
      if (_strip != null) ..._strip!.frames,
    ];
    return nearestFrame(candidates, ms);
  }

  Future<void> _pump() async {
    if (_disposed || _inflight) {
      return;
    }
    final ms = _pendingMs;
    if (ms == null) {
      return;
    }
    _pendingMs = null;
    final width = _pendingWidth;
    _inflight = true;
    final result = await engine.mediaFrames(
      path,
      timesMs: [ms],
      width: width,
      quality: 78,
    );
    _inflight = false;
    if (_disposed) {
      return;
    }
    final frame = result?.frames.isNotEmpty == true
        ? result!.frames.first
        : null;
    if (frame != null) {
      _exact[ms] = frame;
      _exactOrder.remove(ms);
      _exactOrder.add(ms);
      while (_exactOrder.length > _cacheLimit) {
        _exact.remove(_exactOrder.removeAt(0));
      }
      _notify();
    }
    if (_pendingMs != null) {
      _timer?.cancel();
      _timer = Timer(const Duration(milliseconds: _debounceMs), _pump);
    }
  }

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
