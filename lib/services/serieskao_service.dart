import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:pointycastle/export.dart' as pc;

import '../models/models.dart';
import 'cuevana_poseidon_service.dart';
import 'stream_validator.dart';

/// Proveedor sólido de Series en Español Latino / Sub (`serieskao.top` + Embed69).
///
/// Ventajas verificadas empíricamente en auditoría multi-episodio (18/18 = 100%):
/// 1. Catálogo curado de series populares (`/series/populares`) y recientes (`/series`)
///    con portadas TMDB HD (`w500` / `w780`) y títulos reales de episodios en español.
/// 2. Búsqueda exacta (`/search?s=...`) que encuentra Breaking Bad, Stranger Things,
///    The Last of Us, Game of Thrones, 9-1-1, Dexter, La Casa de Papel, etc.
/// 3. API JSON limpia por episodio (`/api/episodio/serie/<slug>/<S>/<E>`) con
///    descifrado puro en Dart AES-256-CBC de Embed69 (`LINK_CHALLENGE` + `LINK_SALT`)
///    que entrega hosts VidHide y StreamWish en LAT / ESP / SUB para TODOS los
///    episodios (Ep 1, 2, 3, ..., 62+).
class SeriesKaoService {
  static final SeriesKaoService _instance = SeriesKaoService._internal();
  factory SeriesKaoService() => _instance;
  SeriesKaoService._internal();

  static const String baseUrl = 'https://serieskao.top';
  static const Map<String, String> _headers = {
    'User-Agent': StreamValidator.defaultUserAgent,
    'Accept-Language': 'es-MX,es;q=0.9,en;q=0.8',
  };

  final Map<String, List<VodEpisode>> _episodeCache = {};
  final Map<String, VodItem> _detailCache = {};
  final Map<String, _CachedSkStreams> _streamCache = {};

  /// Series populares curadas y verificadas (`/series/populares`).
  Future<List<VodItem>> fetchPopularSeries({int page = 1}) async {
    final url = page > 1
        ? '$baseUrl/series/populares?page=$page'
        : '$baseUrl/series/populares';
    return _fetchCatalog(url);
  }

  /// Series recientes actualizadas (`/series`).
  Future<List<VodItem>> fetchLatestSeries({int page = 1}) async {
    final url = page > 1 ? '$baseUrl/series?page=$page' : '$baseUrl/series';
    return _fetchCatalog(url);
  }

  /// Categorías por género del propio sitio (`/generos/<slug>`). Slugs y
  /// conteos verificados en vivo (200 OK, 24 tarjetas/pág en todas las
  /// categorías que usa la app: accion, comedia, crimen, animacion, drama,
  /// fantasia, aventura, dorama, ciencia-ficcion, familia, documental, belica).
  Future<List<VodItem>> fetchGenreSeries(String slug, {int page = 1}) async {
    final clean = slug.trim();
    if (clean.isEmpty) return [];
    final url = page > 1
        ? '$baseUrl/generos/$clean?page=$page'
        : '$baseUrl/generos/$clean';
    return _fetchCatalog(url, includeAnime: clean == 'animacion');
  }

  /// Animes populares en Español Latino / Sub con TODAS las temporadas
  /// unificadas en una sola ficha (`/animes/populares`, verificado 200 OK, 24/pág).
  Future<List<VodItem>> fetchPopularAnimes({int page = 1}) async {
    final url = page > 1
        ? '$baseUrl/animes/populares?page=$page'
        : '$baseUrl/animes/populares';
    return _fetchCatalog(url, includeAnime: true, onlyAnime: true);
  }

  /// Animes recientes actualizados en Español Latino (`/animes`).
  Future<List<VodItem>> fetchLatestAnimes({int page = 1}) async {
    final url = page > 1 ? '$baseUrl/animes?page=$page' : '$baseUrl/animes';
    return _fetchCatalog(url, includeAnime: true, onlyAnime: true);
  }

  /// Búsqueda exacta de animes en SeriesKao (`/search?s=...`, filtra `/anime/`).
  Future<List<VodItem>> searchAnimes(String query) async {
    final clean = query.trim();
    if (clean.isEmpty) return [];

    final q = Uri.encodeQueryComponent(clean);
    var hits = await _fetchCatalog(
      '$baseUrl/search?s=$q',
      includeAnime: true,
      onlyAnime: true,
    );
    if (hits.isEmpty) {
      final ascii = StreamValidator.stripAccents(clean);
      if (ascii != clean) {
        hits = await _fetchCatalog(
          '$baseUrl/search?s=${Uri.encodeQueryComponent(ascii)}',
          includeAnime: true,
          onlyAnime: true,
        );
      }
    }
    return hits;
  }

