import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../models/models.dart';
import 'artwork_cache_service.dart';
import 'cuevana_poseidon_service.dart';
import 'jkanime_service.dart';
import 'live_tv_sync_service.dart';
import 'my_list_service.dart';
import 'pelisflix_service.dart';
import 'serieskao_service.dart';
import 'tv_taste_profile_service.dart';
import 'vod_catalog_service.dart' show VodCatalogService;
import 'watch_history.dart';

List<Channel> _parseChannelsInIsolate(String jsonStr) {
  final list = json.decode(jsonStr) as List;
  return [
    for (final item in list) Channel.fromJson(item as Map<String, dynamic>),
  ];
}

({List<VodItem> movies, List<VodItem> series}) _parseVodInIsolate(
  String jsonStr,
) {
  final vodList = json.decode(jsonStr) as List;
  final movies = <VodItem>[];
  final series = <VodItem>[];
  for (final item in vodList) {
    final vod = VodItem.fromJson(item as Map<String, dynamic>);
    if (vod.isSeries) {
      series.add(vod);
    } else {
      movies.add(vod);
    }
  }
  return (movies: movies, series: series);
}

/// Servicio central reactivo de datos de InútilTV v3.3 (`ChangeNotifier`).
///
/// - Carga instantánea de **1,183 canales verificados** (`assets/channels_master.json`)
///   + sincronización en segundo plano con listas públicas abiertas (`LiveTvSyncService`).
/// - Estrenos de Cine y Series desde **PoseidonHD2 / Cuevana3** y **SeriesKao**
///   (portadas TMDB HD, sinopsis reales en español y calificaciones reales) con failover.
/// - Anime en tendencia desde **JKAnime** (portadas HD + failover a TioAnime).
/// - **Personalización viva**: escucha cambios de `WatchHistory`, `MyListService` y
///   `TvTasteProfileService` para re-rankear Novedades, Hero y rieles por usuario,
///   excluir vistos/abandonados y rotar sin repetición.
class XuperService extends ChangeNotifier {
  static final XuperService _instance = XuperService._internal();
  factory XuperService() => _instance;
  XuperService._internal();

  bool _initialized = false;
  bool _liveCatalogLoaded = false;
  bool _tasteListenersAttached = false;
  Future<void>? _initFuture;
  Timer? _recomputeDebounce;
  String _lastFetchedTasteSignature = '';

  List<Channel> _allChannels = [];
  List<VodItem> _liveMovies = [];
  List<VodItem> _trendingMovies = [];
  List<VodItem> _classicMovies = [];
  List<VodItem> _liveSeries = [];
  List<VodItem> _latestSeries = [];
  List<VodItem> _liveAnime = [];
  List<VodItem> _tasteBonusItems = [];
  Map<String, List<VodItem>> _vodCategories = {};

  bool get liveCatalogLoaded => _liveCatalogLoaded;

  Future<void> initialize() {
    if (_initialized) return Future.value();
    return _initFuture ??= _initializeInternal();
  }

  void _ensureTasteListeners() {
    if (_tasteListenersAttached) return;
    _tasteListenersAttached = true;
    WatchHistory().addListener(_onUserTasteSignalChanged);
    MyListService.instance.addListener(_onUserTasteSignalChanged);
    TvTasteProfileService.instance.addListener(_onUserTasteSignalChanged);
  }

  void _onUserTasteSignalChanged() {
    if (!_initialized) return;
    _recomputeDebounce?.cancel();
    _recomputeDebounce = Timer(const Duration(milliseconds: 350), () {
      _updateCategories(recordImpressions: false);
      notifyListeners();
      // Si el top de géneros cambió, traer catálogo fresco de esos géneros en fondo
      final sig = _currentTasteFetchSignature();
      if (sig.isNotEmpty && sig != _lastFetchedTasteSignature) {
        unawaited(_fetchTasteTargetedCatalog());
      }
    });
  }

  String _currentTasteFetchSignature() {
    final top = TvTasteProfileService.instance.computeSummary().topGenres(2);
    if (top.isEmpty) return '';
    return top.map((e) => e.key).join(',');
  }

