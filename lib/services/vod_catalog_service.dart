import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

import '../models/models.dart';
import 'cuevana_poseidon_service.dart';
import 'jkanime_service.dart';
import 'pelisflix_service.dart';
import 'series_health_service.dart';
import 'serieskao_service.dart';
import 'stream_validator.dart';
import 'tioanime_service.dart';

({List<VodItem> movies, List<VodItem> series}) _parseMasterVodInIsolate(
  String jsonStr,
) {
  final list = json.decode(jsonStr) as List;
  final movies = <VodItem>[];
  final series = <VodItem>[];
  for (final item in list) {
    final vod = VodItem.fromJson(item as Map<String, dynamic>);
    if (vod.isSeries) {
      series.add(vod);
    } else {
      movies.add(vod);
    }
  }
  return (movies: movies, series: series);
}

/// Servicio maestro multi-proveedor VOD para InútilTV v3.1.
///
/// Arquitectura anti-caídas de múltiples proveedores:
/// - **Series (Primario + Respaldo cruzado por episodio):**
///   [SeriesKaoService] (`/series/populares` + `/series` + Embed69 AES-256-CBC
///   con 100% disponibilidad multi-episodio) <-> [CuevanaPoseidonService]
///   (`poseidonhd2.co` + `cuevana3.eu`) <-> [PelisflixService].
///   Filtrado y priorización inteligente vía [SeriesHealthService].
/// - **Películas (Primario + Respaldo):** [CuevanaPoseidonService] (metadatos
///   TMDB HD) <-> [PelisflixService] + Clásicos permanentes (`vod_master.json`).
/// - **Anime (Primario + Respaldo):** [JkAnimeService] (portadas HD + búsqueda
///   sin tildes + paginación de +1,000 episodios) <-> [TioAnimeService].
class VodCatalogService {
  static final VodCatalogService _instance = VodCatalogService._internal();
  factory VodCatalogService() => _instance;
  VodCatalogService._internal();

  final _serieskao = SeriesKaoService();
  final _poseidon = CuevanaPoseidonService();
  final _pelisflix = PelisflixService();
  final _jkanime = JkAnimeService();
  final _tioanime = TioAnimeService();
  final _health = SeriesHealthService.instance;

  bool _initialized = false;
  Future<void>? _initFuture;
  List<VodItem> _masterMovies = [];
  List<VodItem> _masterSeries = [];

  final Map<String, List<VodItem>> _moviePageCache = {};
  final Map<String, List<VodItem>> _seriesPageCache = {};
  final Map<String, List<VodItem>> _animePageCache = {};

  Future<void>? _respaldosFuture;
  List<VodItem> _copiaMovies = [];
  List<VodItem> _copiaSeries = [];
  List<VodItem> _copiaAnime = [];
  final Set<String> _copiaGuardada = {};
  String? _copiaDirParaPruebas;

  /// Ultima pagina de catalogo que se pidio y termino con un problema de
  /// red (a diferencia de «no habia nada»). Las pestañas lo usan para
  /// explicar que paso en vez de mostrar una pantalla vacia.
  bool ultimoErrorDeRed = false;

  /// Carpeta alternativa para la copia local en las pruebas unitarias.
  @visibleForTesting
  set copiaDirParaPruebas(String dir) => _copiaDirParaPruebas = dir;

  /// Vaciar caches tambien descarta la copia en memoria para que un
  /// «Reintentar» vuelva a la red de verdad.
  void _limpiarCaches() {
    _moviePageCache.clear();
    _seriesPageCache.clear();
    _animePageCache.clear();
    _copiaMovies = [];
    _copiaSeries = [];
    _copiaAnime = [];
    _copiaGuardada.clear();
    _respaldosFuture = null;
  }

  List<VodItem> get _masterAnime =>
      [..._masterMovies, ..._masterSeries].where((i) => i.isAnime).toList();

  List<VodItem> get classicMovies => List.unmodifiable(_masterMovies);

  Future<void> initialize() {
    if (_initialized) return Future.value();
    return _initFuture ??= _initializeInternal();
  }

