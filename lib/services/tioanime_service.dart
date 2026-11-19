import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/models.dart';
import 'stream_validator.dart';

/// Proveedor de respaldo automático de Anime en Español (`tioanime.com`).
///
/// Extrae streams MP4 directos verificados desde `YourUpload` cuando el
/// proveedor principal (`JKAnime`) no encuentra un episodio o tiene un servidor caído.
class TioAnimeService {
  static final TioAnimeService _instance = TioAnimeService._internal();
  factory TioAnimeService() => _instance;
  TioAnimeService._internal();

  static const String baseUrl = 'https://tioanime.com';
  static const Map<String, String> _headers = {
    'User-Agent': StreamValidator.defaultUserAgent,
    'Accept-Language': 'es-MX,es;q=0.9',
  };

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

      final vidsMatch = RegExp(r'var\s+videos\s*=\s*(\[.*?\]);')
          .firstMatch(res.body);
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
    final cleanQuery = StreamValidator.stripAccents(titleOrSlug)
        .replaceAll('-', ' ')
        .trim();
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