  /// Reconstruye inmediatamente los rieles personalizados (por ejemplo tras
  /// restaurar un respaldo en la nube al reinstalar).
  void rebuildRecommendations({bool forceShuffle = false}) {
    if (forceShuffle) {
      TvTasteProfileService.instance.bumpSession(persist: false);
    }
    _updateCategories(forceShuffle: forceShuffle, recordImpressions: forceShuffle);
    notifyListeners();
    if (_liveCatalogLoaded) {
      unawaited(_fetchTasteTargetedCatalog());
    }
  }

  Future<void> _initializeInternal() async {
    try {
      _ensureTasteListeners();

      // Cargar historial, Mi Lista y perfil de gustos ANTES del primer armado
      // para que Home y Novedades nazcan personalizados desde el arranque.
      await Future.wait([
        WatchHistory().load(),
        MyListService.instance.load(),
        TvTasteProfileService.instance.load(),
      ]);

      // 1. Cargar y parsear canales verificados en un isolate separado (cero jank UI)
      final channels = <Channel>[];
      try {
        final jsonStr =
            await rootBundle.loadString('assets/channels_master.json');
        channels.addAll(await compute(_parseChannelsInIsolate, jsonStr));
      } catch (e) {
        debugPrint('[XuperService] Error cargando channels_master.json: $e');
      }

      if (channels.isEmpty) {
        channels.addAll(const [
          Channel(
            id: 'canal_once_mexico',
            name: 'Canal Once México',
            logo:
                'https://upload.wikimedia.org/wikipedia/commons/thumb/d/d4/Canal_Once_logo_%282020%29.svg/512px-Canal_Once_logo_%282020%29.svg.png',
            group: 'México',
            country: 'MX',
            sources: [
              StreamSource(
                url:
                    'https://vivo.canaloncelive.tv/securepkgr3/oncemexico/playlist.m3u8',
                quality: 'HD · Fuente 1',
              ),
            ],
          ),
        ]);
      }
      _allChannels = channels;

      // 2. Cargar clásicos offline de respaldo en isolate secundario
      try {
        final vodJsonStr =
            await rootBundle.loadString('assets/vod_master.json');
        final parsed = await compute(_parseVodInIsolate, vodJsonStr);
        _classicMovies = parsed.movies;
        if (parsed.series.isNotEmpty) _liveSeries = parsed.series;
      } catch (e) {
        debugPrint('[XuperService] Error cargando vod_master.json: $e');
      }

      // Arrancar con destacados curados mientras llegan los catálogos en vivo
      _liveMovies = _buildFallbackMovies();
      if (_liveSeries.isEmpty) _liveSeries = _buildFallbackSeries();
      _liveAnime = _buildFallbackAnime();

      _updateCategories(recordImpressions: false);
      _initialized = true;
      notifyListeners();

      // 3. Cargar catálogo en vivo + auto-sincronizar respaldos IPTV en background
      unawaited(_refreshLiveCatalogInBackground());
      unawaited(_syncLiveTvInBackground());
    } catch (e) {
      debugPrint('[XuperService] Error general en initialize: $e');
      _initFuture = null;
    }
  }

  /// Fuerza recarga de estrenos, series, anime y respaldos de TV desde la red,
  /// refrescando y rotando las recomendaciones personalizadas al estilo Music.
  Future<void> refreshLiveCatalog({bool forceShuffle = false}) async {
    if (forceShuffle) {
      TvTasteProfileService.instance.bumpSession(persist: true);
    }
    await Future.wait([
      _refreshLiveCatalogInBackground(forceShuffle: forceShuffle),
      _syncLiveTvInBackground(forceRefresh: true),
    ]);
    if (forceShuffle) {
      _updateCategories(forceShuffle: true, recordImpressions: true);
      notifyListeners();
    }
  }

