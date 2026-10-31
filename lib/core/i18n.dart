import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Locale, PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// 以中文原文为 key 的轻量 i18n：不抽 key、不跑 gen_l10n。
///
/// 中文是源语言，`tr('转换')` 在中文下原样返回；其它语言从
/// `assets/i18n/<code>.json` 读「中文原文 -> 译文」。译文缺失时回退中文，
/// 不会出现空白界面。测试默认中文，因此现有中文断言不受影响。
class I18n {
  static const Locale zh = Locale('zh');
  static const Locale zhHant =
      Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant');

  static const List<Locale> supported = [
    zh,
    Locale('en'),
    zhHant,
    Locale('ja'),
    Locale('ko'),
    Locale('fr'),
    Locale('de'),
    Locale('es'),
    Locale('it'),
    Locale('pt'),
    Locale('pt', 'BR'),
    Locale('ru'),
    Locale('id'),
    Locale('th'),
    Locale('vi'),
  ];

  /// 语言选择器里显示的自称，避免用户在自己的语言里找英文名
  static const Map<String, String> nativeNames = {
    'zh-Hans': '简体中文',
    'en': 'English',
    'zh-Hant': '繁體中文',
    'ja': '日本語',
    'ko': '한국어',
    'fr': 'Français',
    'de': 'Deutsch',
    'es': 'Español',
    'it': 'Italiano',
    'pt': 'Português',
    'pt-BR': 'Português (Brasil)',
    'ru': 'Русский',
    'id': 'Bahasa Indonesia',
    'th': 'ไทย',
    'vi': 'Tiếng Việt',
  };

  static final ValueNotifier<Locale> locale = ValueNotifier<Locale>(zh);
  static final Map<String, Map<String, String>> _maps = {};
  static final Map<String, List<_XPattern>> _xPatterns = {};

  static bool isChinese(Locale l) => l.languageCode == 'zh';

  static String codeOf(Locale l) {
    if (l.languageCode == 'zh') {
      return l.scriptCode == 'Hant' ||
              l.countryCode == 'TW' ||
              l.countryCode == 'HK' ||
              l.countryCode == 'MO'
          ? 'zh-Hant'
          : 'zh-Hans';
    }
    if (l.languageCode == 'pt') {
      return l.countryCode == 'BR' ? 'pt-BR' : 'pt';
    }
    return l.languageCode;
  }

  static String fileNameOf(Locale l) =>
      codeOf(l).replaceAll('-', '_').toLowerCase();

  /// 系统语言/已保存选择 -> 受支持的语言；不认识的回退英文
  static Locale resolve(Locale l) {
    if (l.languageCode == 'zh') {
      return (l.scriptCode == 'Hant' ||
              l.countryCode == 'TW' ||
              l.countryCode == 'HK' ||
              l.countryCode == 'MO')
          ? zhHant
          : zh;
    }
    for (final s in supported) {
      if (s.languageCode == l.languageCode) {
        if (l.languageCode == 'pt' && l.countryCode == 'BR') {
          return const Locale('pt', 'BR');
        }
        return s;
      }
    }
    return const Locale('en');
  }

  static Future<void> load() async {
    for (final l in supported) {
      if (isChinese(l)) {
        continue;
      }
      final name = fileNameOf(l);
      try {
        final raw = await rootBundle.loadString('assets/i18n/$name.json');
        final decoded = (jsonDecode(raw) as Map).cast<String, String>();
        _maps[name] = decoded;
        _indexX(name, decoded);
      } catch (_) {
        // 译文还没到位时保持中文回退，不让启动失败
      }
    }
    final saved = await _readSaved();
    final forced = Platform.environment['AVOXKIT_LOCALE'];
    locale.value = resolve(
      (forced != null && forced.isNotEmpty)
          ? _parseCode(forced)
          : (saved ?? PlatformDispatcher.instance.locale),
    );
  }

  static Locale _parseCode(String code) {
    final parts = code.split('-');
    if (parts.length == 1) {
      return Locale(parts[0]);
    }
    if (parts[1] == 'Hant' || parts[1] == 'Hans') {
      return Locale.fromSubtags(
        languageCode: parts[0],
        scriptCode: parts[1],
      );
    }
    return Locale(parts[0], parts[1]);
  }

