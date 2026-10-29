/// 单文件字幕任务规划: 有内嵌文本轨就直出, 否则按开关走本地语音识别。
/// 与 native 的 params.subtitle 一一对应; 批量时逐文件规划后提交。
class SubtitleTrackInfo {
  const SubtitleTrackInfo({
    required this.index,
    required this.codec,
    this.language,
    this.title,
    required this.text,
    required this.isDefault,
    required this.forced,
  });

  final int index;
  final String codec;
  final String? language;
  final String? title;

  /// false = PGS/DVD/DVB 等位图字幕, 不能直接导出文字
  final bool text;
  final bool isDefault;
  final bool forced;

  factory SubtitleTrackInfo.fromMap(Map<String, dynamic> map) {
    final codec = '${map['codec'] ?? ''}';
    return SubtitleTrackInfo(
      index: (map['index'] as num?)?.toInt() ?? -1,
      codec: codec,
      language: _string(map['language']),
      title: _string(map['title']),
      text: map['text'] == true || _textCodecs.contains(codec.toLowerCase()),
      isDefault: map['default'] == true,
      forced: map['forced'] == true,
    );
  }

  String get label {
    final parts = <String>[];
    final lang = prettyLanguage(language);
    if (lang.isNotEmpty) {
      parts.add(lang);
    }
    final name = title?.trim();
    if (name != null && name.isNotEmpty && name != lang) {
      parts.add(name);
    }
    parts.add(prettySubtitleCodec(codec));
    if (!text) {
      parts.add('图形，需语音识别');
    }
    if (isDefault) {
      parts.add('默认');
    }
    if (forced) {
      parts.add('强制');
    }
    return parts.join(' · ');
  }

  static String? _string(dynamic value) {
    final text = value is String ? value.trim() : '';
    return text.isEmpty ? null : text;
  }
}

enum SubtitlePlanSource { embedded, speech }

class SubtitlePlan {
  const SubtitlePlan({
    this.source,
    this.streamIndex,
    required this.reason,
    this.error,
    this.needsModel = false,
    this.allowAsr = true,
    this.track,
  });

  final SubtitlePlanSource? source;
  final int? streamIndex;
  final String reason;
  final String? error;

  /// 走语音识别但模型还没下载; UI 需要先下载再提交
  final bool needsModel;
  final bool allowAsr;
  final SubtitleTrackInfo? track;

  bool get canSubmit => error == null && source != null && !needsModel;

  Map<String, dynamic> params({bool overwrite = false}) {
    if (source == SubtitlePlanSource.embedded) {
      return {
        'overwrite': overwrite,
        'subtitle': {
          'mode': 'embedded',
          'stream_index': streamIndex,
          'allow_asr': allowAsr,
        },
      };
    }
    return {
      'overwrite': overwrite,
      'subtitle': {'mode': 'asr', 'allow_asr': true},
    };
  }
}

List<SubtitleTrackInfo> subtitleTracksFromProbe(Map<String, dynamic>? media) {
  final raw = media?['subtitles'];
  if (raw is! List) {
    return const [];
  }
  final tracks = <SubtitleTrackInfo>[];
  for (final item in raw) {
    if (item is Map) {
      final track = SubtitleTrackInfo.fromMap(item.cast<String, dynamic>());
      if (track.index >= 0) {
        tracks.add(track);
      }
    }
  }
  return tracks;
}

