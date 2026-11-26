import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/models.dart';
import 'stream_validator.dart';

/// Servicio central de catálogo y resolución multi-servidor de PelisFlix para InútilTV.
/// Incluye:
/// - Carga paralela de temporadas (5x más rápido en series largas).
/// - Resolución multi-servidor (Nupload + VOE + directos) con reporte de estado paso a paso.
/// - Filtrado inteligente de búsqueda para evitar resultados basura.
class PelisflixService {
  static final PelisflixService _instance = PelisflixService._internal();
  factory PelisflixService() => _instance;
  PelisflixService._internal();

  static const String baseUrl = 'https://pelisflix1.guru';
  static const List<String> mirrors = [
    'https://pelisflix1.guru',
    'https://pelisflix.bio',
  ];

  static const Map<String, String> _headers = {
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0 Safari/537.36',
    'Accept-Language': 'es-MX,es;q=0.9',
  };

  final Map<String, _CachedSources> _cache = {};

  /// 19 géneros oficiales de PelisFlix mapeados con etiquetas legibles
  static const List<Map<String, String>> genres = [
    {'path': 'accion', 'label': 'Acción'},
    {'path': 'animacion', 'label': 'Animación'},
    {'path': 'anime', 'label': 'Anime'},
    {'path': 'aventura', 'label': 'Aventura'},
    {'path': 'belica', 'label': 'Bélica'},
    {'path': 'ciencia-ficcion', 'label': 'Ciencia Ficción'},
    {'path': 'comedia', 'label': 'Comedia'},
    {'path': 'crimen', 'label': 'Crimen'},
    {'path': 'dc', 'label': 'DC Comics'},
    {'path': 'disney', 'label': 'Disney'},
    {'path': 'documental', 'label': 'Documentales'},
    {'path': 'drama', 'label': 'Drama'},
    {'path': 'familia', 'label': 'Familia'},
    {'path': 'fantasia', 'label': 'Fantasía'},
    {'path': 'marvel', 'label': 'Marvel'},
    {'path': 'musical', 'label': 'Musical'},
    {'path': 'romance', 'label': 'Romance'},
    {'path': 'suspense', 'label': 'Suspenso'},
    {'path': 'terror', 'label': 'Terror'},
  ];

  Future<List<VodItem>> fetchMovies({int page = 1, String? genre}) async {
    final String url;
    if (genre != null && genre.isNotEmpty) {
      url = page > 1
          ? '$baseUrl/genero/$genre/page/$page/'
          : '$baseUrl/genero/$genre/';
    } else {
      url = page > 1
          ? '$baseUrl/peliculas-online/page/$page/'
          : '$baseUrl/peliculas-online/';
    }
    return _parseCatalogPage(url, isSeries: false);
  }

  Future<List<VodItem>> fetchSeries({int page = 1}) async {
    final url = page > 1
        ? '$baseUrl/series-online/page/$page/'
        : '$baseUrl/series-online/';
    return _parseCatalogPage(url, isSeries: true);
  }

  /// Búsqueda server-side con filtrado de relevancia (evita resultados sin relación)
  Future<List<VodItem>> search(String query) async {
    final clean = query.trim();
    if (clean.isEmpty) return [];

    final q = Uri.encodeComponent(clean);
    var items = await _parseCatalogPage('$baseUrl/?s=$q', isSeries: false);

    if (items.isEmpty && clean.contains(' ')) {
      final plusQuery = clean.replaceAll(RegExp(r'\s+'), '+');
      items = await _parseCatalogPage('$baseUrl/?s=$plusQuery', isSeries: false);
    }

    if (items.isEmpty) return [];

    // Filtrar ruido evidente cuando PelisFlix devuelve un fallback irrelevante
    final tokens = clean
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((t) => t.length >= 2)
        .toList();
    if (tokens.isEmpty) return items;

    final relevant = items.where((it) {
      final hay = '${it.title} ${it.slug}'.toLowerCase();
      return tokens.any((t) => hay.contains(t));
    }).toList();

    return relevant.isNotEmpty ? relevant : <VodItem>[];
  }