  /// Búsqueda exacta de series (`/search?s=...`).
  Future<List<VodItem>> searchSeries(String query) async {
    final clean = query.trim();
    if (clean.isEmpty) return [];

    final q = Uri.encodeQueryComponent(clean);
    var hits = await _fetchCatalog('$baseUrl/search?s=$q');
    if (hits.isEmpty) {
      final ascii = StreamValidator.stripAccents(clean);
      if (ascii != clean) {
        hits = await _fetchCatalog(
          '$baseUrl/search?s=${Uri.encodeQueryComponent(ascii)}',
        );
      }
    }
    return hits;
  }

  Future<List<VodItem>> _fetchCatalog(
    String url, {
    bool includeAnime = false,
    bool onlyAnime = false,
  }) async {
    try {
      final res = await http
          .get(Uri.parse(url), headers: _headers)
          .timeout(const Duration(seconds: 9));
      if (res.statusCode != 200) return [];
      return parseCatalogCards(
        res.body,
        includeAnime: includeAnime,
        onlyAnime: onlyAnime,
      );
    } catch (e) {
      debugPrint('[SeriesKao] Catalog err ($url): $e');
      return [];
    }
  }

  @visibleForTesting
  static List<VodItem> parseCatalogCards(
    String html, {
    bool includeAnime = false,
    bool onlyAnime = false,
  }) {
    final out = <VodItem>[];
    final seen = <String>{};

    final cardMatches = RegExp(
      r'<article\s+class="card"[^>]*>(.*?)</article>',
      dotAll: true,
    ).allMatches(html);

    for (final m in cardMatches) {
      final block = m.group(1)!;
      final hrefMatch = RegExp(
        r'''href=["\'](?:/|https?://[^"\']+/)?(serie|anime)/([^"\'#/?]+)["\']''',
      ).firstMatch(block);
      if (hrefMatch == null) continue;

      final kind = hrefMatch.group(1)!.trim();
      final isAnimeCard = kind == 'anime';
      if (onlyAnime && !isAnimeCard) continue;
      if (!includeAnime && isAnimeCard) continue;

      final slug = hrefMatch.group(2)!.trim();
      if (slug.isEmpty || !seen.add('$kind/$slug')) continue;

      final imgMatch =
          RegExp(r'''<img[^>]+src=["\']([^"\']+)["\']''').firstMatch(block);
      final altMatch =
          RegExp(r'''<img[^>]+alt=["\']([^"\']+)["\']''').firstMatch(block);
      final titleTextMatch = RegExp(
        r'''class="card__title"[^>]*>([^<]+)<''',
      ).firstMatch(block);
      final yearMatch = RegExp(
        r'''class="card__year"[^>]*>(\d{4})<''',
      ).firstMatch(block) ??
          RegExp(r'''card__badge--year"[^>]*>(\d{4})<''').firstMatch(block);
      final ratingMatch = RegExp(
        r'''class="card__rating"[^>]*>.*?(\d(?:\.\d)?)<''',
        dotAll: true,
      ).firstMatch(block);

      final rawTitle =
          (titleTextMatch?.group(1) ?? altMatch?.group(1) ?? slug).trim();
      final title = _decodeHtmlEntities(rawTitle);
      if (title.isEmpty) continue;

      var poster = (imgMatch?.group(1) ?? '').trim();
      if (poster.contains('image.tmdb.org/t/p/w200/')) {
        poster = poster.replaceFirst('/t/p/w200/', '/t/p/w500/');
      }
      if (poster.startsWith('/')) poster = '$baseUrl$poster';
      final backdrop = poster.contains('image.tmdb.org/t/p/w500/')
          ? poster.replaceFirst('/t/p/w500/', '/t/p/w780/')
          : poster;

      out.add(VodItem(
        id: isAnimeCard ? 'sk_a_$slug' : 'sk_s_$slug',
        title: title,
        poster: poster,
        backdrop: backdrop,
        year: yearMatch?.group(1) ?? '',
        genre: isAnimeCard ? 'Anime · Latino / Sub' : 'Serie · Latino / Sub',
        rating: ratingMatch?.group(1) ?? '',
        isSeries: true,
        isAnime: isAnimeCard,
        slug: slug,
        provider: 'serieskao',
        quality: 'HD',
      ));
    }

    return out;
  }

