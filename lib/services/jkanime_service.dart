import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/models.dart';
import 'stream_validator.dart';
import 'tioanime_service.dart';

/// Resultado paginado real de episodios de JKAnime (soporta animes de +1,000 episodios).
class JkEpisodePageResult {
  final List<VodEpisode> episodes;
  final int currentPage;
  final int lastPage;
  final int totalEpisodes;
  final String animeAjaxId;

  const JkEpisodePageResult({
    required this.episodes,
    required this.currentPage,
    required this.lastPage,
    required this.totalEpisodes,
    this.animeAjaxId = '',
  });
}

/// Servicio de resolución directa de anime Full HD desde JKAnime (+5,077 animes completos).
/// Soporta paginación completa de episodios (One Piece 1,180+, DBZ 291+, etc.)
/// y resolución multi-servidor HLS para fallback automático.
class JkAnimeService {
  static final JkAnimeService _instance = JkAnimeService._internal();
  factory JkAnimeService() => _instance;
  JkAnimeService._internal();

  static const String baseUrl = 'https://jkanime.net';
  static const Map<String, String> _headers = {
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0 Safari/537.36',
  };

  /// Géneros oficiales populares de JKAnime
  static const List<Map<String, String>> genres = [
    {'path': '', 'label': 'Populares'},
    {'path': 'accion', 'label': 'Acción'},
    {'path': 'aventura', 'label': 'Aventura'},
    {'path': 'comedia', 'label': 'Comedia'},
    {'path': 'drama', 'label': 'Drama'},
    {'path': 'fantasia', 'label': 'Fantasía'},
    {'path': 'romance', 'label': 'Romance'},
    {'path': 'sci-fi', 'label': 'Sci-Fi'},
    {'path': 'shounen', 'label': 'Shounen'},
    {'path': 'seinen', 'label': 'Seinen'},
    {'path': 'sobrenatural', 'label': 'Sobrenatural'},
    {'path': 'deportes', 'label': 'Deportes'},
    {'path': 'terror', 'label': 'Terror'},
  ];

  final Map<String, _CachedJkSources> _cache = {};
  final Map<String, _JkAnimeMeta> _metaCache = {};
  String? _sessionCookie;
  String? _csrfToken;
  DateTime? _sessionExpiry;

  Future<void> _ensureSession() async {
    if (_sessionCookie != null &&
        _csrfToken != null &&
        _sessionExpiry != null &&
        DateTime.now().isBefore(_sessionExpiry!)) {
      return;
    }

    try {
      final res = await http
          .get(Uri.parse(baseUrl), headers: _headers)
          .timeout(const Duration(seconds: 8));
      final rawCookie = res.headers['set-cookie'] ?? '';
      _sessionCookie = _formatCookieHeader(rawCookie);
      final tokenMatch =
          RegExp(r'''name="csrf-token"\s+content="([^"]+)"''').firstMatch(res.body);
      _csrfToken = tokenMatch?.group(1) ?? '';
      _sessionExpiry = DateTime.now().add(const Duration(minutes: 30));
    } catch (e) {
      debugPrint('[JkAnimeService] Error obtaining session: $e');
    }
  }

  static String _formatCookieHeader(String setCookie) {
    final cookies = <String>[];
    final parts = setCookie.split(RegExp(r',\s*(?=[a-zA-Z0-9_\-]+=[^;]+)'));
    for (final p in parts) {
      final firstPart = p.split(';').first.trim();
      if (firstPart.contains('=')) {
        cookies.add(firstPart);
      }
    }
    return cookies.join('; ');
  }

  Future<List<VodItem>> fetchDirectory({int page = 1, String? genre}) async {
    try {
      final String url;
      if (genre != null && genre.isNotEmpty) {
        url = '$baseUrl/directorio?p=$page&genero=$genre&filtro=popularidad';
      } else {
        url = '$baseUrl/directorio?p=$page';
      }

      final res = await http
          .get(Uri.parse(url), headers: _headers)
          .timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return [];

      final html = res.body;
      const key = 'var animes = ';
      final st = html.indexOf(key);
      if (st == -1) return [];

      final startIdx = st + key.length;
      final endIdx = html.indexOf(';\n', startIdx);
      if (endIdx == -1) return [];

      final blob = html.substring(startIdx, endIdx);
      final j = jsonDecode(blob) as Map<String, dynamic>;
      final list = j['data'] as List? ?? [];

      final items = <VodItem>[];
      for (final a in list) {
        final slug = a['slug'] as String? ?? '';
        final title = a['title'] as String? ?? slug;
        final img = a['image'] as String? ?? '';
        final syn = a['synopsis'] as String? ?? '';
        final tipo = a['tipo'] as String? ?? 'Anime';

        if (slug.isEmpty) continue;
        final hdPoster = upgradePosterUrl(img, slug);

        items.add(VodItem(
          id: 'jk_$slug',
          title: title,
          poster: hdPoster,
          backdrop: hdPoster,
          overview: syn,
          genre: '$tipo · Sub Español',
          rating: '',
          isSeries: true,
          isAnime: true,
          slug: slug,
          provider: 'jkanime',
          quality: 'HD',
        ));
      }
      return items;
    } catch (e) {
      debugPrint('[JkAnimeService] Error cargando directorio pág $page: $e');
      return [];
    }
  }

