import 'dart:async';
import 'dart:io';

import 'network_config_service.dart';

/// Resultado granular de la validación de un enlace de video:
/// - [valid]: bytes multimedia reales verificados (MPEG-TS, MP4, MKV, AES-128).
/// - [invalid]: el servidor respondió con error HTTP (403/404/5xx) o HTML/DMCA.
/// - [timeout]: la red no alcanzó a responder dentro del límite (útil en redes
///   lentas para conservar el candidato como respaldo si ningún otro ganó rápido).
enum StreamValidationStatus { valid, invalid, timeout }

/// Validador real de streams de video (HLS / MP4 / MPEG-TS) para InútilTV.
///
/// Resuelve el problema clásico de "pantalla negra en 0:00": muchos servidores
/// devuelven HTTP 200 en el `.m3u8`, pero sus segmentos `.ts` contienen páginas
/// HTML de DMCA (`File deleted by DMCA request`) o errores 403/404.
/// Este validador inspecciona los primeros bytes reales del primer segmento
/// multimedia antes de entregar el enlace al reproductor.
class StreamValidator {
  StreamValidator._();

  static const String defaultUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

  /// Elimina acentos y diacríticos para búsquedas tolerantes (`dragón` -> `dragon`).
  static String stripAccents(String input) {
    const map = {
      'á': 'a', 'à': 'a', 'ä': 'a', 'â': 'a', 'ã': 'a',
      'é': 'e', 'è': 'e', 'ë': 'e', 'ê': 'e',
      'í': 'i', 'ì': 'i', 'ï': 'i', 'î': 'i',
      'ó': 'o', 'ò': 'o', 'ö': 'o', 'ô': 'o', 'õ': 'o',
      'ú': 'u', 'ù': 'u', 'ü': 'u', 'û': 'u',
      'ñ': 'n', 'ç': 'c',
      'Á': 'A', 'À': 'A', 'Ä': 'A', 'Â': 'A',
      'É': 'E', 'È': 'E', 'Ë': 'E', 'Ê': 'E',
      'Í': 'I', 'Ì': 'I', 'Ï': 'I', 'Î': 'I',
      'Ó': 'O', 'Ò': 'O', 'Ö': 'O', 'Ô': 'O',
      'Ú': 'U', 'Ù': 'U', 'Ü': 'U', 'Û': 'U',
      'Ñ': 'N', 'Ç': 'C',
    };
    final sb = StringBuffer();
    for (var i = 0; i < input.length; i++) {
      final ch = input[i];
      sb.write(map[ch] ?? ch);
    }
    return sb.toString();
  }

  /// Normaliza un título para deduplicación estricta entre catálogos.
  static String normalizeTitle(String title) {
    return stripAccents(title)
        .toLowerCase()
        .replaceAll(RegExp(r'\([^)]*\)|\[[^\]]*\]'), ' ')
        .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
        .trim();
  }

  /// Inspecciona los primeros bytes de un payload multimedia.
  /// Devuelve `true` solo si corresponden a video real (MPEG-TS, MP4/fMP4, MKV/WebM,
  /// ID3 o segmento cifrado binario) y NUNCA si son HTML/DMCA/JSON de error.
  static bool isPlayableMediaBytes(List<int> bytes) {
    if (bytes.length < 16) return false;

    // 1. Detectar y rechazar texto/HTML/JSON/DMCA en los primeros 256 bytes
    final sampleLen = bytes.length < 256 ? bytes.length : 256;
    final headText = String.fromCharCodes(
      bytes.sublist(0, sampleLen).map((b) => b & 0x7F),
    ).toLowerCase();

    if (headText.contains('<html') ||
        headText.contains('<!doctype') ||
        headText.contains('<head') ||
        headText.contains('<body') ||
        headText.contains('dmca') ||
        headText.contains('file deleted') ||
        headText.contains('access denied') ||
        headText.contains('not found') ||
        headText.contains('forbidden') ||
        headText.contains('error 404') ||
        headText.contains('error 403')) {
      return false;
    }

    final firstChar = bytes.first;
    // Rechazar JSON/XML plano
    if (firstChar == 0x7B /* { */ || firstChar == 0x3C /* < */) {
      return false;
    }

    // 2. Magic bytes conocidos de contenedores de video
    // MPEG-TS sync byte (0x47)
    if (bytes[0] == 0x47) return true;
    // MP4 / fMP4 (ftyp, moof, styp, moov, mdat)
    if (headText.contains('ftyp') ||
        headText.contains('moof') ||
        headText.contains('styp') ||
        headText.contains('moov') ||
        headText.contains('mdat')) {
      return true;
    }
    // Matroska / WebM EBML header (1A 45 DF A3)
    if (bytes[0] == 0x1A &&
        bytes[1] == 0x45 &&
        bytes[2] == 0xDF &&
        bytes[3] == 0xA3) {
      return true;
    }
    // ID3 tag at start of HLS audio/video TS
    if (bytes[0] == 0x49 && bytes[1] == 0x44 && bytes[2] == 0x33) {
      return true;
    }
    // PNG-wrapped TS segments (usado por VidHide / StreamWish sobre TikTok/CDN):
    // Exigimos que realmente contenga tramas MPEG-TS (0x47 cada 188B) o carga
    // binaria suficiente para descartar imágenes PNG de error 1x1 vacías.
    if (bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      if (findMpegTsSyncOffset(bytes) >= 0) return true;
      if (bytes.length >= 512) return true;
      return false;
    }

    // Segmentos HLS cifrados con AES-128 tienen alta entropía binaria (>= 188B)
    if (bytes.length >= 188) {
      var nonAscii = 0;
      for (var i = 0; i < sampleLen; i++) {
        if (bytes[i] < 0x09 || bytes[i] > 0x7E) nonAscii++;
      }
      if (nonAscii > sampleLen * 0.15) return true;
    }

    return false;
  }