  void _updateCategories({
    bool forceShuffle = false,
    bool recordImpressions = false,
  }) {
    final map = <String, List<VodItem>>{};
    final taste = TvTasteProfileService.instance;
    final summary = taste.computeSummary();
    final history = WatchHistory().items;
    final myList = MyListService.instance.items;
    final sessionSeed = taste.sessionCounter +
        (forceShuffle ? (DateTime.now().millisecondsSinceEpoch % 997) : 0);

    final allItems = <VodItem>[
      ..._tasteBonusItems,
      ..._trendingMovies,
      ..._liveMovies,
      ..._latestSeries,
      ..._liveSeries,
      ..._liveAnime,
      ..._classicMovies,
    ];

    final uniquePool = VodCatalogService.groupByShowStateless(
      allItems.where((item) => item.id.isNotEmpty).toList(),
    );

    final usedInTopRails = <String>{};

    // 1. Novedades 100% dinámicas para ti (re-rankeadas por género, formato,
    //    audio preferido, búsquedas y exclusión de terminados/abandonados)
    final novedadesPool = VodCatalogService.groupByShowStateless([
      ..._tasteBonusItems,
      ..._trendingMovies,
      ..._latestSeries,
      ..._liveMovies,
      ..._liveSeries,
      ..._liveAnime,
    ].where((it) => it.id.isNotEmpty).toList());

    final novedades = _rankItems(
      novedadesPool,
      summary: summary,
      history: history,
      excludeCompletedOrAbandoned: true,
      seed: sessionSeed + 17,
      shuffleTopBand: forceShuffle,
    ).take(18).toList();

    if (novedades.isNotEmpty) {
      map['Novedades para ti'] = novedades;
      usedInTopRails.addAll(novedades.take(10).map((e) => e.id));
    }

    // 2. Recomendaciones contextuales: hasta 2 anclas distintas
    //    "Porque viste [Serie/Película]" (excluyendo títulos abandonados rápido)
    if (history.isNotEmpty) {
      final anchors = <WatchProgress>[];
      final seenAnchorFormats = <String>{};
      for (final h in history) {
        if (anchors.length >= 2) break;
        final asVod = h.toVodItem();
        if (taste.isRecentlyAbandoned(asVod)) continue;
        final fmt = TvTasteProfileService.formatOf(asVod);
        if (anchors.isEmpty || !seenAnchorFormats.contains(fmt)) {
          anchors.add(h);
          seenAnchorFormats.add(fmt);
        }
      }

      for (final anchor in anchors) {
        final anchorVod = anchor.toVodItem();
        final targetGenres = taste.resolveGenresForItem(anchorVod).toSet();

        final candidates = uniquePool.where((item) {
          if (item.id == anchor.id) return false;
          if (taste.shouldExcludeFromDiscovery(item, history: history)) {
            return false;
          }
          if (anchor.isAnime && !item.isAnime) return false;
          if (targetGenres.isEmpty) {
            return item.isSeries == anchor.isSeries &&
                item.isAnime == anchor.isAnime;
          }
          final itemGenres = taste.resolveGenresForItem(item).toSet();
          if (itemGenres.intersection(targetGenres).isNotEmpty) return true;
          // Fallback suave mismo formato si pocos títulos comparten género exacto
          return item.isSeries == anchor.isSeries &&
              item.isAnime == anchor.isAnime;
        }).toList();

        final rankedBecause = _rankItems(
          candidates,
          summary: summary,
          history: history,
          excludeCompletedOrAbandoned: true,
          seed: sessionSeed + anchor.id.hashCode,
          shuffleTopBand: forceShuffle,
          boostGenres: targetGenres,
        );

        if (rankedBecause.length >= 4) {
          final displayTitle = anchor.title.length > 22
              ? '${anchor.title.substring(0, 22)}…'
              : anchor.title;
          final key = 'Porque viste $displayTitle';
          if (!map.containsKey(key)) {
            final slice = rankedBecause.take(18).toList();
            map[key] = slice;
            usedInTopRails.addAll(slice.take(6).map((e) => e.id));
          }
        }
      }
    }

    // 3. Recomendación personalizada principal: "Especialmente para ti"
    final recommended = _buildPersonalizedRecommendations(
      pool: uniquePool,
      history: history,
      myList: myList,
      summary: summary,
      excludeIds: usedInTopRails,
      seed: sessionSeed + 41,
      shuffle: forceShuffle,
    );
    if (recommended.isNotEmpty) {
      map['Especialmente para ti'] = recommended.take(18).toList();
      usedInTopRails.addAll(recommended.take(8).map((e) => e.id));
    }

    // 4. Descubrimiento Dinámico / Joyas Ocultas (rotación anti-repetición)
    final discoveryCandidates = uniquePool
        .where((it) =>
            !usedInTopRails.contains(it.id) &&
            !taste.shouldExcludeFromDiscovery(it, history: history))
        .toList();
    final discoveries = _rankItems(
      discoveryCandidates.isNotEmpty ? discoveryCandidates : uniquePool,
      summary: summary,
      history: history,
      excludeCompletedOrAbandoned: false,
      seed: sessionSeed + DateTime.now().hour * 31,
      shuffleTopBand: true,
    ).take(16).toList();
    if (discoveries.isNotEmpty) {
      map['Descubrimientos de la Semana'] = discoveries;
    }

    // 5. Rieles de catálogo re-rankeados según gustos + orden adaptativo por formato
    final trendingSource =
        _trendingMovies.isNotEmpty ? _trendingMovies : _liveMovies;
    final trendingRanked = _rankItems(
      trendingSource,
      summary: summary,
      history: history,
      excludeCompletedOrAbandoned: false,
      seed: sessionSeed + 71,
      shuffleTopBand: forceShuffle,
    ).take(18).toList();

    final moviesRanked = _rankItems(
      _liveMovies,
      summary: summary,
      history: history,
      excludeCompletedOrAbandoned: false,
      seed: sessionSeed + 83,
      shuffleTopBand: forceShuffle,
    ).take(18).toList();

    final seriesPool = VodCatalogService.groupByShowStateless([
      ..._latestSeries,
      ..._liveSeries,
      ..._tasteBonusItems.where((v) => v.isSeries && !v.isAnime),
    ]);
    final seriesRanked = _rankItems(
      seriesPool.isNotEmpty ? seriesPool : _liveSeries,
      summary: summary,
      history: history,
      excludeCompletedOrAbandoned: false,
      seed: sessionSeed + 97,
      shuffleTopBand: forceShuffle,
    ).take(18).toList();

    final animePool = VodCatalogService.groupByShowStateless([
      ..._liveAnime,
      ..._tasteBonusItems.where((v) => v.isAnime),
    ]);
    final animeRanked = _rankItems(
      animePool.isNotEmpty ? animePool : _liveAnime,
      summary: summary,
      history: history,
      excludeCompletedOrAbandoned: false,
      seed: sessionSeed + 113,
      shuffleTopBand: forceShuffle,
    ).take(18).toList();

    if (trendingRanked.isNotEmpty) {
      map['Tendencias de la Semana'] = trendingRanked;
    }

    // Adaptar el orden de Cine / Series / Anime al consumo real del usuario
    final dominant = summary.hasSignals ? summary.dominantFormat : 'movie';
    final formatRails = <MapEntry<String, List<VodItem>>>[
      if (dominant == 'series') ...[
        if (seriesRanked.isNotEmpty) MapEntry('Series Destacadas', seriesRanked),
        if (moviesRanked.isNotEmpty) MapEntry('Estrenos de Cine', moviesRanked),
        if (animeRanked.isNotEmpty) MapEntry('Anime en Tendencia', animeRanked),
      ] else if (dominant == 'anime') ...[
        if (animeRanked.isNotEmpty) MapEntry('Anime en Tendencia', animeRanked),
        if (seriesRanked.isNotEmpty) MapEntry('Series Destacadas', seriesRanked),
        if (moviesRanked.isNotEmpty) MapEntry('Estrenos de Cine', moviesRanked),
      ] else ...[
        if (moviesRanked.isNotEmpty) MapEntry('Estrenos de Cine', moviesRanked),
        if (seriesRanked.isNotEmpty) MapEntry('Series Destacadas', seriesRanked),
        if (animeRanked.isNotEmpty) MapEntry('Anime en Tendencia', animeRanked),
      ],
    ];
    for (final entry in formatRails) {
      map[entry.key] = entry.value;
    }

    if (_classicMovies.isNotEmpty) {
      map['Clásicos Permanentes'] = _rankItems(
        _classicMovies,
        summary: summary,
        history: history,
        excludeCompletedOrAbandoned: false,
        seed: sessionSeed + 131,
        shuffleTopBand: forceShuffle,
      ).take(18).toList();
    }

    _vodCategories = map;

    if (recordImpressions) {
      final shown = <String>[
        ...novedades.take(6).map((e) => e.id),
        ...getFeaturedVod().take(6).map((e) => e.id),
      ];
      taste.recordImpressions(shown);
    }

    // Precargar en disco/RAM las primeras carátulas del Inicio en paralelo
    final posterUrls = <String>[
      for (final list in map.values.take(3))
        for (final item in list.take(6)) item.poster,
    ];
    unawaited(
      ArtworkCacheService.instance.prefetchUrls(
        posterUrls,
        tier: ArtworkTier.poster,
        maxConcurrent: 6,
        limit: 24,
      ),
    );
  }