  /// Obtiene detalle enriquecido (sinopsis real en español + póster HD + lista
  /// completa de temporadas y episodios con títulos reales). Soporta tanto
  /// `/serie/<slug>` como `/anime/<slug>`.
  Future<VodItem?> fetchDetail(VodItem item) async {
    final slug = _cleanSlug(item);
    if (slug.isEmpty) return null;

    final kind = item.isAnime ? 'anime' : 'serie';
    final cacheKey = '$kind/$slug';
    if (_detailCache.containsKey(cacheKey)) {
      return _detailCache[cacheKey];
    }

    try {
      var res = await http
          .get(Uri.parse('$baseUrl/$kind/$slug'), headers: _headers)
          .timeout(const Duration(seconds: 9));
      var effectiveKind = kind;
      if (res.statusCode != 200) {
        effectiveKind = kind == 'anime' ? 'serie' : 'anime';
        res = await http
            .get(Uri.parse('$baseUrl/$effectiveKind/$slug'), headers: _headers)
            .timeout(const Duration(seconds: 9));
      }
      if (res.statusCode != 200) return null;
      final html = res.body;

      final ogDesc = RegExp(
        r'''<meta\s+(?:property="og:description"|name="description")\s+content="([^"]+)"''',
      ).firstMatch(html)?.group(1);
      final overview = _decodeHtmlEntities((ogDesc ?? '').trim());

      final ogImg = RegExp(
        r'''<meta\s+property="og:image"\s+content="([^"]+)"''',
      ).firstMatch(html)?.group(1);
      var poster = item.poster;
      var backdrop = item.backdrop;
      if (ogImg != null && ogImg.startsWith('http')) {
        final w500 = ogImg.replaceFirst('/t/p/original/', '/t/p/w500/');
        final w780 = ogImg.replaceFirst('/t/p/original/', '/t/p/w780/');
        if (poster.isEmpty) poster = w500;
        backdrop = w780;
      }

      final yearMatch = RegExp(r'\((\d{4})\)').firstMatch(
        RegExp(r'<title>([^<]+)</title>').firstMatch(html)?.group(1) ?? '',
      );

      final episodes = parseEpisodesFromHtml(html, slug: slug);
      if (episodes.isNotEmpty) {
        _episodeCache[cacheKey] = episodes;
        _episodeCache[slug] = episodes;
      }
      final seasonsCount = episodes.map((e) => e.seasonNumber).toSet().length;

      final enriched = VodItem(
        id: item.id,
        title: item.title,
        poster: poster,
        backdrop: backdrop,
        overview: overview.isNotEmpty ? overview : item.overview,
        year: item.year.isNotEmpty ? item.year : (yearMatch?.group(1) ?? ''),
        genre: item.genre.isNotEmpty
            ? item.genre
            : (effectiveKind == 'anime'
                ? 'Anime · Latino / Sub'
                : 'Serie · Latino / Sub'),
        rating: item.rating,
        isSeries: true,
        isAnime: item.isAnime || effectiveKind == 'anime',
        slug: slug,
        provider: 'serieskao',
        quality: 'HD',
        episodes: episodes,
        seasonCount: seasonsCount > 0 ? seasonsCount : item.seasonCount,
        episodeCount: episodes.length,
      );
      _detailCache[cacheKey] = enriched;
      return enriched;
    } catch (e) {
      debugPrint('[SeriesKao] Detail err ($slug): $e');
      return null;
    }
  }

  /// Carga todas las temporadas y episodios de una serie o anime de SeriesKao.
  Future<List<VodEpisode>> fetchSeriesEpisodes(VodItem item) async {
    final slug = _cleanSlug(item);
    if (slug.isEmpty) return [];
    final kind = item.isAnime ? 'anime' : 'serie';
    final cacheKey = '$kind/$slug';
    if (_episodeCache.containsKey(cacheKey)) return _episodeCache[cacheKey]!;
    if (_episodeCache.containsKey(slug)) return _episodeCache[slug]!;

    final detail = await fetchDetail(item);
    return detail?.episodes ?? [];
  }