  static String tr(String zhText) {
    if (isChinese(locale.value)) {
      return zhText;
    }
    return trAuto(zhText);
  }

  /// 动态文案：先精确匹配；匹配不到把数字归一成 `{n}` 再查模板，
  /// 这样「任务 #123」「3 个关键帧」不用每个都改模板。
  static String trAuto(String text) {
    final map = _maps[fileNameOf(locale.value)];
    if (map == null) {
      return text;
    }
    final direct = map[text];
    if (direct != null) {
      return direct;
    }
    final re = RegExp(r'\d+(?:[.,:]\d+)*');
    final nums = re.allMatches(text).map((m) => m.group(0)!).toList();
    if (nums.isNotEmpty) {
      final template = map[text.replaceAll(re, '{n}')];
      if (template != null) {
        final parts = template.split('{n}');
        var out = parts.first;
        for (var i = 1; i < parts.length; i++) {
          out += (i - 1 < nums.length ? nums[i - 1] : '') + parts[i];
        }
        return out;
      }
    }
    // 非数字占位（编码器/容器/文件名等）：`{x}` 非贪婪捕获，`{n}` 捕数字
    for (final p in _xPatterns[fileNameOf(locale.value)] ?? const []) {
      final m = p.re.firstMatch(text);
      if (m == null) {
        continue;
      }
      var out = p.value;
      for (var i = 0; i < p.kinds.length; i++) {
        out = out.replaceFirst(p.kinds[i], m.group(i + 1) ?? '');
      }
      return out;
    }
    return text;
  }

  static void _indexX(String name, Map<String, String> map) {
    final list = <_XPattern>[];
    final ph = RegExp(r'\{[nx]\}');
    for (final e in map.entries) {
      if (!e.key.contains('{x}')) {
        continue;
      }
      final kinds = <String>[];
      final pattern = StringBuffer('^');
      var last = 0;
      for (final m in ph.allMatches(e.key)) {
        pattern.write(RegExp.escape(e.key.substring(last, m.start)));
        final k = m.group(0)!;
        kinds.add(k);
        pattern.write(k == '{x}' ? '(.*?)' : r'(\d+(?:[.,:]\d+)*)');
        last = m.end;
      }
      pattern.write(RegExp.escape(e.key.substring(last)));
      pattern.write(r'$');
      list.add(_XPattern(RegExp(pattern.toString(), dotAll: true), e.value, kinds));
    }
    _xPatterns[name] = list;
  }

  static Future<void> set(Locale l) async {
    locale.value = resolve(l);
    await _save(codeOf(locale.value));
  }

  static Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    return File('${dir.path}/locale.txt');
  }

  static Future<Locale?> _readSaved() async {
    try {
      final file = await _file();
      if (!file.existsSync()) {
        return null;
      }
      final code = (await file.readAsString()).trim();
      if (code.isEmpty) {
        return null;
      }
      for (final l in supported) {
        if (codeOf(l) == code) {
          return l;
        }
      }
    } catch (_) {}
    return null;
  }

  static Future<void> _save(String code) async {
    try {
      final file = await _file();
      await file.writeAsString(code, flush: true);
    } catch (_) {}
  }
}

/// 可 const 的 Text 替身：build 时才取译文，避免把整棵组件树改成非 const。
class _XPattern {
  _XPattern(this.re, this.value, this.kinds);
  final RegExp re;
  final String value;
  final List<String> kinds;
}

class T extends StatelessWidget {
  const T(
    this.zh, {
    super.key,
    this.style,
    this.textAlign,
    this.maxLines,
    this.overflow,
    this.softWrap,
    this.textScaler,
    this.semanticsLabel,
  });

  final String zh;
  final TextStyle? style;
  final TextAlign? textAlign;
  final int? maxLines;
  final TextOverflow? overflow;
  final bool? softWrap;
  final TextScaler? textScaler;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    return Text(
      I18n.tr(zh),
      style: style,
      textAlign: textAlign,
      maxLines: maxLines,
      overflow: overflow,
      softWrap: softWrap,
      textScaler: textScaler,
      semanticsLabel: semanticsLabel == null ? null : I18n.tr(semanticsLabel!),
    );
  }
}
