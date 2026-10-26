import 'package:flutter/material.dart';

import '../core/engine.dart';
import '../core/task_store.dart';
import 'pages/about_page.dart';
import 'pages/convert_page.dart';
import 'pages/extract_page.dart';
import 'pages/remux_page.dart';
import 'pages/tasks_page.dart';
import 'tokens.dart';
import 'widgets/panel.dart';

class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    required this.engine,
    required this.taskStore,
  });

  final Engine engine;
  final TaskStore taskStore;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _index = 0;

  static const _items = [
    _NavSpec('格式转换', Icons.swap_horiz),
    _NavSpec('提取音频', Icons.audiotrack),
    _NavSpec('封装转换', Icons.layers_outlined),
    _NavSpec('任务', Icons.list_alt),
    _NavSpec('关于', Icons.info_outline),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 860;
          return Row(
            children: [
              _Sidebar(
                compact: compact,
                selected: _index,
                onSelected: (value) => setState(() => _index = value),
                engine: widget.engine,
              ),
              Expanded(
                child: IndexedStack(
                  index: _index,
                  children: [
                    ConvertPage(
                      engine: widget.engine,
                      taskStore: widget.taskStore,
                    ),
                    ExtractPage(
                      engine: widget.engine,
                      taskStore: widget.taskStore,
                    ),
                    RemuxPage(
                      engine: widget.engine,
                      taskStore: widget.taskStore,
                    ),
                    TasksPage(taskStore: widget.taskStore),
                    AboutPage(engine: widget.engine),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _NavSpec {
  const _NavSpec(this.label, this.icon);
  final String label;
  final IconData icon;
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.compact,
    required this.selected,
    required this.onSelected,
    required this.engine,
  });

  final bool compact;
  final int selected;
  final ValueChanged<int> onSelected;
  final Engine engine;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: compact ? 74 : 220,
      decoration: const BoxDecoration(
        color: AkColors.bgDeep,
        border: Border(right: BorderSide(color: AkColors.border)),
      ),
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(
                compact ? 0 : 20,
                compact ? 20 : 28,
                compact ? 0 : 20,
                28,
              ),
              child: compact
                  ? const Center(
                      child: Text(
                        'AK',
                        style: TextStyle(
                          color: AkColors.accent,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1,
                        ),
                      ),
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'AVOXKIT',
                          style: TextStyle(
                            color: AkColors.textStrong,
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 1.4,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text('本地音视频工具箱', style: AkText.micro),
                      ],
                    ),
            ),
            for (var index = 0; index < _AppShellState._items.length; index++)
              _NavItem(
                spec: _AppShellState._items[index],
                selected: selected == index,
                compact: compact,
                onTap: () => onSelected(index),
              ),
            const Spacer(),
            Padding(
              padding: EdgeInsets.fromLTRB(
                compact ? 0 : 20,
                16,
                compact ? 0 : 20,
                20,
              ),
              child: compact
                  ? Center(
                      child: StateDot(
                        color:
                            engine.ready ? AkColors.state : AkColors.danger,
                      ),
                    )
                  : Row(
                      children: [
                        StateDot(
                          color:
                              engine.ready ? AkColors.state : AkColors.danger,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            engine.ready ? '引擎就绪' : '引擎异常',
                            style: AkText.micro,
                          ),
                        ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.spec,
    required this.selected,
    required this.compact,
    required this.onTap,
  });

  final _NavSpec spec;
  final bool selected;
  final bool compact;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final child = InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOutCubic,
        margin: EdgeInsets.symmetric(
          horizontal: compact ? 10 : 12,
          vertical: 2,
        ),
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 0 : 12,
          vertical: 11,
        ),
        decoration: BoxDecoration(
          color: selected ? AkColors.surfaceHi : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisAlignment:
              compact ? MainAxisAlignment.center : MainAxisAlignment.start,
          children: [
            Icon(
              spec.icon,
              size: 18,
              color: selected ? AkColors.accent : AkColors.muted,
            ),
            if (!compact) ...[
              const SizedBox(width: 12),
              Text(
                spec.label,
                style: TextStyle(
                  fontSize: 13,
                  color: selected ? AkColors.textStrong : AkColors.muted,
                  fontWeight:
                      selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ],
          ],
        ),
      ),
    );

    if (!compact) {
      return child;
    }
    return Tooltip(message: spec.label, child: child);
  }
}