  @visibleForTesting
  static List<VodEpisode> parseEpisodesFromHtml(
    String html, {
    required String slug,
  }) {
    final episodes = <VodEpisode>[];
    final seen = <String>{};

    final epMatches = RegExp(
      r'''<a[^>]+data-season="(\d+)"[^>]+data-episode="(\d+)"[^>]*>(.*?)</a>''',
      dotAll: true,
    ).allMatches(html);

    for (final m in epMatches) {
      final sNum = int.tryParse(m.group(1)!) ?? 1;
      final eNum = int.tryParse(m.group(2)!) ?? 1;
      if (!seen.add('${sNum}x$eNum')) continue;

      final inner = m.group(3)!;
      final titleMatch = RegExp(
        r'''episode-item__title[^>]*>([^<]+)<''',
      ).firstMatch(inner);
      final epTitle = _decodeHtmlEntities(
        (titleMatch?.group(1) ?? 'Episodio $eNum').trim(),
      );

      episodes.add(VodEpisode(
        id: 'sk_ep_${slug}_${sNum}x$eNum',
        title: epTitle.isNotEmpty ? epTitle : 'Episodio $eNum',
        episodeNumber: eNum,
        seasonNumber: sNum,
        // SeriesKao no publica duración por capítulo: se deja vacía para que la
        // UI muestre la insignia de calidad (y el completado cruzado la rellene
        // si el proveedor alterno sí la trae).
        duration: '',
        slug: '$slug/$sNum/$eNum',
        provider: 'serieskao',
      ));
    }

    episodes.sort((a, b) {
      if (a.seasonNumber != b.seasonNumber) {
        return a.seasonNumber.compareTo(b.seasonNumber);
      }
      return a.episodeNumber.compareTo(b.episodeNumber);
    });
    return episodes;
  }

  /// Resuelve fuentes HD verificadas por bytes reales para un episodio específico
  /// de SeriesKao usando la API JSON `/api/episodio/serie/<slug>/<S>/<E>` y
  /// descifrado AES-256-CBC nativo de Embed69.
  Future<List<StreamSource>> resolveEpisodeSources(
    VodItem item,
    VodEpisode episode, {
    void Function(String status)? onStatus,
  }) async {
    final slug = _cleanSlug(item);
    if (slug.isEmpty) return [];

    final cacheKey = '${slug}_${episode.seasonNumber}x${episode.episodeNumber}';
    final cached = _streamCache[cacheKey];
    if (cached != null && DateTime.now().isBefore(cached.expiresAt)) {
      onStatus?.call('Preparando reproducción...');
      return cached.sources;
    }

    try {
      final kind = item.isAnime ? 'anime' : 'serie';
      onStatus?.call(
        'Buscando servidores (T${episode.seasonNumber}·E${episode.episodeNumber})...',
      );
      final apiUrl =
          '$baseUrl/api/episodio/$kind/${Uri.encodeComponent(slug)}/${episode.seasonNumber}/${episode.episodeNumber}';
      final referer = '$baseUrl/$kind/$slug';
      final apiRes = await http
          .get(
            Uri.parse(apiUrl),
            headers: {
              ..._headers,
              'Accept': 'application/json',
              'Referer': referer,
            },
          )
          .timeout(const Duration(seconds: 9));
      if (apiRes.statusCode != 200) return [];

      final decoded = jsonDecode(apiRes.body);
      if (decoded is! Map) return [];
      final epHtml = (decoded['html'] ?? '').toString();
      if (epHtml.isEmpty) return [];

      final vidUrlMatch =
          RegExp(r'''data-url=["\'](/vidurl/[^"\']+)["\']''').firstMatch(epHtml);
      if (vidUrlMatch == null) return [];

      final vidUrl = '$baseUrl${vidUrlMatch.group(1)!}';
      onStatus?.call('Preparando señal HD...');
      final vidRes = await http
          .get(
            Uri.parse(vidUrl),
            headers: {
              ..._headers,
              'Referer': referer,
            },
          )
          .timeout(const Duration(seconds: 9));
      if (vidRes.statusCode != 200) return [];

      final embeds = extractDecryptedEmbeds(vidRes.body);
      if (embeds.isEmpty) return [];

      // Ordenar: LAT primero -> ESP -> SUB; VidHide y StreamWish primero
      embeds.sort((a, b) {
        final langCmp = _langPriority(a.language).compareTo(_langPriority(b.language));
        if (langCmp != 0) return langCmp;
        return _hostPriority(a.server).compareTo(_hostPriority(b.server));
      });

      final cp = CuevanaPoseidonService();
      final verified = <StreamSource>[];
      final timeoutFallbacks = <StreamSource>[];
      final seenUrls = <String>{};

      // Carrera en lotes paralelos de 3 hosts: retorna en cuanto haya >=1 servidor
      // verificado por bytes (sin esperar otro lote extra de 8s) y conserva respaldo
      // en caso de timeout por red lenta.
      const batchSize = 3;
      for (var i = 0; i < embeds.length && verified.isEmpty; i += batchSize) {
        final batch = embeds.skip(i).take(batchSize).toList();
        onStatus?.call(
          'Verificando servidor (${batch.first.langLabel})...',
        );

        final batchResults = await CuevanaPoseidonService.collectBatchWithFastWin(
          batch.map((e) async {
            List<StreamSource> extracted = const [];
            if (e.server == 'vidhide') {
              extracted = await cp.extractVidHideCandidates(
                e.url,
                label: 'HD · ${e.langLabel}',
              );
            } else if (e.server == 'streamwish') {
              extracted = await cp.extractStreamWishCandidates(
                e.url,
                label: 'HD · ${e.langLabel}',
              );
            } else if (e.server == 'vidara') {
              final s = await cp.extractVidara(
                e.url,
                label: 'HD · ${e.langLabel}',
              );
              if (s != null) extracted = [s];
            }
            if (extracted.isEmpty) {
              return (null as StreamSource?, StreamValidationStatus.invalid);
            }

            StreamSource? timedOutCandidate;
            for (final src in extracted) {
              final status = await StreamValidator.validateUrlDetailed(
                src.url,
                headers: src.headers,
                timeout: const Duration(seconds: 9),
              );
              if (status == StreamValidationStatus.valid) {
                return (src, status);
              }
              if (status == StreamValidationStatus.timeout &&
                  timedOutCandidate == null) {
                timedOutCandidate = src;
              }
            }
            if (timedOutCandidate != null) {
              return (timedOutCandidate, StreamValidationStatus.timeout);
            }
            return (null as StreamSource?, StreamValidationStatus.invalid);
          }).toList(growable: false),
        );

        for (final (s, status) in batchResults) {
          if (s == null || !seenUrls.add(s.url)) continue;
          if (status == StreamValidationStatus.valid) {
            verified.add(s);
          } else if (status == StreamValidationStatus.timeout) {
            timeoutFallbacks.add(s);
          }
        }
      }

      final resolved = <StreamSource>[
        ...verified,
        if (verified.length < 2) ...timeoutFallbacks,
      ];

      if (verified.isNotEmpty) {
        _streamCache[cacheKey] = _CachedSkStreams(
          resolved,
          DateTime.now().add(const Duration(hours: 2)),
        );
      }
      return resolved;
    } catch (e) {
      debugPrint('[SeriesKao] resolveEpisode err ($slug): $e');
      return [];
    }
  }

