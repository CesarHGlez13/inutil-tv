import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/models.dart';
import 'network_config_service.dart';
import 'remote_providers_config.dart';
import 'stream_validator.dart';

/// Proveedor VOD principal multi-espejo de InútilTV (PoseidonHD2 + Cuevana3).
///
/// Ventajas clave frente al scraping frágil tradicional:
/// 1. Esquema JSON estructurado (`__NEXT_DATA__`) con **dos espejos activos**
///    (`www.poseidonhd2.co` y `wv3.cuevana3.eu`) con failover automático.
/// 2. **Metadatos oficiales TMDB reales**: portadas HD `w500`, backdrops HD `w780`,
///    sinopsis coherentes en español, calificaciones reales y duración exacta.
/// 3. **Temporadas y episodios completos en 1 sola petición** con miniaturas HD.
/// 4. **Resolución multi-servidor verificada por bytes reales** (Latino, Español y
///    Subtitulado): Vidara HLS 1080p (`POST /api/stream`) + Doodstream MP4 directo
///    (`/pass_md5/`), pasando siempre por [StreamValidator].
class CuevanaPoseidonService {
  static final CuevanaPoseidonService _instance =
      CuevanaPoseidonService._internal();
  factory CuevanaPoseidonService() => _instance;
  CuevanaPoseidonService._internal();

  static const List<String> mirrors = RemoteProvidersConfig.defaultPoseidonMirrors;

  List<String> get _poseidonMirrors =>
      RemoteProvidersConfig.instance.poseidonMirrors;

  String _activeMirror = RemoteProvidersConfig.defaultPoseidonMirrors.first;

  static const Map<String, String> _headers = {
    'User-Agent': StreamValidator.defaultUserAgent,
    'Accept-Language': 'es-MX,es;q=0.9,en;q=0.8',
  };

  /// Géneros oficiales disponibles en los espejos PoseidonHD2 / Cuevana3.
  static const List<Map<String, String>> genres = [
    {'path': 'tendencias', 'label': 'Tendencias'},
    {'path': 'accion', 'label': 'Acción'},
    {'path': 'animacion', 'label': 'Animación'},
    {'path': 'aventura', 'label': 'Aventura'},
    {'path': 'ciencia-ficcion', 'label': 'Ciencia Ficción'},
    {'path': 'comedia', 'label': 'Comedia'},
    {'path': 'crimen', 'label': 'Crimen'},
    {'path': 'drama', 'label': 'Drama'},
    {'path': 'familia', 'label': 'Familia'},
    {'path': 'fantasia', 'label': 'Fantasía'},
    {'path': 'misterio', 'label': 'Misterio'},
    {'path': 'romance', 'label': 'Romance'},
    {'path': 'suspense', 'label': 'Suspenso'},
    {'path': 'terror', 'label': 'Terror'},
  ];

  final Map<String, _CachedStreams> _streamCache = {};
  final Map<String, List<VodEpisode>> _episodeCache = {};
  final Map<String, VodItem> _detailCache = {};

  /// Obtiene películas recientes, tendencias o por género con paginación real.
  Future<List<VodItem>> fetchMovies({int page = 1, String? genre}) async {
    final String path;
    if (genre == 'tendencias') {
      path = page > 1
          ? '/peliculas/tendencias/semana/page/$page'
          : '/peliculas/tendencias/semana';
    } else if (genre != null && genre.isNotEmpty) {
      path = page > 1 ? '/genero/$genre/page/$page' : '/genero/$genre';
    } else {
      path = page > 1 ? '/peliculas/page/$page' : '/peliculas';
    }

    final pageProps = await _fetchPageProps(path);
    if (pageProps == null) return [];

    final rawList = (pageProps['movies'] as List?) ?? const [];
    return _parseMediaList(rawList, defaultIsSeries: false);
  }

  /// Obtiene series destacadas con paginación real.
  Future<List<VodItem>> fetchSeries({int page = 1, String? section}) async {
    final String path;
    if (section == 'tendencias') {
      path = page > 1
          ? '/series/tendencias/semana/page/$page'
          : '/series/tendencias/semana';
    } else if (section == 'estrenos') {
      path = page > 1 ? '/series/estrenos/page/$page' : '/series/estrenos';
    } else {
      path = page > 1 ? '/series/page/$page' : '/series';
    }
    final pageProps = await _fetchPageProps(path);
    if (pageProps == null) return [];

    final rawList = (pageProps['movies'] as List?) ??
        (pageProps['series'] as List?) ??
        const [];
    return _parseMediaList(rawList, defaultIsSeries: true);
  }

  /// Búsqueda en tiempo real en ambos espejos con normalización de acentos.
  Future<List<VodItem>> search(String query) async {
    final clean = query.trim();
    if (clean.isEmpty) return [];

    final q = Uri.encodeQueryComponent(clean);
    var pageProps = await _fetchPageProps('/search?q=$q');
    var rawList = (pageProps?['movies'] as List?) ?? const [];

    if (rawList.isEmpty) {
      final ascii = StreamValidator.stripAccents(clean);
      if (ascii != clean) {
        pageProps = await _fetchPageProps(
          '/search?q=${Uri.encodeQueryComponent(ascii)}',
        );
        rawList = (pageProps?['movies'] as List?) ?? const [];
      }
    }

    return _parseMediaList(rawList, defaultIsSeries: false);
  }

