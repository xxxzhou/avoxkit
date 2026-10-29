import 'package:flutter/material.dart';

import '../../core/engine.dart';
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
          const PageHeader(
            title: '关于',
            description: '一个免费、本地、不需要账号的音视频工具箱。',
          ),
          const SizedBox(height: 24),
          Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('免费', style: AkText.panelTitle),
                const SizedBox(height: 6),
                Text('所有功能免费，没有会员、没有水印。', style: AkText.body),
                const SizedBox(height: 20),
                const Text('本地', style: AkText.panelTitle),
                const SizedBox(height: 6),
                Text('文件只在这台电脑上处理，不会上传到任何服务器。',
                    style: AkText.body),
                const SizedBox(height: 20),
                const Text('无账号', style: AkText.panelTitle),
                const SizedBox(height: 6),
                Text('不需要注册、登录，也不收集使用数据。', style: AkText.body),
              ],
            ),
          ),
          const SizedBox(height: 24),
          Panel(
            color: AkColors.surfaceAlt,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Powered by avox', style: AkText.panelTitle),
                const SizedBox(height: 8),
                Text(
                  '媒体引擎是开源的 avox（AGPL-3.0）。',
                  style: AkText.body.copyWith(color: AkColors.muted),
                ),
                const SizedBox(height: 16),
                Text(
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