  List<VodItem> _rankItems(
    List<VodItem> source, {
    required TvTasteSummary summary,
    required List<WatchProgress> history,
    required bool excludeCompletedOrAbandoned,
    required int seed,
    required bool shuffleTopBand,
    Set<String> boostGenres = const {},
  }) {
    if (source.isEmpty) return const [];
    final taste = TvTasteProfileService.instance;
    final filtered = excludeCompletedOrAbandoned
        ? source
            .where((it) => !taste.shouldExcludeFromDiscovery(it, history: history))
            .toList()
        : List<VodItem>.from(source);

    // Si todo quedó filtrado en un catálogo pequeño, degradar a demotion en vez de vacío
    final working = filtered.isNotEmpty ? filtered : List<VodItem>.from(source);

    final rng = Random(seed);
    final scored = <({VodItem item, double score})>[];
    for (final item in working) {
      var s = taste.scoreItem(
        item,
        summary: summary,
        history: history,
        applyImpressionPenalty: true,
      );
      if (boostGenres.isNotEmpty) {
        final itemGenres = taste.resolveGenresForItem(item).toSet();
        final overlap = itemGenres.intersection(boostGenres).length;
        s += overlap * 2.4;
      }
      // Jitter sutil determinístico por sesión para rotar empates sin perder relevancia
      s += (rng.nextDouble() - 0.5) * (shuffleTopBand ? 1.8 : 0.65);
      scored.add((item: item, score: s));
    }

    scored.sort((a, b) => b.score.compareTo(a.score));
    return scored.map((e) => e.item).toList();
  }

