import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:avoxkit/core/i18n.dart';

void main() {
  test('中文是源语言，tr 原样返回', () {
    expect(I18n.tr('转换'), '转换');
    expect(I18n.trAuto('任务 #42'), '任务 #42');
  });

  test('系统语言映射到受支持的 locale', () {
    expect(I18n.codeOf(I18n.resolve(const Locale('zh', 'TW'))), 'zh-Hant');
    expect(I18n.codeOf(I18n.resolve(const Locale('zh', 'CN'))), 'zh-Hans');
    expect(I18n.codeOf(I18n.resolve(const Locale('pt', 'BR'))), 'pt-BR');
    expect(I18n.codeOf(I18n.resolve(const Locale('pt', 'PT'))), 'pt');
    expect(I18n.codeOf(I18n.resolve(const Locale('en', 'GB'))), 'en');
    expect(I18n.codeOf(I18n.resolve(const Locale('xx'))), 'en');
    expect(I18n.codeOf(I18n.resolve(const Locale.fromSubtags(
      languageCode: 'zh',
      scriptCode: 'Hant',
    ))), 'zh-Hant');
  });

  test('15 个语言每个都有自称', () {
    final codes = I18n.supported.map(I18n.codeOf).toSet();
    expect(codes.length, 15);
    for (final code in codes) {
      expect(I18n.nativeNames[code], isNotNull, reason: code);
    }
  });
}
