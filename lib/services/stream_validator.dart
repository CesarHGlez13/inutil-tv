import 'dart:async';
import 'dart:io';

import 'network_config_service.dart';

/// Resultado granular de la validación de un enlace de video:
/// - [valid]: bytes multimedia reales verificados (MPEG-TS, MP4, MKV, AES-128).
/// - [invalid]: el servidor respondió con error HTTP (403/404/5xx) o HTML/DMCA.
/// - [timeout]: la red no alcanzó a responder dentro del límite (útil en redes
///   lentas para conservar el candidato como respaldo si ningún otro ganó rápido).
enum StreamValidationStatus { valid, invalid, timeout }

/// Resultado detallado de sonda con telemetría real de velocidad y latencia.
class StreamProbeResult {
  final StreamValidationStatus status;
  final int latencyMs;
  final double bytesPerSec;
  final int bytesRead;

  const StreamProbeResult({
    required this.status,
    this.latencyMs = 0,
    this.bytesPerSec = 0,
    this.bytesRead = 0,
  });

  bool get isValid => status == StreamValidationStatus.valid;
}

class _HostStats {
  double ewmaBytesPerSec = 0;
  int stallCount = 0;
  DateTime? penalizedUntil;
  DateTime lastUpdated = DateTime.now();
}

/// Monitor en memoria de salud y velocidad real por CDN/servidor de video.
///
/// Aprende en tiempo real qué hosts responden lento o se traban durante la
/// reproducción (p. ej. nodos saturados con throttling `sp=500`) y los degrada
/// automáticamente al final de la cola para que las películas y episodios
/// elijan primero los servidores rápidos y fluidos.
class StreamHostHealth {
  StreamHostHealth._();
  static final StreamHostHealth instance = StreamHostHealth._();

  static const Duration _penaltyDuration = Duration(minutes: 12);
  static const double _slowThresholdBytesPerSec = 180 * 1024; // 180 KB/s

  final Map<String, _HostStats> _byHost = {};
  final Map<String, _HostStats> _byServer = {};

  static String _hostKey(String url) {
    final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
    if (host.isEmpty) return '';
    // Agrupar subdominios aleatorios del mismo CDN (ej. h85xxx.acek-cdn.com -> acek-cdn.com)
    final parts = host.split('.');
    if (parts.length >= 3) {
      return '${parts[parts.length - 2]}.${parts.last}';
    }
    return host;
  }

  void recordThroughput(
    String url, {
    required int bytes,
    required int elapsedMs,
    String? server,
  }) {
    if (bytes < 4096 || elapsedMs <= 0) return;
    final sample = (bytes * 1000.0) / elapsedMs;
    final now = DateTime.now();

    void update(Map<String, _HostStats> map, String key) {
      if (key.isEmpty) return;
      final st = map.putIfAbsent(key, _HostStats.new);
      st.ewmaBytesPerSec = st.ewmaBytesPerSec <= 0
          ? sample
          : (st.ewmaBytesPerSec * 0.6 + sample * 0.4);
      st.lastUpdated = now;
      if (sample >= _slowThresholdBytesPerSec * 1.5 && st.stallCount > 0) {
        st.stallCount = (st.stallCount - 1).clamp(0, 10);
        if (st.stallCount == 0) st.penalizedUntil = null;
      } else if (bytes >= 32 * 1024 && sample < _slowThresholdBytesPerSec) {
        // Transferencia sostenida por debajo de 180 KB/s: marcar como lento
        st.stallCount = (st.stallCount + 1).clamp(0, 10);
        st.penalizedUntil = now.add(_penaltyDuration);
      }
    }

    update(_byHost, _hostKey(url));
    if (server != null && server.isNotEmpty) {
      update(_byServer, server.toLowerCase());
    }
  }