  List<VodItem> _buildPersonalizedRecommendations({
    required List<VodItem> pool,
    required List<WatchProgress> history,
    required List<VodItem> myList,
    required TvTasteSummary summary,
    required Set<String> excludeIds,
    required int seed,
    required bool shuffle,
  }) {
    final taste = TvTasteProfileService.instance;
    final candidates = pool.where((item) {
      if (excludeIds.contains(item.id)) return false;
      return !taste.shouldExcludeFromDiscovery(item, history: history);
    }).toList();

    final working = candidates.length >= 6
        ? candidates
        : pool
            .where((item) => !taste.shouldExcludeFromDiscovery(item, history: history))
            .toList();

    final listToRank = working.isNotEmpty ? working : pool;
    if (listToRank.isEmpty) return const [];

    // Extra boost suave para afinidad con géneros de Mi Lista si aún hay pocos eventos
    final myListGenres = <String>{
      for (final m in myList) ...taste.resolveGenresForItem(m),
    };

    return _rankItems(
      listToRank,
      summary: summary,
      history: history,
      excludeCompletedOrAbandoned: false,
      seed: seed,
      shuffleTopBand: shuffle,
      boostGenres: summary.hasSignals ? const {} : myListGenres,
    ).take(18).toList();
  }

  /// Obtiene los títulos destacados para el Hero Carousel de Inicio,
  /// adaptados al perfil de gustos, excluyendo vistos/abandonados y con
  /// rotación anti-repetición mediante [seed] y sesión actual.
  List<VodItem> getFeaturedVod({int seed = 0}) {
    final taste = TvTasteProfileService.instance;
    final summary = taste.computeSummary();
    final history = WatchHistory().items;

    final rawPool = VodCatalogService.groupByShowStateless([
      ..._tasteBonusItems,
      ..._trendingMovies,
      ..._liveMovies,
      ..._latestSeries,
      ..._liveSeries,
      ..._liveAnime,
    ].where((v) => v.backdrop.isNotEmpty || v.poster.isNotEmpty).toList());

    if (rawPool.isEmpty) return const [];
    if (rawPool.length <= 6) return rawPool;

    final activeSeed = seed != 0 ? seed : (taste.sessionCounter * 97 + 13);
    final ranked = _rankItems(
      rawPool,
      summary: summary,
      history: history,
      excludeCompletedOrAbandoned: true,
      seed: activeSeed,
      shuffleTopBand: seed != 0,
    );

    if (ranked.length <= 6) return ranked;

    // Distribuir 6 slots del Hero respetando proporción real Película/Serie/Anime
    final movies = ranked.where((v) => !v.isSeries && !v.isAnime).toList();
    final series = ranked.where((v) => v.isSeries && !v.isAnime).toList();
    final anime = ranked.where((v) => v.isAnime).toList();

    int mQuota = 3;
    int sQuota = 2;
    int aQuota = 1;
    if (summary.hasSignals) {
      final mPct = summary.formatRatio['movie'] ?? 0.34;
      final sPct = summary.formatRatio['series'] ?? 0.33;
      final aPct = summary.formatRatio['anime'] ?? 0.33;
      mQuota = (mPct * 6).round().clamp(1, 4);
      sQuota = (sPct * 6).round().clamp(1, 4);
      aQuota = (6 - mQuota - sQuota).clamp(0, 4);
      if (aPct >= 0.45 && aQuota < 2) {
        aQuota = 3;
        mQuota = 2;
        sQuota = 1;
      }
    }

    final selected = <VodItem>[];
    final seen = <String>{};
    void takeFrom(List<VodItem> list, int quota) {
      var added = 0;
      for (final it in list) {
        if (added >= quota || selected.length >= 6) break;
        if (seen.add(it.id)) {
          selected.add(it);
          added++;
        }
      }
    }

    // Ordenar primero la categoría dominante del usuario para que la 1ª lámina
    // del Hero conecte de inmediato con sus gustos
    final dominant = summary.hasSignals ? summary.dominantFormat : 'movie';
    if (dominant == 'series') {
      takeFrom(series, sQuota);
      takeFrom(movies, mQuota);
      takeFrom(anime, aQuota);
    } else if (dominant == 'anime') {
      takeFrom(anime, aQuota);
      takeFrom(series, sQuota);
      takeFrom(movies, mQuota);
    } else {
      takeFrom(movies, mQuota);
      takeFrom(series, sQuota);
      takeFrom(anime, aQuota);
    }

    // Rellenar cualquier hueco restante con los mejor rankeados
    for (final it in ranked) {
      if (selected.length >= 6) break;
      if (seen.add(it.id)) selected.add(it);
    }
    return selected.take(6).toList();
  }