  /// Convierte miniaturas borrosas de 60px (`/image/thumbnail/`) a portadas HD reales.
  static String upgradePosterUrl(String rawUrl, String slug) {
    final cleanSlug = slug.replaceAll('jk_', '').trim();
    if (rawUrl.isNotEmpty) {
      if (rawUrl.contains('/animes/image/thumbnail/')) {
        return rawUrl.replaceFirst('/animes/image/thumbnail/', '/animes/image/');
      }
      if (rawUrl.contains('/thumbnail/')) {
        return rawUrl.replaceFirst('/thumbnail/', '/');
      }
      return rawUrl;
    }
    if (cleanSlug.isNotEmpty) {
      return 'https://cdn.jkdesa.com/assets/images/animes/image/$cleanSlug.jpg';
    }
    return '';
  }

  /// Obtiene la sinopsis real en español y póster HD desde la ficha del anime.
  Future<({String overview, String poster})> fetchAnimeMetaDetails(
    String slug,
  ) async {
    final cleanSlug = slug.replaceAll('jk_', '').trim();
    if (cleanSlug.isEmpty) return (overview: '', poster: '');
    try {
      final res = await http
          .get(Uri.parse('$baseUrl/$cleanSlug/'), headers: _headers)
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return (overview: '', poster: '');
      final html = res.body;

      final synMatch =
          RegExp(r'<p\s+class="[^"]*sinopsis[^"]*"[^>]*>(.*?)</p>', dotAll: true)
                  .firstMatch(html) ??
              RegExp(r'<meta\s+name="description"\s+content="([^"]+)"')
                  .firstMatch(html);
      var syn = (synMatch?.group(1) ?? '')
          .replaceAll(RegExp(r'<[^>]+>'), ' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      if (syn.toLowerCase().startsWith('ver ')) {
        syn = '';
      }

      final ogImg = RegExp(r'<meta\s+property="og:image"\s+content="([^"]+)"')
          .firstMatch(html)
          ?.group(1);
      final poster = upgradePosterUrl(ogImg ?? '', cleanSlug);
      return (overview: syn, poster: poster);
    } catch (_) {
      return (overview: '', poster: upgradePosterUrl('', cleanSlug));
    }
  }

  Future<List<VodItem>> search(String query) async {
    final raw = query.trim();
    if (raw.isEmpty) return [];

    // JKAnime es sensible a tildes ("dragón ball" omitía DBZ y Super):
    // normalizamos acentos antes de consultar.
    final asciiQuery = StreamValidator.stripAccents(raw);
    final queriesToTry = <String>[
      asciiQuery,
      if (raw != asciiQuery) raw,
    ];

    final merged = <VodItem>[];
    final seen = <String>{};

    for (final q in queriesToTry) {
      final hits = await _performAjaxSearch(q);
      for (final it in hits) {
        if (seen.add(it.slug)) {
          merged.add(it);
        }
      }
      if (merged.length >= 10) break;
    }

    return merged;
  }