SubtitlePlan buildSubtitlePlan({
  required Map<String, dynamic>? media,
  int? trackIndex,
  required bool allowAsr,
  required bool modelReady,
}) {
  if (media == null) {
    return const SubtitlePlan(reason: '还在读取媒体信息');
  }
  final tracks = subtitleTracksFromProbe(media);
  final audio = media['audio'] is List && (media['audio'] as List).isNotEmpty;

  if (trackIndex != null) {
    SubtitleTrackInfo? selected;
    for (final track in tracks) {
      if (track.index == trackIndex) {
        selected = track;
        break;
      }
    }
    if (selected == null) {
      return const SubtitlePlan(reason: '', error: '字幕轨不存在，请重新选择文件');
    }
    if (!selected.text) {
      return SubtitlePlan(
        reason: '',
        error: '选中的是 ${prettySubtitleCodec(selected.codec)} 图形字幕，'
            '不能直接导出文字；请改用语音识别，或换一条文本字幕轨',
        track: selected,
      );
    }
    return SubtitlePlan(
      source: SubtitlePlanSource.embedded,
      streamIndex: selected.index,
      reason: '直接导出内嵌 ${prettySubtitleCodec(selected.codec)} 字幕轨',
      allowAsr: allowAsr,
      track: selected,
    );
  }

  final best = _bestTextTrack(tracks);
  if (best != null) {
    return SubtitlePlan(
      source: SubtitlePlanSource.embedded,
      streamIndex: best.index,
      reason: '直接导出内嵌 ${prettySubtitleCodec(best.codec)} 字幕轨'
          '${_languageSuffix(best.language)}',
      allowAsr: allowAsr,
      track: best,
    );
  }

  if (!allowAsr) {
    return const SubtitlePlan(
      reason: '',
      error: '没有内嵌文本字幕；打开“无字幕时语音识别”可生成',
    );
  }
  if (!audio) {
    return const SubtitlePlan(
      reason: '',
      error: '文件没有音轨，无法语音识别',
    );
  }
  return SubtitlePlan(
    source: SubtitlePlanSource.speech,
    reason: modelReady
        ? '没有内嵌文本字幕，将用本地语音识别生成 SRT'
        : '需要先下载语音识别模型（$SttModelSize.label）',
    needsModel: !modelReady,
    allowAsr: allowAsr,
  );
}

SubtitleTrackInfo? _bestTextTrack(List<SubtitleTrackInfo> tracks) {
  final text = tracks.where((track) => track.text).toList();
  if (text.isEmpty) {
    return null;
  }
  for (final track in text) {
    if (track.isDefault) {
      return track;
    }
  }
  for (final track in text) {
    final lang = (track.language ?? '').toLowerCase();
    if (lang == 'zh' ||
        lang == 'chi' ||
        lang == 'zho' ||
        lang.startsWith('zh-') ||
        lang.startsWith('zh_')) {
      return track;
    }
  }
  return text.first;
}

String _languageSuffix(String? language) {
  final name = prettyLanguage(language);
  return name.isEmpty ? '' : '（$name）';
}

const _textCodecs = {
  'subrip',
  'srt',
  'ass',
  'ssa',
  'mov_text',
  'webvtt',
  'vtt',
  'text',
  'subviewer',
  'subviewer1',
  'sami',
  'realtext',
  'stl',
  'ttml',
  'microdvd',
  'mpl2',
  'vplayer',
  'pjs',
  'jacosub',
  'hdmv_text_subtitle',
};

String prettySubtitleCodec(String codec) {
  switch (codec.toLowerCase()) {
    case 'subrip':
    case 'srt':
      return 'SRT';
    case 'ass':
    case 'ssa':
      return 'ASS';
    case 'mov_text':
      return 'MP4 文本';
    case 'webvtt':
    case 'vtt':
      return 'WebVTT';
    case 'hdmv_pgs_subtitle':
      return 'PGS';
    case 'dvd_subtitle':
      return 'DVD';
    case 'dvb_subtitle':
      return 'DVB';
    case 'xsub':
      return 'XSUB';
    default:
      return codec.isEmpty ? '字幕' : codec.toUpperCase();
  }
}

String prettyLanguage(String? language) {
  final code = (language ?? '').trim().toLowerCase();
  switch (code) {
    case 'zh':
    case 'chi':
    case 'zho':
    case 'zh-cn':
    case 'zh_cn':
    case 'chs':
    case 'cmn':
      return '中文';
    case 'zh-tw':
    case 'zh_tw':
    case 'cht':
      return '繁体中文';
    case 'en':
    case 'eng':
      return 'English';
    case 'ja':
    case 'jpn':
      return '日本語';
    case 'ko':
    case 'kor':
      return '한국어';
    case 'fr':
    case 'fre':
    case 'fra':
      return 'Français';
    case 'de':
    case 'ger':
    case 'deu':
      return 'Deutsch';
    case 'es':
    case 'spa':
      return 'Español';
    case 'ru':
    case 'rus':
      return 'Русский';
    case 'und':
    case '':
      return '';
    default:
      return code.toUpperCase();
  }
}

/// 只给提示文案用, 避免 plan 依赖 UI/模型实现
class SttModelSize {
  static const label = '约 230 MB';
}
