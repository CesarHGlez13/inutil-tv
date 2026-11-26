import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:tubotv/services/ota_download_manager.dart';

class _TempPathProvider extends PathProviderPlatform {
  _TempPathProvider(this.root);
  final Directory root;

  @override
  Future<String?> getTemporaryPath() async => root.path;

  @override
  Future<String?> getApplicationSupportPath() async => root.path;

  @override
  Future<String?> getApplicationDocumentsPath() async => root.path;

  @override
  Future<String?> getExternalStoragePath() async => root.path;
}

void main() {
  late Directory tempDir;
  late PathProviderPlatform previousProvider;
  late HttpServer server;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('tv_ota_validation_test_');
    previousProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _TempPathProvider(tempDir);
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  });

  tearDown(() async {
    await server.close(force: true);
    PathProviderPlatform.instance = previousProvider;
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('rechaza APK HTML y valida SHA-256 correctamente en Inutix TV', () async {
    final validApkBytes = <int>[0x50, 0x4B, 0x03, 0x04, 9, 8, 7, 6];
    final validSha = sha256.convert(validApkBytes).toString();
    var serveHtml = true;

    server.listen((req) {
      final body = serveHtml
          ? utf8.encode('<html>portal</html>')
          : validApkBytes;
      req.response
        ..statusCode = HttpStatus.ok
        ..headers.contentLength = body.length
        ..add(body);
      req.response.close();
    });

    final manager = OtaDownloadManager();
    addTearDown(manager.dispose);

    await expectLater(
      manager.download(
        url: 'http://127.0.0.1:${server.port}/tv.apk',
        fileName: 'tv_test.apk',
        onProgress: (_) {},
      ),
      throwsA(
        isA<OtaDownloadException>().having(
          (e) => e.message,
          'message',
          contains('no es un paquete APK válido'),
        ),
      ),
    );

    serveHtml = false;
    await expectLater(
      manager.download(
        url: 'http://127.0.0.1:${server.port}/tv.apk',
        fileName: 'tv_test.apk',
        expectedSha256: '1111111111111111111111111111111111111111111111111111111111111111',
        onProgress: (_) {},
      ),
      throwsA(
        isA<OtaDownloadException>().having(
          (e) => e.message,
          'message',
          contains('SHA-256'),
        ),
      ),
    );

    final path = await manager.download(
      url: 'http://127.0.0.1:${server.port}/tv.apk',
      fileName: 'tv_test.apk',
      expectedSha256: validSha,
      onProgress: (_) {},
    );
    expect(File(path).existsSync(), isTrue);
  });
}
