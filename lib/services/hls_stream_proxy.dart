import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'network_config_service.dart';
import 'stream_validator.dart';
import 'tv_mode_service.dart';
import 'vault_crypto.dart';

/// Proxy HTTP local (`127.0.0.1:<puerto_efímero>`) de InútilTV v3.1.
///
/// Resuelve simultáneamente DOS problemas críticos de streaming Android (`libmpv`):
/// 1. **Segmentos HLS disfrazados (VidHide / StreamWish / TikTok CDN):**
///    Estos servidores entregan segmentos con extensión `.image`/`.png`/`.jpg`
///    y un prefijo PNG falso de ~70 bytes antes de la trama MPEG-TS `0x47`.
///    `ffmpeg`/`libmpv` rechaza `.image` con `not in allowed_segment_extensions`.
///    Este proxy reescribe todo playlist a URLs locales `/seg/<idx>.ts`, inyecta
///    `Referer`/`Origin`/`User-Agent` y recorta el prefijo falso al vuelo para
///    emitir `video/mp2t` 100 % limpio.
/// 2. **Precarga instantánea del siguiente episodio (Series y Anime):**
///    Permite pre-descargar en segundo plano los primeros 2–3 minutos (~16 MB)
///    de segmentos HLS o primeros 10 MB de MP4 en memoria RAM acotada, sirviendo
///    esos bloques en <5 ms desde `127.0.0.1` al cambiar de episodio y haciendo
///    proxy transparente del resto del archivo.
class HlsStreamProxy {
  HlsStreamProxy._();
  static final HlsStreamProxy instance = HlsStreamProxy._();

  static const int _maxTotalCacheBytes = 42 * 1024 * 1024; // 42 MB máx. global
  static const int _maxSessions = 6;
  static const Duration _connectTimeout = Duration(seconds: 7);
  static const Duration _upstreamTimeout = Duration(seconds: 12);

  HttpServer? _server;
  HttpClient? _sharedHttpClient;
  int _port = 0;
  int _nextSessionSeq = 0;
  double _ewmaBytesPerSec = 0;
  final Map<String, _ProxySession> _sessions = {};
  final Map<String, _VaultPlaybackSession> _vaultSessions = {};
  Future<void>? _starting;

  /// Estima cuántos segmentos adelantar según el ancho de banda real medido.
  /// En redes lentas (< 200 KB/s ≈ 1.6 Mbps) limita el lookahead a +1 segmento
  /// para que el segmento actual reciba todo el ancho de banda sin saturarse.
  @visibleForTesting
  static int adaptiveLookaheadForThroughput(double bytesPerSec) {
    if (bytesPerSec <= 0) return 3; // aún sin medir: balanceado
    if (bytesPerSec < 200 * 1024) return 1; // red lenta (3G / 4G débil)
    if (bytesPerSec < 600 * 1024) return 2; // red media
    return 4; // Wi-Fi / fibra rápida
  }

  void _recordThroughput(int bytes, int elapsedMs) {
    if (bytes < 4096 || elapsedMs <= 0) return;
    final sample = (bytes * 1000.0) / elapsedMs;
    _ewmaBytesPerSec = _ewmaBytesPerSec <= 0
        ? sample
        : (_ewmaBytesPerSec * 0.65 + sample * 0.35);
  }

  HttpClient get _httpClient {
    final existing = _sharedHttpClient;
    if (existing != null) return existing;
    final c = HttpClient()
      ..connectionTimeout = _connectTimeout
      ..idleTimeout = const Duration(seconds: 30)
      ..maxConnectionsPerHost = 8
      ..badCertificateCallback = (_, __, ___) => true;
    // Video: atraviesa el proxy corporativo / DNS seguro cuando están activos.
    NetworkConfigService.instance.apply(
      c,
      tolerateBadCertificates: true,
      connectTimeout: _connectTimeout,
    );
    _sharedHttpClient = c;
    return c;
  }

  /// Un cambio de proxy o de DNS seguro invalida el cliente con pool antiguo:
  /// la siguiente conexión ya usa la configuración nueva.
  void _resetUpstreamClient() {
    final c = _sharedHttpClient;
    if (c == null) return;
    _sharedHttpClient = null;
    c.close(force: true);
  }

  int get port => _port;
  bool get isRunning => _server != null && _port > 0;

  Future<void> ensureStarted() async {
    if (_server != null && _port > 0) return;
    if (_starting != null) return _starting;
    // Reacciona a cambios de proxy / DNS seguro definidos en Ajustes.
    NetworkConfigService.instance.removeListener(_resetUpstreamClient);
    NetworkConfigService.instance.addListener(_resetUpstreamClient);
    _starting = _startInternal();
    try {
      await _starting;
    } finally {
      _starting = null;
    }
  }