  Future<void> _syncLiveTvInBackground({bool forceRefresh = false}) async {
    try {
      final merged = await LiveTvSyncService.instance.syncAndMerge(
        _allChannels,
        forceRefresh: forceRefresh,
      );
      if (merged.isNotEmpty) {
        _allChannels = merged;
        notifyListeners();
      }
    } catch (e) {
      debugPrint('[XuperService] LiveTV sync error: $e');
    }
  }

  Future<void> _refreshLiveCatalogInBackground({
    bool forceShuffle = false,
  }) async {
    try {
      final cp = CuevanaPoseidonService();
      final sk = SeriesKaoService();
      final results = await Future.wait([
        cp.fetchMovies(page: 1, genre: 'tendencias'),
        cp.fetchMovies(page: 1),
        sk.fetchPopularSeries(page: 1),
        sk.fetchLatestSeries(page: 1),
        JkAnimeService().fetchDirectory(page: 1),
      ]);

      final trending = results[0];
      var movies = results[1];
      var series = results[2];
      var latestSeries = results[3];
      final anime = results[4];

      // Failover automático si algún proveedor primario no respondió
      if (movies.isEmpty) {
        movies = await PelisflixService().fetchMovies(page: 1);
      }
      if (series.isEmpty) {
        series = await cp.fetchSeries(page: 1);
      }
      if (series.isEmpty) {
        series = await PelisflixService().fetchSeries(page: 1);
      }
      if (latestSeries.isEmpty) {
        latestSeries = await cp.fetchSeries(page: 1, section: 'estrenos');
      }

      if (trending.isNotEmpty) _trendingMovies = trending;
      if (movies.isNotEmpty) _liveMovies = movies;
      if (series.isNotEmpty) _liveSeries = series;
      if (latestSeries.isNotEmpty) _latestSeries = latestSeries;
      if (anime.isNotEmpty) _liveAnime = anime;

      _liveCatalogLoaded = true;
      _updateCategories(forceShuffle: forceShuffle, recordImpressions: true);
      notifyListeners();

      // En segundo plano, traer 1-2 géneros top del usuario para enriquecer Novedades
      unawaited(_fetchTasteTargetedCatalog());
    } catch (e) {
      debugPrint('[XuperService] Error cargando VOD en background: $e');
    }
  }

