import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/models.dart';
import 'remote_providers_config.dart';
import 'stream_validator.dart';

/// Proveedor de respaldo automático de Anime en Español (`tioanime.com`).
///
/// Extrae streams MP4 directos verificados desde `YourUpload` cuando el
/// proveedor principal (`JKAnime`) no encuentra un episodio o tiene un servidor caído.
class TioAnimeService {
  static final TioAnimeService _instance = TioAnimeService._internal();
  factory TioAnimeService() => _instance;
  TioAnimeService._internal();

  static String get baseUrl => RemoteProvidersConfig.instance.tioAnimeBaseUrl;
  static const Map<String, String> _headers = {
    'User-Agent': StreamValidator.defaultUserAgent,
    'Accept-Language': 'es-MX,es;q=0.9',
  };

  final Map<String, List<VodEpisode>> _episodeCache = {};

  /// Limpia las cachés del servicio (no la memoria de red, que es del proceso).
  @visibleForTesting
  static void resetForTest() {
    _instance._episodeCache.clear();
  }

  /// Directorio de anime de TioAnime (`/directorio?p=$page`, verificado 200 OK).
  Future<List<VodItem>> fetchDirectory({int page = 1, String? genre}) async {
    try {
      final url = (genre != null && genre.isNotEmpty)
          ? '$baseUrl/directorio?genero[]=$genre&p=$page'
          : '$baseUrl/directorio?p=$page';
      final res = await http
          .get(Uri.parse(url), headers: _headers)
          .timeout(const Duration(seconds: 9));
      if (res.statusCode != 200) return [];
      return parseDirectoryCards(res.body);
    } catch (e) {
      debugPrint('[TioAnimeService] Directory err: $e');
      return [];
    }
  }

  /// Búsqueda directa de anime en TioAnime (`/directorio?q=...`).
  Future<List<VodItem>> search(String query) async {
    final clean = query.trim();
    if (clean.isEmpty) return [];
    try {
      final q = Uri.encodeQueryComponent(clean);
      final res = await http
          .get(Uri.parse('$baseUrl/directorio?q=$q'), headers: _headers)
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return [];
      return parseDirectoryCards(res.body);
    } catch (e) {
      debugPrint('[TioAnimeService] Search err: $e');
      return [];
    }
  }

  /// Lista completa de episodios reales desde `/anime/<slug>` (`var episodes = [...]`).
  Future<List<VodEpisode>> fetchEpisodes(
    String slugOrId, {
    int seasonNumber = 1,
  }) async {
    final slug = slugOrId.replaceFirst('tio_', '').trim();
    if (slug.isEmpty) return [];
    final cacheKey = '$slug#$seasonNumber';
    if (_episodeCache.containsKey(cacheKey)) return _episodeCache[cacheKey]!;

    try {
      final res = await http
          .get(Uri.parse('$baseUrl/anime/$slug'), headers: _headers)
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return [];

      final m =
          RegExp(r'var\s+episodes\s*=\s*\[([^\]]*)\]').firstMatch(res.body);
      if (m == null) return [];
      final nums = m
          .group(1)!
          .split(',')
          .map((s) => int.tryParse(s.trim()))
          .whereType<int>()
          .toSet()
          .toList()
        ..sort();
      if (nums.isEmpty) return [];

      final eps = [
        for (final n in nums)
          VodEpisode(
            id: '$baseUrl/ver/$slug-$n',
            title: 'Episodio $n',
            episodeNumber: n,
            seasonNumber: seasonNumber,
            duration: '24 min',
            overview: 'Episodio $n · Sub Español (TioAnime).',
            slug: '$slug/$n',
            provider: 'tioanime',
          ),
      ];
      _episodeCache[cacheKey] = eps;
      return eps;
    } catch (e) {
      debugPrint('[TioAnimeService] fetchEpisodes($slug) err: $e');
      return [];
    }
  }