  Future<void> _initializeInternal() async {
    try {
      await _cargarRespaldos();
      await Future.wait([
        getMovies(page: 1),
        getSeries(page: 1),
        getAnime(page: 1),
      ]);
      _initialized = true;
    } catch (e) {
      debugPrint('[VodCatalogService] Init error: $e');
      _initFuture = null;
    }
  }

  /// Trae el catalogo empaquetado en la app y la ultima copia buena que se
  /// vio en este telefono. Nunca lanza: si algo falla deja los respaldos
  /// vacios y la pestaña mostrara el estado de red.
  Future<void> _cargarRespaldos() => _respaldosFuture ??= () async {
        try {
          await _health.load();
        } catch (e) {
          debugPrint('[VodCatalogService] salud de series no cargada: $e');
        }
        try {
          final jsonStr =
              await rootBundle.loadString('assets/vod_master.json');
          final parsed = await compute(_parseMasterVodInIsolate, jsonStr);
          _masterMovies = parsed.movies;
          _masterSeries = parsed.series;
        } catch (e) {
          debugPrint('[VodCatalogService] Error cargando vod_master.json: $e');
        }
        await _leerCopiaLocal();
      }();

  Future<String> _rutaCopia() async {
    final dir = _copiaDirParaPruebas ??
        (await getApplicationSupportDirectory()).path;
    return '$dir/inutiltv_catalogo_copia.json';
  }

  /// Lee la copia buena guardada en el telefono (si existe y es legible).
  Future<void> _leerCopiaLocal() async {
    try {
      final archivo = File(await _rutaCopia());
      if (!await archivo.exists()) return;
      final j = jsonDecode(await archivo.readAsString())
          as Map<String, dynamic>;
      List<VodItem> lee(String clave) => ((j[clave] as List?) ?? const [])
          .map((e) => VodItem.fromJson(e as Map<String, dynamic>))
          .toList();
      _copiaMovies = lee('peliculas');
      _copiaSeries = lee('series');
      _copiaAnime = lee('anime');
    } catch (e) {
      debugPrint('[VodCatalogService] copia local ilegible: $e');
    }
  }

  /// Guarda la primera pagina que SÍ vino de la red, una sola vez por
  /// lista y por arrancada, para poder mostrarla cuando la red falle.
  void _guardarCopia(String clave, List<VodItem> items) {
    if (items.isEmpty || _copiaGuardada.contains(clave)) return;
    _copiaGuardada.add(clave);
    if (clave == 'peliculas') _copiaMovies = items;
    if (clave == 'series') _copiaSeries = items;
    if (clave == 'anime') _copiaAnime = items;
    unawaited(_escribirCopia());
  }

  Future<void> _escribirCopia() async {
    try {
      final archivo = File(await _rutaCopia());
      if (!await archivo.parent.exists()) {
        await archivo.parent.create(recursive: true);
      }
      await archivo.writeAsString(jsonEncode({
        'guardadoEl': DateTime.now().toIso8601String(),
        'peliculas': _copiaMovies.map((e) => e.toJson()).toList(),
        'series': _copiaSeries.map((e) => e.toJson()).toList(),
        'anime': _copiaAnime.map((e) => e.toJson()).toList(),
      }));
    } catch (e) {
      debugPrint('[VodCatalogService] no se pudo guardar la copia: $e');
    }
  }

  void clearPageCaches() => _limpiarCaches();