  Future<List<VodItem>> _performAjaxSearch(String q) async {
    try {
      await _ensureSession();
      final res = await http
          .post(
            Uri.parse('$baseUrl/ajax_search'),
            headers: {
              ..._headers,
              'Referer': '$baseUrl/',
              'X-Requested-With': 'XMLHttpRequest',
              if (_csrfToken != null) 'X-CSRF-TOKEN': _csrfToken!,
              if (_sessionCookie != null && _sessionCookie!.isNotEmpty)
                'Cookie': _sessionCookie!,
            },
            body: {
              if (_csrfToken != null) '_token': _csrfToken!,
              'q': q,
            },
          )
          .timeout(const Duration(seconds: 8));

      if (res.statusCode == 419) {
        _sessionCookie = null;
        _csrfToken = null;
        await _ensureSession();
        final retryRes = await http
            .post(
              Uri.parse('$baseUrl/ajax_search'),
              headers: {
                ..._headers,
                'Referer': '$baseUrl/',
                'X-Requested-With': 'XMLHttpRequest',
                if (_csrfToken != null) 'X-CSRF-TOKEN': _csrfToken!,
                if (_sessionCookie != null && _sessionCookie!.isNotEmpty)
                  'Cookie': _sessionCookie!,
              },
              body: {
                if (_csrfToken != null) '_token': _csrfToken!,
                'q': q,
              },
            )
            .timeout(const Duration(seconds: 8));
        if (retryRes.statusCode == 200) {
          return _parseAjaxSearch(retryRes.body);
        }
      }

      if (res.statusCode == 200) {
        return _parseAjaxSearch(res.body);
      }
    } catch (e) {
      debugPrint('[JkAnimeService] Error en búsqueda $q: $e');
    }
    return [];
  }

  List<VodItem> _parseAjaxSearch(String jsonStr) {
    try {
      final data = jsonDecode(jsonStr);
      if (data is! List) return [];
      final items = <VodItem>[];
      for (final it in data) {
        if (it is! Map) continue;
        final slug = it['slug']?.toString() ?? '';
        final title = it['title']?.toString() ?? slug;
        final thumb = it['thumbnail']?.toString() ?? '';
        final type = it['type']?.toString() ?? 'Anime';
        final status = it['status']?.toString() ?? '';

        if (slug.isEmpty) continue;
        final hdPoster = upgradePosterUrl(thumb, slug);

        items.add(VodItem(
          id: 'jk_$slug',
          title: title,
          poster: hdPoster,
          backdrop: hdPoster,
          overview: status.isNotEmpty ? 'Estado: $status' : '',
          genre: '$type · Sub Español',
          rating: '',
          isSeries: true,
          isAnime: true,
          slug: slug,
          provider: 'jkanime',
          quality: 'HD',
        ));
      }
      return items;
    } catch (e) {
      debugPrint('[JkAnimeService] Error parsing ajax search: $e');
      return [];
    }
  }

  Future<_JkAnimeMeta?> _resolveAnimeMeta(String slug) async {
    final cleanSlug = slug.replaceAll('jk_', '');
    if (_metaCache.containsKey(cleanSlug)) return _metaCache[cleanSlug];

    final pageUrl = '$baseUrl/$cleanSlug/';
    final res = await http
        .get(Uri.parse(pageUrl), headers: _headers)
        .timeout(const Duration(seconds: 8));
    if (res.statusCode != 200) return null;

    final html = res.body;
    final idMatch =
        RegExp(r'''/ajax/(?:search_)?episodes/(\d+)/''').firstMatch(html);
    if (idMatch == null) return null;

    final csrfMatch =
        RegExp(r'''name="csrf-token"\s+content="([^"]+)"''').firstMatch(html);
    final cookie = _formatCookieHeader(res.headers['set-cookie'] ?? '');

    final meta = _JkAnimeMeta(
      ajaxId: idMatch.group(1)!,
      csrf: csrfMatch?.group(1) ?? '',
      cookie: cookie,
      pageUrl: pageUrl,
    );
    _metaCache[cleanSlug] = meta;
    return meta;
  }

