import 'dart:async';
import 'package:flutter/foundation.dart';

import '../models/models.dart';
import 'audio_language_priority.dart';
import 'hls_stream_proxy.dart';
import 'stream_validator.dart';
import 'vod_catalog_service.dart';

enum PreloadPhase { idle, resolving, buffering, ready, failed }

@immutable
class NextEpisodePreloadState {
  final PreloadPhase phase;
  final String itemId;
  final int seasonNumber;
  final int episodeNumber;
  final String episodeLabel;
  final int segmentsCached;
  final int targetSegments;
  final int bytesCached;

  const NextEpisodePreloadState({
    this.phase = PreloadPhase.idle,
    this.itemId = '',
    this.seasonNumber = 0,
    this.episodeNumber = 0,
    this.episodeLabel = '',
    this.segmentsCached = 0,
    this.targetSegments = 0,
    this.bytesCached = 0,
  });

  bool matches(String id, VodEpisode ep) =>
      itemId == id &&
      seasonNumber == ep.seasonNumber &&
      episodeNumber == ep.episodeNumber;

  double get megabytes => bytesCached / (1024 * 1024);

  bool get isReady => phase == PreloadPhase.ready;
}

class PreloadedEpisodeBundle {
  final String sessionId;
  final String localProxyUrl;
  final List<StreamSource> sources;
  final int segmentsCached;
  final int bytesCached;

  const PreloadedEpisodeBundle({
    required this.sessionId,
    required this.localProxyUrl,
    required this.sources,
    required this.segmentsCached,
    required this.bytesCached,
  });
}

/// Precargador en segundo plano del SIGUIENTE episodio (Series y Anime).
///
/// Mientras el usuario ve el episodio actual, resuelve silenciosamente el
/// episodio `N+1` y precarga sus primeros ~2–3 minutos (hasta 16 MB en HLS o
/// 10 MB en MP4) en [HlsStreamProxy] (`127.0.0.1`). Al pulsar "Siguiente" o al
/// terminar la cuenta regresiva, la reproducción arranca de forma instantánea
/// (<300 ms) sin volver a raspar servidores ni sufrir buffering en frío.
class NextEpisodePreloader {
  NextEpisodePreloader._();
  static final NextEpisodePreloader instance = NextEpisodePreloader._();

  final ValueNotifier<NextEpisodePreloadState> state =
      ValueNotifier(const NextEpisodePreloadState());

  int _generation = 0;
  PreloadedEpisodeBundle? _readyBundle;
  String _readyKey = '';
  String _readyAudioLang = '';
  String _inFlightAudioLang = '';

  static String _keyFor(String itemId, VodEpisode ep) =>
      '${itemId}_s${ep.seasonNumber}_e${ep.episodeNumber}';

