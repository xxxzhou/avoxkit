import 'dart:convert';

import 'package:path/path.dart' as p;

import '../native/ak_bindings.dart';
import 'app_paths.dart';

/// 图像修复支持的输入扩展名（avox 的 stb 解码 + opencv 兜底）。
const imageExtensions = <String>[
  'jpg', 'jpeg', 'png', 'bmp', 'tga', 'webp', //
];

class ImageBox {
  const ImageBox({
    required this.x,
    required this.y,
    required this.w,
    required this.h,
  });

  final double x;
  final double y;
  final double w;
  final double h;

  factory ImageBox.fromJson(Map<String, dynamic> json) => ImageBox(
        x: (json['x'] as num?)?.toDouble() ?? 0,
        y: (json['y'] as num?)?.toDouble() ?? 0,
        w: (json['w'] as num?)?.toDouble() ?? 0,
        h: (json['h'] as num?)?.toDouble() ?? 0,
      );
}

/// 一次水印检测的结果。ok=false 时 code/message 说明原因（多为模型未下载）。
class ImageDetectResult {
  const ImageDetectResult({
    required this.ok,
    this.width = 0,
    this.height = 0,
    this.found = false,
    this.boxes = const [],
    this.detectMs = 0,
    this.code,
    this.message,
  });

  final bool ok;
  final int width;
  final int height;
  final bool found;
  final List<ImageBox> boxes;
  final int detectMs;
  final String? code;
  final String? message;

  factory ImageDetectResult.fromJson(Map<String, dynamic> json) {
    final boxes = <ImageBox>[];
    final raw = json['boxes'];
    if (raw is List) {
      for (final item in raw) {
        if (item is Map) {
          boxes.add(ImageBox.fromJson(item.cast<String, dynamic>()));
        }
      }
    }
    return ImageDetectResult(
      ok: json['ok'] == true,
      width: (json['width'] as num?)?.toInt() ?? 0,
      height: (json['height'] as num?)?.toInt() ?? 0,
      found: json['found'] == true,
      boxes: boxes,
      detectMs: (json['detect_ms'] as num?)?.toInt() ?? 0,
      code: json['code'] as String?,
      message: json['message'] as String?,
    );
  }
}

/// isolate 入口: 独立 FFI 句柄做水印检测, 不阻塞 UI。
ImageDetectResult scanImageDetection(
  String path, {
  double threshold = 0.2,
  String model = 'lama',
}) {
  try {
    final bindings = AkBindings.open();
    final text = bindings.imageDetect(
      path,
      jsonEncode({'threshold': threshold, 'model': model}),
    );
    final value = jsonDecode(text);
    if (value is Map<String, dynamic>) {
      return ImageDetectResult.fromJson(value);
    }
    return const ImageDetectResult(ok: false, code: 'bad_reply');
  } catch (error) {
    return ImageDetectResult(ok: false, code: 'internal', message: '$error');
  }
}

String imageOutputExtension(String input) {
  final ext = p.extension(input).toLowerCase();
  if (ext == '.jpg' || ext == '.jpeg' || ext == '.png' || ext == '.bmp' ||
      ext == '.tga') {
    return ext;
  }
  return '.png';
}

/// 单图默认输出: 源文件旁加 -repaired, 保持可编辑格式。
String suggestImageOutput(String input, {String? extension}) {
  final ext = extension == null || extension.isEmpty
      ? imageOutputExtension(input)
      : (extension.startsWith('.') ? extension : '.$extension');
  return AppPaths.suggested(
    input,
    '${p.basenameWithoutExtension(input)}-repaired$ext',
  );
}

Map<String, dynamic> imageRepairParams({
  required String mode,
  String? maskPath,
  String model = 'lama',
  int dilate = 20,
  double threshold = 0.2,
  bool overwrite = false,
}) {
  return {
    'overwrite': overwrite,
    'image': {
      'mode': mode,
      if (maskPath != null && maskPath.isNotEmpty) 'mask_path': maskPath,
      'model': model,
      'dilate': dilate,
      'threshold': threshold,
    },
  };
}