  /// Carga películas con paginación infinita y filtro por género.
  ///
  /// Orden de respaldo: Poseidon/Cuevana → PelisFlix → última copia buena
  /// vista en este teléfono → catálogo empaquetado. Así la pestaña nunca
  /// queda vacía por culpa de una red que no deja salir.
  Future<List<VodItem>> getMovies({int page = 1, String? genre}) async {
    await _cargarRespaldos();
    final cacheKey = '$page-${genre ?? "all"}';
    if (_moviePageCache.containsKey(cacheKey)) {
      return _moviePageCache[cacheKey]!;
    }

    if (genre == 'clasicos') {
      const pageSize = 24;
      final start = (page - 1) * pageSize;
      final slice = (start < _masterMovies.length)
          ? _masterMovies.skip(start).take(pageSize).toList()
          : <VodItem>[];
      if (slice.isNotEmpty) _moviePageCache[cacheKey] = slice;
      return slice;
    }

    var falloDeRed = false;
    List<VodItem> primary = [];
    try {
      primary = await _poseidon.fetchMovies(page: page, genre: genre);
    } catch (_) {
      falloDeRed = true;
    }

    if (primary.isEmpty && genre != 'tendencias') {
      try {
        primary = await _pelisflix.fetchMovies(page: page, genre: genre);
      } catch (_) {
        falloDeRed = true;
      }
    }

    List<VodItem> combined = [...primary];
    if (combined.isEmpty && page == 1 && _copiaMovies.isNotEmpty) {
      combined = List.of(_copiaMovies);
    }
    if (combined.isEmpty) {
      var pool = _masterMovies;
      if (genre != null && genre.isNotEmpty && genre != 'all') {
        final gLower = genre.toLowerCase();
        final filtrado = _masterMovies
            .where((m) =>
                m.genre.toLowerCase().contains(gLower) ||
                m.overview.toLowerCase().contains(gLower))
            .toList();
        // Si la categoría no existe en el catálogo empaquetado se muestra el
        // completo: una pestaña vacía confunde más que un género aproximado.
        pool = filtrado.isNotEmpty ? filtrado : _masterMovies;
      }
      const pageSize = 20;
      final start = (page - 1) * pageSize;
      if (start < pool.length) {
        combined = pool.skip(start).take(pageSize).toList();
      }
    }

    final unique = _dedupeByTitle(combined);
    // La bandera honesta es «la red no trajo títulos», aunque un respaldo
    // local haya llenado la pestaña: así el aviso nunca miente.
    ultimoErrorDeRed = primary.isEmpty;
    if (unique.isEmpty) return unique; // vacío: el próximo toque reintentará
    if (page == 1 && !falloDeRed && primary.isNotEmpty) {
      _guardarCopia('peliculas', primary);
    }
    _moviePageCache[cacheKey] = unique;
    return unique;
  }

  /// Carga series verificadas con paginación infinita y categorías:
  /// - `populares` (por defecto): SeriesKao populares (Breaking Bad, TWD, Dexter,
  ///   Rick y Morty, Los Simpson, etc. — 100% multi-episodio verificado).
  /// - `recientes`: SeriesKao últimos capítulos agregados.
  /// - `estrenos`: PoseidonHD2 / Cuevana3 (con respaldo a SeriesKao y PelisFlix).
  Future<List<VodItem>> getSeries({
    int page = 1,
    String category = 'populares',
  }) async {
    await _cargarRespaldos();
    final cacheKey = '$page-$category';
    if (_seriesPageCache.containsKey(cacheKey)) {
      return _seriesPageCache[cacheKey]!;
    }

    var falloDeRed = false;
    List<VodItem> primary = [];
    if (category == 'estrenos') {
      try {
        primary = await _poseidon.fetchSeries(page: page);
      } catch (_) {}
      if (primary.isEmpty) {
        try {
          primary = await _serieskao.fetchLatestSeries(page: page);
        } catch (_) {}
      }
    } else if (category == 'recientes') {
      try {
        primary = await _serieskao.fetchLatestSeries(page: page);
      } catch (_) {}
      if (primary.isEmpty) {
        try {
          primary = await _poseidon.fetchSeries(page: page);
        } catch (_) {}
      }
    } else {
      // 'populares': catálogo más sólido con todos los capítulos vivos
      try {
        primary = await _serieskao.fetchPopularSeries(page: page);
      } catch (_) {}
      if (primary.isEmpty) {
        try {
          primary = await _poseidon.fetchSeries(page: page);
        } catch (_) {}
      }
    }

    if (primary.isEmpty) {
      try {
        primary = await _pelisflix.fetchSeries(page: page);
      } catch (_) {
        falloDeRed = true;
      }
    }

    // Respaldos locales: primero la última copia buena vista en el teléfono
    // (trae portadas reales y ya cacheadas) y al final el empaquetado.
    final masterSlice = primary.isEmpty && page == 1
        ? (_copiaSeries.isNotEmpty ? _copiaSeries : _masterSeries)
        : <VodItem>[];
    final deduped = _dedupeByTitle([...primary, ...masterSlice]);
    final healthy = _health.filterAndRankSeries(deduped);
    ultimoErrorDeRed = primary.isEmpty;
    if (healthy.isEmpty) return healthy; // vacío: se reintenta al tocar
    if (page == 1 && !falloDeRed && primary.isNotEmpty) {
      _guardarCopia('series', primary);
    }
    _seriesPageCache[cacheKey] = healthy;
    return healthy;
  }

