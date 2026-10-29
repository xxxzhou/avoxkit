import 'package:avoxkit/core/subtitle_plan.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> media({
  List<Map<String, dynamic>> subtitles = const [],
  bool audio = true,
  bool video = true,
}) {
  return {
    'ok': true,
    if (video) 'video': [{'index': 0, 'codec': 'h264'}],
    if (audio) 'audio': [{'index': 1, 'codec': 'aac'}],
    'subtitles': subtitles,
  };
}

Map<String, dynamic> track({
  required int index,
  String codec = 'subrip',
  String? language,
  String? title,
  bool text = true,
  bool isDefault = false,
  bool forced = false,
}) {
  return {
    'index': index,
    'codec': codec,
    'language': ?language,
    'title': ?title,
    'text': text,
    'default': isDefault,
    'forced': forced,
  };
}

void main() {
  group('subtitle plan', () {
    test('内嵌文本轨直接导出', () {
      final plan = buildSubtitlePlan(
        media: media(subtitles: [track(index: 2, language: 'zh')]),
        allowAsr: true,
        modelReady: false,
      );
      expect(plan.source, SubtitlePlanSource.embedded);
      expect(plan.streamIndex, 2);
      expect(plan.canSubmit, isTrue);
      expect(plan.needsModel, isFalse);
      expect(plan.params()['subtitle']['mode'], 'embedded');
    });

    test('默认轨优先于排序靠前的轨', () {
      final plan = buildSubtitlePlan(
        media: media(subtitles: [
          track(index: 2, language: 'en'),
          track(index: 3, language: 'zh', isDefault: true),
        ]),
        allowAsr: false,
        modelReady: false,
      );
      expect(plan.streamIndex, 3);
    });

    test('没有默认轨时优先中文', () {
      final plan = buildSubtitlePlan(
        media: media(subtitles: [
          track(index: 2, language: 'eng'),
          track(index: 3, language: 'zh-CN'),
        ]),
        allowAsr: false,
        modelReady: false,
      );
      expect(plan.streamIndex, 3);
    });

    test('只有图形字幕且开启识别时走语音识别', () {
      final plan = buildSubtitlePlan(
        media: media(subtitles: [
          track(index: 2, codec: 'hdmv_pgs_subtitle', text: false),
        ]),
        allowAsr: true,
        modelReady: false,
      );
      expect(plan.source, SubtitlePlanSource.speech);
      expect(plan.needsModel, isTrue);
      expect(plan.canSubmit, isFalse);
      expect(plan.error, isNull);
    });

    test('模型就绪时语音识别可直接提交', () {
      final plan = buildSubtitlePlan(
        media: media(subtitles: const []),
        allowAsr: true,
        modelReady: true,
      );
      expect(plan.source, SubtitlePlanSource.speech);
      expect(plan.needsModel, isFalse);
      expect(plan.canSubmit, isTrue);
      expect(plan.params()['subtitle']['mode'], 'asr');
    });

    test('关闭识别且无文本轨时报错', () {
      final plan = buildSubtitlePlan(
        media: media(subtitles: [
          track(index: 2, codec: 'hdmv_pgs_subtitle', text: false),
        ]),
        allowAsr: false,
        modelReady: true,
      );
      expect(plan.canSubmit, isFalse);
      expect(plan.error, isNotNull);
    });

    test('没有音轨时不能语音识别', () {
      final plan = buildSubtitlePlan(
        media: media(audio: false),
        allowAsr: true,
        modelReady: true,
      );
      expect(plan.canSubmit, isFalse);
      expect(plan.error, contains('音轨'));
    });

    test('显式选择文本轨优先', () {
      final plan = buildSubtitlePlan(
        media: media(subtitles: [
          track(index: 2, language: 'en'),
          track(index: 3, language: 'zh', isDefault: true),
        ]),
        trackIndex: 2,
        allowAsr: true,
        modelReady: true,
      );
      expect(plan.source, SubtitlePlanSource.embedded);
      expect(plan.streamIndex, 2);
    });

    test('显式选择图形轨明确拒绝', () {
      final plan = buildSubtitlePlan(
        media: media(subtitles: [
          track(index: 2, codec: 'hdmv_pgs_subtitle', text: false),
        ]),
        trackIndex: 2,
        allowAsr: true,
        modelReady: true,
      );
      expect(plan.canSubmit, isFalse);
      expect(plan.error, contains('图形字幕'));
    });

    test('媒体信息未就绪时不可提交', () {
      final plan = buildSubtitlePlan(
        media: null,
        allowAsr: true,
        modelReady: true,
      );
      expect(plan.source, isNull);
      expect(plan.canSubmit, isFalse);
    });

    test('旧 probe 没有 text 字段时按编码判断', () {
      final tracks = subtitleTracksFromProbe({
        'subtitles': [
          {'index': 2, 'codec': 'subrip'},
          {'index': 3, 'codec': 'hdmv_pgs_subtitle'},
        ],
      });
      expect(tracks[0].text, isTrue);
      expect(tracks[1].text, isFalse);
      expect(tracks[1].label, contains('需语音识别'));
    });

    test('语言与编码展示', () {
      expect(prettyLanguage('zho'), '中文');
      expect(prettyLanguage('jpn'), '日本語');
      expect(prettySubtitleCodec('mov_text'), 'MP4 文本');
      expect(prettySubtitleCodec('hdmv_pgs_subtitle'), 'PGS');
    });
  });
}
