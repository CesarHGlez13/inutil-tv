import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Progreso de una descarga OTA reanudable.
class OtaDownloadProgress {
  const OtaDownloadProgress({
    required this.receivedBytes,
    required this.totalBytes,
    required this.resumedBytes,
    required this.bytesPerSecond,
  });

  final int receivedBytes;
  final int totalBytes;
  final int resumedBytes;
  final int bytesPerSecond;

  bool get hasTotal => totalBytes > 0;

  double? get fraction {
    if (totalBytes <= 0) return null;
    return (receivedBytes / totalBytes).clamp(0.0, 1.0);
  }

  bool get isResuming => resumedBytes > 0;
}

class OtaDownloadCancelled implements Exception {
  const OtaDownloadCancelled();

  @override
  String toString() => 'La descarga de la actualización se canceló.';
}

class OtaDownloadException implements Exception {
  const OtaDownloadException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

/// Descarga el APK de actualización con soporte HTTP Range (reanudación)
/// dentro de `getExternalStorageDirectory()/updates` (compartido por FileProvider).
class OtaDownloadManager {
  OtaDownloadManager({
    HttpClient? client,
    Stopwatch Function()? clock,
  })  : _httpClient = client,
        _clock = clock ?? Stopwatch.new;

  static const String updatesDirectoryName = 'updates';
  static const Duration _idleTimeout = Duration(seconds: 45);
  static const Duration _connectTimeout = Duration(seconds: 25);
  static const Duration _responseTimeout = Duration(seconds: 30);
  static const Duration _progressThrottle = Duration(milliseconds: 180);
  static const int _progressByteThrottle = 256 * 1024;
  static const int _statusPartialContent = 206;
  static const int _statusRangeNotSatisfiable = 416;

  final HttpClient? _httpClient;
  final Stopwatch Function() _clock;

  bool _cancelled = false;
  StreamSubscription<List<int>>? _activeSubscription;
  HttpClient? _ownedClient;

  bool get isDownloadActive => _activeSubscription != null;

  void dispose() {
    unawaited(_activeSubscription?.cancel() ?? Future<void>.value());
    _activeSubscription = null;
    _ownedClient?.close(force: true);
    _ownedClient = null;
  }

  Future<Directory> updatesDirectory() async {
    Directory? base;
    try {
      if (Platform.isAndroid) {
        base = await getTemporaryDirectory();
      } else if (Platform.isLinux || Platform.isMacOS || Platform.isWindows) {
        base = await getApplicationSupportDirectory();
      }
    } catch (_) {
      base = null;
    }
    if (base == null && Platform.isAndroid) {
      try {
        base = await getExternalStorageDirectory();
      } catch (_) {
        base = null;
      }
    }
    base ??= await getApplicationDocumentsDirectory();
    final directory = Directory(p.join(base.path, updatesDirectoryName));
    return directory.create(recursive: true);
  }

  /// Verifica firma ZIP (`PK\x03\x04`) para `.apk` y SHA-256 si fue publicado.
  Future<String?> _validateDownloadedFile(
    File file, {
    required String fileName,
    String expectedSha256 = '',
  }) async {
    if (!await file.exists()) return 'El archivo descargado no existe.';
    final size = await file.length();
    if (size < 4) return 'El archivo descargado está vacío o truncado.';
    if (fileName.toLowerCase().endsWith('.apk')) {
      RandomAccessFile? raf;
      try {
        raf = await file.open();
        final header = await raf.read(4);
        if (header.length < 4 ||
            header[0] != 0x50 ||
            header[1] != 0x4B ||
            header[2] != 0x03 ||
            header[3] != 0x04) {
          return 'El archivo descargado no es un paquete APK válido (posible bloqueo de red o portal cautivo).';
        }
      } finally {
        await raf?.close();
      }
    }
    final cleanSha = expectedSha256.trim().toLowerCase();
    if (cleanSha.isNotEmpty) {
      final digest = await sha256.bind(file.openRead()).first;
      if (digest.toString().toLowerCase() != cleanSha) {
        return 'La verificación de integridad (SHA-256) falló; el paquete se descargó corrupto.';
      }
    }
    return null;
  }

  Future<void> cancelActiveDownload() async {
    _cancelled = true;
    final subscription = _activeSubscription;
    _activeSubscription = null;
    if (subscription != null) {
      await subscription.cancel();
    }
  }