  /// Carga animes con paginación infinita y filtro por género desde JKAnime
  /// (portadas HD), con respaldo en la última copia buena y en el catálogo
  /// empaquetado: antes, si jkanime no respondía, la pestaña quedaba en cero.
  Future<List<VodItem>> getAnime({int page = 1, String? genre}) async {
    await _cargarRespaldos();
    final key = '$page-${genre ?? "all"}';
    if (_animePageCache.containsKey(key)) {
      return _animePageCache[key]!;
    }

    var falloDeRed = false;
    List<VodItem> list = [];
    try {
      list = await _jkanime.fetchDirectory(page: page, genre: genre);
    } catch (_) {
      falloDeRed = true;
    }
    final vinoDeRed = list.isNotEmpty;

    if (list.isEmpty && page == 1 && _copiaAnime.isNotEmpty) {
      list = List.of(_copiaAnime);
    }
    if (list.isEmpty) {
      var pool = _masterAnime;
      if (genre != null && genre.isNotEmpty && genre != 'all') {
        final gLower = genre.toLowerCase();
        final filtrado = pool
            .where((a) =>
                a.genre.toLowerCase().contains(gLower) ||
                a.overview.toLowerCase().contains(gLower))
            .toList();
        pool = filtrado.isNotEmpty ? filtrado : pool;
      }
      const pageSize = 20;
      final start = (page - 1) * pageSize;
      if (start < pool.length) {
        list = pool.skip(start).take(pageSize).toList();
      }
    }

    ultimoErrorDeRed = !vinoDeRed;
    if (list.isEmpty) return list; // vacío: se reintenta al tocar
    if (page == 1 && !falloDeRed) _guardarCopia('anime', list);
    _animePageCache[key] = list;
    return list;
  }

  /// Enriquecimiento de ficha de detalle (sinopsis real en español + episodios).
  Future<VodItem> enrichDetail(VodItem item) async {
    try {
      if (item.provider == 'serieskao') {
        final enriched = await _serieskao.fetchDetail(item);
        if (enriched != null) return item.mergedWith(enriched);
      } else if (item.provider == 'poseidon') {
        final enriched = await _poseidon.fetchDetail(item);
        if (enriched != null) return item.mergedWith(enriched);
      } else if (item.isAnime || item.provider == 'jkanime') {
        if (item.overview.isEmpty ||
            item.overview.startsWith('Estado:') ||
            item.poster.contains('/thumbnail/')) {
          final meta = await _jkanime.fetchAnimeMetaDetails(item.slug);
          return item.mergedWith(VodItem(
            id: item.id,
            title: item.title,
            poster: meta.poster,
            backdrop: meta.poster,
            overview: meta.overview,
          ));
        }
      }
    } catch (_) {}
    return item;
  }