  /// Obtiene detalle enriquecido (sinopsis completa, temporadas y episodios reales).
  Future<VodItem?> fetchDetail(VodItem item) async {
    final slugPath = _detailPathFor(item);
    if (slugPath == null) return null;

    if (_detailCache.containsKey(slugPath)) {
      return _detailCache[slugPath];
    }

    final pageProps = await _fetchPageProps(slugPath);
    if (pageProps == null) return null;

    final raw = (pageProps['thisMovie'] ?? pageProps['thisSerie'])
        as Map<String, dynamic>?;
    if (raw == null) return null;

    final parsed = _parseMediaObject(raw, defaultIsSeries: item.isSeries);
    if (parsed == null) return null;

    final episodes = _parseSeasonsFromRaw(raw, itemSlug: item.slug);
    final enriched = parsed.copyWithEpisodes(episodes);
    _detailCache[slugPath] = enriched;
    if (episodes.isNotEmpty) {
      _episodeCache[item.slug] = episodes;
    }
    return enriched;
  }

  /// Carga TODAS las temporadas y episodios de una serie en una sola petición JSON.
  Future<List<VodEpisode>> fetchSeriesEpisodes(VodItem item) async {
    final cacheKey = item.slug.isNotEmpty ? item.slug : item.id;
    if (_episodeCache.containsKey(cacheKey)) {
      return _episodeCache[cacheKey]!;
    }

    final slugPath = _detailPathFor(item);
    if (slugPath == null) return [];

    final pageProps = await _fetchPageProps(slugPath);
    if (pageProps == null) return [];

    final raw = pageProps['thisSerie'] as Map<String, dynamic>?;
    if (raw == null) return [];

    final episodes = _parseSeasonsFromRaw(raw, itemSlug: item.slug);
    if (episodes.isNotEmpty) {
      _episodeCache[cacheKey] = episodes;
    }
    return episodes;
  }

  /// Mapa `"<temporada>x<episodio>" -> still TMDB` (`w300`) para un título.
  ///
  /// Los espejos PoseidonHD2/Cuevana3 publican la imagen real de cada capítulo
  /// (campo `image` en `__NEXT_DATA__`), así que este mapa se usa para dar
  /// miniatura a episodios de proveedores que no publican imagen por capítulo
  /// (SeriesKao, PelisFlix). Devuelve vacío si el título no aparece en el espejo.
  Future<Map<String, String>> fetchStillsMapForTitle(
    String title, {
    bool isSeries = true,
  }) async {
    final clean = title.trim();
    if (clean.isEmpty) return const {};

    final hits = await search(clean);
    if (hits.isEmpty) return const {};

    final match = pickStillsMatch(hits, clean, isSeries: isSeries);
    if (match == null) return const {};

    final detail = await fetchDetail(match);
    final eps = detail?.episodes ?? const <VodEpisode>[];
    return {
      for (final e in eps)
        if (e.thumbnail.isNotEmpty)
          '${e.seasonNumber}x${e.episodeNumber}': e.thumbnail,
    };
  }

  /// Palabras que cambian entre idiomas/títulos y no ayudan a identificar la obra.
  static const Set<String> _stopTokens = {
    'and', 'y', 'the', 'el', 'la', 'los', 'las', 'un', 'una', 'de', 'del',
    'le', 'a', 'of', 'en',
  };

  /// Elige el candidato del espejo que corresponde a la MISMA obra. Exige que el
  /// conjunto de palabras coincida (ignorando conectores bilingües) para no
  /// rellenar miniaturas con el arte de otra obra parecida (p. ej. «Rick y
  /// Morty: El Anime» no debe ganar sobre «Rick and Morty»).
  @visibleForTesting
  VodItem? pickStillsMatch(List<VodItem> hits, String title,
      {required bool isSeries}) {
    Set<String> tokensFor(String s) => StreamValidator.normalizeTitle(s)
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty && !_stopTokens.contains(t))
        .toSet();

    final target = tokensFor(title);
    if (target.isEmpty) return null;

