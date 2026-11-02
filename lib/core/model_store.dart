import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import './i18n.dart';

enum ModelPhase { notDownloaded, downloading, ready, failed }

class ModelDownloadException implements Exception {
  ModelDownloadException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 一个模型分片: 只在用到对应功能时下载, 不随安装包分发。
class ModelFile {
  const ModelFile({
    required this.relativePath,
    required this.urls,
    required this.bytes,
    required this.sha256,
  });

  final String relativePath;
  final List<String> urls;
  final int bytes;
  final String sha256;
}

/// 按需模型仓的公共下载逻辑: 顺序下载分片, 分片失败换镜像,
/// sha256 校验通过后原子改名。文件落在 `<app support>/models/...`,
/// 通过 ak_init.models_dir 注入引擎。
abstract class ModelPack extends ChangeNotifier {
  ModelPack({required this.root, required this.files});

  final String root;
  final List<ModelFile> files;

  ModelPhase phase = ModelPhase.notDownloaded;
  double progress = 0;
  int downloadedBytes = 0;
  int totalBytes = 0;
  String? error;

  bool _cancelled = false;
  int _transientBytes = 0;
  double _lastNotified = -1;
  HttpClient? _client;
  bool _disposed = false;

  bool get busy => phase == ModelPhase.downloading;
  bool get ready => files.every(_fileReady);

  String pathOf(ModelFile file) => p.join(root, file.relativePath);

  Future<void> check() async {
    if (busy) {
      return;
    }
    await Directory(root).create(recursive: true);
    phase = ready ? ModelPhase.ready : ModelPhase.notDownloaded;
    progress = phase == ModelPhase.ready ? 1 : 0;
    error = null;
    _notify();
  }

  bool _fileReady(ModelFile file) {
    final target = File(pathOf(file));
    return target.existsSync() && target.lengthSync() == file.bytes;
  }

  Future<bool> download() async {
    if (busy) {
      return false;
    }
    _cancelled = false;
    _transientBytes = 0;
    _lastNotified = -1;
    error = null;
    phase = ModelPhase.downloading;
    totalBytes = files.fold(0, (sum, file) => sum + file.bytes);
    downloadedBytes = 0;
    progress = 0;
    _notify();

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20);
    _client = client;
    try {
      await Directory(root).create(recursive: true);
      for (final file in files) {
        _throwIfCancelled();
        final target = File(pathOf(file));
        if (_fileReady(file)) {
          downloadedBytes += file.bytes;
          _updateProgress(notify: true);
          continue;
        }
        await target.parent.create(recursive: true);
        final part = File('${target.path}.part');
        if (part.existsSync()) {
          await part.delete();
        }
        var completed = false;
        Object? lastError;
        for (final url in file.urls) {
          _throwIfCancelled();
          try {
            await _downloadOne(client, url, part, file);
            completed = true;
            break;
          } catch (e) {
            lastError = e;
            _transientBytes = 0;
            if (part.existsSync()) {
              await part.delete();
            }
          }
        }
        if (!completed) {
          throw ModelDownloadException(
            '下载失败: ${p.basename(file.relativePath)} ($lastError)',
          );
        }
        final digest = await sha256.bind(part.openRead()).first;
        if (digest.toString() != file.sha256.toLowerCase()) {
          await part.delete();
          throw ModelDownloadException(
            '模型校验失败: ${p.basename(file.relativePath)}',
          );
        }
        if (target.existsSync()) {
          await target.delete();
        }
        await part.rename(target.path);
        downloadedBytes += file.bytes;
        _transientBytes = 0;
        _updateProgress(notify: true);
      }
      phase = ModelPhase.ready;
      progress = 1;
      _notify();
      return true;
    } catch (e) {
      if (_cancelled) {
        phase = ModelPhase.notDownloaded;
        error = null;
      } else {
        phase = ModelPhase.failed;
        error = '$e';
      }
      _notify();
      return false;
    } finally {
      _client = null;
      client.close(force: true);
    }
  }

  void cancel() {
    _cancelled = true;
    _client?.close(force: true);
  }

