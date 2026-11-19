/// Modelos de datos de Xuper TV: canales IPTV México, Películas y Series VOD.
library models;

/// Una pista de subtítulos asociada a un stream (WebVTT de VOE/Pluto o HLS renditions).
class SubtitleSource {
  final String url;
  final String label;
  final String language;

  const SubtitleSource({
    required this.url,
    this.label = '',
    this.language = 'es',
  });

  Map<String, dynamic> toJson() =>
      {'url': url, 'label': label, 'language': language};

  factory SubtitleSource.fromJson(Map<String, dynamic> j) => SubtitleSource(
        url: j['url'] as String? ?? '',
        label: j['label'] as String? ?? '',
        language: j['language'] as String? ?? 'es',
      );
}

/// Una fuente de reproducción individual (un feed de un canal o un item de lista).
class StreamSource {
  final String url;
  final String quality;

  /// Cabeceras HTTP necesarias para el stream (User-Agent / Referer).
  final Map<String, String> headers;

  /// Pistas de subtítulos disponibles para esta fuente.
  final List<SubtitleSource> subtitles;

  /// Proveedor/origen del enlace (voe, nupload, pluto, jkanime...) para mostrarlo en el reproductor.
  final String server;

  const StreamSource({
    required this.url,
    this.quality = '',
    this.headers = const {},
    this.subtitles = const [],
    this.server = '',
  });

  Map<String, dynamic> toJson() => {
        'url': url,
        'quality': quality,
        'headers': headers,
        'server': server,
        'subtitles': subtitles.map((s) => s.toJson()).toList(),
      };

  factory StreamSource.fromJson(Map<String, dynamic> j) => StreamSource(
        url: j['url'] as String? ?? '',
        quality: j['quality'] as String? ?? '',
        headers: (j['headers'] as Map?)?.cast<String, String>() ?? const {},
        server: j['server'] as String? ?? '',
        subtitles: (j['subtitles'] as List?)
                ?.map((s) => SubtitleSource.fromJson(s as Map<String, dynamic>))
                .toList() ??
            const [],
      );
}

/// Canal de TV (México, Deportes, Cine, Abierta o Internacional).
class Channel {
  final String id;
  final String name;
  final String logo;
  final String group; // categoría (p. ej. '🇲🇽 México Abierta', '⚽ Deportes')
  final String country;
  final bool nsfw;
  final List<StreamSource> sources;

  const Channel({
    required this.id,
    required this.name,
    this.logo = '',
    this.group = '',
    this.country = '',
    this.nsfw = false,
    this.sources = const [],
  });

  String get primaryUrl => sources.isEmpty ? '' : sources.first.url;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'logo': logo,
        'group': group,
        'country': country,
        'nsfw': nsfw,
        'sources': sources.map((s) => s.toJson()).toList(),
      };

  factory Channel.fromJson(Map<String, dynamic> j) => Channel(
        id: j['id'] as String? ?? '',
        name: j['name'] as String? ?? '',
        logo: j['logo'] as String? ?? '',
        group: j['group'] as String? ?? 'General',
        country: j['country'] as String? ?? '',
        nsfw: j['nsfw'] as bool? ?? false,
        sources: (j['sources'] as List?)
                ?.map((s) => StreamSource.fromJson(s as Map<String, dynamic>))
                .toList() ??
            const [],
      );
}

/// Episodio individual de una Serie o Anime
class VodEpisode {
  final String id;
  final String title;
  final int episodeNumber;
  final int seasonNumber;
  final String overview;
  final String duration;
  final String thumbnail;
  final List<StreamSource> sources;

  /// Slug interno del proveedor (p. ej. `dexter-1x1` en PelisFlix o `dragon-ball-z/7` en JKAnime).
  final String slug;

  /// Proveedor de la fuente: 'pelisflix' | 'pluto' | 'jkanime' | 'xuper'.
  final String provider;

  const VodEpisode({
    required this.id,
    required this.title,
    required this.episodeNumber,
    this.seasonNumber = 1,
    this.overview = '',
    this.duration = '',
    this.thumbnail = '',
    this.sources = const [],
    this.slug = '',
    this.provider = '',
  });

