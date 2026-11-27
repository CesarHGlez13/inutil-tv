import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/models.dart';
import 'hls_stream_proxy.dart';
import 'offline_vault_service.dart';
import 'stream_validator.dart';
import 'vod_catalog_service.dart';

/// Paquete ya resuelto y pre-bufferizado en `127.0.0.1` listo para arrancar en <300ms.
class WarmedPlaybackBundle {
  final String key;
  final String sessionId;
  final String localProxyUrl;
  final List<StreamSource> sources;
  final int segmentsCached;
  final int bytesCached;
  final DateTime createdAt;

  const WarmedPlaybackBundle({
    required this.key,
    required this.sessionId,
    required this.localProxyUrl,
    required this.sources,
    required this.segmentsCached,
    required this.bytesCached,
    required this.createdAt,
  });

  bool get isFresh => DateTime.now().difference(createdAt) < const Duration(minutes: 4);
}

/// Precargador especulativo de inicio instantáneo (estilo Netflix / Apple TV).
///
/// Cuando el usuario abre la ficha de una película o serie (`VodDetailModal`),
/// mientras lee el título, sinopsis o selecciona "Reproducir" (2–5 s):
/// 1. Resuelve silenciosamente las fuentes verificadas ordenadas por velocidad real.
/// 2. Registra el mejor servidor en [HlsStreamProxy] (`127.0.0.1`).
/// 3. Pre-descarga los primeros 3 segmentos HLS (~3–5 MB) o primeros 3 MB de MP4.
///
/// Al pulsar "Reproducir":
/// - Si ya terminó: el video arranca en <300 ms desde RAM local.
/// - Si todavía está en curso: `PlayerScreen` se engancha al mismo `Future` en
///   vuelo en lugar de repetir el raspado desde cero.
class VodPlaybackWarmupService {
  VodPlaybackWarmupService._();
  static final VodPlaybackWarmupService instance = VodPlaybackWarmupService._();

  /// Activo por defecto en producción; desactivado automáticamente en `flutter test`
  /// salvo que un test lo habilite explícitamente (`enabled = true`).
  bool? _enabledOverride;
  bool get enabled =>
      _enabledOverride ?? !Platform.environment.containsKey('FLUTTER_TEST');
  set enabled(bool value) => _enabledOverride = value;

  int _generation = 0;
  String _activeKey = '';
  Future<WarmedPlaybackBundle?>? _inFlight;
  WarmedPlaybackBundle? _ready;

  static String keyFor(String itemId, VodEpisode? ep) {
    if (ep == null) return 'm_$itemId';
    return 'e_${itemId}_s${ep.seasonNumber}_e${ep.episodeNumber}';
  }

  /// Inicia el precalentamiento en segundo plano para [item] (y opcionalmente [episode]).
  /// Es idempotente si ya está calentando o listo exactamente el mismo título.
  void warmUp({
    required VodItem item,
    VodEpisode? episode,
  }) {
    if (!enabled) return;
    final key = keyFor(item.id, episode);

    if (_ready != null && _ready!.key == key && _ready!.isFresh) return;
    if (_inFlight != null && _activeKey == key) return;

    // Si ya existe en bóveda offline, ya abre en 0 ms desde disco cifrado
    if (episode == null) {
      if (OfflineVaultService.instance.findCompletedMovie(item.id) != null) {
        return;
      }
    } else {
      if (OfflineVaultService.instance.findCompletedEpisode(
            item.id,
            episode.seasonNumber,
            episode.episodeNumber,
          ) !=
          null) {
        return;
      }
    }

    cancel();
    final gen = ++_generation;
    _activeKey = key;
    bool cancelled() => gen != _generation;

    _inFlight = _runWarmup(
      key: key,
      item: item,
      episode: episode,
      cancelled: cancelled,
    ).whenComplete(() {
      if (gen == _generation) {
        _inFlight = null;
      }
    });
  }