  void recordStallOrTimeout(String url, {String? server}) {
    final now = DateTime.now();
    void penalize(Map<String, _HostStats> map, String key) {
      if (key.isEmpty) return;
      final st = map.putIfAbsent(key, _HostStats.new);
      st.stallCount = (st.stallCount + 1).clamp(0, 10);
      st.penalizedUntil = now.add(_penaltyDuration);
      st.lastUpdated = now;
    }

    penalize(_byHost, _hostKey(url));
    if (server != null && server.isNotEmpty) {
      penalize(_byServer, server.toLowerCase());
    }
  }

  bool isHostPenalized(String url, {String? server}) {
    final now = DateTime.now();
    final h = _byHost[_hostKey(url)];
    if (h?.penalizedUntil != null && now.isBefore(h!.penalizedUntil!)) {
      return true;
    }
    if (server != null && server.isNotEmpty) {
      final s = _byServer[server.toLowerCase()];
      if (s?.penalizedUntil != null && now.isBefore(s!.penalizedUntil!)) {
        return true;
      }
    }
    return false;
  }

  /// Penalización numérica para ordenar hosts candidatos antes de raspar
  /// (0 = sano/rápido, positivo = degradado por cortes recientes).
  int hostOrderPenalty(String server) {
    final now = DateTime.now();
    final st = _byServer[server.toLowerCase()];
    if (st == null) return 0;
    if (st.penalizedUntil != null && now.isBefore(st.penalizedUntil!)) {
      return 100 + st.stallCount * 10;
    }
    if (st.ewmaBytesPerSec > 0 && st.ewmaBytesPerSec < _slowThresholdBytesPerSec) {
      return 50;
    }
    return 0;
  }

  /// Puntaje compuesto de calidad de red (mayor = mejor/más rápido).
  double scoreFor({
    required String url,
    String? server,
    double probeBytesPerSec = 0,
    int latencyMs = 0,
  }) {
    var score = 0.0;
    final penalized = isHostPenalized(url, server: server);
    if (penalized) score -= 5000.0;

    final hStats = _byHost[_hostKey(url)];
    final sStats = (server != null && server.isNotEmpty)
        ? _byServer[server.toLowerCase()]
        : null;

    final knownSpeed = hStats != null && hStats.ewmaBytesPerSec > 0
        ? hStats.ewmaBytesPerSec
        : (sStats != null && sStats.ewmaBytesPerSec > 0
            ? sStats.ewmaBytesPerSec
            : probeBytesPerSec);

    if (knownSpeed > 0) {
      // Escala en KB/s (ej. 1400 KB/s -> +1400, 100 KB/s -> +100)
      score += (knownSpeed / 1024.0).clamp(0.0, 4000.0);
      if (knownSpeed < _slowThresholdBytesPerSec) {
        score -= 1200.0;
      }
    }

    if (latencyMs > 0) {
      score -= (latencyMs / 10.0).clamp(0.0, 800.0);
    }

    // Heurística conocida: enlaces con throttling explícito `&sp=500` de VidHide
    // suelen saturarse en hora pico frente a StreamWish / Vidara.
    final lower = url.toLowerCase();
    if (lower.contains('acek-cdn.com') || lower.contains('&sp=500')) {
      score -= 350.0;
    }

    return score;
  }