  /// Búsqueda unificada en tiempo real sobre SeriesKao + PoseidonHD2 + JKAnime + PelisFlix + Local.
  Future<List<VodItem>> search(String query) async {
    final q = query.trim();
    if (q.isEmpty) return [];

    final qNorm = StreamValidator.normalizeTitle(q);
    final tokens =
        qNorm.split(RegExp(r'\s+')).where((t) => t.length >= 2).toList();

    final localMatches = [..._masterMovies, ..._masterSeries].where((item) {
      final hay = StreamValidator.normalizeTitle(item.title);
      return hay.contains(qNorm) ||
          (tokens.isNotEmpty && tokens.every((t) => hay.contains(t)));
    }).toList();

    final remoteResults = await Future.wait([
      _serieskao.searchSeries(q),
      _poseidon.search(q),
      _jkanime.search(q),
      _pelisflix.search(q),
    ]);

    final all = <VodItem>[
      ...remoteResults[0], // SeriesKao (Series exactas primero!)
      ...remoteResults[1], // Poseidon/Cuevana (Películas + Series TMDB HD)
      ...remoteResults[2], // JKAnime (HD)
      ...remoteResults[3], // PelisFlix respaldo
      ...localMatches,
    ];

    final unique = _dedupeByTitle(all);

    int score(VodItem v) {
      final t = StreamValidator.normalizeTitle(v.title);
      final providerBonus =
          (v.provider == 'serieskao' && v.isSeries) ||
                  (v.provider == 'poseidon' && !v.isSeries)
              ? 0
              : 1;
      if (t == qNorm) return 0 + providerBonus;
      if (t.startsWith(qNorm)) return 2 + providerBonus;
      if (t.contains(qNorm)) return 4 + providerBonus;
      if (tokens.isNotEmpty && tokens.every((tk) => t.contains(tk))) {
        return 6 + providerBonus;
      }
      return 8 + providerBonus;
    }

    unique.sort((a, b) => score(a).compareTo(score(b)));
    return unique;
  }

  Future<List<VodItem>> searchMovies(String query) async {
    final q = query.trim();
    if (q.isEmpty) return [];
    final qNorm = StreamValidator.normalizeTitle(q);

    final localMatches = _masterMovies
        .where((m) => StreamValidator.normalizeTitle(m.title).contains(qNorm))
        .toList();

    final results = await Future.wait([
      _poseidon.search(q),
      _pelisflix.search(q),
    ]);

    final movies = [
      ...results[0].where((it) => !it.isSeries && !it.isAnime),
      ...results[1].where((it) => !it.isSeries && !it.isAnime),
      ...localMatches,
    ];
    return _dedupeByTitle(movies);
  }

  Future<List<VodItem>> searchSeries(String query) async {
    final q = query.trim();
    if (q.isEmpty) return [];
    final qNorm = StreamValidator.normalizeTitle(q);

    final localMatches = _masterSeries
        .where((s) => StreamValidator.normalizeTitle(s.title).contains(qNorm))
        .toList();

    final results = await Future.wait([
      _serieskao.searchSeries(q),
      _poseidon.search(q),
      _pelisflix.search(q),
    ]);

    final series = [
      ...results[0],
      ...results[1].where((it) => it.isSeries && !it.isAnime),
      ...results[2].where((it) => it.isSeries && !it.isAnime),
      ...localMatches,
    ];
    return _health.filterAndRankSeries(_dedupeByTitle(series));
  }

  Future<List<VodItem>> searchAnime(String query) async {
    final q = query.trim();
    if (q.isEmpty) return [];
    return _jkanime.search(q);
  }

  /// Carga episodios completos de cualquier serie o anime.
  Future<List<VodEpisode>> fetchEpisodes(VodItem item) async {
    if (item.episodes.isNotEmpty) return item.episodes;

    if (item.provider == 'jkanime' || item.isAnime) {
      final slug = item.slug.isNotEmpty ? item.slug : item.id.replaceAll('jk_', '');
      return _jkanime.fetchEpisodes(slug);
    }

    if (item.provider == 'serieskao') {
      final eps = await _serieskao.fetchSeriesEpisodes(item);
      if (eps.isNotEmpty) return eps;
    }

    if (item.provider == 'poseidon') {
      final eps = await _poseidon.fetchSeriesEpisodes(item);
      if (eps.isNotEmpty) return eps;
    }

    if (item.provider == 'pelisflix' || item.isSeries) {
      final slug = item.slug.isNotEmpty
          ? item.slug
          : item.id.replaceAll('pf_serie_', '').replaceAll('pf_pelicula_', '');
      final eps = await _pelisflix.fetchSeriesEpisodes(slug);
      if (eps.isNotEmpty) return eps;
    }

    return [];
  }