  Future<String?> existingDownload({
    required String url,
    required String fileName,
    String expectedSha256 = '',
  }) async {
    try {
      final directory = await updatesDirectory();
      final finalFile = File(p.join(directory.path, fileName));
      final doneMetaPath = p.join(directory.path, '$fileName.done.meta');
      if (!await finalFile.exists()) return null;
      final meta = await _readMeta(doneMetaPath);
      if (meta != null && meta['url'] == url && meta['complete'] == true) {
        final problem = await _validateDownloadedFile(
          finalFile,
          fileName: fileName,
          expectedSha256: expectedSha256,
        );
        if (problem == null) return finalFile.path;
        await _deleteQuietly(finalFile);
        await _deleteQuietly(File(doneMetaPath));
      }
    } catch (_) {}
    return null;
  }

  Future<String> download({
    required String url,
    required String fileName,
    required void Function(OtaDownloadProgress progress) onProgress,
    String expectedSha256 = '',
  }) async {
    _cancelled = false;
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) {
      throw const OtaDownloadException('El enlace de descarga no es válido.');
    }
    final directory = await updatesDirectory();
    final finalPath = p.join(directory.path, fileName);
    final partPath = p.join(directory.path, '$fileName.part');
    final metaPath = p.join(directory.path, '$fileName.part.meta');
    final doneMetaPath = p.join(directory.path, '$fileName.done.meta');
    final partFile = File(partPath);

    final previous = await existingDownload(
      url: url,
      fileName: fileName,
      expectedSha256: expectedSha256,
    );
    if (previous != null) return previous;

    var startOffset = 0;
    if (await partFile.exists()) {
      final meta = await _readMeta(metaPath);
      if (meta == null || meta['url'] != url) {
        await _deleteQuietly(partFile);
        await _deleteQuietly(File(metaPath));
      } else {
        startOffset = await partFile.length();
      }
    }

    final client = _httpClient ??
        (_ownedClient ??= HttpClient()..connectionTimeout = _connectTimeout);

    HttpClientResponse response;
    try {
      final request = await client.getUrl(uri).timeout(_connectTimeout);
      request.headers.set(
        HttpHeaders.userAgentHeader,
        'InutilTV-Updater/2.0.0 (OTA; resumable)',
      );
      request.headers.set(HttpHeaders.acceptHeader, '*/*');
      if (startOffset > 0) {
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=$startOffset-');
      }
      response = await request.close().timeout(_responseTimeout);
    } on TimeoutException {
      throw const OtaDownloadException(
        'El servidor de actualizaciones tardó demasiado en responder.',
      );
    } on SocketException catch (error) {
      throw OtaDownloadException(
        'Sin conexión con el servidor de actualizaciones: ${error.message}',
      );
    }