  String get primaryUrl => sources.isEmpty ? '' : sources.first.url;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'episodeNumber': episodeNumber,
        'seasonNumber': seasonNumber,
        'overview': overview,
        'duration': duration,
        'thumbnail': thumbnail,
        'slug': slug,
        'provider': provider,
        'sources': sources.map((s) => s.toJson()).toList(),
      };

  factory VodEpisode.fromJson(Map<String, dynamic> j) => VodEpisode(
        id: j['id'] as String? ?? '',
        title: j['title'] as String? ?? '',
        episodeNumber: j['episodeNumber'] as int? ?? 1,
        seasonNumber: j['seasonNumber'] as int? ?? 1,
        overview: j['overview'] as String? ?? '',
        duration: j['duration'] as String? ?? '',
        thumbnail: j['thumbnail'] as String? ?? '',
        slug: j['slug'] as String? ?? '',
        provider: j['provider'] as String? ?? '',
        sources: (j['sources'] as List?)
                ?.map((s) => StreamSource.fromJson(s as Map<String, dynamic>))
                .toList() ??
            const [],
      );
}

/// Contenido VOD (Película, Serie o Anime estilo Xuper / Netflix).
class VodItem {
  final String id;
  final String title;
  final String poster;
  final String backdrop;
  final String overview;
  final String year;
  final String genre;
  final String rating;
  final String duration;
  final bool isSeries;
  final bool isAnime;
  final List<StreamSource> sources;
  final List<VodEpisode> episodes;

  /// Slug interno del proveedor (p. ej. `el-gran-hotel-budapest` en PelisFlix).
  final String slug;

  /// Proveedor primario del catálogo: 'pelisflix' | 'pluto' | 'jkanime' | 'xuper'.
  final String provider;

  /// Calidad real informada por el proveedor (720p / 1080p) para el badge del grid.
  final String quality;

  /// Totales conocidos por el proveedor (0 = desconocido).
  final int seasonCount;
  final int episodeCount;

  /// Ruta/parámetro de género del proveedor para búsquedas y filtros server-side.
  final String genrePath;

  const VodItem({
    required this.id,
    required this.title,
    this.poster = '',
    this.backdrop = '',
    this.overview = '',
    this.year = '',
    this.genre = '',
    this.rating = '8.0',
    this.duration = '',
    this.isSeries = false,
    this.isAnime = false,
    this.sources = const [],
    this.episodes = const [],
    this.slug = '',
    this.provider = '',
    this.quality = '',
    this.seasonCount = 0,
    this.episodeCount = 0,
    this.genrePath = '',
  });

  List<int> get seasons {
    if (episodes.isEmpty) {
      return [for (var i = 1; i <= (seasonCount < 1 ? 1 : seasonCount); i++) i];
    }
    final s = episodes.map((e) => e.seasonNumber).toSet().toList();
    s.sort();
    if (s.length == 1 && seasonCount > 1) {
      return [for (var i = 1; i <= seasonCount; i++) i];
    }
    return s;
  }

  List<VodEpisode> episodesForSeason(int season) =>
      episodes.where((e) => e.seasonNumber == season).toList();

  /// Copia con los campos no vacíos de [other] (para fusionar detalle diferido).
  VodItem mergedWith(VodItem other) => VodItem(
        id: id,
        title: other.title.isNotEmpty ? other.title : title,
        poster: other.poster.isNotEmpty ? other.poster : poster,
        backdrop: other.backdrop.isNotEmpty ? other.backdrop : backdrop,
        overview: other.overview.isNotEmpty ? other.overview : overview,
        year: other.year.isNotEmpty ? other.year : year,
        genre: other.genre.isNotEmpty ? other.genre : genre,
        rating: other.rating.isNotEmpty ? other.rating : rating,
        duration: other.duration.isNotEmpty ? other.duration : duration,
        isSeries: other.isSeries || isSeries,
        isAnime: other.isAnime || isAnime,
        sources: other.sources.isNotEmpty ? other.sources : sources,
        episodes: other.episodes.isNotEmpty ? other.episodes : episodes,
        slug: other.slug.isNotEmpty ? other.slug : slug,
        provider: other.provider.isNotEmpty ? other.provider : provider,
        quality: other.quality.isNotEmpty ? other.quality : quality,
        seasonCount: other.seasonCount > 0 ? other.seasonCount : seasonCount,
        episodeCount: other.episodeCount > 0 ? other.episodeCount : episodeCount,
        genrePath: other.genrePath.isNotEmpty ? other.genrePath : genrePath,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'poster': poster,
        'backdrop': backdrop,
        'overview': overview,
        'year': year,
        'genre': genre,
        'rating': rating,
        'duration': duration,
        'isSeries': isSeries,
        'isAnime': isAnime,
        'slug': slug,
        'provider': provider,
        'quality': quality,
        'seasonCount': seasonCount,
        'episodeCount': episodeCount,
        'genrePath': genrePath,
        'sources': sources.map((s) => s.toJson()).toList(),
        'episodes': episodes.map((e) => e.toJson()).toList(),
      };