  void resetForTest() {
    _byHost.clear();
    _byServer.clear();
  }
}

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

  /// Cabeceras completas de navegador para proveedores que filtran User-Agent de robot.
  static const Map<String, String> browserHeaders = <String, String>{
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, '
            'like Gecko) Chrome/125.0.0.0 Safari/537.36',
    'Accept': 'application/json,text/html;q=0.9,*/*;q=0.8',
    'Accept-Language': 'es-MX,es;q=0.9,en;q=0.8',
    'sec-ch-ua':
        '"Chromium";v="125", "Not-A.Brand";v="24", "Google Chrome";v="125"',
    'sec-ch-ua-mobile': '?0',
    'sec-ch-ua-platform': '"Windows"',
    'sec-fetch-dest': 'empty',
    'sec-fetch-mode': 'cors',
    'sec-fetch-site': 'same-origin',
  };

  /// Elimina acentos y diacríticos para búsquedas tolerantes (`dragón` -> `dragon`).
  static String stripAccents(String input) {
    const map = {
      'á': 'a',
      'à': 'a',
      'ä': 'a',
      'â': 'a',
      'ã': 'a',
      'é': 'e',
      'è': 'e',
      'ë': 'e',
      'ê': 'e',
      'í': 'i',
      'ì': 'i',
      'ï': 'i',
      'î': 'i',
      'ó': 'o',
      'ò': 'o',
      'ö': 'o',
      'ô': 'o',
      'õ': 'o',
      'ú': 'u',
      'ù': 'u',
      'ü': 'u',
      'û': 'u',
      'ñ': 'n',
      'ç': 'c',
      'Á': 'A',
      'À': 'A',
      'Ä': 'A',
      'Â': 'A',
      'É': 'E',
      'È': 'E',
      'Ë': 'E',
      'Ê': 'E',
      'Í': 'I',
      'Ì': 'I',
      'Ï': 'I',
      'Î': 'I',
      'Ó': 'O',
      'Ò': 'O',
      'Ö': 'O',
      'Ô': 'O',
      'Ú': 'U',
      'Ù': 'U',
      'Ü': 'U',
      'Û': 'U',
      'Ñ': 'N',
      'Ç': 'C',
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
    final shortLimit =
        bytes.length - 188 < maxScan ? bytes.length - 188 : maxScan;
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
    final res = await probeUrl(
      url,
      headers: headers,
      timeout: timeout,
      depth: depth,
      sharedClient: sharedClient,
    );
    return res.status;
  }

  /// Sonda de validación + velocidad real: además de comprobar bytes multimedia
  /// reales (rechazando HTML/DMCA/404), mide latencia y velocidad de descarga
  /// de una muestra real del segmento (hasta 48 KB) para detectar servidores
  /// lentos o saturados y priorizar los más rápidos.
  static Future<StreamProbeResult> probeUrl(
    String url, {
    Map<String, String> headers = const {},
    Duration timeout = const Duration(seconds: 8),
    int depth = 0,
    HttpClient? sharedClient,
    String? server,
  }) async {
    if (depth > 3 || !url.startsWith('http')) {
      return const StreamProbeResult(status: StreamValidationStatus.invalid);
    }

    final ownsClient = sharedClient == null;
    final client = sharedClient ?? _validationClient(timeout);
    final totalSw = Stopwatch()..start();

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
        req.headers.set('Range', 'bytes=0-49151');
      }

      final res = await req.close().timeout(timeout);
      if (res.statusCode < 200 || res.statusCode >= 400) {
        await res.drain<void>().catchError((_) {});
        return StreamProbeResult(
          status: StreamValidationStatus.invalid,
          latencyMs: totalSw.elapsedMilliseconds,
        );
      }

      final readSw = Stopwatch()..start();
      final maxRead = looksLikePlaylistUrl ? 16384 : 49152;
      final bytes = await _readUpTo(res, maxRead).timeout(timeout);
      readSw.stop();
      if (bytes.isEmpty) {
        return StreamProbeResult(
          status: StreamValidationStatus.invalid,
          latencyMs: totalSw.elapsedMilliseconds,
        );
      }

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
        if (lines.isEmpty) {
          return StreamProbeResult(
            status: StreamValidationStatus.invalid,
            latencyMs: totalSw.elapsedMilliseconds,
          );
        }

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
          return await probeUrl(
            nextUri,
            headers: headers,
            timeout: timeout,
            depth: depth + 1,
            sharedClient: client,
            server: server,
          );
        }

        // Verificar bytes reales + velocidad del primer segmento usando el MISMO client keep-alive
        return await _probeSegmentBytes(
          nextUri,
          headers: headers,
          timeout: timeout,
          client: client,
          server: server,
          totalElapsedBeforeMs: totalSw.elapsedMilliseconds,
        );
      }

      // Stream directo (MP4 / TS / MKV)
      final ok = isPlayableMediaBytes(bytes);
      final elapsedMs = readSw.elapsedMilliseconds.clamp(1, 60000);
      final bps = ok ? (bytes.length * 1000.0) / elapsedMs : 0.0;
      if (ok && bytes.length >= 4096) {
        StreamHostHealth.instance.recordThroughput(
          url,
          bytes: bytes.length,
          elapsedMs: elapsedMs,
          server: server,
        );
      }
      return StreamProbeResult(
        status: ok
            ? StreamValidationStatus.valid
            : StreamValidationStatus.invalid,
        latencyMs: totalSw.elapsedMilliseconds,
        bytesPerSec: bps,
        bytesRead: bytes.length,
      );
    } on TimeoutException {
      StreamHostHealth.instance.recordStallOrTimeout(url, server: server);
      return StreamProbeResult(
        status: StreamValidationStatus.timeout,
        latencyMs: totalSw.elapsedMilliseconds,
      );
    } on SocketException {
      return StreamProbeResult(
        status: StreamValidationStatus.timeout,
        latencyMs: totalSw.elapsedMilliseconds,
      );
    } catch (_) {
      return StreamProbeResult(
        status: StreamValidationStatus.invalid,
        latencyMs: totalSw.elapsedMilliseconds,
      );
    } finally {
      if (ownsClient) {
        client.close(force: true);
      }
    }
  }

  static Future<StreamProbeResult> _probeSegmentBytes(
    String segmentUrl, {
    required Map<String, String> headers,
    required Duration timeout,
    required HttpClient client,
    String? server,
    int totalElapsedBeforeMs = 0,
  }) async {
    final segSw = Stopwatch()..start();
    try {
      final req = await client
          .getUrl(Uri.parse(segmentUrl))
          .timeout(timeout);
      req.headers.set('User-Agent', headers['User-Agent'] ?? defaultUserAgent);
      headers.forEach((k, v) {
        if (k.toLowerCase() != 'user-agent') {
          req.headers.set(k, v);
        }
      });
      // Leer hasta 48 KB reales: ~35 ms en un servidor rápido, pero expone de
      // inmediato CDNs con throttling o estancados tras el primer KB.
      req.headers.set('Range', 'bytes=0-49151');

      final res = await req.close().timeout(timeout);
      if (res.statusCode < 200 || res.statusCode >= 400) {
        await res.drain<void>().catchError((_) {});
        return StreamProbeResult(
          status: StreamValidationStatus.invalid,
          latencyMs: totalElapsedBeforeMs + segSw.elapsedMilliseconds,
        );
      }

      final readSw = Stopwatch()..start();
      final bytes = await _readUpTo(res, 49152).timeout(timeout);
      readSw.stop();
      final ok = isPlayableMediaBytes(bytes);
      final elapsedMs = readSw.elapsedMilliseconds.clamp(1, 60000);
      final bps = ok ? (bytes.length * 1000.0) / elapsedMs : 0.0;
      if (ok && bytes.length >= 4096) {
        StreamHostHealth.instance.recordThroughput(
          segmentUrl,
          bytes: bytes.length,
          elapsedMs: elapsedMs,
          server: server,
        );
      }
      return StreamProbeResult(
        status: ok
            ? StreamValidationStatus.valid
            : StreamValidationStatus.invalid,
        latencyMs: totalElapsedBeforeMs + segSw.elapsedMilliseconds,
        bytesPerSec: bps,
        bytesRead: bytes.length,
      );
    } on TimeoutException {
      StreamHostHealth.instance
          .recordStallOrTimeout(segmentUrl, server: server);
      return StreamProbeResult(
        status: StreamValidationStatus.timeout,
        latencyMs: totalElapsedBeforeMs + segSw.elapsedMilliseconds,
      );
    } on SocketException {
      return StreamProbeResult(
        status: StreamValidationStatus.timeout,
        latencyMs: totalElapsedBeforeMs + segSw.elapsedMilliseconds,
      );
    } catch (_) {
      return StreamProbeResult(
        status: StreamValidationStatus.invalid,
        latencyMs: totalElapsedBeforeMs + segSw.elapsedMilliseconds,
      );
    }
  }

  static Future<List<int>> _readUpTo(
      HttpClientResponse res, int maxBytes) async {
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
