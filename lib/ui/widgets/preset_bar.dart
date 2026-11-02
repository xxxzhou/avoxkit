import 'package:flutter/material.dart';

import '../../core/i18n.dart';
import '../../core/presets.dart';
import '../tokens.dart';

/// 通用预设条: 应用下拉(动作菜单, 选中不驻留) + 保存当前设置 + 删除用户预设。
/// 任何实现了 [ToolPresetHost] 的工具页直接放入即可。
class AkPresetBar extends StatefulWidget {
  const AkPresetBar({super.key, required this.host, required this.store});

  final ToolPresetHost host;
  final PresetStore store;

  @override
  State<AkPresetBar> createState() => _AkPresetBarState();
}

class _AkPresetBarState extends State<AkPresetBar> {
  ToolPreset? _lastApplied;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.store,
      builder: (context, _) {
        final presets = widget.store.presetsFor(widget.host.presetToolId);
        final deletable = _lastApplied != null && !_lastApplied!.builtin;
        return Row(
          children: [
            DropdownButton<String>(
              value: null,
              hint: T('预设', style: AkText.body.copyWith(color: AkColors.muted)),
              isDense: true,
              underline: const SizedBox.shrink(),
              items: [
                for (final preset in presets)
                  DropdownMenuItem<String>(
                    value: preset.name,
                    child: T(preset.name, style: AkText.body),
                  ),
              ],
              onChanged: (name) {
                if (name == null) {
                  return;
                }
                final preset =
                    widget.store.byName(widget.host.presetToolId, name);
                if (preset == null) {
                  return;
                }
                widget.host.applyPresetValues(preset.values);
                setState(() => _lastApplied = preset);
              },
            ),
            const Spacer(),
            TextButton(
              onPressed: _save,
              child: const T('保存当前设置'),
            ),
            if (deletable)
              TextButton(
                onPressed: () {
                  widget.store.delete(_lastApplied!);
                  setState(() => _lastApplied = null);
                },
                child: const T('删除预设'),
              ),
          ],
        );
      },
    );
  }

  Future<void> _save() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const T('保存当前设置为预设'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(hintText: I18n.tr('预设名称')),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const T('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const T('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.isEmpty) {
      return;
    }
    final ok = widget.store.save(
      toolId: widget.host.presetToolId,
      name: name,
      values: widget.host.capturePresetValues(),
    );
    if (!ok) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: T('与出厂预设重名，换一个名字')),
        );
      }
      return;
    }
    if (mounted) {
      setState(() {
        _lastApplied = widget.store.byName(widget.host.presetToolId, name);
      });
    }
  }
}
