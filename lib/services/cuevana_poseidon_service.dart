import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/models.dart';
import 'network_config_service.dart';
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

  static const List<String> mirrors = [
    'https://www.poseidonhd2.co',
    'https://wv3.cuevana3.eu',
  ];

  String _activeMirror = mirrors.first;

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
  Future<List<VodItem>> fetchSeries({int page = 1}) async {
    final path = page > 1 ? '/series/page/$page' : '/series';
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
    // Prioridad de host por confiabilidad verificada por bytes reales:
    // VidHide (7 espejos activos, HLS 1080p en ~100% de cine y series) ->
    // Vidara (API POST directa, HLS 1080p + subtítulos) -> Doodstream (MP4).
    final candidates = <_ServerCandidate>[];
    const langOrder = [
      ('latino', 'Latino'),
      ('spanish', 'Español'),
      ('english', 'Subtitulado'),
    ];
    const hostOrder = ['vidhide', 'streamwish', 'vidara', 'doodstream'];

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

    final resolved = <StreamSource>[];
    final seenUrls = <String>{};

    // Carrera en lotes paralelos de 3 hosts para resolución rápida (~2-3s)
    const batchSize = 3;
    for (var i = 0; i < candidates.length && resolved.length < 2; i += batchSize) {
      final batch = candidates.skip(i).take(batchSize).toList();
      final first = batch.first;
      onStatus?.call(
        'Verificando servidor (${first.language})...',
      );

      final batchResults = await Future.wait(batch.map((cand) async {
        final embedUrl = await _resolvePlayerRedirect(cand.playerPhpUrl);
        if (embedUrl == null) return null;

        StreamSource? source;
        if (cand.cyberlocker == 'vidhide') {
          source = await extractVidHide(
            embedUrl,
            label: 'HD · ${cand.language}',
          );
        } else if (cand.cyberlocker == 'streamwish') {
          source = await extractStreamWish(
            embedUrl,
            label: 'HD · ${cand.language}',
          );
        } else if (cand.cyberlocker == 'vidara') {
          source = await extractVidara(
            embedUrl,
            label: 'HD · ${cand.language}',
          );
        } else if (cand.cyberlocker == 'doodstream') {
          source = await _extractDoodstream(
            embedUrl,
            referer: cand.playerPhpUrl,
            label: 'HD · ${cand.language}',
          );
        }

        if (source == null) return null;
        final valid = await StreamValidator.validateUrl(
          source.url,
          headers: source.headers,
        );
        return valid ? source : null;
      }));

      for (final source in batchResults) {
        if (source != null && seenUrls.add(source.url)) {
          resolved.add(source);
        }
      }
    }

    if (resolved.isNotEmpty) {
      _streamCache[path] = _CachedStreams(
        resolved,
        DateTime.now().add(const Duration(hours: 2)),
      );
    }

    return resolved;
  }

  // ── Extracción de hosts reales ─────────────────────────────────────────────

  static const List<String> _streamWishMirrors = [
    'cdnwish.com',
    'jodwish.com',
    'swhoi.com',
    'uqloads.xyz',
    'embedwish.com',
    'swishsrv.com',
    'iplayerhls.com',
  ];

  /// Extrae todos los `.m3u8` del JS desempaquetado y los ordena priorizando
  /// rutas `/stream/.../master.m3u8` (200 OK) por encima de CDNs `premilkyway.com/hls2`
  /// (que suelen devolver 502 Bad Gateway).
  @visibleForTesting
  static List<String> rankExtractedM3u8Urls(String hay, String host) {
    final matches = RegExp(
      r'''(https?://[^\s"'<>]+\.m3u8[^\s"'<>]*|/stream/[^\s"'<>]+\.m3u8[^\s"'<>]*)''',
    ).allMatches(hay);
    final urls = <String>[];
    final seen = <String>{};
    for (final m in matches) {
      var u = m.group(1)!;
      if (u.startsWith('/')) u = 'https://$host$u';
      if (seen.add(u)) urls.add(u);
    }

    int score(String u) {
      final l = u.toLowerCase();
      if (l.contains('/stream/')) return 0; // Más confiable (200 OK)
      if (l.contains('premilkyway.com/hls2')) return 3; // Suele dar 502
      if (l.contains('master.m3u8')) return 1;
      return 2;
    }

    urls.sort((a, b) => score(a).compareTo(score(b)));
    return urls;
  }

  /// Extrae HLS 1080p desde StreamWish probando sus 7 espejos activos en paralelo
  /// y priorizando `/stream/.../master.m3u8`.
  Future<StreamSource?> extractStreamWish(
    String embedUrl, {
    required String label,
  }) async {
    try {
      final uri = Uri.parse(embedUrl);
      final segs = uri.pathSegments.where((s) => s.isNotEmpty).toList();
      if (segs.isEmpty) return null;
      final code = segs.last;

      const batchSize = 3;
      for (var i = 0; i < _streamWishMirrors.length; i += batchSize) {
        final batch = _streamWishMirrors.skip(i).take(batchSize).toList();
        final results = await Future.wait(batch.map((host) async {
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
                .timeout(const Duration(seconds: 6));
            if (res.statusCode != 200) return null;

            final unpacked = _unpackDeanEdwards(res.body);
            final hay = unpacked ?? res.body;
            final ranked = rankExtractedM3u8Urls(hay, host);
            if (ranked.isEmpty) return null;

            final headers = {
              'Referer': 'https://$host/',
              'Origin': 'https://$host',
              'User-Agent': StreamValidator.defaultUserAgent,
            };

            // Si hay más de un m3u8 (p. ej. /stream/ + premilkyway), elegir el primero vivo
            for (final candidateUrl in ranked) {
              if (ranked.length == 1) {
                return StreamSource(
                  url: candidateUrl,
                  quality: label,
                  server: 'streamwish',
                  headers: headers,
                );
              }
              final ok = await StreamValidator.validateUrl(
                candidateUrl,
                headers: headers,
                timeout: const Duration(seconds: 5),
              );
              if (ok) {
                return StreamSource(
                  url: candidateUrl,
                  quality: label,
                  server: 'streamwish',
                  headers: headers,
                );
              }
            }
          } catch (_) {}
          return null;
        }));

        for (final r in results) {
          if (r != null) return r;
        }
      }
    } catch (e) {
      debugPrint('[CuevanaPoseidon] StreamWish err: $e');
    }
    return null;
  }

  static const List<String> _vidHideMirrors = [
    'vidhidevip.com',
    'vidhideplus.com',
    'callistanise.com',
    'dhtpre.com',
    'peytonepre.com',
    'bingezove.com',
    'smoothpre.com',
  ];

  /// Extrae HLS 1080p desde VidHide probando sus 7 espejos activos en paralelo
  /// y desempaquetando el bloque Dean Edwards `eval(function(p,a,c,k,e,d))`.
  Future<StreamSource?> extractVidHide(
    String embedUrl, {
    required String label,
  }) async {
    try {
      final uri = Uri.parse(embedUrl);
      final segs = uri.pathSegments.where((s) => s.isNotEmpty).toList();
      if (segs.isEmpty) return null;
      final code = segs.last;

      const batchSize = 3;
      for (var i = 0; i < _vidHideMirrors.length; i += batchSize) {
        final batch = _vidHideMirrors.skip(i).take(batchSize).toList();
        final results = await Future.wait(batch.map((host) async {
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
                .timeout(const Duration(seconds: 6));
            if (res.statusCode != 200) return null;

            final unpacked = _unpackDeanEdwards(res.body);
            final hay = unpacked ?? res.body;
            final ranked = rankExtractedM3u8Urls(hay, host);
            if (ranked.isEmpty) return null;

            final headers = {
              'Referer': 'https://$host/',
              'Origin': 'https://$host',
              'User-Agent': StreamValidator.defaultUserAgent,
            };

            for (final candidateUrl in ranked) {
              if (ranked.length == 1) {
                return StreamSource(
                  url: candidateUrl,
                  quality: label,
                  server: 'vidhide',
                  headers: headers,
                );
              }
              final ok = await StreamValidator.validateUrl(
                candidateUrl,
                headers: headers,
                timeout: const Duration(seconds: 5),
              );
              if (ok) {
                return StreamSource(
                  url: candidateUrl,
                  quality: label,
                  server: 'vidhide',
                  headers: headers,
                );
              }
            }
          } catch (_) {}
          return null;
        }));

        for (final r in results) {
          if (r != null) return r;
        }
      }
    } catch (e) {
      debugPrint('[CuevanaPoseidon] VidHide err: $e');
    }
    return null;
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
          .timeout(const Duration(seconds: 8));
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
    final orderedMirrors = [
      _activeMirror,
      ...mirrors.where((m) => m != _activeMirror),
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

        episodes.add(VodEpisode(
          id: 'cp_ep_${itemSlug}_${sNum}x$eNum',
          title: title.isNotEmpty ? title : 'Episodio $eNum',
          episodeNumber: eNum,
          seasonNumber: sNum,
          duration: '45 min',
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