  @visibleForTesting
  static List<VodItem> parseDirectoryCards(String html) {
    final out = <VodItem>[];
    final seen = <String>{};
    final matches = RegExp(
      r'<article\s+class="anime"[^>]*>(.*?)</article>',
      dotAll: true,
    ).allMatches(html);

    for (final m in matches) {
      final block = m.group(1)!;
      final href = RegExp(r'href="/anime/([^"]+)"').firstMatch(block)?.group(1);
      if (href == null || href.isEmpty || !seen.add(href)) continue;

      final img =
          RegExp(r'<img[^>]+src="([^"]+)"').firstMatch(block)?.group(1) ?? '';
      final rawTitle = RegExp(r'<h3[^>]*class="title"[^>]*>([^<]+)</h3>')
              .firstMatch(block)
              ?.group(1) ??
          href;
      final title = rawTitle
          .replaceAll('&amp;', '&')
          .replaceAll('&#039;', "'")
          .replaceAll('&quot;', '"')
          .trim();
      final poster =
          img.startsWith('http') ? img : (img.isNotEmpty ? '$baseUrl$img' : '');

      out.add(VodItem(
        id: 'tio_$href',
        title: title.isNotEmpty ? title : href,
        poster: poster,
        backdrop: poster,
        genre: 'Anime · Sub Español',
        rating: '',
        isSeries: true,
        isAnime: true,
        slug: href,
        provider: 'tioanime',
        quality: 'HD',
      ));
    }
    return out;
  }

  /// Resuelve fuentes MP4 verificadas para un episodio de anime por título o slug.
  Future<List<StreamSource>> resolveEpisodeFallback(
    String titleOrSlug,
    int episodeNumber, {
    void Function(String status)? onStatus,
  }) async {
    try {
      onStatus?.call('Buscando servidor alterno (Ep. $episodeNumber)...');
      final slug = await _findAnimeSlug(titleOrSlug);
      if (slug == null) return [];

      final epUrl = '$baseUrl/ver/$slug-$episodeNumber';
      final res = await http
          .get(Uri.parse(epUrl), headers: _headers)
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return [];

      final vidsMatch =
          RegExp(r'var\s+videos\s*=\s*(\[.*?\]);').firstMatch(res.body);
      if (vidsMatch == null) return [];

      final list = jsonDecode(vidsMatch.group(1)!) as List;
      final sources = <StreamSource>[];

      for (final entry in list) {
        if (entry is! List || entry.length < 2) continue;
        final host = entry[0].toString().toLowerCase();
        final embedUrl = entry[1].toString().replaceAll(r'\/', '/');

        if (host.contains('yourupload') && embedUrl.startsWith('http')) {
          onStatus?.call('Verificando servidor alterno...');
          final mp4 = await _extractYourUpload(embedUrl);
          if (mp4 != null) {
            final valid = await StreamValidator.validateUrl(
              mp4.url,
              headers: mp4.headers,
            );
            if (valid) {
              sources.add(mp4);
              break;
            }
          }
        }
      }

      return sources;
    } catch (e) {
      debugPrint('[TioAnimeService] Fallback err: $e');
      return [];
    }
  }

  Future<String?> _findAnimeSlug(String titleOrSlug) async {
    final cleanQuery =
        StreamValidator.stripAccents(titleOrSlug).replaceAll('-', ' ').trim();
    if (cleanQuery.isEmpty) return null;

    // 1. Probar slug directo primero (ultrarrápido)
    final directSlug = cleanQuery
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-|-$'), '');
    try {
      final check = await http
          .get(Uri.parse('$baseUrl/anime/$directSlug'), headers: _headers)
          .timeout(const Duration(seconds: 6));
      if (check.statusCode == 200 && check.body.contains('var anime_info')) {
        return directSlug;
      }
    } catch (_) {}

    // 2. Buscar en el directorio de TioAnime
    try {
      final q = Uri.encodeQueryComponent(cleanQuery);
      final res = await http
          .get(Uri.parse('$baseUrl/directorio?q=$q'), headers: _headers)
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return null;
      final m = RegExp(r'href="/anime/([^"]+)"').firstMatch(res.body);
      return m?.group(1);
    } catch (_) {
      return null;
    }
  }

  Future<StreamSource?> _extractYourUpload(String embedUrl) async {
    try {
      final res = await http
          .get(
            Uri.parse(embedUrl),
            headers: {..._headers, 'Referer': '$baseUrl/'},
          )
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return null;

      final m = RegExp(r"""file\s*:\s*['"]([^'"]+)['"]""").firstMatch(res.body);
      final rawUrl = m?.group(1);
      if (rawUrl == null || !rawUrl.startsWith('http')) return null;

      return StreamSource(
        url: rawUrl,
        quality: 'Servidor Alterno · HD',
        server: 'tioanime',
        headers: const {
          'Referer': 'https://www.yourupload.com/',
          'User-Agent': StreamValidator.defaultUserAgent,
        },
      );
    } catch (_) {
      return null;
    }
  }
}
