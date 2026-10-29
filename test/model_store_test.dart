import 'dart:convert';
import 'dart:io';

import 'package:avoxkit/core/model_store.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('avoxkit_model_test_');
  });

  tearDown(() {
    if (temp.existsSync()) {
      temp.deleteSync(recursive: true);
    }
  });

  ModelFile file(String relative, String content) {
    final bytes = utf8.encode(content);
    return ModelFile(
      relativePath: relative,
      urls: const ['https://example.invalid/model'],
      bytes: bytes.length,
      sha256: sha256.convert(bytes).toString(),
    );
  }

  test('默认清单是 SenseVoice 三件套', () {
    expect(SttModel.defaultFiles, hasLength(3));
    expect(
      SttModel.defaultFiles.map((file) => file.relativePath),
      containsAll([
        'stt/sense-voice/model.int8.onnx',
        'stt/sense-voice/tokens.txt',
        'stt/sense-voice/silero_vad.onnx',
      ]),
    );
    for (final file in SttModel.defaultFiles) {
      expect(file.bytes, greaterThan(0));
      expect(file.sha256.length, 64);
      expect(file.urls, isNotEmpty);
    }
  });

  test('分片齐全且大小一致时 ready', () async {
    final files = [file('stt/sense-voice/a.onnx', 'abc'), file('stt/sense-voice/b.txt', 'de')];
    for (final item in files) {
      final target = File(p.join(temp.path, item.relativePath));
      target.parent.createSync(recursive: true);
      target.writeAsStringSync('x' * item.bytes);
    }
    final model = SttModel(root: temp.path, files: files);
    await model.check();
    expect(model.ready, isTrue);
    expect(model.phase, ModelPhase.ready);
    expect(model.progress, 1);
    model.dispose();
  });

  test('大小不符时不算 ready', () async {
    final files = [file('a.onnx', 'abc')];
    final target = File(p.join(temp.path, 'a.onnx'));
    target.parent.createSync(recursive: true);
    target.writeAsStringSync('abcd');
    final model = SttModel(root: temp.path, files: files);
    await model.check();
    expect(model.ready, isFalse);
    expect(model.phase, ModelPhase.notDownloaded);
    model.dispose();
  });

  test('缺目录时 check 会建目录且不崩', () async {
    final root = p.join(temp.path, 'missing', 'models');
    final model = SttModel(root: root, files: const []);
    await model.check();
    expect(Directory(root).existsSync(), isTrue);
    expect(model.ready, isTrue);
    model.dispose();
  });

  test('下载校验 sha256，主源失败自动换镜像', () async {
    final payload = utf8.encode('abcde');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      if (request.uri.path == '/model') {
        request.response.headers.contentLength = payload.length;
        request.response.add(payload);
      } else {
        request.response.statusCode = HttpStatus.notFound;
      }
      await request.response.close();
    });
    final item = ModelFile(
      relativePath: 'a.onnx',
      urls: [
        'http://127.0.0.1:${server.port}/missing',
        'http://127.0.0.1:${server.port}/model',
      ],
      bytes: payload.length,
      sha256: sha256.convert(payload).toString(),
    );
    final model = SttModel(root: temp.path, files: [item]);
    expect(await model.download(), isTrue);
    expect(model.ready, isTrue);
    expect(model.phase, ModelPhase.ready);
    expect(File(p.join(temp.path, 'a.onnx')).readAsStringSync(), 'abcde');
    model.dispose();
  });
}