  /// Resuelve TODAS las fuentes de reproducción VALIDADAS con failover automático
  /// a nivel de episodio entre TODOS los proveedores:
  /// - Series: `SeriesKao` <-> `PoseidonHD2` <-> `PelisFlix`
  /// - Películas: `PoseidonHD2` <-> `PelisFlix`
  /// - Anime: `JKAnime` <-> `TioAnime`
  Future<List<StreamSource>> resolveAllPlaybackSources(
    VodItem item, [
    VodEpisode? episode,
    void Function(String status)? onStatus,
  ]) async {
    final sw = Stopwatch()..start();

    // 1. Fuentes directas precargadas (clásicos / direct MP4)
    if (episode != null && episode.sources.isNotEmpty) {
      final valid =
          episode.sources.where((s) => !s.url.contains('pluto.tv')).toList();
      if (valid.isNotEmpty) {
        onStatus?.call('Enlace directo verificado...');
        return valid;
      }
    }
    if (episode == null && item.sources.isNotEmpty) {
      final valid =
          item.sources.where((s) => !s.url.contains('pluto.tv')).toList();
      if (valid.isNotEmpty) {
        onStatus?.call('Enlace directo verificado...');
        return valid;
      }
    }

    // 2. Anime: JKAnime (HLS validado) -> respaldo TioAnime (YourUpload MP4)
    if (item.isAnime || item.provider == 'jkanime') {
      final epNum = episode?.episodeNumber ?? 1;
      final animeSlug =
          item.slug.isNotEmpty ? item.slug : item.id.replaceAll('jk_', '');
      final sources = await _jkanime.getEpisodeSources(
        animeSlug,
        epNum,
        onStatus: onStatus,
      );
      if (sources.isNotEmpty) return sources;

      final tioBackup = await _tioanime.resolveEpisodeFallback(
        item.title,
        epNum,
        onStatus: onStatus,
      );
      if (tioBackup.isNotEmpty) return tioBackup;
    }

    // 3. SeriesKao (Primario de Series) -> failover automático por episodio a PoseidonHD2!
    if (item.provider == 'serieskao' && episode != null) {
      final skSources = await _serieskao.resolveEpisodeSources(
        item,
        episode,
        onStatus: onStatus,
      );
      if (skSources.isNotEmpty) {
        _health.recordSuccess(item.title, latencyMs: sw.elapsedMilliseconds);
        return skSources;
      }

      // Cross-provider failover hacia PoseidonHD2 para este episodio exacto
      onStatus?.call(
        'Probando servidor alterno para "${item.title}" T${episode.seasonNumber}·E${episode.episodeNumber}...',
      );
      final cpHits = await _poseidon.search(item.title);
      final match = _pickBestMatch(cpHits, item.title, isSeries: true);
      if (match != null) {
        final cpSources = await _poseidon.resolveAllStreamSources(
          match,
          episode: episode,
          onStatus: onStatus,
        );
        if (cpSources.isNotEmpty) {
          _health.recordSuccess(item.title, latencyMs: sw.elapsedMilliseconds);
          return cpSources;
        }
      }

      _health.recordFailure(item.title);
      return [];
    }

    // 4. PoseidonHD2 / Cuevana3 -> failover automático a SeriesKao (series) o PelisFlix (cine)!
    if (item.provider == 'poseidon') {
      final cpSources = await _poseidon.resolveAllStreamSources(
        item,
        episode: episode,
        onStatus: onStatus,
      );
      if (cpSources.isNotEmpty) {
        if (item.isSeries) {
          _health.recordSuccess(item.title, latencyMs: sw.elapsedMilliseconds);
        }
        return cpSources;
      }

      // Cross-provider failover para SERIES (Ep 1, 2, 3...) -> SeriesKao!
      if (item.isSeries && episode != null) {
        final skBackup = await _serieskao.resolveByTitleAndEpisode(
          item.title,
          episode.seasonNumber,
          episode.episodeNumber,
          onStatus: onStatus,
        );
        if (skBackup.isNotEmpty) {
          _health.recordSuccess(item.title, latencyMs: sw.elapsedMilliseconds);
          return skBackup;
        }
        _health.recordFailure(item.title);
        return [];
      }

      // Cross-provider failover para PELÍCULAS -> PelisFlix
      if (!item.isSeries) {
        onStatus?.call('Buscando servidor alterno...');
        final pfHits = await _pelisflix.search(item.title);
        final match = _pickBestMatch(pfHits, item.title, isSeries: false);
        if (match != null) {
          final pfSources = await _pelisflix.resolveAllStreamSources(
            match.slug,
            onStatus: onStatus,
          );
          if (pfSources.isNotEmpty) return pfSources;
        }
      }
      return [];
    }

    // 5. PelisFlix -> si está caído, failover automático a SeriesKao (series) / PoseidonHD2!
    final targetUrl = (episode != null && episode.id.startsWith('http'))
        ? episode.id
        : (item.slug.isNotEmpty
            ? item.slug
            : item.id
                .replaceAll('pf_pelicula_', '')
                .replaceAll('pf_serie_', ''));

    final pfSources = await _pelisflix.resolveAllStreamSources(
      targetUrl,
      onStatus: onStatus,
    );
    if (pfSources.isNotEmpty) {
      if (item.isSeries) {
        _health.recordSuccess(item.title, latencyMs: sw.elapsedMilliseconds);
      }
      return pfSources;
    }

    if (item.isSeries && episode != null) {
      final skBackup = await _serieskao.resolveByTitleAndEpisode(
        item.title,
        episode.seasonNumber,
        episode.episodeNumber,
        onStatus: onStatus,
      );
      if (skBackup.isNotEmpty) {
        _health.recordSuccess(item.title, latencyMs: sw.elapsedMilliseconds);
        return skBackup;
      }
    }

    onStatus?.call('Probando servidor alterno HD...');
    final cpHits = await _poseidon.search(item.title);
    final match = _pickBestMatch(cpHits, item.title, isSeries: item.isSeries);
    if (match != null) {
      final cpRes = await _poseidon.resolveAllStreamSources(
        match,
        episode: episode,
        onStatus: onStatus,
      );
      if (cpRes.isNotEmpty && item.isSeries) {
        _health.recordSuccess(item.title, latencyMs: sw.elapsedMilliseconds);
      }
      return cpRes;
    }

    if (item.isSeries) _health.recordFailure(item.title);
    return [];
  }