  /// Carga una página específica de episodios de JKAnime (16 episodios por página)
  /// devolviendo el total real (`totalEpisodes` y `lastPage`, p. ej. 1,180 en One Piece).
  Future<JkEpisodePageResult> fetchEpisodesPage(
    String slug, {
    int page = 1,
  }) async {
    final cleanSlug = slug.replaceAll('jk_', '');
    try {
      final meta = await _resolveAnimeMeta(cleanSlug);
      if (meta == null) {
        final fallback = List.generate(
          24,
          (i) => VodEpisode(
            id: '$baseUrl/$cleanSlug/${i + 1}/',
            title: 'Episodio ${i + 1}',
            episodeNumber: i + 1,
            seasonNumber: 1,
            duration: '24 min',
            overview: 'Capítulo subtitulado en español.',
            slug: '$cleanSlug/${i + 1}',
            provider: 'jkanime',
          ),
        );
        return JkEpisodePageResult(
          episodes: fallback,
          currentPage: 1,
          lastPage: 1,
          totalEpisodes: fallback.length,
        );
      }

      final url = page <= 1
          ? '$baseUrl/ajax/episodes/${meta.ajaxId}/'
          : '$baseUrl/ajax/episodes/${meta.ajaxId}/?p=$page';

      final postRes = await http
          .post(
            Uri.parse(url),
            headers: {
              ..._headers,
              if (meta.csrf.isNotEmpty) 'X-CSRF-TOKEN': meta.csrf,
              if (meta.cookie.isNotEmpty) 'Cookie': meta.cookie,
              'X-Requested-With': 'XMLHttpRequest',
              'Referer': meta.pageUrl,
            },
          )
          .timeout(const Duration(seconds: 10));

      if (postRes.statusCode == 200) {
        final j = jsonDecode(postRes.body) as Map<String, dynamic>;
        final data = j['data'] as List? ?? [];
        final total = (j['total'] as num?)?.toInt() ?? data.length;
        final lastPage = (j['last_page'] as num?)?.toInt() ?? 1;
        final eps = <VodEpisode>[];

        for (final ep in data) {
          final numVal = ep['number'] is int
              ? ep['number'] as int
              : int.tryParse(ep['number'].toString()) ?? 1;
          final title = ep['title'] as String? ?? 'Episodio $numVal';
          final img = ep['image'] as String? ?? '';
          final thumb = img.isNotEmpty
              ? 'https://cdn.jkdesa.com/assets/images/animes/video/image_thumb/$img'
              : '';

          eps.add(VodEpisode(
            id: '$baseUrl/$cleanSlug/$numVal/',
            title: title,
            episodeNumber: numVal,
            seasonNumber: 1,
            duration: '24 min',
            thumbnail: thumb,
            overview: 'Capítulo subtitulado en español.',
            slug: '$cleanSlug/$numVal',
            provider: 'jkanime',
          ));
        }

        eps.sort((a, b) => a.episodeNumber.compareTo(b.episodeNumber));
        return JkEpisodePageResult(
          episodes: eps,
          currentPage: page,
          lastPage: lastPage < 1 ? 1 : lastPage,
          totalEpisodes: total,
          animeAjaxId: meta.ajaxId,
        );
      }
    } catch (e) {
      debugPrint('[JkAnimeService] Error fetchEpisodesPage($slug, p=$page): $e');
    }

    return const JkEpisodePageResult(
      episodes: [],
      currentPage: 1,
      lastPage: 1,
      totalEpisodes: 0,
    );
  }

  /// Carga episodios completos de un anime.
  /// Para animes de hasta 64 episodios (4 páginas) carga todos en paralelo;
  /// para animes gigantes (One Piece, Naruto, DBZ) genera la lista completa hasta
  /// `totalEpisodes` manteniendo los metadatos reales de la página 1, de modo que
  /// el usuario pueda saltar directamente al episodio 1,000+ sin truncarse en 16!
  Future<List<VodEpisode>> fetchEpisodes(String slug) async {
    final cleanSlug = slug.replaceAll('jk_', '');
    try {
      final first = await fetchEpisodesPage(cleanSlug, page: 1);
      if (first.episodes.isEmpty) return [];

      // Si tiene hasta 4 páginas (<=64 episodios), descargar todas en paralelo con thumbnails reales
      if (first.lastPage > 1 && first.lastPage <= 4) {
        final rest = await Future.wait([
          for (var p = 2; p <= first.lastPage; p++)
            fetchEpisodesPage(cleanSlug, page: p),
        ]);
        final all = <VodEpisode>[...first.episodes];
        for (final r in rest) {
          all.addAll(r.episodes);
        }
        final seen = <int>{};
        final unique = all.where((e) => seen.add(e.episodeNumber)).toList()
          ..sort((a, b) => a.episodeNumber.compareTo(b.episodeNumber));
        return unique;
      }

      // Si es un anime largo (+64 episodios, ej. One Piece 1,180 / DBZ 291),
      // creamos el catálogo completo hasta totalEpisodes conservando los de pág 1
      // y resolviendo cada episodio al vuelo cuando el usuario lo abre.
      if (first.totalEpisodes > first.episodes.length) {
        final byNum = <int, VodEpisode>{
          for (final e in first.episodes) e.episodeNumber: e,
        };
        final full = <VodEpisode>[];
        for (var n = 1; n <= first.totalEpisodes; n++) {
          full.add(
            byNum[n] ??
                VodEpisode(
                  id: '$baseUrl/$cleanSlug/$n/',
                  title: 'Episodio $n',
                  episodeNumber: n,
                  seasonNumber: 1,
                  duration: '24 min',
                  overview: 'Episodio $n de $cleanSlug · Sub Español.',
                  slug: '$cleanSlug/$n',
                  provider: 'jkanime',
                ),
          );
        }
        return full;
      }

      return first.episodes;
    } catch (e) {
      debugPrint('[JkAnimeService] Error cargando episodios de $slug: $e');
      return [];
    }
  }