  /// Consulta hasta 2 géneros favoritos del usuario en los proveedores activos
  /// para que Novedades y Series realmente se adapten a sus gustos.
  Future<void> _fetchTasteTargetedCatalog() async {
    final summary = TvTasteProfileService.instance.computeSummary();
    final top = summary.topGenres(2);
    if (top.isEmpty) return;

    final sig = top.map((e) => e.key).join(',');
    _lastFetchedTasteSignature = sig;

    try {
      final catalog = VodCatalogService();
      final futures = <Future<List<VodItem>>>[];

      for (final entry in top) {
        final g = entry.key;
        final movieSlug = TvTasteProfileService.toMovieGenreSlug(g);
        final seriesCat = TvTasteProfileService.toSeriesCategorySlug(g);
        final animeSlug = TvTasteProfileService.toAnimeGenreSlug(g);

        if (summary.dominantFormat == 'series' && seriesCat != null) {
          futures.add(catalog.getSeries(page: 1, category: seriesCat));
          if (movieSlug != null && futures.length < 3) {
            futures.add(catalog.getMovies(page: 1, genre: movieSlug));
          }
        } else if (summary.dominantFormat == 'anime' && animeSlug != null) {
          futures.add(catalog.getAnime(page: 1, genre: animeSlug));
          if (seriesCat != null && futures.length < 3) {
            futures.add(catalog.getSeries(page: 1, category: seriesCat));
          }
        } else {
          if (movieSlug != null) {
            futures.add(catalog.getMovies(page: 1, genre: movieSlug));
          }
          if (seriesCat != null && futures.length < 3) {
            futures.add(catalog.getSeries(page: 1, category: seriesCat));
          }
        }
        if (futures.length >= 3) break;
      }

      if (futures.isEmpty) return;
      final lists = await Future.wait(
        futures.map((f) => f.catchError((_) => const <VodItem>[])),
      );
      final combined = <VodItem>[
        for (final list in lists) ...list.take(12),
      ];
      if (combined.isEmpty) return;

      _tasteBonusItems = VodCatalogService.groupByShowStateless(combined);
      _updateCategories(recordImpressions: false);
      notifyListeners();
    } catch (e) {
      debugPrint('[XuperService] Taste targeted fetch err: $e');
    }
  }

  /// Permite inyectar catálogo determinístico en pruebas unitarias sin red.
  @visibleForTesting
  void setCatalogForTest({
    List<VodItem> trendingMovies = const [],
    List<VodItem> liveMovies = const [],
    List<VodItem> liveSeries = const [],
    List<VodItem> latestSeries = const [],
    List<VodItem> liveAnime = const [],
    List<VodItem> classicMovies = const [],
    List<VodItem> tasteBonusItems = const [],
  }) {
    _ensureTasteListeners();
    _trendingMovies = List<VodItem>.from(trendingMovies);
    _liveMovies = List<VodItem>.from(liveMovies);
    _liveSeries = List<VodItem>.from(liveSeries);
    _latestSeries = List<VodItem>.from(latestSeries);
    _liveAnime = List<VodItem>.from(liveAnime);
    _classicMovies = List<VodItem>.from(classicMovies);
    _tasteBonusItems = List<VodItem>.from(tasteBonusItems);
    _initialized = true;
    _updateCategories(recordImpressions: false);
    notifyListeners();
  }

