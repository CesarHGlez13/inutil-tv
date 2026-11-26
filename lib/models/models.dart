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

/// Referencia a una temporada agrupada bajo un mismo título (p. ej. JKAnime
/// separa cada temporada en su propio slug: `kaijuu-8-gou` y
/// `kaijuu-8-gou-2nd-season`). Permite unificar todas las temporadas en una
/// sola tarjeta y resolver episodios por temporada al abrir la ficha.
class VodSeasonRef {
  final int seasonNumber;
  final String title;
  final String slug;
  final String provider;

  const VodSeasonRef({
    required this.seasonNumber,
    required this.title,
    required this.slug,
    this.provider = '',
  });

  Map<String, dynamic> toJson() => {
        'seasonNumber': seasonNumber,
        'title': title,
        'slug': slug,
        'provider': provider,
      };

  factory VodSeasonRef.fromJson(Map<String, dynamic> j) => VodSeasonRef(
        seasonNumber: (j['seasonNumber'] as num?)?.toInt() ?? 1,
        title: j['title'] as String? ?? '',
        slug: j['slug'] as String? ?? '',
        provider: j['provider'] as String? ?? '',
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

  /// Referencias de temporadas agrupadas (cuando un proveedor lista cada
  /// temporada como una entrada independiente con su propio slug).
  final List<VodSeasonRef> seasonRefs;

  /// Stills reales de «momentos destacados» (TMDB `w300`) que alimentan el
  /// canvas en vivo estilo Spotify de [LiveCanvasPreview] (v3.3.18). Los elige
  /// de forma determinista `VodCatalogService.pickHighlightStills` a partir de
  /// los stills ya resueltos por el relleno cruzado de v3.3.17; vacío => el
  /// canvas cae en el arte generado (`DynamicPosterCanvas`).
  final List<String> highlightStills;

  /// URL del logo oficial en PNG transparente (v3.3.28 estilo Crunchyroll).
  /// Resuelto vía [TitleLogoService] sobre TMDB o Fanart.tv.
  final String titleLogo;

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
    this.seasonRefs = const [],
    this.highlightStills = const [],
    this.titleLogo = '',
  });

  List<int> get seasons {
    final s = <int>{
      for (final e in episodes) e.seasonNumber,
      for (final r in seasonRefs) r.seasonNumber,
    }..remove(0);
    if (s.isEmpty) {
      return [for (var i = 1; i <= (seasonCount < 1 ? 1 : seasonCount); i++) i];
    }
    final list = s.toList()..sort();
    if (list.length == 1 && seasonCount > 1) {
      return [for (var i = 1; i <= seasonCount; i++) i];
    }
    return list;
  }

  /// Etiqueta corta de una temporada agrupada si el proveedor la nombró distinto.
  String? seasonLabelFor(int season) {
    for (final r in seasonRefs) {
      if (r.seasonNumber == season && r.title.isNotEmpty) return r.title;
    }
    return null;
  }

  List<VodEpisode> episodesForSeason(int season) =>
      episodes.where((e) => e.seasonNumber == season).toList();

  /// Agrupa entradas hermanas del MISMO show (una por temporada en el
  /// proveedor) bajo [this]: conserva la identidad de la base y UNE los
  /// episodios de las hermanas (dedupe por temporada#episodio). Base
  /// inmutable; devuelve una copia. (No confundir con [mergedWith], que
  /// reemplaza listas en lugar de unirlas.)
  VodItem groupedWithSeasonSiblings(List<VodEpisode> siblingEpisodes) {
    if (siblingEpisodes.isEmpty) return this;
    final seenKeys = <String>{
      for (final e in episodes) '${e.seasonNumber}#${e.episodeNumber}',
    };
    final merged = <VodEpisode>[...episodes];
    for (final e in siblingEpisodes) {
      final k = '${e.seasonNumber}#${e.episodeNumber}';
      if (seenKeys.add(k)) merged.add(e);
    }
    merged.sort((a, b) {
      final s = a.seasonNumber.compareTo(b.seasonNumber);
      return s != 0 ? s : a.episodeNumber.compareTo(b.episodeNumber);
    });
    final seasonsSet = <int>{
      for (final e in merged) e.seasonNumber,
      for (final r in seasonRefs) r.seasonNumber,
      if (seasonCount > 0) ...List.generate(seasonCount, (i) => i + 1),
    }..remove(0);
    return VodItem(
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
      episodes: merged,
      slug: slug,
      provider: provider,
      quality: quality,
      seasonCount: seasonsSet.length > 1 ? seasonsSet.length : seasonCount,
      episodeCount: merged.length > episodeCount ? merged.length : episodeCount,
      genrePath: genrePath,
      seasonRefs: seasonRefs,
      highlightStills: highlightStills.isNotEmpty
          ? highlightStills
          : selectHighlightStills(merged),
      titleLogo: titleLogo,
    );
  }

  /// Agrupa una entrada hermana completa ([sibling], p. ej. "Kaijuu 8-gou 2nd Season")
  /// bajo [this] preservando tanto los episodios ya cargados como las referencias
  /// de slug por temporada ([seasonRefs]) para carga diferida en el modal.
  VodItem groupedWithSiblingItem(
    VodItem sibling, {
    required int baseSeasonNumber,
    required int siblingSeasonNumber,
  }) {
    final refsBySlug = <String, VodSeasonRef>{};
    if (seasonRefs.isNotEmpty) {
      for (final r in seasonRefs) {
        if (r.slug.isNotEmpty) refsBySlug[r.slug] = r;
      }
    } else if (slug.isNotEmpty) {
      refsBySlug[slug] = VodSeasonRef(
        seasonNumber: baseSeasonNumber < 1 ? 1 : baseSeasonNumber,
        title: title,
        slug: slug,
        provider: provider,
      );
    }

    final sameProvider = provider.isEmpty ||
        sibling.provider.isEmpty ||
        sibling.provider == provider;

    if (sameProvider) {
      if (sibling.seasonRefs.isNotEmpty) {
        for (final r in sibling.seasonRefs) {
          if (r.slug.isNotEmpty &&
              (r.provider.isEmpty || r.provider == provider) &&
              !refsBySlug.containsKey(r.slug)) {
            refsBySlug[r.slug] = r;
          }
        }
      } else if (sibling.slug.isNotEmpty &&
          !refsBySlug.containsKey(sibling.slug)) {
        var assignedSeason = siblingSeasonNumber < 1 ? 1 : siblingSeasonNumber;
        final usedSeasons =
            refsBySlug.values.map((r) => r.seasonNumber).toSet();
        while (usedSeasons.contains(assignedSeason)) {
          assignedSeason++;
        }
        refsBySlug[sibling.slug] = VodSeasonRef(
          seasonNumber: assignedSeason,
          title: sibling.title,
          slug: sibling.slug,
          provider: sibling.provider,
        );
      }
    }

    final mergedRefs = refsBySlug.values.toList()
      ..sort((a, b) => a.seasonNumber.compareTo(b.seasonNumber));

    // Re-etiquetar episodios de la hermana con su número de temporada si venían en T1
    final siblingEps = sibling.episodes.map((e) {
      if (e.seasonNumber == 1 && siblingSeasonNumber > 1) {
        return VodEpisode(
          id: e.id,
          title: e.title,
          episodeNumber: e.episodeNumber,
          seasonNumber: siblingSeasonNumber,
          overview: e.overview,
          duration: e.duration,
          thumbnail: e.thumbnail,
          sources: e.sources,
          slug: e.slug,
          provider: e.provider,
        );
      }
      return e;
    }).toList();

    final withEps = groupedWithSeasonSiblings(siblingEps);
    final totalSeasons = {
      ...withEps.seasons,
      for (final r in mergedRefs) r.seasonNumber,
    }..remove(0);

    return VodItem(
      id: withEps.id,
      title: withEps.title,
      poster: withEps.poster.isNotEmpty ? withEps.poster : sibling.poster,
      backdrop:
          withEps.backdrop.isNotEmpty ? withEps.backdrop : sibling.backdrop,
      overview:
          withEps.overview.isNotEmpty ? withEps.overview : sibling.overview,
      year: withEps.year.isNotEmpty ? withEps.year : sibling.year,
      genre: withEps.genre.isNotEmpty ? withEps.genre : sibling.genre,
      rating: withEps.rating.isNotEmpty ? withEps.rating : sibling.rating,
      duration:
          withEps.duration.isNotEmpty ? withEps.duration : sibling.duration,
      isSeries: withEps.isSeries || sibling.isSeries,
      isAnime: withEps.isAnime || sibling.isAnime,
      sources: withEps.sources.isNotEmpty ? withEps.sources : sibling.sources,
      episodes: withEps.episodes,
      slug: withEps.slug,
      provider: withEps.provider,
      quality: withEps.quality.isNotEmpty ? withEps.quality : sibling.quality,
      seasonCount: totalSeasons.length > withEps.seasonCount
          ? totalSeasons.length
          : withEps.seasonCount,
      episodeCount: withEps.episodeCount,
      genrePath:
          withEps.genrePath.isNotEmpty ? withEps.genrePath : sibling.genrePath,
      seasonRefs: mergedRefs,
      highlightStills: withEps.highlightStills,
      titleLogo: withEps.titleLogo.isNotEmpty
          ? withEps.titleLogo
          : sibling.titleLogo,
    );
  }

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
        seasonCount:
            other.seasonCount > seasonCount ? other.seasonCount : seasonCount,
        episodeCount: other.episodeCount > episodeCount
            ? other.episodeCount
            : episodeCount,
        genrePath: other.genrePath.isNotEmpty ? other.genrePath : genrePath,
        seasonRefs: other.seasonRefs.length >= seasonRefs.length &&
                other.seasonRefs.isNotEmpty
            ? other.seasonRefs
            : seasonRefs,
        highlightStills: other.highlightStills.isNotEmpty
            ? other.highlightStills
            : (highlightStills.isNotEmpty
                ? highlightStills
                : selectHighlightStills(
                    other.episodes.isNotEmpty ? other.episodes : episodes)),
        titleLogo: other.titleLogo.isNotEmpty ? other.titleLogo : titleLogo,
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
        if (seasonRefs.isNotEmpty)
          'seasonRefs': seasonRefs.map((r) => r.toJson()).toList(),
        if (highlightStills.isNotEmpty) 'highlightStills': highlightStills,
        if (titleLogo.isNotEmpty) 'titleLogo': titleLogo,
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
        seasonRefs: (j['seasonRefs'] as List?)
                ?.map((r) => VodSeasonRef.fromJson(r as Map<String, dynamic>))
                .toList() ??
            const [],
        highlightStills: (j['highlightStills'] as List?)
                ?.map((e) => '$e')
                .where((e) => e.isNotEmpty)
                .toList() ??
            const [],
        titleLogo: j['titleLogo'] as String? ?? '',
      );

  VodItem copyWith({
    String? id,
    String? title,
    String? poster,
    String? backdrop,
    String? overview,
    String? year,
    String? genre,
    String? rating,
    String? duration,
    bool? isSeries,
    bool? isAnime,
    List<StreamSource>? sources,
    List<VodEpisode>? episodes,
    String? slug,
    String? provider,
    String? quality,
    int? seasonCount,
    int? episodeCount,
    String? genrePath,
    List<VodSeasonRef>? seasonRefs,
    List<String>? highlightStills,
    String? titleLogo,
  }) =>
      VodItem(
        id: id ?? this.id,
        title: title ?? this.title,
        poster: poster ?? this.poster,
        backdrop: backdrop ?? this.backdrop,
        overview: overview ?? this.overview,
        year: year ?? this.year,
        genre: genre ?? this.genre,
        rating: rating ?? this.rating,
        duration: duration ?? this.duration,
        isSeries: isSeries ?? this.isSeries,
        isAnime: isAnime ?? this.isAnime,
        sources: sources ?? this.sources,
        episodes: episodes ?? this.episodes,
        slug: slug ?? this.slug,
        provider: provider ?? this.provider,
        quality: quality ?? this.quality,
        seasonCount: seasonCount ?? this.seasonCount,
        episodeCount: episodeCount ?? this.episodeCount,
        genrePath: genrePath ?? this.genrePath,
        seasonRefs: seasonRefs ?? this.seasonRefs,
        highlightStills: highlightStills ?? this.highlightStills,
        titleLogo: titleLogo ?? this.titleLogo,
      );

  /// Stills deterministas de «momentos destacados» para el canvas en vivo
  /// (v3.3.18). Puro y sin red: ordena los capítulos por temporada/episodio,
  /// quita URLs repetidas y, si hay más de [max], reparte los picks a lo largo
  /// de la obra (primero, ~⅓, ~⅔, último) en vez de tomar sólo el arranque,
  /// igual que el canvas de Spotify no muestra siempre los mismos clips.
  static List<String> selectHighlightStills(
    List<VodEpisode> episodes, {
    int max = 4,
  }) {
    if (episodes.isEmpty || max < 1) return const [];
    final ordered = [...episodes]..sort((a, b) {
        final s = a.seasonNumber.compareTo(b.seasonNumber);
        return s != 0 ? s : a.episodeNumber.compareTo(b.episodeNumber);
      });

    final urls = <String>[];
    final seen = <String>{};
    for (final e in ordered) {
      final u = e.thumbnail.trim();
      if (u.isEmpty) continue;
      if (seen.add(u)) urls.add(u);
    }
    if (urls.isEmpty) return const [];
    if (urls.length <= max) return urls;
    if (max == 1) return [urls.first];

    final n = urls.length;
    final picks = <String>[];
    for (var k = 0; k < max; k++) {
      final url = urls[(k * (n - 1) / (max - 1)).round()];
      if (!picks.contains(url)) picks.add(url);
    }
    return picks;
  }
}