  Future<List<VodItem>> _parseCatalogPage(
    String url, {
    required bool isSeries,
  }) async {
    try {
      final res = await http
          .get(Uri.parse(url), headers: _headers)
          .timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return [];
      return parseItemsFromHtml(res.body, defaultIsSeries: isSeries);
    } catch (e) {
      debugPrint('[PelisflixService] Error cargando $url: $e');
      return [];
    }
  }

  List<VodItem> parseItemsFromHtml(String html, {bool defaultIsSeries = false}) {
    final items = <VodItem>[];
    final seenSlugs = <String>{};
    final seenTitles = <String>{};

    final liMatches =
        RegExp(r'''<li[^>]*>(.*?)</li>''', dotAll: true).allMatches(html);
    for (final m in liMatches) {
      final b = m.group(1)!;
      final urlMatch = RegExp(
        r'''href=["\'](https?://[^"\'/]+/(pelicula|serie[s]?)/([^"\'/]+)/?)["\']''',
      ).firstMatch(b);
      if (urlMatch == null) continue;

      final typeStr = urlMatch.group(2)!;
      final slug = urlMatch.group(3)!;
      if (seenSlugs.contains(slug)) continue;

      final isSeries = typeStr.startsWith('serie') || defaultIsSeries;

      final titleMatch = RegExp(r'''class=["\']Title["\']>([^<]+)<''').firstMatch(b) ??
          RegExp(r'''alt=["\']([^"\']+)["\']''').firstMatch(b);
      final title = titleMatch?.group(1)?.trim() ?? slug.replaceAll('-', ' ');

      final imgMatch = RegExp(r'''data-src=["\']([^"\']+)["\']''').firstMatch(b) ??
          RegExp(r'''src=["\']([^"\']+)["\']''').firstMatch(b);
      var poster = imgMatch?.group(1) ?? '';
      if (poster.startsWith('//')) poster = 'https:$poster';

      // Descartar duplicados rotos con portada 404x.jpg (casi siempre sin servidores)
      if (poster.isEmpty || poster.contains('404x.jpg')) continue;

      final normTitle = StreamValidator.normalizeTitle(title);
      if (normTitle.isNotEmpty && !seenTitles.add(normTitle)) continue;

      final yearMatch = RegExp(r'''class=["\']Year["\']>([^<]*)<''').firstMatch(b) ??
          RegExp(r'''class=["\']year[^"\']*["\']>([^<]*)<''').firstMatch(b);
      final year = yearMatch?.group(1)?.trim() ?? '';

      seenSlugs.add(slug);
      items.add(VodItem(
        id: 'pf_${typeStr}_$slug',
        title: title,
        poster: poster,
        backdrop: poster,
        year: year,
        genre: isSeries ? 'Serie · Latino / Sub' : 'Película · Latino / Sub',
        rating: '',
        isSeries: isSeries,
        slug: slug,
        provider: 'pelisflix',
        quality: 'HD',
      ));
    }

    if (items.isNotEmpty) return items;

    final legacyMatches = RegExp(
      r'''href=["\']https?://[^"\'/]+/(pelicula|serie[s]?)/([^"\'/]+)/?["\'].*?<img[^>]+src=["\']([^"\']+)["\'].*?alt=["\']([^"\']*)["\']''',
      dotAll: true,
    ).allMatches(html);
    for (final m in legacyMatches) {
      final typeStr = m.group(1)!;
      final slug = m.group(2)!;
      if (seenSlugs.contains(slug)) continue;

      var poster = m.group(3) ?? '';
      if (poster.startsWith('//')) poster = 'https:$poster';
      if (poster.isEmpty || poster.contains('404x.jpg')) continue;

      final title = m.group(4)?.trim() ?? slug;
      final normTitle = StreamValidator.normalizeTitle(title);
      if (normTitle.isNotEmpty && !seenTitles.add(normTitle)) continue;
      seenSlugs.add(slug);

      items.add(VodItem(
        id: 'pf_${typeStr}_$slug',
        title: title.isNotEmpty ? title : slug,
        poster: poster,
        backdrop: poster,
        genre: typeStr.startsWith('serie')
            ? 'Serie · Latino / Sub'
            : 'Película · Latino / Sub',
        rating: '',
        isSeries: typeStr.startsWith('serie'),
        slug: slug,
        provider: 'pelisflix',
        quality: 'HD',
      ));
    }

    return items;
  }

