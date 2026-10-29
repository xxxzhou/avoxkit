import 'package:avoxkit/ui/widgets/task_summary.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const path = r'D:\movie\out.mp4';

  Future<void> doubleTap(WidgetTester tester, Finder finder) async {
    await tester.tap(finder);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  testWidgets('双击产物路径复制到剪贴板并提示', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );

    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: AkOutputPath(path: path))),
    );

    await doubleTap(tester, find.text(path));

    expect(copied, path);
    expect(find.text('已复制路径到剪贴板'), findsOneWidget);
  });

  testWidgets('单击只保留待判定, 不复制路径', (tester) async {
    var copied = false;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = true;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );

    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: AkOutputPath(path: path))),
    );

    await tester.tap(find.text(path));
    await tester.pumpAndSettle();

    expect(copied, isFalse);
    expect(find.text('已复制路径到剪贴板'), findsNothing);
  });
}
