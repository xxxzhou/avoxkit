import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/engine.dart';
import '../tokens.dart';

/// 原生窗口直显预览: 控件本身是占位框, shim 在同一屏幕矩形上放一个
/// avox 直渲的子窗口。绑定按 taskId, 只有录制中的任务才显示原生窗。
class AkLivePreview extends StatefulWidget {
  const AkLivePreview({
    super.key,
    required this.engine,
    required this.taskId,
    this.active = true,
    this.aspectRatio = 16 / 9,
    this.placeholder,
  });

  final Engine engine;
  final int taskId;

  /// 页面不可见(IndexedStack 切页/被路由覆盖)时必须收起原生窗
  final bool active;
  final double aspectRatio;

  /// 原生窗未显示时露出: 排队中/已完成/无画面
  final Widget? placeholder;

  @override
  State<AkLivePreview> createState() => _AkLivePreviewState();
}

class _AkLivePreviewState extends State<AkLivePreview> {
  final GlobalKey _boxKey = GlobalKey();
  Timer? _timer;
  bool _routeCurrent = true;
  bool _windowOpen = false;
  bool _unsupported = false;
  int? _boundTaskId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _sync());
    _timer = Timer.periodic(const Duration(milliseconds: 120), (_) => _sync());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 路由被详情页覆盖时, IndexedStack 里的本页仍然 active
    _routeCurrent = ModalRoute.of(context)?.isCurrent ?? true;
    WidgetsBinding.instance.addPostFrameCallback((_) => _sync());
  }

  @override
  void didUpdateWidget(covariant AkLivePreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.taskId != widget.taskId && _windowOpen) {
      widget.engine.previewBind(widget.taskId);
      _boundTaskId = widget.taskId;
    }
    if (oldWidget.active != widget.active) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _sync());
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _release();
    super.dispose();
  }

  bool get _visible => widget.active && _routeCurrent;

  void _sync() {
    if (!mounted) {
      return;
    }
    if (!_visible) {
      _release();
      return;
    }
    final box = _boxKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.attached || !box.hasSize) {
      return;
    }
    if (!_windowOpen && !_unsupported) {
      if (!widget.engine.previewOpen()) {
        _unsupported = true;
        return;
      }
      _windowOpen = true;
      widget.engine.previewBind(widget.taskId);
      _boundTaskId = widget.taskId;
    } else if (_windowOpen && _boundTaskId != widget.taskId) {
      widget.engine.previewBind(widget.taskId);
      _boundTaskId = widget.taskId;
    }
    if (!_windowOpen) {
      return;
    }
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final origin = box.localToGlobal(Offset.zero) * dpr;
    final size = box.size * dpr;
    widget.engine.previewRect(origin.dx, origin.dy, size.width, size.height);
  }

  void _release() {
    if (!_windowOpen) {
      return;
    }
    widget.engine.previewUnbind();
    widget.engine.previewClose();
    _windowOpen = false;
    _boundTaskId = null;
  }

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: widget.aspectRatio,
      child: Container(
        decoration: BoxDecoration(
          color: AkColors.bgDeep,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AkColors.border),
        ),
        // 1px 内缩让边框露出来; 内框矩形即视频窗矩形
        padding: const EdgeInsets.all(1),
        child: Container(
          key: _boxKey,
          color: AkColors.bgDeep,
          alignment: Alignment.center,
          child: widget.placeholder,
        ),
      ),
    );
  }
}