  /// Carga las temporadas y episodios de una serie de PelisFlix EN PARALELO
  Future<List<VodEpisode>> fetchSeriesEpisodes(String slug) async {
    try {
      final url = '$baseUrl/serie/$slug/';
      final res = await http
          .get(Uri.parse(url), headers: _headers)
          .timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return [];
      final html = res.body;

      // Regex corregida: acepta comilla simple o doble al cierre
      final seasonMatches = RegExp(
        r'''href=["\'](https?://[^"\'/]+/temporada/[^"\'/]+/?)["\']''',
      )
          .allMatches(html)
          .map((m) => m.group(1)!)
          .toSet()
          .toList();

      final allEpisodes = <VodEpisode>[];

      // Descarga paralela en lotes de hasta 5 temporadas simultáneas
      const batchSize = 5;
      for (var i = 0; i < seasonMatches.length; i += batchSize) {
        final batch = seasonMatches.skip(i).take(batchSize).toList();
        final batchResults = await Future.wait(batch.map((sUrl) async {
          try {
            final sRes = await http
                .get(Uri.parse(sUrl), headers: _headers)
                .timeout(const Duration(seconds: 8));
            if (sRes.statusCode != 200) return <VodEpisode>[];
            final sHtml = sRes.body;

            final epMatches = RegExp(
              r'''href=["\'](https?://[^"\'/]+/episodio/[^"\'/]+/?)["\']''',
            ).allMatches(sHtml).map((m) => m.group(1)!).toSet();

            final eps = <VodEpisode>[];
            for (final epUrl in epMatches) {
              final parts = epUrl.split('/').where((s) => s.isNotEmpty).last;
              final matchCode = RegExp(r'(\d+)x(\d+)').firstMatch(parts);
              final sNum =
                  matchCode != null ? int.tryParse(matchCode.group(1)!) ?? 1 : 1;
              final eNum =
                  matchCode != null ? int.tryParse(matchCode.group(2)!) ?? 1 : 1;

              eps.add(VodEpisode(
                id: epUrl,
                title: 'Episodio $eNum',
                episodeNumber: eNum,
                seasonNumber: sNum,
                duration: '45 min',
                overview: 'Capítulo de $slug disponible en HD.',
                slug: parts,
                provider: 'pelisflix',
              ));
            }
            return eps;
          } catch (_) {
            return <VodEpisode>[];
          }
        }));
        for (final list in batchResults) {
          allEpisodes.addAll(list);
        }
      }

      if (allEpisodes.isEmpty) {
        return List.generate(
          12,
          (i) => VodEpisode(
            id: '$baseUrl/episodio/$slug-1x${i + 1}/',
            title: 'Episodio ${i + 1}',
            episodeNumber: i + 1,
            seasonNumber: 1,
            duration: '45 min',
            overview: 'Capítulo de $slug en HD.',
            slug: '$slug-1x${i + 1}',
            provider: 'pelisflix',
          ),
        );
      }

      // Deduplicar por season+episode y ordenar ascendentemente
      final seenEp = <String>{};
      final unique = allEpisodes
          .where((e) => seenEp.add('${e.seasonNumber}x${e.episodeNumber}'))
          .toList();
      unique.sort((a, b) {
        if (a.seasonNumber != b.seasonNumber) {
          return a.seasonNumber.compareTo(b.seasonNumber);
        }
        return a.episodeNumber.compareTo(b.episodeNumber);
      });
      return unique;
    } catch (e) {
      debugPrint('[PelisflixService] Error cargando episodios de serie $slug: $e');
      return [];
    }
  }

  /// Saca los servidores que publica una página (ver [playerUrlsFromHtml]).
  /// `responded` false significa que no contestó, distinto de "respondió pero no
  /// lista jugadores".
  Future<({bool responded, List<String> urls})> _playersFor(String pageUrl) async {
    try {
      final res = await http
          .get(Uri.parse(pageUrl), headers: _headers)
          .timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return (responded: false, urls: <String>[]);
      return (responded: true, urls: playerUrlsFromHtml(res.body));
    } catch (e) {
      debugPrint('[PelisflixService] Error cargando $pageUrl: $e');
      return (responded: false, urls: <String>[]);
    }
  }

