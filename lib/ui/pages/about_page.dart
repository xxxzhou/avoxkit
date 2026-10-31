import 'package:flutter/material.dart';

import '../../core/compat_options.dart';
import '../../core/engine.dart';
import '../../core/i18n.dart';
import '../tokens.dart';
import '../widgets/panel.dart';

class AboutPage extends StatelessWidget {
  const AboutPage({super.key, required this.engine});

  final Engine engine;

  @override
  Widget build(BuildContext context) {
    final version = engine.version['avox'] is Map
        ? (engine.version['avox'] as Map)['version']
        : null;
    final ffmpeg = engine.version['ffmpeg'] is Map
        ? (engine.version['ffmpeg'] as Map)['version']
        : null;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(32, 32, 32, 40),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PageHeader(
            title: I18n.tr('关于'),
            description: I18n.tr('一个免费、本地、不需要账号的音视频工具箱。'),
          ),
          const SizedBox(height: 24),
          Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const T('免费', style: AkText.panelTitle),
                const SizedBox(height: 6),
                T('所有功能免费，没有会员、没有水印。', style: AkText.body),
                const SizedBox(height: 20),
                const T('本地', style: AkText.panelTitle),
                const SizedBox(height: 6),
                T('文件只在这台电脑上处理，不会上传到任何服务器。',
                    style: AkText.body),
                const SizedBox(height: 20),
                const T('无账号', style: AkText.panelTitle),
                const SizedBox(height: 6),
                T('不需要注册、登录，也不收集使用数据。', style: AkText.body),
              ],
            ),
          ),
          const SizedBox(height: 24),
          Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const T('语言', style: AkText.panelTitle),
                const SizedBox(height: 6),
                ValueListenableBuilder<Locale>(
                  valueListenable: I18n.locale,
                  builder: (context, loc, _) => DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      value: I18n.codeOf(loc),
                      isExpanded: true,
                      items: I18n.supported
                          .map((l) => I18n.codeOf(l))
                          .toSet()
                          .map((code) => DropdownMenuItem(
                                value: code,
                                child: T(I18n.nativeNames[code] ?? code),
                              ))
                          .toList(),
                      onChanged: (code) {
                        if (code == null) {
                          return;
                        }
                        final target = I18n.supported.firstWhere(
                          (l) => I18n.codeOf(l) == code,
                        );
                        I18n.set(target);
                      },
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                T('切换后立即生效，下次启动保持。', style: AkText.micro),
              ],
            ),
          ),
          const SizedBox(height: 24),
          Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const T('兼容性', style: AkText.panelTitle),
                const SizedBox(height: 6),
                T('远程桌面、自动化工具或读屏软件在启动时读取界面，'
                  '可能触发 Flutter 引擎的已知崩溃。勾选并重启后关闭界面的无障碍信息；'
                  '需要读屏时请取消，等 Flutter 修复后再开。',
                  style: AkText.body,
                ),
                const SizedBox(height: 12),
                ValueListenableBuilder<bool>(
                  valueListenable: CompatOptions.disableAccessibility,
                  builder: (context, disabled, _) => Row(
                    children: [
                      Switch(
                        value: disabled,
                        onChanged: CompatOptions.setDisableAccessibility,
                      ),
                      const SizedBox(width: 6),
                      T('关闭无障碍支持', style: AkText.body),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          Panel(
            color: AkColors.surfaceAlt,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                T('Powered by avox', style: AkText.panelTitle),
                const SizedBox(height: 8),
                T('媒体引擎是开源的 avox（AGPL-3.0 / 商业双许可）。',
                  style: AkText.body.copyWith(color: AkColors.muted),
                ),
                const SizedBox(height: 16),
                T(
                  'avox ${version ?? '—'} · ffmpeg ${ffmpeg ?? '—'} · '
                  'ABI ${(engine.abi >> 16)}.${engine.abi & 0xffff}',
                  style: AkText.mono,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
