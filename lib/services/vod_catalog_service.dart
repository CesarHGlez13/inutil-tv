import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

import '../models/models.dart';
import 'audio_language_priority.dart';
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

  /// Still TMDB real por título y capítulo (`"<T>x<E>" -> url w300`), tomado del
  /// proveedor alterno que sí publica imagen por episodio. Evita recuadros
  /// negros en fichas de Series/Anime cuyos episodios llegan sin miniatura.
  final Map<String, Map<String, String>> _stillsByTitle = {};

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
    if (category.startsWith('gen:')) {
      // Categorías de género de SeriesKao (slugs medidos en vivo: 200 OK,
      // 24 tarjetas/pág en todas las que expone la app).
      try {
        primary = await _serieskao
            .fetchGenreSeries(category.substring(4), page: page);
      } catch (_) {}
    } else if (category == 'tendencias') {
      try {
        primary = await _poseidon.fetchSeries(page: page, section: 'tendencias');
      } catch (_) {}
      if (primary.isEmpty) {
        try {
          primary = await _serieskao.fetchPopularSeries(page: page);
        } catch (_) {}
      }
    } else if (category == 'estrenos') {
      try {
        primary = await _poseidon.fetchSeries(page: page, section: 'estrenos');
      } catch (_) {}
      if (primary.isEmpty) {
        try {
          primary = await _poseidon.fetchSeries(page: page);
        } catch (_) {}
      }
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
    final deduped = _dedupeGroupedByShow([...primary, ...masterSlice],
        reset: page == 1, stream: 'series');
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
      if (genre == 'sk:populares') {
        list = await _serieskao.fetchPopularAnimes(page: page);
      } else if (genre == 'sk:recientes') {
        list = await _serieskao.fetchLatestAnimes(page: page);
      } else if (genre == 'tio:populares') {
        list = await _tioanime.fetchDirectory(page: page);
      } else {
        list = await _jkanime.fetchDirectory(page: page, genre: genre);
      }
    } catch (_) {
      falloDeRed = true;
    }

    // Failover automático entre proveedores sólidos de anime cuando el primario falla
    if (list.isEmpty && (genre == null || genre.isEmpty)) {
      try {
        list = await _serieskao.fetchPopularAnimes(page: page);
      } catch (_) {}
      if (list.isEmpty) {
        try {
          list = await _tioanime.fetchDirectory(page: page);
        } catch (_) {}
      }
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
    list = _dedupeGroupedByShow(list, reset: page == 1, stream: 'anime');
    if (list.isEmpty) return list; // vacío: se reintenta al tocar
    if (page == 1 && !falloDeRed) _guardarCopia('anime', list);
    _animePageCache[key] = list;
    return list;
  }

  /// Enriquecimiento de ficha de detalle (sinopsis real en español + temporadas + episodios).
  Future<VodItem> enrichDetail(VodItem item) async {
    try {
      if (item.provider == 'serieskao') {
        final enriched = await _serieskao.fetchDetail(item);
        if (enriched != null) {
          await _crossFillEpisodeStills(enriched, enriched.episodes);
          return item.mergedWith(enriched);
        }
      } else if (item.provider == 'poseidon') {
        final enriched = await _poseidon.fetchDetail(item);
        if (enriched != null) return item.mergedWith(enriched);
      } else if (item.provider == 'jkanime' ||
          (item.isAnime && item.provider != 'tioanime')) {
        final slug =
            item.slug.isNotEmpty ? item.slug : item.id.replaceAll('jk_', '');
        final needsMeta = item.overview.isEmpty ||
            item.overview.startsWith('Estado:') ||
            item.poster.contains('/thumbnail/');
        final results = await Future.wait([
          if (needsMeta)
            _jkanime.fetchAnimeMetaDetails(slug)
          else
            Future.value((overview: item.overview, poster: item.poster)),
          _jkanime.discoverSeasonChain(
            slug,
            fallbackTitle: item.title,
            seedRefs: item.seasonRefs,
          ),
        ]);
        final meta = results[0] as ({String overview, String poster});
        final chain = results[1] as List<VodSeasonRef>;
        return item.mergedWith(VodItem(
          id: item.id,
          title: item.title,
          poster: meta.poster,
          backdrop: meta.poster,
          overview: meta.overview,
          seasonCount: chain.length > 1 ? chain.length : item.seasonCount,
          seasonRefs: chain,
        ));
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
      _serieskao.searchAnimes(q),
      _poseidon.search(q),
      _jkanime.search(q),
      _tioanime.search(q),
      _pelisflix.search(q),
    ]);

    final all = <VodItem>[
      ...remoteResults[0], // SeriesKao (Series exactas primero!)
      ...remoteResults[1], // SeriesKao Animes (Latino + todas las temporadas!)
      ...remoteResults[2], // Poseidon/Cuevana (Películas + Series TMDB HD)
      ...remoteResults[3], // JKAnime (HD)
      ...remoteResults[4], // TioAnime (respaldo sólido)
      ...remoteResults[5], // PelisFlix respaldo
      ...localMatches,
    ];

    final unique = groupByShowStateless(all);

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
    return _health.filterAndRankSeries(groupByShowStateless(series));
  }

  Future<List<VodItem>> searchAnime(String query) async {
    final q = query.trim();
    if (q.isEmpty) return [];
    final results = await Future.wait([
      _jkanime.search(q),
      _serieskao.searchAnimes(q),
      _tioanime.search(q),
    ]);
    final combined = <VodItem>[
      ...results[0],
      ...results[1],
      ...results[2],
    ];
    return groupByShowStateless(combined);
  }

  /// Carga episodios completos de cualquier serie o anime.
  /// - Anime JKAnime: descubre toda la cadena de temporadas (Precuela/Secuela)
  ///   y carga sus capítulos en paralelo etiquetando cada temporada (T1, T2...).
  /// - Series (SeriesKao / PoseidonHD2): si el primario devuelve pocos capítulos
  ///   o solo 1 temporada, consulta al proveedor complementario y UNE los
  ///   capítulos/temporadas faltantes (sin duplicar temporada#episodio).
  Future<List<VodEpisode>> fetchEpisodes(VodItem item) async {
    final eps = await _fetchEpisodesRaw(item);
    if (eps.isNotEmpty) await _crossFillEpisodeStills(item, eps);
    return eps;
  }

  /// Rellena EN SITIO las miniaturas (y la duración) de los episodios que su
  /// proveedor no publica, usando los stills TMDB reales del espejo PoseidonHD2.
  /// Solo se tocan `thumbnail`/`duration`: `provider` y `slug` se conservan
  /// porque la resolución de fuentes por episodio depende de ellos.
  Future<void> _crossFillEpisodeStills(
    VodItem item,
    List<VodEpisode> eps,
  ) async {
    final missing = eps.where((e) => e.thumbnail.isEmpty).toList();
    if (missing.isEmpty) return;
    // PoseidonHD2 es la fuente de stills; si a él le faltan, nadie los tiene.
    if (item.provider == 'poseidon') return;

    final key = StreamValidator.normalizeTitle(item.title);
    final map = _stillsByTitle[key] ??
        await _poseidon.fetchStillsMapForTitle(
          item.title,
          isSeries: item.isSeries,
        );
    _stillsByTitle[key] = map;
    if (map.isEmpty) return;

    for (var i = 0; i < eps.length; i++) {
      final e = eps[i];
      if (e.thumbnail.isNotEmpty) continue;
      final thumb = map['${e.seasonNumber}x${e.episodeNumber}'];
      if (thumb == null || thumb.isEmpty) continue;
      eps[i] = VodEpisode(
        id: e.id,
        title: e.title,
        episodeNumber: e.episodeNumber,
        seasonNumber: e.seasonNumber,
        overview: e.overview,
        duration: e.duration,
        thumbnail: thumb,
        sources: e.sources,
        slug: e.slug,
        provider: e.provider,
      );
    }
  }

  Future<List<VodEpisode>> _fetchEpisodesRaw(VodItem item) async {
    if (item.episodes.isNotEmpty) return item.episodes;

    // 1. Anime en SeriesKao (Latino + multi-temporada nativa) -> respaldo JKAnime/TioAnime
    if (item.provider == 'serieskao' && item.isAnime) {
      final eps = await _serieskao.fetchSeriesEpisodes(item);
      if (eps.isNotEmpty) return eps;
      final jkHits = await _jkanime.search(item.title);
      final jkMatch = _pickBestMatch(jkHits, item.title, isSeries: true);
      if (jkMatch != null) {
        final chain = await _jkanime.discoverSeasonChain(
          jkMatch.slug,
          fallbackTitle: jkMatch.title,
        );
        final jkEps = chain.length > 1
            ? await _jkanime.fetchAllSeasonsEpisodes(chain)
            : await _jkanime.fetchEpisodes(jkMatch.slug);
        if (jkEps.isNotEmpty) return jkEps;
      }
      return [];
    }

    // 2. Anime en TioAnime -> respaldo JKAnime
    if (item.provider == 'tioanime') {
      final eps = await _tioanime.fetchEpisodes(item.slug);
      if (eps.isNotEmpty) return eps;
      final jkHits = await _jkanime.search(item.title);
      final jkMatch = _pickBestMatch(jkHits, item.title, isSeries: true);
      if (jkMatch != null) {
        return _jkanime.fetchEpisodes(jkMatch.slug);
      }
      return [];
    }

    // 3. Anime en JKAnime: agrupar TODAS las temporadas de la cadena en la misma ficha
    if (item.provider == 'jkanime' || item.isAnime) {
      final slug =
          item.slug.isNotEmpty ? item.slug : item.id.replaceAll('jk_', '');
      final chain = await _jkanime.discoverSeasonChain(
        slug,
        fallbackTitle: item.title,
        seedRefs: item.seasonRefs,
      );
      List<VodEpisode> eps = chain.length > 1
          ? await _jkanime.fetchAllSeasonsEpisodes(chain)
          : await _jkanime.fetchEpisodes(slug);

      // Si JKAnime falló o trajo incompleto, intentar SeriesKao Animes / TioAnime
      if (eps.isEmpty) {
        final skHits = await _serieskao.searchAnimes(item.title);
        final skMatch = _pickBestMatch(skHits, item.title, isSeries: true);
        if (skMatch != null) {
          eps = await _serieskao.fetchSeriesEpisodes(skMatch);
        }
      }
      if (eps.isEmpty) {
        final tioHits = await _tioanime.search(item.title);
        final tioMatch = _pickBestMatch(tioHits, item.title, isSeries: true);
        if (tioMatch != null) {
          eps = await _tioanime.fetchEpisodes(tioMatch.slug);
        }
      }
      return eps;
    }

    // 4. Series: SeriesKao con completado cruzado desde PoseidonHD2 para evitar capítulos faltantes
    if (item.provider == 'serieskao') {
      final eps = await _serieskao.fetchSeriesEpisodes(item);
      return _supplementSeriesEpisodes(item, eps, complement: 'poseidon');
    }

    // 5. Series: PoseidonHD2 con completado cruzado desde SeriesKao
    if (item.provider == 'poseidon') {
      final eps = await _poseidon.fetchSeriesEpisodes(item);
      return _supplementSeriesEpisodes(item, eps, complement: 'serieskao');
    }

    if (item.provider == 'pelisflix' || item.isSeries) {
      final slug = item.slug.isNotEmpty
          ? item.slug
          : item.id.replaceAll('pf_serie_', '').replaceAll('pf_pelicula_', '');
      final eps = await _pelisflix.fetchSeriesEpisodes(slug);
      if (eps.isNotEmpty) return eps;
      // Si PelisFlix está caído, buscar la serie en SeriesKao / PoseidonHD2
      return _supplementSeriesEpisodes(item, const [], complement: 'serieskao');
    }

    return [];
  }

  /// Completa temporadas/capítulos faltantes consultando el proveedor alterno
  /// cuando el primario quedó vacío o incompleto (<=1 temporada o <20 capítulos).
  Future<List<VodEpisode>> _supplementSeriesEpisodes(
    VodItem item,
    List<VodEpisode> primaryEps, {
    required String complement,
  }) async {
    final primarySeasons = primaryEps.map((e) => e.seasonNumber).toSet();
    final needsCheck = primaryEps.isEmpty ||
        primarySeasons.length <= 1 ||
        primaryEps.length < 20;
    if (!needsCheck) return primaryEps;

    try {
      List<VodEpisode> extra = const [];
      if (complement == 'poseidon') {
        final hits = await _poseidon
            .search(item.title)
            .timeout(const Duration(seconds: 7), onTimeout: () => []);
        final match = _pickBestMatch(hits, item.title, isSeries: true);
        if (match != null) {
          extra = await _poseidon
              .fetchSeriesEpisodes(match)
              .timeout(const Duration(seconds: 7), onTimeout: () => []);
        }
      } else {
        final hits = await _serieskao
            .searchSeries(item.title)
            .timeout(const Duration(seconds: 7), onTimeout: () => []);
        final match = _pickBestMatch(hits, item.title, isSeries: true);
        if (match != null) {
          extra = await _serieskao
              .fetchSeriesEpisodes(match)
              .timeout(const Duration(seconds: 7), onTimeout: () => []);
        }
      }

      if (extra.isEmpty) return primaryEps;
      if (primaryEps.isEmpty) return extra;

      // Unir conservando los del proveedor primario y llenando huecos con el alterno
      final merged = <VodEpisode>[...primaryEps];
      final seen = <String>{
        for (final e in primaryEps) '${e.seasonNumber}#${e.episodeNumber}',
      };
      for (final e in extra) {
        if (seen.add('${e.seasonNumber}#${e.episodeNumber}')) {
          merged.add(e);
        }
      }
      merged.sort((a, b) {
        final s = a.seasonNumber.compareTo(b.seasonNumber);
        return s != 0 ? s : a.episodeNumber.compareTo(b.episodeNumber);
      });
      return merged;
    } catch (_) {
      return primaryEps;
    }
  }

  /// Resuelve TODAS las fuentes de reproducción VALIDADAS con failover automático
  /// a nivel de episodio entre TODOS los proveedores:
  /// - Series: `SeriesKao` <-> `PoseidonHD2` <-> `PelisFlix`
  /// - Películas: `PoseidonHD2` <-> `PelisFlix`
  /// - Anime: `JKAnime` <-> `TioAnime`
  static List<StreamSource> _mergePrioritizedSources(
    List<StreamSource> primary,
    List<StreamSource> secondary, {
    required String desiredLang,
  }) {
    final seen = <String>{};
    final merged = <StreamSource>[];
    for (final s in [...primary, ...secondary]) {
      if (seen.add(s.url)) merged.add(s);
    }
    return AudioLanguagePriority.prioritizeSources(
      merged,
      desiredLang: desiredLang,
    );
  }

  Future<List<StreamSource>> resolveAllPlaybackSources(
    VodItem item, [
    VodEpisode? episode,
    void Function(String status)? onStatus,
    String? preferredAudioLang,
  ]) async {
    final sw = Stopwatch()..start();
    final desired = AudioLanguagePriority.resolveDesiredAudioLang(
      activeSessionLang: preferredAudioLang,
    );

    // 1. Fuentes directas precargadas (clásicos / direct MP4)
    if (episode != null && episode.sources.isNotEmpty) {
      final valid =
          episode.sources.where((s) => !s.url.contains('pluto.tv')).toList();
      if (valid.isNotEmpty) {
        onStatus?.call('Enlace directo verificado...');
        return AudioLanguagePriority.prioritizeSources(
          valid,
          desiredLang: desired,
        );
      }
    }
    if (episode == null && item.sources.isNotEmpty) {
      final valid =
          item.sources.where((s) => !s.url.contains('pluto.tv')).toList();
      if (valid.isNotEmpty) {
        onStatus?.call('Enlace directo verificado...');
        return AudioLanguagePriority.prioritizeSources(
          valid,
          desiredLang: desired,
        );
      }
    }

    // 2. Anime: respeta el proveedor real del episodio (SeriesKao Latino / JKAnime / TioAnime)
    if (item.isAnime ||
        item.provider == 'jkanime' ||
        item.provider == 'tioanime' ||
        episode?.provider == 'jkanime' ||
        episode?.provider == 'tioanime') {
      final epNum = episode?.episodeNumber ?? 1;

      // 2a. Anime de SeriesKao (Audio Latino + Embed69 HD) -> failover a JKAnime / TioAnime
      if ((item.provider == 'serieskao' || episode?.provider == 'serieskao') &&
          episode != null) {
        final skSources = await _serieskao.resolveEpisodeSources(
          item,
          episode,
          onStatus: onStatus,
          preferredAudioLang: desired,
        );
        if (skSources.isNotEmpty) {
          return AudioLanguagePriority.prioritizeSources(
            skSources,
            desiredLang: desired,
          );
        }
      }

      // 2b. Episodio específico de TioAnime -> probar TioAnime primero
      if (episode?.provider == 'tioanime' || item.provider == 'tioanime') {
        final tioSlug = (episode != null && episode.slug.contains('/'))
            ? episode.slug.split('/').first
            : (item.slug.isNotEmpty ? item.slug : item.title);
        final tioSources = await _tioanime.resolveEpisodeFallback(
          tioSlug,
          epNum,
          onStatus: onStatus,
        );
        if (tioSources.isNotEmpty) return tioSources;
      }

      // 2c. JKAnime: usar el slug de la TEMPORADA del episodio (`episode.slug`)
      // cuando exista (`kaijuu-8-gou-2nd-season/3`), no solo el slug base T1.
      final epSlugPrefix = (episode != null &&
              episode.provider == 'jkanime' &&
              episode.slug.contains('/'))
          ? episode.slug.split('/').first
          : '';
      final animeSlug = epSlugPrefix.isNotEmpty
          ? epSlugPrefix
          : (item.slug.isNotEmpty ? item.slug : item.id.replaceAll('jk_', ''));
      if (animeSlug.isNotEmpty) {
        final sources = await _jkanime.getEpisodeSources(
          animeSlug,
          epNum,
          onStatus: onStatus,
        );
        if (sources.isNotEmpty) return sources;
      }

      // 2d. Respaldo cruzado a TioAnime
      final tioBackup = await _tioanime.resolveEpisodeFallback(
        epSlugPrefix.isNotEmpty ? epSlugPrefix : item.title,
        epNum,
        onStatus: onStatus,
      );
      if (tioBackup.isNotEmpty) return tioBackup;
    }

    // 2.5. Si el episodio fue completado desde un proveedor alterno, respetarlo primero
    // (y si solo entregó un idioma distinto al deseado, rescatar Latino del otro proveedor).
    if (episode != null &&
        episode.provider == 'poseidon' &&
        item.provider != 'poseidon') {
      final cpHits = await _poseidon.search(item.title);
      final match = _pickBestMatch(cpHits, item.title, isSeries: true);
      if (match != null) {
        final cpSources = await _poseidon.resolveAllStreamSources(
          match,
          episode: episode,
          onStatus: onStatus,
          preferredAudioLang: desired,
        );
        if (cpSources.isNotEmpty) {
          if (AudioLanguagePriority.hasDesiredLanguage(
            cpSources,
            desiredLang: desired,
          )) {
            return AudioLanguagePriority.prioritizeSources(
              cpSources,
              desiredLang: desired,
            );
          }
          final skRescue = await _serieskao.resolveByTitleAndEpisode(
            item.title,
            episode.seasonNumber,
            episode.episodeNumber,
            onStatus: onStatus,
            preferredAudioLang: desired,
          );
          return _mergePrioritizedSources(
            skRescue,
            cpSources,
            desiredLang: desired,
          );
        }
      }
    } else if (episode != null &&
        episode.provider == 'serieskao' &&
        item.provider != 'serieskao') {
      final skSources = await _serieskao.resolveByTitleAndEpisode(
        item.title,
        episode.seasonNumber,
        episode.episodeNumber,
        onStatus: onStatus,
        preferredAudioLang: desired,
      );
      if (skSources.isNotEmpty) {
        if (AudioLanguagePriority.hasDesiredLanguage(
          skSources,
          desiredLang: desired,
        )) {
          return AudioLanguagePriority.prioritizeSources(
            skSources,
            desiredLang: desired,
          );
        }
        final cpHits = await _poseidon.search(item.title);
        final match = _pickBestMatch(cpHits, item.title, isSeries: true);
        if (match != null) {
          final cpRescue = await _poseidon.resolveAllStreamSources(
            match,
            episode: episode,
            onStatus: onStatus,
            preferredAudioLang: desired,
          );
          if (cpRescue.isNotEmpty) {
            return _mergePrioritizedSources(
              cpRescue,
              skSources,
              desiredLang: desired,
            );
          }
        }
        return AudioLanguagePriority.prioritizeSources(
          skSources,
          desiredLang: desired,
        );
      }
    }

    // 3. SeriesKao (Primario de Series) -> failover automático por episodio a PoseidonHD2!
    if (item.provider == 'serieskao' && episode != null) {
      final skSources = await _serieskao.resolveEpisodeSources(
        item,
        episode,
        onStatus: onStatus,
        preferredAudioLang: desired,
      );
      if (skSources.isNotEmpty &&
          AudioLanguagePriority.hasDesiredLanguage(
            skSources,
            desiredLang: desired,
          )) {
        _health.recordSuccess(item.title, latencyMs: sw.elapsedMilliseconds);
        return AudioLanguagePriority.prioritizeSources(
          skSources,
          desiredLang: desired,
        );
      }

      // Cross-provider failover / rescate de idioma (p. ej. si SeriesKao solo
      // tuvo Subtitulado para este capítulo, buscar Latino en PoseidonHD2).
      onStatus?.call(
        skSources.isEmpty
            ? 'Probando servidor alterno para "${item.title}" T${episode.seasonNumber}·E${episode.episodeNumber}...'
            : 'Buscando audio preferido para T${episode.seasonNumber}·E${episode.episodeNumber}...',
      );
      final cpHits = await _poseidon.search(item.title);
      final match = _pickBestMatch(cpHits, item.title, isSeries: true);
      if (match != null) {
        final cpSources = await _poseidon.resolveAllStreamSources(
          match,
          episode: episode,
          onStatus: onStatus,
          preferredAudioLang: desired,
        );
        if (cpSources.isNotEmpty) {
          _health.recordSuccess(item.title, latencyMs: sw.elapsedMilliseconds);
          return _mergePrioritizedSources(
            cpSources,
            skSources,
            desiredLang: desired,
          );
        }
      }

      if (skSources.isNotEmpty) {
        _health.recordSuccess(item.title, latencyMs: sw.elapsedMilliseconds);
        return AudioLanguagePriority.prioritizeSources(
          skSources,
          desiredLang: desired,
        );
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
        preferredAudioLang: desired,
      );
      if (cpSources.isNotEmpty) {
        final hasPreferred = AudioLanguagePriority.hasDesiredLanguage(
          cpSources,
          desiredLang: desired,
        );
        if (hasPreferred || !item.isSeries || episode == null) {
          if (item.isSeries) {
            _health.recordSuccess(item.title, latencyMs: sw.elapsedMilliseconds);
          }
          return AudioLanguagePriority.prioritizeSources(
            cpSources,
            desiredLang: desired,
          );
        }

        // Poseidon solo encontró otro idioma (ej. Subtitulado): rescatar el
        // idioma preferido desde SeriesKao antes de caer a inglés.
        onStatus?.call(
          'Buscando audio preferido para T${episode.seasonNumber}·E${episode.episodeNumber}...',
        );
        final skRescue = await _serieskao.resolveByTitleAndEpisode(
          item.title,
          episode.seasonNumber,
          episode.episodeNumber,
          onStatus: onStatus,
          preferredAudioLang: desired,
        );
        _health.recordSuccess(item.title, latencyMs: sw.elapsedMilliseconds);
        return _mergePrioritizedSources(
          skRescue,
          cpSources,
          desiredLang: desired,
        );
      }

      // Cross-provider failover para SERIES (Ep 1, 2, 3...) -> SeriesKao!
      if (item.isSeries && episode != null) {
        final skBackup = await _serieskao.resolveByTitleAndEpisode(
          item.title,
          episode.seasonNumber,
          episode.episodeNumber,
          onStatus: onStatus,
          preferredAudioLang: desired,
        );
        if (skBackup.isNotEmpty) {
          _health.recordSuccess(item.title, latencyMs: sw.elapsedMilliseconds);
          return AudioLanguagePriority.prioritizeSources(
            skBackup,
            desiredLang: desired,
          );
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
          if (pfSources.isNotEmpty) {
            return AudioLanguagePriority.prioritizeSources(
              pfSources,
              desiredLang: desired,
            );
          }
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
      return AudioLanguagePriority.prioritizeSources(
        pfSources,
        desiredLang: desired,
      );
    }

    if (item.isSeries && episode != null) {
      final skBackup = await _serieskao.resolveByTitleAndEpisode(
        item.title,
        episode.seasonNumber,
        episode.episodeNumber,
        onStatus: onStatus,
        preferredAudioLang: desired,
      );
      if (skBackup.isNotEmpty) {
        _health.recordSuccess(item.title, latencyMs: sw.elapsedMilliseconds);
        return AudioLanguagePriority.prioritizeSources(
          skBackup,
          desiredLang: desired,
        );
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
        preferredAudioLang: desired,
      );
      if (cpRes.isNotEmpty && item.isSeries) {
        _health.recordSuccess(item.title, latencyMs: sw.elapsedMilliseconds);
      }
      return AudioLanguagePriority.prioritizeSources(
        cpRes,
        desiredLang: desired,
      );
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

  /// Resuelve fuentes desde proveedores ALTERNOS cuando el proveedor primario
  /// respondió con servidores saturados o cortados en mitad de la reproducción.
  Future<List<StreamSource>> resolveAlternativeProviderSources(
    VodItem item, [
    VodEpisode? episode,
    void Function(String status)? onStatus,
    String? preferredAudioLang,
  ]) async {
    final desired = AudioLanguagePriority.resolveDesiredAudioLang(
      activeSessionLang: preferredAudioLang,
    );
    try {
      if (item.isAnime) {
        final epNum = episode?.episodeNumber ?? 1;
        if (item.provider == 'jkanime') {
          final tio = await _tioanime.resolveEpisodeFallback(
            item.slug.isNotEmpty ? item.slug : item.title,
            epNum,
            onStatus: onStatus,
          );
          if (tio.isNotEmpty) return tio;
        }
        final cpHits = await _poseidon.search(item.title);
        final match =
            _pickBestMatch(cpHits, item.title, isSeries: item.isSeries);
        if (match != null) {
          final cpRes = await _poseidon.resolveAllStreamSources(
            match,
            episode: episode,
            onStatus: onStatus,
            preferredAudioLang: desired,
          );
          if (cpRes.isNotEmpty) {
            return AudioLanguagePriority.prioritizeSources(
              cpRes,
              desiredLang: desired,
            );
          }
        }
        return const [];
      }

      if (item.isSeries && episode != null) {
        if (item.provider == 'poseidon') {
          final sk = await _serieskao.resolveByTitleAndEpisode(
            item.title,
            episode.seasonNumber,
            episode.episodeNumber,
            onStatus: onStatus,
            preferredAudioLang: desired,
          );
          if (sk.isNotEmpty) {
            return AudioLanguagePriority.prioritizeSources(
              sk,
              desiredLang: desired,
            );
          }
        } else {
          final cpHits = await _poseidon.search(item.title);
          final match = _pickBestMatch(cpHits, item.title, isSeries: true);
          if (match != null) {
            final cpRes = await _poseidon.resolveAllStreamSources(
              match,
              episode: episode,
              onStatus: onStatus,
              preferredAudioLang: desired,
            );
            if (cpRes.isNotEmpty) {
              return AudioLanguagePriority.prioritizeSources(
                cpRes,
                desiredLang: desired,
              );
            }
          }
        }
        return const [];
      }

      // Películas: cruzar PoseidonHD2 <-> PelisFlix
      if (item.provider == 'poseidon') {
        final pfHits = await _pelisflix.search(item.title);
        final match = _pickBestMatch(pfHits, item.title, isSeries: false);
        if (match != null) {
          final pfRes = await _pelisflix.resolveAllStreamSources(
            match.slug,
            onStatus: onStatus,
          );
          if (pfRes.isNotEmpty) {
            return AudioLanguagePriority.prioritizeSources(
              pfRes,
              desiredLang: desired,
            );
          }
        }
      } else {
        final cpHits = await _poseidon.search(item.title);
        final match = _pickBestMatch(cpHits, item.title, isSeries: false);
        if (match != null) {
          final cpRes = await _poseidon.resolveAllStreamSources(
            match,
            onStatus: onStatus,
            preferredAudioLang: desired,
          );
          if (cpRes.isNotEmpty) {
            return AudioLanguagePriority.prioritizeSources(
              cpRes,
              desiredLang: desired,
            );
          }
        }
      }
    } catch (e) {
      debugPrint('[VodCatalog] resolveAlternativeProviderSources err: $e');
    }
    return const [];
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

  static final RegExp _reFinalSeason = RegExp(r'\b(?:the\s+)?final\s+season\b');
  static final RegExp _reOrdSeason = RegExp(r'\b(\d+)(?:st|nd|rd|th)\s+season\b');
  static final RegExp _reExplicitSeason =
      RegExp(r'\b(?:t|temporada|temp|season|s)\s*(\d+)\b');
  static final RegExp _rePartSeason = RegExp(r'\b(?:part|parte|cour)\s*(\d+)$');
  static final RegExp _reRomanSeason = RegExp(r'\s+(ii|iii|iv|v|vi)$');
  static final RegExp _reTrailingDigitSeason = RegExp(r'^(.+\s+\S+)\s+([2-9])$');

  static final RegExp _reCanonPrefix =
      RegExp(r'^(?:t|temporada|temp|season|serie|series?)\s+\d+\s+');
  static final RegExp _reCanonFinal = RegExp(
      r'\s+(?:the\s+)?final\s+season(?:\s+(?:part|parte|cour)\s*\d+)?$');
  static final RegExp _reCanonOrd = RegExp(
      r'\s+\d+(?:st|nd|rd|th)\s+season(?:\s+(?:part|parte|cour)\s*\d+)?$');
  static final RegExp _reCanonExplicit = RegExp(
      r'\s+(?:t|temporada|temp|season|s)\s*\d+(?:\s+(?:part|parte|cour)\s*\d+)?$');
  static final RegExp _reCanonPart = RegExp(r'\s+(?:part|parte|cour)\s*\d+$');
  static final RegExp _reCanonTv = RegExp(r'\s+tv$');
  static final RegExp _reCanonSpaces = RegExp(r'\s+');
  static final RegExp _reCanonRoman = RegExp(r'^(.{3,}?)\s+(?:ii|iii|iv|v|vi)$');
  static final RegExp _reCanonDigit = RegExp(r'^(\S+\s+.+?)\s+[2-9]$');

  /// Extrae el número de temporada implícito en un título de serie o anime
  /// ("2nd Season" -> 2, "Temporada 3" -> 3, "T4" -> 4, "Final Season" -> 99,
  ///  "Overlord III" -> 3, base sin sufijo -> 1).
  static int extractSeasonNumber(String title) {
    final norm = StreamValidator.normalizeTitle(title);
    if (norm.isEmpty) return 1;

    if (_reFinalSeason.hasMatch(norm)) return 99;

    final ord = _reOrdSeason.firstMatch(norm);
    if (ord != null) return int.tryParse(ord.group(1)!) ?? 1;

    final explicit = _reExplicitSeason.firstMatch(norm);
    if (explicit != null) return int.tryParse(explicit.group(1)!) ?? 1;

    final part = _rePartSeason.firstMatch(norm);
    if (part != null) return int.tryParse(part.group(1)!) ?? 1;

    final roman = _reRomanSeason.firstMatch(norm);
    if (roman != null && norm.length > roman.group(1)!.length + 3) {
      return switch (roman.group(1)) {
        'ii' => 2,
        'iii' => 3,
        'iv' => 4,
        'v' => 5,
        'vi' => 6,
        _ => 1,
      };
    }

    final trailingDigit = _reTrailingDigitSeason.firstMatch(norm);
    if (trailingDigit != null) {
      return int.tryParse(trailingDigit.group(2)!) ?? 1;
    }
    return 1;
  }

  /// Clave canónica para AGRUPAR temporadas: normaliza el título y le quita
  /// sufijos/prefijos de temporada ("T2", "Temporada 3", "Season 2", "S2",
  /// "2nd Season", "3rd Season", "Part 2", "The Final Season", "II/III/IV",
  /// o dígito final "2..9" en títulos multi-palabra) para que todas las
  /// temporadas del mismo show aparezcan en UNA sola tarjeta.
  /// Las películas conservan su título completo para no colapsar secuelas.
  static String canonicalShowKey(VodItem it) {
    final rawNorm = StreamValidator.normalizeTitle(it.title);
    final kind = it.isAnime ? 'a' : (it.isSeries ? 's' : 'm');
    if (!it.isSeries && !it.isAnime) {
      return '${kind}_${rawNorm.isNotEmpty ? rawNorm : it.id}';
    }

    var norm = rawNorm;
    // Repetir hasta 2 pasadas para limpiar compuestos como "Season 3 Part 2"
    for (var i = 0; i < 2; i++) {
      final before = norm;
      norm = norm
          .replaceFirst(_reCanonPrefix, ' ')
          .replaceFirst(_reCanonFinal, ' ')
          .replaceFirst(_reCanonOrd, ' ')
          .replaceFirst(_reCanonExplicit, ' ')
          .replaceFirst(_reCanonPart, ' ')
          .replaceFirst(_reCanonTv, ' ')
          .replaceAll(_reCanonSpaces, ' ')
          .trim();
      if (norm == before) break;
    }

    // Numerales romanos de temporada al final (II, III, IV, V, VI) si hay base >= 3 chars
    final romanMatch = _reCanonRoman.firstMatch(norm);
    if (romanMatch != null) {
      norm = romanMatch.group(1)!.trim();
    }

    // Dígito final de temporada (2..9) solo en títulos de >=2 palabras (ej. "5 toubun no hanayome 2")
    final digitMatch = _reCanonDigit.firstMatch(norm);
    if (digitMatch != null) {
      norm = digitMatch.group(1)!.trim();
    }

    if (norm.isEmpty) norm = rawNorm;
    return '${kind}_${norm.isNotEmpty ? norm : it.id}';
  }

  /// Agrupa una lista de resultados (búsquedas o rieles) sin estado global,
  /// eligiendo como base la temporada menor (T1) y conservando todas las
  /// temporadas hermanas dentro de `seasonRefs` + unión de episodios.
  static List<VodItem> groupByShowStateless(List<VodItem> items) {
    final out = <VodItem>[];
    final byKey = <String, int>{};
    for (final it in items) {
      if (it.poster.contains('404x.jpg')) continue;
      final key = canonicalShowKey(it);
      final idx = byKey[key];
      if (idx == null) {
        byKey[key] = out.length;
        out.add(it);
      } else {
        out[idx] = _mergeShowPair(out[idx], it);
      }
    }
    return out;
  }

  /// Fusiona dos entradas del mismo show eligiendo siempre como tarjeta base la
  /// de temporada más baja (p. ej. T1 sobre T2) y conservando todas las
  /// referencias de temporadas hermanas (`seasonRefs`) + episodios.
  static VodItem _mergeShowPair(VodItem a, VodItem b) {
    final sa = extractSeasonNumber(a.title);
    final sb = extractSeasonNumber(b.title);
    final bIsBetterBase = sb < sa ||
        (sb == sa && a.poster.isEmpty && b.poster.isNotEmpty);
    final base = bIsBetterBase ? b : a;
    final sibling = bIsBetterBase ? a : b;
    final baseSeason = bIsBetterBase ? sb : sa;
    final siblingSeason = bIsBetterBase ? sa : sb;
    return base.groupedWithSiblingItem(
      sibling,
      baseSeasonNumber: baseSeason,
      siblingSeasonNumber: siblingSeason,
    );
  }

  /// Estado global de agrupación entre páginas (se reinicia en page 1).
  /// Se nombrespacea por stream ('series'/'anime') para que el scroll
  /// infinito de una pestaña no se coma entradas de la otra.
  final Set<String> _vistosAgrupados = <String>{};

  /// Dedupe AGRUPANDO por show canónico: la primera entrada (o la de menor
  /// temporada en la página) es la base y conserva tanto episodios como
  /// referencias de slug de todas las temporadas hermanas (`seasonRefs`).
  /// [reset] limpia el estado de ese stream (llamar true solo en page 1).
  List<VodItem> _dedupeGroupedByShow(List<VodItem> items,
      {bool reset = false, String stream = 'default'}) {
    if (reset) _vistosAgrupados.removeWhere((k) => k.startsWith('$stream|'));
    final out = <VodItem>[];
    final byKey = <String, int>{}; // key -> índice en out
    for (final it in items) {
      if (it.poster.contains('404x.jpg')) continue;
      final key = canonicalShowKey(it);
      final namespaced = '$stream|$key';
      final idx = byKey[key];
      if (idx == null) {
        if (_vistosAgrupados.contains(namespaced)) continue; // ya mostrado
        _vistosAgrupados.add(namespaced);
        byKey[key] = out.length;
        out.add(it);
      } else {
        out[idx] = _mergeShowPair(out[idx], it);
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