  Future<void> _downloadOne(
    HttpClient client,
    String url,
    File part,
    ModelFile file,
  ) async {
    final request = await client.getUrl(Uri.parse(url));
    request.headers.set(HttpHeaders.userAgentHeader, 'avoxkit');
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      throw ModelDownloadException('HTTP ${response.statusCode}');
    }
    final sink = part.openWrite();
    var received = 0;
    try {
      await for (final chunk in response) {
        _throwIfCancelled();
        sink.add(chunk);
        received += chunk.length;
        _transientBytes = received;
        _updateProgress();
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    if (received != file.bytes) {
      throw ModelDownloadException('大小不符: $received/${file.bytes}');
    }
  }

  void _throwIfCancelled() {
    if (_cancelled) {
      throw StateError('cancelled');
    }
  }

  void _updateProgress({bool notify = false}) {
    if (totalBytes <= 0) {
      return;
    }
    final value =
        ((downloadedBytes + _transientBytes) / totalBytes).clamp(0.0, 1.0);
    progress = value;
    if (!notify && (value - _lastNotified).abs() < 0.005 && value < 1) {
      return;
    }
    _lastNotified = value;
    _notify();
  }

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    cancel();
    super.dispose();
  }
}

/// SenseVoice + Silero VAD 的按需模型仓。文件直接落在
/// `<app support>/models/stt/sense-voice/`, 通过 ak_init.models_dir 注入引擎。
class SttModel extends ModelPack {
  SttModel({required super.root, List<ModelFile>? files})
      : super(files: files ?? defaultFiles);

  static const license = 'SenseVoice · Apache-2.0 / Silero VAD · MIT';
  static String get downloadSizeLabel => I18n.tr('约 230 MB');

  static const defaultFiles = <ModelFile>[
    ModelFile(
      relativePath: 'stt/sense-voice/model.int8.onnx',
      urls: [
        'https://huggingface.co/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/main/model.int8.onnx',
        'https://hf-mirror.com/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/main/model.int8.onnx',
      ],
      bytes: 239233841,
      sha256: 'c71f0ce00bec95b07744e116345e33d8cbbe08cef896382cf907bf4b51a2cd51',
    ),
    ModelFile(
      relativePath: 'stt/sense-voice/tokens.txt',
      urls: [
        'https://huggingface.co/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/main/tokens.txt',
        'https://hf-mirror.com/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/main/tokens.txt',
      ],
      bytes: 315894,
      sha256: 'f449eb28dc567533d7fa59be34e2abca8784f771850c78a47fb731a31429a1dc',
    ),
    ModelFile(
      relativePath: 'stt/sense-voice/silero_vad.onnx',
      urls: [
        'https://github.com/xxxzhou/avox_model/raw/main/assets/models/stt/sense-voice/silero_vad.onnx',
        'https://media.githubusercontent.com/media/xxxzhou/avox_model/main/assets/models/stt/sense-voice/silero_vad.onnx',
      ],
      bytes: 643854,
      sha256: '9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6',
    ),
  ];
}

/// LaMa 修复 + YOLO26-Seg 水印检测的按需模型仓。
class InpaintModel extends ModelPack {
  InpaintModel({required super.root, List<ModelFile>? files})
      : super(files: files ?? defaultFiles);

  static const license = 'LaMa · Apache-2.0 / YOLO26-Seg · AGPL-3.0';
  static String get downloadSizeLabel => I18n.tr('约 290 MB');

  static const defaultFiles = <ModelFile>[
    ModelFile(
      relativePath: 'inpaint/lama_base.onnx',
      urls: [
        'https://github.com/xxxzhou/avox_model/raw/main/assets/models/inpaint/lama_base.onnx',
        'https://media.githubusercontent.com/media/xxxzhou/avox_model/main/assets/models/inpaint/lama_base.onnx',
      ],
      bytes: 208044816,
      sha256: '1faef5301d78db7dda502fe59966957ec4b79dd64e16f03ed96913c7a4eb68d6',
    ),
    ModelFile(
      relativePath: 'inpaint/yolo26m-seg_watermark.onnx',
      urls: [
        'https://github.com/xxxzhou/avox_model/raw/main/assets/models/inpaint/yolo26m-seg_watermark.onnx',
        'https://media.githubusercontent.com/media/xxxzhou/avox_model/main/assets/models/inpaint/yolo26m-seg_watermark.onnx',
      ],
      bytes: 94329787,
      sha256: 'ca42b56e9472ba9e77c8703114b9ee379561810cccb9c2e57e8c18f3a7f44613',
    ),
  ];
}