  Future<void> _startInternal() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    _port = server.port;
    server.listen(
      _handleRequest,
      onError: (Object e) => debugPrint('[HlsStreamProxy] Server error: $e'),
    );
  }

  /// Registra un flujo HLS remoto y devuelve su URL local `http://127.0.0.1:...`
  /// lista para `media_kit` (con extensión `.ts` garantizada y recorte de header
  /// PNG falso).
  ///
  /// Si [eagerWarmup] es `true`, comienza en segundo plano a descargar el
  /// master playlist, la variante preferida y los primeros 2 segmentos antes
  /// incluso de que `libmpv` abra el socket local.
  Future<ProxyRegistration> registerHlsSession({
    required String upstreamUrl,
    Map<String, String> headers = const {},
    String? tag,
    bool eagerWarmup = false,
  }) async {
    await ensureStarted();
    _evictOldSessionsIfNeeded();

    final id = 's${++_nextSessionSeq}_${DateTime.now().millisecondsSinceEpoch}';
    final session = _ProxySession(
      id: id,
      isMp4: false,
      upstreamMasterUrl: upstreamUrl,
      headers: Map<String, String>.from(headers),
      tag: tag ?? '',
    );
    _sessions[id] = session;

    if (eagerWarmup) {
      unawaited(_warmHlsStartup(session));
    }

    return ProxyRegistration(
      sessionId: id,
      localUrl: 'http://127.0.0.1:$_port/s/$id/master.m3u8',
      isMp4: false,
    );
  }

  /// Calienta silenciosamente el playlist maestro, su variante preferida y los
  /// primeros 2 segmentos en paralelo para recortar el arranque en frío.
  Future<void> _warmHlsStartup(_ProxySession session) async {
    try {
      final master = await _ensureMasterPlaylist(session);
      if (master == null || !_sessions.containsKey(session.id)) return;
      if (master.variantIndices.isNotEmpty) {
        final bestVarIdx =
            master.preferredVariantIndex ?? master.variantIndices.first;
        final sub = await _ensureSubPlaylist(session, bestVarIdx);
        if (sub != null &&
            sub.segmentIndices.isNotEmpty &&
            _sessions.containsKey(session.id)) {
          _triggerLookahead(session, sub.segmentIndices.first - 1, maxAhead: 2);
        }
      } else if (master.segmentIndices.isNotEmpty) {
        _triggerLookahead(session, master.segmentIndices.first - 1,
            maxAhead: 2);
      }
    } catch (_) {}
  }

  /// Registra un MP4 directo para precarga de sus primeros bytes y proxy de
  /// rangos `206 Partial Content`.
  ///
  /// [extension] conserva la terminación real del archivo upstream (`.mkv`,
  /// `.webm`...) para que `libmpv` elija el demuxer correcto al ver la URL
  /// local; por defecto `mp4`.
  Future<ProxyRegistration> registerMp4Session({
    required String upstreamUrl,
    Map<String, String> headers = const {},
    String? tag,
    String extension = 'mp4',
  }) async {
    await ensureStarted();
    _evictOldSessionsIfNeeded();

    final id = 'm${++_nextSessionSeq}_${DateTime.now().millisecondsSinceEpoch}';
    final session = _ProxySession(
      id: id,
      isMp4: true,
      upstreamMasterUrl: upstreamUrl,
      headers: Map<String, String>.from(headers),
      tag: tag ?? '',
    );
    _sessions[id] = session;

    final safeExt =
        RegExp(r'^[a-z0-9]{1,5}$').hasMatch(extension) ? extension : 'mp4';
    return ProxyRegistration(
      sessionId: id,
      localUrl: 'http://127.0.0.1:$_port/m/$id/video.$safeExt',
      isMp4: true,
    );
  }

  /// Precarga en memoria los primeros ~2–3 minutos de un playlist HLS registrado
  /// (selecciona automáticamente la variante de mejor calidad si es master).
  /// Devuelve la cantidad de segmentos y bytes cacheados.
  Future<PreloadStats> preloadHlsSession(
    String sessionId, {
    int maxSegments = 22,
    int maxBytes = 16 * 1024 * 1024,
    bool Function()? isCancelled,
    void Function(int done, int target, int bytes)? onProgress,
  }) async {
    final session = _sessions[sessionId];
    if (session == null || session.isMp4) {
      return const PreloadStats(segmentsCached: 0, bytesCached: 0);
    }

    // 1. Resolver master -> media playlist y reescribir segmentos
    final masterResult = await _fetchAndRewritePlaylist(
      session,
      session.upstreamMasterUrl,
    );
    if (masterResult == null || (isCancelled?.call() ?? false)) {
      return const PreloadStats(segmentsCached: 0, bytesCached: 0);
    }
    session.rewrittenMaster = masterResult.rewrittenBody;

    // Si es un master con variantes, precargar la mejor variante (primera o mayor ancho de banda)
    if (masterResult.variantIndices.isNotEmpty) {
      final bestVarIdx = masterResult.preferredVariantIndex ??
          masterResult.variantIndices.first;
      final varUrl = session.subPlaylists[bestVarIdx];
      if (varUrl != null && !(isCancelled?.call() ?? false)) {
        final mediaRes = await _fetchAndRewritePlaylist(session, varUrl);
        if (mediaRes != null) {
          session.rewrittenSubPlaylists[bestVarIdx] = mediaRes.rewrittenBody;
          session.activeMediaSegmentIndices = mediaRes.segmentIndices;
        }
      }
    } else {
      session.activeMediaSegmentIndices = masterResult.segmentIndices;
    }

    final segIndices = session.activeMediaSegmentIndices;
    if (segIndices.isEmpty) {
      return const PreloadStats(segmentsCached: 0, bytesCached: 0);
    }

    // Precargar claves AES-128 si el playlist está cifrado
    for (final keyIdx in session.keys.keys.toList()) {
      if (isCancelled?.call() ?? false) break;
      await _fetchKeyBytes(session, keyIdx);
    }

    final targetCount =
        segIndices.length < maxSegments ? segIndices.length : maxSegments;
    var cachedCount = 0;
    var cachedBytes = 0;

    // Descarga en lotes paralelos de 3 segmentos para calentar 2-3 min rápido
    const batchSize = 3;
    for (var i = 0; i < targetCount; i += batchSize) {
      if (isCancelled?.call() ?? false) break;
      if (cachedBytes >= maxBytes) break;

      final end = (i + batchSize < targetCount) ? i + batchSize : targetCount;
      final batch = segIndices.sublist(i, end);

      final results = await Future.wait(
        batch.map((segIdx) async {
          if (isCancelled?.call() ?? false) return null;
          return _fetchSegmentBytes(session, segIdx, storeInCache: true);
        }),
      );

      for (final bytes in results) {
        if (bytes != null && bytes.isNotEmpty) {
          cachedCount++;
          cachedBytes += bytes.length;
        }
      }
      onProgress?.call(cachedCount, targetCount, cachedBytes);
      _enforceGlobalByteBudget(protectedSessionId: sessionId);
    }

    return PreloadStats(
      segmentsCached: cachedCount,
      bytesCached: cachedBytes,
    );
  }

  /// Precarga los primeros [maxBytes] (por defecto 10 MB) de un MP4 directo.
  Future<PreloadStats> preloadMp4Session(
    String sessionId, {
    int maxBytes = 10 * 1024 * 1024,
    bool Function()? isCancelled,
    void Function(int done, int target, int bytes)? onProgress,
  }) async {
    final session = _sessions[sessionId];
    if (session == null || !session.isMp4) {
      return const PreloadStats(segmentsCached: 0, bytesCached: 0);
    }

    try {
      final uri = Uri.parse(session.upstreamMasterUrl);
      final req = await _httpClient.getUrl(uri).timeout(_upstreamTimeout);
      _applyUpstreamHeaders(req, session.headers);
      req.headers.set('Range', 'bytes=0-${maxBytes - 1}');

      final res = await req.close().timeout(_upstreamTimeout);
      if (res.statusCode < 200 || res.statusCode >= 300) {
        return const PreloadStats(segmentsCached: 0, bytesCached: 0);
      }

      final contentRange = res.headers.value(HttpHeaders.contentRangeHeader);
      if (contentRange != null) {
        final m = RegExp(r'/(\d+)$').firstMatch(contentRange);
        if (m != null) {
          session.mp4TotalLength = int.tryParse(m.group(1)!);
        }
      }
      session.mp4TotalLength ??=
          res.contentLength > 0 ? res.contentLength : null;
      session.mp4ContentType = res.headers.contentType?.mimeType ?? 'video/mp4';

      final builder = BytesBuilder(copy: false);
      var lastReported = 0;
      await for (final chunk in res) {
        if (isCancelled?.call() ?? false) break;
        final remaining = maxBytes - builder.length;
        if (remaining <= 0) break;
        if (chunk.length <= remaining) {
          builder.add(chunk);
        } else {
          builder.add(chunk.sublist(0, remaining));
          break;
        }
        if (builder.length - lastReported >= 512 * 1024) {
          lastReported = builder.length;
          onProgress?.call(
            (builder.length / (1024 * 1024)).round(),
            (maxBytes / (1024 * 1024)).round(),
            builder.length,
          );
        }
      }

      if (isCancelled?.call() ?? false) {
        return const PreloadStats(segmentsCached: 0, bytesCached: 0);
      }

      final data = builder.takeBytes();
      if (data.isEmpty || !StreamValidator.isPlayableMediaBytes(data)) {
        return const PreloadStats(segmentsCached: 0, bytesCached: 0);
      }

      session.mp4PrefixBytes = data;
      _enforceGlobalByteBudget(protectedSessionId: sessionId);
      onProgress?.call(1, 1, data.length);
      return PreloadStats(segmentsCached: 1, bytesCached: data.length);
    } catch (e) {
      debugPrint('[HlsStreamProxy] MP4 preload err: $e');
      return const PreloadStats(segmentsCached: 0, bytesCached: 0);
    }
  }

  /// Registra una sesión de reproducción OFFLINE cifrada (Bóveda AES-256-CTR)
  /// para HLS o MP4. Descifra al vuelo en RAM sin escribir jamás un solo byte
  /// descifrado en disco.
  Future<VaultProxyRegistration> registerVaultSession({
    required Directory vaultDir,
    required Uint8List key32,
    required Uint8List nonce16,
    required bool isMp4,
    int subtitleCount = 0,
  }) async {
    await ensureStarted();
    final id = 'v${++_nextSessionSeq}_${DateTime.now().millisecondsSinceEpoch}';
    _vaultSessions[id] = _VaultPlaybackSession(
      id: id,
      vaultDir: vaultDir,
      key32: key32,
      nonce16: nonce16,
      isMp4: isMp4,
    );

    final subUrls = [
      for (var i = 0; i < subtitleCount; i++)
        'http://127.0.0.1:$_port/v/$id/sub/$i.vtt',
    ];
    return VaultProxyRegistration(
      sessionId: id,
      localUrl: isMp4
          ? 'http://127.0.0.1:$_port/v/$id/video.mp4'
          : 'http://127.0.0.1:$_port/v/$id/master.m3u8',
      isMp4: isMp4,
      subtitleUrls: subUrls,
    );
  }

  /// Libera una sesión específica y su caché en RAM.
  void releaseSession(String? sessionId) {
    if (sessionId == null || sessionId.isEmpty) return;
    _sessions.remove(sessionId)?.clearCache();
    _vaultSessions.remove(sessionId)?.clearCache();
  }

  /// Libera todas las sesiones excepto [keepSessionId].
  void releaseAllExcept(String? keepSessionId) {
    final toRemove = _sessions.keys
        .where((id) => id != keepSessionId)
        .toList(growable: false);
    for (final id in toRemove) {
      _sessions.remove(id)?.clearCache();
    }
    final vaultToRemove = _vaultSessions.keys
        .where((id) => id != keepSessionId)
        .toList(growable: false);
    for (final id in vaultToRemove) {
      _vaultSessions.remove(id)?.clearCache();
    }
  }

  /// Detiene el servidor local (solo en shutdown/pruebas).
  Future<void> close() async {
    for (final s in _sessions.values) {
      s.clearCache();
    }
    for (final v in _vaultSessions.values) {
      v.clearCache();
    }
    _sessions.clear();
    _vaultSessions.clear();
    _sharedHttpClient?.close(force: true);
    _sharedHttpClient = null;
    final srv = _server;
    _server = null;
    _port = 0;
    await srv?.close(force: true);
  }

  /// Recorta cualquier cabecera disfrazada (PNG, JPEG, GIF, WebP, texto basura)
  /// antepuesta a un segmento MPEG-TS real (`0x47 ... 188B ... 0x47`).
  /// Si ya inicia en `0x47` o es fMP4/ID3/AES-128 válido, se devuelve intacto.
  static Uint8List stripDisguisedHeader(Uint8List bytes) {
    if (bytes.length < 16) return bytes;

    // Ya inicia en sync byte MPEG-TS
    if (bytes[0] == 0x47) return bytes;

    // fMP4 (ftyp / moof / styp) o ID3 al inicio -> no tocar
    if (bytes[0] == 0x49 && bytes[1] == 0x44 && bytes[2] == 0x33) return bytes;
    if (bytes.length >= 8) {
      final box = String.fromCharCodes(bytes.sublist(4, 8));
      if (box == 'ftyp' || box == 'moof' || box == 'styp' || box == 'free') {
        return bytes;
      }
    }

    // Cabecera de imagen disfrazada (PNG, JPEG, GIF, BMP, WebP)
    final isDisguisedImage = (bytes[0] == 0x89 &&
            bytes[1] == 0x50 &&
            bytes[2] == 0x4E &&
            bytes[3] == 0x47) ||
        (bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) ||
        (bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46) ||
        (bytes[0] == 0x42 && bytes[1] == 0x4D) ||
        (bytes[0] == 0x52 &&
            bytes[1] == 0x49 &&
            bytes[2] == 0x46 &&
            bytes[3] == 0x46);

    if (isDisguisedImage) {
      final tsOff = StreamValidator.findMpegTsSyncOffset(bytes);
      if (tsOff > 0) {
        return Uint8List.sublistView(bytes, tsOff);
      }
    }

    return bytes;
  }

  // ── Enrutamiento HTTP local ────────────────────────────────────────────────

  Future<void> _handleRequest(HttpRequest req) async {
    try {
      final segs = req.uri.pathSegments;
      if (segs.length < 3) {
        req.response
          ..statusCode = HttpStatus.notFound
          ..close();
        return;
      }

      final kind =
          segs[0]; // 's' (HLS), 'm' (MP4) o 'v' (Bóveda Offline cifrada)
      final sessionId = segs[1];

      if (kind == 'v') {
        final vs = _vaultSessions[sessionId];
        if (vs == null) {
          req.response
            ..statusCode = HttpStatus.notFound
            ..close();
          return;
        }
        await _handleVaultRequest(req, vs, segs);
        return;
      }

      final session = _sessions[sessionId];
      if (session == null) {
        req.response
          ..statusCode = HttpStatus.notFound
          ..close();
        return;
      }
      session.lastAccessedAt = DateTime.now();

      if (kind == 'm' && session.isMp4) {
        await _serveMp4(req, session);
        return;
      }

      if (kind == 's' && !session.isMp4) {
        final action = segs[2];
        if (action == 'master.m3u8') {
          await _serveMasterPlaylist(req, session);
          return;
        }
        if (action == 'pl' && segs.length >= 4) {
          final idx = int.tryParse(segs[3].replaceAll('.m3u8', ''));
          if (idx != null) {
            await _serveSubPlaylist(req, session, idx);
            return;
          }
        }
        if (action == 'seg' && segs.length >= 4) {
          final idx = int.tryParse(segs[3].replaceAll('.ts', ''));
          if (idx != null) {
            await _serveSegment(req, session, idx);
            return;
          }
        }
        if (action == 'key' && segs.length >= 4) {
          final idx = int.tryParse(segs[3].replaceAll('.bin', ''));
          if (idx != null) {
            await _serveKey(req, session, idx);
            return;
          }
        }
      }

      req.response
        ..statusCode = HttpStatus.notFound
        ..close();
    } catch (e) {
      debugPrint('[HlsStreamProxy] Request err: $e');
      try {
        req.response.statusCode = HttpStatus.badGateway;
        await req.response.close();
      } catch (_) {}
    }
  }

  Future<_RewrittenPlaylist?> _ensureMasterPlaylist(_ProxySession session) {
    final cached = session.rewrittenMasterResult;
    if (cached != null) return Future.value(cached);
    final running = session.inFlightMaster;
    if (running != null) return running;

    final future = () async {
      try {
        final fetched = await _fetchAndRewritePlaylist(
          session,
          session.upstreamMasterUrl,
        );
        if (fetched != null) {
          session.rewrittenMaster = fetched.rewrittenBody;
          session.rewrittenMasterResult = fetched;
          if (fetched.segmentIndices.isNotEmpty) {
            session.activeMediaSegmentIndices = fetched.segmentIndices;
          }
        }
        return fetched;
      } finally {
        session.inFlightMaster = null;
      }
    }();
    session.inFlightMaster = future;
    return future;
  }

  Future<_RewrittenPlaylist?> _ensureSubPlaylist(
    _ProxySession session,
    int idx,
  ) {
    final cached = session.rewrittenSubPlaylistResults[idx];
    if (cached != null) return Future.value(cached);
    final running = session.inFlightSubPlaylists[idx];
    if (running != null) return running;
    final upstream = session.subPlaylists[idx];
    if (upstream == null) return Future.value(null);

    final future = () async {
      try {
        final fetched = await _fetchAndRewritePlaylist(session, upstream);
        if (fetched != null) {
          session.rewrittenSubPlaylists[idx] = fetched.rewrittenBody;
          session.rewrittenSubPlaylistResults[idx] = fetched;
          if (fetched.segmentIndices.isNotEmpty) {
            session.activeMediaSegmentIndices = fetched.segmentIndices;
          }
        }
        return fetched;
      } finally {
        session.inFlightSubPlaylists.remove(idx);
      }
    }();
    session.inFlightSubPlaylists[idx] = future;
    return future;
  }

  Future<void> _serveMasterPlaylist(
    HttpRequest req,
    _ProxySession session,
  ) async {
    var body = session.rewrittenMaster;
    if (body == null) {
      final fetched = await _ensureMasterPlaylist(session);
      if (fetched == null) {
        req.response.statusCode = HttpStatus.badGateway;
        await req.response.close();
        return;
      }
      body = fetched.rewrittenBody;
      if (fetched.variantIndices.isNotEmpty) {
        // Adelantar sub-playlist y primeros 2 segmentos mientras libmpv parsea el master
        final bestVarIdx =
            fetched.preferredVariantIndex ?? fetched.variantIndices.first;
        unawaited(_ensureSubPlaylist(session, bestVarIdx).then((sub) {
          if (sub != null &&
              sub.segmentIndices.isNotEmpty &&
              _sessions.containsKey(session.id)) {
            _triggerLookahead(session, sub.segmentIndices.first - 1,
                maxAhead: 2);
          }
        }));
      } else if (fetched.segmentIndices.isNotEmpty) {
        _triggerLookahead(session, fetched.segmentIndices.first - 1,
            maxAhead: 2);
      }
    }

    final bytes = utf8.encode(body);
    req.response.statusCode = HttpStatus.ok;
    req.response.headers.set(
      HttpHeaders.contentTypeHeader,
      'application/vnd.apple.mpegurl',
    );
    req.response.headers.set(HttpHeaders.contentLengthHeader, bytes.length);
    req.response.add(bytes);
    await req.response.close();
  }

  Future<void> _serveSubPlaylist(
    HttpRequest req,
    _ProxySession session,
    int idx,
  ) async {
    var body = session.rewrittenSubPlaylists[idx];
    if (body == null) {
      final upstream = session.subPlaylists[idx];
      if (upstream == null) {
        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
        return;
      }
      final fetched = await _ensureSubPlaylist(session, idx);
      if (fetched == null) {
        req.response.statusCode = HttpStatus.badGateway;
        await req.response.close();
        return;
      }
      body = fetched.rewrittenBody;
      if (fetched.segmentIndices.isNotEmpty) {
        // Comenzar a descargar los primeros 2 segmentos en paralelo mientras libmpv parsea
        _triggerLookahead(session, fetched.segmentIndices.first - 1,
            maxAhead: 2);
      }
    }

    final bytes = utf8.encode(body);
    req.response.statusCode = HttpStatus.ok;
    req.response.headers.set(
      HttpHeaders.contentTypeHeader,
      'application/vnd.apple.mpegurl',
    );
    req.response.headers.set(HttpHeaders.contentLengthHeader, bytes.length);
    req.response.add(bytes);
    await req.response.close();
  }

  Future<void> _serveSegment(
    HttpRequest req,
    _ProxySession session,
    int idx,
  ) async {
    // Disparar lookahead INMEDIATAMENTE antes de esperar el segmento actual:
    // así N+1..N+ahead se descargan en paralelo con N (cero cascada secuencial).
    _triggerLookahead(session, idx);

    // 1. Respuesta instantánea desde memoria si ya fue precargado (<5ms!)
    var bytes = session.cachedSegments[idx];
    if (bytes == null) {
      bytes = await _fetchSegmentBytes(session, idx, storeInCache: false);
    } else {
      // Ventana deslizante compacta en Smart TV (2 GB RAM): libera segmentos ya
      // entregados para evitar presión de GC y swap, manteniendo 2 atrás para -10s.
      final maxKeep = TvModeService.instance.isTv ? 6 : 24;
      final behindKeep = TvModeService.instance.isTv ? 2 : 4;
      while (session.cachedSegments.length > maxKeep) {
        final oldest = session.cachedSegments.keys.first;
        if (oldest < idx - behindKeep) {
          session.removeCachedSegment(oldest);
        } else {
          break;
        }
      }
    }

    if (bytes == null || bytes.isEmpty) {
      req.response.statusCode = HttpStatus.badGateway;
      await req.response.close();
      return;
    }

    req.response.statusCode = HttpStatus.ok;
    req.response.headers.set(HttpHeaders.contentTypeHeader, 'video/mp2t');
    req.response.headers.set(HttpHeaders.contentLengthHeader, bytes.length);
    req.response.add(bytes);
    await req.response.close();
  }

  void _triggerLookahead(_ProxySession session, int currentIdx,
      {int? maxAhead}) {
    final isTv = TvModeService.instance.isTv;
    var ahead = maxAhead ?? adaptiveLookaheadForThroughput(_ewmaBytesPerSec);
    if (isTv && ahead > 2) ahead = 2;
    final maxSessionBytes = isTv ? 14 * 1024 * 1024 : 28 * 1024 * 1024;
    for (var offset = 1; offset <= ahead; offset++) {
      final nextIdx = currentIdx + offset;
      if (!session.segments.containsKey(nextIdx)) continue;
      if (session.cachedSegments.containsKey(nextIdx)) continue;
      if (session.inFlightSegments.containsKey(nextIdx)) continue;
      if (session.totalCachedBytes > maxSessionBytes) break;
      unawaited(_fetchSegmentBytes(session, nextIdx, storeInCache: true));
    }
  }

  Future<void> _serveKey(
    HttpRequest req,
    _ProxySession session,
    int idx,
  ) async {
    final bytes = await _fetchKeyBytes(session, idx);
    if (bytes == null) {
      req.response.statusCode = HttpStatus.badGateway;
      await req.response.close();
      return;
    }
    req.response.statusCode = HttpStatus.ok;
    req.response.headers.set(
      HttpHeaders.contentTypeHeader,
      'application/octet-stream',
    );
    req.response.headers.set(HttpHeaders.contentLengthHeader, bytes.length);
    req.response.add(bytes);
    await req.response.close();
  }

  Future<void> _serveMp4(HttpRequest req, _ProxySession session) async {
    final prefix = session.mp4PrefixBytes;
    final rangeHeader = req.headers.value(HttpHeaders.rangeHeader);

    // Si tenemos el prefijo precargado y el rango cabe en memoria -> 0 ms!
    if (prefix != null && prefix.isNotEmpty) {
      var start = 0;
      int? requestedEnd;
      if (rangeHeader != null && rangeHeader.startsWith('bytes=')) {
        final spec = rangeHeader.substring('bytes='.length).split(',').first;
        final parts = spec.split('-');
        start = int.tryParse(parts[0].trim()) ?? 0;
        if (parts.length > 1 && parts[1].trim().isNotEmpty) {
          requestedEnd = int.tryParse(parts[1].trim());
        }
      }

      if (start < prefix.length) {
        final totalLen = session.mp4TotalLength;
        final availableEnd = prefix.length - 1;
        final end = requestedEnd != null
            ? (requestedEnd < availableEnd ? requestedEnd : availableEnd)
            : availableEnd;

        if (end >= start) {
          final slice = Uint8List.sublistView(prefix, start, end + 1);
          req.response.statusCode = HttpStatus.partialContent;
          req.response.headers
              .set(HttpHeaders.contentTypeHeader, session.mp4ContentType);
          req.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
          req.response.headers
              .set(HttpHeaders.contentLengthHeader, slice.length);
          req.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes $start-$end/${totalLen ?? "*"}',
          );
          req.response.add(slice);
          await req.response.close();
          return;
        }
      }
    }

    // Fuera del prefijo precargado: proxy streaming directo con pool Keep-Alive
    try {
      final upReq = await _httpClient
          .getUrl(Uri.parse(session.upstreamMasterUrl))
          .timeout(_upstreamTimeout);
      _applyUpstreamHeaders(upReq, session.headers);
      if (rangeHeader != null) {
        upReq.headers.set(HttpHeaders.rangeHeader, rangeHeader);
      }
      final upRes = await upReq.close().timeout(_upstreamTimeout);

      req.response.statusCode = upRes.statusCode;
      final ct = upRes.headers.value(HttpHeaders.contentTypeHeader);
      if (ct != null) {
        req.response.headers.set(HttpHeaders.contentTypeHeader, ct);
      }
      final cr = upRes.headers.value(HttpHeaders.contentRangeHeader);
      if (cr != null) {
        req.response.headers.set(HttpHeaders.contentRangeHeader, cr);
      }
      final ar = upRes.headers.value(HttpHeaders.acceptRangesHeader);
      if (ar != null) {
        req.response.headers.set(HttpHeaders.acceptRangesHeader, ar);
      }
      if (upRes.contentLength >= 0) {
        req.response.headers
            .set(HttpHeaders.contentLengthHeader, upRes.contentLength);
      }
      await req.response.addStream(upRes);
      await req.response.close();
    } catch (_) {
      try {
        await req.response.close();
      } catch (_) {}
    }
  }

  // ── Reproducción OFFLINE cifrada desde Bóveda (AES-256-CTR al vuelo) ──────

  static const int vaultManifestNonceIndex = 999999;
  static const int vaultKeyNonceBase = 500000;
  static const int vaultSubNonceBase = 700000;

  Future<void> _handleVaultRequest(
    HttpRequest req,
    _VaultPlaybackSession vs,
    List<String> segs,
  ) async {
    final action = segs[2];

    if (action == 'video.mp4' && vs.isMp4) {
      final file = File('${vs.vaultDir.path}/media.ivlt');
      if (!await file.exists()) {
        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
        return;
      }
      final totalLen = await file.length();
      var start = 0;
      var end = totalLen - 1;
      var isRange = false;
      final rangeHeader = req.headers.value(HttpHeaders.rangeHeader);
      if (rangeHeader != null && rangeHeader.startsWith('bytes=')) {
        isRange = true;
        final spec = rangeHeader.substring(6).split(',').first.trim();
        final parts = spec.split('-');
        start = int.tryParse(parts[0].trim()) ?? 0;
        if (parts.length > 1 && parts[1].trim().isNotEmpty) {
          end = int.tryParse(parts[1].trim()) ?? (totalLen - 1);
        }
        start = start.clamp(0, totalLen > 0 ? totalLen - 1 : 0);
        end = end.clamp(start, totalLen > 0 ? totalLen - 1 : 0);
      }

      final length = totalLen == 0 ? 0 : (end - start + 1);
      req.response.statusCode =
          isRange ? HttpStatus.partialContent : HttpStatus.ok;
      req.response.headers.set(HttpHeaders.contentTypeHeader, 'video/mp4');
      req.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      req.response.headers.set(HttpHeaders.contentLengthHeader, length);
      if (isRange) {
        req.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-$end/$totalLen',
        );
      }

      final raf = await file.open(mode: FileMode.read);
      try {
        await raf.setPosition(start);
        var offset = start;
        var remaining = length;
        const chunkSize =
            256 * 1024; // 256 KB en Isolate trabajador + backpressure
        while (remaining > 0) {
          final toRead = remaining < chunkSize ? remaining : chunkSize;
          final encrypted = await raf.read(toRead);
          if (encrypted.isEmpty) break;
          final plain = await VaultCrypto.transformOffMainThread(
            encrypted,
            key32: vs.key32,
            nonce16: vs.nonce16,
            byteOffset: offset,
          );
          req.response.add(plain);
          // Backpressure TCP real: si libmpv cierra o hace seek, salimos al instante
          // sin acumular cientos de MB en RAM ni provocar pausas de GC.
          await req.response.flush();
          offset += encrypted.length;
          remaining -= encrypted.length;
        }
      } catch (_) {
        // Cliente cerró la conexión anticipadamente (p. ej. al hacer seek/salir)
      } finally {
        await raf.close();
      }
      try {
        await req.response.close();
      } catch (_) {}
      return;
    }

    if (action == 'master.m3u8' && !vs.isMp4) {
      final file = File('${vs.vaultDir.path}/manifest.ivlt');
      if (!await file.exists()) {
        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
        return;
      }
      final enc = await file.readAsBytes();
      final plainBytes = await VaultCrypto.transformOffMainThread(
        enc,
        key32: vs.key32,
        nonce16: VaultCrypto.deriveSegmentNonce(
          vs.nonce16,
          vaultManifestNonceIndex,
        ),
      );
      final base = 'http://127.0.0.1:$_port/v/${vs.id}';
      final playlist = utf8
          .decode(plainBytes, allowMalformed: true)
          .replaceAll('{{BASE}}', base);
      final outBytes = utf8.encode(playlist);
      // Pre-descifrar los primeros 2 segmentos en segundo plano para arranque 0 ms
      _triggerVaultLookahead(vs, -1);
      req.response.statusCode = HttpStatus.ok;
      req.response.headers.set(
        HttpHeaders.contentTypeHeader,
        'application/vnd.apple.mpegurl',
      );
      req.response.headers
          .set(HttpHeaders.contentLengthHeader, outBytes.length);
      req.response.add(outBytes);
      await req.response.close();
      return;
    }

    if (action == 'seg' && segs.length >= 4 && !vs.isMp4) {
      final idx = int.tryParse(segs[3].replaceAll('.ts', ''));
      if (idx == null) {
        req.response.statusCode = HttpStatus.badRequest;
        await req.response.close();
        return;
      }
      final plain = await _loadVaultSegment(vs, idx);
      if (plain == null) {
        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
        return;
      }
      // Purgar segmentos ya reproducidos y pre-descifrar +2 en el Isolate trabajador
      vs.pruneOldSegments(idx);
      _triggerVaultLookahead(vs, idx);

      req.response.statusCode = HttpStatus.ok;
      req.response.headers.set(HttpHeaders.contentTypeHeader, 'video/mp2t');
      req.response.headers.set(HttpHeaders.contentLengthHeader, plain.length);
      req.response.add(plain);
      await req.response.close();
      return;
    }

    if (action == 'key' && segs.length >= 4) {
      final idx = int.tryParse(segs[3].replaceAll('.bin', ''));
      if (idx == null) {
        req.response.statusCode = HttpStatus.badRequest;
        await req.response.close();
        return;
      }
      final file = File('${vs.vaultDir.path}/key_$idx.ivlt');
      if (!await file.exists()) {
        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
        return;
      }
      final enc = await file.readAsBytes();
      final plain = VaultCrypto.transformAtOffset(
        enc,
        key32: vs.key32,
        nonce16: VaultCrypto.deriveSegmentNonce(
          vs.nonce16,
          vaultKeyNonceBase + idx,
        ),
      );
      req.response.statusCode = HttpStatus.ok;
      req.response.headers.set(
        HttpHeaders.contentTypeHeader,
        'application/octet-stream',
      );
      req.response.headers.set(HttpHeaders.contentLengthHeader, plain.length);
      req.response.add(plain);
      await req.response.close();
      return;
    }

    if (action == 'sub' && segs.length >= 4) {
      final idx = int.tryParse(segs[3].replaceAll('.vtt', ''));
      if (idx == null) {
        req.response.statusCode = HttpStatus.badRequest;
        await req.response.close();
        return;
      }
      final file = File('${vs.vaultDir.path}/sub_$idx.ivlt');
      if (!await file.exists()) {
        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
        return;
      }
      final enc = await file.readAsBytes();
      final plain = VaultCrypto.transformAtOffset(
        enc,
        key32: vs.key32,
        nonce16: VaultCrypto.deriveSegmentNonce(
          vs.nonce16,
          vaultSubNonceBase + idx,
        ),
      );
      req.response.statusCode = HttpStatus.ok;
      req.response.headers.set(
        HttpHeaders.contentTypeHeader,
        'text/vtt; charset=utf-8',
      );
      req.response.headers.set(HttpHeaders.contentLengthHeader, plain.length);
      req.response.add(plain);
      await req.response.close();
      return;
    }

    req.response.statusCode = HttpStatus.notFound;
    await req.response.close();
  }

  Future<Uint8List?> _loadVaultSegment(
      _VaultPlaybackSession vs, int idx) async {
    final cached = vs.decryptedSegments[idx];
    if (cached != null) return cached;
    final running = vs.inFlight[idx];
    if (running != null) return running;

    final future = () async {
      try {
        final name = 'seg_${idx.toString().padLeft(5, '0')}.ivlt';
        final file = File('${vs.vaultDir.path}/$name');
        if (!await file.exists()) return null;
        final enc = await file.readAsBytes();
        final plain = await VaultCrypto.transformOffMainThread(
          enc,
          key32: vs.key32,
          nonce16: VaultCrypto.deriveSegmentNonce(vs.nonce16, idx),
        );
        return plain;
      } catch (_) {
        return null;
      } finally {
        vs.inFlight.remove(idx);
      }
    }();
    vs.inFlight[idx] = future;
    return future;
  }

  void _triggerVaultLookahead(_VaultPlaybackSession vs, int currentIdx) {
    for (var offset = 1; offset <= 2; offset++) {
      final nextIdx = currentIdx + offset;
      if (nextIdx < 0) continue;
      if (vs.decryptedSegments.containsKey(nextIdx)) continue;
      if (vs.inFlight.containsKey(nextIdx)) continue;
      if (vs.decryptedSegments.length >= 3) break;
      unawaited(
        _loadVaultSegment(vs, nextIdx).then((bytes) {
          if (bytes != null && _vaultSessions.containsKey(vs.id)) {
            vs.decryptedSegments[nextIdx] = bytes;
          }
        }),
      );
    }
  }

  // ── Descarga y reescritura de playlists / segmentos ────────────────────────

  Future<_RewrittenPlaylist?> _fetchAndRewritePlaylist(
    _ProxySession session,
    String upstreamUrl,
  ) async {
    final uri = Uri.parse(upstreamUrl);
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        final req = await _httpClient.getUrl(uri).timeout(_connectTimeout);
        _applyUpstreamHeaders(req, session.headers);
        final res = await req.close().timeout(_upstreamTimeout);
        if (res.statusCode < 200 || res.statusCode >= 300) {
          await res.drain<void>().catchError((_) {});
          if (attempt < 2) {
            await Future<void>.delayed(
              Duration(milliseconds: attempt == 0 ? 250 : 750),
            );
          }
          continue;
        }

        var resolvedBase = uri;
        for (final r in res.redirects) {
          resolvedBase = resolvedBase.resolveUri(r.location);
        }

        final rawBytes = await _readAllBytes(res).timeout(_upstreamTimeout);
        final text = utf8.decode(rawBytes, allowMalformed: true);
        if (!text.contains('#EXTM3U')) {
          if (attempt < 2) {
            await Future<void>.delayed(
              Duration(milliseconds: attempt == 0 ? 250 : 750),
            );
          }
          continue;
        }

        final lines = text.split(RegExp(r'\r?\n'));
        final out = StringBuffer();
        final variantIndices = <int>[];
        final segmentIndices = <int>[];
        var lastLineWasStreamInf = false;
        var lastBandwidth = 0;
        var bestBandwidth = -1;
        int? preferredVariantIdx;
        final preferLowBitrate =
            _ewmaBytesPerSec > 0 && _ewmaBytesPerSec < 350 * 1024;
        var bestSlowBandwidth = 1 << 30;

        for (final rawLine in lines) {
          final line = rawLine.trim();
          if (line.isEmpty) continue;

          if (line.startsWith('#')) {
            if (line.startsWith('#EXT-X-STREAM-INF')) {
              lastLineWasStreamInf = true;
              final bwMatch = RegExp(r'BANDWIDTH=(\d+)').firstMatch(line);
              lastBandwidth = int.tryParse(bwMatch?.group(1) ?? '') ?? 0;
              out.writeln(line);
            } else if (line.startsWith('#EXT-X-KEY') ||
                line.startsWith('#EXT-X-MAP') ||
                line.startsWith('#EXT-X-MEDIA')) {
              // Reescribir URI="..." hacia /key/ o /pl/ local
              final rewrittenTag = line.replaceAllMapped(
                RegExp(r'URI="([^"]+)"'),
                (m) {
                  final abs = resolvedBase.resolve(m.group(1)!).toString();
                  if (line.startsWith('#EXT-X-MEDIA') &&
                      abs.toLowerCase().contains('.m3u8')) {
                    final plIdx = session.registerSubPlaylist(abs);
                    return 'URI="http://127.0.0.1:$_port/s/${session.id}/pl/$plIdx.m3u8"';
                  }
                  final keyIdx = session.registerKey(abs);
                  return 'URI="http://127.0.0.1:$_port/s/${session.id}/key/$keyIdx.bin"';
                },
              );
              out.writeln(rewrittenTag);
            } else {
              out.writeln(line);
            }
            continue;
          }

          final absUrl = resolvedBase.resolve(line).toString();
          final looksLikePlaylist = lastLineWasStreamInf ||
              absUrl.toLowerCase().contains('.m3u8') ||
              absUrl.toLowerCase().contains('chunklist') ||
              absUrl.toLowerCase().contains('index-');

          if (looksLikePlaylist) {
            final plIdx = session.registerSubPlaylist(absUrl);
            variantIndices.add(plIdx);
            if (preferLowBitrate && lastBandwidth > 0) {
              if (lastBandwidth < bestSlowBandwidth) {
                bestSlowBandwidth = lastBandwidth;
                preferredVariantIdx = plIdx;
              }
            } else if (lastBandwidth >= bestBandwidth) {
              bestBandwidth = lastBandwidth;
              preferredVariantIdx = plIdx;
            }
            out.writeln(
                'http://127.0.0.1:$_port/s/${session.id}/pl/$plIdx.m3u8');
          } else {
            final segIdx = session.registerSegment(absUrl);
            segmentIndices.add(segIdx);
            out.writeln(
                'http://127.0.0.1:$_port/s/${session.id}/seg/$segIdx.ts');
          }
          lastLineWasStreamInf = false;
          lastBandwidth = 0;
        }

        return _RewrittenPlaylist(
          rewrittenBody: out.toString(),
          variantIndices: variantIndices,
          preferredVariantIndex: preferredVariantIdx,
          segmentIndices: segmentIndices,
        );
      } catch (e) {
        debugPrint(
            '[HlsStreamProxy] Playlist fetch err (intento ${attempt + 1}): $e');
        if (attempt < 2) {
          await Future<void>.delayed(
            Duration(milliseconds: attempt == 0 ? 250 : 750),
          );
        }
      }
    }
    return null;
  }

  Future<Uint8List?> _fetchSegmentBytes(
    _ProxySession session,
    int segIdx, {
    required bool storeInCache,
  }) async {
    final existing = session.cachedSegments[segIdx];
    if (existing != null) return existing;

    final inFlight = session.inFlightSegments[segIdx];
    if (inFlight != null) return inFlight;

    final upstream = session.segments[segIdx];
    if (upstream == null) return null;

    final future = () async {
      try {
        for (var attempt = 0; attempt < 2; attempt++) {
          try {
            final sw = Stopwatch()..start();
            final req = await _httpClient
                .getUrl(Uri.parse(upstream))
                .timeout(_connectTimeout);
            _applyUpstreamHeaders(req, session.headers);
            final res = await req.close().timeout(_upstreamTimeout);
            if (res.statusCode < 200 || res.statusCode >= 300) {
              await res.drain<void>().catchError((_) {});
              if (attempt == 0) {
                await Future<void>.delayed(const Duration(milliseconds: 220));
              }
              continue;
            }

            final raw = await _readAllBytes(res).timeout(_upstreamTimeout);
            sw.stop();
            if (raw.isEmpty) continue;
            _recordThroughput(raw.length, sw.elapsedMilliseconds);
            StreamHostHealth.instance.recordThroughput(
              upstream,
              bytes: raw.length,
              elapsedMs: sw.elapsedMilliseconds,
            );

            final clean = stripDisguisedHeader(raw);
            if (storeInCache) {
              session.putCachedSegment(segIdx, clean);
            }
            return clean;
          } catch (_) {
            StreamHostHealth.instance.recordStallOrTimeout(upstream);
            if (attempt == 0) {
              await Future<void>.delayed(const Duration(milliseconds: 220));
            }
          }
        }
        return null;
      } finally {
        session.inFlightSegments.remove(segIdx);
      }
    }();

    session.inFlightSegments[segIdx] = future;
    return future;
  }

  Future<Uint8List?> _fetchKeyBytes(_ProxySession session, int keyIdx) async {
    final cached = session.cachedKeys[keyIdx];
    if (cached != null) return cached;
    final upstream = session.keys[keyIdx];
    if (upstream == null) return null;

    try {
      final req = await _httpClient
          .getUrl(Uri.parse(upstream))
          .timeout(_upstreamTimeout);
      _applyUpstreamHeaders(req, session.headers);
      final res = await req.close().timeout(_upstreamTimeout);
      if (res.statusCode < 200 || res.statusCode >= 300) {
        await res.drain<void>().catchError((_) {});
        return null;
      }
      final raw = await _readAllBytes(res);
      if (raw.isNotEmpty) session.cachedKeys[keyIdx] = raw;
      return raw;
    } catch (_) {
      return null;
    }
  }

  void _applyUpstreamHeaders(
      HttpClientRequest req, Map<String, String> headers) {
    req.headers.set(
      'User-Agent',
      headers['User-Agent'] ?? StreamValidator.defaultUserAgent,
    );
    headers.forEach((k, v) {
      if (k.toLowerCase() != 'user-agent') {
        req.headers.set(k, v);
      }
    });
  }

  Future<Uint8List> _readAllBytes(HttpClientResponse res) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in res) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  void _evictOldSessionsIfNeeded() {
    while (_sessions.length >= _maxSessions) {
      String? oldestId;
      DateTime? oldestTime;
      for (final e in _sessions.entries) {
        if (oldestTime == null || e.value.lastAccessedAt.isBefore(oldestTime)) {
          oldestTime = e.value.lastAccessedAt;
          oldestId = e.key;
        }
      }
      if (oldestId == null) break;
      _sessions.remove(oldestId)?.clearCache();
    }
  }

  int get _effectiveMaxTotalCacheBytes =>
      TvModeService.instance.isTv ? 28 * 1024 * 1024 : _maxTotalCacheBytes;

  void _enforceGlobalByteBudget({String? protectedSessionId}) {
    var total = 0;
    for (final s in _sessions.values) {
      total += s.totalCachedBytes;
    }
    final limit = _effectiveMaxTotalCacheBytes;
    if (total <= limit) return;

    final ordered = _sessions.values
        .where((s) => s.id != protectedSessionId)
        .toList()
      ..sort((a, b) => a.lastAccessedAt.compareTo(b.lastAccessedAt));

    for (final s in ordered) {
      if (total <= limit) break;
      total -= s.totalCachedBytes;
      s.clearCache();
    }
  }
}

