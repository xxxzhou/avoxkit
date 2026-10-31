import 'package:path/path.dart' as p;
import './i18n.dart';

/// 转换页的输出设置。'source' = 跟源文件一致。
class ConvertSettings {
  const ConvertSettings({
    this.container = 'source',
    this.video = 'source',
    this.height,
    this.audio = 'source',
    this.audioBitrateKbps = -1,
    this.quality = 60,
    this.hardware = false,
  });

  /// source | mp4 | mkv | mov
  final String container;

  /// source | h264 | h265
  final String video;

  /// null = 源分辨率; 否则为目标高度
  final int? height;

  /// source | aac | mp3
  final String audio;
  final int audioBitrateKbps;
  final int quality;
  final bool hardware;

  bool get isIdentity =>
      container == 'source' &&
      video == 'source' &&
      height == null &&
      audio == 'source';

  Map<String, dynamic> toJson() => {
        'container': container,
        'video': video,
        if (height != null) 'height': height,
        'audio': audio,
        'audio_bitrate_kbps': audioBitrateKbps,
        'quality': quality,
        'hardware': hardware,
      };
}

/// probe 结果里转换判定需要的字段
class SourceMedia {
  const SourceMedia({
    required this.container,
    required this.videoCodec,
    required this.width,
    required this.height,
    required this.audioCodec,
    required this.hasVideo,
    required this.hasAudio,
  });

  factory SourceMedia.fromProbe(String path, Map<String, dynamic> probe) {
    final video = _firstTrack(probe['video']);
    final audio = _firstTrack(probe['audio']);
    return SourceMedia(
      container: normalizeContainer(path, probe['format']?.toString()),
      videoCodec: normalizeVideo(video?['codec']?.toString()),
      width: (video?['width'] as num?)?.toInt(),
      height: (video?['height'] as num?)?.toInt(),
      audioCodec: audio?['codec']?.toString().toLowerCase(),
      hasVideo: video != null,
      hasAudio: audio != null,
    );
  }

  final String container;
  final String videoCodec;
  final int? width;
  final int? height;
  final String? audioCodec;
  final bool hasVideo;
  final bool hasAudio;

  static Map<String, dynamic>? _firstTrack(dynamic value) {
    if (value is List && value.isNotEmpty && value.first is Map) {
      return (value.first as Map).cast<String, dynamic>();
    }
    return null;
  }
}

class ConversionPlan {
  const ConversionPlan({
    required this.reason,
    required this.detail,
    this.kind,
    this.params = const {},
    this.transMode,
    this.videoMode,
    this.audioMode,
    this.warnings = const [],
    this.noop = false,
    this.error,
  });

  /// remux | transcode; noop/error 时为空
  final String? kind;
  final Map<String, dynamic> params;

  /// all | audio_copy | video_copy
  final String? transMode;

  /// copy | encode | null(无该轨)
  final String? videoMode;
  final String? audioMode;
  final String reason;
  final String detail;
  final List<String> warnings;
  final bool noop;
  final String? error;

  bool get canSubmit => kind != null && error == null && !noop;
}