  /// Resuelve TODAS las fuentes HLS activas de un episodio de anime (multi-servidor)
  Future<List<StreamSource>> getEpisodeSources(
    String animeSlugOrId,
    int episodeNumber, {
    void Function(String status)? onStatus,
  }) async {
    final slug = animeSlugOrId.replaceAll('jk_', '');
    final key = '$slug/$episodeNumber';

    final cached = _cache[key];
    if (cached != null && DateTime.now().isBefore(cached.expiresAt)) {
      onStatus?.call('Preparando episodio...');
      return cached.sources;
    }

    final sources = <StreamSource>[];
    final seenUrls = <String>{};
    const playbackHeaders = {
      'Referer': 'https://jkanime.net/',
      'User-Agent':
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0 Safari/537.36',
    };

    try {
      final episodePageUrl = '$baseUrl/$slug/$episodeNumber/';
      onStatus?.call('Buscando servidores (Ep. $episodeNumber)...');
      final res = await http
          .get(Uri.parse(episodePageUrl), headers: _headers)
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) {
        onStatus?.call('Servidor no disponible temporalmente.');
        return [];
      }

      final regex = RegExp(
        r'''video\[\d+\]\s*=\s*['"]<iframe[^>]*src=['"]([^'"]+)['"]''',
      );
      final matches = regex.allMatches(res.body).toList();
      var idx = 0;

      for (final m in matches) {
        final playerUrl = m.group(1);
        if (playerUrl == null || !playerUrl.startsWith('http')) continue;
        idx++;
        onStatus?.call('Verificando servidor #$idx...');

        try {
          final pRes = await http
              .get(
                Uri.parse(playerUrl),
                headers: {
                  ..._headers,
                  'Referer': episodePageUrl,
                },
              )
              .timeout(const Duration(seconds: 7));

          if (pRes.statusCode != 200) continue;

          String? streamUrl;
          final m3Match = RegExp(r'''(https?://[^\s"'<>]+\.m3u8[^\s"'<>]*)''')
              .firstMatch(pRes.body);
          if (m3Match != null) {
            streamUrl = m3Match.group(1)!;
          } else {
            final atobMatch =
                RegExp(r'''atob\(\s*['"]([A-Za-z0-9+/=]{10,})['"]\)''')
                    .firstMatch(pRes.body);
            if (atobMatch != null) {
              try {
                final dec = utf8.decode(
                  base64.decode(atobMatch.group(1)!),
                  allowMalformed: true,
                );
                if (dec.contains('.m3u8') || dec.startsWith('http')) {
                  streamUrl = dec;
                }
              } catch (_) {}
            }
          }

          if (streamUrl != null &&
              streamUrl.isNotEmpty &&
              seenUrls.add(streamUrl)) {
            final valid = await StreamValidator.validateUrl(
              streamUrl,
              headers: playbackHeaders,
            );
            if (!valid) continue;
            sources.add(StreamSource(
              url: streamUrl,
              quality: 'Servidor #$idx · HD',
              server: 'jkanime',
              headers: playbackHeaders,
            ));
            if (sources.length >= 2) break;
          }
        } catch (_) {}
      }

      // Failover automático a TioAnime (YourUpload MP4 verificado) si JKAnime falló
      if (sources.isEmpty) {
        final backup = await TioAnimeService().resolveEpisodeFallback(
          slug,
          episodeNumber,
          onStatus: onStatus,
        );
        sources.addAll(backup);
      }

      if (sources.isNotEmpty) {
        _cache[key] = _CachedJkSources(
          sources,
          DateTime.now().add(const Duration(hours: 3)),
        );
      }
    } catch (e) {
      debugPrint('[JkAnimeService] Error resolviendo $slug/$episodeNumber: $e');
    }

    return sources;
  }

  /// Compatibilidad: devuelve la primera URL HLS activa
  Future<String?> resolveEpisodeStream(
    String animeSlugOrId,
    int episodeNumber,
  ) async {
    final list = await getEpisodeSources(animeSlugOrId, episodeNumber);
    return list.isNotEmpty ? list.first.url : null;
  }
}

class _JkAnimeMeta {
  final String ajaxId;
  final String csrf;
  final String cookie;
  final String pageUrl;
  const _JkAnimeMeta({
    required this.ajaxId,
    required this.csrf,
    required this.cookie,
    required this.pageUrl,
  });
}

class _CachedJkSources {
  final List<StreamSource> sources;
  final DateTime expiresAt;
  const _CachedJkSources(this.sources, this.expiresAt);
}