  /// Localiza el offset donde inicia un flujo real MPEG-TS (`0x47` con
  /// periodicidad de paquete de 188 bytes) dentro de un segmento disfrazado
  /// como PNG/JPEG/GIF. Devuelve `-1` si no encuentra sincronización TS.
  static int findMpegTsSyncOffset(List<int> bytes, {int maxScan = 1024}) {
    if (bytes.length < 377) return -1;
    final limit = bytes.length - 376 < maxScan ? bytes.length - 376 : maxScan;
    for (var i = 0; i < limit; i++) {
      if (bytes[i] == 0x47 &&
          bytes[i + 188] == 0x47 &&
          bytes[i + 376] == 0x47) {
        return i;
      }
    }
    // Fallback para segmentos cortos (< 564B): 2 paquetes consecutivos
    final shortLimit = bytes.length - 188 < maxScan ? bytes.length - 188 : maxScan;
    for (var i = 0; i < shortLimit; i++) {
      if (bytes[i] == 0x47 && bytes[i + 188] == 0x47) {
        return i;
      }
    }
    return -1;
  }

  /// Detecta si [url] apunta a un playlist HLS o a un segmento con extensión
  /// disfrazada que requiere pasar por el proxy local `127.0.0.1` (.ts puro).
  static bool needsLocalHlsProxy(String url) {
    final l = url.toLowerCase();
    if (l.startsWith('http://127.0.0.1') || l.startsWith('http://localhost')) {
      return false;
    }
    return l.contains('.m3u8') ||
        l.contains('/stream/') ||
        l.contains('master.txt') ||
        l.contains('hls');
  }

  /// Cliente HTTP de validación: respeta el proxy corporativo y el DNS seguro
  /// configurados en Ajustes (ver `NetworkConfigService`) y mantiene keep-alive
  /// entre master.m3u8 -> index.m3u8 -> primer segmento .ts (1 solo handshake TLS).
  static HttpClient _validationClient(Duration timeout) {
    final client = HttpClient()
      ..idleTimeout = const Duration(seconds: 15)
      ..maxConnectionsPerHost = 4
      ..badCertificateCallback = (_, __, ___) => true;
    NetworkConfigService.instance.apply(
      client,
      tolerateBadCertificates: true,
      connectTimeout: timeout,
    );
    return client;
  }

  /// Verifica en red que [url] entregue video reproducible real (NO DMCA HTML).
  static Future<bool> validateUrl(
    String url, {
    Map<String, String> headers = const {},
    Duration timeout = const Duration(seconds: 10),
    int depth = 0,
  }) async {
    final status = await validateUrlDetailed(
      url,
      headers: headers,
      timeout: timeout,
      depth: depth,
    );
    return status == StreamValidationStatus.valid;
  }