class ProxyRegistration {
  final String sessionId;
  final String localUrl;
  final bool isMp4;

  const ProxyRegistration({
    required this.sessionId,
    required this.localUrl,
    required this.isMp4,
  });
}

class VaultProxyRegistration {
  final String sessionId;
  final String localUrl;
  final bool isMp4;
  final List<String> subtitleUrls;

  const VaultProxyRegistration({
    required this.sessionId,
    required this.localUrl,
    required this.isMp4,
    this.subtitleUrls = const [],
  });
}

class _VaultPlaybackSession {
  final String id;
  final Directory vaultDir;
  final Uint8List key32;
  final Uint8List nonce16;
  final bool isMp4;
  final Map<int, Uint8List> decryptedSegments = {};
  final Map<int, Future<Uint8List?>> inFlight = {};

  _VaultPlaybackSession({
    required this.id,
    required this.vaultDir,
    required this.key32,
    required this.nonce16,
    required this.isMp4,
  });

  void pruneOldSegments(int currentIdx) {
    decryptedSegments.removeWhere((k, _) => k <= currentIdx - 1);
  }

  void clearCache() {
    decryptedSegments.clear();
    inFlight.clear();
  }
}

class PreloadStats {
  final int segmentsCached;
  final int bytesCached;

  const PreloadStats({
    required this.segmentsCached,
    required this.bytesCached,
  });