  List<VodItem> _buildFallbackMovies() {
    return const [
      VodItem(
        id: 'cp_m_49519',
        title: 'Los Croods',
        slug: 'movies/49519/los-croods',
        poster:
            'https://image.tmdb.org/t/p/w500/p3bV4j38yP80n2G2j1W6e9jK1pG.jpg',
        backdrop:
            'https://image.tmdb.org/t/p/w780/w5k9i9A7M9iX9g9v2Y5v1n0p4tL.jpg',
        overview:
            'Cuando la cueva que siempre ha protegido a su familia queda destruida, los Croods emprenden un viaje inolvidable por un mundo lleno de criaturas fantásticas.',
        year: '2013',
        genre: 'Animación · Aventura · Familia',
        rating: '7.0',
        duration: '1h 38m',
        provider: 'poseidon',
        quality: 'HD',
      ),
    ];
  }

  List<VodItem> _buildFallbackSeries() {
    return const [
      VodItem(
        id: 'cp_s_253372',
        title: 'El instituto',
        slug: 'series/253372/the-institute',
        poster:
            'https://image.tmdb.org/t/p/w500/fK9XYdRf4Mi0QkTu27prFX8FsM9.jpg',
        backdrop:
            'https://image.tmdb.org/t/p/w780/fK9XYdRf4Mi0QkTu27prFX8FsM9.jpg',
        overview:
            'Luke Ellis, un genio de 14 años, es secuestrado en plena noche y trasladado a una misteriosa instalación llena de jóvenes con habilidades extraordinarias.',
        year: '2025',
        genre: 'Misterio · Ciencia Ficción',
        rating: '7.8',
        duration: '50m',
        isSeries: true,
        provider: 'poseidon',
        quality: 'HD',
      ),
    ];
  }

  List<VodItem> _buildFallbackAnime() {
    return const [
      VodItem(
        id: 'jk_one-piece',
        title: 'One Piece',
        slug: 'one-piece',
        poster:
            'https://cdn.jkdesa.com/assets/images/animes/image/one-piece.jpg',
        backdrop:
            'https://cdn.jkdesa.com/assets/images/animes/image/one-piece.jpg',
        overview:
            'Monkey D. Luffy zarpa hacia el Grand Line junto a su tripulación en busca del tesoro legendario One Piece para convertirse en el Rey de los Piratas.',
        year: '1999',
        genre: 'Serie · Sub Español',
        rating: '',
        duration: '24m',
        isSeries: true,
        isAnime: true,
        provider: 'jkanime',
        quality: 'HD',
      ),
    ];
  }

  List<String> getChannelCategories() {
    const predefinedOrder = [
      'Todos',
      'Favoritos',
      'México',
      'Deportes',
      'Cine y Series',
      'Infantil y Anime',
      'Noticias',
      'Documentales y Cultura',
      'España',
      'Latinoamérica',
      'Música',
      'Internacional',
    ];

    if (_allChannels.isEmpty) return predefinedOrder;

    final found = <String>{};
    for (final ch in _allChannels) {
      if (ch.group.isNotEmpty) found.add(ch.group);
    }

    final out = <String>['Todos', 'Favoritos'];
    for (final cat in predefinedOrder.skip(2)) {
      if (found.contains(cat)) out.add(cat);
    }
    for (final f in found) {
      if (!out.contains(f)) out.add(f);
    }
    return out;
  }

  List<String> getLiveCategories() => getChannelCategories();

  Future<List<Channel>> getLiveChannels({bool includeGlobal = false}) async {
    if (!_initialized) {
      await initialize();
    }
    return _allChannels;
  }

  List<VodItem> getMovies() =>
      [..._trendingMovies, ..._liveMovies, ..._classicMovies];

  List<VodItem> getLiveMovies() => List.unmodifiable(
        _trendingMovies.isNotEmpty ? _trendingMovies : _liveMovies,
      );

  List<VodItem> getSeries() => List.unmodifiable(
        _latestSeries.isNotEmpty
            ? VodCatalogService.groupByShowStateless([
                ..._latestSeries,
                ..._liveSeries,
              ])
            : _liveSeries,
      );

  List<VodItem> getAnime() => List.unmodifiable(_liveAnime);

  Map<String, List<VodItem>> getVodCategories() => _vodCategories;
}