/// 单文件判定: 目标容器 + 目标编码/分辨率 vs 源流, 决定封装还是重编。
ConversionPlan buildConversionPlan({
  required SourceMedia source,
  required ConvertSettings settings,
  bool h264Available = true,
  bool h265Available = true,
  bool aacAvailable = true,
  bool mp3Available = true,
}) {
  final targetContainer =
      settings.container == 'source' ? source.container : settings.container;
  final warnings = <String>[];

  String? videoMode; // copy | encode
  String? audioMode; // copy | encode
  String? encodeVideo;
  String? encodeAudio;
  int? outWidth;
  int? outHeight;

  if (source.hasVideo) {
    final srcCodec = source.videoCodec;
    final scaling = _targetSize(source, settings.height, warnings);
    if (scaling == null) {
      return ConversionPlan(
        reason: I18n.tr('无法读取源视频分辨率'),
        detail: '',
        error: I18n.tr('无法读取源视频分辨率，不能调整输出大小'),
      );
    }
    outWidth = scaling.$1;
    outHeight = scaling.$2;
    final sameSize = outWidth == null && outHeight == null;

    final requested = settings.video == 'source'
        ? srcCodec
        : (settings.video == 'h265' ? 'hevc' : 'h264');
    final sameCodec = requested == srcCodec;
    final stores = containerStoresVideo(targetContainer, srcCodec);
    final copy = sameCodec && sameSize && stores;

    if (copy) {
      videoMode = 'copy';
    } else {
      videoMode = 'encode';
      encodeVideo = _pickVideoEncoder(
        settings.video == 'source' ? srcCodec : requested,
        srcCodec,
        h264Available,
        h265Available,
        warnings,
      );
      if (encodeVideo == null) {
        return ConversionPlan(
          reason: I18n.tr('本机没有可用的视频编码器'),
          detail: '',
          error: I18n.tr('本机没有可用的 H.264 / H.265 编码器'),
        );
      }
      if (!containerStoresVideo(targetContainer, encodeVideo)) {
        return ConversionPlan(
          reason: I18n.tr('目标容器不支持该视频编码'),
          detail: '',
          error: '${prettyContainer(targetContainer)} 不能装 '
              '${prettyCodec(encodeVideo)}，请换容器或换编码',
        );
      }
      if (sameSize) {
        outWidth = null;
        outHeight = null;
      }
    }
  }

  if (source.hasAudio) {
    final srcCodec = source.audioCodec ?? '';
    final requested = settings.audio == 'source' ? srcCodec : settings.audio;
    final sameCodec = requested == srcCodec;
    final stores = containerStoresAudio(targetContainer, srcCodec);
    if (sameCodec && stores) {
      audioMode = 'copy';
    } else {
      audioMode = 'encode';
      encodeAudio = settings.audio == 'source' ? 'aac' : settings.audio;
      encodeAudio = _pickAudioEncoder(
        encodeAudio,
        aacAvailable,
        mp3Available,
        warnings,
      );
      if (encodeAudio == null) {
        return ConversionPlan(
          reason: I18n.tr('本机没有可用的音频编码器'),
          detail: '',
          error: I18n.tr('本机没有可用的 AAC / MP3 编码器'),
        );
      }
      if (settings.audio == 'source' && !stores) {
        warnings.insert(
          0,
          '${prettyContainer(targetContainer)} 不支持 '
          '${prettyCodec(srcCodec)} 音频，将转成 ${prettyCodec(encodeAudio)}',
        );
      }
      if (!containerStoresAudio(targetContainer, encodeAudio)) {
        return ConversionPlan(
          reason: I18n.tr('目标容器不支持该音频编码'),
          detail: '',
          error: '${prettyContainer(targetContainer)} 不能装 '
              '${prettyCodec(encodeAudio)}，请换容器或换编码',
        );
      }
    }
  }

  // Windows 自带播放器对 MP4 内的 HEVC/AV1 和旧式多声道音频支持不稳, 提交前提示
  if (targetContainer == 'mp4') {
    final outputVideo = videoMode == 'copy' ? source.videoCodec : encodeVideo;
    if (source.hasVideo &&
        (outputVideo == 'hevc' || outputVideo == 'av1')) {
      warnings.add(
        'Windows 自带播放器可能打不开 ${prettyCodec(outputVideo ?? '')}；'
        '请用支持该编码的播放器，或把视频改成 H.264',
      );
    }
    if (audioMode == 'copy' &&
        (source.audioCodec == 'eac3' ||
            source.audioCodec == 'ac3' ||
            source.audioCodec == 'alac')) {
      warnings.add(
        'Windows 自带播放器可能不支持 MP4 内的 '
        '${prettyCodec(source.audioCodec ?? '')}；'
        '打不开请把音频改成 AAC 或改用 MKV',
      );
    }
  }

  if (videoMode == null && audioMode == null) {
    return  ConversionPlan(
      reason: I18n.tr('源文件没有可处理的轨道'),
      detail: '',
      error: I18n.tr('源文件没有视频或音频轨道'),
    );
  }
  if (videoMode == null && audioMode == 'encode') {
    return  ConversionPlan(
      reason: I18n.tr('源文件没有视频轨'),
      detail: '',
      error: I18n.tr('源文件没有视频轨；音频重编码请使用「提取音频」'),
    );
  }

  final noop = videoMode != 'encode' &&
      audioMode != 'encode' &&
      targetContainer == source.container;
  if (noop) {
    return ConversionPlan(
      reason: I18n.tr('输出设置与原文件一致，无需转换'),
      detail: _detail(source, targetContainer, videoMode, audioMode,
          outWidth, outHeight, encodeVideo, encodeAudio),
      videoMode: videoMode,
      audioMode: audioMode,
      warnings: warnings,
      noop: true,
    );
  }

  // 没有视频轨时按直拷处理, 纯换容器走 remux
  final videoCopy = videoMode != 'encode';
  final audioCopy = audioMode == 'copy';
  final String kind;
  String? transMode;
  if (videoCopy && (audioCopy || audioMode == null)) {
    kind = 'remux';
  } else {
    kind = 'transcode';
    if (videoCopy) {
      transMode = 'video_copy';
    } else if (audioCopy) {
      transMode = 'audio_copy';
    } else {
      transMode = 'all';
    }
  }

  final params = <String, dynamic>{
    'container': targetContainer,
    'trans_mode': ?transMode,
  };
  if (kind == 'transcode') {
    params['video'] = <String, dynamic>{
      // copy 时只用于满足录制器的非 none 检查; video_copy 由 trans_mode 决定
      'codec': videoCopy
          ? (source.videoCodec == 'hevc' ? 'hevc' : 'h264')
          : encodeVideo,
      'width': ?outWidth,
      'height': ?outHeight,
      'hardware': settings.hardware ? 'auto' : 'off',
      'rate_mode': 'quality',
      'quality': settings.quality,
    };
    params['audio'] = <String, dynamic>{
      // copy 时同样只是回退目标: 正常情况下音频包直拷
      'codec': audioCopy ? 'aac' : (encodeAudio ?? (audioMode == null ? 'none' : 'aac')),
      'bitrate_kbps': settings.audioBitrateKbps,
    };
  }

  final reason = switch ((videoMode, audioMode)) {
    ('copy', 'copy') => I18n.tr('直接封装，不重新编码'),
    ('copy', 'encode') => I18n.tr('视频直拷，重新编码音频'),
    ('encode', 'copy') => I18n.tr('重新编码视频，音频直拷'),
    ('encode', 'encode') => I18n.tr('重新编码视频和音频'),
    ('encode', null) => I18n.tr('重新编码视频'),
    ('copy', null) => I18n.tr('直接封装，不重新编码'),
    _ => I18n.tr('直接封装，不重新编码'),
  };

  return ConversionPlan(
    kind: kind,
    params: params,
    transMode: transMode,
    videoMode: videoMode,
    audioMode: audioMode,
    reason: reason,
    detail: _detail(source, targetContainer, videoMode, audioMode, outWidth,
        outHeight, encodeVideo, encodeAudio),
    warnings: warnings,
  );
}