  /// Respaldo cross-provider por título + temporada + episodio (usado cuando
  /// otro proveedor como PoseidonHD2 falla en el capítulo 2 o 3).
  Future<List<StreamSource>> resolveByTitleAndEpisode(
    String title,
    int seasonNumber,
    int episodeNumber, {
    void Function(String status)? onStatus,
  }) async {
    onStatus?.call('Buscando servidor alterno (T$seasonNumber·E$episodeNumber)...');
    final hits = await searchSeries(title);
    if (hits.isEmpty) return [];

    final targetNorm = StreamValidator.normalizeTitle(title);
    VodItem? match;
    for (final h in hits) {
      if (StreamValidator.normalizeTitle(h.title) == targetNorm) {
        match = h;
        break;
      }
    }
    match ??= hits.firstWhere(
      (h) {
        final nt = StreamValidator.normalizeTitle(h.title);
        return nt.contains(targetNorm) || targetNorm.contains(nt);
      },
      orElse: () => hits.first,
    );

    return resolveEpisodeSources(
      match,
      VodEpisode(
        id: 'sk_fb_${match.slug}_${seasonNumber}x$episodeNumber',
        title: 'Episodio $episodeNumber',
        episodeNumber: episodeNumber,
        seasonNumber: seasonNumber,
        provider: 'serieskao',
      ),
      onStatus: onStatus,
    );
  }