  Future<StreamSource?> resolvePlaybackSource(
    VodItem item, [
    VodEpisode? episode,
  ]) async {
    final all = await resolveAllPlaybackSources(item, episode);
    return all.isNotEmpty ? all.first : null;
  }

  static List<VodItem> _dedupeByTitle(List<VodItem> items) {
    final out = <VodItem>[];
    final seen = <String>{};
    for (final it in items) {
      if (it.poster.contains('404x.jpg')) continue;
      final norm = StreamValidator.normalizeTitle(it.title);
      final key =
          '${it.isAnime ? "a" : (it.isSeries ? "s" : "m")}_${norm.isNotEmpty ? norm : it.id}';
      if (seen.add(key)) {
        out.add(it);
      }
    }
    return out;
  }

  static VodItem? _pickBestMatch(
    List<VodItem> candidates,
    String targetTitle, {
    required bool isSeries,
  }) {
    if (candidates.isEmpty) return null;
    final normTarget = StreamValidator.normalizeTitle(targetTitle);
    final filtered =
        candidates.where((c) => c.isSeries == isSeries).toList();
    final pool = filtered.isNotEmpty ? filtered : candidates;
    for (final c in pool) {
      if (StreamValidator.normalizeTitle(c.title) == normTarget) return c;
    }
    for (final c in pool) {
      final nt = StreamValidator.normalizeTitle(c.title);
      if (nt.contains(normTarget) || normTarget.contains(nt)) return c;
    }
    return null;
  }
}