    if (response.statusCode == _statusRangeNotSatisfiable) {
      await _deleteQuietly(partFile);
      await _deleteQuietly(File(metaPath));
      await response.drain<void>();
      throw const OtaDownloadException(
        'La descarga anterior quedó obsoleta. Vuelve a intentarlo.',
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      await response.drain<void>();
      throw OtaDownloadException(
        'El servidor devolvió el código HTTP ${response.statusCode}.',
        statusCode: response.statusCode,
      );
    }

    final partialAccepted =
        response.statusCode == _statusPartialContent && startOffset > 0;
    if (!partialAccepted && startOffset > 0) {
      await _deleteQuietly(partFile);
      startOffset = 0;
    }

    final remaining = response.contentLength;
    final totalBytes = remaining < 0
        ? -1
        : (partialAccepted ? startOffset + remaining : remaining);

    await _writeMeta(metaPath, <String, Object?>{
      'url': url,
      'totalBytes': totalBytes,
      'complete': false,
    });

    final sink = partFile.openWrite(
      mode: partialAccepted ? FileMode.append : FileMode.write,
    );
    final stopwatch = _clock()..start();
    var sessionBytes = 0;
    var lastEmitBytes = 0;
    var lastEmitAt = DateTime.fromMillisecondsSinceEpoch(0);
    final completer = Completer<String>();
    Timer? idleTimer;

    void reportProgress() {
      final elapsed = stopwatch.elapsed;
      final speed = elapsed.inMilliseconds > 200
          ? sessionBytes * 1000 ~/ elapsed.inMilliseconds
          : 0;
      onProgress(
        OtaDownloadProgress(
          receivedBytes: startOffset + sessionBytes,
          totalBytes: totalBytes,
          resumedBytes: partialAccepted ? startOffset : 0,
          bytesPerSecond: speed,
        ),
      );
      lastEmitBytes = sessionBytes;
      lastEmitAt = DateTime.now();
    }

    void failWith(Object error, [StackTrace? stackTrace]) {
      if (completer.isCompleted) return;
      completer.completeError(error, stackTrace ?? StackTrace.current);
    }

    void armIdleTimer() {
      idleTimer?.cancel();
      idleTimer = Timer(_idleTimeout, () {
        final active = _activeSubscription;
        _activeSubscription = null;
        unawaited(active?.cancel() ?? Future<void>.value());
        unawaited(sink.close());
        failWith(
          const OtaDownloadException(
            'La descarga dejó de responder. Puedes reanudarla.',
          ),
        );
      });
    }

    reportProgress();
    late final StreamSubscription<List<int>> subscription;
    subscription = response.listen(
      (chunk) {
        armIdleTimer();
        sink.add(chunk);
        sessionBytes += chunk.length;
        final sinceBytes = sessionBytes - lastEmitBytes;
        final sinceTime = DateTime.now().difference(lastEmitAt);
        if (sinceBytes >= _progressByteThrottle ||
            sinceTime >= _progressThrottle) {
          reportProgress();
        }
      },
      onDone: () async {
        idleTimer?.cancel();
        _activeSubscription = null;
        try {
          await sink.flush();
          await sink.close();
        } catch (_) {}
        if (_cancelled) {
          failWith(const OtaDownloadCancelled());
          return;
        }
        try {
          final written = await partFile.length();
          if (totalBytes > 0 && written != totalBytes) {
            throw OtaDownloadException(
              'La descarga se interrumpió ($written / $totalBytes bytes). '
              'Vuelve a intentarlo para reanudar.',
            );
          }
          final validationProblem = await _validateDownloadedFile(
            partFile,
            fileName: fileName,
            expectedSha256: expectedSha256,
          );
          if (validationProblem != null) {
            await _deleteQuietly(partFile);
            await _deleteQuietly(File(metaPath));
            throw OtaDownloadException(validationProblem);
          }
          final target = File(finalPath);
          if (await target.exists()) {
            await target.delete();
          }
          await partFile.rename(finalPath);
          await _writeMeta(doneMetaPath, <String, Object?>{
            'url': url,
            'totalBytes': written,
            'complete': true,
          });
          await _deleteQuietly(File(metaPath));
          if (!completer.isCompleted) {
            completer.complete(finalPath);
          }
        } catch (error, stackTrace) {
          failWith(error, stackTrace);
        }
      },
      onError: (Object error, StackTrace stackTrace) async {
        idleTimer?.cancel();
        _activeSubscription = null;
        try {
          await sink.close();
        } catch (_) {}
        if (_cancelled) {
          failWith(const OtaDownloadCancelled());
          return;
        }
        failWith(
          error is OtaDownloadException
              ? error
              : OtaDownloadException(
                  'La descarga se interrumpió: $error. Puedes reanudarla.',
                ),
          stackTrace,
        );
      },
      cancelOnError: true,
    );
    _activeSubscription = subscription;
    armIdleTimer();

    try {
      return await completer.future;
    } finally {
      idleTimer?.cancel();
      _activeSubscription = null;
    }
  }

  Future<void> clearDownloads() async {
    try {
      final directory = await updatesDirectory();
      if (!await directory.exists()) return;
      await for (final entity in directory.list(followLinks: false)) {
        if (entity is File) await _deleteQuietly(entity);
      }
    } catch (_) {}
  }

  Future<Map<String, Object?>?> _readMeta(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return null;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map) {
        return decoded.map(
          (key, value) => MapEntry(key.toString(), value as Object?),
        );
      }
    } catch (_) {}
    return null;
  }

  Future<void> _writeMeta(String path, Map<String, Object?> meta) async {
    try {
      final file = File(path);
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode(meta), flush: true);
    } catch (_) {}
  }

  Future<void> _deleteQuietly(FileSystemEntity entity) async {
    try {
      if (await entity.exists()) await entity.delete();
    } catch (_) {}
  }
}