  factory VodItem.fromJson(Map<String, dynamic> j) => VodItem(
        id: j['id'] as String? ?? '',
        title: j['title'] as String? ?? '',
        poster: j['poster'] as String? ?? '',
        backdrop: j['backdrop'] as String? ?? '',
        overview: j['overview'] as String? ?? '',
        year: j['year'] as String? ?? '',
        genre: j['genre'] as String? ?? '',
        rating: j['rating'] as String? ?? '8.0',
        duration: j['duration'] as String? ?? '',
        isSeries: j['isSeries'] as bool? ?? false,
        isAnime: j['isAnime'] as bool? ?? false,
        slug: j['slug'] as String? ?? '',
        provider: j['provider'] as String? ?? '',
        quality: j['quality'] as String? ?? '',
        seasonCount: (j['seasonCount'] as num?)?.toInt() ?? 0,
        episodeCount: (j['episodeCount'] as num?)?.toInt() ?? 0,
        genrePath: j['genrePath'] as String? ?? '',
        sources: (j['sources'] as List?)
                ?.map((s) => StreamSource.fromJson(s as Map<String, dynamic>))
                .toList() ??
            const [],
        episodes: (j['episodes'] as List?)
                ?.map((e) => VodEpisode.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const [],
      );
}

/// Página de catálogo con metadatos de paginación real del proveedor.
class CatalogPage {
  final List<VodItem> items;

  /// Página cargada (base 1).
  final int page;

  /// Última página disponible (0 = desconocida).
  final int lastPage;

  /// Total aproximado de títulos del catálogo (0 = desconocido).
  final int totalEstimate;

  const CatalogPage({
    this.items = const [],
    this.page = 1,
    this.lastPage = 0,
    this.totalEstimate = 0,
  });

  bool get hasMore => lastPage > 0 && page < lastPage;

  Map<String, dynamic> toJson() => {
        'items': items.map((i) => i.toJson()).toList(),
        'page': page,
        'lastPage': lastPage,
        'totalEstimate': totalEstimate,
      };

  factory CatalogPage.fromJson(Map<String, dynamic> j) => CatalogPage(
        items: (j['items'] as List?)
                ?.map((i) => VodItem.fromJson(i as Map<String, dynamic>))
                .toList() ??
            const [],
        page: (j['page'] as num?)?.toInt() ?? 1,
        lastPage: (j['lastPage'] as num?)?.toInt() ?? 0,
        totalEstimate: (j['totalEstimate'] as num?)?.toInt() ?? 0,
      );
}

/// Película clásica de Archive
class ArchiveMovie {
  final String identifier;
  final String title;
  final int downloads;
  final String year;

  const ArchiveMovie({
    required this.identifier,
    required this.title,
    this.downloads = 0,
    this.year = '',
  });

  String posterUrl(String ext) =>
      'https://archive.org/services/img/$identifier';

  String get watchUrl => 'https://archive.org/details/$identifier';
}

/// Variante de video reproducible de una película.
class MovieVariant {
  final String name;
  final String url;
  final String label;
  final int sizeBytes;

  const MovieVariant({
    required this.name,
    required this.url,
    required this.label,
    this.sizeBytes = 0,
  });
}

/// Fuente de lista agregada por el usuario (M3U o Xtream Codes).
class UserPlaylist {
  final String id;
  final String name;
  final String type; // 'm3u' | 'xtream'
  final String url; // URL M3U o host Xtream
  final String user;
  final String pass;

  const UserPlaylist({
    required this.id,
    required this.name,
    required this.type,
    required this.url,
    this.user = '',
    this.pass = '',
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'type': type,
        'url': url,
        'user': user,
        'pass': pass,
      };

  factory UserPlaylist.fromJson(Map<String, dynamic> j) => UserPlaylist(
        id: j['id'] as String,
        name: j['name'] as String? ?? 'Lista',
        type: j['type'] as String? ?? 'm3u',
        url: j['url'] as String? ?? '',
        user: j['user'] as String? ?? '',
        pass: j['pass'] as String? ?? '',
      );
}
