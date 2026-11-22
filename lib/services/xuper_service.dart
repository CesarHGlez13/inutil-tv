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

/// Servicio central reactivo de datos de InútilTV v3.0 (`ChangeNotifier`).
///
/// - Carga instantánea de **1,183 canales verificados** (`assets/channels_master.json`)
///   + sincronización en segundo plano con listas públicas abiertas (`LiveTvSyncService`).
/// - Estrenos de Cine y Series desde **PoseidonHD2 / Cuevana3** (portadas TMDB HD,
///   sinopsis reales en español y calificaciones reales) con failover a PelisFlix.
/// - Anime en tendencia desde **JKAnime** (portadas HD + failover a TioAnime).
class XuperService extends ChangeNotifier {
  static final XuperService _instance = XuperService._internal();
  factory XuperService() => _instance;
  XuperService._internal();

  bool _initialized = false;
  bool _liveCatalogLoaded = false;
  Future<void>? _initFuture;

  List<Channel> _allChannels = [];
  List<VodItem> _liveMovies = [];
  List<VodItem> _trendingMovies = [];
  List<VodItem> _classicMovies = [];
  List<VodItem> _liveSeries = [];
  List<VodItem> _liveAnime = [];
  Map<String, List<VodItem>> _vodCategories = {};

  bool get liveCatalogLoaded => _liveCatalogLoaded;

  Future<void> initialize() {
    if (_initialized) return Future.value();
    return _initFuture ??= _initializeInternal();
  }