  /// Inicia (o mantiene) la precarga en segundo plano del siguiente episodio.
  Future<void> preloadNext({
    required VodItem item,
    required VodEpisode nextEpisode,
    String? preferredAudioLang,
  }) async {
    final key = _keyFor(item.id, nextEpisode);
    final desired = AudioLanguagePriority.resolveDesiredAudioLang(
      activeSessionLang: preferredAudioLang,
    );

    // Si ya está listo o cargándose exactamente el mismo episodio con el mismo
    // idioma objetivo, no repetir.
    if (_readyKey == key &&
        _readyBundle != null &&
        _readyAudioLang == desired) {
      return;
    }
    if (state.value.matches(item.id, nextEpisode) &&
        _inFlightAudioLang == desired &&
        (state.value.phase == PreloadPhase.resolving ||
            state.value.phase == PreloadPhase.buffering)) {
      return;
    }

    // Cancelar precarga anterior y liberar su sesión de proxy
    cancel();
    final gen = ++_generation;
    _inFlightAudioLang = desired;
    bool cancelled() => gen != _generation;

    final epLabel = item.isAnime
        ? 'Ep. ${nextEpisode.episodeNumber}'
        : 'T${nextEpisode.seasonNumber}·E${nextEpisode.episodeNumber}';

    state.value = NextEpisodePreloadState(
      phase: PreloadPhase.resolving,
      itemId: item.id,
      seasonNumber: nextEpisode.seasonNumber,
      episodeNumber: nextEpisode.episodeNumber,
      episodeLabel: epLabel,
    );

    try {
      // 1. Resolver fuentes verificadas del siguiente episodio en el idioma objetivo
      final rawSources = nextEpisode.sources.isNotEmpty
          ? nextEpisode.sources
          : await VodCatalogService().resolveAllPlaybackSources(
              item,
              nextEpisode,
              null,
              desired,
            );

      if (cancelled()) return;
      if (rawSources.isEmpty) {
        state.value = NextEpisodePreloadState(
          phase: PreloadPhase.failed,
          itemId: item.id,
          seasonNumber: nextEpisode.seasonNumber,
          episodeNumber: nextEpisode.episodeNumber,
          episodeLabel: epLabel,
        );
        return;
      }

      final sources = AudioLanguagePriority.prioritizeSources(
        rawSources,
        desiredLang: desired,
      );

      // 2. Registrar la fuente ganadora en el proxy local y pre-bufferizar 2–3 min
      final primary = sources.first;
      final isHls = StreamValidator.needsLocalHlsProxy(primary.url);

      state.value = NextEpisodePreloadState(
        phase: PreloadPhase.buffering,
        itemId: item.id,
        seasonNumber: nextEpisode.seasonNumber,
        episodeNumber: nextEpisode.episodeNumber,
        episodeLabel: epLabel,
      );

      final reg = isHls
          ? await HlsStreamProxy.instance.registerHlsSession(
              upstreamUrl: primary.url,
              headers: primary.headers,
              tag: key,
            )
          : await HlsStreamProxy.instance.registerMp4Session(
              upstreamUrl: primary.url,
              headers: primary.headers,
              tag: key,
            );

      if (cancelled()) {
        HlsStreamProxy.instance.releaseSession(reg.sessionId);
        return;
      }

      final stats = isHls
          ? await HlsStreamProxy.instance.preloadHlsSession(
              reg.sessionId,
              maxSegments: 22, // ~2.5 - 3.5 minutos de video HD
              maxBytes: 16 * 1024 * 1024,
              isCancelled: cancelled,
              onProgress: (done, target, bytes) {
                if (cancelled()) return;
                state.value = NextEpisodePreloadState(
                  phase: PreloadPhase.buffering,
                  itemId: item.id,
                  seasonNumber: nextEpisode.seasonNumber,
                  episodeNumber: nextEpisode.episodeNumber,
                  episodeLabel: epLabel,
                  segmentsCached: done,
                  targetSegments: target,
                  bytesCached: bytes,
                );
              },
            )
          : await HlsStreamProxy.instance.preloadMp4Session(
              reg.sessionId,
              maxBytes: 10 * 1024 * 1024,
              isCancelled: cancelled,
              onProgress: (done, target, bytes) {
                if (cancelled()) return;
                state.value = NextEpisodePreloadState(
                  phase: PreloadPhase.buffering,
                  itemId: item.id,
                  seasonNumber: nextEpisode.seasonNumber,
                  episodeNumber: nextEpisode.episodeNumber,
                  episodeLabel: epLabel,
                  segmentsCached: done,
                  targetSegments: target,
                  bytesCached: bytes,
                );
              },
            );

      if (cancelled()) {
        HlsStreamProxy.instance.releaseSession(reg.sessionId);
        return;
      }

      // Incluso si el servidor no permitió prefetch completo, conservamos los
      // enlaces ya resueltos + proxy listo para cero tiempo de raspado.
      _readyKey = key;
      _readyAudioLang = desired;
      _readyBundle = PreloadedEpisodeBundle(
        sessionId: reg.sessionId,
        localProxyUrl: reg.localUrl,
        sources: sources,
        segmentsCached: stats.segmentsCached,
        bytesCached: stats.bytesCached,
      );

      state.value = NextEpisodePreloadState(
        phase: PreloadPhase.ready,
        itemId: item.id,
        seasonNumber: nextEpisode.seasonNumber,
        episodeNumber: nextEpisode.episodeNumber,
        episodeLabel: epLabel,
        segmentsCached: stats.segmentsCached,
        targetSegments: stats.segmentsCached,
        bytesCached: stats.bytesCached,
      );
    } catch (e) {
      debugPrint('[NextEpisodePreloader] Preload err: $e');
      if (!cancelled()) {
        state.value = NextEpisodePreloadState(
          phase: PreloadPhase.failed,
          itemId: item.id,
          seasonNumber: nextEpisode.seasonNumber,
          episodeNumber: nextEpisode.episodeNumber,
          episodeLabel: epLabel,
        );
      }
    }
  }

  /// Consume y devuelve el paquete precargado si coincide con [itemId] + [ep]
  /// (y con el idioma preferido si se especifica).
  /// El consumidor pasa a ser dueño de [PreloadedEpisodeBundle.sessionId].
  PreloadedEpisodeBundle? consumeIfReady(
    String itemId,
    VodEpisode ep, {
    String? preferredAudioLang,
  }) {
    final key = _keyFor(itemId, ep);
    if (_readyKey != key || _readyBundle == null) return null;
    if (preferredAudioLang != null && preferredAudioLang.trim().isNotEmpty) {
      final desired = AudioLanguagePriority.resolveDesiredAudioLang(
        activeSessionLang: preferredAudioLang,
      );
      if (_readyAudioLang.isNotEmpty && _readyAudioLang != desired) {
        cancel();
        return null;
      }
    }
    final bundle = _readyBundle;
    _readyBundle = null;
    _readyKey = '';
    _readyAudioLang = '';
    state.value = const NextEpisodePreloadState();
    return bundle;
  }

  /// Cancela cualquier precarga en curso y libera su sesión no consumida.
  void cancel() {
    _generation++;
    _inFlightAudioLang = '';
    if (_readyBundle != null) {
      HlsStreamProxy.instance.releaseSession(_readyBundle!.sessionId);
      _readyBundle = null;
      _readyKey = '';
      _readyAudioLang = '';
    }
    if (state.value.phase != PreloadPhase.idle) {
      state.value = const NextEpisodePreloadState();
    }
  }
}