  /// Servidores que publica el HTML de una página. El template histórico los
  /// publicaba como `data-url` en base64; el de ahora los lista en un `<select>`
  /// con `<option value="http...">`, y algunos vienen envueltos (`?url=`
  /// codificado) por el proveedor, así que el servidor real es el de adentro. Se
  /// aceptan las tres formas para no romper a los proveedores que cambiaron de
  /// template.
  @visibleForTesting
  static List<String> playerUrlsFromHtml(String html) {
    final urls = <String>[];
    void add(String u) {
      if (u.startsWith('http') && !urls.contains(u)) urls.add(u);
    }

    for (final raw in RegExp(r'''data-(?:url|server)=["\']([^"\']+)["\']''')
        .allMatches(html)) {
      try {
        add(utf8.decode(base64.decode(raw.group(1)!), allowMalformed: true));
      } catch (_) {}
    }

    final optionRe = RegExp(
      r'''<option[^>]*value=["'](https?://[^"']+)["']''',
      caseSensitive: false,
    );
    for (final m in optionRe.allMatches(html)) {
      final u = m.group(1)!;
      add(u);
      final inner = Uri.parse(u).queryParameters['url'];
      if (inner != null) add(inner);
    }
    return urls;
  }

  /// Resuelve TODAS las fuentes de reproducción válidas (Nupload + VOE + directos)
  /// reportando progreso humano paso a paso para el HUD del reproductor.
  Future<List<StreamSource>> resolveAllStreamSources(
    String slugOrUrl, {
    void Function(String status)? onStatus,
  }) async {
    final cacheKey = slugOrUrl;
    final cached = _cache[cacheKey];
    if (cached != null && DateTime.now().isBefore(cached.expiresAt)) {
      onStatus?.call('Preparando reproducción...');
      return cached.sources;
    }

    final resolved = <StreamSource>[];
    final seenUrls = <String>{};
    var playbackHeaders = {
      'Referer': '$baseUrl/',
      'User-Agent': _headers['User-Agent']!,
    };

    try {
      var pageUrl = slugOrUrl.startsWith('http')
          ? slugOrUrl
          : '$baseUrl/pelicula/$slugOrUrl/';
      final isSlug = !slugOrUrl.startsWith('http');

      onStatus?.call('Consultando servidores disponibles...');
      final primary = await _playersFor(pageUrl);
      var responded = primary.responded;
      var decodedUrls = primary.urls;

      // v3.3.38: el dominio principal responde con un template cuyo reproductor
      // llena el navegador, así que ahí el scraper no ve servidores. Reintentamos
      // los espejos publicados, que sí listan los jugadores en el HTML.
      if (responded && decodedUrls.isEmpty && isSlug) {
        for (final mirror in mirrors) {
          final mirrorUrl = '$mirror/pelicula/$slugOrUrl/';
          if (mirrorUrl == pageUrl) continue;
          onStatus?.call('Probando un espejo...');
          pageUrl = mirrorUrl;
          final tried = await _playersFor(pageUrl);
          responded = tried.responded;
          decodedUrls = tried.urls;
          if (decodedUrls.isNotEmpty) break;
        }
      }

      // El Referer de reproducción es el de la página que dio la lista.
      playbackHeaders = {
        'Referer': pageUrl,
        'User-Agent': _headers['User-Agent']!,
      };

      if (!responded) {
        onStatus?.call('Servidor no disponible temporalmente.');
        return [];
      }

      if (decodedUrls.isEmpty) {
        onStatus?.call('No se encontraron servidores en este título.');
        return [];
      }

      // 1. Probar Nupload validando bytes reales (rechaza HTML DMCA de sv2/sv3/sv4)
      var nuploadCount = 0;
      for (final u in decodedUrls.where((x) => x.contains('nupload.my'))) {
        nuploadCount++;
        onStatus?.call('Verificando servidor #$nuploadCount...');
        final stream = await _decryptNupload(u);
        if (stream != null && stream.isNotEmpty && seenUrls.add(stream)) {
          final isReal = await StreamValidator.validateUrl(
            stream,
            headers: playbackHeaders,
          );
          if (!isReal) continue;
          resolved.add(StreamSource(
            url: stream,
            quality: 'Servidor HD #$nuploadCount',
            server: 'nupload',
            headers: playbackHeaders,
          ));
          if (resolved.length >= 2) break;
        }
      }

      // 2. Probar VOE (validado por bytes)
      if (resolved.length < 2) {
        var voeCount = 0;
        for (final u in decodedUrls.where((x) => x.contains('voe.'))) {
          voeCount++;
          onStatus?.call('Verificando servidor alterno #$voeCount...');
          final stream = await _decryptVoe(u, referer: pageUrl);
          if (stream != null && stream.isNotEmpty && seenUrls.add(stream)) {
            final isReal = await StreamValidator.validateUrl(
              stream,
              headers: playbackHeaders,
            );
            if (!isReal) continue;
            resolved.add(StreamSource(
              url: stream,
              quality: 'Servidor HD',
              server: 'voe',
              headers: playbackHeaders,
            ));
            if (resolved.length >= 2) break;
          }
        }
      }

      // 3. Directos .m3u8 o .mp4 (validados por bytes)
      for (final u in decodedUrls) {
        if ((u.contains('.m3u8') || u.contains('.mp4')) && seenUrls.add(u)) {
          final isReal = await StreamValidator.validateUrl(
            u,
            headers: playbackHeaders,
          );
          if (!isReal) continue;
          resolved.add(StreamSource(
            url: u,
            quality: 'Servidor HD',
            server: 'direct',
            headers: playbackHeaders,
          ));
        }
      }

      if (resolved.isNotEmpty) {
        _cache[cacheKey] = _CachedSources(
          resolved,
          DateTime.now().add(const Duration(hours: 3)),
        );
      }
    } catch (e) {
      debugPrint('[PelisflixService] Error resolviendo stream para $slugOrUrl: $e');
    }
    return resolved;
  }