  Future<void> _initializeInternal() async {
    try {
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

      _updateCategories();
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
  /// refrescando y rotando las recomendaciones personalizadas al estilo Spotify.
  Future<void> refreshLiveCatalog({bool forceShuffle = false}) async {
    await Future.wait([
      _refreshLiveCatalogInBackground(forceShuffle: forceShuffle),
      _syncLiveTvInBackground(forceRefresh: true),
    ]);
    if (forceShuffle) {
      _updateCategories(forceShuffle: true);
      notifyListeners();
    }
  }

  void _updateCategories({bool forceShuffle = false}) {
    final map = <String, List<VodItem>>{};

    final allItems = <VodItem>[
      ..._trendingMovies,
      ..._liveMovies,
      ..._liveSeries,
      ..._liveAnime,
      ..._classicMovies,
    ];

    final uniquePool = VodCatalogService.groupByShowStateless(
      allItems.where((item) => item.id.isNotEmpty).toList(),
    );

    final history = WatchHistory().items;
    final myList = MyListService.instance.items;

    // 1. Recomendación contextual: "Porque viste [Título]"
    if (history.isNotEmpty) {
      final last = history.first;
      final targetGenres = last.genre
          .split(RegExp(r'[,/·]'))
          .map((g) => g.trim().toLowerCase())
          .where((g) => g.isNotEmpty)
          .toSet();

      final becauseYouWatched = uniquePool.where((item) {
        if (item.id == last.id) return false;
        if (last.isAnime && !item.isAnime) return false;
        if (targetGenres.isEmpty) {
          return item.isSeries == last.isSeries;
        }
        final itemGenres = item.genre
            .split(RegExp(r'[,/·]'))
            .map((g) => g.trim().toLowerCase())
            .toSet();
        return itemGenres.intersection(targetGenres).isNotEmpty;
      }).toList();

      if (becauseYouWatched.length >= 4) {
        if (forceShuffle) {
          becauseYouWatched.shuffle();
        }
        final displayTitle = last.title.length > 22
            ? '${last.title.substring(0, 22)}…'
            : last.title;
        map['Porque viste $displayTitle'] =
            becauseYouWatched.take(18).toList();
      }
    }

    // 2. Recomendación personalizada: "Especialmente para ti"
    final recommended = _buildPersonalizedRecommendations(
      pool: uniquePool,
      history: history,
      myList: myList,
      shuffle: forceShuffle,
    );
    if (recommended.isNotEmpty) {
      map['Especialmente para ti'] = recommended.take(18).toList();
    }

    // 3. Descubrimiento Dinámico / Joyas Ocultas (rotación dinámica tipo Spotify)
    final discoveries = List<VodItem>.from(uniquePool);
    final hourSeed = DateTime.now().hour +
        (forceShuffle ? DateTime.now().millisecondsSinceEpoch % 1000 : 0);
    discoveries.shuffle(Random(hourSeed));
    final existingTitles =
        map.values.expand((list) => list.map((e) => e.id)).toSet();
    final freshDiscoveries = discoveries
        .where((it) => !existingTitles.contains(it.id))
        .take(16)
        .toList();
    if (freshDiscoveries.isNotEmpty) {
      map['Descubrimientos de la Semana'] = freshDiscoveries;
    }

    // Categorías canónicas del catálogo
    final trending = _trendingMovies.isNotEmpty ? _trendingMovies : _liveMovies;
    if (trending.isNotEmpty) {
      map['Tendencias de la Semana'] = trending.take(18).toList();
    }
    if (_liveMovies.isNotEmpty) {
      map['Estrenos de Cine'] = _liveMovies.take(18).toList();
    }
    if (_liveSeries.isNotEmpty) {
      map['Series Destacadas'] = _liveSeries.take(18).toList();
    }
    if (_liveAnime.isNotEmpty) {
      map['Anime en Tendencia'] = _liveAnime.take(18).toList();
    }
    if (_classicMovies.isNotEmpty) {
      map['Clásicos Permanentes'] = _classicMovies.take(18).toList();
    }
    _vodCategories = map;

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

  List<VodItem> _buildPersonalizedRecommendations({
    required List<VodItem> pool,
    required List<WatchProgress> history,
    required List<VodItem> myList,
    required bool shuffle,
  }) {
    final finishedIds =
        history.where((p) => p.finished).map((p) => p.id).toSet();
    final preferredGenres = <String, int>{};

    for (final h in history) {
      for (final g in h.genre.split(RegExp(r'[,/·]'))) {
        final clean = g.trim().toLowerCase();
        if (clean.isNotEmpty) {
          preferredGenres[clean] = (preferredGenres[clean] ?? 0) + 2;
        }
      }
    }
    for (final m in myList) {
      for (final g in m.genre.split(RegExp(r'[,/·]'))) {
        final clean = g.trim().toLowerCase();
        if (clean.isNotEmpty) {
          preferredGenres[clean] = (preferredGenres[clean] ?? 0) + 1;
        }
      }
    }

    if (preferredGenres.isEmpty) {
      final mixed = <VodItem>[
        ..._trendingMovies.take(6),
        ..._liveSeries.take(6),
        ..._liveAnime.take(6),
        ..._classicMovies.take(4),
      ];
      if (shuffle) mixed.shuffle();
      return mixed;
    }

    final scored =
        pool.where((item) => !finishedIds.contains(item.id)).map((item) {
      var score = 0;
      final genres = item.genre
          .split(RegExp(r'[,/·]'))
          .map((g) => g.trim().toLowerCase());
      for (final g in genres) {
        score += preferredGenres[g] ?? 0;
      }
      if (item.backdrop.isNotEmpty) score += 1;
      return MapEntry(item, score);
    }).toList();

    scored.sort((a, b) => b.value.compareTo(a.value));
    final candidates =
        scored.where((e) => e.value > 0).map((e) => e.key).toList();
    if (candidates.isEmpty) {
      return pool.take(18).toList();
    }
    if (shuffle) {
      final top = candidates.take(30).toList()..shuffle();
      return top.take(18).toList();
    }
    return candidates.take(18).toList();
  }

  /// Obtiene los títulos destacados para el Hero Carousel de Inicio,
  /// permitiendo rotación dinámica mediante [seed].
  List<VodItem> getFeaturedVod({int seed = 0}) {
    final pool = <VodItem>[
      ..._trendingMovies,
      ..._liveMovies,
      ..._liveSeries,
      ..._liveAnime,
    ].where((v) => v.backdrop.isNotEmpty || v.poster.isNotEmpty).toList();

    if (pool.isEmpty) return const [];
    if (pool.length <= 6) return pool;

    if (seed != 0) {
      final rotated = List<VodItem>.from(pool);
      rotated.shuffle(Random(seed));
      return rotated.take(6).toList();
    }
    return [
      ..._liveMovies.take(3),
      ..._liveSeries.take(2),
      ..._liveAnime.take(1),
    ]
        .where((v) => v.backdrop.isNotEmpty || v.poster.isNotEmpty)
        .take(6)
        .toList();
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
        JkAnimeService().fetchDirectory(page: 1),
      ]);

      final trending = results[0];
      var movies = results[1];
      var series = results[2];
      final anime = results[3];

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

      if (trending.isNotEmpty) _trendingMovies = trending;
      if (movies.isNotEmpty) _liveMovies = movies;
      if (series.isNotEmpty) _liveSeries = series;
      if (anime.isNotEmpty) _liveAnime = anime;

      _liveCatalogLoaded = true;
      _updateCategories(forceShuffle: forceShuffle);
      notifyListeners();
    } catch (e) {
      debugPrint('[XuperService] Error cargando VOD en background: $e');
    }
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

  List<VodItem> getSeries() => List.unmodifiable(_liveSeries);

  List<VodItem> getAnime() => List.unmodifiable(_liveAnime);

  Map<String, List<VodItem>> getVodCategories() => _vodCategories;
}
