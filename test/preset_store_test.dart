import 'dart:io';

import 'package:avoxkit/core/presets.dart';
import 'package:avoxkit/ui/widgets/preset_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeHost implements ToolPresetHost {
  _FakeHost(this.presetToolId, this.current);

  @override
  final String presetToolId;

  Map<String, dynamic> current;

  @override
  Map<String, dynamic> capturePresetValues() => Map.of(current);

  @override
  void applyPresetValues(Map<String, dynamic> values) =>
      current = Map.of(values);
}

void main() {
  group('PresetStore', () {
    test('出厂在前、同名覆盖用户预设', () {
      final store = PresetStore();
      expect(
        store.presetsFor('extract').map((preset) => preset.name),
        ['原始音轨', 'M4A · 192', 'MP3 · 192'],
      );

      expect(
        store.save(
          toolId: 'extract',
          name: '我的 320',
          values: {'format': 'mp3', 'bitrate_kbps': 320},
        ),
        isTrue,
      );
      expect(store.byName('extract', '我的 320')!.builtin, isFalse);

      // 同名覆盖, 不产生重复
      store.save(
        toolId: 'extract',
        name: '我的 320',
        values: {'format': 'mp3', 'bitrate_kbps': 256},
      );
      final mine = store.presetsFor('extract')
          .where((preset) => !preset.builtin)
          .toList();
      expect(mine, hasLength(1));
      expect(mine.single.values['bitrate_kbps'], 256);

      // 与出厂重名拒绝
      expect(
        store.save(toolId: 'extract', name: 'M4A · 192', values: const {}),
        isFalse,
      );
    });

    test('只能删除用户预设', () {
      final store = PresetStore();
      store.save(toolId: 'convert', name: '自定', values: const {});
      final user = store.byName('convert', '自定')!;
      expect(store.delete(user), isTrue);
      expect(store.byName('convert', '自定'), isNull);

      final builtin = store.byName('convert', 'H.265 · 1080p')!;
      expect(store.delete(builtin), isFalse);
      expect(store.byName('convert', 'H.265 · 1080p'), isNotNull);
    });

    test('用户预设落盘并按 toolId 恢复', () async {
      final dir = await Directory.systemTemp.createTemp('avoxkit_preset');
      addTearDown(() => dir.delete(recursive: true));

      final first = PresetStore(storageDir: dir.path);
      await first.restore();
      first.save(
        toolId: 'convert',
        name: '竖屏 720',
        values: const {'height': 720, 'hardware': true},
      );
      await first.flush();

      final second = PresetStore(storageDir: dir.path);
      await second.restore();
      final restored = second.byName('convert', '竖屏 720');
      expect(restored, isNotNull);
      expect(restored!.values, {'height': 720, 'hardware': true});
      // 出厂预设不落盘, 新实例仍来自代码
      expect(second.byName('convert', '仅换容器 MP4'), isNotNull);
    });
  });

  group('AkPresetBar', () {
    testWidgets('选择预设即应用到宿主', (tester) async {
      final host = _FakeHost('extract', {'format': 'm4a', 'bitrate_kbps': 256});
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AkPresetBar(host: host, store: PresetStore()),
          ),
        ),
      );
      await tester.tap(find.text('预设'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('MP3 · 192').last);
      await tester.pumpAndSettle();
      expect(host.current, {'format': 'mp3', 'bitrate_kbps': 192});
    });

    testWidgets('应用用户预设后可删除', (tester) async {
      final host = _FakeHost('convert', const {});
      final store = PresetStore();
      store.save(toolId: 'convert', name: '自定', values: const {'height': 720});
      await store.flush();
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: AkPresetBar(host: host, store: store))),
      );
      await tester.tap(find.text('预设'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('自定').last);
      await tester.pumpAndSettle();
      expect(find.text('删除预设'), findsOneWidget);

      await tester.tap(find.text('删除预设'));
      await tester.pumpAndSettle();
      expect(find.text('删除预设'), findsNothing);
      expect(store.byName('convert', '自定'), isNull);
      await store.flush();
    });
  });
}