/// 返回 (width, height); 不缩放时返回 (null, null), 源分辨率无法读取时返回 null
(int?, int?)? _targetSize(
  SourceMedia source,
  int? targetHeight,
  List<String> warnings,
) {
  if (targetHeight == null) {
    return (null, null);
  }
  final sw = source.width;
  final sh = source.height;
  if (sw == null || sh == null || sw <= 0 || sh <= 0) {
    return null;
  }
  var width = (sw * targetHeight / sh).round();
  width -= width % 2;
  var height = targetHeight - targetHeight % 2;
  if (width < 2) {
    width = 2;
  }
  if (height < 2) {
    height = 2;
  }
  if (width == sw && height == sh) {
    return (null, null);
  }
  if (height > sh) {
    warnings.add(I18n.tr('输出分辨率高于源文件，会放大画面'));
  }
  return (width, height);
}

String? _pickVideoEncoder(
  String preferred,
  String sourceCodec,
  bool h264,
  bool h265,
  List<String> warnings,
) {
  final normalized = normalizeVideo(preferred);
  final available = {
    'h264': h264,
    'hevc': h265,
  };
  if (available[normalized] == true) {
    return normalized;
  }
  if (normalized != 'h264' && normalized != 'hevc') {
    final fallback = h264 ? 'h264' : (h265 ? 'hevc' : null);
    if (fallback != null) {
      warnings.add(
        '源视频编码 ${prettyCodec(sourceCodec)} 本机无法编码，'
        '改用 ${prettyCodec(fallback)}',
      );
    }
    return fallback;
  }
  final fallback = normalized == 'h264'
      ? (h265 ? 'hevc' : null)
      : (h264 ? 'h264' : null);
  if (fallback != null) {
    warnings.add(
      '${prettyCodec(normalized)} 编码器不可用，改用 ${prettyCodec(fallback)}',
    );
  }
  return fallback;
}