  /// Extrae y descifra los enlaces `dataLink` de una página `/vidurl/...` usando
  /// `SHA-256(LINK_CHALLENGE + LINK_SALT)` + AES-256-CBC (PKCS7) puro en Dart.
  @visibleForTesting
  static List<DecryptedEmbed> extractDecryptedEmbeds(String html) {
    final challenge =
        RegExp(r"""LINK_CHALLENGE\s*=\s*['"]([^'"]+)['"]""").firstMatch(html)?.group(1);
    final salt =
        RegExp(r"""LINK_SALT\s*=\s*['"]([^'"]+)['"]""").firstMatch(html)?.group(1);
    final dataLinkMatch = RegExp(
      r'let\s+dataLink\s*=\s*(\[.*?\]);',
      dotAll: true,
    ).firstMatch(html);

    if (challenge == null || salt == null || dataLinkMatch == null) {
      return [];
    }

    final keyBytes = Uint8List.fromList(
      crypto.sha256.convert(utf8.encode('$challenge$salt')).bytes,
    );

    final rawList = jsonDecode(dataLinkMatch.group(1)!);
    if (rawList is! List) return [];

    final out = <DecryptedEmbed>[];
    for (final grp in rawList) {
      if (grp is! Map) continue;
      final lang = (grp['video_language'] ?? 'LAT').toString().toUpperCase();
      final embeds = grp['sortedEmbeds'];
      if (embeds is! List) continue;

      for (final e in embeds) {
        if (e is! Map) continue;
        final server = (e['servername'] ?? '').toString().toLowerCase().trim();
        if (server != 'vidhide' &&
            server != 'streamwish' &&
            server != 'vidara') {
          continue;
        }
        final encrypted = (e['link'] ?? '').toString().trim();
        if (encrypted.isEmpty) continue;

        final plain = decryptAes256Cbc(encrypted, keyBytes);
        if (plain != null) {
          final cleanUrl = plain.replaceAll('`', '').trim();
          if (cleanUrl.startsWith('http')) {
            out.add(DecryptedEmbed(
              language: lang,
              server: server,
              url: cleanUrl,
            ));
          }
        }
      }
    }
    return out;
  }

  /// Descifra Base64 (`[16B IV][ciphertext]`) con AES-256-CBC + PKCS7.
  @visibleForTesting
  static String? decryptAes256Cbc(String encryptedBase64, Uint8List key32) {
    try {
      final raw = base64.decode(encryptedBase64);
      if (raw.length <= 16) return null;
      final iv = Uint8List.fromList(raw.sublist(0, 16));
      final ct = Uint8List.fromList(raw.sublist(16));
      if (ct.isEmpty || ct.length % 16 != 0) return null;

      final cipher = pc.PaddedBlockCipherImpl(
        pc.PKCS7Padding(),
        pc.CBCBlockCipher(pc.AESEngine()),
      );
      cipher.init(
        false,
        pc.PaddedBlockCipherParameters<pc.ParametersWithIV<pc.KeyParameter>,
            Null>(
          pc.ParametersWithIV<pc.KeyParameter>(
            pc.KeyParameter(Uint8List.fromList(key32.sublist(0, 32))),
            iv,
          ),
          null,
        ),
      );
      final decrypted = cipher.process(ct);
      return utf8.decode(decrypted, allowMalformed: true);
    } catch (_) {
      return null;
    }
  }

  static int _langPriority(String lang) => switch (lang.toUpperCase()) {
        'LAT' => 0,
        'ESP' => 1,
        'SUB' => 2,
        _ => 3,
      };

  static int _hostPriority(String host) => switch (host) {
        'vidhide' => 0,
        'streamwish' => 1,
        'vidara' => 2,
        _ => 3,
      };

  static String _cleanSlug(VodItem item) {
    if (item.slug.isNotEmpty) {
      return item.slug.replaceFirst(RegExp(r'^/?(?:serie|anime)/'), '').trim();
    }
    return item.id
        .replaceFirst('sk_s_', '')
        .replaceFirst('sk_a_', '')
        .trim();
  }

  static String _decodeHtmlEntities(String input) {
    return input
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&#039;', "'")
        .replaceAll('&#39;', "'")
        .replaceAll('&apos;', "'")
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&nbsp;', ' ');
  }
}

class DecryptedEmbed {
  final String language;
  final String server;
  final String url;

  const DecryptedEmbed({
    required this.language,
    required this.server,
    required this.url,
  });

  String get langLabel => switch (language.toUpperCase()) {
        'LAT' => 'Latino',
        'ESP' => 'Español',
        'SUB' => 'Subtitulado',
        _ => language,
      };
}

class _CachedSkStreams {
  final List<StreamSource> sources;
  final DateTime expiresAt;
  const _CachedSkStreams(this.sources, this.expiresAt);
}