  /// Compatibilidad: devuelve la primera URL HLS activa
  Future<String?> resolveStreamUrl(String slugOrUrl) async {
    final all = await resolveAllStreamSources(slugOrUrl);
    return all.isNotEmpty ? all.first.url : null;
  }

  /// Descifra el stream HLS directo de Nupload.my
  Future<String?> _decryptNupload(String nuploadUrl) async {
    try {
      final res = await http.get(
        Uri.parse(nuploadUrl),
        headers: {
          ..._headers,
          'Referer': baseUrl,
        },
      ).timeout(const Duration(seconds: 8));

      if (res.statusCode != 200) return null;
      final html = res.body;

      final idx = html.indexOf('.forEach');
      if (idx == -1) {
        // Fallback directo por si Nupload expone el m3u8 sin ofuscar
        final direct = RegExp(r'''(https?://[^\s"'<>]+\.m3u8[^\s"'<>]*)''')
            .firstMatch(html);
        return direct?.group(1);
      }

      final chunk = html.substring(
        idx - 60 > 0 ? idx - 60 : 0,
        (idx + 220 < html.length) ? idx + 220 : html.length,
      );
      final arrMatch = RegExp(r'([a-zA-Z0-9_]+)\.forEach').firstMatch(chunk);
      final offMatch = RegExp(r'-\s*(\d+)').firstMatch(chunk);
      final seszMatch = RegExp(r'sesz="([^"]*)"').firstMatch(chunk);

      if (arrMatch != null && offMatch != null && seszMatch != null) {
        final arrVar = arrMatch.group(1)!;
        final offset = int.parse(offMatch.group(1)!);
        final sesz = seszMatch.group(1)!;

        final defIdx = html.indexOf('$arrVar =');
        if (defIdx != -1) {
          final endArr = html.indexOf('];', defIdx);
          if (endArr != -1) {
            final rawItems =
                RegExp(r'"([^"]+)"').allMatches(html.substring(defIdx, endArr + 2));
            final sb = StringBuffer();
            for (final it in rawItems) {
              final dec =
                  utf8.decode(base64.decode(it.group(1)!), allowMalformed: true);
              final digits = dec.replaceAll(RegExp(r'\D'), '');
              if (digits.isNotEmpty) {
                final val = int.parse(digits) - offset;
                sb.writeCharCode(val);
              }
            }
            final hlsUrl = '${sb.toString()}?s=$sesz';
            if (hlsUrl.startsWith('http')) {
              return hlsUrl;
            }
          }
        }
      }
    } catch (e) {
      debugPrint('[PelisflixService] Error descifrando Nupload: $e');
    }
    return null;
  }