String? _pickAudioEncoder(
  String preferred,
  bool aac,
  bool mp3,
  List<String> warnings,
) {
  if (preferred == 'aac' && aac) {
    return 'aac';
  }
  if (preferred == 'mp3' && mp3) {
    return 'mp3';
  }
  final fallback = aac ? 'aac' : (mp3 ? 'mp3' : null);
  if (fallback != null) {
    warnings.add(
      '${prettyCodec(preferred)} 编码器不可用，改用 ${prettyCodec(fallback)}',
    );
  }
  return fallback;
}

String _detail(
  SourceMedia source,
  String targetContainer,
  String? videoMode,
  String? audioMode,
  int? outWidth,
  int? outHeight,
  String? encodeVideo,
  String? encodeAudio,
) {
  final parts = <String>[];
  parts.add(
    targetContainer == source.container
        ? I18n.trAuto('容器保持 ${prettyContainer(source.container)}')
        : I18n.trAuto('容器 ${prettyContainer(source.container)} → '
            '${prettyContainer(targetContainer)}'),
  );
  if (source.hasVideo) {
    final from = prettyCodec(source.videoCodec);
    if (videoMode == 'copy') {
      parts.add(I18n.trAuto('视频 $from 直拷'));
    } else {
      final to = prettyCodec(encodeVideo ?? '');
      final size = outWidth != null && outHeight != null
          ? ' · $outWidth×$outHeight'
          : '';
      parts.add('${I18n.trAuto('视频 $from → $to')}$size');
    }
  }
  if (source.hasAudio) {
    final from = prettyCodec(source.audioCodec ?? '');
    if (audioMode == 'copy') {
      parts.add(I18n.trAuto('音频 $from 直拷'));
    } else {
      parts.add(I18n.trAuto('音频 $from → ${prettyCodec(encodeAudio ?? '')}'));
    }
  }
  return parts.join(' · ');
}

String normalizeVideo(String? codec) {
  switch (codec?.toLowerCase()) {
    case 'h264':
    case 'avc':
      return 'h264';
    case 'h265':
    case 'hevc':
      return 'hevc';
    default:
      return (codec ?? '').toLowerCase();
  }
}

String normalizeContainer(String path, [String? format]) {
  final ext = p.extension(path).toLowerCase().replaceFirst('.', '');
  const byExt = {
    'mp4': 'mp4',
    'm4v': 'mp4',
    'mkv': 'mkv',
    'mov': 'mov',
    'webm': 'webm',
    'avi': 'avi',
    'ts': 'ts',
    'm2ts': 'ts',
    'mts': 'ts',
    'flv': 'flv',
    'wmv': 'wmv',
    'asf': 'wmv',
  };
  if (byExt.containsKey(ext)) {
    return byExt[ext]!;
  }
  final name = (format ?? '').toLowerCase();
  if (name.contains('matroska')) {
    return ext == 'webm' || name.contains('webm') ? 'webm' : 'mkv';
  }
  if (name.contains('webm')) {
    return 'webm';
  }
  if (name.contains('mov') || name.contains('mp4')) {
    return ext == 'mov' ? 'mov' : 'mp4';
  }
  if (name.contains('avi')) {
    return 'avi';
  }
  if (name.contains('mpegts')) {
    return 'ts';
  }
  if (name.contains('flv')) {
    return 'flv';
  }
  if (name.contains('asf')) {
    return 'wmv';
  }
  return ext.isEmpty ? 'unknown' : ext;
}