  /// Igual que [validateUrl] pero distingue entre rechazo real (`invalid`: 403/404/DMCA)
  /// y vencimiento de tiempo por red lenta (`timeout`), reutilizando el mismo
  /// `HttpClient` keep-alive en toda la cadena HLS para ahorrar 2 handshakes TLS.
  static Future<StreamValidationStatus> validateUrlDetailed(
    String url, {
    Map<String, String> headers = const {},
    Duration timeout = const Duration(seconds: 10),
    int depth = 0,
    HttpClient? sharedClient,
  }) async {
    if (depth > 3 || !url.startsWith('http')) {
      return StreamValidationStatus.invalid;
    }

    final ownsClient = sharedClient == null;
    final client = sharedClient ?? _validationClient(timeout);

    try {
      final uri = Uri.parse(url);
      final req = await client.getUrl(uri).timeout(timeout);
      req.headers.set('User-Agent', headers['User-Agent'] ?? defaultUserAgent);
      headers.forEach((k, v) {
        if (k.toLowerCase() != 'user-agent') {
          req.headers.set(k, v);
        }
      });
      final lowerUrl = url.toLowerCase();
      final looksLikePlaylistUrl = lowerUrl.contains('.m3u8') ||
          lowerUrl.contains('master.txt') ||
          lowerUrl.contains('/playlist');
      // No enviar Range en playlists .m3u8/.txt (algunos CDNs devuelven 416/403).
      if (!looksLikePlaylistUrl) {
        req.headers.set('Range', 'bytes=0-16383');
      }

      final res = await req.close().timeout(timeout);
      if (res.statusCode < 200 || res.statusCode >= 400) {
        await res.drain<void>().catchError((_) {});
        return StreamValidationStatus.invalid;
      }

      final bytes = await _readUpTo(res, 16384).timeout(timeout);
      if (bytes.isEmpty) return StreamValidationStatus.invalid;

      // ¿Es un playlist HLS (#EXTM3U)?
      final prefixLen = bytes.length < 128 ? bytes.length : 128;
      final prefix = String.fromCharCodes(
        bytes.sublist(0, prefixLen).map((b) => b & 0x7F),
      );
      if (prefix.contains('#EXTM3U')) {
        final text = String.fromCharCodes(bytes.map((b) => b & 0x7F));
        final lines = text
            .split('\n')
            .map((l) => l.trim())
            .where((l) => l.isNotEmpty && !l.startsWith('#'))
            .toList();
        if (lines.isEmpty) return StreamValidationStatus.invalid;

        var resolvedBase = uri;
        for (final r in res.redirects) {
          resolvedBase = resolvedBase.resolveUri(r.location);
        }
        final nextUri = resolvedBase.resolve(lines.first).toString();
        final nextLower = nextUri.toLowerCase();
        final isSubPlaylist = nextLower.contains('.m3u8') ||
            nextLower.contains('master') ||
            nextLower.contains('index') ||
            nextLower.contains('chunklist') ||
            nextLower.contains('playlist');

        if (isSubPlaylist && depth < 2) {
          return await validateUrlDetailed(
            nextUri,
            headers: headers,
            timeout: timeout,
            depth: depth + 1,
            sharedClient: client,
          );
        }

        // Verificar bytes reales del primer segmento de video usando el MISMO client keep-alive
        return await _validateSegmentBytesDetailed(
          nextUri,
          headers: headers,
          timeout: timeout,
          client: client,
        );
      }

      // Stream directo (MP4 / TS / MKV)
      return isPlayableMediaBytes(bytes)
          ? StreamValidationStatus.valid
          : StreamValidationStatus.invalid;
    } on TimeoutException {
      return StreamValidationStatus.timeout;
    } on SocketException {
      return StreamValidationStatus.timeout;
    } catch (_) {
      return StreamValidationStatus.invalid;
    } finally {
      if (ownsClient) {
        client.close(force: true);
      }
    }
  }

  static Future<StreamValidationStatus> _validateSegmentBytesDetailed(
    String segmentUrl, {
    required Map<String, String> headers,
    required Duration timeout,
    required HttpClient client,
  }) async {
    try {
      final req = await client.getUrl(Uri.parse(segmentUrl)).timeout(timeout);
      req.headers.set('User-Agent', headers['User-Agent'] ?? defaultUserAgent);
      headers.forEach((k, v) {
        if (k.toLowerCase() != 'user-agent') {
          req.headers.set(k, v);
        }
      });
      req.headers.set('Range', 'bytes=0-1023');

      final res = await req.close().timeout(timeout);
      if (res.statusCode < 200 || res.statusCode >= 400) {
        await res.drain<void>().catchError((_) {});
        return StreamValidationStatus.invalid;
      }

      final bytes = await _readUpTo(res, 1024).timeout(timeout);
      return isPlayableMediaBytes(bytes)
          ? StreamValidationStatus.valid
          : StreamValidationStatus.invalid;
    } on TimeoutException {
      return StreamValidationStatus.timeout;
    } on SocketException {
      return StreamValidationStatus.timeout;
    } catch (_) {
      return StreamValidationStatus.invalid;
    }
  }

  static Future<List<int>> _readUpTo(HttpClientResponse res, int maxBytes) async {
    final out = <int>[];
    await for (final chunk in res) {
      final remaining = maxBytes - out.length;
      if (remaining <= 0) break;
      if (chunk.length <= remaining) {
        out.addAll(chunk);
      } else {
        out.addAll(chunk.sublist(0, remaining));
        break;
      }
    }
    return out;
  }
}