    VodItem? best;
    var bestScore = 0.0;
    for (final h in hits) {
      final t = tokensFor(h.title);
      if (t.isEmpty) continue;
      final inter = t.intersection(target).length;
      double score;
      if (t.length == target.length && inter == t.length) {
        score = 1.0; // mismo conjunto de palabras
      } else if (inter == target.length || inter == t.length) {
        score = 0.85; // uno contiene al otro
      } else {
        score = inter / t.length;
      }
      if (h.isSeries == isSeries) score += 0.1;
      if (score > bestScore) {
        bestScore = score;
        best = h;
      }
    }
    return bestScore >= 0.9 ? best : null;
  }

  /// Resuelve TODAS las fuentes de reproducción válidas para una película o episodio,
  /// validando bytes reales de video (Vidara HLS + Doodstream MP4) antes de devolverlas.
  Future<List<StreamSource>> resolveAllStreamSources(
    VodItem item, {
    VodEpisode? episode,
    void Function(String status)? onStatus,
  }) async {
    final path = episode != null
        ? _episodePathFor(item, episode)
        : _detailPathFor(item);
    if (path == null) return [];

    final cached = _streamCache[path];
    if (cached != null && DateTime.now().isBefore(cached.expiresAt)) {
      onStatus?.call('Preparando reproducción...');
      return cached.sources;
    }

    onStatus?.call('Buscando servidores disponibles...');
    final pageProps = await _fetchPageProps(path);
    if (pageProps == null) return [];

    final container = (pageProps['thisMovie'] ??
        pageProps['episode'] ??
        pageProps['thisSerie']) as Map<String, dynamic>?;
    final videosMap = container?['videos'];
    if (videosMap is! Map) return [];

    // Construir cola ordenada: Latino primero, luego Español, luego Subtitulado.
    // Prioridad de host guiada por salud y velocidad real medida (`StreamHostHealth`):
    // StreamWish (CDN rápido) + Vidara (API directa) + VidHide + Doodstream,
    // degradando automáticamente cualquier host que esté lento o trabado.
    final candidates = <_ServerCandidate>[];
    const langOrder = [
      ('latino', 'Latino'),
      ('spanish', 'Español'),
      ('english', 'Subtitulado'),
    ];
    final baseHosts = ['streamwish', 'vidara', 'vidhide', 'doodstream'];
    final hostOrder = List<String>.of(baseHosts)
      ..sort((a, b) {
        final pa = StreamHostHealth.instance.hostOrderPenalty(a);
        final pb = StreamHostHealth.instance.hostOrderPenalty(b);
        if (pa != pb) return pa.compareTo(pb);
        return baseHosts.indexOf(a).compareTo(baseHosts.indexOf(b));
      });

    for (final (langKey, langLabel) in langOrder) {
      final list = videosMap[langKey];
      if (list is! List) continue;
      for (final host in hostOrder) {
        for (final entry in list) {
          if (entry is! Map) continue;
          final cl = (entry['cyberlocker'] ?? '').toString().toLowerCase();
          final resUrl = (entry['result'] ?? '').toString();
          if (cl == host && resUrl.startsWith('http')) {
            candidates.add(_ServerCandidate(
              cyberlocker: cl,
              playerPhpUrl: resUrl,
              language: langLabel,
            ));
          }
        }
      }
    }

    if (candidates.isEmpty) {
      onStatus?.call('No se encontraron servidores disponibles para este título.');
      return [];
    }

    final verifiedScored = <({StreamSource source, double score, int langRank})>[];
    final timeoutFallbacks = <StreamSource>[];
    final seenUrls = <String>{};

    int langRankFor(String label) {
      final l = label.toLowerCase();
      if (l.contains('latino')) return 0;
      if (l.contains('español') || l.contains('espanol')) return 1;
      return 2;
    }

    // Carrera en lotes paralelos de 3 hosts con sonda real de velocidad (48 KB):
    // prioriza el servidor más rápido y sano dentro del mismo idioma.
    const batchSize = 3;
    for (var i = 0; i < candidates.length && verifiedScored.isEmpty; i += batchSize) {
      final batch = candidates.skip(i).take(batchSize).toList();
      final first = batch.first;
      onStatus?.call(
        'Verificando servidor (${first.language})...',
      );

      final probeScores = <String, double>{};
      final batchResults = await collectBatchWithFastWin(
        batch.map((cand) async {
          final embedUrl = await _resolvePlayerRedirect(cand.playerPhpUrl);
          if (embedUrl == null) {
            return (null as StreamSource?, StreamValidationStatus.invalid);
          }

          List<StreamSource> extracted = const [];
          if (cand.cyberlocker == 'vidhide') {
            extracted = await extractVidHideCandidates(
              embedUrl,
              label: 'HD · ${cand.language}',
            );
          } else if (cand.cyberlocker == 'streamwish') {
            extracted = await extractStreamWishCandidates(
              embedUrl,
              label: 'HD · ${cand.language}',
            );
          } else if (cand.cyberlocker == 'vidara') {
            final s = await extractVidara(
              embedUrl,
              label: 'HD · ${cand.language}',
            );
            if (s != null) extracted = [s];
          } else if (cand.cyberlocker == 'doodstream') {
            final s = await _extractDoodstream(
              embedUrl,
              referer: cand.playerPhpUrl,
              label: 'HD · ${cand.language}',
            );
            if (s != null) extracted = [s];
          }

          if (extracted.isEmpty) {
            return (null as StreamSource?, StreamValidationStatus.invalid);
          }
          StreamSource? timedOutCandidate;
          for (final source in extracted) {
            final probe = await StreamValidator.probeUrl(
              source.url,
              headers: source.headers,
              timeout: const Duration(seconds: 7),
              server: source.server,
            );
            if (probe.isValid) {
              probeScores[source.url] = StreamHostHealth.instance.scoreFor(
                url: source.url,
                server: source.server,
                probeBytesPerSec: probe.bytesPerSec,
                latencyMs: probe.latencyMs,
              );
              return (source, probe.status);
            }
            if (probe.status == StreamValidationStatus.timeout &&
                timedOutCandidate == null) {
              timedOutCandidate = source;
            }
          }
          if (timedOutCandidate != null) {
            return (timedOutCandidate, StreamValidationStatus.timeout);
          }
          return (null as StreamSource?, StreamValidationStatus.invalid);
        }).toList(growable: false),
        graceWindow: const Duration(milliseconds: 900),
      );

      for (final (source, status) in batchResults) {
        if (source == null || !seenUrls.add(source.url)) continue;
        if (status == StreamValidationStatus.valid) {
          verifiedScored.add((
            source: source,
            score: probeScores[source.url] ??
                StreamHostHealth.instance.scoreFor(
                  url: source.url,
                  server: source.server,
                ),
            langRank: langRankFor(source.quality),
          ));
        } else if (status == StreamValidationStatus.timeout) {
          timeoutFallbacks.add(source);
        }
      }
    }

    verifiedScored.sort((a, b) {
      if (a.langRank != b.langRank) return a.langRank.compareTo(b.langRank);
      return b.score.compareTo(a.score);
    });
    final verified = verifiedScored.map((e) => e.source).toList();

    // Priorizar siempre los validados por bytes; si la red es muy lenta y sólo
    // hubo timeouts (no DMCA/404), entregar los extraídos para que HlsStreamProxy
    // los reproduzca con reintentos y timeout amplio.
    final resolved = <StreamSource>[
      ...verified,
      if (verified.length < 2) ...timeoutFallbacks,
    ];

    if (verified.isNotEmpty) {
      _streamCache[path] = _CachedStreams(
        resolved,
        DateTime.now().add(const Duration(hours: 2)),
      );
    }

    return resolved;
  }

  /// Ejecuta un lote de candidatos en paralelo y devuelve inmediatamente en cuanto
  /// todos terminan o tras una ventana de gracia de [graceWindow] desde el primer
  /// servidor `valid` (evita esperar 6-10s por un Doodstream o espejo colgado cuando
  /// VidHide o StreamWish ya respondieron en ~1s).
  static Future<List<(StreamSource?, StreamValidationStatus)>>
      collectBatchWithFastWin(
    List<Future<(StreamSource?, StreamValidationStatus)>> tasks, {
    Duration graceWindow = const Duration(milliseconds: 700),
  }) async {
    if (tasks.isEmpty) return const [];
    final completer =
        Completer<List<(StreamSource?, StreamValidationStatus)>>();
    final collected = <(StreamSource?, StreamValidationStatus)>[];
    var remaining = tasks.length;
    Timer? graceTimer;

    void finish() {
      graceTimer?.cancel();
      if (!completer.isCompleted) {
        completer.complete(List.of(collected));
      }
    }

    for (final task in tasks) {
      task.then((res) {
        collected.add(res);
        remaining--;
        final isValid = res.$1 != null && res.$2 == StreamValidationStatus.valid;
        if (remaining <= 0) {
          finish();
        } else if (isValid && graceTimer == null) {
          graceTimer = Timer(graceWindow, finish);
        }
      }).catchError((Object _) {
        remaining--;
        if (remaining <= 0) finish();
      });
    }
    return completer.future;
  }

  /// Ejecuta [tasks] en paralelo y devuelve el PRIMER resultado no-nulo apenas
  /// responde (sin esperar a que los espejos lentos o caídos agoten timeout).
  @visibleForTesting
  static Future<T?> raceFirstNonNull<T>(List<Future<T?>> tasks) async {
    if (tasks.isEmpty) return null;
    final completer = Completer<T?>();
    var remaining = tasks.length;
    for (final task in tasks) {
      task.then((value) {
        if (value != null && !completer.isCompleted) {
          completer.complete(value);
          return;
        }
        remaining--;
        if (remaining <= 0 && !completer.isCompleted) {
          completer.complete(null);
        }
      }).catchError((Object _) {
        remaining--;
        if (remaining <= 0 && !completer.isCompleted) {
          completer.complete(null);
        }
      });
    }
    return completer.future;
  }

  // ── Extracción de hosts reales ─────────────────────────────────────────────

  // Espejos directos primero (200 OK sin redirección 302 extra) para mínima latencia.
  // Se leen dinámicamente desde `RemoteProvidersConfig` (`app_config/providers`).
  List<String> get _streamWishMirrors =>
      RemoteProvidersConfig.instance.streamWishMirrors;

  /// Extrae todos los `.m3u8` (y respaldos `master.txt` / `/stream/...`) del JS
  /// desempaquetado y los ordena priorizando rutas `/stream/.../master.m3u8`
  /// (200 OK) por encima de CDNs `premilkyway.com/hls2` (que suelen dar 502).
  @visibleForTesting
  static List<String> rankExtractedM3u8Urls(String hay, String host) {
    final matches = RegExp(
      r'''(https?://[^\s"'<>]+\.(?:m3u8|txt)(?:\?[^\s"'<>]*)?|/stream/[^\s"'<>]+\.(?:m3u8|txt)(?:\?[^\s"'<>]*)?)''',
    ).allMatches(hay);
    final urls = <String>[];
    final seen = <String>{};
    for (final m in matches) {
      var u = m.group(1)!;
      final lower = u.toLowerCase();
      // Filtrar .txt que no sean playlists HLS (solo aceptar master.txt / hls / stream)
      if (lower.contains('.txt') &&
          !lower.contains('master.txt') &&
          !lower.contains('/hls') &&
          !lower.contains('/stream/')) {
        continue;
      }
      if (u.startsWith('/')) u = 'https://$host$u';
      if (seen.add(u)) urls.add(u);
    }

    int score(String u) {
      final l = u.toLowerCase();
      if (l.contains('/stream/') && l.contains('.m3u8')) return 0; // Más confiable
      if (l.contains('premilkyway.com/hls2')) return 4; // Suele dar 502
      if (l.contains('master.m3u8')) return 1;
      if (l.contains('.m3u8')) return 2;
      if (l.contains('master.txt')) return 3; // Respaldo HLS3/HLS4 válido
      return 5;
    }

    urls.sort((a, b) => score(a).compareTo(score(b)));
    return urls;
  }

  /// Extrae candidatos HLS ordenados desde StreamWish usando carrera de primer ganador.
  Future<List<StreamSource>> extractStreamWishCandidates(
    String embedUrl, {
    required String label,
  }) async {
    try {
      final uri = Uri.parse(embedUrl);
      final segs = uri.pathSegments.where((s) => s.isNotEmpty).toList();
      if (segs.isEmpty) return const [];
      final code = segs.last;

      const batchSize = 3;
      for (var i = 0; i < _streamWishMirrors.length; i += batchSize) {
        final batch = _streamWishMirrors.skip(i).take(batchSize).toList();
        final winner = await raceFirstNonNull<List<StreamSource>>(
          batch.map((host) async {
            try {
              final mirrorUrl = 'https://$host/e/$code';
              final res = await http
                  .get(
                    Uri.parse(mirrorUrl),
                    headers: {
                      ..._headers,
                      'Referer': 'https://player.poseidonhd2.co/',
                    },
                  )
                  .timeout(const Duration(seconds: 10));
              if (res.statusCode != 200) return null;

              final effectiveHost = res.request?.url.host.isNotEmpty == true
                  ? res.request!.url.host
                  : host;
              final unpacked = _unpackDeanEdwards(res.body);
              final hay = unpacked ?? res.body;
              final ranked = rankExtractedM3u8Urls(hay, effectiveHost);
              if (ranked.isEmpty) return null;

              final headers = {
                'Referer': 'https://$effectiveHost/',
                'Origin': 'https://$effectiveHost',
                'User-Agent': StreamValidator.defaultUserAgent,
              };
              return [
                for (final candidateUrl in ranked)
                  StreamSource(
                    url: candidateUrl,
                    quality: label,
                    server: 'streamwish',
                    headers: headers,
                  ),
              ];
            } catch (_) {
              return null;
            }
          }).toList(growable: false),
        );

        if (winner != null && winner.isNotEmpty) return winner;
      }
    } catch (e) {
      debugPrint('[CuevanaPoseidon] StreamWish err: $e');
    }
    return const [];
  }

  /// Extrae HLS 1080p desde StreamWish probando sus espejos activos en paralelo.
  Future<StreamSource?> extractStreamWish(
    String embedUrl, {
    required String label,
  }) async {
    final cands = await extractStreamWishCandidates(embedUrl, label: label);
    return cands.isNotEmpty ? cands.first : null;
  }

  // Espejos directos primero (callistanise / peytonepre / smoothpre responden 200
  // directo sin redirección 302 ni errores SSL como dhtpre.com).
  // Se leen dinámicamente desde `RemoteProvidersConfig` (`app_config/providers`).
  List<String> get _vidHideMirrors =>
      RemoteProvidersConfig.instance.vidHideMirrors;

  /// Extrae candidatos HLS ordenados desde VidHide usando carrera de primer ganador
  /// y desempaquetando el bloque Dean Edwards `eval(function(p,a,c,k,e,d))`.
  Future<List<StreamSource>> extractVidHideCandidates(
    String embedUrl, {
    required String label,
  }) async {
    try {
      final uri = Uri.parse(embedUrl);
      final segs = uri.pathSegments.where((s) => s.isNotEmpty).toList();
      if (segs.isEmpty) return const [];
      final code = segs.last;

      const batchSize = 3;
      for (var i = 0; i < _vidHideMirrors.length; i += batchSize) {
        final batch = _vidHideMirrors.skip(i).take(batchSize).toList();
        final winner = await raceFirstNonNull<List<StreamSource>>(
          batch.map((host) async {
            try {
              final mirrorUrl = 'https://$host/v/$code';
              final res = await http
                  .get(
                    Uri.parse(mirrorUrl),
                    headers: {
                      ..._headers,
                      'Referer': 'https://player.poseidonhd2.co/',
                    },
                  )
                  .timeout(const Duration(seconds: 10));
              if (res.statusCode != 200) return null;

              final effectiveHost = res.request?.url.host.isNotEmpty == true
                  ? res.request!.url.host
                  : host;
              final unpacked = _unpackDeanEdwards(res.body);
              final hay = unpacked ?? res.body;
              final ranked = rankExtractedM3u8Urls(hay, effectiveHost);
              if (ranked.isEmpty) return null;

              final headers = {
                'Referer': 'https://$effectiveHost/',
                'Origin': 'https://$effectiveHost',
                'User-Agent': StreamValidator.defaultUserAgent,
              };
              return [
                for (final candidateUrl in ranked)
                  StreamSource(
                    url: candidateUrl,
                    quality: label,
                    server: 'vidhide',
                    headers: headers,
                  ),
              ];
            } catch (_) {
              return null;
            }
          }).toList(growable: false),
        );

        if (winner != null && winner.isNotEmpty) return winner;
      }
    } catch (e) {
      debugPrint('[CuevanaPoseidon] VidHide err: $e');
    }
    return const [];
  }

  /// Extrae HLS 1080p desde VidHide probando sus espejos activos en paralelo.
  Future<StreamSource?> extractVidHide(
    String embedUrl, {
    required String label,
  }) async {
    final cands = await extractVidHideCandidates(embedUrl, label: label);
    return cands.isNotEmpty ? cands.first : null;
  }

  /// Desempaquetador nativo puro en Dart para bloques JS `eval(function(p,a,c,k,e,d)...)`.
  static String? _unpackDeanEdwards(String html) {
    final m = RegExp(
      r"""eval\(function\(p,a,c,k,e,[dr]\)\{.*?\}\('(.*?)',(\d+),(\d+),'(.*?)'\.split\('\|'\)""",
      dotAll: true,
    ).firstMatch(html);
    if (m == null) return null;

    var payload = m.group(1)!;
    final radix = int.tryParse(m.group(2)!) ?? 36;
    final count = int.tryParse(m.group(3)!) ?? 0;
    final symtab = m.group(4)!.split('|');

    payload = payload
        .replaceAll(r"\'", "'")
        .replaceAll(r'\"', '"')
        .replaceAll(r'\\', r'\');

    const alphabet =
        '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ';

    String encodeBase(int n) {
      if (n == 0) return '0';
      var v = n;
      final sb = StringBuffer();
      while (v > 0) {
        sb.write(alphabet[v % radix]);
        v ~/= radix;
      }
      return sb.toString().split('').reversed.join();
    }

    final dict = <String, String>{};
    for (var i = count - 1; i >= 0; i--) {
      final key = encodeBase(i);
      dict[key] = (i < symtab.length && symtab[i].isNotEmpty) ? symtab[i] : key;
    }

    return payload.replaceAllMapped(
      RegExp(r'\b\w+\b'),
      (match) => dict[match.group(0)!] ?? match.group(0)!,
    );
  }

  Future<String?> _resolvePlayerRedirect(String playerPhpUrl) async {
    try {
      final res = await http
          .get(
            Uri.parse(playerPhpUrl),
            headers: {..._headers, 'Referer': '$_activeMirror/'},
          )
          .timeout(const Duration(seconds: 12));
      if (res.statusCode != 200) return null;
      final m = RegExp(r"""var\s+url\s*=\s*['"]([^'"]+)['"]""")
              .firstMatch(res.body) ??
          RegExp(r'''iframe[^>]+src=["'](https?://[^"']+)["']''')
              .firstMatch(res.body);
      return m?.group(1);
    } catch (_) {
      return null;
    }
  }

  /// Extrae HLS 1080p directo + subtítulos desde `vidara.to/api/stream`.
  Future<StreamSource?> extractVidara(
    String embedUrl, {
    required String label,
  }) async {
    try {
      final uri = Uri.parse(embedUrl);
      final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
      if (segments.isEmpty) return null;
      final filecode = segments.last;
      final origin = '${uri.scheme}://${uri.host}';

      final res = await http
          .post(
            Uri.parse('$origin/api/stream'),
            headers: {
              ..._headers,
              'Content-Type': 'application/json',
              'Referer': embedUrl,
              'Origin': origin,
            },
            body: jsonEncode({'filecode': filecode, 'device': 'desktop'}),
          )
          .timeout(const Duration(seconds: 8));

      if (res.statusCode != 200) return null;
      final j = jsonDecode(res.body);
      if (j is! Map) return null;
      final streamUrl = j['streaming_url']?.toString() ?? '';
      if (!streamUrl.startsWith('http')) return null;

      final subs = <SubtitleSource>[];
      final rawSubs = j['subtitles'];
      if (rawSubs is List) {
        for (final s in rawSubs) {
          if (s is Map) {
            final u = (s['file_path'] ?? s['url'] ?? '').toString();
            if (u.startsWith('http')) {
              subs.add(SubtitleSource(
                url: u,
                label: (s['label'] ?? s['language'] ?? 'Subtítulos').toString(),
                language: (s['language'] ?? 'es').toString(),
              ));
            }
          }
        }
      }

      return StreamSource(
        url: streamUrl,
        quality: label,
        server: 'vidara',
        subtitles: subs,
        headers: {
          'Referer': '$origin/',
          'Origin': origin,
          'User-Agent': StreamValidator.defaultUserAgent,
        },
      );
    } catch (e) {
      debugPrint('[CuevanaPoseidon] Vidara err: $e');
      return null;
    }
  }

  /// Extrae MP4 directo desde Doodstream / Playmogo (`/pass_md5/`).
  Future<StreamSource?> _extractDoodstream(
    String embedUrl, {
    required String referer,
    required String label,
  }) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8)
      ..badCertificateCallback = (_, __, ___) => true;
    // Respetamos proxy corporativo / DNS seguro si el usuario los activó.
    NetworkConfigService.instance.apply(client, tolerateBadCertificates: true);
    try {
      final req = await client.getUrl(Uri.parse(embedUrl));
      req.headers.set('User-Agent', StreamValidator.defaultUserAgent);
      req.headers.set('Referer', referer);
      final res = await req.close().timeout(const Duration(seconds: 8));
      var resolvedFinal = Uri.parse(embedUrl);
      for (final r in res.redirects) {
        resolvedFinal = resolvedFinal.resolveUri(r.location);
      }
      final rawBytes = await res
          .fold<List<int>>([], (acc, chunk) => acc..addAll(chunk))
          .timeout(const Duration(seconds: 8));
      final html = utf8.decode(rawBytes, allowMalformed: true);

      final md5Match = RegExp(r"""(/pass_md5/[^'"]+)""").firstMatch(html);
      if (md5Match == null) return null;

      final tokMatch = RegExp(r'token=([a-zA-Z0-9]+)').firstMatch(html);
      final origin = '${resolvedFinal.scheme}://${resolvedFinal.host}';
      final md5Url = '$origin${md5Match.group(1)}';

      final md5Res = await http
          .get(
            Uri.parse(md5Url),
            headers: {
              ..._headers,
              'Referer': resolvedFinal.toString(),
            },
          )
          .timeout(const Duration(seconds: 8));
      if (md5Res.statusCode != 200) return null;

      final prefix = md5Res.body.trim();
      if (!prefix.startsWith('http')) return null;

      const chars =
          'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
      final rng = Random();
      final rand10 =
          List.generate(10, (_) => chars[rng.nextInt(chars.length)]).join();
      final token = tokMatch?.group(1) ?? md5Match.group(1)!.split('/').last;
      final expiry = DateTime.now().millisecondsSinceEpoch;
      final mp4Url = '$prefix$rand10?token=$token&expiry=$expiry';

      return StreamSource(
        url: mp4Url,
        quality: label,
        server: 'doodstream',
        headers: {
          'Referer': '$origin/',
          'User-Agent': StreamValidator.defaultUserAgent,
        },
      );
    } catch (e) {
      debugPrint('[CuevanaPoseidon] Doodstream err: $e');
      return null;
    } finally {
      client.close(force: true);
    }
  }

  // ── Parsing Next.js __NEXT_DATA__ con failover de espejos ──────────────────

  Future<Map<String, dynamic>?> _fetchPageProps(String path) async {
    final currentMirrors = _poseidonMirrors;
    final orderedMirrors = [
      if (currentMirrors.contains(_activeMirror)) _activeMirror,
      ...currentMirrors.where((m) => m != _activeMirror),
    ];

    for (final base in orderedMirrors) {
      try {
        final url = '$base$path';
        final res = await http
            .get(Uri.parse(url), headers: _headers)
            .timeout(const Duration(seconds: 9));
        if (res.statusCode != 200) continue;

        final match = RegExp(
          r'<script\s+id="__NEXT_DATA__"[^>]*>(.*?)</script>',
          dotAll: true,
        ).firstMatch(res.body);
        if (match == null) continue;

        final data = jsonDecode(match.group(1)!) as Map<String, dynamic>;
        final props = data['props'];
        if (props is Map && props['pageProps'] is Map) {
          _activeMirror = base;
          return (props['pageProps'] as Map).cast<String, dynamic>();
        }
      } catch (e) {
        debugPrint('[CuevanaPoseidon] Mirror $base$path err: $e');
      }
    }
    return null;
  }

  List<VodItem> _parseMediaList(
    List<dynamic> rawList, {
    required bool defaultIsSeries,
  }) {
    final out = <VodItem>[];
    final seen = <String>{};

    for (final raw in rawList) {
      if (raw is! Map) continue;
      final item = _parseMediaObject(
        raw.cast<String, dynamic>(),
        defaultIsSeries: defaultIsSeries,
      );
      if (item == null) continue;
      final key = '${item.isSeries ? "s" : "m"}_${StreamValidator.normalizeTitle(item.title)}';
      if (seen.add(key)) {
        out.add(item);
      }
    }
    return out;
  }

  VodItem? _parseMediaObject(
    Map<String, dynamic> raw, {
    required bool defaultIsSeries,
  }) {
    final titles = raw['titles'];
    final title = (titles is Map ? titles['name'] : raw['title'])
            ?.toString()
            .trim() ??
        '';
    if (title.isEmpty) return null;

    final urlObj = raw['url'];
    final rawSlug =
        (urlObj is Map ? urlObj['slug'] : raw['slug'])?.toString() ?? '';
    final isSeries = rawSlug.startsWith('series/') ||
        rawSlug.startsWith('serie/') ||
        (defaultIsSeries && !rawSlug.startsWith('movies/'));

    final tmdbId = (raw['TMDbId'] ?? raw['_id'] ?? '').toString().trim();
    final images = raw['images'] is Map ? raw['images'] as Map : const {};
    var poster = _optimizeTmdbImage(images['poster']?.toString() ?? '', 'w500');
    var backdrop =
        _optimizeTmdbImage(images['backdrop']?.toString() ?? '', 'w780');
    if (poster.isEmpty && backdrop.isNotEmpty) poster = backdrop;
    if (backdrop.isEmpty && poster.isNotEmpty) backdrop = poster;

    // Ignorar entradas sin póster válido
    if (poster.contains('404x.jpg')) poster = '';

    final overview = (raw['overview'] ?? '').toString().trim();

    final rateObj = raw['rate'];
    final avg = rateObj is Map ? (rateObj['average'] as num?) : null;
    final rating = (avg != null && avg > 0) ? avg.toStringAsFixed(1) : '';

    final relDate = (raw['releaseDate'] ?? '').toString();
    final year = relDate.length >= 4 ? relDate.substring(0, 4) : '';

    final runtimeNum = raw['runtime'] is num ? (raw['runtime'] as num).toInt() : 0;
    final duration = runtimeNum > 0
        ? (runtimeNum >= 60
            ? '${runtimeNum ~/ 60}h ${(runtimeNum % 60).toString().padLeft(2, '0')}m'
            : '${runtimeNum}m')
        : '';

    final genresRaw = raw['genres'];
    final genreNames = <String>[];
    if (genresRaw is List) {
      for (final g in genresRaw) {
        if (g is Map && g['name'] != null) {
          genreNames.add(g['name'].toString());
        }
      }
    }
    final genreStr = genreNames.isNotEmpty
        ? genreNames.take(3).join(' · ')
        : (isSeries ? 'Serie · Latino / Sub' : 'Película · Latino / Sub');

    // Guardamos slug canónico con formato `movies/<id>/<slug>` o `series/<id>/<slug>`
    final canonicalSlug = rawSlug.isNotEmpty
        ? rawSlug
        : '${isSeries ? "series" : "movies"}/$tmdbId/${_slugify(title)}';

    return VodItem(
      id: 'cp_${isSeries ? "s" : "m"}_${tmdbId.isNotEmpty ? tmdbId : _slugify(title)}',
      title: title,
      poster: poster,
      backdrop: backdrop,
      overview: overview,
      year: year,
      genre: genreStr,
      rating: rating,
      duration: duration,
      isSeries: isSeries,
      slug: canonicalSlug,
      provider: 'poseidon',
      quality: 'HD',
    );
  }

  List<VodEpisode> _parseSeasonsFromRaw(
    Map<String, dynamic> raw, {
    required String itemSlug,
  }) {
    final seasons = raw['seasons'];
    if (seasons is! List) return [];

    final episodes = <VodEpisode>[];
    for (final s in seasons) {
      if (s is! Map) continue;
      final sNum = (s['number'] as num?)?.toInt() ?? 1;
      final rawEps = s['episodes'];
      if (rawEps is! List) continue;
      for (final e in rawEps) {
        if (e is! Map) continue;
        final eNum = (e['number'] as num?)?.toInt() ?? 1;
        final title = (e['title'] ?? 'Episodio $eNum').toString().trim();
        final thumb = _optimizeTmdbImage((e['image'] ?? '').toString(), 'w300');
        final epUrlSlug = (e['url'] is Map ? e['url']['slug'] : '')?.toString() ?? '';
        // Duración real si el espejo la publica; '' => la UI muestra la
        // insignia de calidad en lugar de inventar un número.
        final runtimeMin = _runtimeMinutes(e['runtime'] ?? e['duration']);

        episodes.add(VodEpisode(
          id: 'cp_ep_${itemSlug}_${sNum}x$eNum',
          title: title.isNotEmpty ? title : 'Episodio $eNum',
          episodeNumber: eNum,
          seasonNumber: sNum,
          duration: runtimeMin != null ? '$runtimeMin min' : '',
          thumbnail: thumb,
          slug: epUrlSlug.isNotEmpty ? epUrlSlug : '$itemSlug/seasons/$sNum/episodes/$eNum',
          provider: 'poseidon',
        ));
      }
    }

    episodes.sort((a, b) {
      if (a.seasonNumber != b.seasonNumber) {
        return a.seasonNumber.compareTo(b.seasonNumber);
      }
      return a.episodeNumber.compareTo(b.episodeNumber);
    });
    return episodes;
  }

  String? _detailPathFor(VodItem item) {
    final s = item.slug.trim();
    if (s.isEmpty) return null;
    if (s.startsWith('movies/')) {
      return '/pelicula/${s.substring('movies/'.length)}';
    }
    if (s.startsWith('series/')) {
      return '/serie/${s.substring('series/'.length)}';
    }
    if (s.startsWith('/pelicula/') || s.startsWith('/serie/')) {
      return s;
    }
    return null;
  }

  String? _episodePathFor(VodItem item, VodEpisode ep) {
    final base = _detailPathFor(item);
    if (base == null) return null;
    return '$base/temporada/${ep.seasonNumber}/episodio/${ep.episodeNumber}';
  }

  /// Minutos reales de un episodio a partir de `runtime`/`duration` del JSON
  /// del espejo (número o ISO-8601 tipo `PT0H22M00S`). `null` si no viene.
  static int? _runtimeMinutes(dynamic raw) {
    if (raw == null) return null;
    if (raw is num) return raw.toInt() > 0 ? raw.toInt() : null;
    final s = raw.toString().trim();
    if (s.isEmpty) return null;
    final iso = RegExp(r'P(?:\d+D)?T?(?:(\d+)H)?(?:(\d+)M)?').firstMatch(s);
    if (iso != null && (iso.group(1) != null || iso.group(2) != null)) {
      final mins = int.tryParse(iso.group(1) ?? '0')! * 60 +
          int.tryParse(iso.group(2) ?? '0')!;
      return mins > 0 ? mins : null;
    }
    final plain = int.tryParse(s.replaceAll(RegExp(r'[^0-9]'), ''));
    return (plain != null && plain > 0 && plain < 600) ? plain : null;
  }

  static String _optimizeTmdbImage(String raw, String size) {
    if (raw.isEmpty) return '';
    if (raw.contains('image.tmdb.org/t/p/original/')) {
      return raw.replaceFirst('/t/p/original/', '/t/p/$size/');
    }
    return raw;
  }

  static String _slugify(String s) {
    return StreamValidator.stripAccents(s)
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-|-$'), '');
  }
}

extension _VodItemCopy on VodItem {
  VodItem copyWithEpisodes(List<VodEpisode> eps) => VodItem(
        id: id,
        title: title,
        poster: poster,
        backdrop: backdrop,
        overview: overview,
        year: year,
        genre: genre,
        rating: rating,
        duration: duration,
        isSeries: isSeries,
        isAnime: isAnime,
        sources: sources,
        episodes: eps.isNotEmpty ? eps : episodes,
        slug: slug,
        provider: provider,
        quality: quality,
        seasonCount: seasonCount,
        episodeCount: eps.isNotEmpty ? eps.length : episodeCount,
        genrePath: genrePath,
      );
}

class _ServerCandidate {
  final String cyberlocker;
  final String playerPhpUrl;
  final String language;

  const _ServerCandidate({
    required this.cyberlocker,
    required this.playerPhpUrl,
    required this.language,
  });
}

class _CachedStreams {
  final List<StreamSource> sources;
  final DateTime expiresAt;
  const _CachedStreams(this.sources, this.expiresAt);
}