const _allVideo = <String>{
  'h264', 'hevc', 'mpeg1', 'mpeg2', 'mpeg4', 'h263', 'flv1', 'wmv1', 'wmv2',
  'wmv3', 'vc1', 'rv10', 'rv20', 'rv30', 'rv40', 'vp8', 'vp9', 'av1', 'prores',
  'mjpeg', 'vvc',
};

const _allAudio = <String>{
  'aac', 'mp3', 'ac3', 'eac3', 'alac', 'flac', 'opus', 'vorbis', 'dts',
  'truehd', 'pcm_s16le', 'pcm_s24le', 'pcm_u8', 'wmav1', 'wmav2', 'wmapro',
  'cook', 'atrac3',
};

/// 目标容器能装下的编码; 表里没有的容器交给引擎自判(返回 true)
bool containerStoresVideo(String container, String codec) {
  if (codec.isEmpty) {
    return false;
  }
  final set = switch (container) {
    'mp4' => const {'h264', 'hevc', 'mpeg4', 'av1'},
    'mov' => const {'h264', 'hevc', 'mpeg4', 'prores', 'av1'},
    'webm' => const {'vp8', 'vp9', 'av1'},
    'avi' => const {'h264', 'mpeg2', 'mpeg4', 'mjpeg'},
    'ts' => const {'h264', 'hevc', 'mpeg2'},
    'flv' => const {'h264'},
    'wmv' => const {'wmv1', 'wmv2', 'wmv3', 'vc1'},
    'mkv' => _allVideo,
    _ => null,
  };
  return set == null || set.contains(codec);
}

bool containerStoresAudio(String container, String codec) {
  if (codec.isEmpty) {
    return false;
  }
  final set = switch (container) {
    'mp4' => const {'aac', 'mp3', 'ac3', 'eac3', 'alac'},
    'mov' => const {
        'aac', 'mp3', 'ac3', 'eac3', 'alac', 'pcm_s16le', 'pcm_s24le'
      },
    'webm' => const {'opus', 'vorbis'},
    'avi' => const {'mp3', 'ac3', 'pcm_s16le'},
    'ts' => const {'aac', 'mp3', 'ac3', 'eac3'},
    'flv' => const {'aac', 'mp3'},
    'wmv' => const {'wmav1', 'wmav2', 'wmapro'},
    'mkv' => _allAudio,
    _ => null,
  };
  return set == null || set.contains(codec);
}

String prettyCodec(String codec) {
  switch (codec.toLowerCase()) {
    case 'h264':
    case 'avc':
      return 'H.264';
    case 'hevc':
    case 'h265':
      return 'H.265';
    case 'mpeg1':
      return 'MPEG-1';
    case 'mpeg2':
      return 'MPEG-2';
    case 'mpeg4':
      return 'MPEG-4';
    case 'aac':
      return 'AAC';
    case 'mp3':
      return 'MP3';
    case 'ac3':
      return 'AC-3';
    case 'eac3':
      return 'E-AC-3';
    case 'dts':
      return 'DTS';
    case 'truehd':
      return 'TrueHD';
    case 'pcm_s16le':
    case 'pcm_s24le':
    case 'pcm_u8':
      return 'PCM';
    default:
      final value = codec.trim();
      return value.isEmpty ? I18n.tr('未知') : value.toUpperCase();
  }
}

String prettyContainer(String container) {
  switch (container) {
    case 'mp4':
      return 'MP4';
    case 'mkv':
      return 'MKV';
    case 'mov':
      return 'MOV';
    case 'webm':
      return 'WebM';
    case 'avi':
      return 'AVI';
    case 'ts':
      return 'TS';
    case 'flv':
      return 'FLV';
    case 'wmv':
      return 'WMV';
    default:
      return container.toUpperCase();
  }
}
