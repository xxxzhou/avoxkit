import 'dart:convert';

import 'package:avoxkit/core/image_plan.dart';
import 'package:avoxkit/core/model_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('输出扩展名: 常见图片保持, 不支持的回退 PNG', () {
    expect(imageOutputExtension('a.JPG'), '.jpg');
    expect(imageOutputExtension('a.jpeg'), '.jpeg');
    expect(imageOutputExtension('a.png'), '.png');
    expect(imageOutputExtension('a.tga'), '.tga');
    // webp 只做输入: avox 保存不支持 webp, 回退 PNG
    expect(imageOutputExtension('a.webp'), '.png');
  });

  test('单图输出默认加 -repaired 且可指定格式', () {
    expect(
      suggestImageOutput('/tmp/photo.jpg'),
      p.join('/tmp', 'photo-repaired.jpg'),
    );
    expect(
      suggestImageOutput('/tmp/photo.jpg', extension: '.png'),
      p.join('/tmp', 'photo-repaired.png'),
    );
    expect(
      suggestImageOutput('/tmp/photo.jpg', extension: 'png'),
      p.join('/tmp', 'photo-repaired.png'),
    );
  });

  test('任务参数: 只有手绘模式带 mask_path', () {
    final auto = imageRepairParams(mode: 'auto');
    final image = auto['image'] as Map<String, dynamic>;
    expect(image['mode'], 'auto');
    expect(image.containsKey('mask_path'), isFalse);
    expect(image['model'], 'lama');
    expect(image['dilate'], 20);

    final mask = imageRepairParams(
      mode: 'mask',
      maskPath: '/tmp/mask.png',
      threshold: 0.35,
      overwrite: true,
    );
    final maskImage = mask['image'] as Map<String, dynamic>;
    expect(mask['overwrite'], isTrue);
    expect(maskImage['mask_path'], '/tmp/mask.png');
    expect(maskImage['threshold'], 0.35);
  });

  test('检测结果解析: 框、尺寸和错误码', () {
    final ok = ImageDetectResult.fromJson(
      jsonDecode('''{
        "ok": true, "width": 1920, "height": 1080, "found": true,
        "detect_ms": 88,
        "boxes": [{"x": 10, "y": 20, "w": 100, "h": 30}]
      }''') as Map<String, dynamic>,
    );
    expect(ok.ok, isTrue);
    expect(ok.width, 1920);
    expect(ok.found, isTrue);
    expect(ok.boxes, hasLength(1));
    expect(ok.boxes.first.x, 10);
    expect(ok.boxes.first.h, 30);

    final failed = ImageDetectResult.fromJson(
      jsonDecode('{"ok": false, "code": "model_missing"}')
          as Map<String, dynamic>,
    );
    expect(failed.ok, isFalse);
    expect(failed.code, 'model_missing');
    expect(failed.boxes, isEmpty);
  });

  test('图像修复模型清单是 LaMa + 水印检测两件套', () {
    expect(InpaintModel.defaultFiles, hasLength(2));
    expect(
      InpaintModel.defaultFiles.map((file) => file.relativePath),
      containsAll([
        'inpaint/lama_base.onnx',
        'inpaint/yolo26m-seg_watermark.onnx',
      ]),
    );
    for (final file in InpaintModel.defaultFiles) {
      expect(file.bytes, greaterThan(0));
      expect(file.sha256.length, 64);
      expect(file.urls, isNotEmpty);
    }
  });
}