  /// Descifra el HLS directo de VOE.sx
  Future<String?> _decryptVoe(String voeUrl, {required String referer}) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    client.userAgent = _headers['User-Agent']!;
    try {
      var html = await _getVia(client, voeUrl, referer);

      final jsonRe = RegExp(
        r'<script\s+type="application/json">(.*?)</script>',
        dotAll: true,
      );
      var jsonMatch = jsonRe.firstMatch(html);
      if (jsonMatch == null) {
        final direct = RegExp(r'''(https?://[^\s"'<>]+\.m3u8[^\s"'<>]*)''')
            .firstMatch(html);
        if (direct != null) return direct.group(1);

        // v3.3.38: VOE ya no publica el JSON en la URL corta, responde una página
        // con el salto que daría el navegador (`window.location.href = 'https://
        // <dominio en rotacion>/e/<id>'`). Hay que dar ese salto; el dominio rota,
        // así que se usa el que la propia página dice, nunca uno fijado aqui.
        final hop = voeHopUrl(html);
        if (hop == null) return null;
        html = await _getVia(client, hop, referer);
        jsonMatch = jsonRe.firstMatch(html);
        if (jsonMatch == null) return null;
      }

      final rawList = jsonDecode(jsonMatch.group(1)!) as List;
      final p8 = rawList.first.toString();
      var vf = _rot13(p8);
      for (final p in ['@\$', '^^', '~@', '%?', '*~', '!!', '#&']) {
        vf = vf.replaceAll(p, '');
      }
      final vf4 = utf8.decode(base64.decode(vf), allowMalformed: true);
      final vf5 = String.fromCharCodes(vf4.codeUnits.map((c) => c - 3));
      final vf6 = vf5.split('').reversed.join();
      final decrypted = jsonDecode(
        utf8.decode(base64.decode(vf6), allowMalformed: true),
      ) as Map<String, dynamic>;
      return decrypted['source']?.toString() ?? decrypted['hls']?.toString();
    } catch (e) {
      debugPrint('[PelisflixService] Fallo descifrando VOE: $e');
      return null;
    } finally {
      client.close();
    }
  }

  /// URL del salto que la página de VOE manda dar al navegador. El dominio del
  /// destino rota, así que se usa siempre el que la página dice.
  @visibleForTesting
  static String? voeHopUrl(String html) {
    final m = RegExp(
      r'''window\.location\.href\s*=\s*["\'](https?://[^"\']+)["\']''',
    ).firstMatch(html);
    return m?.group(1);
  }

  /// GET con los headers de la app, para dar el salto que daría el navegador.
  Future<String> _getVia(HttpClient client, String url, String referer) async {
    final req = await client.getUrl(Uri.parse(url));
    req.headers.set('User-Agent', _headers['User-Agent']!);
    req.headers.set('Referer', referer);
    final res = await req.close().timeout(const Duration(seconds: 8));
    return res.transform(utf8.decoder).join().timeout(const Duration(seconds: 8));
  }

  static String _rot13(String input) {
    final out = StringBuffer();
    for (var i = 0; i < input.length; i++) {
      final code = input.codeUnitAt(i);
      if (code >= 65 && code <= 90) {
        out.writeCharCode(((code - 65 + 13) % 26) + 65);
      } else if (code >= 97 && code <= 122) {
        out.writeCharCode(((code - 97 + 13) % 26) + 97);
      } else {
        out.writeCharCode(code);
      }
    }
    return out.toString();
  }
}

class _CachedSources {
  final List<StreamSource> sources;
  final DateTime expiresAt;
  const _CachedSources(this.sources, this.expiresAt);
}