  Future<WarmedPlaybackBundle?> _runWarmup({
    required String key,
    required VodItem item,
    required VodEpisode? episode,
    required bool Function() cancelled,
  }) async {
    try {
      final sources = (episode != null && episode.sources.isNotEmpty)
          ? episode.sources
          : (episode == null && item.sources.isNotEmpty)
              ? item.sources
              : await VodCatalogService().resolveAllPlaybackSources(
                  item,
                  episode,
                );
      if (cancelled() || sources.isEmpty) return null;

      final primary = sources.first;
      final lowerUrl = primary.url.toLowerCase();
      final isHls = StreamValidator.needsLocalHlsProxy(primary.url) ||
          lowerUrl.contains('.m3u8') ||
          lowerUrl.contains('master.txt');
      final reg = isHls
          ? await HlsStreamProxy.instance.registerHlsSession(
              upstreamUrl: primary.url,
              headers: primary.headers,
              tag: 'warm_$key',
            )
          : await HlsStreamProxy.instance.registerMp4Session(
              upstreamUrl: primary.url,
              headers: primary.headers,
              tag: 'warm_$key',
            );

      if (cancelled()) {
        HlsStreamProxy.instance.releaseSession(reg.sessionId);
        return null;
      }

      // Publicar inmediatamente el bundle con el proxy abierto para que si el
      // usuario pulsa Reproducir mientras aún bajan los 3 segmentos, arranque ya.
      final partial = WarmedPlaybackBundle(
        key: key,
        sessionId: reg.sessionId,
        localProxyUrl: reg.localUrl,
        sources: sources,
        segmentsCached: 0,
        bytesCached: 0,
        createdAt: DateTime.now(),
      );
      _ready = partial;

      final stats = isHls
          ? await HlsStreamProxy.instance.preloadHlsSession(
              reg.sessionId,
              maxSegments: 3,
              maxBytes: 5 * 1024 * 1024,
              isCancelled: cancelled,
            )
          : await HlsStreamProxy.instance.preloadMp4Session(
              reg.sessionId,
              maxBytes: 3 * 1024 * 1024,
              isCancelled: cancelled,
            );

      if (cancelled()) {
        // Si ya fue consumido por PlayerScreen, no liberamos su sesión.
        if (_ready?.sessionId == reg.sessionId) {
          HlsStreamProxy.instance.releaseSession(reg.sessionId);
          _ready = null;
        }
        return null;
      }

      final bundle = WarmedPlaybackBundle(
        key: key,
        sessionId: reg.sessionId,
        localProxyUrl: reg.localUrl,
        sources: sources,
        segmentsCached: stats.segmentsCached,
        bytesCached: stats.bytesCached,
        createdAt: DateTime.now(),
      );
      if (_ready?.sessionId == reg.sessionId) {
        _ready = bundle;
      }
      return bundle;
    } catch (e) {
      debugPrint('[VodWarmup] err: $e');
      return null;
    }
  }

  /// Consume el paquete precalentado si coincide con [itemId] + [episode].
  /// Si aún está resolviendo, espera brevemente (hasta [waitIfInFlight]) para
  /// reutilizar el trabajo en curso y evitar duplicar raspado.
  Future<WarmedPlaybackBundle?> consumeOrAttach(
    String itemId, {
    VodEpisode? episode,
    Duration waitIfInFlight = const Duration(seconds: 5),
  }) async {
    final key = keyFor(itemId, episode);

    // 1. Ya listo (total o con proxy ya abierto y segmentos descargándose en RAM)
    final ready = _ready;
    if (ready != null && ready.key == key && ready.isFresh) {
      _ready = null;
      _activeKey = '';
      // Incrementamos generación sin liberar la sesión: el reproductor pasa a ser dueño
      _generation++;
      return ready;
    }

    // 2. Todavía resolviendo fuentes para este mismo título -> engancharse
    final running = _inFlight;
    if (running != null && _activeKey == key) {
      try {
        await running.timeout(waitIfInFlight);
      } catch (_) {}
      final nowReady = _ready;
      if (nowReady != null && nowReady.key == key && nowReady.isFresh) {
        _ready = null;
        _activeKey = '';
        _generation++;
        return nowReady;
      }
    }

    return null;
  }

  /// Cancela cualquier precalentamiento pendiente y libera su RAM.
  void cancel() {
    _generation++;
    _activeKey = '';
    final old = _ready;
    _ready = null;
    if (old != null) {
      HlsStreamProxy.instance.releaseSession(old.sessionId);
    }
  }
}