  bool get hasData => bytesCached > 0 && segmentsCached > 0;
  double get megabytes => bytesCached / (1024 * 1024);
}

class _RewrittenPlaylist {
  final String rewrittenBody;
  final List<int> variantIndices;
  final int? preferredVariantIndex;
  final List<int> segmentIndices;

  const _RewrittenPlaylist({
    required this.rewrittenBody,
    required this.variantIndices,
    required this.preferredVariantIndex,
    required this.segmentIndices,
  });
}

class _ProxySession {
  final String id;
  final bool isMp4;
  final String upstreamMasterUrl;
  final Map<String, String> headers;
  final String tag;
  DateTime lastAccessedAt = DateTime.now();

  String? rewrittenMaster;
  _RewrittenPlaylist? rewrittenMasterResult;
  Future<_RewrittenPlaylist?>? inFlightMaster;
  final Map<int, String> subPlaylists = {};
  final Map<String, int> _subPlaylistToIdx = {};
  final Map<int, String> rewrittenSubPlaylists = {};
  final Map<int, _RewrittenPlaylist> rewrittenSubPlaylistResults = {};
  final Map<int, Future<_RewrittenPlaylist?>> inFlightSubPlaylists = {};

  final Map<int, String> segments = {};
  final Map<String, int> _segmentToIdx = {};
  final Map<int, Uint8List> cachedSegments = {};
  final Map<int, Future<Uint8List?>> inFlightSegments = {};
  List<int> activeMediaSegmentIndices = [];

  final Map<int, String> keys = {};
  final Map<String, int> _keyToIdx = {};
  final Map<int, Uint8List> cachedKeys = {};

  Uint8List? mp4PrefixBytes;
  int? mp4TotalLength;
  String mp4ContentType = 'video/mp4';

  int _cachedBytes = 0;

  _ProxySession({
    required this.id,
    required this.isMp4,
    required this.upstreamMasterUrl,
    required this.headers,
    required this.tag,
  });

  int get totalCachedBytes => _cachedBytes + (mp4PrefixBytes?.length ?? 0);

  int registerSubPlaylist(String url) => _subPlaylistToIdx.putIfAbsent(url, () {
        final idx = subPlaylists.length;
        subPlaylists[idx] = url;
        return idx;
      });

  int registerSegment(String url) => _segmentToIdx.putIfAbsent(url, () {
        final idx = segments.length;
        segments[idx] = url;
        return idx;
      });

  int registerKey(String url) => _keyToIdx.putIfAbsent(url, () {
        final idx = keys.length;
        keys[idx] = url;
        return idx;
      });

  void putCachedSegment(int idx, Uint8List data) {
    final prev = cachedSegments[idx];
    if (prev != null) _cachedBytes -= prev.length;
    cachedSegments[idx] = data;
    _cachedBytes += data.length;
  }

  void removeCachedSegment(int idx) {
    final prev = cachedSegments.remove(idx);
    if (prev != null) _cachedBytes -= prev.length;
  }

  void clearCache() {
    cachedSegments.clear();
    cachedKeys.clear();
    mp4PrefixBytes = null;
    _cachedBytes = 0;
  }
}
